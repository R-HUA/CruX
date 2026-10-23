import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { FrameCallback, UIContext } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MediaFile, MediaFiles } from './MediaFiles';
import { MediaAddress, resolveMedia } from './WebMedia';
import { WebImageDownloads } from './WebImageDownloads';
import { accountDetailsScript } from './ClientSettings';
import { profileUrl, pathOf } from './WebConfig';
import { isSiteUrl } from './WebSystem';
import { OWN_HANDLE_SCRIPT, profileBootstrapScript, accountAvatarScript, accountAvatarDiagScript,
  unquoteScriptResult } from './WebChrome';

const DOMAIN: number = 0x0A11;
const TAG: string = 'OpenTwit';
const PREFS_NAME: string = 'opentwit_web';
const OWN_HANDLE_KEY: string = 'own_handle';
const AVATAR_KEY: string = 'own_avatar';
const AVATAR_RETRY_MS: number = 1200;
const AVATAR_RETRY_LIMIT: number = 6;
const PROFILE_TIMEOUT_MS: number = 10000;

interface AccountDetails { handle: string; name: string; bio: string; }

/** 从页面读取即时上下文，账号状态只在会话中保存。 */
export interface AccountHost {
  getUIContext: () => UIContext;
  webScript: (script: string) => Promise<string>;
  url: () => string;
  isAuthenticationPage: () => boolean;
  isRawWeb: () => boolean;
  webImages: () => WebImageDownloads | undefined;
  currentIndex: () => number;
  isControllerReady: () => boolean;
  isSettingsOpen: () => boolean;
  isComposerOpen: () => boolean;
  accountChanged: () => void;
  loadWeb: (url: string, keepProfile: boolean, allowDocumentLoad: boolean, direct: boolean) => Promise<void>;
  toast: (message: ResourceStr) => void;
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

/** 账号识别与头像缓存共用身份和取消代际，防止缓存跨账号应用。 */
@Observed
export class AccountSession {
  // 设置读取与资料跳转分别取消，退出设置不影响已确认的身份。
  settingsReadGeneration: number = 0;
  accountName: string = '';
  accountBio: string = '';
  accountLoading: boolean = false;
  accountError: boolean = false;
  ownHandle: string = '';
  // 头像文件归账号会话持有，网页仅提供可重新读取的地址。
  avatarUrl: string = '';
  avatarPath: string = '';
  avatarFailedUrl: string = '';
  private avatarFiles: MediaFiles | undefined = undefined;
  private avatarGeneration: number = 0;
  private avatarReadRequest: number = 0;
  private avatarRetryTimer: number = -1;
  private avatarRetries: number = 0;
  private retiredAvatarFiles: MediaFiles[] = [];
  private avatarCleanupScheduled: boolean = false;
  discovering: boolean = false;
  profileNavigation: number = 0;
  private alive: boolean = false;
  private appBackground: boolean = false;
  private host: AccountHost;

  constructor(host: AccountHost) { this.host = host; }

  /** 生命周期由页面转发，内部异步结果和资源在同一处失效。 */
  activate(background: boolean): void { this.alive = true; this.appBackground = background; }

  setBackground(background: boolean): void {
    this.appBackground = background;
    if (background) { this.clearAvatarRetry(); }
  }

  dispose(): void {
    this.alive = false;
    this.resetAvatar();
    this.closeRetiredAvatarFiles();
  }

  /** 缓存只预热头像，不能作为当前登录身份。 */
  async initialize(prefs: preferences.Preferences): Promise<void> {
    const cachedHandle = await prefs.get(OWN_HANDLE_KEY, '') as string;
    if (this.ownHandle === '' && cachedHandle !== '') { this.restoreAvatar(cachedHandle, true); }
  }

  /** 登录表单出现时，旧身份及其异步读取同时失效。 */
  authenticationRequired(): void {
    this.ownHandle = '';
    this.saveOwnHandle('');
    this.settingsReadGeneration++;
    this.profileNavigation++;
    this.accountName = '';
    this.accountBio = '';
    this.accountLoading = false;
    this.accountError = true;
    this.resetAvatar();
  }

  /** 显式刷新才重置自动重试预算。 */
  retryFailedAvatar(): void {
    this.avatarReadRequest++;
    this.clearAvatarRetry();
    if (this.avatarFailedUrl !== '' && this.avatarUrl !== '') { this.loadAvatar(this.avatarUrl, true); }
  }

  /** 资料字段只接受当前身份和当前设置读取代际的结果。 */
  readProfileDetails(): void {
    if (!this.host.isControllerReady()) { return; }
    const handle = this.ownHandle;
    const generation = this.settingsReadGeneration;
    this.host.webScript(accountDetailsScript(handle)).then((raw: string) => {
      if (!this.alive || this.ownHandle.toLowerCase() !== handle.toLowerCase() || generation !== this.settingsReadGeneration) { return; }
      const clean = unquoteScriptResult(raw);
      if (clean !== '') {
        try {
          const account = JSON.parse(clean) as AccountDetails;
          if (account.handle.toLowerCase() === this.ownHandle.toLowerCase()) {
            if (account.name) { this.accountName = account.name; }
            if (account.bio) { this.accountBio = account.bio; }
          }
        } catch (err) {}
      }
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'event=account_details_failed code=%{public}d', err.code);
    });
  }

