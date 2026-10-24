import web_webview from '@ohos.web.webview';
import mediaquery from '@ohos.mediaquery';
import { MediaAddress, MediaPostState, MediaActionResult, MediaOrigin, resolveMedia, MEDIA_CLICK_SCRIPT,
  MEDIA_ACTION_RESPONSE_SCRIPT, mediaActionScript, restoreMediaOriginScript } from '../common/WebMedia';
import { MediaFile } from '../common/MediaFiles';
import { WebImageDownloads } from '../common/WebImageDownloads';
import { IncomingContent } from '../common/IncomingContent';
import { NativeImageViewer } from './NativeImageViewer';
import { NetworkSettingsSheet } from './NetworkSettingsSheet';
import { ComposerPanel } from './ComposerPanel';
import { ComposerSession } from '../common/ComposerSession';
import { UnreadSession } from '../common/UnreadSession';
import { AccountSession } from '../common/AccountSession';
import { WebNavigation } from '../common/WebNavigation';
import { WEB_RESPONSE_SCRIPT } from '../common/WebResponses';
import { NativeBottomBar } from './NativeBottomBar';
import { NativeTopBar } from './NativeTopBar';
import { NativeSettingsPage } from './NativeSettingsPage';
import { DEFAULT_TABS, ALL_TAB_IDS, REQUIRED_TAB_IDS, appearanceScript } from '../common/ClientSettings';
import { NetworkConfig, NetworkSnapshot } from '../common/NetworkConfig';
import { preferences } from '@kit.ArkData';
import { isSiteUrl, isAuthUrl, mediaAcceptTypes, chooseMedia, installDownloads, removeExpiredDownloads } from '../common/WebSystem';
import { abilityAccessCtrl, common, ConfigurationConstant, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ColorMetrics, LengthMetrics, uiMaterial, window } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationTitleMode, HdsTabs, hdsMaterial,
  HdsTabsController, HdsAnimationMode, BlurStrategy, ScrollEffectType } from '@kit.UIDesignKit';
import { vibrator } from '@kit.SensorServiceKit';
import {
  BAR_HEIGHT, FONT_FAMILY, PROGRESS_HEIGHT, RAIL_WIDTH, RADIUS, S12, S16, S4, S8, TOUCH_TARGET,
  WIDE_BREAKPOINT
} from '../common/Theme';
import {
  TWITTER_BASE, TWITTER_ROUTES, TWITTER_UA,
  TWITTER_NOTIF_SETTINGS, TWITTER_EDIT_PROFILE,
  profileUrl, pathOf, routeIndexForUrl, profileHandleForUrl,
  isTabRootPath, isPostDetailUrl, isSecondaryUrl, usesNativeNavigation, usesNativeHeader, userAgentFor
} from '../common/WebConfig';
import {
  chromeScript, chromeFlagScript, chromeInsetsScript, chromeDocumentStartScript, chromeActiveScript, scrollToTopScript,
  unquoteScriptResult,
  HOME_TAB_SCRIPT, selectHomeTabScript,
  ACCOUNT_SWITCH_SCRIPT
} from '../common/WebChrome';

// 原生层提供导航、纯文字编辑与系统交互，网页保留搜索及会话交互。
// 主 WebView 独立于标签内容，避免切换标签时销毁网页和会话。

const DOMAIN: number = 0x0A11;
const TAG: string = 'OpenTwit';

const PREFS_NAME: string = 'opentwit_web';
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
const LOCATION_PERMISSIONS: Permissions[] = ['ohos.permission.LOCATION'];
const FIRST_LOAD_TIMEOUT_MS: number = 15000;
// The page's title and history only settle a moment after it navigates.
const PAGE_STATE_DELAY_MS: number = 700;

// Bridge exposed to the page as window.otNative. x.com is a single-page app, so
// its navigations never fire the Web component's load callbacks; the injected
// history hook calls this instead.
class PageBridge {
  private active: () => boolean = () => false;
  constructor(active: () => boolean) { this.active = active; }
  // 网页弹层只能绘制在 Web 内，需要通知原生控件让位。
  private modalHandler: (url: string, open: boolean) => void = () => {};
  setModalHandler(handler: (url: string, open: boolean) => void): void { this.modalHandler = handler; }
  onWebModal(url: string, open: boolean): void { if (this.active()) { this.modalHandler(url, open); } }
  private profileHandler: (payload: string) => void = () => {};
  setProfileHandler(handler: (payload: string) => void): void { this.profileHandler = handler; }
  onProfileLayout(payload: string): void { if (this.active()) { this.profileHandler(payload); } }
  private themeHandler: (color: string) => void = () => {};
  setThemeHandler(handler: (color: string) => void): void { this.themeHandler = handler; }
  onTheme(source: string, color: string): void { if (this.active() && source === 'main') { this.themeHandler(color); } }
  private imageHandler: (payload: string) => boolean = () => false;
  setImageHandler(handler: (payload: string) => boolean): void { this.imageHandler = handler; }

  onImages(payload: string): boolean { return this.active() && this.imageHandler(payload); }
  private handler: (url: string) => void = (url: string) => {
  };

  setHandler(handler: (url: string) => void): void {
    this.handler = handler;
  }

  onUrlChange(source: string, url: string): void {
    if (this.active() && source === 'main') { this.handler(url); }
  }
}
// 网页路由与账号入口共用有界就绪检查，避免慢网误判。
const PROFILE_TIMEOUT_MS: number = 10000;

interface ImagePayload {
  urls: string[];
  index: number;
  postId?: string;
  postUrl?: string;
  liked?: boolean;
  bookmarked?: boolean;
  reposted?: boolean;
  origin?: MediaOrigin;
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

@Entry
@Component
struct MainTabs {
  @State @Watch('imageViewerChanged') imageViewerOpen: boolean = false;
  private imageItems: MediaAddress[] = [];
  @State imageIndex: number = 0;
  @State imagePost: MediaPostState = { postId: '', postUrl: '' };
  private imageActionSequence: number = 0;
  // 互动和返回只归当前查看会话，网页恢复后旧回调随实例一起失效。
  private imageSession: number = 0;
  private imageOwner: string = '';
  private imageWebSession: number = 0;
  private imageOrigin: MediaOrigin | undefined = undefined;
  private imageNavigation: number = -1;
  @State imagePostReady: boolean = false;
  @State imageUncertainActions: string[] = [];
  @State imageChromeVisible: boolean = true;
  @State imageDragging: boolean = false;
  @State imageDetailsVisible: boolean = false;
  @State imageCurrentFile: MediaFile | undefined = undefined;
  @State imageBusy: boolean = false;
  @State imageShareTrigger: number = 0;
  @State imageRepostMenuOpen: boolean = false;
  @State imageMoreOpen: boolean = false;
  @State imageAnalyzerSelecting: boolean = false;
  @State imageAnalyzerCancelTrigger: number = 0;
  @State currentIndex: number = 0;
  @State settingsOpen: boolean = false;
  @State settingsPage: string = '';
  @State settingsWeb: boolean = false;
  private settingsOrigin: number = 0;
  private settingsOriginUrl: string = TWITTER_ROUTES[0];
  private settingsWebRoot: string = '';
  @State themeMode: string = 'system';
  @State fontScale: number = 100;
  @State originalImages: boolean = true;
  @State showNotificationBadge: boolean = true;
  @State enabledTabs: number[] = DEFAULT_TABS.slice();
  @State tabOrder: number[] = ALL_TAB_IDS.slice();
  @State materialLevel: string = 'adaptive';
  @State tabToggleGeneration: number = 0;
  @State customUa: string = '';
  private pageAlive: boolean = false;
  // Which Home timeline the native switcher has selected: 0 = For you,
  // 1 = Following. Mirrors x.com's own tab row.
  @State homeTabIndex: number = 0;
  @State homeTabsHeight: number = 32;
  @State isWide: boolean = false;
  @State floatingBar: boolean = true;
  @State autoHideBar: boolean = true;
  @State immersiveMaterial: boolean = false;
  @State @Watch('onNetworkOpenChanged') networkOpen: boolean = false;
  @State @Watch('onBarsCollapsedChanged') barsCollapsed: boolean = false;
  @State bottomInset: number = 0;
  @State topInset: number = 0;
  private shellWindow: window.Window | undefined = undefined;
  private avoidChanged: (area: window.AvoidAreaOptions) => void = () => this.updateShellInsets();
  private tabsController: HdsTabsController = new HdsTabsController();
  // Web 的滚动由渲染进程持有，HDS 只能读取 ArkUI 可滚动组件；把网页偏移镜像到
  // 这个 1vp 隐藏滚动容器，标题栏才能按官方指南在两种样式间过渡。
  private blurScroller: Scroller = new Scroller();
  private settingsScroller: ListScroller = new ListScroller();
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
  @State navigation: WebNavigation = new WebNavigation({
    controller: () => this.controller, isNetworkReady: () => this.webNetworkReady,
    isControllerReady: () => this.webControllerReady,
    isActive: () => this.pageAlive && !this.appBackground,
    documentStarted: (url: string) => this.documentStarted(url),
    cancelProfileNavigation: () => this.account.cancelProfileNavigation(),
    routeSettled: () => {
      this.syncFromUrl(this.webUrl());
      this.schedulePageStateRead();
    },
    toast: (message: ResourceStr) => this.toast(message)
  });
  @State account: AccountSession = new AccountSession({
    getUIContext: () => this.getUIContext(), webScript: (script: string) => this.webScript(script),
    url: () => this.navigation.currentUrl, isAuthenticationPage: () => this.authenticationPage,
    isRawWeb: () => this.rawWeb, webImages: () => this.webImages, currentIndex: () => this.currentIndex,
    isControllerReady: () => this.webControllerReady, isSettingsOpen: () => this.settingsOpen,
    isComposerOpen: () => this.composer.sheetOpen, accountChanged: () => {
      this.navigation.cancel();
      this.unread.resetAccount();
      this.imageOrigin = undefined;
      if (this.imageViewerOpen) { this.imageViewerOpen = false; }
    },
    loadWeb: (url: string) => this.navigation.loadWeb(url),
    toast: (message: ResourceStr) => this.toast(message)
  });
  @State unread: UnreadSession = new UnreadSession({
    webScript: (script: string) => this.webScript(script), owner: () => this.account.ownHandle, url: () => this.navigation.currentUrl,
    isControllerReady: () => this.webControllerReady,
    isRawWeb: () => this.rawWeb, getUIContext: () => this.getUIContext(),
    putPreference: (key: string, value: preferences.ValueType) => this.putPreference(key, value)
  });
  @State composer: ComposerSession = new ComposerSession({
    getUIContext: () => this.getUIContext(),
    confirmCurrentAccount: () => this.account.confirmCurrentAccount(),
    acceptHandle: (handle: string, navigate: boolean) => this.account.acceptHandle(handle, navigate),
    putPreference: (key: string, value: preferences.ValueType) => this.putPreference(key, value),
    toast: (message: ResourceStr) => this.toast(message)
  });
  @State rawWeb: boolean = false;
  @State desktopMode: boolean = false;
  @State preferencesReady: boolean = false;
  @State webSession: number = 0;
  @State webNetworkReady: boolean = true;
  private webSource: string = TWITTER_ROUTES[0];
  // 新文档尚未提交时，控制器仍可能返回上一页地址。
  private pendingDocumentUrl: string = '';
  private failedWebUrl: string = '';
  @State retrying: boolean = false;
  private renderRecoveryPending: boolean = false;
  private lastRenderRecovery: number = 0;
  private pageStateTimer: number = -1;
  @State authenticationPage: boolean = false;
  @State fullScreen: boolean = false;
  @StorageLink('appBackground') @Watch('onBackgroundChanged') appBackground: boolean = false;
  @StorageLink('incomingContent') @Watch('onIncomingContentChanged') incomingContent: IncomingContent =
    { kind: '', value: '' };
  @StorageLink('incomingError') @Watch('onIncomingErrorChanged') incomingError: number = 0;
  private webControllerReady: boolean = false;
  private incomingPageReady: boolean = false;
  private fullScreenHandler: FullScreenExitHandler | undefined = undefined;
  private fullScreenWindow: window.Window | undefined = undefined;
  private previousLayoutFullScreen: boolean = false;
  private downloadDelegate: web_webview.WebDownloadDelegate | undefined = undefined;
  private webImages: WebImageDownloads | undefined = undefined;
  private composeDownloadDelegate: web_webview.WebDownloadDelegate | undefined = undefined;
  // The page's own title (x.com's " / X" suffix stripped) and whether there is
  // web history to go back to. The shell draws the header for every page, so
  // these are what the native title bar shows.
  @State refreshing: boolean = false;
  @State pageTitle: string = '';
  @State canGoBack: boolean = false;
  private controller: web_webview.WebviewController = new web_webview.WebviewController();
  private wideListener: mediaquery.MediaQueryListener | undefined = undefined;
  private bridge: PageBridge = this.createBridge(0);
  private firstLoadTimer: number = -1;
  private networkUnsubscribe: (() => void) | undefined = undefined;
  private networkGeneration: number = 0;
  private networkPendingReload: boolean = false;
  private networkReloadTimer: number = -1;

