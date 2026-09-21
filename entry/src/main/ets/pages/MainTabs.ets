import web_webview from '@ohos.web.webview';
import mediaquery from '@ohos.mediaquery';
import { preferences } from '@kit.ArkData';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { abilityAccessCtrl, common, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { vibrator } from '@kit.SensorServiceKit';
import {
  BAR_HEIGHT, PROGRESS_HEIGHT, RAIL_WIDTH, RADIUS, S12, S16, S4, S8, TOUCH_TARGET, WIDE_BREAKPOINT
} from '../common/Theme';
import {
  TWITTER_ROUTES, TWITTER_COMPOSE, TWITTER_UA, TWITTER_LOGIN,
  TWITTER_SIGNUP, TWITTER_DM_COMPOSE, TWITTER_NOTIF_SETTINGS, TWITTER_EDIT_PROFILE,
  searchUrl, profileUrl, pathOf, routeIndexForUrl, profileHandleForUrl, isTabRootPath, userAgentFor
} from '../common/WebConfig';
import {
  DISCOVER_OWN_HANDLE_SCRIPT, chromeScript, chromeFlagScript, scrollToTopScript,
  CLICK_POST_BUTTON_SCRIPT
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
const DESKTOP_MODE_KEY: string = 'desktop_site';
const LOCATION_PERMISSIONS: Permissions[] = ['ohos.permission.LOCATION'];
const FIRST_LOAD_TIMEOUT_MS: number = 15000;

@Entry
@Component
struct MainTabs {
  @State currentIndex: number = 0;
  @State progress: number = 0;
  @State hasError: boolean = false;
  @State searchText: string = '';
  @State ownHandle: string = '';
  @State viewingHandle: string = '';
  @State currentPath: string = '';
  @State currentUrl: string = '';
  @State isWide: boolean = false;
  @State desktopMode: boolean = false;
  @State firstLoadDone: boolean = false;
  @State sheetOpen: boolean = false;
  private controller: web_webview.WebviewController = new web_webview.WebviewController();
  private composeController: web_webview.WebviewController = new web_webview.WebviewController();
  private wideListener: mediaquery.MediaQueryListener | undefined = undefined;
  private firstLoadTimer: number = -1;

  async aboutToAppear(): Promise<void> {
    this.applyBreakpoints();
    this.armFirstLoadTimeout();
    try {
      const ctx: common.Context | undefined = this.getUIContext().getHostContext();
      if (ctx !== undefined) {
        const prefs: preferences.Preferences = await preferences.getPreferences(ctx, PREFS_NAME);
        const saved: string = await prefs.get(OWN_HANDLE_KEY, '') as string;
        if (saved !== '') {
          this.ownHandle = saved;
        }
        // A chosen user agent is a user preference; keep it across launches.
        this.desktopMode = await prefs.get(DESKTOP_MODE_KEY, false) as boolean;
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
    if (this.wideListener !== undefined) {
      try {
        this.wideListener.off('change');
      } catch (err) {
      }
      this.wideListener = undefined;
    }
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
    return out.length >= 1 ? out.toLowerCase() : '';
  }

  private discoverOwnProfile(navigate: boolean): void {
    let pending: Promise<string> | undefined = undefined;
    try {
      pending = this.controller.runJavaScript(DISCOVER_OWN_HANDLE_SCRIPT);
    } catch (err) {
      pending = undefined;
    }
    if (pending === undefined) {
      if (navigate) {
        this.loadWeb(TWITTER_LOGIN);
      }
      return;
    }
    (pending as Promise<string>).then((raw: string) => {
      const handle: string = MainTabs.parseHandle(raw);
      if (handle === '') {
        if (navigate) {
          this.loadWeb(TWITTER_LOGIN);
        }
        return;
      }
      this.ownHandle = handle;
      this.saveOwnHandle(handle);
      if (navigate && this.currentIndex === 4) {
        this.viewingHandle = handle;
        this.loadWeb(profileUrl(handle));
      }
    }).catch(() => {
      if (navigate) {
        this.loadWeb(TWITTER_LOGIN);
      }
    });
  }

  private loadWeb(url: string): void {
    this.hasError = false;
    this.progress = 0;
    try {
      this.controller.loadUrl(url);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'loadUrl failed: %{public}s', JSON.stringify(err));
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

  // Desktop site toggle. x.com refuses email sign-up on its mobile web path
  // ("email sign-up is only available in the app"), so the shell needs a way to
  // ask for the desktop experience.
  private toggleDesktopMode(): void {
    this.desktopMode = !this.desktopMode;
    this.saveDesktopMode(this.desktopMode);
    try {
      this.controller.setCustomUserAgent(userAgentFor(this.desktopMode));
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'UA switch failed: %{public}s', JSON.stringify(err));
    }
    const target: string = this.currentUrl !== '' ? this.currentUrl : TWITTER_ROUTES[this.currentIndex];
    this.loadWeb(target);
  }

  private async saveDesktopMode(enabled: boolean): Promise<void> {
    try {
      const ctx: common.Context | undefined = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return;
      }
      const prefs: preferences.Preferences = await preferences.getPreferences(ctx, PREFS_NAME);
      await prefs.put(DESKTOP_MODE_KEY, enabled);
      await prefs.flush();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'desktop mode not persisted: %{public}s', JSON.stringify(err));
    }
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
    if (this.currentIndex === 4 && this.viewingHandle !== '') {
      return '@' + this.viewingHandle;
    }
    return '';
  }

  private headerMenus(): NavigationMenuItem[] {
    const menus: NavigationMenuItem[] = [];
    if (this.currentIndex === 0) {
      menus.push({
        value: $r('app.string.menu_search'),
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.magnifyingglass')),
        action: () => {
          this.goRoute(1);
        }
      });
    } else if (this.currentIndex === 2) {
      menus.push({
        value: $r('app.string.menu_notification_settings'),
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.gearshape')),
        action: () => {
          this.loadWeb(TWITTER_NOTIF_SETTINGS);
        }
      });
    } else if (this.currentIndex === 3) {
      menus.push({
        value: $r('app.string.menu_new_message'),
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.square_and_pencil')),
        action: () => {
          this.loadWeb(TWITTER_DM_COMPOSE);
        }
      });
    } else if (this.currentIndex === 4) {
      // The Profile tab owns account actions: edit when signed in, create when
      // signed out. x.com's mobile web hides its own sign-up entry, so the shell
      // exposes it natively.
      if (this.ownHandle === '') {
        menus.push({
          value: $r('app.string.menu_create_account'),
          symbolIcon: new SymbolGlyphModifier($r('sys.symbol.person_badge_plus')),
          action: () => {
            this.loadWeb(TWITTER_SIGNUP);
          }
        });
      } else {
        menus.push({
          value: $r('app.string.menu_edit_profile'),
          symbolIcon: new SymbolGlyphModifier($r('sys.symbol.square_and_pencil')),
          action: () => {
            this.loadWeb(TWITTER_EDIT_PROFILE);
          }
        });
      }
    }
    menus.push({
      value: this.desktopMode ? $r('app.string.menu_mobile_site') : $r('app.string.menu_desktop_site'),
      symbolIcon: new SymbolGlyphModifier($r('sys.symbol.desktop_site')),
      action: () => {
        this.toggleDesktopMode();
      }
    });
    menus.push({
      value: $r('app.string.menu_refresh'),
      symbolIcon: new SymbolGlyphModifier($r('sys.symbol.arrow_counterclockwise')),
      action: () => {
        this.reloadCurrent();
      }
    });
    return menus;
  }

  private reloadCurrent(): void {
    this.progress = 0;
    try {
      this.controller.refresh();
    } catch (err) {
      this.loadWeb(TWITTER_ROUTES[this.currentIndex]);
    }
  }

  private applyPageChrome(url: string): void {
    const root: boolean = isTabRootPath(pathOf(url));
    try {
      this.controller.runJavaScript(chromeScript(this.ownHandle, root));
    } catch (err) {
    }
  }

  private updateChromeFlag(url: string): void {
    try {
      this.controller.runJavaScript(chromeFlagScript(isTabRootPath(pathOf(url))));
    } catch (err) {
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
    this.sheetOpen = true;
  }

  // Native "Post": drive x.com's own submit button and tell the user what
  // happened instead of failing silently.
  private postFromSheet(): void {
    let pending: Promise<string> | undefined = undefined;
    try {
      pending = this.composeController.runJavaScript(CLICK_POST_BUTTON_SCRIPT);
    } catch (err) {
      pending = undefined;
    }
    if (pending === undefined) {
      this.toast($r('app.string.compose_post_missing'));
      return;
    }
    (pending as Promise<string>).then((result: string) => {
      if (result === 'ok') {
        this.tick();
        this.toast($r('app.string.compose_post_sent'));
        this.sheetOpen = false;
      } else {
        this.toast($r('app.string.compose_post_missing'));
      }
    }).catch(() => {
      this.toast($r('app.string.compose_post_missing'));
    });
  }

  @Builder
  navTitleBar() {
    Column({ space: 0 }) {
      if (this.titleMain() !== '') {
        Text(this.titleMain())
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
      } else {
        Text(this.tabLabel(this.currentIndex))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
      }
      if (this.currentPath !== '') {
        Text(this.currentPath === '/' ? 'x.com' : 'x.com' + this.currentPath)
          .fontSize(11)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
      }
    }
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Center)
    .height(48)
    .padding({ left: S12 })
  }

  @Builder
  navItem(index: number, symbol: Resource) {
    Column({ space: S4 }) {
      SymbolGlyph(symbol)
        .fontSize(this.isWide ? 26 : 23)
        .fontWeight(this.currentIndex === index ? FontWeight.Bold : FontWeight.Regular)
        .fontColor([this.currentIndex === index
          ? $r('sys.color.ohos_id_color_emphasize')
          : $r('sys.color.ohos_id_color_text_secondary')])
      Text(this.tabLabel(index))
        .fontSize(11)
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
        justifyContent: this.isWide ? FlexAlign.Start : FlexAlign.SpaceBetween,
        alignItems: ItemAlign.Center
      }) {
        this.navItem(0, $r('sys.symbol.house'))
        this.navItem(1, $r('sys.symbol.magnifyingglass'))
        this.navItem(2, $r('sys.symbol.bell'))
        this.navItem(3, $r('sys.symbol.envelope'))
        this.navItem(4, $r('sys.symbol.person'))
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
      SymbolGlyph($r('sys.symbol.square_and_pencil'))
        .fontSize(24)
        .fontColor([$r('sys.color.ohos_id_color_foreground_contrary')])
    }
    .width(56)
    .height(56)
    .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
    .shadow({ radius: 12, color: '#33000000', offsetX: 0, offsetY: 4 })
    .margin({ right: S16, bottom: S16 })
    .accessibilityText($r('app.string.compose_title'))
    .accessibilityLevel('yes')
    .onClick(() => {
      this.openCompose();
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
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
      Text($r('app.string.error_message'))
        .fontSize(14)
        .textAlign(TextAlign.Center)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
      Button($r('app.string.retry'))
        .type(ButtonType.Capsule)
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
      .onControllerAttached(() => {
        // userAgent() on the attribute is deprecated; the controller API is the
        // supported way and can only run once the controller is bound.
        try {
          this.controller.setCustomUserAgent(userAgentFor(this.desktopMode));
        } catch (err) {
          hilog.warn(DOMAIN, TAG, 'custom UA rejected: %{public}s', JSON.stringify(err));
        }
      })
      .javaScriptAccess(true)
      .domStorageAccess(true)
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
        this.finishFirstLoad();
        if (event && event.url) {
          this.syncFromUrl(event.url);
          this.applyPageChrome(event.url);
        }
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
        this.finishFirstLoad();
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

        if (this.currentIndex === 1) {
          Search({ value: $$this.searchText, placeholder: $r('app.string.search_placeholder') })
            .width('100%')
            .margin({ left: S12, right: S12, top: S4, bottom: S8 })
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

        // Single shared WebView — always visible regardless of tab.
        if (this.hasError) {
          this.errorState()
        } else {
          Column() {
            this.webView()
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
    Column({ space: 0 }) {
      Row() {
        Button($r('app.string.compose_cancel'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .onClick(() => {
            this.sheetOpen = false;
          })
        Blank()
        Text($r('app.string.compose_title'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
        Blank()
        Button($r('app.string.compose_post'))
          .buttonStyle(ButtonStyleMode.EMPHASIZED)
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

      Web({ src: TWITTER_COMPOSE, controller: this.composeController })
        .width('100%')
        .layoutWeight(1)
        .onControllerAttached(() => {
          try {
            this.composeController.setCustomUserAgent(userAgentFor(this.desktopMode));
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
    }
    .width('100%')
    .height('100%')
    .borderRadius({ topLeft: RADIUS, topRight: RADIUS })
    .clip(true)
    .backgroundColor($r('sys.color.ohos_id_color_background'))
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
    .menus(this.headerMenus())
    .backgroundColor($r('sys.color.ohos_id_color_background'))
    .bindSheet($$this.sheetOpen, this.composeSheet(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: false,
      blurStyle: BlurStyle.COMPONENT_ULTRA_THICK
    })
  }
}