  private async saveOwnHandle(handle: string): Promise<void> {
    try {
      const ctx: common.Context | undefined = this.host.getUIContext().getHostContext();
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
      const ctx: common.Context | undefined = this.host.getUIContext().getHostContext();
      if (ctx === undefined) {
        return;
      }
      const prefs: preferences.Preferences = await preferences.getPreferences(ctx, PREFS_NAME);
      if (!this.alive || generation !== this.avatarGeneration || this.avatarUrl !== url ||
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
      const ctx: common.Context | undefined = this.host.getUIContext().getHostContext();
      if (ctx === undefined) { return; }
      const prefs: preferences.Preferences = await preferences.getPreferences(ctx, PREFS_NAME);
      const url = await prefs.get(AVATAR_KEY + ':' + handle.toLowerCase(), '') as string;
      if (this.alive && generation === this.avatarGeneration && !this.host.isAuthenticationPage() &&
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
    if (!this.alive || this.host.isRawWeb() || this.host.isAuthenticationPage() || (!retry && this.avatarUrl === url)) { return; }
    const generation: number = ++this.avatarGeneration;
    const handle: string = this.ownHandle.toLowerCase();
    const previous: MediaFiles | undefined = this.avatarFiles;
    const wasDisplayed: boolean = this.avatarPath !== '';
    const files: MediaFiles = new MediaFiles(this.host.webImages());
    this.avatarFiles = files;
    this.avatarUrl = url;
    this.avatarPath = '';
    this.avatarFailedUrl = '';
    this.retireAvatarFiles(previous, wasDisplayed);
    try {
      const resolved = resolveMedia(url);
      const address: MediaAddress = { id: 'avatar_' + generation.toString(), source: url,
        candidates: resolved !== undefined ? resolved.candidates : [url] };
      const context = this.host.getUIContext().getHostContext() as common.UIAbilityContext;
      const file: MediaFile = await files.load(address, context);
      if (!this.alive || generation !== this.avatarGeneration || this.ownHandle.toLowerCase() !== handle ||
        this.host.isAuthenticationPage()) { return; }
      this.avatarPath = 'file://' + file.path;
      if (this.avatarRetryTimer !== -1) { clearTimeout(this.avatarRetryTimer); }
      this.avatarRetryTimer = -1;
      if (handle !== '') { this.saveAvatar(handle, url); }
      hilog.debug(DOMAIN, TAG, 'event=avatar_loaded');
    } catch (err) {
      if (!this.alive || generation !== this.avatarGeneration) { return; }
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

  /** Image 的迟到事件不能撤下已经替换的新头像。 */
  avatarImageFailed(path: string): void {
    if (!this.alive || path === '' || path !== this.avatarPath) { return; }
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
    if (!wasDisplayed || !this.alive) {
      this.closeAvatarFiles(files);
      return;
    }
    this.retiredAvatarFiles.push(files);
    if (this.avatarCleanupScheduled) { return; }
    this.avatarCleanupScheduled = true;
    this.host.getUIContext().postFrameCallback(new AvatarCleanupFrame(() => this.closeRetiredAvatarFiles()));
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

  /** 后台探测不能改变用户已经选择的新路由。 */
  async discoverOwnProfile(): Promise<void> {
    if (!this.host.isControllerReady() || this.host.isRawWeb() || this.discovering || this.host.isComposerOpen()) { return; }
    const pageUrl = this.host.url();
    const generation = this.profileNavigation;
    try {
      const raw = await this.host.webScript(OWN_HANDLE_SCRIPT);
      if (!this.alive || this.host.url() !== pageUrl || this.appBackground || generation !== this.profileNavigation) { return; }
      const direct: string = AccountSession.parseHandle('/' + unquoteScriptResult(raw));
      if (direct !== '') { this.acceptHandle(direct, false); }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'event=account_read_failed code=%{public}d', (error as BusinessError).code);
    }
  }

  /** 探测占用的网页抽屉随取消退出，避免残留遮挡。 */
  async closeWebDrawer(): Promise<void> {
    if (this.host.isControllerReady()) {
      try {
        await this.host.webScript('window.__otBootCancel&&window.__otBootCancel()');
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'event=account_read_cancel_failed code=%{public}d', (error as BusinessError).code);
      }
    }
  }

  /** 切换路由或生命周期后，旧资料读取不能再驱动导航。 */
  async cancelProfileNavigation(): Promise<void> {
    this.profileNavigation++;
    this.discovering = false;
    await this.closeWebDrawer();
  }

  /** 身份变化时一起失效头像与角标；重复确认保留正在读取的资源。 */
  acceptHandle(handle: string, navigate: boolean): void {
    const changed: boolean = this.ownHandle.toLowerCase() !== handle.toLowerCase();
    if (changed) {
      this.accountName = '';
      this.accountBio = '';
      this.cancelProfileNavigation();
      this.resetAvatar();
      this.host.accountChanged();
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
    if (this.ownHandle) {
      this.host.loadWeb(profileUrl(this.ownHandle), false, true, true);
      return;
    }
    this.host.toast($r('app.string.account_unconfirmed'));
  }

  /** 设置页只消费仍属于本次打开过程的账号结果。 */
  async readSettingsAccount(): Promise<void> {
    const generation = ++this.settingsReadGeneration;
    this.accountLoading = true;
    this.accountError = false;
    try {
      if (this.ownHandle === '') {
        const handle = await this.confirmCurrentAccount();
        await this.cancelProfileNavigation();
        if (generation !== this.settingsReadGeneration || !this.host.isSettingsOpen()) { return; }
        if (handle !== '') {
          this.acceptHandle(handle, false);
        } else {
          this.accountError = true;
          return;
        }
      }
      const handle = this.ownHandle;
      if (handle !== '' && isSiteUrl(this.host.url()) && pathOf(this.host.url()).toLowerCase() === '/' + handle.toLowerCase()) {
        const raw = unquoteScriptResult(await this.host.webScript(accountDetailsScript(handle)));
        if (generation === this.settingsReadGeneration && raw !== '') {
          const account = JSON.parse(raw) as AccountDetails;
          if (account.handle.toLowerCase() === this.ownHandle.toLowerCase()) {
            if (account.name) { this.accountName = account.name; }
            if (account.bio) { this.accountBio = account.bio; }
          }
        }
      }
    } catch (error) {
      if (generation === this.settingsReadGeneration) {
        this.accountError = true;
        hilog.error(DOMAIN, TAG, 'event=settings_account_failed error=%{public}s', JSON.stringify(error));
      }
    } finally {
      if (generation === this.settingsReadGeneration) { this.accountLoading = false; }
    }
  }

  /** 首页账号控件即可提供头像，资料页只补充已确认本人的链接。 */
  readAvatar(retryFailed: boolean = false): void {
    if (!this.host.isControllerReady() || !this.alive || this.host.isRawWeb() || this.host.isAuthenticationPage()) { return; }
    const handle: string = this.ownHandle;
    const pageUrl: string = this.host.url();
    const request: number = ++this.avatarReadRequest;
    try {
      this.host.webScript(accountAvatarScript(handle)).then((raw: string) => {
        if (!this.alive || request !== this.avatarReadRequest || this.host.isAuthenticationPage() ||
          this.host.isRawWeb() || this.host.url() !== pageUrl || this.ownHandle.toLowerCase() !== handle.toLowerCase()) { return; }
        const url: string = unquoteScriptResult(raw);
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
            this.host.currentIndex(), String(handle !== ''), this.avatarRetries);
          if (this.avatarRetries === 0) {
            this.host.webScript(accountAvatarDiagScript()).then((diagnostics: string) => {
              hilog.info(DOMAIN, TAG, 'event=avatar_dom_diagnostics data=%{public}s', unquoteScriptResult(diagnostics));
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
    if (!this.alive || this.appBackground || this.host.isRawWeb() || this.host.isAuthenticationPage() || this.avatarPath !== '' ||
      this.avatarRetryTimer !== -1 || this.avatarRetries >= AVATAR_RETRY_LIMIT) { return; }
    this.avatarRetries++;
    this.avatarRetryTimer = setTimeout(() => {
      this.avatarRetryTimer = -1;
      this.readAvatar(true);
    }, AVATAR_RETRY_MS);
  }

  clearAvatarRetry(): void {
    if (this.avatarRetryTimer !== -1) { clearTimeout(this.avatarRetryTimer); }
    this.avatarRetryTimer = -1;
    this.avatarRetries = 0;
  }

  /** 发帖和资料入口需要当前网页确认，不能直接信任上次缓存的账号。 */
  async confirmCurrentAccount(): Promise<string> {
    const pageUrl = this.host.url();
    const generation = this.profileNavigation;
    const direct = unquoteScriptResult(await this.host.webScript(OWN_HANDLE_SCRIPT));
    if (pageUrl !== this.host.url() || generation !== this.profileNavigation) { return ''; }
    if (/^[A-Za-z0-9_]{1,15}$/.test(direct)) { return direct; }
    const result = unquoteScriptResult(await this.host.webScript(profileBootstrapScript(false)));
    if (result !== 'armed') { return ''; }
    const deadline = Date.now() + PROFILE_TIMEOUT_MS;
    while (Date.now() < deadline && this.alive && !this.appBackground &&
      pageUrl === this.host.url() && generation === this.profileNavigation) {
      const handle = unquoteScriptResult(await this.host.webScript('window.__otBoot||""'));
      if (pageUrl !== this.host.url() || generation !== this.profileNavigation) { return ''; }
      if (/^[A-Za-z0-9_]{1,15}$/.test(handle)) { return handle; }
      await new Promise<void>((resolve) => { setTimeout(resolve, 100); });
    }
    return '';
  }
}