  onWillApplyTheme(theme: Theme): void {
    const color = ColorMetrics.resourceColor(theme.colors.fontPrimary);
    this.statusBarContentColor = '#' + ((color.red << 16) | (color.green << 8) | color.blue)
      .toString(16).padStart(6, '0');
  }

  /** 旧网页保留的代理只属于旧会话，恢复期间不能回调新控制器。 */
  private createBridge(session: number): PageBridge {
    const bridge = new PageBridge(() => this.pageAlive && this.webControllerReady && session === this.webSession);
    bridge.setImageHandler((payload: string) => this.openImages(payload));
    bridge.setModalHandler((url: string, open: boolean) => {
      if (this.rawWeb || !isSiteUrl(url) || this.webUrl() !== url) { return; }
      this.updateWebModal(open);
    });
    bridge.setProfileHandler((payload: string) => this.receiveProfileLayout(payload));
    bridge.setThemeHandler((color: string) => {
      const match = /^rgb\((\d{1,3}),\s*(\d{1,3}),\s*(\d{1,3})\)$/.exec(color);
      if (!match || !isSiteUrl(this.webUrl())) { return; }
      const red = Number(match[1]), green = Number(match[2]), blue = Number(match[3]);
      if (red > 255 || green > 255 || blue > 255) { return; }
      this.pageBackground = color;
      this.webColorMode = this.themeMode === 'dark' ? ThemeColorMode.DARK : this.themeMode === 'light' ?
        ThemeColorMode.LIGHT : ThemeColorMode.SYSTEM;
    });
    bridge.setHandler((url: string) => {
      if (!isSiteUrl(url) && !isAuthUrl(url)) { return; }
      this.saveWebSession();
      if (this.rawWeb) { return; }
      this.syncFromUrl(url);
      this.updateChromeFlag(url);
      this.applyPageChrome(url);
      this.schedulePageStateRead();
    });
    return bridge;
  }

  async aboutToAppear(): Promise<void> {
    this.composer.activate(this.appBackground);
    this.unread.activate(this.appBackground);
    this.pageAlive = true;
    this.account.activate(this.appBackground);
    try {
      const shellContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      try {
        this.immersiveMaterial = hdsMaterial.getSystemMaterialTypes().includes(hdsMaterial.MaterialType.IMMERSIVE);
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'event=material_unavailable error=%{public}s', JSON.stringify(error));
      }
      try {
        this.shellWindow = await window.getLastWindow(shellContext);
        if (!this.pageAlive) { return; }
        // 状态栏透出页面底色，文字颜色继续由导航组件管理。
        await this.shellWindow.setWindowSystemBarProperties({ statusBarColor: '#00000000' });
        this.shellWindow.on('avoidAreaChange', this.avoidChanged);
        this.updateShellInsets();
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'event=shell_window_unavailable error=%{public}s', JSON.stringify(error));
      }
      if (!this.pageAlive) { return; }
      const net = NetworkConfig.getInstance();
      net.ensureInitialized(shellContext);
      const netSnapshot: NetworkSnapshot = net.snapshot();
      this.webNetworkReady = !(netSnapshot.mode === 'secure_only' && !netSnapshot.suspended && netSnapshot.applyError);
      if (!this.webNetworkReady) { this.navigation.failure = 'policy'; }
      this.networkGeneration = netSnapshot.generation;
      this.networkUnsubscribe = net.subscribe((snapshot: NetworkSnapshot) => {
        const ready = !(snapshot.mode === 'secure_only' && !snapshot.suspended && snapshot.applyError);
        if (!ready) {
          this.webControllerReady = false;
          this.retrying = false;
          this.renderRecoveryPending = false;
          this.pendingDocumentUrl = '';
          this.navigation.cancel();
          this.webNetworkReady = false;
          this.navigation.failure = 'policy';
          this.incomingPageReady = false;
          this.account.cancelProfileNavigation();
          this.composer.networkBlocked();
          this.webImages?.close().catch((error: Error) => {
            hilog.error(DOMAIN, TAG, 'event=web_image_close_failed error=%{public}s', error.message);
          });
          this.webImages = undefined;
        } else if (!this.webNetworkReady) {
          this.webNetworkReady = true;
          this.recoverMediaWeb(this.rawWeb, false);
          this.composer.resetController();
        }
        if (snapshot.generation !== this.networkGeneration) {
          this.networkPendingReload = true;
        }
      });
      this.applyBreakpoints();
      this.armFirstLoadTimeout();
      this.unread.armBadgeRefresh();
      try { await removeExpiredDownloads(shellContext.cacheDir); } catch (error) {
        hilog.warn(DOMAIN, TAG, 'event=download_cleanup_failed error=%{public}s', JSON.stringify(error));
        this.toast($r('app.string.operation_failed'));
      }
      const ctx: common.Context | undefined = this.getUIContext().getHostContext();
      if (ctx !== undefined) {
        const prefs: preferences.Preferences = await preferences.getPreferences(ctx, PREFS_NAME);
        await this.composer.initialize(prefs);
        await this.unread.initialize(prefs);
        this.floatingBar = await prefs.get(FLOATING_BAR_KEY, true) as boolean;
        this.autoHideBar = await prefs.get(AUTO_HIDE_BAR_KEY, true) as boolean;
        this.desktopMode = await prefs.get(DESKTOP_MODE_KEY, false) as boolean;
        this.themeMode = await prefs.get('theme_mode', 'system') as string;
        ctx.getApplicationContext().setColorMode(this.themeMode === 'dark' ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK :
          this.themeMode === 'light' ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
        this.fontScale = await prefs.get('font_scale', 100) as number;
        ctx.getApplicationContext().setFontSizeScale(this.fontScale / 100);
        this.originalImages = await prefs.get('original_images', true) as boolean;
        this.showNotificationBadge = await prefs.get('show_notification_badge', true) as boolean;
        this.enabledTabs = JSON.parse(await prefs.get('enabled_tabs', JSON.stringify(DEFAULT_TABS)) as string) as number[];
        const savedOrder = await prefs.get('tab_order', '') as string;
        if (savedOrder !== '') {
          try {
            this.tabOrder = JSON.parse(savedOrder) as number[];
          } catch {
            this.tabOrder = ALL_TAB_IDS.slice();
          }
        } else {
          const current = this.enabledTabs.slice();
          const rest = ALL_TAB_IDS.filter(id => !current.includes(id));
          this.tabOrder = current.concat(rest);
        }
        this.materialLevel = await prefs.get('material_level', 'adaptive') as string;
        this.customUa = await prefs.get('custom_ua', '') as string;
        this.webColorMode = this.themeMode === 'dark' ? ThemeColorMode.DARK : this.themeMode === 'light' ?
          ThemeColorMode.LIGHT : ThemeColorMode.SYSTEM;
        this.applyUserAgent();
        // 上次账号只预热头像，不用于资料跳转或发帖身份确认。
        await this.account.initialize(prefs);
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
    this.imageSession++;
    this.imageActionSequence++;
    this.imageOrigin = undefined;
    this.webControllerReady = false;
    this.retrying = false;
    this.renderRecoveryPending = false;
    this.pendingDocumentUrl = '';
    this.navigation.cancel();
    this.account.cancelProfileNavigation();
    this.incomingPageReady = false;
    this.pageAlive = false;
    this.stopBackgroundWork();
    this.composer.dispose();
    this.unread.dispose();
    this.account.dispose();
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
    if (this.firstLoadTimer !== -1) {
      clearTimeout(this.firstLoadTimer);
      this.firstLoadTimer = -1;
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
    this.account.setBackground(this.appBackground);
    this.composer.setBackground(this.appBackground);
    this.unread.setBackground(this.appBackground);
    if (this.appBackground) {
      this.navigation.cancel();
      this.account.cancelProfileNavigation();
      this.stopBackgroundWork();
      this.saveWebSession();
    } else if (this.pageAlive) {
      this.schedulePageStateRead();
      this.flushNetworkReload();
    }
    if (this.webControllerReady && !this.rawWeb) {
      this.webScript(chromeActiveScript(!this.appBackground)).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'event=chrome_lifecycle_failed code=%{public}d', err.code);
      });
    }
  }

  /** 只停止可恢复的界面轮询，正在进行的发布仍保留待确认标志。 */
  private stopBackgroundWork(): void {
    this.unread.stop();
    if (this.pageStateTimer !== -1) { clearTimeout(this.pageStateTimer); this.pageStateTimer = -1; }
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
    this.unread.refreshBadges();
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
    if (content.kind === '' || !this.webControllerReady || !this.incomingPageReady) { return; }
    this.incomingContent = { kind: '', value: '' };
    if (this.modalBlocksNetworkReload() || this.fullScreen || this.composer.openingCompose) {
      this.toast($r('app.string.incoming_busy'));
      return;
    }
    if (content.kind === 'compose') {
      this.composer.openCompose(content.value);
      return;
    }
    this.navigation.loadWeb(content.value);
  }

