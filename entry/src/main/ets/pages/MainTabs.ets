import web_webview from '@ohos.web.webview';
import mediaquery from '@ohos.mediaquery';
import { MediaAddress, resolveMedia, MEDIA_CLICK_SCRIPT } from '../common/WebMedia';
import { MediaFile, MediaFiles } from '../common/MediaFiles';
import { WebImageDownloads } from '../common/WebImageDownloads';
import { IncomingContent } from '../common/IncomingContent';
import { NativeImageViewer } from './NativeImageViewer';
import { NetworkSettingsSheet } from './NetworkSettingsSheet';
import { ComposerPanel } from './ComposerPanel';
import { NativeBottomBar } from './NativeBottomBar';
import { NativeTopBar } from './NativeTopBar';
import { NetworkConfig, NetworkSnapshot } from '../common/NetworkConfig';
import { preferences } from '@kit.ArkData';
import { isSiteUrl, isAuthUrl, mediaAcceptTypes, chooseMedia, installDownloads, sharePage, removeExpiredDownloads } from '../common/WebSystem';
import { abilityAccessCtrl, common, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { BusinessError, deviceInfo, pasteboard } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ColorMetrics, FrameCallback, LengthMetrics, SymbolGlyphModifier, window } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationTitleMode, HdsTabs, hdsMaterial,
  HdsTabsController, HdsAnimationMode, BlurStrategy, ScrollEffectType } from '@kit.UIDesignKit';
import { KeyCode } from '@kit.InputKit';
import { vibrator } from '@kit.SensorServiceKit';
import {
  BAR_HEIGHT, FONT_FAMILY, PROGRESS_HEIGHT, RAIL_WIDTH, RADIUS, S12, S16, S4, S8, TOUCH_TARGET,
  WIDE_BREAKPOINT
} from '../common/Theme';
import {
  TWITTER_BASE, TWITTER_ROUTES, TWITTER_COMPOSE, TWITTER_UA,
  TWITTER_NOTIF_SETTINGS, TWITTER_EDIT_PROFILE,
  TWITTER_SETTINGS, TWITTER_BOOKMARKS,
  profileUrl, listsUrl, pathOf, routeIndexForUrl, profileHandleForUrl,
  isTabRootPath, isPostDetailUrl, isSecondaryUrl, usesNativeNavigation, usesNativeHeader, userAgentFor
} from '../common/WebConfig';
import {
  OWN_HANDLE_SCRIPT, chromeScript, chromeFlagScript, chromeInsetsScript, chromeDocumentStartScript, chromeActiveScript, scrollToTopScript,
  CLICK_POST_BUTTON_SCRIPT, POST_RESULT_SCRIPT, profileBootstrapScript, clickRouteScript, fillComposerScript,
  HOME_TAB_SCRIPT, selectHomeTabScript, accountAvatarScript, accountAvatarDiagScript, UNREAD_COUNTS_SCRIPT,
  ACCOUNT_SWITCH_SCRIPT, COMPOSER_READY_SCRIPT, UNREAD_RESPONSE_SCRIPT
} from '../common/WebChrome';

// 原生层提供导航、纯文字编辑与系统交互，网页保留搜索及会话交互。
// 主 WebView 独立于标签内容，避免切换标签时销毁网页和会话。

const DOMAIN: number = 0x0A11;
const TAG: string = 'OpenTwit';

const PREFS_NAME: string = 'opentwit_web';
const OWN_HANDLE_KEY: string = 'own_handle';
const AVATAR_KEY: string = 'own_avatar';
const DESKTOP_MODE_KEY: string = 'desktop_site';
const FLOATING_BAR_KEY: string = 'floating_bar';
const AUTO_HIDE_BAR_KEY: string = 'auto_hide_bar';
const HEADER_HEIGHT: number = 56;
// HDS 的羽化蒙层只对 GRADIENT_BLUR 生效，蒙层向标题栏下方延伸这段高度。
const HEADER_BLUR_EXTRA_HEIGHT: number = 20;
// 滚动多少 vp 后顶栏达到完全模糊。
const HEADER_BLUR_DISTANCE: number = 32;
// 标题栏内容整体上移，给摄像头的上下留出更均匀的呼吸空间。
const HEADER_CONTENT_LIFT: number = 4;
const FLOATING_BAR_HEIGHT: number = 58;
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
const AVATAR_RETRY_MS: number = 1200;
const AVATAR_RETRY_LIMIT: number = 6;
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
  // 网页弹层只能绘制在 Web 内，需要通知原生控件让位。
  private modalHandler: (url: string, open: boolean) => void = () => {};
  setModalHandler(handler: (url: string, open: boolean) => void): void { this.modalHandler = handler; }
  onWebModal(url: string, open: boolean): void { this.modalHandler(url, open); }
  private profileHandler: (payload: string) => void = () => {};
  setProfileHandler(handler: (payload: string) => void): void { this.profileHandler = handler; }
  onProfileLayout(payload: string): void { this.profileHandler(payload); }
  private themeHandler: (color: string) => void = () => {};
  setThemeHandler(handler: (color: string) => void): void { this.themeHandler = handler; }
  onTheme(source: string, color: string): void { if (source === 'main') { this.themeHandler(color); } }
  private imageHandler: (payload: string) => boolean = () => false;
  setImageHandler(handler: (payload: string) => boolean): void { this.imageHandler = handler; }

  onImages(payload: string): boolean { return this.imageHandler(payload); }
  private handler: (url: string) => void = (url: string) => {
  };

  setHandler(handler: (url: string) => void): void {
    this.handler = handler;
  }

  onUrlChange(source: string, url: string): void {
    if (source === 'main') { this.handler(url); }
  }
}
// 网页路由与账号入口共用有界就绪检查，避免慢网误判。
const PROFILE_TIMEOUT_MS: number = 10000;

interface ImagePayload {
  urls: string[];
  index: number;
}

/** 网页边界使用 CSS 像素，接收时按实际视口统一换算为 vp。 */
interface ProfileLayout {
  url: string;
  width: number;
  viewWidth: number;
  scrollY: number;
  ready: boolean;
  hasBanner: boolean;
  bannerBottom: number;
  identityBottom: number;
  name: string;
  handle: string;
}

interface AccountPictureState {
  path: string;
}

interface ChromeDiagnostics {
  navigation: boolean;
  header: boolean;
  navMatches: number;
  pullMatches: number;
  avatarFound: boolean;
  error?: string;
}

class AvatarCleanupFrame extends FrameCallback {
  private cleanup: () => void;

  constructor(cleanup: () => void) {
    super();
    this.cleanup = cleanup;
  }

  onIdle(_timeLeftInNano: number): void {
    this.cleanup();
  }
}

@Entry
@Component
struct MainTabs {
  @State imageViewerOpen: boolean = false;
  private imageItems: MediaAddress[] = [];
  private imageIndex: number = 0;
  @State currentIndex: number = 0;
  @State progress: number = 0;
  @State hasError: boolean = false;
  @State ownHandle: string = '';
  // 从当前账号控件读取真实头像，缓存按已确认的账号隔离。
  @State avatarUrl: string = '';
  @State avatarPath: string = '';
  @State avatarFailedUrl: string = '';
  private avatarFiles: MediaFiles | undefined = undefined;
  private avatarGeneration: number = 0;
  private avatarReadRequest: number = 0;
  private avatarAlive: boolean = false;
  private avatarRetryTimer: number = -1;
  private avatarRetries: number = 0;
  private retiredAvatarFiles: MediaFiles[] = [];
  private avatarCleanupScheduled: boolean = false;
  // Which Home timeline the native switcher has selected: 0 = For you,
  // 1 = Following. Mirrors x.com's own tab row.
  @State homeTabIndex: number = 0;
  @State homeTabsHeight: number = 32;
  @State viewingHandle: string = '';
  @State currentPath: string = '';
  @State currentUrl: string = '';
  @State isWide: boolean = false;
  @State floatingBar: boolean = true;
  @State autoHideBar: boolean = true;
  @State @Watch('onAppearanceOpenChanged') appearanceOpen: boolean = false;
  @State @Watch('onNetworkOpenChanged') networkOpen: boolean = false;
  @State @Watch('onBarsCollapsedChanged') barsCollapsed: boolean = false;
  @State immersiveMaterial: boolean = false;
  @State bottomInset: number = 0;
  @State topInset: number = 0;
  private shellWindow: window.Window | undefined = undefined;
  private avoidChanged: (area: window.AvoidAreaOptions) => void = () => this.updateShellInsets();
  private tabsController: HdsTabsController = new HdsTabsController();
  // Web 的滚动由渲染进程持有，HDS 只能读取 ArkUI 可滚动组件；把网页偏移镜像到
  // 这个 1vp 隐藏滚动容器，标题栏才能按官方指南在两种样式间过渡。
  private blurScroller: Scroller = new Scroller();
  private lastBlurOffset: number = 0;
  private profileLayout: ProfileLayout | undefined = undefined;
  @State profileBlurProgress: number = 0;
  @State profileTitleOpacity: number = 0;
  @State profileHasBanner: boolean = true;
  @State profileName: string = '';
  @State measuredHandle: string = '';
  @State statusBarContentColor: string = '#000000';
  @State webColorMode: ThemeColorMode = ThemeColorMode.SYSTEM;
  @State pageBackground: string = '';
  @State webWidth: number = 0;
  private lastScrollY: number = 0;
  private scrollDistance: number = 0;
  private webTouchActive: boolean = false;
  // 方向确认后保留到明确反转，避免手指微抖触发相反动画。
  private webTouchDirection: number = 0;
  private webCollapseInertia: boolean = false;
  private lastWebScrollTime: number = 0;
  private lastTouchX: number = 0;
  private lastTouchY: number = 0;
  @State firstLoadDone: boolean = false;
  @State documentLoading: boolean = false;
  @State webModalOpen: boolean = false;
  @State sheetOpen: boolean = false;
  // Native composer state. "webComposer" is the escape hatch: when the page's
  // own composer cannot be driven (or the post needs media/GIF/poll), the sheet
  // reveals the real x.com composer instead of failing.
  @State draft: string = '';
  @State webComposer: boolean = false;
  @State composeUrl: string = TWITTER_COMPOSE;
  @State composeLoading: boolean = true;
  @State composePreparing: boolean = false;
  @State posting: boolean = false;
  @State rawWeb: boolean = false;
  @State desktopMode: boolean = false;
  @State preferencesReady: boolean = false;
  @State webSession: number = 0;
  @State webNetworkReady: boolean = true;
  private webSource: string = TWITTER_ROUTES[0];
  @State composeReady: boolean = false;
  private composeSyncTimer: number = -1;
  private composeRevision: number = 0;
  private pageStateTimer: number = -1;
  private notificationTimer: number = -1;
  @State authenticationPage: boolean = false;
  @State fullScreen: boolean = false;
  @StorageLink('appBackground') @Watch('onBackgroundChanged') appBackground: boolean = false;
  @StorageLink('incomingContent') @Watch('onIncomingContentChanged') incomingContent: IncomingContent =
    { kind: '', value: '' };
  @StorageLink('incomingError') @Watch('onIncomingErrorChanged') incomingError: number = 0;
  private incomingControllerReady: boolean = false;
  private incomingPageReady: boolean = false;
  private fullScreenHandler: FullScreenExitHandler | undefined = undefined;
  private fullScreenWindow: window.Window | undefined = undefined;
  private previousLayoutFullScreen: boolean = false;
  private downloadDelegate: web_webview.WebDownloadDelegate | undefined = undefined;
  private webImages: WebImageDownloads | undefined = undefined;
  private composeDownloadDelegate: web_webview.WebDownloadDelegate | undefined = undefined;
  @State postUncertain: boolean = false;
  private composeHandoff: boolean = false;
  @State composeMessage: ResourceStr = '';
  private composeOwner: string = '';
  private legacyDraft: string = '';
  private postTimer: number = -1;
  private postChecks: number = 0;
  private draftWrite: Promise<void> = Promise.resolve();
  private openingCompose: boolean = false;
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
  // 只缓存系统已接受的角标计数，失败不能阻止后续同步。
  private badgeShown: number = -1;
  private badgeSyncing: boolean = false;
  private badgeSyncTarget: string = '';
  private badgeSyncFailures: number = 0;
  private profileNavigation: number = 0;
  private navigationGeneration: number = 0;
  private networkUnsubscribe: (() => void) | undefined = undefined;
  private networkGeneration: number = 0;
  private networkPendingReload: boolean = false;
  private networkReloadTimer: number = -1;

  onWillApplyTheme(theme: Theme): void {
    const color = ColorMetrics.resourceColor(theme.colors.fontPrimary);
    this.statusBarContentColor = '#' + ((color.red << 16) | (color.green << 8) | color.blue)
      .toString(16).padStart(6, '0');
  }

