import web_webview from '@ohos.web.webview';
import mediaquery from '@ohos.mediaquery';
import { preferences } from '@kit.ArkData';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { abilityAccessCtrl, common, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { KeyCode } from '@kit.InputKit';
import { vibrator } from '@kit.SensorServiceKit';
import {
  BAR_HEIGHT, FONT_FAMILY, PROGRESS_HEIGHT, RAIL_WIDTH, RADIUS, S12, S16, S4, S8, TOUCH_TARGET,
  WIDE_BREAKPOINT
} from '../common/Theme';
import {
  TWITTER_ROUTES, TWITTER_COMPOSE, TWITTER_UA,
  TWITTER_SIGNUP, TWITTER_DM_COMPOSE, TWITTER_NOTIF_SETTINGS, TWITTER_EDIT_PROFILE,
  TWITTER_SETTINGS, TWITTER_BOOKMARKS,
  searchUrl, profileUrl, listsUrl, pathOf, routeIndexForUrl, profileHandleForUrl,
  isTabRootPath, userAgentFor
} from '../common/WebConfig';
import {
  OWN_HANDLE_SCRIPT, chromeScript, chromeFlagScript, scrollToTopScript,
  CLICK_POST_BUTTON_SCRIPT, PROFILE_BOOTSTRAP_SCRIPT, fillComposerScript,
  HOME_TAB_SCRIPT, selectHomeTabScript, AVATAR_SCRIPT, UNREAD_COUNTS_SCRIPT,
  ONLINE_PATCH
} from '../common/WebChrome';

// OpenTwit-Web: the real x.com web app inside a fully native HarmonyOS shell.
//
// The shell owns all app chrome — Navigation title (with the current x.com path
// as subtitle) and per-tab menus, native Search on Explore, a bottom bar that
// turns into a side rail on wide layouts, a native compose bottom sheet, a
// native compose FAB, native progress / first-load / offline / retry states,
// native back handling, tactile tab switching, and system colours so light/dark
// come from the OS. x.com supplies content only; its own top nav, bottom nav and
// floating compose button are removed by the injected scripts in WebChrome.ets.
//
// The single shared WebView lives outside any Tabs on purpose: Tabs destroys its
// inactive TabContent, which would reload x.com on every tab switch.

const DOMAIN: number = 0x0A11;
const TAG: string = 'OpenTwit';

const PREFS_NAME: string = 'opentwit_web';
const OWN_HANDLE_KEY: string = 'own_handle';
const AVATAR_KEY: string = 'own_avatar';
const DESKTOP_MODE_KEY: string = 'desktop_site';
// The composer's text, kept in ArkData preferences so a draft survives the
// sheet closing and the app being killed.
const COMPOSE_DRAFT_KEY: string = 'compose_draft';
const NOTIFICATION_ASKED_KEY: string = 'notification_asked';
const LOCATION_PERMISSIONS: Permissions[] = ['ohos.permission.LOCATION'];
const FIRST_LOAD_TIMEOUT_MS: number = 15000;
// The page's title and history only settle a moment after it navigates.
const PAGE_STATE_DELAY_MS: number = 700;
// How often the shell re-reads the unread counters from the page. x.com counts
// arrive over its own streaming connection, so a poll is what keeps the tab
// badges and the launcher badge in step with the account.
const BADGE_REFRESH_MS: number = 30000;
// A page that is mid-load has no navigation to read yet, so the first answer
// can be "not yet" (see UNREAD_COUNTS_SCRIPT). Ask again a few times instead of
// leaving the badges blank until the next tick.
const BADGE_RETRY_MS: number = 1200;
const BADGE_RETRY_LIMIT: number = 6;
// After the notification prompt, keep watching for a while in case the user
// allows it from Settings rather than in the dialog.
const NOTIFICATION_POLL_MS: number = 5000;
const NOTIFICATION_POLL_LIMIT: number = 6;
// The composer writes its draft a moment after the last keystroke.
const DRAFT_SAVE_DEBOUNCE_MS: number = 700;

// Bridge exposed to the page as window.otNative. x.com is a single-page app, so
// its navigations never fire the Web component's load callbacks; the injected
// history hook calls this instead.
class PageBridge {
  private handler: (url: string) => void = (url: string) => {
  };

  setHandler(handler: (url: string) => void): void {
    this.handler = handler;
  }

  onUrlChange(url: string): void {
    this.handler(url);
  }
}
// How long the account menu needs before it has rendered its links.
const BOOTSTRAP_SETTLE_MS: number = 1800;

@Entry
@Component
struct MainTabs {
  @State currentIndex: number = 0;
  @State progress: number = 0;
  @State hasError: boolean = false;
  @State searchText: string = '';
  @State ownHandle: string = '';
  // Signed-in avatar, read off the account's own profile page and cached, so
  // the Home header can show the real account picture like the stock app.
  @State avatarUrl: string = '';
  // Which Home timeline the native switcher has selected: 0 = For you,
  // 1 = Following. Mirrors x.com's own tab row.
  @State homeTabIndex: number = 0;
  @State viewingHandle: string = '';
  @State currentPath: string = '';
  @State currentUrl: string = '';
  @State isWide: boolean = false;
  @State firstLoadDone: boolean = false;
  @State sheetOpen: boolean = false;
  // Native composer state. "webComposer" is the escape hatch: when the page's
  // own composer cannot be driven (or the post needs media/GIF/poll), the sheet
  // reveals the real x.com composer instead of failing.
  @State draft: string = '';
  @State webComposer: boolean = false;
  @State posting: boolean = false;
  // True while the shell is reading the signed-in handle behind a native panel.
  @State discovering: boolean = false;
  // The page's own title (x.com's " / X" suffix stripped) and whether there is
  // web history to go back to. The shell draws the header for every page, so
  // these are what the native title bar shows.
  @State refreshing: boolean = false;
  // Unread items, read from the page's own navigation entries. Both the tab bar
  // and the launcher icon show them, so the count does not depend on the web UI
  // being on screen.
  @State unreadNotifications: number = 0;
  @State unreadMessages: number = 0;
  @State pageTitle: string = '';
  @State canGoBack: boolean = false;
  private controller: web_webview.WebviewController = new web_webview.WebviewController();
  private composeController: web_webview.WebviewController = new web_webview.WebviewController();
  private wideListener: mediaquery.MediaQueryListener | undefined = undefined;
  private bridge: PageBridge = new PageBridge();
  private firstLoadTimer: number = -1;
  private badgeTimer: number = -1;
  private badgeRetryTimer: number = -1;
  private badgeRetries: number = 0;
  private draftSaveTimer: number = -1;
  // Whether the notification prompt (the one that lets the icon carry a badge)
  // has been shown, so a decline is respected and never repeated.
  private notificationAsked: boolean = false;
  // Last count handed to the launcher, so the shell only calls out when it
  // actually changes.
  private badgeShown: number = -1;

  async aboutToAppear(): Promise<void> {
    this.bridge.setHandler((url: string) => {
      this.syncFromUrl(url);
      this.updateChromeFlag(url);
      this.applyPageChrome(url);
      this.schedulePageStateRead();
    });
    this.applyBreakpoints();
    this.armFirstLoadTimeout();
    this.armBadgeRefresh();
    try {
      const ctx: common.Context | undefined = this.getUIContext().getHostContext();
      if (ctx !== undefined) {
        const prefs: preferences.Preferences = await preferences.getPreferences(ctx, PREFS_NAME);
        const saved: string = await prefs.get(OWN_HANDLE_KEY, '') as string;
        if (saved !== '') {
          this.ownHandle = saved;
        }
        const avatar: string = await prefs.get(AVATAR_KEY, '') as string;
        if (avatar !== '') {
          this.avatarUrl = avatar;
        }
        const draft: string = await prefs.get(COMPOSE_DRAFT_KEY, '') as string;
        if (draft !== '') {
          this.draft = draft;
        }
        this.notificationAsked = await prefs.get(NOTIFICATION_ASKED_KEY, false) as boolean;
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'preferences unavailable: %{public}s', JSON.stringify(err));
    }
  }

  aboutToDisappear(): void {
    if (this.firstLoadTimer !== -1) {
      clearTimeout(this.firstLoadTimer);
      this.firstLoadTimer = -1;
    }
    if (this.badgeTimer !== -1) {
      clearInterval(this.badgeTimer);
      this.badgeTimer = -1;
    }
    if (this.badgeRetryTimer !== -1) {
      clearTimeout(this.badgeRetryTimer);
      this.badgeRetryTimer = -1;
    }
    if (this.draftSaveTimer !== -1) {
      clearTimeout(this.draftSaveTimer);
      this.draftSaveTimer = -1;
      // Leaving the app is a good moment to make sure the draft is on disk.
      this.saveDraft();
    }
    if (this.wideListener !== undefined) {
      try {
        this.wideListener.off('change');
      } catch (err) {
      }
      this.wideListener = undefined;
    }
  }

  // Coming back to the app is the moment the counts are most likely to be stale
  // (the page kept running in the background), so re-read them here as well as
  // on the timer.
  onPageShow(): void {
    this.refreshBadges();
  }

  // A page that never finishes loading must not leave the first-load spinner up
  // forever.
  private armFirstLoadTimeout(): void {
    this.firstLoadTimer = setTimeout(() => {
      this.firstLoadDone = true;
    }, FIRST_LOAD_TIMEOUT_MS);
  }

  private finishFirstLoad(): void {
    this.firstLoadDone = true;
    if (this.firstLoadTimer !== -1) {
      clearTimeout(this.firstLoadTimer);
      this.firstLoadTimer = -1;
    }
  }

  // Bottom bar on phones, side rail on wide layouts. The listener only flips a
  // state flag, so the WebView is never re-created by a breakpoint change.
  private applyBreakpoints(): void {
    try {
      const listener: mediaquery.MediaQueryListener =
        this.getUIContext().getMediaQuery().matchMediaSync('(width>=' + WIDE_BREAKPOINT + 'vp)');
      this.isWide = listener.matches;
      listener.on('change', (result: mediaquery.MediaQueryResult) => {
        this.isWide = result.matches;
      });
      this.wideListener = listener;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'media query unavailable: %{public}s', JSON.stringify(err));
    }
  }

  // Short tick on tab change — HarmonyOS expects light tactile confirmation for
  // navigation, and a device without a motor simply rejects the request.
  private tick(): void {
    // 2in1 desktops have no motor, and the SDK marks vibration as a capability
    // that is not present on every device type.
    if (!canIUse('SystemCapability.Sensors.MiscDevice')) {
      return;
    }
    try {
      vibrator.startVibration({ type: 'time', duration: 10 }, { id: 0, usage: 'unknown' })
        .catch((err: Error) => {
          hilog.debug(DOMAIN, TAG, 'no haptics: %{public}s', err.message);
        });
    } catch (err) {
    }
  }

  private toast(message: ResourceStr): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (err) {
    }
  }

  // System back: close the sheet, then walk the web history, then return to the
  // Home tab, and only then let the system close the app (HarmonyOS UX
  // requirement — back must not drop the user out of a page they can leave).
  onBackPress(): boolean {
    if (this.sheetOpen) {
      this.sheetOpen = false;
      return true;
    }
    try {
      if (this.controller.accessBackward()) {
        this.controller.backward();
        return true;
      }
    } catch (err) {
      return false;
    }
    if (this.currentIndex !== 0) {
      this.goRoute(0);
      return true;
    }
    return false;
  }

  private tabLabel(index: number): Resource {
    if (index === 0) {
      return $r('app.string.tab_home');
    } else if (index === 1) {
      return $r('app.string.tab_explore');
    } else if (index === 2) {
      return $r('app.string.tab_notifications');
    } else if (index === 3) {
      return $r('app.string.tab_messages');
    }
    return $r('app.string.tab_profile');
  }

  private async saveOwnHandle(handle: string): Promise<void> {
    try {
      const ctx: common.Context | undefined = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return;
      }
      const prefs: preferences.Preferences = await preferences.getPreferences(ctx, PREFS_NAME);
      await prefs.put(OWN_HANDLE_KEY, handle);
      await prefs.flush();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'own handle not persisted: %{public}s', JSON.stringify(err));
    }
  }

  private async saveAvatar(url: string): Promise<void> {
    try {
      const ctx: common.Context | undefined = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return;
      }
      const prefs: preferences.Preferences = await preferences.getPreferences(ctx, PREFS_NAME);
      await prefs.put(AVATAR_KEY, url);
      await prefs.flush();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'avatar not persisted: %{public}s', JSON.stringify(err));
    }
  }

  // WebviewController.runJavaScript answers with the evaluated result
  // JSON-encoded, so a JavaScript string arrives quoted. Every value the shell
  // reads back out of a page goes through here first.
  private static unquote(raw: string): string {
    if (!raw) {
      return '';
    }
    const first: string = raw.charAt(0);
    if (first === '"' && raw.length >= 2) {
      try {
        return JSON.parse(raw) as string;
      } catch (err) {
        return raw.substring(1, raw.length - 1);
      }
    }
    if (raw === 'undefined' || raw === 'null') {
      return '';
    }
    return raw;
  }

  private static parseHandle(raw: string): string {
    if (!raw) {
      return '';
    }
    const slash: number = raw.indexOf('/');
    if (slash < 0) {
      return '';
    }
    let out: string = '';
    for (let i: number = slash + 1; i < raw.length && out.length < 15; i++) {
      const ch: string = raw.charAt(i);
      if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
        (ch >= '0' && ch <= '9') || ch === '_') {
        out += ch;
      } else {
        break;
      }
    }
    // Case is kept: x.com treats handles case-insensitively but displays
    // them as typed, and the shell mirrors the page in the title bar.
    return out.length >= 1 ? out : '';
  }

  private discoverOwnProfile(navigate: boolean): void {
    if (this.ownHandle !== '') {
      this.finishDiscover(navigate);
      return;
    }
    // Fast path: a layout that links the account directly (the desktop sidebar
    // does; the mobile web does not).
    let pending: Promise<string> | undefined = undefined;
    try {
      pending = this.controller.runJavaScript(OWN_HANDLE_SCRIPT);
    } catch (err) {
      pending = undefined;
    }
    if (pending === undefined) {
      if (navigate) {
        this.bootstrapProfile();
      }
      return;
    }
    (pending as Promise<string>).then((raw: string) => {
      const direct: string = MainTabs.parseHandle('/' + MainTabs.unquote(raw));
      if (direct !== '') {
        this.acceptHandle(direct, navigate);
        return;
      }
      if (navigate) {
        this.bootstrapProfile();
      }
    }).catch(() => {
      if (navigate) {
        this.bootstrapProfile();
      }
    });
  }

  // The signed-in handle is only published inside the account menu on the
  // mobile web, so this opens that menu, reads the handle and closes it again —
  // behind a native panel, so what the user sees is a HarmonyOS spinner. It
  // runs at most once per install; the handle is then persisted.
  private bootstrapProfile(): void {
    this.discovering = true;
    let pending: Promise<string> | undefined = undefined;
    try {
      pending = this.controller.runJavaScript(PROFILE_BOOTSTRAP_SCRIPT);
    } catch (err) {
      pending = undefined;
    }
    if (pending === undefined) {
      this.finishBootstrap('');
      return;
    }
    (pending as Promise<string>).then(() => {
      setTimeout(() => {
        try {
          this.controller.runJavaScript('window.__otBoot||""').then((raw: string) => {
            this.finishBootstrap(MainTabs.parseHandle('/' + MainTabs.unquote(raw)));
          }).catch(() => {
            this.finishBootstrap('');
          });
        } catch (err) {
          this.finishBootstrap('');
        }
      }, BOOTSTRAP_SETTLE_MS + 1600);
    }).catch(() => {
      this.finishBootstrap('');
    });
  }

  private finishBootstrap(handle: string): void {
    this.discovering = false;
    if (handle !== '') {
      this.acceptHandle(handle, true);
      return;
    }
    this.finishDiscover(true);
  }

  private acceptHandle(handle: string, navigate: boolean): void {
    this.ownHandle = handle;
    this.saveOwnHandle(handle);
    this.finishDiscover(navigate);
  }

  // A signed-out visitor is sent to the profile editor too: x.com redirects
  // that URL to its own login flow, so the shell does not have to guess.
  private finishDiscover(navigate: boolean): void {
    if (!navigate) {
      return;
    }
    if (this.ownHandle !== '') {
      this.viewingHandle = this.ownHandle;
      this.loadWeb(profileUrl(this.ownHandle));
      return;
    }
    this.loadWeb(TWITTER_EDIT_PROFILE);
  }

  private loadWeb(url: string): void {
    this.hasError = false;
    this.progress = 0;
    try {
      // x.com refuses e-mail sign-up on its mobile web path, so that flow is
      // loaded with a desktop user agent. No user-facing switch: the shell
      // picks what the page needs.
      this.controller.setCustomUserAgent(
        userAgentFor(deviceInfo.deviceType === '2in1' || url.indexOf('/i/flow/signup') >= 0));
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'UA switch failed: %{public}s', JSON.stringify(err));
    }
    try {
      this.controller.loadUrl(url);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'loadUrl failed: %{public}s', JSON.stringify(err));
    }
  }

  // A 2in1 window is a desktop, so it asks x.com for the desktop web app: a
  // phone user agent inside a 1000+ vp window is a mismatch the site acts on
  // (and one its sign-in risk checks can read as an emulated browser). Phones,
  // tablets and unfolded foldables keep the mobile web app they were built
  // against.
  private userAgent(): string {
    return userAgentFor(deviceInfo.deviceType === '2in1');
  }

  // Feeds the document-start navigator.onLine patch (see ONLINE_PATCH). The
  // shell only ever corrects it downwards, when the main frame really failed.
  private setOnlineFlag(online: boolean): void {
    try {
      this.controller.runJavaScript('window.__otOnline=' + (online ? 'true' : 'false') + ';');
    } catch (err) {
    }
  }

  private syncFromUrl(url: string): void {
    const idx: number = routeIndexForUrl(url);
    if (idx >= 0 && idx !== this.currentIndex) {
      this.currentIndex = idx;
    }
    this.viewingHandle = profileHandleForUrl(url);
    this.currentPath = pathOf(url);
    this.currentUrl = url;
  }

  private goRoute(index: number): void {
    if (index === 4) {
      this.openOwnProfile();
      return;
    }
    if (index === this.currentIndex) {
      // Tapping the active tab scrolls to top, like the stock app.
      try {
        this.controller.runJavaScript(scrollToTopScript());
      } catch (err) {
      }
      return;
    }
    this.tick();
    this.currentIndex = index;
    this.viewingHandle = '';
    this.loadWeb(TWITTER_ROUTES[index]);
  }

  // Native Home switcher -> the page's own (hidden) timeline tab. The page
  // reports the resulting selection back through readHomeTab, so the underline
  // only moves once the timeline has actually changed.
  private selectHomeTab(index: number): void {
    if (index === this.homeTabIndex) {
      try {
        this.controller.runJavaScript(scrollToTopScript());
      } catch (err) {
      }
      return;
    }
    try {
      this.controller.runJavaScript(selectHomeTabScript(index));
    } catch (err) {
    }
    this.tick();
    this.homeTabIndex = index;
    this.schedulePageStateRead();
  }

  private openOwnProfile(): void {
    this.currentIndex = 4;
    this.hasError = false;
    if (this.ownHandle !== '') {
      this.viewingHandle = this.ownHandle;
      this.loadWeb(profileUrl(this.ownHandle));
      return;
    }
    this.progress = 0;
    this.discoverOwnProfile(true);
  }

  private titleMain(): string {
    if (this.viewingHandle !== '') {
      // The stock app titles a profile with the display name and puts the
      // handle underneath. x.com titles the page "Abhi (@Abhi_Flex) / X".
      const name: string = MainTabs.nameInTitle(this.pageTitle);
      if (name !== '') {
        return name;
      }
      return '@' + this.profileHandle();
    }
    if (isTabRootPath(this.currentPath)) {
      return '';
    }
    return this.pageTitle;
  }

  // Handle spelled the way the page spells it, falling back to the one in the
  // URL (which x.com lowercases).
  private profileHandle(): string {
    const fromTitle: string = MainTabs.handleInTitle(this.pageTitle);
    return fromTitle !== '' ? fromTitle : this.viewingHandle;
  }

  private static nameInTitle(title: string): string {
    const at: number = title.indexOf(' (@');
    if (at > 0) {
      return title.substring(0, at);
    }
    return '';
  }

  private static handleInTitle(title: string): string {
    const at: number = title.indexOf('@');
    if (at < 0) {
      return '';
    }
    let out: string = '';
    for (let i: number = at + 1; i < title.length && out.length < 15; i++) {
      const ch: string = title.charAt(i);
      const ok: boolean = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
        (ch >= '0' && ch <= '9') || ch === '_';
      if (!ok) {
        break;
      }
      out += ch;
    }
    return out;
  }

  private localized(key: Resource): string {
    try {
      const ctx: common.Context | undefined = this.getUIContext().getHostContext();
      if (ctx !== undefined) {
        return ctx.resourceManager.getStringSync(key.id);
      }
    } catch (err) {
    }
    return '';
  }

  // Second line of the header: a profile shows its handle, a post shows what
  // kind of page it is. Tab roots and everything else show nothing — no URLs.
  private subtitleMain(): string {
    if (this.viewingHandle !== '') {
      return '@' + this.profileHandle();
    }
    if (isTabRootPath(this.currentPath)) {
      return '';
    }
    const handle: string = profileHandleForUrl(this.currentUrl);
    if (handle !== '') {
      return '@' + handle;
    }
    if (this.currentPath.indexOf('/status/') >= 0) {
      return this.localized($r('app.string.post'));
    }
    return '';
  }

  private reloadCurrent(): void {
    this.progress = 0;
    this.refreshing = true;
    try {
      this.controller.refresh();
    } catch (err) {
      this.loadWeb(TWITTER_ROUTES[this.currentIndex]);
    }
  }

  // How far down the page the page's own header can sit. A phone keeps its
  // header in the top strip; a wide layout pushes it well below the fold.
  private chromeBand(): number {
    return this.isWide ? 300 : 140;
  }

  private applyPageChrome(url: string): void {
    const root: boolean = isTabRootPath(pathOf(url));
    try {
      this.controller.runJavaScript(chromeScript(this.ownHandle, root, this.chromeBand()));
    } catch (err) {
    }
  }

  private updateChromeFlag(url: string): void {
    try {
      this.controller.runJavaScript(chromeFlagScript(isTabRootPath(pathOf(url)), this.chromeBand()));
    } catch (err) {
    }
  }

  // Unread counters, straight off the page's own navigation entries. The page
  // is the only thing that knows the account's counts, and it already publishes
  // them for its own (hidden) tab row — see UNREAD_COUNTS_SCRIPT.
  //
  // A negative count means the page has not told us yet (still loading, or its
  // navigation has not hydrated), so the previous value stands and the read is
  // retried. Moving between tabs used to wipe the badges because a mid-reload
  // read came back empty and was taken at face value.
  private refreshBadges(): void {
    try {
      this.controller.runJavaScript(UNREAD_COUNTS_SCRIPT).then((raw: string) => {
        this.applyBadgeCounts(MainTabs.unquote(raw));
      }, (err: BusinessError) => {
        hilog.debug(DOMAIN, TAG, 'badge read failed: %{public}d %{public}s', err.code, err.message);
        this.retryBadgeRead();
      });
    } catch (err) {
      this.retryBadgeRead();
    }
  }

  private applyBadgeCounts(counts: string): void {
    const cut: number = counts.indexOf('/');
    if (cut <= 0) {
      this.retryBadgeRead();
      return;
    }
    const notifications: number = Number.parseInt(counts.substring(0, cut), 10);
    const messages: number = Number.parseInt(counts.substring(cut + 1), 10);
    if (Number.isNaN(notifications) || Number.isNaN(messages)) {
      this.retryBadgeRead();
      return;
    }
    if (notifications >= 0) {
      this.unreadNotifications = notifications;
    }
    if (messages >= 0) {
      this.unreadMessages = messages;
    }
    if (notifications < 0 || messages < 0) {
      this.retryBadgeRead();
    } else {
      this.badgeRetries = 0;
    }
    this.syncLauncherBadge();
  }

  // Ask again shortly — bounded, and only while the page still owes an answer.
  private retryBadgeRead(): void {
    if (this.badgeRetryTimer !== -1 || this.badgeRetries >= BADGE_RETRY_LIMIT) {
      return;
    }
    this.badgeRetries++;
    this.badgeRetryTimer = setTimeout(() => {
      this.badgeRetryTimer = -1;
      this.refreshBadges();
    }, BADGE_RETRY_MS);
  }

  // Keep the launcher icon's own badge in step with what the tab bar shows, so
  // the count is visible without opening the app (HarmonyOS draws the badge on
  // the desktop icon or the folder the icon sits in).
  private syncLauncherBadge(): void {
    const total: number = this.unreadNotifications + this.unreadMessages;
    if (total === this.badgeShown) {
      return;
    }
    if (total > 0 && !this.notificationsAllowed()) {
      // HarmonyOS treats the app-icon badge as a notification surface — its own
      // permission dialog lists "角标 / badge" among the reminder modes — so
      // nothing lands on the icon until the account allows notifications.
      this.askForNotificationsOnce();
      return;
    }
    this.badgeShown = total;
    hilog.info(DOMAIN, TAG, 'launcher badge -> %{public}d', total);
    try {
      notificationManager.setBadgeNumber(total)
        .then(() => {
          hilog.info(DOMAIN, TAG, 'launcher badge accepted: %{public}d', total);
        })
        .catch((err: BusinessError) => {
          hilog.warn(DOMAIN, TAG, 'launcher badge rejected: %{public}d %{public}s', err.code, err.message);
        });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'launcher badge unavailable: %{public}s', JSON.stringify(err));
    }
  }

  private notificationsAllowed(): boolean {
    try {
      return notificationManager.isNotificationEnabledSync();
    } catch (err) {
      return false;
    }
  }

  // Asked once, in context — when there is finally something to badge — and
  // never again after a decline. The tab bar badges do not depend on it, so
  // saying no only costs the launcher icon.
  private askForNotificationsOnce(): void {
    if (this.notificationAsked) {
      return;
    }
    this.notificationAsked = true;
    this.saveNotificationAsked();
    this.retryLauncherBadgeWhenAllowed(0);
    const host: common.Context | undefined = this.getUIContext().getHostContext();
    if (host === undefined) {
      return;
    }
    try {
      notificationManager.requestEnableNotification(host as common.UIAbilityContext)
        .then(() => {
          hilog.info(DOMAIN, TAG, '%{public}s', 'notifications allowed for the icon badge');
          this.badgeShown = -1;
          this.syncLauncherBadge();
        })
        .catch((err: BusinessError) => {
          hilog.info(DOMAIN, TAG, 'notifications declined (%{public}d): icon badge stays off', err.code);
        });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'notification request failed: %{public}s', JSON.stringify(err));
    }
  }

  // The user may allow notifications in Settings instead of in our dialog. Keep
  // checking for a while so the icon picks the count up without a relaunch.
  private retryLauncherBadgeWhenAllowed(attempt: number): void {
    if (attempt >= NOTIFICATION_POLL_LIMIT) {
      return;
    }
    setTimeout(() => {
      if (this.notificationsAllowed()) {
        this.badgeShown = -1;
        this.syncLauncherBadge();
        return;
      }
      this.retryLauncherBadgeWhenAllowed(attempt + 1);
    }, NOTIFICATION_POLL_MS);
  }

  private armBadgeRefresh(): void {
    if (this.badgeTimer !== -1) {
      clearInterval(this.badgeTimer);
    }
    this.badgeTimer = setInterval(() => {
      this.badgeRetries = 0;
      this.refreshBadges();
    }, BADGE_REFRESH_MS);
  }

  // Badge for a tab bar item: the count lives on Notifications and Messages,
  // and clears while that tab is the one on screen — the same thing the stock
  // app does when you open the tab and read it.
  private badgeCount(index: number): number {
    if (index === this.currentIndex) {
      return 0;
    }
    if (index === 2) {
      return this.unreadNotifications;
    }
    if (index === 3) {
      return this.unreadMessages;
    }
    return 0;
  }

  private static stripSiteSuffix(raw: string): string {
    let title: string = MainTabs.unquote(raw);
    const suffix: string = ' / X';
    if (title.length > suffix.length &&
      title.substring(title.length - suffix.length) === suffix) {
      title = title.substring(0, title.length - suffix.length);
    }
    // A post is titled "<author> on X: \"<text>\"" — the header should name the
    // author, not quote the whole post back at the user.
    const marker: string = ' on X: ';
    const at: number = title.indexOf(marker);
    if (at > 0) {
      title = title.substring(0, at);
    }
    return title;
  }

  // x.com's own header is removed on every page, so the shell takes the page
  // name from the document title instead (e.g. "Abhi (@Abhi_Flex) / X").
  private readPageState(): void {
    try {
      this.controller.runJavaScript('document.title').then((raw: string) => {
        const title: string = MainTabs.unquote(raw);
        this.pageTitle = MainTabs.stripSiteSuffix(title);
      });
    } catch (err) {
    }
    this.readHomeTab();
    this.readAvatar();
    try {
      this.canGoBack = this.controller.accessBackward();
    } catch (err) {
      this.canGoBack = false;
    }
  }

  // Keep the native Home switcher in step with whatever the page selected last
  // (the row is hidden, so this is the only place the state can come from).
  private readHomeTab(): void {
    try {
      this.controller.runJavaScript(HOME_TAB_SCRIPT).then((raw: string) => {
        const index: number = Number.parseInt(MainTabs.unquote(raw), 10);
        if (!Number.isNaN(index) && index >= 0) {
          this.homeTabIndex = index;
        }
      });
    } catch (err) {
    }
  }

  // Only the account's own profile page carries the signed-in avatar, and it is
  // worth a native fetch: the shell shows it in the Home header.
  private readAvatar(): void {
    if (this.ownHandle === '' || this.avatarUrl !== '') {
      return;
    }
    const handle: string = this.ownHandle.toLowerCase();
    if (this.currentPath !== '/' + handle) {
      return;
    }
    try {
      this.controller.runJavaScript(AVATAR_SCRIPT).then((raw: string) => {
        const url: string = MainTabs.unquote(raw);
        if (url.indexOf('http') === 0) {
          this.avatarUrl = url;
          this.saveAvatar(url);
        }
      });
    } catch (err) {
    }
  }

  private schedulePageStateRead(): void {
    setTimeout(() => {
      this.readPageState();
      this.refreshBadges();
    }, PAGE_STATE_DELAY_MS);
  }


  private goBack(): void {
    try {
      if (this.controller.accessBackward()) {
        this.controller.backward();
        return;
      }
    } catch (err) {
    }
    if (this.currentIndex !== 0) {
      this.goRoute(0);
    }
  }

  // Never auto-grant: the user decides, and only then do we ask the system for
  // ohos.permission.LOCATION and answer the web page with a real result.
  private askLocation(origin: string, geolocation: JsGeolocation): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.location_dialog_title'),
      message: $r('app.string.location_dialog_message'),
      primaryButton: {
        value: $r('app.string.deny'),
        action: () => {
          this.answerLocation(origin, geolocation, false);
        }
      },
      secondaryButton: {
        value: $r('app.string.allow'),
        action: () => {
          const ctx: common.Context | undefined = this.getUIContext().getHostContext();
          if (ctx === undefined) {
            this.answerLocation(origin, geolocation, false);
            return;
          }
          abilityAccessCtrl.createAtManager()
            .requestPermissionsFromUser(ctx, LOCATION_PERMISSIONS)
            .then((result: PermissionRequestResult) => {
              const granted: boolean = result.authResults.length > 0 && result.authResults[0] === 0;
              this.answerLocation(origin, geolocation, granted);
            })
            .catch((err: Error) => {
              hilog.warn(DOMAIN, TAG, 'location permission denied: %{public}s', err.message);
              this.answerLocation(origin, geolocation, false);
            });
        }
      }
    });
  }

  private answerLocation(origin: string, geolocation: JsGeolocation, allowed: boolean): void {
    try {
      geolocation.invoke(origin, allowed, false);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'geolocation invoke failed: %{public}s', JSON.stringify(err));
    }
  }

  // x.com's composer and profile editor ask for files through the WebView file
  // selector; wiring it to the system picker is what makes uploads work.
  private openFileSelector(event: OnShowFileSelectorEvent): void {
    try {
      const multiple: boolean =
        event.fileSelector.getMode() === FileSelectorMode.FileOpenMultipleMode;
      const options: photoAccessHelper.PhotoSelectOptions =
        new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE;
      options.maxSelectNumber = multiple ? 10 : 1;
      new photoAccessHelper.PhotoViewPicker().select(options)
        .then((result: photoAccessHelper.PhotoSelectResult) => {
          event.result.handleFileList(result.photoUris);
        })
        .catch((err: Error) => {
          hilog.warn(DOMAIN, TAG, 'file picker cancelled: %{public}s', err.message);
          event.result.handleFileList([]);
        });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'file selector failed: %{public}s', JSON.stringify(err));
      event.result.handleFileList([]);
    }
  }

  private openCompose(): void {
    // A fresh controller per sheet: the sheet's WebView is destroyed on close.
    this.composeController = new web_webview.WebviewController();
    // Whatever was typed last time is still here (see COMPOSE_DRAFT_KEY); the
    // composer opens with the draft in place instead of an empty box.
    this.webComposer = false;
    this.posting = false;
    this.sheetOpen = true;
  }

  // Drafts are saved as you type, so closing the sheet — or the app — cannot
  // lose what was written.
  private scheduleDraftSave(): void {
    if (this.draftSaveTimer !== -1) {
      clearTimeout(this.draftSaveTimer);
    }
    this.draftSaveTimer = setTimeout(() => {
      this.draftSaveTimer = -1;
      this.saveDraft();
    }, DRAFT_SAVE_DEBOUNCE_MS);
  }

  private saveDraft(): void {
    this.putPreference(COMPOSE_DRAFT_KEY, this.draft);
  }

  private saveNotificationAsked(): void {
    this.putPreference(NOTIFICATION_ASKED_KEY, true);
  }

  // Desktop keyboards: Escape leaves the composer and Ctrl/Cmd+Enter posts —
  // the two shortcuts every client of this kind has, and on a 2in1 they are
  // faster than reaching for the sheet's buttons. Returns true when the key is
  // consumed so it does not also reach the editor.
  private composeKey(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down) {
      return false;
    }
    if (event.keyCode === KeyCode.KEYCODE_ESCAPE) {
      this.sheetOpen = false;
      return true;
    }
    if (event.keyCode !== KeyCode.KEYCODE_ENTER) {
      return false;
    }
    if (event.metaKey === 1 || MainTabs.ctrlDown(event)) {
      this.postFromSheet();
      return true;
    }
    return false;
  }

  private static ctrlDown(event: KeyEvent): boolean {
    try {
      // Optional on the type: it is absent on older devices and under a stylus.
      if (event.getModifierKeyState === undefined) {
        return false;
      }
      return event.getModifierKeyState(['Ctrl']);
    } catch (err) {
      return false;
    }
  }

  private async putPreference(key: string, value: preferences.ValueType): Promise<void> {
    try {
      const ctx: common.Context | undefined = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return;
      }
      const prefs: preferences.Preferences = await preferences.getPreferences(ctx, PREFS_NAME);
      await prefs.put(key, value);
      await prefs.flush();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'preference write failed: %{public}s', JSON.stringify(err));
    }
  }

  // Native "Post": type the draft into the page's own editor, then press the
  // page's own submit button. The whole composer is HarmonyOS UI — only the
  // submit goes through x.com, so the post is a real post.
  private postFromSheet(): void {
    const text: string = this.draft.trim();
    if (text === '' || this.posting) {
      return;
    }
    this.posting = true;
    let pending: Promise<string> | undefined = undefined;
    try {
      pending = this.composeController.runJavaScript(fillComposerScript(text));
    } catch (err) {
      pending = undefined;
    }
    if (pending === undefined) {
      this.posting = false;
      this.openWebComposer();
      return;
    }
    (pending as Promise<string>).then((filled: string) => {
      if (MainTabs.unquote(filled) !== 'ok') {
        // The page's composer is not ready: hand the draft to the web composer
        // rather than dropping it.
        return '';
      }
      return this.composeController.runJavaScript(CLICK_POST_BUTTON_SCRIPT) as Promise<string>;
    }).then((result: string) => {
      this.posting = false;
      if (MainTabs.unquote(result) === 'ok') {
        this.tick();
        this.toast($r('app.string.compose_post_sent'));
        this.sheetOpen = false;
        // The draft is now a post; clear what was saved for next time.
        this.draft = '';
        this.saveDraft();
      } else {
        // The text is already in the page's editor; showing it lets the user
        // finish there (media, polls, threads) without retyping.
        this.openWebComposer();
      }
    }).catch(() => {
      this.posting = false;
      this.openWebComposer();
    });
  }

  private openWebComposer(): void {
    this.posting = false;
    this.webComposer = true;
    if (this.draft.trim() !== '') {
      this.toast($r('app.string.compose_web_fallback'));
    }
  }

  // The shell's title bar, laid out the way the X app lays out its own: a
  // leading control, a centre that belongs to the current tab, and at most one
  // trailing action. Every icon here is one the stock app also puts in a
  // header; anything already reachable from the tab bar, the page body or the
  // account menu stays out.
  @Builder
  navTitleBar() {
    Row({ space: 0 }) {
      if (this.showBack()) {
        this.backButton()
      } else if (this.isHomeRoot()) {
        this.accountAvatar()
      }
      if (this.isHomeRoot()) {
        this.homeTimelineTabs()
      } else if (this.isExploreSurface()) {
        this.headerSearch()
      } else {
        this.headerTitles()
      }
      this.headerAction()
    }
    .height(48)
    .alignItems(VerticalAlign.Center)
    .padding({ left: this.showBack() ? S4 : S12, right: S4 })
  }

  // Back only exists where there is history to walk and the page is not one of
  // the five tab roots.
  private showBack(): boolean {
    return this.canGoBack && !this.isTabRoot();
  }

  // A profile is a tab root too: /<handle> is what the Profile tab loads, so
  // the shell must not offer a back arrow there even though the web history has
  // an entry behind it.
  private isTabRoot(): boolean {
    if (isTabRootPath(this.currentPath)) {
      return true;
    }
    return this.currentIndex === 4 && this.isOwnProfile() &&
      this.currentPath === '/' + this.ownHandle.toLowerCase();
  }

  private isHomeRoot(): boolean {
    return this.currentPath === '/' || this.currentPath === '/home';
  }

  // Explore owns the native search field, including its result pages.
  private isExploreSurface(): boolean {
    return this.currentPath === '/explore' || this.currentPath.indexOf('/explore/') === 0 ||
      this.currentPath === '/search' || this.currentPath.indexOf('/search') === 0;
  }

  @Builder
  backButton() {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph($r('sys.symbol.arrow_left'))
        .fontSize(22)
        .fontColor([$r('sys.color.ohos_id_color_text_primary')])
    }
    .width(TOUCH_TARGET)
    .height(TOUCH_TARGET)
    .backgroundColor(Color.Transparent)
    .accessibilityText($r('app.string.back'))
    .accessibilityLevel('yes')
    .onClick(() => {
      this.goBack();
    })
  }

  // Account picture, as the stock app has it: top-left on Home, and the entry
  // point to the account's own pages. Until the profile page has been visited
  // once there is no picture to read, so the HarmonyOS account glyph stands in.
  @Builder
  accountAvatar() {
    Row() {
      if (this.avatarUrl !== '') {
        Image(this.avatarUrl)
          .width(32)
          .height(32)
          .borderRadius(16)
          .objectFit(ImageFit.Cover)
      } else {
        SymbolGlyph($r('sys.symbol.person_crop_circle_fill'))
          .fontSize(32)
          .fontColor([$r('sys.color.ohos_id_color_text_secondary')])
      }
    }
    .width(TOUCH_TARGET)
    .height(TOUCH_TARGET)
    .justifyContent(FlexAlign.Center)
    // Pointer devices (2in1 / tablet with a mouse) get the hover the phone
    // never needed.
    .hoverEffect(HoverEffect.Highlight)
    .accessibilityText($r('app.string.menu_account'))
    .accessibilityLevel('yes')
    .bindMenu(this.accountMenu)
  }

  // The account pages the stock app keeps one level down from the avatar.
  @Builder
  accountMenu() {
    Menu() {
      if (this.ownHandle !== '') {
        MenuItem({
          content: $r('app.string.menu_view_profile'),
          symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.person_fill'))
        })
          .onClick(() => {
            this.openOwnProfile();
          })
        MenuItem({
          content: $r('app.string.menu_bookmarks'),
          symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.bookmark_fill'))
        })
          .onClick(() => {
            this.loadWeb(TWITTER_BOOKMARKS);
          })
        MenuItem({
          content: $r('app.string.menu_lists'),
          symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.list_bullet_square_fill'))
        })
          .onClick(() => {
            this.loadWeb(listsUrl(this.ownHandle));
          })
      } else {
        MenuItem({
          content: $r('app.string.menu_create_account'),
          symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.person_badge_plus'))
        })
          .onClick(() => {
            this.loadWeb(TWITTER_SIGNUP);
          })
      }
      MenuItem({
        content: $r('app.string.menu_settings'),
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.gearshape'))
      })
        .onClick(() => {
          this.loadWeb(TWITTER_SETTINGS);
        })
    }
  }

  // "For you / Following", the one piece of the Home header the stock app draws
  // itself. The page's own copy of this row is hidden by the injected chrome, so
  // each tap drives the page's real tab instead of faking a timeline switch.
  @Builder
  homeTimelineTabs() {
    Row({ space: S4 }) {
      this.homeTimelineTab($r('app.string.home_for_you'), 0)
      this.homeTimelineTab($r('app.string.home_following'), 1)
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  homeTimelineTab(label: Resource, index: number) {
    Column({ space: 0 }) {
      Text(label)
        .fontSize(15)
        .fontFamily(FONT_FAMILY)
        .fontWeight(this.homeTabIndex === index ? FontWeight.Bold : FontWeight.Regular)
        // A large system font must not push the switcher out of the title bar.
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor(this.homeTabIndex === index
          ? $r('sys.color.ohos_id_color_text_primary')
          : $r('sys.color.ohos_id_color_text_secondary'))
      Column()
        .width(44)
        .height(3)
        .margin({ top: 5 })
        .borderRadius(2)
        .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
        .opacity(this.homeTabIndex === index ? 1 : 0)
    }
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: S12, right: S12 })
    .hoverEffect(HoverEffect.Highlight)
    .accessibilityText(label)
    .accessibilityLevel('yes')
    .onClick(() => {
      this.selectHomeTab(index);
    })
  }

  @Builder
  headerSearch() {
    Row() {
      Search({ value: $$this.searchText, placeholder: $r('app.string.search_placeholder') })
        .width('100%')
        .height(38)
        .placeholderFont({ size: 15, family: FONT_FAMILY })
        .textFont({ size: 15, family: FONT_FAMILY })
        .onChange((value: string) => {
          this.searchText = value;
        })
        .onSubmit((value: string) => {
          this.searchText = value;
          if (value.trim() !== '') {
            this.loadWeb(searchUrl(value.trim()));
          }
        })
    }
    .layoutWeight(1)
    .height('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ right: S8 })
  }

  @Builder
  headerTitles() {
    Column({ space: 0 }) {
      Text(this.headerTitle())
        .fontSize(20)
        .fontFamily(FONT_FAMILY)
        .fontWeight(FontWeight.Bold)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
      if (this.subtitleMain() !== '') {
        Text(this.subtitleMain())
          .fontSize(11)
          .fontFamily(FONT_FAMILY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
      }
    }
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Center)
    .layoutWeight(1)
  }

  private headerTitle(): string {
    const title: string = this.titleMain();
    // "X" is x.com's own site name and what it titles unknown pages with, so it
    // is not a page name: fall back to the tab the user is on.
    if (title !== '' && title !== 'X') {
      return title;
    }
    return this.localized(this.tabLabel(this.currentIndex));
  }

  // One trailing action per tab, matching the stock app: notification settings
  // on Notifications, message settings on Messages, settings on your own
  // profile, nothing anywhere else.
  @Builder
  headerAction() {
    // Actions belong to a tab's own root screen. On a page pushed from there
    // (notification settings, a chat, another account) the only control is the
    // back arrow the bar already draws.
    if (this.currentIndex === 2 && this.currentPath === '/notifications') {
      this.headerIconButton($r('sys.symbol.gearshape'), $r('app.string.menu_notification_settings'),
        () => {
          this.loadWeb(TWITTER_NOTIF_SETTINGS);
        })
    } else if (this.currentIndex === 3 &&
      (this.currentPath === '/messages' || this.currentPath === '/i/chat')) {
      // x.com has no separate direct-message settings page any more (its
      // /settings/messages route is gone), so this opens the settings root the
      // stock app's gear leads to as well.
      this.headerIconButton($r('sys.symbol.gearshape'), $r('app.string.menu_settings'), () => {
        this.loadWeb(TWITTER_SETTINGS);
      })
    } else if (this.currentIndex === 4 && this.isOwnProfile()) {
      this.headerIconButton($r('sys.symbol.gearshape'), $r('app.string.menu_settings'), () => {
        this.loadWeb(TWITTER_SETTINGS);
      })
    }
  }

  private isOwnProfile(): boolean {
    return this.ownHandle !== '' &&
      this.viewingHandle.toLowerCase() === this.ownHandle.toLowerCase();
  }

  @Builder
  headerIconButton(symbol: Resource, label: Resource, action: () => void) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph(symbol)
        .fontSize(22)
        .fontColor([$r('sys.color.ohos_id_color_text_primary')])
    }
    .width(TOUCH_TARGET)
    .height(TOUCH_TARGET)
    .backgroundColor(Color.Transparent)
    .accessibilityText(label)
    .accessibilityLevel('yes')
    .onClick(action)
  }

  // Filled HarmonyOS Symbols for the tab bar. The bar never falls back to
  // outline glyphs: the same filled icon is drawn in both states and colour
  // carries the selection (system blue when active, secondary grey when not).
  //
  // Explore uses the compass rather than the magnifier because the HarmonyOS
  // symbol set ships no filled magnifier (house/bell/envelope/person all have a
  // _fill twin; magnifyingglass does not), and an outline glyph among four
  // filled ones reads as a rendering mistake.
  private tabSymbol(index: number): Resource {
    if (index === 0) {
      return $r('sys.symbol.house_fill');
    } else if (index === 1) {
      return $r('sys.symbol.compass_circle_fill');
    } else if (index === 2) {
      return $r('sys.symbol.bell_fill');
    } else if (index === 3) {
      return $r('sys.symbol.envelope_fill');
    }
    return $r('sys.symbol.person_fill');
  }

  @Builder
  navItem(index: number) {
    Column({ space: S4 }) {
      Badge({
        count: this.badgeCount(index),
        position: BadgePosition.RightTop,
        style: { fontSize: 10, badgeSize: 16 }
      }) {
        SymbolGlyph(this.tabSymbol(index))
          .fontSize(this.isWide ? 26 : 23)
          .fontColor([this.currentIndex === index
            ? $r('sys.color.ohos_id_color_emphasize')
            : $r('sys.color.ohos_id_color_text_secondary')])
      }
      Text(this.tabLabel(index))
        .fontSize(11)
        .fontFamily(FONT_FAMILY)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontWeight(this.currentIndex === index ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.currentIndex === index
          ? $r('sys.color.ohos_id_color_emphasize')
          : $r('sys.color.ohos_id_color_text_secondary'))
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .width(this.isWide ? RAIL_WIDTH : undefined)
    .height(this.isWide ? TOUCH_TARGET + S16 : undefined)
    .layoutWeight(this.isWide ? 0 : 1)
    // Mouse hover, so the rail reads as a desktop navigation rail on 2in1.
    .hoverEffect(HoverEffect.Highlight)
    .accessibilityText(this.tabLabel(index))
    .accessibilityDescription(this.tabLabel(index))
    .accessibilityLevel('yes')
    .onClick(() => {
      this.goRoute(index);
    })
  }

  @Builder
  navBar() {
    Column() {
      if (!this.isWide) {
        Divider()
          .strokeWidth(0.5)
          .color($r('sys.color.ohos_id_color_list_separator'))
      }
      Flex({
        direction: this.isWide ? FlexDirection.Column : FlexDirection.Row,
        justifyContent: this.isWide ? FlexAlign.Center : FlexAlign.SpaceBetween,
        alignItems: ItemAlign.Center
      }) {
        this.navItem(0)
        this.navItem(1)
        this.navItem(2)
        this.navItem(3)
        this.navItem(4)
      }
      .width('100%')
      .height(this.isWide ? '100%' : BAR_HEIGHT)
    }
    .width(this.isWide ? RAIL_WIDTH : '100%')
    .height(this.isWide ? '100%' : BAR_HEIGHT)
    // Start (not Center) so the bar row keeps its position when the background
    // is expanded into the bottom safe area below.
    .justifyContent(this.isWide ? FlexAlign.Center : FlexAlign.Start)
    // One chrome surface for the whole shell: the tab bar and rail use the same
    // background as the title bar and the page, so there is no grey-vs-white
    // seam between the bar and the window area below it. The hairline divider
    // above the row keeps the separation from the web content.
    .backgroundColor($r('sys.color.ohos_id_color_background'))
    // Paint that surface all the way to the screen edge on devices where the
    // layout stops at the navigation-indicator safe area.
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  @Builder
  composeFab() {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph($r('sys.symbol.square_and_pencil_fill'))
        .fontSize(24)
        .fontColor([$r('sys.color.ohos_id_color_foreground_contrary')])
    }
    .width(56)
    .height(56)
    .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
    .shadow({ radius: 12, color: '#33000000', offsetX: 0, offsetY: 4 })
    .margin({ right: S16, bottom: S16 })
    .accessibilityText(this.currentIndex === 3
      ? $r('app.string.menu_new_message')
      : $r('app.string.compose_title'))
    .accessibilityLevel('yes')
    .onClick(() => {
      // The stock app's compose button starts a new post everywhere except
      // Messages, where it starts a new direct message.
      if (this.currentIndex === 3) {
        this.loadWeb(TWITTER_DM_COMPOSE);
      } else {
        this.openCompose();
      }
    })
  }

  @Builder
  errorState() {
    Column({ space: S12 }) {
      SymbolGlyph($r('sys.symbol.wifi_slash'))
        .fontSize(48)
        .fontColor([$r('sys.color.ohos_id_color_text_secondary')])
      Text($r('app.string.error_title'))
        .fontSize(17)
        .fontFamily(FONT_FAMILY)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
      Text($r('app.string.error_message'))
        .fontSize(14)
        .fontFamily(FONT_FAMILY)
        .textAlign(TextAlign.Center)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
      Button($r('app.string.retry'))
        .type(ButtonType.Capsule)
        .fontFamily(FONT_FAMILY)
        .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
        .margin({ top: S8 })
        .onClick(() => {
          this.hasError = false;
          this.progress = 0;
          try {
            this.controller.refresh();
          } catch (err) {
          }
        })
    }
    .width('100%')
    .height('100%')
    .padding({ left: S16, right: S16 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('sys.color.ohos_id_color_background'))
  }

  @Builder
  webView() {
    Web({ src: TWITTER_ROUTES[0], controller: this.controller })
      .width('100%')
      .height('100%')
      // Injected at document start, so the page's history hook always finds it.
      .javaScriptProxy({
        object: this.bridge,
        name: 'otNative',
        methodList: ['onUrlChange'],
        controller: this.controller
      })
      .onControllerAttached(() => {
        // userAgent() on the attribute is deprecated; the controller API is the
        // supported way and can only run once the controller is bound.
        try {
          this.controller.setCustomUserAgent(this.userAgent());
        } catch (err) {
          hilog.warn(DOMAIN, TAG, 'custom UA rejected: %{public}s', JSON.stringify(err));
        }
      })
      // x.com opens some flows — the Google and Apple sign-in hand-offs, and
      // links that leave the site — in a new tab. ArkWeb blocks the renderer
      // until this event is answered, which is why those links used to look
      // dead; the shell deliberately has one WebView, so the target is loaded
      // here and no second window is created.
      .onWindowNew((event: OnWindowNewEvent) => {
        try {
          const target: string = event.targetUrl;
          try {
            event.handler.setWebController(null);
          } catch (err) {
            hilog.warn(DOMAIN, TAG, 'new-window hand-off failed: %{public}s', JSON.stringify(err));
          }
          if (target !== '') {
            hilog.info(DOMAIN, TAG, 'new-window request served in place: %{public}s', target);
            this.loadWeb(target);
          }
        } catch (err) {
        }
      })
      // Runs before any page script: ArkWeb's own navigator.onLine is wrong on
      // these images, and x.com's Chat and sign-in flows act on it.
      .runJavaScriptOnDocumentStart([{ script: ONLINE_PATCH, scriptRules: ['*'] }])
      .javaScriptAccess(true)
      .domStorageAccess(true)
      // x.com's chat client keeps its session state in browser storage; ArkWeb
      // gates the database APIs behind this flag and defaults them off.
      .databaseAccess(true)
      .fileAccess(false)
      .mixedMode(MixedMode.Compatible)
      .cacheMode(CacheMode.Default)
      .overviewModeAccess(true)
      .zoomAccess(true)
      .geolocationAccess(true)
      .mediaPlayGestureAccess(false)
      .darkMode(WebDarkMode.Auto)
      .textZoomRatio(100)
      .onProgressChange((event) => {
        if (event) {
          this.progress = event.newProgress;
        }
      })
      .onPageBegin(() => {
        this.hasError = false;
      })
      .onPageEnd((event) => {
        this.progress = 100;
        this.refreshing = false;
        this.finishFirstLoad();
        // A page that rendered was served, so the connection is up — this is
        // what keeps the injected navigator.onLine patch honest.
        this.setOnlineFlag(true);
        if (event && event.url) {
          this.syncFromUrl(event.url);
          this.applyPageChrome(event.url);
        }
        this.schedulePageStateRead();
        if (this.ownHandle === '') {
          this.discoverOwnProfile(false);
        }
      })
      .onLoadIntercept((event) => {
        try {
          const url: string = event.data.getRequestUrl();
          if (url !== '' && (url.indexOf('x.com') >= 0 || url.indexOf('twitter.com') >= 0)) {
            this.syncFromUrl(url);
            this.updateChromeFlag(url);
          }
        } catch (err) {
        }
        return false;
      })
      .onErrorReceive((event) => {
        // Subresource failures (images, analytics) are normal on x.com — only
        // treat main-frame failures as fatal.
        try {
          if (event && event.request && !event.request.isMainFrame()) {
            return;
          }
        } catch (err) {
        }
        this.hasError = true;
        this.progress = 100;
        this.refreshing = false;
        this.finishFirstLoad();
        this.setOnlineFlag(false);
      })
      .onRenderExited((event) => {
        // The render process is restarted by the system; recover by loading the
        // page again instead of dumping the user on an error card.
        hilog.warn(DOMAIN, TAG, 'render exited: %{public}s', JSON.stringify(event));
        this.hasError = false;
        this.progress = 0;
        try {
          this.controller.refresh();
        } catch (err) {
          this.hasError = true;
        }
      })
      .onGeolocationShow((event) => {
        if (event && event.geolocation) {
          this.askLocation(event.origin, event.geolocation);
        }
      })
      .onShowFileSelector((event) => {
        this.openFileSelector(event);
        return true;
      })
  }

  @Builder
  webArea() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column({ space: 0 }) {
        if (this.progress < 100 && !this.hasError) {
          Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(PROGRESS_HEIGHT)
            .color($r('sys.color.ohos_id_color_emphasize'))
            .backgroundColor(Color.Transparent)
        }

        // Single shared WebView — always visible regardless of tab.
        if (this.hasError) {
          this.errorState()
        } else {
          Column() {
            // HarmonyOS pull-to-refresh drives the WebView directly, so the
            // header does not need a refresh button.
            Refresh({ refreshing: $$this.refreshing }) {
              this.webView()
            }
            .width('100%')
            .height('100%')
            .pullToRefresh(true)
            .onRefreshing(() => {
              this.refreshing = true;
              this.reloadCurrent();
            })
          }
          .width('100%')
          .layoutWeight(1)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.ohos_id_color_background'))

      if (!this.firstLoadDone) {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
            .color($r('sys.color.ohos_id_color_emphasize'))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor($r('sys.color.ohos_id_color_background'))
      }

      // Reading the signed-in handle briefly opens the page's account menu.
      // This native panel is what the user sees while that happens.
      if (this.discovering) {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
            .color($r('sys.color.ohos_id_color_emphasize'))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor($r('sys.color.ohos_id_color_background'))
      }

      // Native compose entry point, like the stock app: on the four content
      // tabs (never on Profile), and only once a page is on screen.
      if (this.currentIndex !== 4 && !this.hasError && this.firstLoadDone) {
        this.composeFab()
      }
    }
    .width('100%')
    .height('100%')
    .flexGrow(1)
    .flexShrink(1)
    .backgroundColor($r('sys.color.ohos_id_color_background'))
  }

  @Builder
  composeSheet() {
    Stack({ alignContent: Alignment.TopStart }) {
      // x.com's own composer, kept invisible under the native panel. It exists
      // only so the native Post button submits through the real web session;
      // if it has to surface (media, polls, threads, or an undrivable editor)
      // it is revealed and the native panel steps aside.
      Web({ src: TWITTER_COMPOSE, controller: this.composeController })
        .width('100%')
        .height('100%')
        .opacity(this.webComposer ? 1 : 0)
        .onControllerAttached(() => {
          try {
            this.composeController.setCustomUserAgent(this.userAgent());
          } catch (err) {
          }
        })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(false)
        .mixedMode(MixedMode.Compatible)
        .cacheMode(CacheMode.Default)
        .zoomAccess(false)
        .darkMode(WebDarkMode.Auto)
        .onShowFileSelector((event) => {
          this.openFileSelector(event);
          return true;
        })

      Column({ space: 0 }) {
        Row() {
          Button($r('app.string.compose_cancel'))
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontFamily(FONT_FAMILY)
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
            .onClick(() => {
              this.sheetOpen = false;
            })
          Blank()
          Text($r('app.string.compose_title'))
            .fontSize(17)
            .fontFamily(FONT_FAMILY)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
          Blank()
          Button($r('app.string.compose_post'))
            .buttonStyle(ButtonStyleMode.EMPHASIZED)
            .fontFamily(FONT_FAMILY)
            .enabled(this.draft.trim() !== '' && !this.posting)
            .onClick(() => {
              this.postFromSheet();
            })
        }
        .width('100%')
        .padding({ left: S8, right: S8, top: S8, bottom: S8 })
        .alignItems(VerticalAlign.Center)

        Divider()
          .strokeWidth(0.5)
          .color($r('sys.color.ohos_id_color_list_separator'))

        // Counter and the web-composer escape hatch sit above the field: with
        // the keyboard up, the bottom of the sheet is off screen.
        Row() {
          Text($r('app.string.compose_counter', this.draft.length))
            .fontSize(13)
            .fontFamily(FONT_FAMILY)
            .fontColor(this.draft.length > 280
              ? $r('sys.color.ohos_id_color_warning')
              : $r('sys.color.ohos_id_color_text_secondary'))
          Blank()
          // The parts of composing that are x.com's, not the shell's: media,
          // GIFs, polls and threads.
          Button($r('app.string.compose_more'))
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontFamily(FONT_FAMILY)
            .onClick(() => {
              this.openWebComposer();
            })
        }
        .width('100%')
        .padding({ left: S16, right: S8, top: S4, bottom: S4 })
        .alignItems(VerticalAlign.Center)

        TextArea({ text: $$this.draft, placeholder: $r('app.string.compose_placeholder') })
          .width('100%')
          .layoutWeight(1)
          .fontFamily(FONT_FAMILY)
          .fontSize(18)
          .backgroundColor(Color.Transparent)
          .padding({ left: S16, right: S16, top: S12 })
          .onChange(() => {
            this.scheduleDraftSave();
          })
          // Pre-IME: the editor would otherwise swallow Enter (it is a newline
          // there), so Ctrl/Cmd+Enter has to be handled before the input method
          // and the editor ever see the key.
          .onKeyPreIme((event: KeyEvent) => this.composeKey(event))
          .defaultFocus(true)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.ohos_id_color_background'))
      .visibility(this.webComposer ? Visibility.Hidden : Visibility.Visible)
    }
    .width('100%')
    .height('100%')
    .borderRadius({ topLeft: RADIUS, topRight: RADIUS })
    .clip(true)
    .backgroundColor($r('sys.color.ohos_id_color_background'))
    // Escape works from anywhere in the sheet, not only from the editor.
    .onKeyEvent((event: KeyEvent) => this.composeKey(event))
  }

  build() {
    Navigation() {
      // navBar() is declared first so ColumnReverse puts it at the bottom and
      // Row puts it on the left — same children, no re-creation on breakpoints.
      Flex({
        direction: this.isWide ? FlexDirection.Row : FlexDirection.ColumnReverse
      }) {
        this.navBar()
        this.webArea()
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .title(this.navTitleBar())
    .titleMode(NavigationTitleMode.Mini)
    // Navigation defaults to Split mode on wide windows, which would reserve a
    // left pane for the title bar and squeeze our own rail + WebView into it.
    // The shell owns the wide layout, so keep Navigation in Stack mode.
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .backgroundColor($r('sys.color.ohos_id_color_background'))
    .bindSheet($$this.sheetOpen, this.composeSheet(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: false,
      blurStyle: BlurStyle.COMPONENT_ULTRA_THICK
    })
  }
}