  // A page that never finishes loading must not leave the first-load spinner up
  // forever.
  private armFirstLoadTimeout(): void {
    if (this.firstLoadTimer !== -1) { clearTimeout(this.firstLoadTimer); }
    this.firstLoadTimer = setTimeout(() => {
      this.firstLoadDone = true;
      this.documentLoading = false;
      this.retrying = false;
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
    this.navigation.cancel();
    this.account.cancelProfileNavigation();
    if (this.imageViewerOpen) {
      if (this.cancelImageAnalyzer()) { return true; }
      if (!this.dismissImageDetails()) { this.imageViewerOpen = false; }
      return true;
    }
    if (this.networkOpen) { this.networkOpen = false; return true; }
    if (this.fullScreenHandler !== undefined) { this.fullScreenHandler.exitFullScreen(); return true; }
    if (this.composer.sheetOpen) {
      this.composer.closeCompose();
      return true;
    }
    if (this.settingsOpen) {
      if (this.settingsPage !== '') { this.settingsPage = ''; return true; }
      this.leaveSettings();
      return true;
    }
    if (this.settingsWeb) {
      if (this.navigation.hasError || this.navigation.currentUrl === this.settingsWebRoot || !this.webCanGoBack()) {
        this.settingsWeb = false;
        this.settingsOpen = true;
        this.navigation.failure = 'none';
        return true;
      }
      try {
        if (this.webCanGoBack()) {
          this.controller.backward();
          return true;
        }
      } catch (err) {
      }
      this.settingsWeb = false;
      this.settingsOpen = true;
      this.navigation.failure = 'none';
      return true;
    }
    if (!this.webControllerReady) { return this.retrying; }
    try {
      if (this.webCanGoBack()) {
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
    if (index === 5) { return $r('app.string.tab_grok'); }
    return $r('app.string.tab_settings');
  }

  // WebviewController.runJavaScript answers with the evaluated result
  // JSON-encoded, so a JavaScript string arrives quoted. Every value the shell
  // reads back out of a page goes through here first.
  private static unquote(raw: string): string {
    return unquoteScriptResult(raw);
  }

  // A 2in1 window is a desktop, so it asks x.com for the desktop web app: a
  // phone user agent inside a 1000+ vp window is a mismatch the site acts on
  // (and one its sign-in risk checks can read as an emulated browser). Phones,
  // tablets and unfolded foldables keep the mobile web app they were built
  // against.
  private userAgent(): string {
    return this.customUa || userAgentFor(this.desktopMode || deviceInfo.deviceType === '2in1');
  }

  private syncFromUrl(url: string, documentLoaded: boolean = false): void {
    if (this.imageViewerOpen && url !== this.navigation.currentUrl && url !== this.imagePost.postUrl) {
      this.imageOrigin = undefined;
      this.imageViewerOpen = false;
    }
    if (this.account.discovering && url !== this.navigation.currentUrl && pathOf(url) !== '/home') { this.account.cancelProfileNavigation(); }
    if (url !== this.navigation.currentUrl) { this.resetProfileLayout(); this.resetChromeScroll(); }
    this.navigation.syncFromUrl(url, documentLoaded);
    const idx: number = routeIndexForUrl(TWITTER_BASE + this.navigation.currentPath);
    if (!this.navigation.isNavigating && !this.settingsOpen && !this.settingsWeb && idx >= 0 && this.enabledTabs.includes(idx) && idx !== this.currentIndex) {
      this.currentIndex = idx;
    }
  }

  /** 网页账号入口不修改会话；切换后重新确认身份和头像。 */
  private async openAccountSwitcher(): Promise<void> {
    this.account.cancelProfileNavigation();
    try {
      if (!this.isHomeRoot() && await this.navigation.loadWeb(TWITTER_ROUTES[0]) !== 'arrived') { return; }
      const generation = this.navigation.navigationGeneration;
      const deadline = Date.now() + PROFILE_TIMEOUT_MS;
      while (generation === this.navigation.navigationGeneration && this.pageAlive && !this.appBackground) {
        if (this.isHomeRoot()) {
          const result = MainTabs.unquote(await this.webScript(ACCOUNT_SWITCH_SCRIPT));
          if (result === 'opened') { return; }
        }
        if (Date.now() >= deadline) { break; }
        await new Promise<void>((resolve) => { setTimeout(resolve, 150); });
      }
      this.toast($r('app.string.account_unconfirmed'));
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'event=account_switch_open_failed code=%{public}d', (err as BusinessError).code);
      this.toast($r('app.string.operation_failed'));
    }
  }

  private async goRoute(index: number): Promise<void> {
    if (index === 4) {
      this.openSettings();
      return;
    }
    this.navigation.cancel();
    const wasSettings = this.settingsOpen || this.settingsWeb;
    const previousIndex = this.currentIndex;
    const settingsGeneration = ++this.account.settingsReadGeneration;
    this.account.cancelProfileNavigation();
    if (!wasSettings && index === previousIndex && isTabRootPath(this.navigation.currentPath)) {
      // Tapping the active tab scrolls to top, like the stock app.
      this.webScript(scrollToTopScript()).catch((error: Error) => {
        hilog.warn(DOMAIN, TAG, 'event=scroll_top_failed error=%{public}s', error.message);
      });
      return;
    }
    this.tick();
    const pending = this.navigation.loadWeb(index === 5 ? TWITTER_BASE + '/i/grok' : TWITTER_ROUTES[index]);
    const generation = this.navigation.navigationGeneration;
    const result = await pending;
    if (result === 'cancelled' || generation !== this.navigation.navigationGeneration ||
      settingsGeneration !== this.account.settingsReadGeneration) { return; }
    if (result === 'arrived') { this.settingsOpen = false; this.settingsWeb = false; }
    else if (wasSettings) { return; }
    const actualIndex = routeIndexForUrl(TWITTER_BASE + this.navigation.currentPath);
    this.currentIndex = result === 'arrived' ? index : actualIndex >= 0 ? actualIndex : previousIndex;
  }

  /** 原生设置覆盖常驻网页，资料读取与用户离开共用代际取消。 */
  private openSettings(page: string = ''): void {
    this.navigation.cancel();
    this.account.cancelProfileNavigation();
    if (!this.settingsOpen && !this.settingsWeb) {
      this.settingsOrigin = this.currentIndex;
      this.settingsOriginUrl = this.navigation.currentUrl || TWITTER_ROUTES[0];
    }
    this.currentIndex = 4;
    this.settingsPage = page;
    this.settingsOpen = true;
    this.settingsWeb = false;
    this.resetChromeScroll();
    if (this.authenticationPage || !this.incomingPageReady) { this.account.accountError = true; }
    else { this.account.readSettingsAccount(); }
  }

  private async leaveSettings(): Promise<void> {
    const settingsGeneration = ++this.account.settingsReadGeneration;
    this.account.accountLoading = false;
    const pending = this.navigation.loadWeb(this.settingsOriginUrl);
    const generation = this.navigation.navigationGeneration;
    const result = await pending;
    if (result !== 'arrived' || generation !== this.navigation.navigationGeneration ||
      settingsGeneration !== this.account.settingsReadGeneration) { return; }
    this.settingsOpen = false;
    this.settingsWeb = false;
    this.currentIndex = this.settingsOrigin;
  }

  private async openSettingsRoute(path: string): Promise<void> {
    const generation = ++this.account.settingsReadGeneration;
    this.account.accountLoading = false;
    const target = TWITTER_BASE + path;
    const pending = this.navigation.loadWeb(target);
    const navigationGeneration = this.navigation.navigationGeneration;
    const result = await pending;
    if (result !== 'arrived' || navigationGeneration !== this.navigation.navigationGeneration ||
      generation !== this.account.settingsReadGeneration || !this.settingsOpen) { return; }
    this.settingsWebRoot = target;
    this.settingsWeb = true;
    this.settingsOpen = false;
  }

  private async saveClientSetting(key: string, value: preferences.ValueType): Promise<void> {
    try {
      await this.putPreference(key, value);
      if (key === 'theme_mode') {
        this.themeMode = value as string;
        // 应用级颜色模式同步系统资源与 HDS 内部控件，局部 WithTheme 无法替代资源配置。
        this.getUIContext().getHostContext()!.getApplicationContext().setColorMode(value === 'dark' ?
          ConfigurationConstant.ColorMode.COLOR_MODE_DARK : value === 'light' ?
          ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
        this.webColorMode = value === 'dark' ? ThemeColorMode.DARK : value === 'light' ? ThemeColorMode.LIGHT : ThemeColorMode.SYSTEM;
        if (this.webControllerReady) { await this.webScript(appearanceScript(this.themeMode)); }
        if (this.composer.composeReady) { await this.composer.composeController.runJavaScript(appearanceScript(this.themeMode)); }
      } else if (key === 'font_scale') {
        this.getUIContext().getHostContext()!.getApplicationContext().setFontSizeScale((value as number) / 100);
        this.fontScale = value as number;
      }
      else if (key === 'custom_ua') {
        this.customUa = value as string;
        this.applyUserAgent();
        this.reloadCurrent();
        this.toast($r('app.string.settings_saved'));
      }
      hilog.info(DOMAIN, TAG, 'event=client_setting_saved key=%{public}s', key);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'event=client_setting_failed key=%{public}s error=%{public}s', key, JSON.stringify(error));
      this.toast($r('app.string.operation_failed'));
    }
  }

  private async setTabEnabled(id: number, enabled: boolean): Promise<void> {
    if (id !== 2 && id !== 3 && id !== 5) { return; }
    if (enabled && !this.enabledTabs.includes(id) && this.enabledTabs.length >= 5) {
      this.tabToggleGeneration++;
      this.toast($r('app.string.settings_tabs_limit'));
      return;
    }
    const selected = enabled ? [...this.enabledTabs, id] : this.enabledTabs.filter((value: number) => value !== id);
    const tabs = (this.tabOrder || [0, 1, 2, 3, 5, 4]).filter((value: number) => selected.includes(value));
    try {
      await this.putPreference('enabled_tabs', JSON.stringify(tabs));
      this.enabledTabs = tabs;
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'event=tab_setting_failed error=%{public}s', JSON.stringify(error));
      this.tabToggleGeneration++;
      this.toast($r('app.string.operation_failed'));
    }
  }

  private async reorderTabs(order: number[]): Promise<void> {
    this.tabOrder = order.slice();
    const newEnabled = this.tabOrder.filter((value: number) => this.enabledTabs.includes(value));
    try {
      await this.putPreference('tab_order', JSON.stringify(this.tabOrder));
      await this.putPreference('enabled_tabs', JSON.stringify(newEnabled));
      this.enabledTabs = newEnabled;
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'event=tab_reorder_failed error=%{public}s', JSON.stringify(error));
      this.toast($r('app.string.operation_failed'));
    }
  }

  private async setMaterialLevel(level: string): Promise<void> {
    this.materialLevel = level;
    try {
      await this.putPreference('material_level', level);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'event=material_level_save_failed error=%{public}s', JSON.stringify(error));
      this.toast($r('app.string.operation_failed'));
    }
  }

  private currentHdsMaterialLevel(): hdsMaterial.MaterialLevel {
    if (this.materialLevel === 'exquisite') {
      return hdsMaterial.MaterialLevel.EXQUISITE;
    }
    if (this.materialLevel === 'gentle') {
      return hdsMaterial.MaterialLevel.GENTLE;
    }
    if (this.materialLevel === 'smooth') {
      return hdsMaterial.MaterialLevel.SMOOTH;
    }
    return hdsMaterial.MaterialLevel.ADAPTIVE;
  }