  async aboutToAppear(): Promise<void> {
    this.avatarAlive = true;
    try {
      const shellContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      try {
        this.immersiveMaterial = hdsMaterial.getSystemMaterialTypes().includes(hdsMaterial.MaterialType.IMMERSIVE);
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'event=material_unavailable error=%{public}s', JSON.stringify(error));
      }
      try {
        this.shellWindow = await window.getLastWindow(shellContext);
        if (!this.avatarAlive) { return; }
        // 状态栏透出页面底色，文字颜色继续由导航组件管理。
        await this.shellWindow.setWindowSystemBarProperties({ statusBarColor: '#00000000' });
        this.shellWindow.on('avoidAreaChange', this.avoidChanged);
        this.updateShellInsets();
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'event=shell_window_unavailable error=%{public}s', JSON.stringify(error));
      }
      if (!this.avatarAlive) { return; }
      const net = NetworkConfig.getInstance();
      net.ensureInitialized(shellContext);
      const netSnapshot: NetworkSnapshot = net.snapshot();
      this.webNetworkReady = !(netSnapshot.mode === 'secure_only' && !netSnapshot.suspended && netSnapshot.applyError);
      if (!this.webNetworkReady) { this.hasError = true; }
      this.networkGeneration = netSnapshot.generation;
      this.networkUnsubscribe = net.subscribe((snapshot: NetworkSnapshot) => {
        const ready = !(snapshot.mode === 'secure_only' && !snapshot.suspended && snapshot.applyError);
        if (!ready) {
          this.navigationGeneration++;
          this.webNetworkReady = false;
          this.hasError = true;
          this.incomingControllerReady = false;
          this.incomingPageReady = false;
          this.cancelProfileNavigation();
          this.clearComposeSync();
          if (this.posting) { this.markPostUnknown(); }
          this.webImages?.close().catch((error: Error) => {
            hilog.error(DOMAIN, TAG, 'event=web_image_close_failed error=%{public}s', error.message);
          });
          this.webImages = undefined;
        } else if (!this.webNetworkReady) {
          this.webNetworkReady = true;
          this.recoverMediaWeb(this.rawWeb, false);
          this.composeController = new web_webview.WebviewController();
        }
        if (snapshot.generation !== this.networkGeneration) {
          this.networkPendingReload = true;
        }
      });
      this.bridge.setImageHandler((payload: string) => this.openImages(payload));
      this.bridge.setModalHandler((url: string, open: boolean) => {
        if (this.rawWeb || !this.incomingControllerReady || !isSiteUrl(url) || this.controller.getUrl() !== url) { return; }
        this.updateWebModal(open);
      });
      this.bridge.setProfileHandler((payload: string) => this.receiveProfileLayout(payload));
      this.bridge.setThemeHandler((color: string) => {
        const match = /^rgb\((\d{1,3}),\s*(\d{1,3}),\s*(\d{1,3})\)$/.exec(color);
        if (!match || !isSiteUrl(this.controller.getUrl())) { return; }
        const red = Number(match[1]), green = Number(match[2]), blue = Number(match[3]);
        if (red > 255 || green > 255 || blue > 255) { return; }
        this.pageBackground = color;
        this.webColorMode = red * 0.299 + green * 0.587 + blue * 0.114 < 128 ? ThemeColorMode.DARK : ThemeColorMode.LIGHT;
      });
      this.bridge.setHandler((url: string) => {
        this.saveWebSession();
        if (this.rawWeb) { return; }
        this.syncFromUrl(url);
        this.updateChromeFlag(url);
        this.applyPageChrome(url);
        this.schedulePageStateRead();
      });
      this.applyBreakpoints();
      this.armFirstLoadTimeout();
      this.armBadgeRefresh();
      try { await removeExpiredDownloads(shellContext.cacheDir); } catch (error) {
        hilog.warn(DOMAIN, TAG, 'event=download_cleanup_failed error=%{public}s', JSON.stringify(error));
        this.toast($r('app.string.operation_failed'));
      }
      const ctx: common.Context | undefined = this.getUIContext().getHostContext();
      if (ctx !== undefined) {
        const prefs: preferences.Preferences = await preferences.getPreferences(ctx, PREFS_NAME);
        this.legacyDraft = await prefs.get(COMPOSE_DRAFT_KEY, '') as string;
        this.notificationAsked = await prefs.get(NOTIFICATION_ASKED_KEY, false) as boolean;
        this.floatingBar = await prefs.get(FLOATING_BAR_KEY, true) as boolean;
        this.autoHideBar = await prefs.get(AUTO_HIDE_BAR_KEY, true) as boolean;
        this.desktopMode = await prefs.get(DESKTOP_MODE_KEY, false) as boolean;
        if (this.incomingControllerReady) { this.controller.setCustomUserAgent(this.userAgent()); }
        // 上次账号只预热头像，不用于资料跳转或发帖身份确认。
        const cachedHandle = await prefs.get(OWN_HANDLE_KEY, '') as string;
        if (this.ownHandle === '' && cachedHandle !== '') { this.restoreAvatar(cachedHandle, true); }
        this.syncChromeInsets();
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'event=shell_initialization_failed error=%{public}s', JSON.stringify(err));
      this.toast($r('app.string.operation_failed'));
    } finally {
      this.preferencesReady = true;
    }
  }

  aboutToDisappear(): void {
    this.navigationGeneration++;
    this.cancelProfileNavigation();
    this.incomingControllerReady = false;
    this.incomingPageReady = false;
    this.avatarAlive = false;
    this.stopBackgroundWork();
    this.clearComposeSync();
    this.resetAvatar();
    this.closeRetiredAvatarFiles();
    this.webImages?.close().catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'event=web_image_close_failed code=%{public}d', (err as BusinessError).code);
    });
    try { this.shellWindow?.off('avoidAreaChange', this.avoidChanged); } catch (error) {
      hilog.warn(DOMAIN, TAG, 'event=shell_window_release_failed error=%{public}s', JSON.stringify(error));
    }
    if (this.networkUnsubscribe !== undefined) {
      this.networkUnsubscribe();
      this.networkUnsubscribe = undefined;
    }
    if (this.networkReloadTimer !== -1) {
      clearTimeout(this.networkReloadTimer);
      this.networkReloadTimer = -1;
    }
    this.stopPostCheck();
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
        hilog.warn(DOMAIN, TAG, 'event=window_listener_release_failed code=%{public}d', (err as BusinessError).code);
      }
      this.wideListener = undefined;
    }
  }

  // Coming back to the app is the moment the counts are most likely to be stale
  // (the page kept running in the background), so re-read them here as well as
  // on the timer.
  onBackgroundChanged(): void {
    if (this.appBackground) {
      this.cancelProfileNavigation();
      this.stopBackgroundWork();
      this.clearAvatarRetry();
      this.clearComposeSync();
      this.saveWebSession();
    } else if (this.avatarAlive) {
      this.armBadgeRefresh();
      this.badgeRetries = 0;
      this.schedulePageStateRead();
      if (this.sheetOpen && !this.webComposer && !this.posting) { this.scheduleComposeSync(); }
      if (this.posting && this.postUncertain) { this.checkPostResult(); }
      this.flushNetworkReload();
    }
    if (this.incomingControllerReady && !this.rawWeb) {
      this.controller.runJavaScript(chromeActiveScript(!this.appBackground)).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'event=chrome_lifecycle_failed code=%{public}d', err.code);
      });
    }
    if (this.appBackground && this.composeOwner !== '' && !this.posting && !this.webComposer) { this.saveDraft(); }
  }

  /** 只停止可恢复的界面轮询，正在进行的发布仍保留待确认标志。 */
  private stopBackgroundWork(): void {
    if (this.badgeTimer !== -1) { clearInterval(this.badgeTimer); this.badgeTimer = -1; }
    if (this.badgeRetryTimer !== -1) { clearTimeout(this.badgeRetryTimer); this.badgeRetryTimer = -1; }
    if (this.pageStateTimer !== -1) { clearTimeout(this.pageStateTimer); this.pageStateTimer = -1; }
    if (this.notificationTimer !== -1) { clearTimeout(this.notificationTimer); this.notificationTimer = -1; }
    this.stopPostCheck();
  }

  /** 缩短登录 Cookie 等待周期落盘的窗口，避免突然退出时丢失尚未保存的会话。 */
  private async saveWebSession(): Promise<void> {
    try {
      await web_webview.WebCookieManager.saveCookieAsync();
      hilog.info(DOMAIN, TAG, 'event=session_saved');
    } catch (err) {
      const error = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'event=session_save_failed code=%{public}d', error.code);
      if (!this.appBackground) { this.toast($r('app.string.operation_failed')); }
    }
  }

  onPageShow(): void {
    this.refreshBadges();
    this.flushNetworkReload();
    this.onIncomingErrorChanged();
    this.onIncomingContentChanged();
  }

  /** 分享失败必须显式告知，不把不可解析的数据当成空草稿。 */
  private onIncomingErrorChanged(): void {
    if (this.incomingError === 0) { return; }
    this.incomingError = 0;
    this.toast($r('app.string.incoming_failed'));
  }

  /** 外部入口只在控制器就绪后消费，编辑或模态操作进行中不覆盖用户状态。 */
  private onIncomingContentChanged(): void {
    const content = this.incomingContent;
    if (content.kind === '' || !this.incomingControllerReady || !this.incomingPageReady) { return; }
    this.incomingContent = { kind: '', value: '' };
    if (this.modalBlocksNetworkReload() || this.fullScreen || this.openingCompose) {
      this.toast($r('app.string.incoming_busy'));
      return;
    }
    if (content.kind === 'compose') {
      this.openCompose(content.value);
      return;
    }
    this.loadWeb(content.value, false, true);
  }

  // A page that never finishes loading must not leave the first-load spinner up
  // forever.
  private armFirstLoadTimeout(): void {
    if (this.firstLoadTimer !== -1) { clearTimeout(this.firstLoadTimer); }
    this.firstLoadTimer = setTimeout(() => {
      this.firstLoadDone = true;
      this.documentLoading = false;
      this.firstLoadTimer = -1;
    }, FIRST_LOAD_TIMEOUT_MS);
  }

  private finishFirstLoad(): void {
    this.firstLoadDone = true;
    this.documentLoading = false;
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
        this.resetChromeScroll();
        this.syncChromeInsets();
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
      hilog.debug(DOMAIN, TAG, 'event=haptics_failed code=%{public}d', (err as BusinessError).code);
    }
  }

  private toast(message: ResourceStr): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'event=toast_failed code=%{public}d', (err as BusinessError).code);
    }
  }

  // System back: close the sheet, then walk the web history, then return to the
  // Home tab, and only then let the system close the app (HarmonyOS UX
  // requirement — back must not drop the user out of a page they can leave).
  onBackPress(): boolean {
    this.cancelProfileNavigation();
    if (this.imageViewerOpen) { this.imageViewerOpen = false; return true; }
    if (this.appearanceOpen) { this.appearanceOpen = false; return true; }
    if (this.networkOpen) { this.networkOpen = false; return true; }
    if (this.fullScreenHandler !== undefined) { this.fullScreenHandler.exitFullScreen(); return true; }
    if (this.sheetOpen) {
      this.closeCompose();
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

  private async saveAvatar(handle: string, url: string): Promise<void> {
    const generation: number = this.avatarGeneration;
    try {
      const ctx: common.Context | undefined = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return;
      }
      const prefs: preferences.Preferences = await preferences.getPreferences(ctx, PREFS_NAME);
      if (!this.avatarAlive || generation !== this.avatarGeneration || this.avatarUrl !== url ||
        this.ownHandle.toLowerCase() !== handle.toLowerCase()) { return; }
      await prefs.put(AVATAR_KEY + ':' + handle.toLowerCase(), url);
      await prefs.flush();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'event=avatar_cache_write_failed code=%{public}d', (err as BusinessError).code);
    }
  }

  private async restoreAvatar(handle: string, preview: boolean = false): Promise<void> {
    const generation: number = this.avatarGeneration;
    try {
      const ctx: common.Context | undefined = this.getUIContext().getHostContext();
      if (ctx === undefined) { return; }
      const prefs: preferences.Preferences = await preferences.getPreferences(ctx, PREFS_NAME);
      const url = await prefs.get(AVATAR_KEY + ':' + handle.toLowerCase(), '') as string;
      if (this.avatarAlive && generation === this.avatarGeneration && !this.authenticationPage &&
        (preview ? this.ownHandle === '' : this.ownHandle.toLowerCase() === handle.toLowerCase()) && this.avatarUrl === '' &&
        /^https:\/\/(pbs|abs)\.twimg\.com\//i.test(url)) {
        this.loadAvatar(url);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'event=avatar_cache_read_failed code=%{public}d', (err as BusinessError).code);
    }
  }

  /** 每个地址独占下载会话，复用真实图片下载器的 DoH 与回退策略。 */
  private async loadAvatar(url: string, retry: boolean = false): Promise<void> {
    if (!this.avatarAlive || this.rawWeb || this.authenticationPage || (!retry && this.avatarUrl === url)) { return; }
    const generation: number = ++this.avatarGeneration;
    const handle: string = this.ownHandle.toLowerCase();
    const previous: MediaFiles | undefined = this.avatarFiles;
    const wasDisplayed: boolean = this.avatarPath !== '';
    const files: MediaFiles = new MediaFiles(this.webImages);
    this.avatarFiles = files;
    this.avatarUrl = url;
    this.avatarPath = '';
    this.avatarFailedUrl = '';
    this.retireAvatarFiles(previous, wasDisplayed);
    try {
      const resolved = resolveMedia(url);
      const address: MediaAddress = { id: 'avatar_' + generation.toString(), source: url,
        candidates: resolved !== undefined ? resolved.candidates : [url] };
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const file: MediaFile = await files.load(address, context);
      if (!this.avatarAlive || generation !== this.avatarGeneration || this.ownHandle.toLowerCase() !== handle ||
        this.authenticationPage) { return; }
      this.avatarPath = 'file://' + file.path;
      if (this.avatarRetryTimer !== -1) { clearTimeout(this.avatarRetryTimer); }
      this.avatarRetryTimer = -1;
      if (handle !== '') { this.saveAvatar(handle, url); }
      hilog.debug(DOMAIN, TAG, 'event=avatar_loaded');
    } catch (err) {
      if (!this.avatarAlive || generation !== this.avatarGeneration) { return; }
      this.avatarFailedUrl = url;
      this.avatarFiles = undefined;
      this.retireAvatarFiles(files, false);
      hilog.warn(DOMAIN, TAG, 'event=avatar_download_failed code=%{public}d', (err as BusinessError).code);
      this.retryAvatarRead();
    }
  }

  private resetAvatar(): void {
    this.clearAvatarRetry();
    this.avatarGeneration++;
    this.avatarReadRequest++;
    const files: MediaFiles | undefined = this.avatarFiles;
    const wasDisplayed: boolean = this.avatarPath !== '';
    this.avatarFiles = undefined;
    this.avatarUrl = '';
    this.avatarPath = '';
    this.avatarFailedUrl = '';
    this.retireAvatarFiles(files, wasDisplayed);
  }

  private avatarImageFailed(path: string): void {
    if (!this.avatarAlive || path === '' || path !== this.avatarPath) { return; }
    this.avatarFailedUrl = this.avatarUrl;
    this.avatarPath = '';
    const files: MediaFiles | undefined = this.avatarFiles;
    this.avatarFiles = undefined;
    this.retireAvatarFiles(files, true);
    hilog.warn(DOMAIN, TAG, 'event=avatar_image_load_failed');
    this.retryAvatarRead();
  }

  private closeAvatarFiles(files: MediaFiles): void {
    files.close().catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'event=avatar_cleanup_failed code=%{public}d', (err as BusinessError).code);
    });
  }

  private closeRetiredAvatarFiles(): void {
    const retired: MediaFiles[] = this.retiredAvatarFiles;
    this.retiredAvatarFiles = [];
    this.avatarCleanupScheduled = false;
    for (const files of retired) { this.closeAvatarFiles(files); }
  }

  /** 先撤下旧 Image，再在帧渲染结束后删除文件，避免异步解码仍读取旧路径。 */
  private retireAvatarFiles(files: MediaFiles | undefined, wasDisplayed: boolean): void {
    if (files === undefined) { return; }
    if (!wasDisplayed || !this.avatarAlive) {
      this.closeAvatarFiles(files);
      return;
    }
    this.retiredAvatarFiles.push(files);
    if (this.avatarCleanupScheduled) { return; }
    this.avatarCleanupScheduled = true;
    this.getUIContext().postFrameCallback(new AvatarCleanupFrame(() => this.closeRetiredAvatarFiles()));
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

  private async discoverOwnProfile(): Promise<void> {
    if (this.rawWeb || this.discovering || this.sheetOpen) { return; }
    const pageUrl = this.currentUrl;
    const generation = this.profileNavigation;
    try {
      const raw = await this.controller.runJavaScript(OWN_HANDLE_SCRIPT);
      if (!this.avatarAlive || this.currentUrl !== pageUrl || this.appBackground || generation !== this.profileNavigation) { return; }
      const direct: string = MainTabs.parseHandle('/' + MainTabs.unquote(raw));
      if (direct !== '') { this.acceptHandle(direct, false); }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'event=account_read_failed code=%{public}d', (error as BusinessError).code);
    }
  }

  /** 切换路由或生命周期后，旧资料读取不能再驱动导航。 */
  private async cancelProfileNavigation(): Promise<void> {
    this.profileNavigation++;
    this.discovering = false;
    if (this.incomingControllerReady) {
      try { await this.controller.runJavaScript('window.__otBootCancel&&window.__otBootCancel()'); } catch (error) {
        hilog.warn(DOMAIN, TAG, 'event=account_read_cancel_failed code=%{public}d', (error as BusinessError).code);
      }
    }
  }

  private acceptHandle(handle: string, navigate: boolean): void {
    const changed: boolean = this.ownHandle.toLowerCase() !== handle.toLowerCase();
    if (changed) {
      this.cancelProfileNavigation();
      this.resetAvatar();
      this.clearNetworkBadgeCounts();
      this.unreadNotifications = 0;
      this.unreadMessages = 0;
      this.badgeShown = -1;
    }
    this.ownHandle = handle;
    this.saveOwnHandle(handle);
    if (changed) {
      this.restoreAvatar(handle);
      this.readAvatar();
    }
    this.finishDiscover(navigate);
  }

  // 无法确认本人入口时明确报错，避免误跳资料编辑页。
  private finishDiscover(navigate: boolean): void {
    if (!navigate) {
      return;
    }
    if (this.ownHandle !== '') {
      this.loadWeb(profileUrl(this.ownHandle));
      return;
    }
    this.toast($r('app.string.account_unconfirmed'));
  }

  /** 常规入口只触发网页路由；外部链接和故障恢复才允许建立新文档。 */
  private async loadWeb(url: string, keepProfile: boolean = false, allowDocumentLoad: boolean = false): Promise<void> {
    if (!this.webNetworkReady) { this.hasError = true; return; }
    if (!keepProfile) { this.cancelProfileNavigation(); }
    const generation = ++this.navigationGeneration;
    const pageUrl = this.currentUrl;
    try {
      const deadline = Date.now() + 3000;
      while (generation === this.navigationGeneration && this.webNetworkReady) {
        const result: string = MainTabs.unquote(await this.controller.runJavaScript(clickRouteScript(url)));
        if (generation !== this.navigationGeneration || !this.webNetworkReady) { return; }
        if (result === 'cancelled') { return; }
        if (result === 'clicked' || result === 'same') { this.hasError = false; return; }
        if (result !== 'pending' || Date.now() >= deadline) { break; }
        await new Promise<void>((resolve) => { setTimeout(resolve, 100); });
      }
      if (generation !== this.navigationGeneration || !this.webNetworkReady) { return; }
      await this.controller.runJavaScript('window.__otRouteCancel&&window.__otRouteCancel()');
      hilog.warn(DOMAIN, TAG, 'event=page_route_unavailable');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'event=page_route_script_failed error=%{public}s', JSON.stringify(err));
    }
    if (generation !== this.navigationGeneration || !this.webNetworkReady || this.currentUrl !== pageUrl) { return; }
    if (allowDocumentLoad) {
      try {
        this.hasError = false;
        this.progress = 0;
        this.controller.loadUrl(url);
        return;
      } catch (err) {
        this.hasError = true;
        hilog.error(DOMAIN, TAG, 'event=document_navigation_failed error=%{public}s', JSON.stringify(err));
      }
    }
    this.toast($r('app.string.operation_failed'));
  }

  // A 2in1 window is a desktop, so it asks x.com for the desktop web app: a
  // phone user agent inside a 1000+ vp window is a mismatch the site acts on
  // (and one its sign-in risk checks can read as an emulated browser). Phones,
  // tablets and unfolded foldables keep the mobile web app they were built
  // against.
  private userAgent(): string {
    return userAgentFor(this.desktopMode || deviceInfo.deviceType === '2in1');
  }

  private syncFromUrl(url: string): void {
    if (this.discovering && url !== this.currentUrl && pathOf(url) !== '/home') { this.cancelProfileNavigation(); }
    if (url !== this.currentUrl) { this.resetProfileLayout(); this.resetChromeScroll(); }
    const idx: number = routeIndexForUrl(url);
    if (idx >= 0 && idx !== this.currentIndex) {
      this.currentIndex = idx;
    }
    this.viewingHandle = profileHandleForUrl(url);
    this.currentPath = pathOf(url);
    this.currentUrl = url;
  }

  private async shareCurrentPage(): Promise<void> {
    try {
      await sharePage(this.getUIContext().getHostContext() as common.UIAbilityContext, this.controller.getUrl());
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'event=page_share_failed code=%{public}d', (err as BusinessError).code);
      this.toast($r('app.string.operation_failed'));
    }
  }

  /** 网页账号入口不修改会话；切换后重新确认身份和头像。 */
  private async openAccountSwitcher(): Promise<void> {
    this.cancelProfileNavigation();
    try {
      const result = MainTabs.unquote(await this.controller.runJavaScript(ACCOUNT_SWITCH_SCRIPT));
      if (result !== 'opened') { this.toast($r('app.string.account_unconfirmed')); }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'event=account_switch_open_failed code=%{public}d', (err as BusinessError).code);
      this.toast($r('app.string.operation_failed'));
    }
  }

  private goRoute(index: number): void {
    if (index === 4) {
      this.openOwnProfile();
      return;
    }
    this.cancelProfileNavigation();
    if (index === this.currentIndex && isTabRootPath(this.currentPath)) {
      // Tapping the active tab scrolls to top, like the stock app.
      try {
        this.controller.runJavaScript(scrollToTopScript());
      } catch (err) {
      }
      return;
    }
    this.tick();
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
    this.schedulePageStateRead();
  }

  private async openOwnProfile(): Promise<void> {
    this.cancelProfileNavigation();
    const generation = this.profileNavigation;
    this.discovering = true;
    this.hasError = false;
    try {
      // 能从当前网页确认身份时直接进入资料，避免先绕回主页。
      let handle = MainTabs.unquote(await this.controller.runJavaScript(OWN_HANDLE_SCRIPT));
      if (generation !== this.profileNavigation || !this.avatarAlive || this.appBackground) { return; }
      if (!/^[A-Za-z0-9_]{1,15}$/.test(handle)) {
        // 移动网页只在首页提供账号抽屉，缺少本人入口时沿用该身份确认流程。
        if (!this.isHomeRoot()) { await this.loadWeb(TWITTER_ROUTES[0], true); }
        const deadline = Date.now() + PROFILE_TIMEOUT_MS;
        while (!this.isHomeRoot() && Date.now() < deadline) {
          if (generation !== this.profileNavigation || !this.avatarAlive || this.appBackground) { return; }
          await new Promise<void>((resolve) => { setTimeout(resolve, 100); });
        }
        if (generation !== this.profileNavigation || !this.avatarAlive || this.appBackground) { return; }
        handle = this.isHomeRoot() ? await this.confirmCurrentAccount() : '';
      }
      if (generation !== this.profileNavigation || !this.avatarAlive || this.appBackground) { return; }
      if (handle === '') { this.toast($r('app.string.account_unconfirmed')); return; }
      this.acceptHandle(handle, true);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'event=profile_navigation_failed error=%{public}s', JSON.stringify(error));
      if (generation === this.profileNavigation) { this.toast($r('app.string.account_unconfirmed')); }
    } finally {
      if (generation === this.profileNavigation) { this.discovering = false; }
    }
  }

  private titleMain(): string {
    if (this.viewingHandle !== '') {
      if (this.profileName !== '') { return this.profileName; }
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
    if (this.measuredHandle !== '') { return this.measuredHandle; }
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
    if (isPostDetailUrl(this.currentUrl)) { return ''; }
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
    if (!this.webNetworkReady) { NetworkConfig.getInstance().refresh(); return; }
    // A retry replaces the error surface with the normal progress UI.
    this.hasError = false;
    this.avatarReadRequest++;
    this.clearAvatarRetry();
    if (this.avatarFailedUrl !== '' && this.avatarUrl !== '') { this.loadAvatar(this.avatarUrl, true); }
    this.progress = 0;
    this.refreshing = true;
    try {
      this.controller.refresh();
    } catch (err) {
      this.hasError = true;
      this.refreshing = false;
      hilog.error(DOMAIN, TAG, 'event=refresh_failed error=%{public}s', JSON.stringify(err));
    }
  }

  /** 重建所属 Web 隔离无 GUID 的旧下载；保留共享登录会话和当前站内地址。 */
  private recoverMediaWeb(showWeb: boolean, notify: boolean = true): void {
    this.navigationGeneration++;
    this.cancelProfileNavigation();
    this.imageViewerOpen = false;
    this.rawWeb = showWeb;
    this.webSource = this.currentUrl || TWITTER_ROUTES[0];
    this.webImages?.close().catch((error: Error) => {
      hilog.error(DOMAIN, TAG, 'event=web_image_close_failed error=%{public}s', error.message);
      this.toast($r('app.string.operation_failed'));
    });
    this.webImages = undefined;
    this.incomingControllerReady = false;
    this.incomingPageReady = false;
    this.webModalOpen = false;
    this.controller = new web_webview.WebviewController();
    this.hasError = false;
    this.progress = 0;
    this.webSession++;
    if (notify && !showWeb) { this.toast($r('app.string.media_reopen')); }
  }

  /** 账号读取失败不应使原生界面消失；登录与未知路由交给网页。 */
  private showsNativeNavigation(): boolean {
    return !this.rawWeb && !this.fullScreen && !this.authenticationPage &&
      usesNativeNavigation(this.currentUrl);
  }

  /** 私信使用固定视口和底部输入框，保留原生栏占位而不覆盖网页。 */
  private overlaysWeb(): boolean {
    return this.showsNativeNavigation() && (isPostDetailUrl(this.currentUrl) || this.currentIndex !== 3);
  }

  private bottomChromeHeight(): number {
    return this.webModalOpen || !this.showsNativeNavigation() || isSecondaryUrl(this.currentUrl) || (this.isWide && !isPostDetailUrl(this.currentUrl)) ? 0 :
      (this.floatingBar ? FLOATING_BAR_HEIGHT : BAR_HEIGHT) + this.bottomInset;
  }

  /** 弹层关闭后恢复原有底栏及网页留白，不改动标题栏和系统栏。 */
  private updateWebModal(open: boolean): void {
    if (this.webModalOpen === open) { return; }
    this.webModalOpen = open;
    this.syncChromeInsets();
    if (!open) { this.flushNetworkReload(); }
  }

  private updateShellInsets(): void {
    if (!this.shellWindow) { return; }
    const area = this.shellWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
    this.bottomInset = this.getUIContext().px2vp(area.bottomRect.height);
    const systemArea = this.shellWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    this.topInset = this.getUIContext().px2vp(systemArea.topRect.height);
    this.syncChromeInsets();
  }

  private onBarsCollapsedChanged(): void {
    if (this.barsCollapsed) { this.tabsController.applyHideAnimation(HdsAnimationMode.SCROLL_ANIMATION); }
    else { this.tabsController.applyShowAnimation(HdsAnimationMode.SCROLL_ANIMATION); }
  }

  /** 同一目标状态只下发一次，避免连续滚动重启动画。 */
  private setBarsCollapsed(collapsed: boolean): void {
    if (collapsed !== this.barsCollapsed) { this.barsCollapsed = collapsed; }
  }

  private topChromeHeight(): number {
    return this.showsNativeNavigation() && usesNativeHeader(this.currentUrl) ? HEADER_HEIGHT : 0;
  }

  /** 网页媒体查看器固定使用黑色画布，系统栏需随页面而非系统主题配色。 */
  private isMediaViewer(): boolean {
    return isSiteUrl(this.currentUrl) &&
      /^\/[a-z0-9_]{1,15}\/status\/\d+\/(mediaviewer|(?:video|photo)\/[1-4])$/.test(this.currentPath);
  }

  private resetHeaderBlur(): void {
    this.lastBlurOffset = 0;
    try {
      this.blurScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false });
    } catch {
      // 首次进入页面时隐藏滚动容器尚未挂载。
    }
  }

  /** 切页和重载先释放旧坐标，未测量的新主页始终保持透明。 */
  private resetProfileLayout(): void {
    this.profileLayout = undefined;
    this.profileBlurProgress = 0;
    this.profileTitleOpacity = 0;
    this.profileHasBanner = true;
    this.profileName = '';
    this.measuredHandle = '';
    this.resetHeaderBlur();
  }

  /** 只接受当前文档、当前视口的资料节点，SPA 切页中的旧节点不能驱动标题。 */
  private receiveProfileLayout(payload: string): void {
    let layout: ProfileLayout;
    try {
      layout = JSON.parse(payload) as ProfileLayout;
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'event=profile_layout_invalid error=%{public}s', String(error));
      return;
    }
    if (!layout || typeof layout.ready !== 'boolean' || !this.avatarAlive || this.appBackground || this.rawWeb || this.viewingHandle === '' ||
      layout.url !== this.currentUrl || layout.url !== this.controller.getUrl() ||
      layout.viewWidth !== this.webWidth) { return; }
    if (!layout.ready) { this.resetProfileLayout(); return; }
    if (typeof layout.hasBanner !== 'boolean' || !(layout.width > 0) || !Number.isFinite(layout.width) || !Number.isFinite(layout.scrollY) ||
      !Number.isFinite(layout.bannerBottom) || !Number.isFinite(layout.identityBottom) ||
      layout.bannerBottom <= 0 || layout.identityBottom <= 0 || typeof layout.name !== 'string' ||
      typeof layout.handle !== 'string' || layout.handle.toLowerCase() !== this.viewingHandle.toLowerCase()) { return; }
    this.profileLayout = layout;
    this.profileHasBanner = layout.hasBanner;
    this.profileName = layout.name;
    this.measuredHandle = layout.handle;
    this.lastScrollY = Math.max(0, layout.scrollY * this.webWidth / layout.width);
    this.syncHeaderBlur(this.lastScrollY);
  }

  private profileBannerButtons(): boolean {
    return this.viewingHandle !== '' && this.profileHasBanner && this.profileBlurProgress < 0.5;
  }

  /** 把网页滚动位置镜像给 HDS，顶栏在顶部保持全透明，随滚动逐渐模糊。 */
  private syncHeaderBlur(yOffset: number): void {
    let position: number = yOffset;
    if (this.viewingHandle !== '') {
      const layout = this.profileLayout;
      if (layout === undefined) { return; }
      const scale: number = this.webWidth / layout.width;
      const coveredBottom: number = this.topInset + HEADER_HEIGHT;
      this.profileBlurProgress = Math.min(1, Math.max(0,
        (yOffset + coveredBottom - layout.bannerBottom * scale) / 48));
      const titleProgress: number = Math.min(1, Math.max(0,
        (yOffset + coveredBottom - layout.identityBottom * scale) / 32));
      this.profileTitleOpacity = titleProgress * titleProgress * (3 - 2 * titleProgress);
      position = this.profileBlurProgress * HEADER_BLUR_DISTANCE;
    }
    const offset: number = Math.min(HEADER_BLUR_DISTANCE, Math.max(0, position));
    if (Math.abs(offset - this.lastBlurOffset) < 0.5) { return; }
    this.lastBlurOffset = offset;
    try {
      this.blurScroller.scrollTo({ xOffset: 0, yOffset: offset, animation: false });
    } catch {
      // 隐藏滚动容器尚未挂载时忽略，下一次滚动会重试。
    }
  }

  private resetChromeScroll(): void {
    this.lastScrollY = 0;
    this.scrollDistance = 0;
    this.webTouchActive = false;
    this.webTouchDirection = 0;
    this.webCollapseInertia = false;
    this.lastWebScrollTime = 0;
    this.resetHeaderBlur();
    this.setBarsCollapsed(false);
  }

  /** 展开只接受当前向下拖动，抬手后仅保留向下浏览的惯性收起。 */
  private handleWebTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.scrollDistance = 0;
      this.webTouchActive = event.touches.length === 1;
      this.webTouchDirection = 0;
      this.webCollapseInertia = false;
      this.lastWebScrollTime = 0;
      if (this.webTouchActive) {
        this.lastTouchX = event.touches[0].x;
        this.lastTouchY = event.touches[0].y;
      }
    } else if (event.type === TouchType.Move && this.webTouchActive && event.touches.length === 1) {
      const dx: number = event.touches[0].x - this.lastTouchX;
      const dy: number = event.touches[0].y - this.lastTouchY;
      if (Math.abs(dy) <= Math.abs(dx)) { return; }
      const direction: number = dy > 0 ? 1 : -1;
      if (direction !== this.webTouchDirection) {
        if (Math.abs(dy) < 8) { return; }
        this.scrollDistance = 0;
        this.webTouchDirection = direction;
      }
      this.lastTouchX = event.touches[0].x;
      this.lastTouchY = event.touches[0].y;
    } else if (event.type === TouchType.Up && this.webTouchActive && event.touches.length <= 1) {
      this.webTouchActive = false;
      this.webCollapseInertia = this.webTouchDirection === -1 && this.lastWebScrollTime > 0 &&
        Date.now() - this.lastWebScrollTime <= 200;
      this.webTouchDirection = 0;
      if (!this.webCollapseInertia) { this.scrollDistance = 0; }
    } else if (event.type !== TouchType.Move || event.touches.length !== 1) {
      this.webTouchActive = false;
      this.webTouchDirection = 0;
      this.webCollapseInertia = false;
      this.scrollDistance = 0;
    }
  }

  /** 网页偏移可能自行调整，只有与已确认手势方向一致的 vp 位移参与显隐。 */
  private handleWebScroll(yOffset: number): void {
    const y: number = Math.max(0, yOffset);
    const delta: number = y - this.lastScrollY;
    const now: number = Date.now();
    if (!this.webTouchActive && (delta < 0 || now - this.lastWebScrollTime > 200)) {
      this.webCollapseInertia = false;
      this.scrollDistance = 0;
    }
    this.lastScrollY = y;
    this.lastWebScrollTime = now;
    this.syncHeaderBlur(y);
    if (!this.overlaysWeb() || isPostDetailUrl(this.currentUrl) || !this.autoHideBar || this.isWide || y < 48) {
      this.setBarsCollapsed(false);
      this.scrollDistance = 0;
      this.webCollapseInertia = false;
      return;
    }
    const direction: number = this.webTouchActive ? this.webTouchDirection : (this.webCollapseInertia ? -1 : 0);
    if (direction === 0 || delta * direction >= 0) { return; }
    if ((direction === 1 && !this.barsCollapsed) || (direction === -1 && this.barsCollapsed)) {
      this.scrollDistance = 0;
      return;
    }
    // 小步位移照常累计；抖动由手势方向的确认距离过滤。
    this.scrollDistance += delta;
    if (y > 80 && this.scrollDistance > 44) {
      this.setBarsCollapsed(true);
      this.scrollDistance = 0;
    } else if (this.scrollDistance <= -56) {
      this.setBarsCollapsed(false);
      this.scrollDistance = 0;
    }
  }

  private syncChromeInsets(): void {
    if (this.rawWeb || !isSiteUrl(this.currentUrl) || this.webWidth <= 0) { return; }
    if (this.viewingHandle !== '') { this.syncHeaderBlur(this.lastScrollY); }
    this.controller.runJavaScript(chromeInsetsScript(
      this.overlayTopInset(),
      this.overlaysWeb() ? this.bottomChromeHeight() : 0, this.webWidth
    )).catch((error: Error) => {
      hilog.error(DOMAIN, TAG, 'event=chrome_insets_failed error=%{public}s', error.message);
      this.toast($r('app.string.operation_failed'));
    });
  }

  private overlayTopInset(): number {
    if (!this.overlaysWeb() || this.topChromeHeight() === 0) { return 0; }
    if (this.viewingHandle !== '') { return 0; }
    // 首页滚动内容紧接下划线底缘，保留帖子自身的内边距，不累计标题栏的空白下半区。
    const height: number = this.isHomeRoot()
      ? Math.min(HEADER_HEIGHT, (HEADER_HEIGHT + this.homeTabsHeight) / 2 - HEADER_CONTENT_LIFT)
      : this.topChromeHeight();
    return this.topInset + height;
  }

  private async setAppearance(key: string, value: boolean): Promise<void> {
    try {
      await this.putPreference(key, value);
      if (key === FLOATING_BAR_KEY) { this.floatingBar = value; }
      if (key === AUTO_HIDE_BAR_KEY) { this.autoHideBar = value; }
      if (key === DESKTOP_MODE_KEY) {
        this.desktopMode = value;
        this.controller.setCustomUserAgent(this.rawWeb ? web_webview.WebviewController.getDefaultUserAgent() : this.userAgent());
        this.reloadCurrent();
      }
      this.resetChromeScroll();
      this.syncChromeInsets();
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'event=appearance_save_failed error=%{public}s', JSON.stringify(error));
      this.toast($r('app.string.operation_failed'));
    }
  }

  /** 登录/欢迎页没有原生底栏；胶囊占用同一位置，避开 X 的登录按钮与顶栏。 */
  private settingsPillBottom(): number {
    return this.bottomInset + S16;
  }

  private settingsPillVisible(): boolean {
    if (this.fullScreen || this.imageViewerOpen || this.sheetOpen || this.networkOpen ||
      this.appearanceOpen || this.discovering || this.isMediaViewer()) {
      return false;
    }
    if (this.rawWeb) { return true; }
    // 原生导航页有悬浮底栏，胶囊会与标签栏重叠；这些页面已有头像/错误页入口。
    if (this.showsNativeNavigation()) {
      return false;
    }
    // 首屏加载与错误页没有其他设置入口。
    if (!this.firstLoadDone || this.hasError) {
      return true;
    }
    // 已加载的普通网页（含账号信息页）保留网页自己的入口。
    return isSiteUrl(this.currentUrl) &&
      (this.currentPath === '/' || this.currentPath === '/login' || this.currentPath === '/signup' ||
        this.currentPath === '/i/flow/login' || this.currentPath === '/i/flow/signup');
  }

  private openNetworkSettings(): void {
    if (this.imageViewerOpen || this.sheetOpen || this.fullScreen ||
      this.appearanceOpen || this.discovering) {
      return;
    }
    this.networkOpen = true;
  }

  private onNetworkOpenChanged(): void {
    if (!this.networkOpen) {
      this.flushNetworkReload();
    }
  }

  private onAppearanceOpenChanged(): void {
    if (!this.appearanceOpen) {
      this.flushNetworkReload();
    }
  }

  private modalBlocksNetworkReload(): boolean {
    return this.webModalOpen || this.imageViewerOpen || this.sheetOpen || this.networkOpen ||
      this.appearanceOpen || this.discovering;
  }

  /** DoH changes apply to new resolutions; reload once after the panel closes. */
  private flushNetworkReload(): void {
    if (!this.networkPendingReload || this.appBackground || this.fullScreen ||
      this.modalBlocksNetworkReload()) {
      return;
    }
    if (this.networkReloadTimer !== -1) {
      return;
    }
    this.networkReloadTimer = setTimeout(() => {
      this.networkReloadTimer = -1;
      if (!this.networkPendingReload || this.appBackground || this.fullScreen ||
        this.modalBlocksNetworkReload()) {
        return;
      }
      this.networkPendingReload = false;
      this.networkGeneration = NetworkConfig.getInstance().snapshot().generation;
      this.recoverAfterNetworkChange();
    }, 200);
  }

  /** 登录页/首屏加载同样需要重载，否则新 DoH 只影响后续请求而当前页继续失败。 */
  private recoverAfterNetworkChange(): void {
    hilog.info(DOMAIN, TAG, 'event=network_reload');
    if (!this.firstLoadDone) {
      if (this.firstLoadTimer !== -1) {
        clearTimeout(this.firstLoadTimer);
        this.firstLoadTimer = -1;
      }
      this.armFirstLoadTimeout();
    }
    if (this.currentUrl.length === 0) {
      this.loadWeb(TWITTER_ROUTES[0], false, true);
    } else {
      this.reloadCurrent();
    }
  }

  @Builder
  networkSettingsSheet() {
    NetworkSettingsSheet()
  }

  private applyPageChrome(url: string): void {
    if (this.rawWeb || !/^https:\/\/(www\.)?(x|twitter)\.com(\/|$)/.test(url)) { return; }
    const navigation: boolean = usesNativeNavigation(url);
    try {
      this.controller.runJavaScript(chromeScript(navigation, usesNativeHeader(url), url))
        .then((raw: string) => this.logChromeResult('apply', raw))
        .catch((err: Error) => {
          hilog.warn(DOMAIN, TAG, 'event=chrome_injection_failed source=apply code=%{public}d',
            (err as BusinessError).code);
        });
      this.syncChromeInsets();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'event=chrome_injection_failed source=apply code=%{public}d',
        (err as BusinessError).code);
    }
  }

  private updateChromeFlag(url: string): void {
    if (this.rawWeb) { return; }
    try {
      const navigation: boolean = usesNativeNavigation(url);
      this.controller.runJavaScript(chromeFlagScript(navigation, usesNativeHeader(url), url))
        .then((raw: string) => this.logChromeResult('flag', raw))
        .catch((err: Error) => {
          hilog.warn(DOMAIN, TAG, 'event=chrome_injection_failed source=flag code=%{public}d',
            (err as BusinessError).code);
        });
      this.syncChromeInsets();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'event=chrome_injection_failed source=flag code=%{public}d',
        (err as BusinessError).code);
    }
  }

  private logChromeResult(source: string, raw: string): void {
    const result: string = MainTabs.unquote(raw);
    if (result === '') { return; }
    try {
      const report: ChromeDiagnostics = JSON.parse(result) as ChromeDiagnostics;
      if (typeof report.error === 'string') {
        // 只记录标准错误类型，避免网页异常消息带出账号、地址或正文。
        const kind: string = report.error.split(':')[0];
        hilog.warn(DOMAIN, TAG, 'event=chrome_script_failed source=%{public}s type=%{public}s', source,
          /^(Error|TypeError|ReferenceError|SyntaxError|RangeError|URIError|EvalError)$/.test(kind) ? kind : 'Error');
        return;
      }
      hilog.debug(DOMAIN, TAG, 'event=chrome_applied source=%{public}s result=%{public}s', source,
        JSON.stringify({ navigation: report.navigation, header: report.header, navMatches: report.navMatches,
          pullMatches: report.pullMatches, avatarFound: report.avatarFound }));
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'event=chrome_report_failed source=%{public}s', source);
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
    if (this.rawWeb || this.appBackground || !this.avatarAlive) { return; }
    const owner = this.ownHandle;
    const pageUrl = this.currentUrl;
    try {
      this.controller.runJavaScript(UNREAD_COUNTS_SCRIPT).then((raw: string) => {
        if (this.appBackground || !this.avatarAlive || this.ownHandle !== owner || this.currentUrl !== pageUrl) { return; }
        this.applyBadgeCounts(MainTabs.unquote(raw));
      }, (err: BusinessError) => {
        hilog.debug(DOMAIN, TAG, 'badge read failed: %{public}d %{public}s', err.code, err.message);
        this.retryBadgeRead();
      });
    } catch (err) {
      this.retryBadgeRead();
    }
  }

  /** 账号变化后忽略前一会话仍在途的计数响应。 */
  private clearNetworkBadgeCounts(): void {
    this.controller.runJavaScript('window.__otBadgeEpoch=(window.__otBadgeEpoch||0)+1;window.__otBadgeCounts=null;')
      .catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'event=badge_reset_failed code=%{public}d', err.code);
      });
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
    if (this.appBackground || !this.avatarAlive || this.badgeRetryTimer !== -1 || this.badgeRetries >= BADGE_RETRY_LIMIT) {
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
  private async syncLauncherBadge(): Promise<void> {
    const total: number = this.unreadNotifications + this.unreadMessages;
    const target = this.ownHandle + ':' + total;
    if (target !== this.badgeSyncTarget) { this.badgeSyncTarget = target; this.badgeSyncFailures = 0; }
    if (this.badgeSyncFailures >= BADGE_RETRY_LIMIT) { return; }
    if (this.badgeSyncing || total === this.badgeShown) {
      return;
    }
    if (total > 0 && !this.notificationsAllowed()) {
      // HarmonyOS treats the app-icon badge as a notification surface — its own
      // permission dialog lists "角标 / badge" among the reminder modes — so
      // nothing lands on the icon until the account allows notifications.
      this.askForNotificationsOnce();
      return;
    }
    const owner = this.ownHandle;
    this.badgeSyncing = true;
    hilog.info(DOMAIN, TAG, 'launcher badge -> %{public}d', total);
    try {
      await notificationManager.setBadgeNumber(total);
      if (owner === this.ownHandle) { this.badgeShown = total; }
      this.badgeSyncFailures = 0;
      hilog.info(DOMAIN, TAG, 'event=launcher_badge_applied total=%{public}d', total);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'event=launcher_badge_failed error=%{public}s', JSON.stringify(err));
      this.badgeSyncFailures++;
      if (this.badgeSyncFailures < BADGE_RETRY_LIMIT) { this.retryBadgeRead(); }
    } finally {
      this.badgeSyncing = false;
      if (owner !== this.ownHandle || total !== this.unreadNotifications + this.unreadMessages) { this.syncLauncherBadge(); }
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
    if (this.appBackground || !this.avatarAlive || attempt >= NOTIFICATION_POLL_LIMIT) {
      return;
    }
    this.notificationTimer = setTimeout(() => {
      this.notificationTimer = -1;
      if (this.notificationsAllowed()) {
        this.badgeShown = -1;
        this.syncLauncherBadge();
        return;
      }
      this.retryLauncherBadgeWhenAllowed(attempt + 1);
    }, NOTIFICATION_POLL_MS);
  }

  private armBadgeRefresh(): void {
    if (this.appBackground) { return; }
    if (this.badgeTimer !== -1) {
      clearInterval(this.badgeTimer);
    }
    this.badgeTimer = setInterval(() => {
      this.badgeRetries = 0;
      this.refreshBadges();
    }, BADGE_REFRESH_MS);
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
    const pageUrl = this.currentUrl;
    try {
      this.controller.runJavaScript('Boolean(document.querySelector(\'input[autocomplete="username"],input[autocomplete="current-password"],input[autocomplete="one-time-code"]\'))')
        .then((raw: string) => {
          if (!this.avatarAlive || this.currentUrl !== pageUrl || this.appBackground) { return; }
          this.authenticationPage = raw === 'true';
          if (this.authenticationPage) {
            this.clearNetworkBadgeCounts();
            this.ownHandle = '';
            this.resetAvatar();
            this.unreadNotifications = 0;
            this.unreadMessages = 0;
          } else { this.discoverOwnProfile(); }
        }).catch((err: Error) => {
          hilog.warn(DOMAIN, TAG, 'event=auth_page_read_failed error=%{public}s', err.message);
        });
      this.controller.runJavaScript('document.title').then((raw: string) => {
        if (!this.avatarAlive || this.currentUrl !== pageUrl || this.appBackground) { return; }
        const title: string = MainTabs.unquote(raw);
        this.pageTitle = MainTabs.stripSiteSuffix(title);
      }).catch((err: BusinessError) => { hilog.warn(DOMAIN, TAG, 'event=page_title_failed code=%{public}d', err.code); });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'event=page_state_failed code=%{public}d', (err as BusinessError).code);
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
    const pageUrl = this.currentUrl;
    try {
      this.controller.runJavaScript(HOME_TAB_SCRIPT).then((raw: string) => {
        if (!this.avatarAlive || this.currentUrl !== pageUrl || this.appBackground) { return; }
        const index: number = Number.parseInt(MainTabs.unquote(raw), 10);
        if (!Number.isNaN(index) && index >= 0) {
          this.homeTabIndex = index;
        }
      }).catch((err: BusinessError) => { hilog.warn(DOMAIN, TAG, 'event=home_tab_read_failed code=%{public}d', err.code); });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'event=home_tab_read_failed code=%{public}d', (err as BusinessError).code);
    }
  }

  // 首页即可读取账号控件；资料页仅使用已确认本人的头像链接作为补充。
  private readAvatar(retryFailed: boolean = false): void {
    if (!this.avatarAlive || this.rawWeb || this.authenticationPage) { return; }
    const handle: string = this.ownHandle;
    const pageUrl: string = this.currentUrl;
    const request: number = ++this.avatarReadRequest;
    try {
      this.controller.runJavaScript(accountAvatarScript(handle)).then((raw: string) => {
        if (!this.avatarAlive || request !== this.avatarReadRequest || this.authenticationPage ||
          this.rawWeb || this.currentUrl !== pageUrl || this.ownHandle.toLowerCase() !== handle.toLowerCase()) { return; }
        const url: string = MainTabs.unquote(raw);
        if (/^https:\/\/(pbs|abs)\.twimg\.com\//i.test(url)) {
          const failed: boolean = this.avatarFailedUrl === url;
          if (url !== this.avatarUrl || (failed && retryFailed)) {
            hilog.info(DOMAIN, TAG, 'event=avatar_url_matched retry=%{public}s', String(failed));
            this.loadAvatar(url, failed);
          } else if (failed) {
            this.retryAvatarRead();
          }
        } else if (this.avatarPath === '') {
          hilog.info(DOMAIN, TAG, 'event=avatar_read_empty tab=%{public}d hasHandle=%{public}s attempt=%{public}d',
            this.currentIndex, String(handle !== ''), this.avatarRetries);
          if (this.avatarRetries === 0) {
            this.controller.runJavaScript(accountAvatarDiagScript()).then((diagnostics: string) => {
              hilog.info(DOMAIN, TAG, 'event=avatar_dom_diagnostics data=%{public}s', MainTabs.unquote(diagnostics));
            }).catch((err: BusinessError) => {
              hilog.warn(DOMAIN, TAG, 'event=avatar_diagnostics_failed code=%{public}d', err.code);
            });
          }
          this.retryAvatarRead();
        }
      }).catch((err: Error) => {
        hilog.debug(DOMAIN, TAG, 'event=avatar_read_failed code=%{public}d', (err as BusinessError).code);
        this.retryAvatarRead();
      });
    } catch (err) {
      hilog.debug(DOMAIN, TAG, 'event=avatar_read_failed code=%{public}d', (err as BusinessError).code);
      this.retryAvatarRead();
    }
  }

  /** 水合和下载失败共用有限重试，避免一次失败长期停在占位头像。 */
  private retryAvatarRead(): void {
    if (!this.avatarAlive || this.appBackground || this.rawWeb || this.authenticationPage || this.avatarPath !== '' ||
      this.avatarRetryTimer !== -1 || this.avatarRetries >= AVATAR_RETRY_LIMIT) { return; }
    this.avatarRetries++;
    this.avatarRetryTimer = setTimeout(() => {
      this.avatarRetryTimer = -1;
      this.readAvatar(true);
    }, AVATAR_RETRY_MS);
  }

  private clearAvatarRetry(): void {
    if (this.avatarRetryTimer !== -1) { clearTimeout(this.avatarRetryTimer); }
    this.avatarRetryTimer = -1;
    this.avatarRetries = 0;
  }

  private schedulePageStateRead(): void {
    if (this.pageStateTimer !== -1) { clearTimeout(this.pageStateTimer); }
    if (this.rawWeb || this.appBackground || !this.avatarAlive) { return; }
    this.pageStateTimer = setTimeout(() => {
      this.pageStateTimer = -1;
      if (this.rawWeb || this.appBackground || !this.avatarAlive) { return; }
      this.readPageState();
      this.refreshBadges();
    }, PAGE_STATE_DELAY_MS);
  }


  private goBack(): void {
    this.onBackPress();
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

  private openFileSelector(event: OnShowFileSelectorEvent): boolean {
    const mode = event.fileSelector.getMode();
    if (mode !== FileSelectorMode.FileOpenMode && mode !== FileSelectorMode.FileOpenMultipleMode) { return false; }
    const types = mediaAcceptTypes(event.fileSelector.getAcceptType());
    if (types.length === 0 || event.fileSelector.isCapture()) { return false; }
    chooseMedia(event, types, () => { this.toast($r('app.string.file_select_failed')); })
      .catch((err: Error) => {
        hilog.error(DOMAIN, TAG, 'event=file_select_callback_failed error=%{public}s', err.message);
        this.toast($r('app.string.file_select_failed'));
      });
    return true;
  }

  private async openExternal(target: string): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await ctx.startAbility({ action: 'ohos.want.action.viewData', uri: target });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'event=external_link_failed error=%{public}s', JSON.stringify(err));
      this.toast($r('app.string.operation_failed'));
    }
  }

  private interceptExternal(event: OnLoadInterceptEvent): boolean {
    const target = event.data.getRequestUrl();
    if (!event.data.isMainFrame() || isSiteUrl(target) || isAuthUrl(target)) { return false; }
    if (/^https?:\/\//i.test(target)) { this.openExternal(target); return true; }
    return false;
  }

  private reportDownload(result: string): void {
    if (result === 'cancelled') { return; }
    this.toast(result === 'saved' ? $r('app.string.file_saved') :
      result === 'cleanup_failed' ? $r('app.string.file_cleanup_failed') : $r('app.string.file_save_failed'));
  }

  private async enterFullScreen(handler: FullScreenExitHandler): Promise<void> {
    this.fullScreenHandler = handler;
    this.fullScreen = true;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const main = await window.getLastWindow(ctx);
      if (!this.fullScreen) { return; }
      this.fullScreenWindow = main;
      this.previousLayoutFullScreen = main.getWindowProperties().isLayoutFullScreen;
      await main.setWindowLayoutFullScreen(true);
      if (!this.fullScreen) { return; }
      await main.setWindowSystemBarEnable([]);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'event=fullscreen_enter_failed error=%{public}s', JSON.stringify(err));
      handler.exitFullScreen();
      this.toast($r('app.string.operation_failed'));
    }
  }

  private async exitFullScreen(): Promise<void> {
    this.fullScreen = false;
    this.fullScreenHandler = undefined;
    try {
      if (this.fullScreenWindow !== undefined) {
        await this.fullScreenWindow.setWindowLayoutFullScreen(this.previousLayoutFullScreen);
        await this.fullScreenWindow.setWindowSystemBarEnable(['status', 'navigation']);
        this.fullScreenWindow = undefined;
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'event=fullscreen_exit_failed error=%{public}s', JSON.stringify(err));
      this.toast($r('app.string.operation_failed'));
    }
    this.flushNetworkReload();
  }

  /** 账号必须由当前网页确认，缓存不能决定草稿归属。 */
  private async confirmCurrentAccount(): Promise<string> {
    const pageUrl = this.currentUrl;
    const generation = this.profileNavigation;
    const direct = MainTabs.unquote(await this.controller.runJavaScript(OWN_HANDLE_SCRIPT));
    if (pageUrl !== this.currentUrl || generation !== this.profileNavigation) { return ''; }
    if (/^[A-Za-z0-9_]{1,15}$/.test(direct)) { return direct; }
    const result = MainTabs.unquote(await this.controller.runJavaScript(profileBootstrapScript(false)));
    if (result !== 'armed') { return ''; }
    const deadline = Date.now() + PROFILE_TIMEOUT_MS;
    while (Date.now() < deadline && this.avatarAlive && !this.appBackground &&
      pageUrl === this.currentUrl && generation === this.profileNavigation) {
      const handle = MainTabs.unquote(await this.controller.runJavaScript('window.__otBoot||""'));
      if (pageUrl !== this.currentUrl || generation !== this.profileNavigation) { return ''; }
      if (/^[A-Za-z0-9_]{1,15}$/.test(handle)) { return handle; }
      await new Promise<void>((resolve) => { setTimeout(resolve, 100); });
    }
    return '';
  }

  /** 当前账号确认后才读取其草稿，旧草稿需要用户确认归属。 */
  private async openCompose(sharedText: string = ''): Promise<void> {
    if (this.openingCompose || this.sheetOpen) { return; }
    this.openingCompose = true;
    this.composePreparing = true;
    this.composeOwner = '';
    this.draft = sharedText;
    this.postUncertain = false;
    this.composeHandoff = false;
    this.composeMessage = '';
    this.composeController = new web_webview.WebviewController();
    this.composeUrl = TWITTER_COMPOSE;
    this.composeLoading = true;
    this.webComposer = false;
    this.posting = false;
    this.clearComposeSync();
    this.sheetOpen = true;
    try {
      const handle: string = await this.confirmCurrentAccount();
      if (!this.sheetOpen) { return; }
      if (!/^[A-Za-z0-9_]{1,15}$/.test(handle)) {
        this.composeMessage = $r('app.string.account_unconfirmed');
        return;
      }
      const owner: string = handle.toLowerCase();
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const prefs = await preferences.getPreferences(ctx, PREFS_NAME);
      const draft = await prefs.get(COMPOSE_DRAFT_KEY + ':' + owner, '') as string;
      const uncertain = await prefs.get('post_pending:' + owner, false) as boolean;
      const handoff = await prefs.get('compose_handoff:' + owner, '') as string;
      if (!this.sheetOpen) { return; }
      this.composeOwner = owner;
      this.acceptHandle(handle, false);
      this.draft = draft;
      this.composeHandoff = handoff !== '';
      this.postUncertain = uncertain || this.composeHandoff;
      this.composeMessage = this.composeHandoff ? $r('app.string.compose_handoff') :
        this.postUncertain ? $r('app.string.post_unknown') : '';
      if (sharedText !== '') {
        if (this.postUncertain) {
          this.toast($r('app.string.incoming_busy'));
        } else if (draft === '') {
          this.draft = sharedText;
          await this.persistDraft();
        } else {
          this.getUIContext().showAlertDialog({
            title: $r('app.string.incoming_draft_title'),
            message: $r('app.string.incoming_draft_message'),
            primaryButton: { value: $r('app.string.compose_cancel'), action: () => {} },
            secondaryButton: { value: $r('app.string.incoming_append'), action: () => {
              this.draft = this.draft + '\n' + sharedText;
              this.saveDraft();
            } }
          });
        }
      } else if (this.legacyDraft !== '' && this.draft === '') {
        this.getUIContext().showAlertDialog({
          title: $r('app.string.legacy_draft_title'),
          message: $r('app.string.legacy_draft_message'),
          primaryButton: { value: $r('app.string.compose_cancel'), action: () => {} },
          secondaryButton: { value: $r('app.string.use_draft'), action: () => { this.adoptLegacyDraft(); } }
        });
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'event=compose_open_failed error=%{public}s', JSON.stringify(err));
      this.composeMessage = $r('app.string.draft_read_failed');
    } finally {
      this.composePreparing = false;
      this.openingCompose = false;
      this.scheduleComposeSync();
    }
  }

  private async adoptLegacyDraft(): Promise<void> {
    this.draft = this.legacyDraft;
    try {
      await this.persistDraft();
      await this.putPreference(COMPOSE_DRAFT_KEY, '');
      this.legacyDraft = '';
      this.scheduleComposeSync();
    } catch (err) {
      this.toast($r('app.string.draft_save_failed'));
    }
  }

  private persistDraft(): Promise<void> {
    if (this.composeOwner === '') { return Promise.resolve(); }
    const key = COMPOSE_DRAFT_KEY + ':' + this.composeOwner;
    const value = this.draft;
    // 顺序写入防止较早的防抖任务覆盖后续草稿；每次失败仍由调用方显示。
    const save = (): Promise<void> => this.putPreference(key, value);
    this.draftWrite = this.draftWrite.then(save, save);
    return this.draftWrite;
  }

  private closeCompose(): void {
    if (this.posting) { return; }
    if (this.webComposer) {
      this.getUIContext().showAlertDialog({
        title: $r('app.string.compose_cancel'),
        message: $r('app.string.close_web_draft'),
        primaryButton: { value: $r('app.string.keep_editing'), action: () => {} },
        secondaryButton: { value: $r('app.string.close_editor'), action: () => { this.saveAndClose(); } }
      });
      return;
    }
    this.saveAndClose();
  }

  private async saveAndClose(): Promise<void> {
    try {
      await this.persistDraft();
      this.stopPostCheck();
      this.clearComposeSync();
      this.sheetOpen = false;
    } catch (err) {
      this.toast($r('app.string.draft_save_failed'));
    }
  }

  private stopPostCheck(): void {
    if (this.postTimer !== -1) { clearTimeout(this.postTimer); this.postTimer = -1; }
  }

  // Drafts are saved as you type, so closing the sheet — or the app — cannot
  // lose what was written.
  private scheduleDraftSave(): void {
    this.scheduleComposeSync();
    if (this.draftSaveTimer !== -1) {
      clearTimeout(this.draftSaveTimer);
    }
    this.draftSaveTimer = setTimeout(() => {
      this.draftSaveTimer = -1;
      this.saveDraft();
    }, DRAFT_SAVE_DEBOUNCE_MS);
  }

  private clearComposeSync(): void {
    this.composeRevision++;
    this.composeReady = false;
    if (this.composeSyncTimer !== -1) { clearTimeout(this.composeSyncTimer); this.composeSyncTimer = -1; }
  }

  /** 编辑停止后交给网页校验，过期异步结果不能启用下一份草稿的发布按钮。 */
  private scheduleComposeSync(): void {
    this.clearComposeSync();
    if (this.appBackground || !this.sheetOpen || this.webComposer || this.composeLoading || this.composePreparing ||
      this.posting || this.postUncertain || this.draft.trim() === '' || this.composeOwner === '') { return; }
    const revision = this.composeRevision;
    const text = this.draft;
    this.composeSyncTimer = setTimeout(async () => {
      this.composeSyncTimer = -1;
      try {
        const filled = MainTabs.unquote(await this.composeController.runJavaScript(fillComposerScript(text)));
        if (revision !== this.composeRevision || !this.sheetOpen || this.webComposer || this.posting) { return; }
        if (filled !== 'ok') { this.composeMessage = $r('app.string.compose_fill_failed'); return; }
        const ready = await this.composeController.runJavaScript(COMPOSER_READY_SCRIPT);
        if (revision === this.composeRevision) {
          this.composeReady = ready === 'true';
          this.composeMessage = this.composeReady ? '' : $r('app.string.compose_submit_unavailable');
        }
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'event=compose_validation_failed code=%{public}d', (err as BusinessError).code);
        if (revision === this.composeRevision) { this.composeMessage = $r('app.string.compose_fill_failed'); }
      }
    }, DRAFT_SAVE_DEBOUNCE_MS);
  }

  private saveDraft(): void {
    this.scheduleComposeSync();
    this.persistDraft().catch((err: Error) => {
      hilog.error(DOMAIN, TAG, 'event=draft_save_failed error=%{public}s', err.message);
      this.toast($r('app.string.draft_save_failed'));
    });
  }

  private saveNotificationAsked(): void {
    this.putPreference(NOTIFICATION_ASKED_KEY, true).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'event=preference_save_failed error=%{public}s', err.message);
    });
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
      this.closeCompose();
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
      if (ctx === undefined) { throw new Error('Context unavailable'); }
      const prefs: preferences.Preferences = await preferences.getPreferences(ctx, PREFS_NAME);
      await prefs.put(key, value);
      await prefs.flush();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'event=preference_write_failed error=%{public}s', JSON.stringify(err));
      throw err as Error;
    }
  }

  /** 先保存提交意图；未知结果不得自动重发或清空草稿。 */
  private async postFromSheet(): Promise<void> {
    if (!this.composeReady || this.draft.trim() === '' || this.posting || this.postUncertain || this.webComposer ||
      this.composePreparing || this.composeLoading || this.composeOwner === '') { return; }
    this.posting = true;
    this.clearComposeSync();
    this.composeMessage = '';
    if (this.draftSaveTimer !== -1) { clearTimeout(this.draftSaveTimer); this.draftSaveTimer = -1; }
    try {
      await this.persistDraft();
      const account = await this.confirmCurrentAccount();
      if (account.toLowerCase() !== this.composeOwner) {
        this.composeMessage = $r('app.string.account_changed');
        this.posting = false;
        return;
      }
      const filled = MainTabs.unquote(await this.composeController.runJavaScript(fillComposerScript(this.draft)));
      if (filled !== 'ok') {
        this.composeMessage = $r('app.string.compose_fill_failed');
        this.posting = false;
        return;
      }
      await this.putPreference('post_pending:' + this.composeOwner, true);
      this.postUncertain = true;
      const result = MainTabs.unquote(await this.composeController.runJavaScript(CLICK_POST_BUTTON_SCRIPT));
      if (result === 'missing' || result === 'disabled') {
        await this.putPreference('post_pending:' + this.composeOwner, false);
        this.postUncertain = false;
        this.posting = false;
        this.composeMessage = $r('app.string.compose_submit_unavailable');
        return;
      }
      if (result !== 'submitted') { this.markPostUnknown(); return; }
      this.postChecks = 0;
      this.checkPostResult();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'event=post_failed error=%{public}s', JSON.stringify(err));
      this.posting = false;
      this.composeMessage = this.postUncertain ? $r('app.string.post_unknown') : $r('app.string.operation_failed');
    } finally {
      if (!this.posting && !this.postUncertain) { this.scheduleComposeSync(); }
    }
  }

  private async checkPostResult(): Promise<void> {
    if (this.appBackground || !this.avatarAlive) { return; }
    try {
      const result = MainTabs.unquote(await this.composeController.runJavaScript(POST_RESULT_SCRIPT));
      if (result === 'confirmed') {
        // 先落盘清除草稿，再解除待确认标记，避免进程退出后重复发送。
        await this.draftWrite;
        await this.putPreference(COMPOSE_DRAFT_KEY + ':' + this.composeOwner, '');
        await this.putPreference('post_pending:' + this.composeOwner, false);
        if (this.draftSaveTimer !== -1) { clearTimeout(this.draftSaveTimer); this.draftSaveTimer = -1; }
        this.draft = '';
        this.postUncertain = false;
        this.posting = false;
        this.sheetOpen = false;
        this.toast($r('app.string.compose_post_sent'));
        return;
      }
      if (result === 'unknown' || ++this.postChecks >= 16) { this.markPostUnknown(); return; }
      if (!this.appBackground && this.avatarAlive) { this.postTimer = setTimeout(() => { this.checkPostResult(); }, 1000); }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'event=post_result_unknown error=%{public}s', JSON.stringify(err));
      this.markPostUnknown();
    }
  }

  private markPostUnknown(): void {
    this.stopPostCheck();
    this.posting = false;
    this.postUncertain = true;
    this.composeMessage = $r('app.string.post_unknown');
  }

  private async resolveUnknownPost(): Promise<void> {
    if (this.composeHandoff) {
      this.getUIContext().showAlertDialog({
        title: $r('app.string.compose_handoff_title'), message: $r('app.string.compose_handoff_message'),
        buttons: [
          { value: $r('app.string.compose_cancel'), action: () => {} },
          { value: $r('app.string.post_checked'), action: () => { this.clearPendingPost(); } },
          { value: $r('app.string.compose_handoff_clear'), action: () => { this.clearHandoffDraft(); } }
        ]
      });
      return;
    }
    this.getUIContext().showAlertDialog({
      title: $r('app.string.post_unknown_title'),
      message: $r('app.string.post_check_message'),
      primaryButton: { value: $r('app.string.compose_cancel'), action: () => {} },
      secondaryButton: { value: $r('app.string.post_checked'), action: () => { this.clearPendingPost(); } }
    });
  }

  private async clearPendingPost(): Promise<void> {
    try {
      await this.putPreference('post_pending:' + this.composeOwner, false);
      await this.putPreference('compose_handoff:' + this.composeOwner, '');
      this.composeHandoff = false;
      this.postUncertain = false;
      this.composeMessage = '';
      this.composeController.loadUrl(TWITTER_COMPOSE);
    } catch (err) { this.toast($r('app.string.operation_failed')); }
  }

  /** 只有用户确认发布或放弃后删除移交快照，先删正文再解除发布限制。 */
  private async clearHandoffDraft(): Promise<void> {
    try {
      await this.draftWrite;
      await this.putPreference(COMPOSE_DRAFT_KEY + ':' + this.composeOwner, '');
      await this.putPreference('post_pending:' + this.composeOwner, false);
      await this.putPreference('compose_handoff:' + this.composeOwner, '');
      this.draft = '';
      this.composeHandoff = false;
      this.postUncertain = false;
      this.composeMessage = '';
      this.composeController.loadUrl(TWITTER_COMPOSE);
    } catch (error) { this.toast($r('app.string.draft_save_failed')); }
  }

  private async copyComposeDraft(): Promise<void> {
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.draft));
      this.toast($r('app.string.media_copied'));
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'event=draft_copy_failed error=%{public}s', JSON.stringify(error));
      this.toast($r('app.string.operation_failed'));
    }
  }

  private async openWebComposer(): Promise<void> {
    if (this.posting || this.postUncertain) { return; }
    this.posting = true;
    this.clearComposeSync();
    if (this.draftSaveTimer !== -1) { clearTimeout(this.draftSaveTimer); this.draftSaveTimer = -1; }
    try {
      await this.persistDraft();
      if (this.draft !== '' && this.composeOwner !== '') {
        // 账号键关联正文，移交标识区分同一账号后续新建的草稿；恢复时必须由用户确认。
        await this.putPreference('compose_handoff:' + this.composeOwner, Date.now().toString() + '-' + this.composeRevision);
        this.composeHandoff = true;
        this.postUncertain = true;
        const account = await this.confirmCurrentAccount();
        if (account.toLowerCase() !== this.composeOwner) { throw new Error('Compose account unconfirmed'); }
        const result = MainTabs.unquote(await this.composeController.runJavaScript(fillComposerScript(this.draft)));
        if (result !== 'ok') { throw new Error('Compose text transfer failed'); }
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'event=compose_handoff_failed error=%{public}s', JSON.stringify(err));
      this.toast($r('app.string.compose_manual_transfer'));
    } finally {
      // 自动填充失败仍允许用户进入真实网页；恢复副本不因显示网页而删除。
      this.webComposer = true;
      this.posting = false;
    }
  }

  @Builder
  navTitleBar() {
    if (this.isHomeRoot()) {
      this.homeTitleBar()
    } else {
      NativeTopBar({ title: this.headerTitle(), subtitle: this.subtitleMain(), showBack: this.showBack(),
        titleOpacity: this.viewingHandle !== '' ? this.profileTitleOpacity : 1,
        bannerButtons: this.profileBannerButtons(),
        onBack: () => {
          if (!this.canGoBack) { this.loadWeb(TWITTER_ROUTES[0]); } else { this.goBack(); }
        }, action: () => { this.headerAction(); } })
    }
  }

  // The timeline switcher is centred on the screen so the camera sits between
  // the two labels, rather than centred in the space left of the avatar. The
  // avatar is anchored to the switcher's bottom edge, so the picture follows
  // the underline at any font scale instead of drifting against it.
  @Builder
  homeTitleBar() {
    RelativeContainer() {
      this.homeTimelineTabs()

      Row() {
        this.accountAvatar()
      }
      .width(TOUCH_TARGET)
      .height(32)
      .margin({ left: S12 })
      .alignRules({
        left: { anchor: '__container__', align: HorizontalAlign.Start },
        bottom: { anchor: 'home_tabs', align: VerticalAlign.Bottom }
      })
    }
    .width('100%')
    .height(HEADER_HEIGHT)
    .translate({ y: -HEADER_CONTENT_LIFT })
    .hitTestBehavior(HitTestMode.Transparent)
  }

  // Back only exists where there is history to walk and the page is not one of
  // the five tab roots.
  private showBack(): boolean {
    return isPostDetailUrl(this.currentUrl) || isSecondaryUrl(this.currentUrl) || (this.canGoBack && !this.isTabRoot());
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

  @Builder
  accountPicture($$: AccountPictureState) {
    Stack() {
      SymbolGlyph($r('sys.symbol.person_crop_circle_fill'))
        .fontSize(32)
        .fontColor([$r('sys.color.ohos_id_color_text_secondary')])
      if ($$.path !== '') {
        Image($$.path)
          .width(32).height(32).borderRadius(16).objectFit(ImageFit.Cover)
          .onComplete(() => {
            if ($$.path === this.avatarPath) { this.clearAvatarRetry(); }
          })
          .onError(() => this.avatarImageFailed($$.path))
      }
    }
    .width(32).height(32)
  }

  // 首页与回复栏共用头像占位，网络图片未就绪或失败时圆框仍可见。
  @Builder
  accountAvatar() {
    Row() {
      this.accountPicture({ path: this.avatarPath })
    }
    .width(TOUCH_TARGET)
    .height(32)
    .justifyContent(FlexAlign.Center)
    // The picture is 32vp tall; the touch target stays 48vp.
    .responseRegion({ x: 0, y: -S8, width: '100%', height: TOUCH_TARGET })
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
      MenuItem({ content: $r('app.string.menu_switch_account') })
        .onClick(() => { this.openAccountSwitcher(); })
      MenuItem({ content: $r('app.string.menu_share_page') })
        .onClick(() => { this.shareCurrentPage(); })
      MenuItem({ content: $r('app.string.appearance_title'),
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.gearshape')) })
        .onClick(() => { this.appearanceOpen = true; })
        MenuItem({ content: $r('app.string.network_title'),
          symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.lock_shield')) })
          .onClick(() => { this.openNetworkSettings(); })
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
      if (this.ownHandle !== '') {
        MenuItem({
          content: $r('app.string.menu_lists'),
          symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.list_bullet_square_fill'))
        })
          .onClick(() => {
            this.loadWeb(listsUrl(this.ownHandle));
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
    Row({ space: S8 }) {
      this.homeTimelineTab($r('app.string.home_for_you'), 0)
      this.homeTimelineTab($r('app.string.home_following'), 1)
    }
    .id('home_tabs')
    .onAreaChange((_old: Area, area: Area) => {
      const height: number = Number(area.height);
      if (height > 0 && height !== this.homeTabsHeight) {
        this.homeTabsHeight = height;
        this.syncChromeInsets();
      }
    })
    .justifyContent(FlexAlign.Center)
    // RelativeContainer names the horizontal-centre rule "middle" and the
    // vertical-centre rule "center".
    .alignRules({
      middle: { anchor: '__container__', align: HorizontalAlign.Center },
      center: { anchor: '__container__', align: VerticalAlign.Center }
    })
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
        .animation({ duration: 240, curve: Curve.FastOutSlowIn })
    }
    .padding({ left: S12, right: S12 })
    .hoverEffect(HoverEffect.Highlight)
    .accessibilityText(label)
    .accessibilityLevel('yes')
    .onClick(() => {
      this.selectHomeTab(index);
    })
  }

  private headerTitle(): string {
    if (isPostDetailUrl(this.currentUrl)) { return this.localized($r('app.string.post')); }
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
        .fontColor([this.profileBannerButtons() ? Color.White : $r('sys.color.ohos_id_color_text_primary')])
    }
    .width(TOUCH_TARGET)
    .height(TOUCH_TARGET)
    .backgroundColor(this.profileBannerButtons() ? '#59000000' : Color.Transparent)
    .accessibilityText(label)
    .accessibilityLevel('yes')
    .onClick(action)
  }

  @Builder
  nativeTabs() {
    NativeBottomBar({ currentIndex: this.currentIndex, notifications: this.unreadNotifications,
      messages: this.unreadMessages, wide: this.isWide,
      labels: [this.tabLabel(0), this.tabLabel(1), this.tabLabel(2), this.tabLabel(3), this.tabLabel(4)],
      onSelect: (index: number) => { this.resetChromeScroll(); this.goRoute(index); }
    })
  }

  @Builder
  navBar() {
    Column() {
      Row() { this.nativeTabs() }
      .width('100%')
      .height(this.isWide ? '100%' : (this.floatingBar ? FLOATING_BAR_HEIGHT : BAR_HEIGHT))
      .padding({ left: this.isWide ? 0 : 6, right: this.isWide ? 0 : 6 })
    }
    .width(this.isWide ? RAIL_WIDTH : '100%')
    .constraintSize({ maxWidth: this.isWide ? RAIL_WIDTH : (this.floatingBar ? 380 : undefined) })
    .height(this.isWide ? '100%' : (this.floatingBar ? FLOATING_BAR_HEIGHT : BAR_HEIGHT))
    .justifyContent(this.isWide ? FlexAlign.Center : FlexAlign.Start)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
    .borderRadius(!this.isWide && this.floatingBar ? 29 : 0)
    .border({ width: 0.5, color: $r('sys.color.ohos_id_color_list_separator') })
    .clip(true)
    .shadow({ radius: !this.isWide && this.floatingBar ? 16 : 0, color: '#24000000', offsetY: 4 })
  }

  @Builder
  bottomNavigation() {
    if (!this.webModalOpen) {
      if (isPostDetailUrl(this.currentUrl)) {
        this.replyBar()
      } else {
        Row() {
          this.nativeTabs()
        }
          .width('100%')
          .height('100%')
          .padding({ left: 4, right: 4 })
      }
    }
  }

  /** 面板立即显示，网页回复上下文在面板内加载，不再等待详情页恢复原帖。 */
  private replyToPost(): void {
    if (this.openingCompose || this.sheetOpen) { return; }
    const postId: string = this.currentPath.substring(this.currentPath.lastIndexOf('/') + 1);
    this.composeOwner = '';
    this.composeController = new web_webview.WebviewController();
    this.composeUrl = TWITTER_BASE + '/intent/tweet?in_reply_to=' + postId;
    this.composeLoading = true;
    this.composePreparing = false;
    this.composeMessage = '';
    this.webComposer = true;
    this.posting = false;
    this.sheetOpen = true;
  }

  @Builder
  replyBar() {
    Row({ space: S12 }) {
      this.accountPicture({ path: this.avatarPath })
      Text($r('app.string.reply_prompt'))
        .fontSize(16).fontFamily(FONT_FAMILY).layoutWeight(1)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
      SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(22)
        .fontColor([$r('sys.color.ohos_id_color_emphasize')])
    }
    .id('post-reply').width('100%').height('100%')
    .padding({ left: S12, right: S12 })
    .accessibilityText($r('app.string.reply_prompt')).accessibilityLevel('yes')
    .onClick(() => { this.replyToPost(); })
  }

  @Builder
  appearanceSheet() {
    Column({ space: S16 }) {
      Text($r('app.string.appearance_title'))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
      Row() {
        Text($r('app.string.appearance_floating')).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.floatingBar })
          .onChange((value: boolean) => { this.setAppearance(FLOATING_BAR_KEY, value); })
      }.width('100%')
      Row() {
        Text($r('app.string.appearance_auto_hide')).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.autoHideBar })
          .onChange((value: boolean) => { this.setAppearance(AUTO_HIDE_BAR_KEY, value); })
      }.width('100%')
      Row() {
        Text($r('app.string.desktop_site')).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.desktopMode || deviceInfo.deviceType === '2in1' })
          .enabled(deviceInfo.deviceType !== '2in1')
          .onChange((value: boolean) => { this.setAppearance(DESKTOP_MODE_KEY, value); })
      }.width('100%')
      Button($r('app.string.menu_share_page')).onClick(() => { this.shareCurrentPage(); })
      Button(this.rawWeb ? $r('app.string.show_native_shell') : $r('app.string.show_original_page'))
        .onClick(() => {
          this.rawWeb = !this.rawWeb;
          this.appearanceOpen = false;
          this.controller.setCustomUserAgent(this.rawWeb ? web_webview.WebviewController.getDefaultUserAgent() : this.userAgent());
          this.reloadCurrent();
        })
    }
    .width('100%')
    .padding({ left: S16, right: S16, top: S16, bottom: 32 })
  }

  @Builder
  composeFab() {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph($r('sys.symbol.square_and_pencil'))
        .fontSize(22)
        .fontColor([$r('sys.color.ohos_id_color_text_secondary')])
    }
    .width(52)
    .height(52)
    .backgroundColor(Color.Transparent)
    // 官方建议悬浮按钮使用超薄/薄材质；这里使用组件级 THIN。
    .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
    .margin({ right: S16, bottom: S16 + (this.overlaysWeb() ? this.bottomChromeHeight() : 0) })
    .scale({ x: this.barsCollapsed ? 0.01 : 1, y: this.barsCollapsed ? 0.01 : 1 })
    .opacity(this.barsCollapsed ? 0 : 1)
    .animation({ duration: 240, curve: Curve.FastOutSlowIn })
    .hitTestBehavior(this.barsCollapsed ? HitTestMode.None : HitTestMode.Default)
    .accessibilityText($r('app.string.compose_title'))
    .accessibilityLevel('yes')
    .onClick(() => { this.openCompose(); })
  }

  @Builder
  settingsMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.network_title'),
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.lock_shield')) })
        .onClick(() => { this.openNetworkSettings(); })
      MenuItem({ content: $r('app.string.appearance_title'),
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.paintbrush_fill')) })
        .onClick(() => { this.appearanceOpen = true; })
    }
  }

  @Builder
  settingsPill() {
    Row() {
      Row({ space: S8 }) {
        SymbolGlyph($r('sys.symbol.gearshape'))
          .fontSize(16)
          .fontColor([$r('sys.color.ohos_id_color_text_primary')])
        Text($r('app.string.settings_title'))
          .fontSize(13)
          .fontFamily(FONT_FAMILY)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .maxLines(1)
      }
      .constraintSize({ minHeight: 36 })
      .padding({ left: S12, right: S12 })
      .borderRadius(18)
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .border({ width: 0.5, color: $r('sys.color.ohos_id_color_list_separator') })
      .clip(true)
      .shadow({ radius: 16, color: '#24000000', offsetY: 4 })
      .responseRegion({ x: 0, y: -6, width: '100%', height: TOUCH_TARGET })
      .hoverEffect(HoverEffect.Highlight)
      .accessibilityText($r('app.string.settings_title'))
      .accessibilityLevel('yes')
      .bindMenu(this.settingsMenu)
    }
    .width('100%')
    .height(TOUCH_TARGET)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .position({ bottom: this.settingsPillBottom(), left: 0 })
    .hitTestBehavior(HitTestMode.Transparent)
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
        .onClick(() => this.reloadCurrent())
      Button($r('app.string.network_open_settings'))
        .type(ButtonType.Capsule)
        .fontFamily(FONT_FAMILY)
        .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
        .onClick(() => {
          this.openNetworkSettings();
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
    Web({ src: this.webSource, controller: this.controller, renderMode: RenderMode.ASYNC_RENDER })
      .width('100%')
      .height('100%')
      // 网页遮罩和背景延伸至手势区，交互元素由网页安全区样式避让。
      .expandSafeArea([SafeAreaType.SYSTEM], this.viewingHandle !== '' && this.showsNativeNavigation()
        ? [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM] : [SafeAreaEdge.BOTTOM])
      // Injected at document start, so the page's history hook always finds it.
      .javaScriptProxy({
        object: this.bridge,
        name: 'otNative',
        methodList: ['onUrlChange', 'onImages', 'onTheme', 'onProfileLayout', 'onWebModal'],
        controller: this.controller
      })
      .onControllerAttached(() => {
        // userAgent() on the attribute is deprecated; the controller API is the
        // supported way and can only run once the controller is bound.
        try {
          this.controller.setCustomUserAgent(this.rawWeb ? web_webview.WebviewController.getDefaultUserAgent() : this.userAgent());
        } catch (err) {
          hilog.warn(DOMAIN, TAG, 'custom UA rejected: %{public}s', JSON.stringify(err));
        }
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        if (!this.webImages) { this.webImages = new WebImageDownloads(this.controller, context.cacheDir); }
        try {
          this.downloadDelegate = installDownloads(this.controller, context,
            (result: string) => { this.reportDownload(result); }, this.webImages);
        } catch (err) {
          hilog.error(DOMAIN, TAG, 'event=download_delegate_failed code=%{public}d', (err as BusinessError).code);
        }
        this.incomingControllerReady = true;
        this.onIncomingContentChanged();
      })
      .onWindowNew((event: OnWindowNewEvent) => {
        event.handler.setWebController(null);
        if (isSiteUrl(event.targetUrl) || isAuthUrl(event.targetUrl)) {
          this.loadWeb(event.targetUrl, false, true);
        } else if (/^https?:\/\//i.test(event.targetUrl)) {
          this.openExternal(event.targetUrl);
        } else { this.toast($r('app.string.operation_failed')); }
      })
      .onLoadIntercept((event) => this.interceptExternal(event))
      .onFullScreenEnter((event) => { this.enterFullScreen(event.handler); })
      .onFullScreenExit(() => { this.exitFullScreen(); })
      .onContextMenuShow((event) => {
        if (!event || this.rawWeb || !event.param.existsImageContents() || !isSiteUrl(this.controller.getUrl())) { return false; }
        const media = resolveMedia(event.param.getSourceUrl());
        if (!media || this.imageViewerOpen) { return false; }
        this.imageItems = [media];
        this.imageIndex = 0;
        this.tick();
        this.imageViewerOpen = true;
        event.result.closeContextMenu();
        return true;
      })
      .javaScriptAccess(true)
      .javaScriptOnDocumentStart([{ script: this.rawWeb ? '' : UNREAD_RESPONSE_SCRIPT + chromeDocumentStartScript(true),
        scriptRules: ['https://x.com', 'https://www.x.com', 'https://twitter.com', 'https://www.twitter.com'] }])
      .domStorageAccess(true)
      // x.com's chat client keeps its session state in browser storage; ArkWeb
      // gates the database APIs behind this flag and defaults them off.
      .databaseAccess(true)
      .fileAccess(false)
      .mixedMode(MixedMode.Compatible)
      .cacheMode(CacheMode.Default)
      .overviewModeAccess(true)
      // 禁止 ArkWeb 自身的下拉刷新/过滚动，避免整页被重新加载。
      .overScrollMode(OverScrollMode.NEVER)
      .zoomAccess(true)
      .geolocationAccess(true)
      .mediaPlayGestureAccess(false)
      .darkMode(WebDarkMode.Auto)
      .textZoomRatio(100)
      .onTouch((event: TouchEvent) => { this.handleWebTouch(event); })
      .onScroll((event: OnScrollEvent) => { this.handleWebScroll(event.yOffset); })
      .onAreaChange((_old: Area, area: Area) => {
        if (this.webWidth !== Number(area.width)) { this.resetProfileLayout(); }
        this.webWidth = Number(area.width);
        this.syncChromeInsets();
      })
      .onProgressChange((event) => {
        if (event) {
          this.progress = event.newProgress;
        }
      })
      .onPageBegin(() => {
        if (!this.webNetworkReady) { return; }
        this.updateWebModal(false);
        this.documentLoading = true;
        this.armFirstLoadTimeout();
        this.resetProfileLayout();
        this.incomingPageReady = false;
        this.hasError = false;
      })
      .onPageEnd((event) => {
        if (!this.webNetworkReady) { return; }
        if (event && this.controller.getUrl() !== event.url) { return; }
        this.documentLoading = false;
        if (!this.rawWeb && event && isSiteUrl(event.url)) {
          this.controller.runJavaScript(MEDIA_CLICK_SCRIPT).catch((error: Error) => {
            hilog.error(DOMAIN, TAG, 'event=image_bridge_failed error=%{public}s', error.message);
            this.toast($r('app.string.operation_failed'));
          });
        }
        this.saveWebSession();
        this.progress = 100;
        this.refreshing = false;
        this.finishFirstLoad();
        if (event && event.url) {
          this.syncFromUrl(event.url);
          this.applyPageChrome(event.url);
        }
        if (this.appBackground && !this.rawWeb) {
          this.controller.runJavaScript(chromeActiveScript(false)).catch((err: BusinessError) => {
            hilog.warn(DOMAIN, TAG, 'event=chrome_lifecycle_failed code=%{public}d', err.code);
          });
        }
        this.incomingPageReady = true;
        if (this.incomingContent.kind !== '') {
          this.onIncomingContentChanged();
          return;
        }
        if (this.rawWeb) { return; }
        this.schedulePageStateRead();
        if (this.ownHandle === '') {
          this.discoverOwnProfile();
        }
      })
      .onErrorReceive((event) => {
        // Subresource failures (images, analytics) are normal on x.com — only
        // treat main-frame failures as fatal.
        try {
          if (event && event.request && !event.request.isMainFrame()) {
            return;
          }
          // 页面内跳转取消旧请求，不代表当前页面加载失败。
          if (event && event.error.getErrorCode() === -3) { return; }
          if (event) {
            hilog.error(DOMAIN, TAG, 'event=main_frame_failed code=%{public}d', event.error.getErrorCode());
          }
        } catch (err) {
        }
        this.hasError = true;
        this.progress = 100;
        this.refreshing = false;
        this.finishFirstLoad();
        if (this.incomingContent.kind !== '') {
          this.incomingContent = { kind: '', value: '' };
          this.toast($r('app.string.incoming_failed'));
        }
      })
      .onRenderExited((event) => {
        hilog.error(DOMAIN, TAG, 'event=render_exit detail=%{public}s', JSON.stringify(event));
        this.hasError = true;
        this.finishFirstLoad();
      })
      .onGeolocationShow((event) => {
        if (event && event.geolocation) {
          this.askLocation(event.origin, event.geolocation);
        }
      })
      .onShowFileSelector((event) => {
        return this.openFileSelector(event);
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
          Column() {
            // HarmonyOS pull-to-refresh drives the WebView directly, so the
            // header does not need a refresh button.
            Refresh({ refreshing: $$this.refreshing }) {
              Column() {
                if (this.preferencesReady && this.webNetworkReady) {
                  ForEach([this.webSession], () => { this.webView() }, (session: number) => session.toString())
                }
              }.width('100%').height('100%')
            }
            .width('100%')
            .height('100%')
            // Web 位于刷新容器内，两者须使用相同的绘制扩展边界。
            .expandSafeArea([SafeAreaType.SYSTEM], this.viewingHandle !== '' && this.showsNativeNavigation()
              ? [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM] : [SafeAreaEdge.BOTTOM])
            .pullToRefresh(true)
            .onRefreshing(() => {
              this.refreshing = true;
              this.reloadCurrent();
            })
          }
          .width('100%')
          .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.ohos_id_color_background'))

      if (this.hasError) { this.errorState() }

      if ((!this.firstLoadDone || this.documentLoading) && !this.hasError) {
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
        .backgroundColor(this.pageBackground || $r('sys.color.ohos_id_color_background'))
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

      // 发帖入口只属于首页，不能随上一次选中的标签泄漏到其他页面。
      if (this.showsNativeNavigation() && this.isHomeRoot() && !this.hasError && this.firstLoadDone) {
        this.composeFab()
      }
    }
    .width('100%')
    .height('100%')
    .flexGrow(1)
    .flexShrink(1)
    // 资料横幅及其遮罩一起延伸至状态栏；其他页面沿用底部扩展边界。
    .expandSafeArea([SafeAreaType.SYSTEM], this.viewingHandle !== '' && this.showsNativeNavigation()
      ? [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM] : [SafeAreaEdge.BOTTOM])
    .backgroundColor($r('sys.color.ohos_id_color_background'))
  }

  @Builder
  composeSheet() {
    Column({ space: 0 }) {
    if (this.webComposer) {
      Row() {
        Button($r('app.string.close_editor')).onClick(() => { this.closeCompose(); })
        Blank()
        if (this.draft !== '') {
          Button($r('app.string.compose_copy_draft')).onClick(() => { this.copyComposeDraft(); })
        }
      }.width('100%').padding(S8)
    }
    Stack({ alignContent: Alignment.TopStart }) {
      // x.com's own composer, kept invisible under the native panel. It exists
      // only so the native Post button submits through the real web session;
      // if it has to surface (media, polls, threads, or an undrivable editor)
      // it is revealed and the native panel steps aside.
      if (this.webNetworkReady) {
      Web({ src: this.composeUrl, controller: this.composeController })
        .width('100%')
        .height('100%')
        .opacity(this.webComposer ? 1 : 0)
        .onControllerAttached(() => {
          try {
            this.composeController.setCustomUserAgent(this.userAgent());
            this.composeDownloadDelegate = installDownloads(this.composeController,
              this.getUIContext().getHostContext() as common.UIAbilityContext,
              (result: string) => { this.reportDownload(result); });
          } catch (err) {
            hilog.error(DOMAIN, TAG, 'event=compose_controller_failed code=%{public}d', (err as BusinessError).code);
            this.composeMessage = $r('app.string.editor_failed');
          }
        })
        .onLoadIntercept((event) => this.interceptExternal(event))
        .onPageBegin(() => { this.composeLoading = true; this.clearComposeSync(); })
        .onPageEnd(() => { this.composeLoading = false; this.scheduleComposeSync(); })
        .onFullScreenEnter((event) => { this.enterFullScreen(event.handler); })
        .onFullScreenExit(() => { this.exitFullScreen(); })
        .onRenderExited(() => {
          this.composeLoading = false;
          if (this.posting) { this.markPostUnknown(); }
          this.composeMessage = $r('app.string.editor_failed');
        })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .databaseAccess(true)
        .fileAccess(false)
        .mixedMode(MixedMode.Compatible)
        .cacheMode(CacheMode.Default)
        .overScrollMode(OverScrollMode.NEVER)
        .zoomAccess(false)
        .darkMode(WebDarkMode.Auto)
        .onShowFileSelector((event) => {
          return this.openFileSelector(event);
        })
      }

      ComposerPanel({ draft: $draft, ready: this.composeReady, posting: this.posting,
        uncertain: this.postUncertain, preparing: this.composePreparing, loading: this.composeLoading,
        hasOwner: this.composeOwner !== '', message: this.composeMessage,
        onClose: () => { this.closeCompose(); }, onPost: () => { this.postFromSheet(); },
        onMore: () => { this.openWebComposer(); }, onVerify: () => { this.resolveUnknownPost(); },
        onDraftChange: () => { this.scheduleDraftSave(); }, onComposeKey: (event: KeyEvent) => this.composeKey(event) })
      .visibility(this.webComposer ? Visibility.Hidden : Visibility.Visible)
      if (this.webComposer && this.composeLoading) {
        LoadingProgress().width(32).height(32).margin(S16)
      }
    }
    .width('100%')
    .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .borderRadius({ topLeft: RADIUS, topRight: RADIUS })
    .clip(true)
    .backgroundColor($r('sys.color.ohos_id_color_background'))
    // Escape works from anywhere in the sheet, not only from the editor.
    .onKeyEvent((event: KeyEvent) => this.composeKey(event))
  }

  /** 桥接数据属于网页输入，完整校验通过后才接管当前点击。 */
  private openImages(payload: string): boolean {
    if (this.rawWeb || this.imageViewerOpen || this.sheetOpen || this.fullScreen || !isSiteUrl(this.controller.getUrl())) { return false; }
    try {
      const data = JSON.parse(payload) as ImagePayload;
      if (!Array.isArray(data.urls) || data.urls.length < 1 || data.urls.length > 4 ||
        !Number.isInteger(data.index) || data.index < 0 || data.index >= data.urls.length) { return false; }
      const items: MediaAddress[] = [];
      for (const url of data.urls) {
        if (typeof url !== 'string') { return false; }
        const item = resolveMedia(url);
        if (!item || items.some((existing: MediaAddress) => existing.id === item.id)) { return false; }
        items.push(item);
      }
      this.imageItems = items;
      this.imageIndex = data.index;
      this.tick();
      this.imageViewerOpen = true;
      return true;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'event=image_payload_rejected error=%{public}s', JSON.stringify(error));
      return false;
    }
  }

  @Builder
  imageViewer() {
    NativeImageViewer({ items: this.imageItems, initialIndex: this.imageIndex,
      webImages: this.webImages, onClose: () => { this.imageViewerOpen = false; },
      onRecover: () => { this.recoverMediaWeb(false); }, onWeb: () => { this.recoverMediaWeb(true); } })
  }

  build() {
    WithTheme({ colorMode: this.webColorMode }) {
    HdsNavigation() {
      Stack() {
        // 网络设置面板独占一个 1x1 宿主，避免覆盖外观/发帖/图片查看器的弹层绑定。
        Row()
          .width(1)
          .height(1)
          .hitTestBehavior(HitTestMode.None)
          .accessibilityLevel('no-hide-descendants')
          .bindSheet($$this.networkOpen, this.networkSettingsSheet(), {
            height: SheetSize.LARGE,
            width: this.isWide ? 480 : '100%',
            dragBar: true,
            showClose: true
          })

        // 只负责把网页的滚动偏移喂给 HDS，本身不绘制也不接触摸。
        Scroll(this.blurScroller) {
          Column().height(HEADER_BLUR_DISTANCE * 2)
        }
        .width(1)
        .height(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)
        .opacity(0)
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no-hide-descendants')

        Row() {
          if (this.isWide && this.showsNativeNavigation() && !isPostDetailUrl(this.currentUrl) && !isSecondaryUrl(this.currentUrl)) { this.navBar() }
          HdsTabs({ barPosition: BarPosition.End, controller: this.tabsController }) {
            // 五个入口均路由到同一网页会话，内容节点常驻，避免页签切换重建 Web。
            TabContent() {
              Column() { this.webArea() }
              .width('100%')
              .height('100%')
              // 网页自带标题时由视口避让状态栏；原生标题覆盖的列表仍从屏幕顶部绘制。
              .padding({ top: this.fullScreen || (this.overlaysWeb() && this.topChromeHeight() > 0) ? 0 :
                this.topInset + (this.overlaysWeb() ? 0 : this.topChromeHeight()),
                bottom: this.overlaysWeb() ? 0 : this.bottomChromeHeight() })
            }
            .tabBar(this.bottomNavigation())
          }
          .scrollable(false)
          .barOverlap(true)
          .barHeight(this.bottomChromeHeight() > 0 ? (this.floatingBar ? FLOATING_BAR_HEIGHT : BAR_HEIGHT) : 0)
          .barFloatingStyle(this.bottomChromeHeight() > 0 && this.floatingBar ? {
            barWidth: { smallWidth: '100%', mediumWidth: 380, largeWidth: 380 },
            barSideMargin: 20,
            // 手势区已提供与图库相同的底边距离，不再叠加额外悬浮间距。
            barBottomMargin: this.bottomInset,
            gradientMask: { maskColor: Color.Transparent, maskHeight: 1 },
            systemMaterialEffect: {
              materialType: this.immersiveMaterial ? hdsMaterial.MaterialType.IMMERSIVE : hdsMaterial.MaterialType.ADAPTIVE,
              materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
            }
          } : undefined)
          // 弹层绑定分属不同节点，避免外观面板的 bindSheet 覆盖图片查看器。
          .bindContentCover($$this.imageViewerOpen, this.imageViewer(), {
            modalTransition: ModalTransition.ALPHA,
            backgroundColor: Color.Transparent,
            onWillDismiss: (action: DismissContentCoverAction) => { action.dismiss(); this.imageViewerOpen = false; }
          })
          .layoutWeight(1)
          // 忽略安全区时，matchParent 同时扩展尺寸；百分比高度只会移动位置。
          .height(LayoutPolicy.matchParent)
          .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
        }
        .width('100%')
        .height(LayoutPolicy.matchParent)
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
        .bindSheet($$this.appearanceOpen, this.appearanceSheet(), {
          height: SheetSize.FIT_CONTENT,
          width: this.isWide ? 480 : '100%',
          dragBar: true,
          showClose: true
        })

        if (this.settingsPillVisible()) {
          this.settingsPill()
        }
      }
      .width('100%')
      .height(LayoutPolicy.matchParent)
    }
    .width('100%')
    .height(LayoutPolicy.matchParent)
    .titleBar({
      enableComponentSafeArea: true,
      content: { stackBuilder: () => { this.navTitleBar(); } },
      style: {
        // 顶部无模糊无底色，滚动后由 HDS 线性过渡到带材质底色的羽化模糊。
        // GRADIENT_BLUR 是唯一支持 maskExtraHeight 的类型，蒙层会向标题栏
        // 下方延伸，形成柔和的渐变边界。
        originalStyle: {
          backgroundStyle: {
            backgroundColor: Color.Transparent,
            blurRadius: 0,
            maskExtraHeight: HEADER_BLUR_EXTRA_HEIGHT
          }
        },
        scrollEffectStyle: {
          backgroundStyle: {
            blurRadius: 32,
            maskExtraHeight: HEADER_BLUR_EXTRA_HEIGHT
          }
        },
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR,
          blurEffectiveStartOffset: LengthMetrics.vp(0),
          blurEffectiveEndOffset: LengthMetrics.vp(HEADER_BLUR_DISTANCE)
        },
        blurStrategy: BlurStrategy.ENABLE,
        systemMaterialEffect: {
          materialType: this.immersiveMaterial ? hdsMaterial.MaterialType.IMMERSIVE : hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      }
    })
    .bindToScrollable([this.blurScroller])
    .withTheme({ enableThemeColorMode: true })
    .systemBarStyle({ statusBarContentColor: this.profileBannerButtons() || this.isMediaViewer() || this.webColorMode === ThemeColorMode.DARK ? '#FFFFFF' :
      this.webColorMode === ThemeColorMode.LIGHT ? '#000000' : this.statusBarContentColor }, undefined)
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideTitleBar(this.topChromeHeight() === 0)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    // Navigation defaults to Split mode on wide windows, which would reserve a
    // left pane for the title bar and squeeze our own rail + WebView into it.
    // The shell owns the wide layout, so keep Navigation in Stack mode.
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .backgroundColor(this.isMediaViewer() ? Color.Black : this.pageBackground || $r('sys.color.ohos_id_color_background'))
    .bindSheet($$this.sheetOpen, this.composeSheet(), {
      height: SheetSize.LARGE,
      width: this.isWide ? 640 : '100%',
      dragBar: true,
      showClose: this.webComposer,
      shouldDismiss: (() => { this.closeCompose(); }),
      blurStyle: BlurStyle.COMPONENT_ULTRA_THICK
    })
    }
  }
}