  private async clearWebCache(): Promise<void> {
    if (!this.webControllerReady) { this.toast($r('app.string.operation_failed')); return; }
    try {
      this.controller.removeCache(true);
      hilog.info(DOMAIN, TAG, 'event=web_cache_cleared');
      this.toast($r('app.string.settings_cache_cleared'));
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'event=web_cache_clear_failed error=%{public}s', JSON.stringify(error));
      this.toast($r('app.string.operation_failed'));
    }
  }

  @Builder
  settingsContent() {
    NativeSettingsPage({ page: $settingsPage, scroller: this.settingsScroller, handle: this.account.ownHandle, displayName: this.account.accountName,
      bio: this.account.accountBio, avatar: this.account.avatarPath, accountError: this.account.accountError,
      themeMode: this.themeMode, materialLevel: this.materialLevel, fontScale: this.fontScale, floating: this.floatingBar, autoHide: this.autoHideBar,
      originalImages: this.originalImages, showNotificationBadge: this.showNotificationBadge,
      enabledTabs: this.enabledTabs, tabOrder: this.tabOrder, customUa: this.customUa,
      desktop: this.desktopMode, desktopLocked: deviceInfo.deviceType === '2in1', rawWeb: this.rawWeb,
      topOffset: this.topInset + HEADER_HEIGHT, bottomOffset: this.bottomChromeHeight(),
      tabToggleGeneration: this.tabToggleGeneration,
      onScrollOffset: (offset: number) => { this.syncHeaderBlur(offset); },
      onProfile: () => { this.openOwnProfile(); },
      onRetryAccount: () => { this.account.readSettingsAccount(); },
      onSwitchAccount: () => {
        this.account.settingsReadGeneration++;
        this.settingsOpen = false;
        this.settingsWeb = false;
        this.currentIndex = this.settingsOrigin;
        this.openAccountSwitcher();
      },
      onRoute: (path: string) => this.openSettingsRoute(path),
      onTheme: (mode: string) => { this.saveClientSetting('theme_mode', mode); },
      onMaterialLevel: (level: string) => { this.setMaterialLevel(level); },
      onFont: (scale: number) => { this.saveClientSetting('font_scale', scale); },
      onToggle: (key: string, value: boolean) => { this.setAppearance(key, value); },
      onTab: (id: number, value: boolean) => { this.setTabEnabled(id, value); },
      onReorder: (order: number[]) => { this.reorderTabs(order); },
      onUa: (value: string) => {
        const ua = value.trim();
        if (/[\r\n\x00-\x1f\x7f]/.test(ua)) { this.toast($r('app.string.settings_ua_invalid')); return; }
        this.saveClientSetting('custom_ua', ua);
      },
      onClearCache: () => { this.clearWebCache(); }, onDoh: () => { this.openNetworkSettings(); },
      onRawWeb: () => {
        this.rawWeb = !this.rawWeb;
        this.leaveSettings();
        this.applyUserAgent();
        this.reloadCurrent();
      } })
  }

  // Native Home switcher -> the page's own (hidden) timeline tab. The page
  // reports the resulting selection back through readHomeTab, so the underline
  // only moves once the timeline has actually changed.
  private selectHomeTab(index: number): void {
    if (index === this.homeTabIndex) {
      this.webScript(scrollToTopScript()).catch((error: Error) => {
        hilog.warn(DOMAIN, TAG, 'event=scroll_top_failed error=%{public}s', error.message);
      });
      return;
    }
    this.webScript(selectHomeTabScript(index)).catch((error: Error) => {
      hilog.warn(DOMAIN, TAG, 'event=home_tab_failed error=%{public}s', error.message);
    });
    this.tick();
    this.schedulePageStateRead();
  }

  private async openOwnProfile(): Promise<void> {
    this.navigation.cancel();
    const navigationGeneration = this.navigation.navigationGeneration;
    const pendingCancel = this.account.cancelProfileNavigation();
    const generation = this.account.profileNavigation;
    const fromSettings = this.settingsOpen;
    this.account.discovering = true;
    this.navigation.failure = 'none';
    try {
      await pendingCancel;
      if (generation !== this.account.profileNavigation || navigationGeneration !== this.navigation.navigationGeneration ||
        !this.pageAlive || this.appBackground) { return; }
      const handle = this.account.ownHandle || await this.account.confirmCurrentAccount();
      if (generation !== this.account.profileNavigation || navigationGeneration !== this.navigation.navigationGeneration ||
        !this.pageAlive || this.appBackground) { return; }
      if (!/^[A-Za-z0-9_]{1,15}$/.test(handle)) {
        this.toast($r('app.string.account_unconfirmed'));
        return;
      }
      this.account.acceptHandle(handle, false);
      this.account.discovering = false;
      if (fromSettings) {
        await this.openSettingsRoute('/' + handle);
      } else { await this.navigation.loadWeb(profileUrl(handle)); }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'event=profile_navigation_failed error=%{public}s', JSON.stringify(error));
      if (generation === this.account.profileNavigation) {
        this.toast($r('app.string.account_unconfirmed'));
      }
    } finally {
      if (generation === this.account.profileNavigation) { this.account.discovering = false; }
    }
  }

  private titleMain(): string {
    if (this.navigation.viewingHandle !== '') {
      if (this.profileName !== '') { return this.profileName; }
      // The stock app titles a profile with the display name and puts the
      // handle underneath. x.com titles the page "Abhi (@Abhi_Flex) / X".
      const name: string = MainTabs.nameInTitle(this.pageTitle);
      if (name !== '') {
        return name;
      }
      return '@' + this.profileHandle();
    }
    if (isTabRootPath(this.navigation.currentPath)) {
      return '';
    }
    return this.pageTitle;
  }

  // Handle spelled the way the page spells it, falling back to the one in the
  // URL (which x.com lowercases).
  private profileHandle(): string {
    if (this.measuredHandle !== '') { return this.measuredHandle; }
    const fromTitle: string = MainTabs.handleInTitle(this.pageTitle);
    return fromTitle !== '' ? fromTitle : this.navigation.viewingHandle;
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
    if (isPostDetailUrl(this.navigation.currentUrl)) { return ''; }
    if (this.navigation.viewingHandle !== '') {
      return '@' + this.profileHandle();
    }
    if (isTabRootPath(this.navigation.currentPath)) {
      return '';
    }
    const handle: string = profileHandleForUrl(this.navigation.currentUrl);
    if (handle !== '') {
      return '@' + handle;
    }
    if (this.navigation.currentPath.indexOf('/status/') >= 0) {
      return this.localized($r('app.string.post'));
    }
    return '';
  }

  /** 绑定检查与同步异常都留在平台边界，调用方始终收到可处理的 Promise。 */
  private async webScript(script: string): Promise<string> {
    if (!this.webControllerReady) { throw new Error('Web controller is not attached'); }
    const session = this.webSession;
    const result = await this.controller.runJavaScript(script);
    if (!this.webControllerReady || session !== this.webSession) { throw new Error('Web session changed'); }
    return result;
  }

  private webUrl(): string {
    if (!this.webControllerReady) { return ''; }
    try { return this.controller.getUrl(); } catch (error) {
      hilog.warn(DOMAIN, TAG, 'event=web_url_failed error=%{public}s', JSON.stringify(error));
      return '';
    }
  }

  private webCanGoBack(): boolean {
    if (!this.webControllerReady) { return false; }
    try { return this.controller.accessBackward(); } catch (error) {
      hilog.warn(DOMAIN, TAG, 'event=web_history_failed error=%{public}s', JSON.stringify(error));
      return false;
    }
  }

  private applyUserAgent(): void {
    if (!this.webControllerReady) { return; }
    try {
      this.controller.setCustomUserAgent(this.rawWeb ? web_webview.WebviewController.getDefaultUserAgent() : this.userAgent());
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'event=user_agent_failed error=%{public}s', JSON.stringify(error));
      this.toast($r('app.string.operation_failed'));
    }
  }

  /** 应用发起的加载先登记目标，覆盖 PageBegin 之前的失败。 */
  private documentStarted(url: string): void {
    this.pendingDocumentUrl = url;
    this.failedWebUrl = url;
    this.documentLoading = true;
    this.incomingPageReady = false;
    this.armFirstLoadTimeout();
  }

  private reloadCurrent(): void {
    if (this.retrying) { return; }
    this.navigation.cancel();
    if (this.navigation.failure === 'policy' || !this.webNetworkReady) {
      this.retrying = true;
      const session = this.webSession;
      const network = NetworkConfig.getInstance();
      network.ensureApplied();
      const snapshot = network.snapshot();
      this.webNetworkReady = !(snapshot.mode === 'secure_only' && !snapshot.suspended && snapshot.applyError);
      // 应用成功的订阅回调可能已重建页面，不能再刷新尚未绑定的新控制器。
      if (!this.webNetworkReady) { this.navigation.failure = 'policy'; this.retrying = false; return; }
      if (this.webSession !== session) { return; }
      this.recoverMediaWeb(this.rawWeb, false);
      this.composer.resetController();
      return;
    }
    if (this.navigation.failure === 'render') {
      this.retrying = true;
      this.lastRenderRecovery = Date.now();
      this.recoverMediaWeb(this.rawWeb, false);
      return;
    }
    if (!this.webControllerReady) { return; }
    const failed = this.navigation.failure === 'document';
    const target = this.failedWebUrl || this.navigation.currentUrl || this.webSource;
    this.retrying = true;
    this.navigation.failure = 'none';
    this.account.retryFailedAvatar();
    this.navigation.progress = 0;
    this.refreshing = true;
    this.documentStarted(target);
    try {
      if (failed) { this.controller.loadUrl(target); }
      else { this.controller.refresh(); }
    } catch (err) {
      this.navigation.failure = 'document';
      this.pendingDocumentUrl = '';
      this.retrying = false;
      this.refreshing = false;
      this.finishFirstLoad();
      hilog.error(DOMAIN, TAG, 'event=refresh_failed error=%{public}s', JSON.stringify(err));
    }
  }

  /** 重建所属 Web 隔离无 GUID 的旧下载；保留共享登录会话和当前站内地址。 */
  private recoverMediaWeb(showWeb: boolean, notify: boolean = true): void {
    this.webControllerReady = false;
    this.retrying = true;
    this.renderRecoveryPending = false;
    this.webSession++;
    this.bridge = this.createBridge(this.webSession);
    this.navigation.cancel();
    this.account.cancelProfileNavigation();
    this.imageViewerOpen = false;
    this.rawWeb = showWeb;
    this.webSource = (this.navigation.hasError ? this.failedWebUrl : '') || this.navigation.currentUrl || this.webSource;
    this.documentStarted(this.webSource);
    this.webImages?.close().catch((error: Error) => {
      hilog.error(DOMAIN, TAG, 'event=web_image_close_failed error=%{public}s', error.message);
      this.toast($r('app.string.operation_failed'));
    });
    this.webImages = undefined;
    this.incomingPageReady = false;
    this.webModalOpen = false;
    this.controller = new web_webview.WebviewController();
    this.navigation.failure = 'none';
    this.navigation.progress = 0;
    if (notify && !showWeb) { this.toast($r('app.string.media_reopen')); }
  }

  /** 查看器先释放图片，再恢复渲染；短时间内重复退出交给用户重试。 */
  private renderExited(): void {
    this.webControllerReady = false;
    this.incomingPageReady = false;
    this.navigation.cancel();
    this.account.cancelProfileNavigation();
    this.pendingDocumentUrl = '';
    this.retrying = false;
    this.refreshing = false;
    this.finishFirstLoad();
    if (this.lastRenderRecovery > 0 && Date.now() - this.lastRenderRecovery < 30000) {
      this.renderRecoveryPending = false;
      this.navigation.failure = 'render';
      return;
    }
    this.renderRecoveryPending = true;
    this.webModalOpen = false;
    this.flushRenderRecovery();
  }

  private flushRenderRecovery(): void {
    if (!this.renderRecoveryPending || !this.pageAlive || this.appBackground || this.fullScreen ||
      this.modalBlocksNetworkReload() || !this.webNetworkReady) { return; }
    this.renderRecoveryPending = false;
    this.lastRenderRecovery = Date.now();
    this.retrying = true;
    this.recoverMediaWeb(this.rawWeb, false);
  }

  /** 账号读取失败不应使原生界面消失；登录与未知路由交给网页。 */
  private showsNativeNavigation(): boolean {
    if (this.settingsOpen || this.imageViewerOpen) { return true; }
    return !this.rawWeb && !this.fullScreen && !this.authenticationPage &&
      usesNativeNavigation(this.navigation.currentUrl);
  }

  /** 私信使用固定视口和底部输入框，保留原生栏占位而不覆盖网页。 */
  private overlaysWeb(): boolean {
    return this.showsNativeNavigation() && (isPostDetailUrl(this.navigation.currentUrl) || routeIndexForUrl(this.navigation.currentUrl) !== 3);
  }

  private bottomChromeHeight(): number {
    if (this.imageViewerOpen) { return this.imageChromeVisible && !this.imageDragging ? FLOATING_BAR_HEIGHT + this.bottomInset : 0; }
    if (this.settingsOpen) { return this.isWide ? 0 : (this.floatingBar ? FLOATING_BAR_HEIGHT : BAR_HEIGHT) + this.bottomInset; }
    return this.webModalOpen || !this.showsNativeNavigation() || isSecondaryUrl(this.navigation.currentUrl) || (this.isWide && !isPostDetailUrl(this.navigation.currentUrl)) ? 0 :
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
    if (this.imageViewerOpen) { return 0; }
    if (this.settingsOpen || this.settingsWeb) { return HEADER_HEIGHT; }
    if (this.navigation.hasError) { return HEADER_HEIGHT; }
    return this.showsNativeNavigation() && usesNativeHeader(this.navigation.currentUrl) ? HEADER_HEIGHT : 0;
  }

  /** 网页媒体查看器固定使用黑色画布，系统栏需随页面而非系统主题配色。 */
  private isMediaViewer(): boolean {
    return isSiteUrl(this.navigation.currentUrl) &&
      /^\/[a-z0-9_]{1,15}\/status\/\d+\/(mediaviewer|(?:video|photo)\/[1-4])$/.test(this.navigation.currentPath);
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
    if (!layout || typeof layout.ready !== 'boolean' || !this.pageAlive || this.appBackground || this.rawWeb ||
      this.settingsOpen || this.imageViewerOpen || this.navigation.viewingHandle === '' ||
      layout.url !== this.navigation.currentUrl || layout.url !== this.webUrl() ||
      layout.viewWidth !== this.webWidth) { return; }
    if (!layout.ready) { this.resetProfileLayout(); return; }
    if (typeof layout.hasBanner !== 'boolean' || !(layout.width > 0) || !Number.isFinite(layout.width) || !Number.isFinite(layout.scrollY) ||
      !Number.isFinite(layout.bannerBottom) || !Number.isFinite(layout.identityBottom) ||
      layout.bannerBottom <= 0 || layout.identityBottom <= 0 || typeof layout.name !== 'string' ||
      typeof layout.handle !== 'string' || layout.handle.toLowerCase() !== this.navigation.viewingHandle.toLowerCase()) { return; }
    this.profileLayout = layout;
    this.profileHasBanner = layout.hasBanner;
    this.profileName = layout.name;
    this.measuredHandle = layout.handle;
    this.lastScrollY = Math.max(0, layout.scrollY * this.webWidth / layout.width);
    this.syncHeaderBlur(this.lastScrollY);
  }

  private profileBannerButtons(): boolean {
    return !this.settingsOpen && !this.imageViewerOpen && this.navigation.viewingHandle !== '' &&
      this.profileHasBanner && this.profileBlurProgress < 0.5;
  }

  /** 把网页滚动位置镜像给 HDS，顶栏在顶部保持全透明，随滚动逐渐模糊。 */
  private syncHeaderBlur(yOffset: number): void {
    let position: number = yOffset;
    if (!this.settingsOpen && this.navigation.viewingHandle !== '') {
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
    if (this.settingsOpen || this.imageViewerOpen) { return; }
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
    if (!this.overlaysWeb() || isPostDetailUrl(this.navigation.currentUrl) || !this.autoHideBar || this.isWide || y < 48) {
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
    if (!this.webControllerReady || this.rawWeb || !isSiteUrl(this.navigation.currentUrl) || this.webWidth <= 0) { return; }
    if (this.navigation.viewingHandle !== '') { this.syncHeaderBlur(this.lastScrollY); }
    this.webScript(chromeInsetsScript(
      this.overlayTopInset(),
      this.overlaysWeb() ? this.bottomChromeHeight() : 0, this.webWidth
    )).catch((error: Error) => {
      hilog.error(DOMAIN, TAG, 'event=chrome_insets_failed error=%{public}s', error.message);
      this.toast($r('app.string.operation_failed'));
    });
  }

  private overlayTopInset(): number {
    if (!this.overlaysWeb() || this.topChromeHeight() === 0) { return 0; }
    if (this.navigation.viewingHandle !== '') { return 0; }
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
      if (key === 'original_images') { this.originalImages = value; }
      if (key === 'show_notification_badge') { this.showNotificationBadge = value; }
      if (key === DESKTOP_MODE_KEY) {
        this.desktopMode = value;
        this.applyUserAgent();
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
    if (this.navigation.hasError || this.fullScreen || this.imageViewerOpen || this.composer.sheetOpen || this.networkOpen ||
      this.settingsOpen || this.account.discovering || this.isMediaViewer()) {
      return false;
    }
    if (this.rawWeb) { return true; }
    // 原生导航页有悬浮底栏，胶囊会与标签栏重叠；这些页面已有头像/错误页入口。
    if (this.showsNativeNavigation()) {
      return false;
    }
    // 首屏尚未呈现网页入口时保留设置胶囊。
    if (!this.firstLoadDone) {
      return true;
    }
    // 已加载的普通网页（含账号信息页）保留网页自己的入口。
    return isSiteUrl(this.navigation.currentUrl) &&
      (this.navigation.currentPath === '/' || this.navigation.currentPath === '/login' || this.navigation.currentPath === '/signup' ||
        this.navigation.currentPath === '/i/flow/login' || this.navigation.currentPath === '/i/flow/signup');
  }

  private openNetworkSettings(): void {
    if (this.imageViewerOpen || this.composer.sheetOpen || this.fullScreen ||
      this.account.discovering) {
      return;
    }
    this.networkOpen = true;
  }

  private onNetworkOpenChanged(): void {
    if (!this.networkOpen) {
      this.flushNetworkReload();
    }
  }

  private modalBlocksNetworkReload(): boolean {
    return this.webModalOpen || this.imageViewerOpen || this.composer.sheetOpen || this.networkOpen ||
      this.account.discovering;
  }

  /** DoH changes apply to new resolutions; reload once after the panel closes. */
  private flushNetworkReload(): void {
    this.flushRenderRecovery();
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
    if (this.navigation.currentUrl.length === 0) {
      this.navigation.loadDocument(TWITTER_ROUTES[0]);
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
      this.webScript(appearanceScript(this.themeMode)).catch((error: Error) => {
        hilog.error(DOMAIN, TAG, 'event=appearance_apply_failed error=%{public}s', error.message);
        this.toast($r('app.string.operation_failed'));
      });
      this.webScript(chromeScript(navigation, usesNativeHeader(url), url))
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
      this.webScript(chromeFlagScript(navigation, usesNativeHeader(url), url))
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
    const pageUrl = this.navigation.currentUrl;
    try {
      this.webScript('Boolean(document.querySelector(\'input[autocomplete="username"],input[autocomplete="current-password"],input[autocomplete="one-time-code"]\'))')
        .then((raw: string) => {
          if (!this.pageAlive || this.navigation.currentUrl !== pageUrl || this.appBackground) { return; }
          this.authenticationPage = raw === 'true';
          if (this.authenticationPage) {
            this.unread.resetAccount(false);
            this.account.authenticationRequired();
          } else { this.account.discoverOwnProfile(); }
        }).catch((err: Error) => {
          hilog.warn(DOMAIN, TAG, 'event=auth_page_read_failed error=%{public}s', err.message);
        });
      this.webScript('document.title').then((raw: string) => {
        if (!this.pageAlive || this.navigation.currentUrl !== pageUrl || this.appBackground) { return; }
        const title: string = MainTabs.unquote(raw);
        this.pageTitle = MainTabs.stripSiteSuffix(title);
      }).catch((err: BusinessError) => { hilog.warn(DOMAIN, TAG, 'event=page_title_failed code=%{public}d', err.code); });
      if (!this.navigation.isNavigating && this.navigation.viewingHandle !== '' &&
        this.profileLayout === undefined && !this.settingsOpen) {
        this.webScript('(function(url){if(location.href!==url)return;window.__otProfileLayout="";' +
          'window.__otApplyTop&&window.__otApplyTop();})(' + JSON.stringify(pageUrl) + ')').catch((error: Error) => {
          hilog.warn(DOMAIN, TAG, 'event=profile_layout_read_failed code=%{public}d', (error as BusinessError).code);
        });
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'event=page_state_failed code=%{public}d', (err as BusinessError).code);
    }
    this.readHomeTab();
    this.account.readAvatar();
    if (this.isOwnProfile()) {
      this.account.readProfileDetails();
    }
    try {
      this.canGoBack = this.webCanGoBack();
    } catch (err) {
      this.canGoBack = false;
    }
  }

  // Keep the native Home switcher in step with whatever the page selected last
  // (the row is hidden, so this is the only place the state can come from).
  private readHomeTab(): void {
    const pageUrl = this.navigation.currentUrl;
    try {
      this.webScript(HOME_TAB_SCRIPT).then((raw: string) => {
        if (!this.pageAlive || this.navigation.currentUrl !== pageUrl || this.appBackground) { return; }
        const index: number = Number.parseInt(MainTabs.unquote(raw), 10);
        if (!Number.isNaN(index) && index >= 0) {
          this.homeTabIndex = index;
        }
      }).catch((err: BusinessError) => { hilog.warn(DOMAIN, TAG, 'event=home_tab_read_failed code=%{public}d', err.code); });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'event=home_tab_read_failed code=%{public}d', (err as BusinessError).code);
    }
  }

  private schedulePageStateRead(): void {
    if (this.pageStateTimer !== -1) { clearTimeout(this.pageStateTimer); }
    if (this.rawWeb || this.appBackground || !this.pageAlive) { return; }
    this.pageStateTimer = setTimeout(() => {
      this.pageStateTimer = -1;
      if (this.rawWeb || this.appBackground || !this.pageAlive) { return; }
      this.readPageState();
      this.unread.refreshBadges();
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
    if (!event.data.isMainFrame()) { return false; }
    // 图片主体拖放会被 ArkWeb 转成文件导航，必须在它提交空白错误页之前取消。
    if (/^file:/i.test(target)) {
      hilog.warn(DOMAIN, TAG, 'event=local_file_navigation_blocked');
      return true;
    }
    if (isSiteUrl(target) || isAuthUrl(target)) { return false; }
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

  @Builder
  navTitleBar() {
    if (this.settingsOpen) {
      NativeTopBar({ title: this.localized(this.settingsPage === 'appearance' ? $r('app.string.settings_appearance') :
        this.settingsPage === 'tabs' ? $r('app.string.settings_bottom_bar') :
        this.settingsPage === 'network' ? $r('app.string.settings_network') : $r('app.string.tab_settings')),
        showBack: this.settingsPage !== '', onBack: () => { this.settingsPage = ''; },
        immersiveMaterial: this.immersiveMaterial })
    } else if (this.isHomeRoot()) {
      this.homeTitleBar()
    } else {
      NativeTopBar({ title: this.headerTitle(), subtitle: this.subtitleMain(), showBack: this.showBack(),
        titleOpacity: this.navigation.viewingHandle !== '' ? this.profileTitleOpacity : 1,
        bannerButtons: this.profileBannerButtons(),
        immersiveMaterial: this.immersiveMaterial,
        onBack: () => {
          this.onBackPress();
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
    return this.settingsWeb || this.navigation.viewingHandle !== '' || isPostDetailUrl(this.navigation.currentUrl) || isSecondaryUrl(this.navigation.currentUrl) || (this.canGoBack && !this.isTabRoot());
  }

  // A profile is a tab root too: /<handle> is what the Profile tab loads, so
  // the shell must not offer a back arrow there even though the web history has
  // an entry behind it.
  private isTabRoot(): boolean {
    if (isTabRootPath(this.navigation.currentPath)) {
      return true;
    }
    return false;
  }

  private isHomeRoot(): boolean {
    return this.navigation.currentPath === '/' || this.navigation.currentPath === '/home';
  }

  @Builder
  accountPicture($$: AccountPictureState) {
    Stack() {
      SymbolGlyph($r('sys.symbol.person_crop_circle_fill'))
        .fontSize(32)
        .fontColor([$r('sys.color.ohos_id_color_text_secondary')])
      ForEach($$.path === '' ? [] : [$$.path], (path: string) => {
        Image(path)
          .width(32).height(32).borderRadius(16).objectFit(ImageFit.Cover)
          .onComplete(() => {
            if (path === this.account.avatarPath) { this.account.clearAvatarRetry(); }
          })
          .onError(() => this.account.avatarImageFailed(path))
      }, (path: string) => path)
    }
    .width(32).height(32)
  }

  // 首页与回复栏共用头像占位，网络图片未就绪或失败时圆框仍可见。
  @Builder
  accountAvatar() {
    Row() {
      this.accountPicture({ path: this.account.avatarPath })
    }
    .width(TOUCH_TARGET)
    .height(32)
    .justifyContent(FlexAlign.Center)
    // The picture is 32vp tall; the touch target stays 48vp.
    .responseRegion({ x: 0, y: -S8, width: '100%', height: TOUCH_TARGET })
    // Pointer devices (2in1 / tablet with a mouse) get the hover the phone
    // never needed.
    .hoverEffect(HoverEffect.Highlight)
    .accessibilityText($r('app.string.menu_view_profile'))
    .accessibilityLevel('yes')
    .onClick(() => { this.openOwnProfile(); })
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
    if (isPostDetailUrl(this.navigation.currentUrl)) { return this.localized($r('app.string.post')); }
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
    if (this.currentIndex === 2 && this.navigation.currentPath === '/notifications') {
      this.headerIconButton($r('sys.symbol.gearshape'), $r('app.string.menu_notification_settings'),
        () => {
          this.navigation.loadWeb(TWITTER_NOTIF_SETTINGS);
        })
    } else if (this.currentIndex === 3 &&
      (this.navigation.currentPath === '/messages' || this.navigation.currentPath === '/i/chat')) {
      // x.com has no separate direct-message settings page any more (its
      // /settings/messages route is gone), so this opens the settings root the
      // stock app's gear leads to as well.
      this.headerIconButton($r('sys.symbol.gearshape'), $r('app.string.menu_settings'), () => {
        this.openSettings();
      })
    }
  }

  private isOwnProfile(): boolean {
    return this.account.ownHandle !== '' &&
      this.navigation.viewingHandle.toLowerCase() === this.account.ownHandle.toLowerCase();
  }

  private headerButtonMaterial(): uiMaterial.Material | undefined {
    if (!this.immersiveMaterial) {
      return undefined;
    }
    try {
      if (canIUse('SystemCapability.ArkUI.ArkUI.Full') && uiMaterial.isImmersiveMaterialSupported()) {
        if (this.profileBannerButtons()) {
          return new uiMaterial.ImmersiveMaterial({
            style: uiMaterial.ImmersiveStyle.REGULAR,
            materialColor: '#59000000',
            interactive: true
          });
        }
        return new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
          interactive: true
        });
      }
    } catch (e) {
      return undefined;
    }
    return undefined;
  }

  @Builder
  headerIconButton(symbol: Resource, label: Resource, action: () => void) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph(symbol)
        .fontSize(20)
        .fontColor([this.profileBannerButtons() ? Color.White : $r('sys.color.ohos_id_color_text_primary')])
    }
    .width(40)
    .height(40)
    .responseRegion({ x: -4, y: -4, width: TOUCH_TARGET, height: TOUCH_TARGET })
    .backgroundColor(this.profileBannerButtons() ? '#59000000' : $r('sys.color.comp_background_tertiary'))
    .backgroundBlurStyle(this.profileBannerButtons() ? BlurStyle.COMPONENT_THICK : BlurStyle.NONE,
      { colorMode: ThemeColorMode.DARK })
    .systemMaterial(this.headerButtonMaterial())
    .accessibilityText(label)
    .accessibilityLevel('yes')
    .onClick(action)
  }

  @Builder
  nativeTabs() {
    NativeBottomBar({ currentIndex: this.currentIndex,
      notifications: this.showNotificationBadge ? this.unread.unreadNotifications : 0,
      messages: this.unread.unreadMessages, wide: this.isWide,
      labels: [this.tabLabel(0), this.tabLabel(1), this.tabLabel(2), this.tabLabel(3), this.tabLabel(4), this.tabLabel(5)],
      enabledTabs: this.enabledTabs,
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
    if (this.imageViewerOpen) {
      // 图片查看器在 TabContent 容器内直出支持平滑进出场的悬浮胶囊
    } else if (this.settingsOpen) {
      Row() {
        this.nativeTabs()
      }
      .width('100%')
      .height('100%')
      .padding({ left: 4, right: 4 })
    } else if (isPostDetailUrl(this.navigation.currentUrl)) {
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

  /** 面板立即显示，网页回复上下文在面板内加载，不再等待详情页恢复原帖。 */
  private replyToPost(): void {
    const postId: string = this.navigation.currentPath.substring(this.navigation.currentPath.lastIndexOf('/') + 1);
    this.composer.openReply(postId);
  }

  @Builder
  replyBar() {
    Row({ space: S12 }) {
      this.accountPicture({ path: this.account.avatarPath })
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
  composeFab() {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph($r('sys.symbol.square_and_pencil'))
        .fontSize(22)
        .fontColor([$r('sys.color.ohos_id_color_text_secondary')])
    }
    .width(52)
    .height(52)
    .backgroundColor(Color.Transparent)
    // 内容区悬浮按钮不在光感支持区域内，保留普通系统模糊。
    .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
    .margin({ right: S16, bottom: S16 + (this.overlaysWeb() ? this.bottomChromeHeight() : 0) })
    .scale({ x: this.barsCollapsed ? 0.01 : 1, y: this.barsCollapsed ? 0.01 : 1 })
    .opacity(this.barsCollapsed ? 0 : 1)
    .animation({ duration: 240, curve: Curve.FastOutSlowIn })
    .hitTestBehavior(this.barsCollapsed ? HitTestMode.None : HitTestMode.Default)
    .accessibilityText($r('app.string.compose_title'))
    .accessibilityLevel('yes')
    .onClick(() => { this.composer.openCompose(); })
  }

  @Builder
  settingsMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.settings_network') })
        .onClick(() => { this.openSettings('network'); })
      MenuItem({ content: $r('app.string.settings_appearance') })
        .onClick(() => { this.openSettings('appearance'); })
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
      Text(this.navigation.failure === 'render' ? $r('app.string.render_error_title') :
        this.navigation.failure === 'policy' ? $r('app.string.policy_error_title') : $r('app.string.error_title'))
        .fontSize(17)
        .fontFamily(FONT_FAMILY)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
      Text(this.navigation.failure === 'render' ? $r('app.string.render_error_message') :
        this.navigation.failure === 'policy' ? $r('app.string.policy_error_message') : $r('app.string.error_message'))
        .fontSize(14)
        .fontFamily(FONT_FAMILY)
        .textAlign(TextAlign.Center)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
      Button($r('app.string.retry'))
        .type(ButtonType.Capsule)
        .fontFamily(FONT_FAMILY)
        .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
        .margin({ top: S8 })
        .enabled(!this.retrying)
        .onClick(() => this.reloadCurrent())
      if (this.settingsWeb) {
        Button($r('app.string.back'))
          .type(ButtonType.Capsule)
          .fontFamily(FONT_FAMILY)
          .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .onClick(() => {
            this.settingsWeb = false;
            this.settingsOpen = true;
            this.navigation.failure = 'none';
          })
      }
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
  webView(session: number) {
    Web({ src: this.webSource, controller: this.controller, renderMode: RenderMode.ASYNC_RENDER })
      .width('100%')
      .height('100%')
      // 网页遮罩和背景延伸至手势区，交互元素由网页安全区样式避让。
      .expandSafeArea([SafeAreaType.SYSTEM], this.navigation.viewingHandle !== '' && this.showsNativeNavigation()
        ? [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM] : [SafeAreaEdge.BOTTOM])
      // Injected at document start, so the page's history hook always finds it.
      .javaScriptProxy({
        object: this.bridge,
        name: 'otNative',
        methodList: ['onUrlChange', 'onImages', 'onTheme', 'onProfileLayout', 'onWebModal'],
        controller: this.controller
      })
      .onControllerAttached(() => {
        if (!this.pageAlive || session !== this.webSession || !this.webNetworkReady) { return; }
        this.webControllerReady = true;
        this.documentStarted(this.webSource);
        this.applyUserAgent();
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        if (!this.webImages) { this.webImages = new WebImageDownloads(this.controller, context.cacheDir); }
        try {
          this.downloadDelegate = installDownloads(this.controller, context,
            (result: string) => { this.reportDownload(result); }, this.webImages);
        } catch (err) {
          hilog.error(DOMAIN, TAG, 'event=download_delegate_failed code=%{public}d', (err as BusinessError).code);
        }
        this.onIncomingContentChanged();
      })
      .onWindowNew((event: OnWindowNewEvent) => {
        event.handler.setWebController(null);
        if (session !== this.webSession || !this.webControllerReady) { return; }
        if (isAuthUrl(event.targetUrl)) {
          this.navigation.loadDocument(event.targetUrl);
        } else if (isSiteUrl(event.targetUrl)) {
          this.navigation.loadWeb(event.targetUrl);
        } else if (/^https?:\/\//i.test(event.targetUrl)) {
          this.openExternal(event.targetUrl);
        } else { this.toast($r('app.string.operation_failed')); }
      })
      .onLoadIntercept((event) => session !== this.webSession || !this.webControllerReady ||
        (event.data.isMainFrame() && this.navigation.interceptDocument()) || this.interceptExternal(event))
      .onFullScreenEnter((event) => { if (session === this.webSession && this.webControllerReady) { this.enterFullScreen(event.handler); } })
      .onFullScreenExit(() => { if (session === this.webSession) { this.exitFullScreen(); } })
      .onContextMenuShow((event) => {
        if (session !== this.webSession || !this.webControllerReady || !event || this.rawWeb || !event.param.existsImageContents() || !isSiteUrl(this.webUrl())) { return false; }
        const media = resolveMedia(event.param.getSourceUrl());
        if (!media || this.imageViewerOpen) { return false; }
        this.imageItems = [media];
        this.imagePost = { postId: '', postUrl: '' };
        this.imageIndex = 0;
        this.tick();
        this.imageViewerOpen = true;
        event.result.closeContextMenu();
        return true;
      })
      .javaScriptAccess(true)
      .javaScriptOnDocumentStart([{ script: this.rawWeb ? '' : WEB_RESPONSE_SCRIPT + MEDIA_ACTION_RESPONSE_SCRIPT + chromeDocumentStartScript(true),
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
      .textZoomRatio(this.fontScale)
      .onTouch((event: TouchEvent) => { this.handleWebTouch(event); })
      .onScroll((event: OnScrollEvent) => { this.handleWebScroll(event.yOffset); })
      .onAreaChange((_old: Area, area: Area) => {
        if (session !== this.webSession) { return; }
        if (this.webWidth !== Number(area.width)) { this.resetProfileLayout(); }
        this.webWidth = Number(area.width);
        this.syncChromeInsets();
      })
      .onProgressChange((event) => {
        if (session !== this.webSession || !this.webNetworkReady) { return; }
        if (event) {
          this.navigation.progress = event.newProgress;
        }
      })
      .onPageBegin((event) => {
        if (session !== this.webSession || !this.webControllerReady || !this.webNetworkReady) { return; }
        if (!isSiteUrl(event.url) && !isAuthUrl(event.url)) { return; }
        this.retrying = false;
        this.documentStarted(event.url);
        this.updateWebModal(false);
        this.resetProfileLayout();
        this.navigation.failure = 'none';
      })
      .onPageEnd((event) => {
        if (session !== this.webSession || !this.webControllerReady || !this.webNetworkReady) { return; }
        this.documentLoading = false;
        this.pendingDocumentUrl = '';
        this.retrying = false;
        this.navigation.progress = 100;
        this.refreshing = false;
        this.finishFirstLoad();
        if (!isSiteUrl(event.url) && !isAuthUrl(event.url)) { return; }
        // 加载失败也会结束文档加载，不能据此启动账号发现或消费待处理链接。
        if (this.navigation.hasError) { return; }
        if (this.webUrl() !== event.url) { return; }
        this.failedWebUrl = '';
        if (!this.rawWeb && event && isSiteUrl(event.url)) {
          this.webScript(MEDIA_CLICK_SCRIPT).catch((error: Error) => {
            hilog.error(DOMAIN, TAG, 'event=image_bridge_failed error=%{public}s', error.message);
            this.toast($r('app.string.operation_failed'));
          });
        }
        this.saveWebSession();
        if (event && event.url) {
          this.syncFromUrl(event.url, true);
          this.applyPageChrome(event.url);
        }
        if (this.appBackground && !this.rawWeb) {
          this.webScript(chromeActiveScript(false)).catch((err: BusinessError) => {
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
        if (this.account.ownHandle === '') {
          this.account.discoverOwnProfile();
        }
      })
      .onErrorReceive((event) => {
        if (session !== this.webSession || !this.webControllerReady || !this.webNetworkReady) { return; }
        const code = event.error.getErrorCode();
        if (!event.request.isMainFrame() || code === -3) { return; }
        const failedUrl = event.request.getRequestUrl();
        const pageUrl = this.pendingDocumentUrl;
        // 图片下载与旧页面错误不能覆盖当前文档，也不能成为整页重试地址。
        if (pageUrl === '' || (!isSiteUrl(failedUrl) && !isAuthUrl(failedUrl)) ||
          failedUrl.split('#')[0] !== pageUrl.split('#')[0]) {
          hilog.debug(DOMAIN, TAG, 'event=web_error_ignored reason=no_matching_document code=%{public}d session=%{public}d', code, session);
          return;
        }
        this.failedWebUrl = failedUrl;
        this.pendingDocumentUrl = '';
        this.retrying = false;
        hilog.error(DOMAIN, TAG, 'event=main_frame_failed code=%{public}d session=%{public}d', code, session);
        this.navigation.failure = 'document';
        this.navigation.progress = 100;
        this.refreshing = false;
        this.finishFirstLoad();
        if (this.incomingContent.kind !== '') {
          this.incomingContent = { kind: '', value: '' };
          this.toast($r('app.string.incoming_failed'));
        }
      })
      .onRenderExited((event) => {
        if (!this.pageAlive || session !== this.webSession || !this.webNetworkReady) { return; }
        hilog.error(DOMAIN, TAG, 'event=render_exit session=%{public}d viewer=%{public}s detail=%{public}s',
          session, String(this.imageViewerOpen), JSON.stringify(event));
        this.renderExited();
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
        if (this.navigation.progress < 100 && !this.navigation.hasError) {
          Progress({ value: this.navigation.progress, total: 100, type: ProgressType.Linear })
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
                  ForEach([this.webSession], (session: number) => { this.webView(session) }, (session: number) => session.toString())
                }
              }.width('100%').height('100%')
            }
            .width('100%')
            .height('100%')
            // Web 位于刷新容器内，两者须使用相同的绘制扩展边界。
            .expandSafeArea([SafeAreaType.SYSTEM], this.navigation.viewingHandle !== '' && this.showsNativeNavigation()
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

      if (this.navigation.hasError) { this.errorState() }

      if ((!this.firstLoadDone || this.documentLoading) && !this.navigation.hasError) {
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
      if (this.account.discovering) {
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
      if (this.showsNativeNavigation() && this.isHomeRoot() && !this.navigation.hasError && this.firstLoadDone) {
        this.composeFab()
      }
    }
    .width('100%')
    .height('100%')
    .flexGrow(1)
    .flexShrink(1)
    // 资料横幅及其遮罩一起延伸至状态栏；其他页面沿用底部扩展边界。
    .expandSafeArea([SafeAreaType.SYSTEM], this.navigation.viewingHandle !== '' && this.showsNativeNavigation()
      ? [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM] : [SafeAreaEdge.BOTTOM])
    .backgroundColor($r('sys.color.ohos_id_color_background'))
  }

  @Builder
  composeSheet() {
    Column({ space: 0 }) {
    if (this.composer.webComposer) {
      Row() {
        Button($r('app.string.close_editor')).onClick(() => { this.composer.closeCompose(); })
        Blank()
        if (this.composer.draft !== '') {
          Button($r('app.string.compose_copy_draft')).onClick(() => { this.composer.copyComposeDraft(); })
        }
      }.width('100%').padding(S8)
    }
    Stack({ alignContent: Alignment.TopStart }) {
      // x.com's own composer, kept invisible under the native panel. It exists
      // only so the native Post button submits through the real web session;
      // if it has to surface (media, polls, threads, or an undrivable editor)
      // it is revealed and the native panel steps aside.
      if (this.webNetworkReady) {
      Web({ src: this.composer.composeUrl, controller: this.composer.composeController })
        .width('100%')
        .height('100%')
        .opacity(this.composer.webComposer ? 1 : 0)
        .onControllerAttached(() => {
          try {
            this.composer.composeController.setCustomUserAgent(this.userAgent());
            this.composeDownloadDelegate = installDownloads(this.composer.composeController,
              this.getUIContext().getHostContext() as common.UIAbilityContext,
              (result: string) => { this.reportDownload(result); });
          } catch (err) {
            hilog.error(DOMAIN, TAG, 'event=compose_controller_failed code=%{public}d', (err as BusinessError).code);
            this.composer.controllerFailed();
          }
        })
        .onLoadIntercept((event) => this.interceptExternal(event))
        .onPageBegin(() => { this.composer.pageStarted(); })
        .onPageEnd(() => {
          this.composer.composeController.runJavaScript(appearanceScript(this.themeMode)).catch((error: Error) => {
            hilog.error(DOMAIN, TAG, 'event=compose_appearance_failed error=%{public}s', error.message);
            this.toast($r('app.string.operation_failed'));
          });
          this.composer.pageFinished();
        })
        .onFullScreenEnter((event) => { this.enterFullScreen(event.handler); })
        .onFullScreenExit(() => { this.exitFullScreen(); })
        .onRenderExited(() => {
          this.composer.renderExited();
        })
        .javaScriptAccess(true)
        .javaScriptOnDocumentStart([{ script: WEB_RESPONSE_SCRIPT,
          scriptRules: ['https://x.com', 'https://www.x.com', 'https://twitter.com', 'https://www.twitter.com'] }])
        .domStorageAccess(true)
        .databaseAccess(true)
        .fileAccess(false)
        .mixedMode(MixedMode.Compatible)
        .cacheMode(CacheMode.Default)
        .overScrollMode(OverScrollMode.NEVER)
        .zoomAccess(false)
        .darkMode(WebDarkMode.Auto)
        .textZoomRatio(this.fontScale)
        .onShowFileSelector((event) => {
          return this.openFileSelector(event);
        })
      }

      ComposerPanel({ draft: this.composer.draft, ready: this.composer.composeReady, posting: this.composer.posting,
        uncertain: this.composer.postUncertain, preparing: this.composer.composePreparing, loading: this.composer.composeLoading,
        hasOwner: this.composer.composeOwner !== '', message: this.composer.composeMessage,
        onClose: () => { this.composer.closeCompose(); }, onPost: () => { this.composer.postFromSheet(); },
        onMore: () => { this.composer.openWebComposer(); }, onVerify: () => { this.composer.resolveUnknownPost(); },
        onDraftChange: (value: string) => { this.composer.changeDraft(value); }, onComposeKey: (event: KeyEvent) => this.composer.composeKey(event) })
      .visibility(this.composer.webComposer ? Visibility.Hidden : Visibility.Visible)
      if (this.composer.webComposer && this.composer.composeLoading) {
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
    .onKeyEvent((event: KeyEvent) => this.composer.composeKey(event))
    .onDisAppear(() => { this.flushNetworkReload(); })
  }

  /** 桥接数据属于网页输入，完整校验通过后才接管当前点击。 */
  private openImages(payload: string): boolean {
    if (this.rawWeb || this.imageViewerOpen || this.composer.sheetOpen || this.fullScreen || !isSiteUrl(this.webUrl())) { return false; }
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
      let post: MediaPostState = { postId: '', postUrl: '' };
      if (data.postId !== undefined) {
        if (typeof data.postId !== 'string' || !/^\d+$/.test(data.postId) || typeof data.postUrl !== 'string' ||
          !isPostDetailUrl(data.postUrl) || !data.postUrl.endsWith('/status/' + data.postId)) { return false; }
        for (const value of [data.liked, data.bookmarked, data.reposted]) {
          if (value !== undefined && typeof value !== 'boolean') { return false; }
        }
        post = { postId: data.postId, postUrl: data.postUrl, liked: data.liked,
          bookmarked: data.bookmarked, reposted: data.reposted };
      }
      if (data.origin !== undefined) {
        const origin = data.origin;
        if (post.postId === '' || origin.url !== this.webUrl() || !isSiteUrl(origin.url) ||
          typeof origin.scrollSelector !== 'string' ||
          ![origin.x, origin.y, origin.scrollTop, origin.scrollLeft].every((value: number) =>
            typeof value === 'number' && Number.isFinite(value))) { return false; }
      }
      this.imageItems = items;
      this.imageIndex = data.index;
      this.imagePost = post;
      this.imageOrigin = data.origin;
      this.tick();
      this.imageViewerOpen = true;
      return true;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'event=image_payload_rejected error=%{public}s', JSON.stringify(error));
      return false;
    }
  }

  /** 账号、网页实例和查看会话共同约束迟到结果。 */
  private imageSessionCurrent(session: number): boolean {
    return session === this.imageSession && this.imageViewerOpen && this.pageAlive && !this.appBackground &&
      !this.rawWeb && !this.authenticationPage && this.webControllerReady && this.webSession === this.imageWebSession &&
      this.account.ownHandle.toLowerCase() === this.imageOwner;
  }

  /** 回执可能早于节点重建，仅更新其包含的状态，避免清空其他已知按钮。 */
  private applyImagePostState(result: MediaActionResult, replace: boolean = true): void {
    this.imagePost = { postId: this.imagePost.postId, postUrl: this.imagePost.postUrl,
      liked: replace || result.liked !== undefined ? result.liked : this.imagePost.liked,
      bookmarked: replace || result.bookmarked !== undefined ? result.bookmarked : this.imagePost.bookmarked,
      reposted: replace || result.reposted !== undefined ? result.reposted : this.imagePost.reposted };
  }

  /** 网格先展示图片，再等待原帖提供操作控件。 */
  private async prepareImagePost(session: number): Promise<void> {
    const postId = this.imagePost.postId;
    let generation = this.navigation.navigationGeneration;
    try {
      let result = JSON.parse(MainTabs.unquote(await this.webScript(mediaActionScript(postId, 0, 'read', false)))) as MediaActionResult;
      if (!this.imageSessionCurrent(session) || generation !== this.navigation.navigationGeneration) { return; }
      if (result.status !== 'ready' && this.imageOrigin !== undefined) {
        this.imageNavigation = generation + 1;
        await this.navigation.loadDocument(this.imagePost.postUrl);
        generation = this.imageNavigation;
        if (!this.imageSessionCurrent(session) || generation !== this.navigation.navigationGeneration) { return; }
      }
      const deadline = Date.now() + PROFILE_TIMEOUT_MS;
      while (this.imageSessionCurrent(session) && generation === this.navigation.navigationGeneration) {
        if (result.postId !== postId) { throw new Error('Image post response mismatch'); }
        if (result.status === 'ready') {
          this.applyImagePostState(result);
          this.imagePostReady = true;
          return;
        }
        if (Date.now() >= deadline) { throw new Error('Image post context unavailable'); }
        await new Promise<void>((resolve) => { setTimeout(resolve, 150); });
        if (!this.imageSessionCurrent(session) || generation !== this.navigation.navigationGeneration) { return; }
        result = JSON.parse(MainTabs.unquote(await this.webScript(mediaActionScript(postId, 0, 'read', false)))) as MediaActionResult;
        if (!this.imageSessionCurrent(session) || generation !== this.navigation.navigationGeneration) { return; }
      }
    } catch (error) {
      if (!this.imageSessionCurrent(session)) { return; }
      hilog.warn(DOMAIN, TAG, 'event=image_post_context_failed error=%{public}s', JSON.stringify(error));
      this.toast($r('app.string.operation_failed'));
    }
  }

  /** 关闭后只恢复本查看会话主动加载的页面，不能覆盖用户的新导航。 */
  private async restoreImageOrigin(origin: MediaOrigin, postUrl: string, session: number,
    generation: number): Promise<void> {
    const owner = this.imageOwner;
    const webSession = this.imageWebSession;
    try {
      if (!this.pageAlive || !this.webControllerReady || this.webSession !== webSession ||
        this.account.ownHandle.toLowerCase() !== owner) { return; }
      this.controller.stop();
      if (this.webUrl() === postUrl && this.webCanGoBack()) { this.controller.backward(); }
      else if (this.webUrl() !== origin.url) {
        await this.navigation.loadDocument(origin.url);
        generation = this.navigation.navigationGeneration;
      } else {
        this.documentLoading = false;
        this.pendingDocumentUrl = '';
        this.finishFirstLoad();
      }
      const deadline = Date.now() + PROFILE_TIMEOUT_MS;
      while (session === this.imageSession && !this.imageViewerOpen && this.pageAlive && !this.appBackground &&
        this.webControllerReady && this.webSession === webSession && this.account.ownHandle.toLowerCase() === owner &&
        generation === this.navigation.navigationGeneration) {
        const result = MainTabs.unquote(await this.webScript(restoreMediaOriginScript(origin)));
        if (session !== this.imageSession || this.imageViewerOpen || !this.pageAlive || this.appBackground ||
          generation !== this.navigation.navigationGeneration ||
          this.webSession !== webSession || this.account.ownHandle.toLowerCase() !== owner) { return; }
        if (result === 'restored') { return; }
        if (Date.now() >= deadline) { throw new Error('Image origin restoration timed out'); }
        await new Promise<void>((resolve) => { setTimeout(resolve, 150); });
      }
    } catch (error) {
      if (session !== this.imageSession || !this.pageAlive || this.webSession !== webSession ||
        this.account.ownHandle.toLowerCase() !== owner || generation !== this.navigation.navigationGeneration) { return; }
      hilog.warn(DOMAIN, TAG, 'event=image_origin_restore_failed error=%{public}s', JSON.stringify(error));
      this.toast($r('app.string.operation_failed'));
    }
  }

  /** 显式查看原帖后保留帖子页面，不再恢复媒体网格。 */
  private async viewImagePost(): Promise<void> {
    const session = this.imageSession;
    if (!this.imageSessionCurrent(session) || this.imagePost.postUrl === '') { return; }
    const url = this.imagePost.postUrl;
    try {
      if (this.webUrl() !== url) {
        this.imageNavigation = this.navigation.navigationGeneration + 1;
        await this.navigation.loadDocument(url);
        if (!this.imageSessionCurrent(session) || this.navigation.navigationGeneration !== this.imageNavigation) { return; }
      }
      this.imageOrigin = undefined;
      this.imageViewerOpen = false;
    } catch (error) {
      if (!this.imageSessionCurrent(session)) { return; }
      hilog.warn(DOMAIN, TAG, 'event=image_view_post_failed error=%{public}s', JSON.stringify(error));
      this.toast($r('app.string.operation_failed'));
    }
  }

  /** 回执缺失只回读一次，不重复提交可能已成功的动作。 */
  private async readBackImageAction(session: number, id: number, action: string, target: boolean): Promise<MediaActionResult> {
    const postId = this.imagePost.postId;
    const unknown: MediaActionResult = { requestId: id, postId: postId, status: 'unknown', target: target };
    this.imagePostReady = false;
    const previousGeneration = this.navigation.navigationGeneration;
    await this.webScript('window.__otMediaReadbackBlocked=true');
    if (!this.imageSessionCurrent(session) || id !== this.imageActionSequence ||
      previousGeneration !== this.navigation.navigationGeneration) { return { requestId: id, postId: postId, status: 'cancelled' }; }
    if (this.webUrl() === this.imagePost.postUrl) {
      this.imageNavigation = ++this.navigation.navigationGeneration;
      this.documentStarted(this.imagePost.postUrl);
      this.controller.refresh(true);
    } else {
      this.imageNavigation = this.navigation.navigationGeneration + 1;
      await this.navigation.loadDocument(this.imagePost.postUrl);
    }
    const generation = this.imageNavigation;
    if (!this.imageSessionCurrent(session) || id !== this.imageActionSequence ||
      generation !== this.navigation.navigationGeneration) { return { requestId: id, postId: postId, status: 'cancelled' }; }
    const deadline = Date.now() + PROFILE_TIMEOUT_MS;
    while (this.imageSessionCurrent(session) && id === this.imageActionSequence && generation === this.navigation.navigationGeneration) {
      const result = JSON.parse(MainTabs.unquote(await this.webScript(mediaActionScript(postId, id, 'read', false)))) as MediaActionResult;
      if (!this.imageSessionCurrent(session) || id !== this.imageActionSequence ||
        generation !== this.navigation.navigationGeneration) { return { requestId: id, postId: postId, status: 'cancelled' }; }
      // 新文档完成后才接受状态，不能把旧页的乐观变色当作回读结果。
      if (!this.documentLoading && this.webUrl() === this.imagePost.postUrl && result.postId === postId && result.status === 'ready') {
        this.applyImagePostState(result);
        this.imagePostReady = true;
        const current = action === 'like' ? result.liked : action === 'bookmark' ? result.bookmarked : result.reposted;
        if (current === target) { result.status = 'done'; return result; }
        return unknown;
      }
      if (Date.now() >= deadline) { return unknown; }
      await new Promise<void>((resolve) => { setTimeout(resolve, 150); });
    }
    return { requestId: id, postId: postId, status: 'cancelled' };
  }

  /** 服务回执确认结果，旧节点是否变色不影响已确认的操作。 */
  private async imagePostAction(action: string): Promise<MediaActionResult> {
    const id = ++this.imageActionSequence;
    const postId = this.imagePost.postId;
    const owner = this.account.ownHandle;
    const generation = this.navigation.navigationGeneration;
    const url = this.navigation.currentUrl;
    const session = this.imageSession;
    const current = action === 'like' ? this.imagePost.liked : action === 'bookmark' ? this.imagePost.bookmarked : this.imagePost.reposted;
    const target = !current;
    const cancelled: MediaActionResult = { requestId: id, postId: postId, status: 'cancelled' };
    const deadline = Date.now() + PROFILE_TIMEOUT_MS;
    let start = true;
    while (this.imageSessionCurrent(session) && id === this.imageActionSequence &&
      this.account.ownHandle.toLowerCase() === owner.toLowerCase() &&
      this.navigation.navigationGeneration === generation && this.navigation.currentUrl === url && this.imagePost.postId === postId) {
      let result: MediaActionResult;
      try {
        const raw = MainTabs.unquote(await this.webScript(mediaActionScript(postId, id, action, start, target)));
        if (!this.imageSessionCurrent(session) || id !== this.imageActionSequence ||
          this.navigation.navigationGeneration !== generation || this.navigation.currentUrl !== url) { return cancelled; }
        result = JSON.parse(raw) as MediaActionResult;
      } catch (error) {
        if (!this.imageSessionCurrent(session) || id !== this.imageActionSequence ||
          this.navigation.navigationGeneration !== generation) { return cancelled; }
        hilog.warn(DOMAIN, TAG, 'event=image_post_receipt_unreadable');
        break;
      }
      if (result.requestId !== id || result.postId !== postId) { throw new Error('Image action response mismatch'); }
      if (result.status === 'failed' || (start && result.status === 'unavailable')) { return result; }
      if (result.status === 'done') {
        hilog.info(DOMAIN, TAG, 'event=image_post_action_confirmed action=%{public}s', action);
        return result;
      }
      if (result.status === 'quote') {
        const quoteUrl = result.quoteUrl;
        if (!quoteUrl || !isSiteUrl(quoteUrl) || pathOf(quoteUrl) !== '/compose/post') { throw new Error('Quote route unavailable'); }
        await this.webScript('document.dispatchEvent(new KeyboardEvent("keydown",{key:"Escape",bubbles:true}))');
        if (!this.imageSessionCurrent(session) || id !== this.imageActionSequence ||
          this.navigation.navigationGeneration !== generation || this.navigation.currentUrl !== url) { return cancelled; }
        this.imageViewerOpen = false;
        this.composer.openQuote(quoteUrl, owner);
        return result;
      }
      if (Date.now() >= deadline) { break; }
      start = false;
      await new Promise<void>((resolve) => { setTimeout(resolve, 150); });
    }
    if (!this.imageSessionCurrent(session) || id !== this.imageActionSequence ||
      this.navigation.navigationGeneration !== generation || this.navigation.currentUrl !== url) { return cancelled; }
    if (action === 'quote') { return { requestId: id, postId: postId, status: 'unknown' }; }
    return this.readBackImageAction(session, id, action, target);
  }

  @Builder
  imageViewer() {
    NativeImageViewer({ items: this.imageItems, index: $imageIndex,
      originalImages: this.originalImages, chromeVisible: $imageChromeVisible, dragging: $imageDragging,
      detailsVisible: $imageDetailsVisible, currentLoadedFile: $imageCurrentFile, busy: $imageBusy,
      moreOpen: $imageMoreOpen, footerOffset: FLOATING_BAR_HEIGHT + this.bottomInset,
      shareTrigger: this.imageShareTrigger, immersiveMaterial: this.immersiveMaterial,
      topInset: this.topInset,
      hasPost: this.imagePost.postId !== '', onViewPost: () => { this.viewImagePost(); },
      analyzerSelecting: $imageAnalyzerSelecting,
      cancelAnalyzerTrigger: this.imageAnalyzerCancelTrigger,
      webImages: this.webImages, onClose: () => { this.imageViewerOpen = false; },
      onRecover: () => { this.recoverMediaWeb(false); }, onWeb: () => { this.recoverMediaWeb(true); } })
  }

  /** 图片画布与常驻网页共用宿主，只切换现有 HDS 底栏的内容。 */
  private imageViewerChanged(): void {
    const session = ++this.imageSession;
    const previousAction = this.imageActionSequence;
    this.imageActionSequence++;
    this.imageDetailsVisible = false;
    this.imageRepostMenuOpen = false;
    this.imageMoreOpen = false;
    this.imageBusy = false;
    this.imageCurrentFile = undefined;
    this.imageChromeVisible = true;
    this.imageDragging = false;
    this.imageAnalyzerSelecting = false;
    this.imageAnalyzerCancelTrigger = 0;
    this.imagePostReady = false;
    this.imageUncertainActions = [];
    if (this.imageViewerOpen) {
      this.imageOwner = this.account.ownHandle.toLowerCase();
      this.imageWebSession = this.webSession;
      this.imageNavigation = -1;
      if (this.imagePost.postId !== '') { this.prepareImagePost(session); }
    } else {
      if (this.webControllerReady) {
        this.webScript('if(window.__otMediaAction&&window.__otMediaAction.id===' + previousAction +
          '){window.__otMediaAction=null;document.dispatchEvent(new KeyboardEvent("keydown",{key:"Escape",bubbles:true}));}')
          .catch((error: Error) => {
            hilog.warn(DOMAIN, TAG, 'event=image_action_cancel_failed code=%{public}d', (error as BusinessError).code);
          });
      }
      const origin = this.imageOrigin;
      this.imageOrigin = undefined;
      if (origin !== undefined && this.imageNavigation === this.navigation.navigationGeneration) {
        const generation = ++this.navigation.navigationGeneration;
        this.restoreImageOrigin(origin, this.imagePost.postUrl, session, generation);
      }
      this.imageNavigation = -1;
      setTimeout(() => this.flushRenderRecovery(), 0);
    }
  }

  private dismissImageDetails(): boolean {
    if (!this.imageDetailsVisible) { return false; }
    this.imageDetailsVisible = false;
    return true;
  }

  private cancelImageAnalyzer(): boolean {
    if (!this.imageAnalyzerSelecting) { return false; }
    this.imageAnalyzerCancelTrigger++;
    return true;
  }

  private async performImagePostAction(action: string): Promise<void> {
    if (this.dismissImageDetails() || this.imageBusy || !this.imagePostReady || this.imageUncertainActions.includes(action)) { return; }
    const session = this.imageSession;
    this.imageBusy = true;
    try {
      const result = await this.imagePostAction(action);
      if (!this.imageSessionCurrent(session) || result.status === 'cancelled' || result.status === 'quote') { return; }
      if (result.status === 'done') { this.applyImagePostState(result, false); }
      else if (result.status === 'unknown') {
        this.imageUncertainActions = [...this.imageUncertainActions, action];
        this.toast($r('app.string.media_action_unknown'));
      } else { this.toast($r('app.string.operation_failed')); }
    } catch (error) {
      if (!this.imageSessionCurrent(session)) { return; }
      hilog.error(DOMAIN, TAG, 'event=image_post_action_failed action=%{public}s error=%{public}s', action, JSON.stringify(error));
      this.imageUncertainActions = [...this.imageUncertainActions, action];
      this.toast($r('app.string.media_action_unknown'));
    } finally { if (session === this.imageSession) { this.imageBusy = false; } }
  }

  private imageViewerBarMaterial(): uiMaterial.Material | undefined {
    if (!this.immersiveMaterial) {
      return undefined;
    }
    try {
      if (canIUse('SystemCapability.ArkUI.ArkUI.Full') && uiMaterial.isImmersiveMaterialSupported()) {
        return new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.REGULAR,
          materialColor: '#66000000',
          interactive: true
        });
      }
    } catch (e) {
      return undefined;
    }
    return undefined;
  }

  @Builder
  imagePostButton(symbol: Resource, label: Resource, id: string, selected: boolean, action: () => void) {
    Row() {
      SymbolGlyph(symbol).fontSize(22)
        .fontColor([selected ? (id === 'image-bookmark' ? $r('sys.color.ohos_id_color_emphasize') : '#F91880') : Color.White])
    }
    .id(id)
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(20)
    .backgroundColor(Color.Transparent)
    .enabled(!this.imageBusy && (id === 'image-share' ? this.imageCurrentFile !== undefined :
      this.imagePostReady && (id === 'image-like' ? typeof this.imagePost.liked === 'boolean' &&
        !this.imageUncertainActions.includes('like') : typeof this.imagePost.bookmarked === 'boolean' &&
        !this.imageUncertainActions.includes('bookmark'))))
    .accessibilityText(label)
    .accessibilitySelected(selected)
    .accessibilityLevel('yes')
    .onClick(() => { if (!this.dismissImageDetails()) { action(); } })
  }

  @Builder
  imageRepostMenu() {
    Menu() {
      MenuItem({ content: this.imagePost.reposted ? $r('app.string.media_unrepost') : $r('app.string.media_repost') })
        .enabled(!this.imageBusy && this.imagePostReady && !this.imageUncertainActions.includes('repost'))
        .onClick(() => { this.performImagePostAction('repost'); })
      MenuItem({ content: $r('app.string.media_quote') })
        .enabled(!this.imageBusy && this.imagePostReady && !this.imageUncertainActions.includes('quote'))
        .onClick(() => { this.performImagePostAction('quote'); })
    }
  }

  @Builder
  imageViewerBottomBar() {
    Row() {
      Row() {
        if (this.imagePost.postId !== '') {
          Row() {
            SymbolGlyph($r('sys.symbol.repeat')).fontSize(22)
              .fontColor([this.imagePost.reposted ? '#00BA7C' : Color.White])
          }
          .id('image-repost')
          .layoutWeight(1)
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .borderRadius(20)
          .backgroundColor(Color.Transparent)
          .enabled(!this.imageBusy && this.imagePostReady && typeof this.imagePost.reposted === 'boolean')
          .accessibilityText($r('app.string.media_repost'))
          .accessibilitySelected(this.imagePost.reposted)
          .accessibilityLevel('yes')
          .onClick(() => { if (!this.dismissImageDetails()) { this.imageRepostMenuOpen = true; } })
          .bindMenu(this.imageRepostMenuOpen, this.imageRepostMenu, {
            onDisappear: () => { this.imageRepostMenuOpen = false; }
          })

          this.imagePostButton(this.imagePost.liked ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'),
            $r('app.string.media_like'), 'image-like', this.imagePost.liked === true, () => { this.performImagePostAction('like'); })
          this.imagePostButton(this.imagePost.bookmarked ? $r('sys.symbol.bookmark_fill') : $r('sys.symbol.bookmark'),
            $r('app.string.menu_bookmarks'), 'image-bookmark', this.imagePost.bookmarked === true, () => { this.performImagePostAction('bookmark'); })
        }
        this.imagePostButton($r('sys.symbol.share'), $r('app.string.media_share'), 'image-share', false,
          () => { this.imageShareTrigger++; })
      }
      .width(this.imagePost.postId !== '' ? (this.isWide ? 380 : 328) : 80)
      .constraintSize({ maxWidth: '90%' })
      .height(FLOATING_BAR_HEIGHT)
      .padding({ left: S8, right: S8 })
      .borderRadius(FLOATING_BAR_HEIGHT / 2)
      .backgroundColor('#66000000')
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.DARK })
      .shadow({ radius: 16, color: '#24000000', offsetY: 4 })
      .border({ width: 0.5, color: '#26FFFFFF' })
      .systemMaterial(this.imageViewerBarMaterial())
      .hitTestBehavior(HitTestMode.Default)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .position({ bottom: this.bottomInset, left: 0 })
    .opacity(this.imageChromeVisible && !this.imageDragging ? 1 : 0)
    .translate({ y: this.imageChromeVisible && !this.imageDragging ? 0 : 20 })
    .animation({ duration: 200, curve: Curve.EaseInOut })
    .hitTestBehavior(this.imageChromeVisible && !this.imageDragging ? HitTestMode.Transparent : HitTestMode.None)
  }

  build() {
    WithTheme({ colorMode: this.imageViewerOpen ? ThemeColorMode.DARK : this.webColorMode }) {
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
          if (!this.imageViewerOpen && this.isWide && this.showsNativeNavigation() && (this.settingsOpen || (!isPostDetailUrl(this.navigation.currentUrl) && !isSecondaryUrl(this.navigation.currentUrl)))) { this.navBar() }
          HdsTabs({ barPosition: BarPosition.End, controller: this.tabsController }) {
            // 五个入口均路由到同一网页会话，内容节点常驻，避免页签切换重建 Web。
            TabContent() {
              Stack() {
                Column() { this.webArea() }
                  .width('100%').height('100%').opacity(this.settingsOpen || this.imageViewerOpen ? 0 : 1)
                  .hitTestBehavior(this.settingsOpen || this.imageViewerOpen ? HitTestMode.None : HitTestMode.Default)
                if (this.settingsOpen) { this.settingsContent() }
                if (this.imageViewerOpen) {
                  this.imageViewer()
                  this.imageViewerBottomBar()
                }
              }
              .width('100%')
              .height('100%')
              // 网页自带标题时由视口避让状态栏；原生标题覆盖的列表仍从屏幕顶部绘制。
              .padding({ top: this.settingsOpen || this.imageViewerOpen || this.fullScreen || (this.overlaysWeb() && this.topChromeHeight() > 0) ? 0 :
                this.topInset + (this.overlaysWeb() ? 0 : this.topChromeHeight()),
                bottom: this.settingsOpen || this.imageViewerOpen || this.overlaysWeb() ? 0 : this.bottomChromeHeight() })
            }
            .tabBar(this.bottomNavigation())
          }
          .scrollable(false)
          .barOverlap(true)
          .barHeight(this.imageViewerOpen ? 0 :
            this.bottomChromeHeight() > 0 ? (this.floatingBar ? FLOATING_BAR_HEIGHT : BAR_HEIGHT) : 0)
          .barFloatingStyle(!this.imageViewerOpen && this.bottomChromeHeight() > 0 && this.floatingBar ? {
            barWidth: { smallWidth: 328, mediumWidth: 380, largeWidth: 380 },
            barSideMargin: 20,
            // 手势区已提供与图库相同的底边距离，不再叠加额外悬浮间距。
            barBottomMargin: this.bottomInset,
            gradientMask: { maskColor: Color.Transparent, maskHeight: 1 },
            systemMaterialEffect: {
              materialType: this.immersiveMaterial ? hdsMaterial.MaterialType.IMMERSIVE : hdsMaterial.MaterialType.ADAPTIVE,
              materialLevel: this.currentHdsMaterialLevel()
            }
          } : undefined)
          .layoutWeight(1)
          // 忽略安全区时，matchParent 同时扩展尺寸；百分比高度只会移动位置。
          .height(LayoutPolicy.matchParent)
          .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
        }
        .width('100%')
        .height(LayoutPolicy.matchParent)
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])

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
      content: {
        stackBuilder: () => { this.navTitleBar(); },
        backIcon: {
          icon: $r('sys.symbol.arrow_left'), label: $r('app.string.back'), componentId: 'navigation-back',
          action: () => { this.onBackPress(); }
        },
        menu: {
          value: []
        }
      },
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
          enableScrollEffect: !this.imageViewerOpen,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR,
          blurEffectiveStartOffset: LengthMetrics.vp(0),
          blurEffectiveEndOffset: LengthMetrics.vp(HEADER_BLUR_DISTANCE)
        },
        blurStrategy: BlurStrategy.ENABLE,
        systemMaterialEffect: {
          materialType: this.immersiveMaterial ? hdsMaterial.MaterialType.IMMERSIVE : hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: this.currentHdsMaterialLevel()
        }
      }
    })
    .bindToScrollable([this.blurScroller])
    .withTheme({ enableThemeColorMode: true })
    .systemBarStyle({ statusBarContentColor: this.imageViewerOpen || this.profileBannerButtons() || this.isMediaViewer() || this.webColorMode === ThemeColorMode.DARK ? '#FFFFFF' :
      this.webColorMode === ThemeColorMode.LIGHT ? '#000000' : this.statusBarContentColor }, undefined)
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideTitleBar(this.imageViewerOpen ? true : this.topChromeHeight() === 0)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    // Navigation defaults to Split mode on wide windows, which would reserve a
    // left pane for the title bar and squeeze our own rail + WebView into it.
    // The shell owns the wide layout, so keep Navigation in Stack mode.
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .backgroundColor(this.imageViewerOpen || this.isMediaViewer() ? Color.Black : $r('sys.color.ohos_id_color_background'))
    .bindSheet($$this.composer.sheetOpen, this.composeSheet(), {
      height: SheetSize.LARGE,
      width: this.isWide ? 640 : '100%',
      dragBar: true,
      showClose: this.composer.webComposer,
      shouldDismiss: (() => { this.composer.closeCompose(); }),
      blurStyle: BlurStyle.COMPONENT_ULTRA_THICK
    })
    }
  }
}
