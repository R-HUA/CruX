import web_webview from '@ohos.web.webview';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { pathOf, profileHandleForUrl } from './WebConfig';
import { clickRouteScript, cancelRouteScript, finishRouteScript, unquoteScriptResult } from './WebChrome';

const DOMAIN: number = 0x0A11;
const TAG: string = 'OpenTwit';

export type NavigationResult = 'arrived' | 'failed' | 'cancelled';
interface RouteReply { status: string; document: string; method: string; evidence: string; }

/** 控制器可能因恢复而更换，跳转始终读取当前实例。 */
export interface NavigationHost {
  controller: () => web_webview.WebviewController;
  isControllerReady: () => boolean;
  isActive: () => boolean;
  documentStarted: (url: string) => void;
  isNetworkReady: () => boolean;
  cancelProfileNavigation: () => Promise<void>;
  routeSettled: () => void;
  toast: (message: ResourceStr) => void;
}

/** URL、加载状态与跳转代际同属当前网页，避免页面保留第二份路由状态。 */
@Observed
export class WebNavigation {
  navigationGeneration: number = 0;
  currentUrl: string = '';
  currentPath: string = '';
  viewingHandle: string = '';
  failure: 'none' | 'document' | 'render' | 'policy' = 'none';
  get hasError(): boolean { return this.failure !== 'none'; }
  get isNavigating(): boolean { return this.pendingGeneration !== 0; }
  progress: number = 0;
  private pendingGeneration: number = 0;
  private unconfirmedUrl: string = '';
  private blockedGeneration: number = 0;
  private routeTimer: number = -1;
  private resumeRoute: (() => void) | undefined = undefined;
  private host: NavigationHost;

  constructor(host: NavigationHost) { this.host = host; }

  /** 地址照实记录，原生栏只在目标内容确认后提交。 */
  syncFromUrl(url: string, documentLoaded: boolean = false): void {
    this.currentUrl = url;
    if (documentLoaded) { this.unconfirmedUrl = ''; }
    if (this.isNavigating || url === this.unconfirmedUrl) { return; }
    this.viewingHandle = profileHandleForUrl(url);
    this.currentPath = pathOf(url);
  }

  /** 返回、新请求及生命周期结束都使排队的旧脚本失效。 */
  cancel(): void {
    if (this.isNavigating) {
      hilog.info(DOMAIN, TAG, 'event=route_cancelled generation=%{public}d', this.pendingGeneration);
    }
    const generation = ++this.navigationGeneration;
    this.pendingGeneration = 0;
    if (this.routeTimer !== -1) { clearTimeout(this.routeTimer); this.routeTimer = -1; }
    const resume = this.resumeRoute;
    this.resumeRoute = undefined;
    if (resume !== undefined) { resume(); }
    if (this.host.isControllerReady()) {
      try {
        this.host.controller().runJavaScript(cancelRouteScript(generation)).catch((error: Error) => {
          hilog.warn(DOMAIN, TAG, 'event=route_cancel_failed error=%{public}s', error.message);
        });
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'event=route_cancel_failed error=%{public}s', JSON.stringify(error));
      }
    }
  }

  /** 只限制主网页的在途 SPA 请求，不干涉子资源或发帖网页。 */
  interceptDocument(): boolean {
    if (!this.isNavigating) { return false; }
    this.blockedGeneration = this.pendingGeneration;
    hilog.warn(DOMAIN, TAG, 'event=route_document_blocked generation=%{public}d', this.pendingGeneration);
    return true;
  }

  private waitRoute(): Promise<void> {
    return new Promise<void>((resolve) => {
      this.resumeRoute = resolve;
      this.routeTimer = setTimeout(() => {
        this.routeTimer = -1;
        this.resumeRoute = undefined;
        resolve();
      }, 100);
    });
  }

  /** 平台回调迟到时仍按期限结束；取消只释放本次等待，不影响更新请求。 */
  private async waitRouteResult(task: Promise<string>, deadline: number): Promise<string> {
    let wake: () => void = () => {};
    const timeout = new Promise<string>((resolve) => {
      wake = () => resolve('');
      this.resumeRoute = wake;
      this.routeTimer = setTimeout(wake, Math.max(0, deadline - Date.now()));
    });
    try {
      return await Promise.race([task, timeout]);
    } finally {
      if (this.resumeRoute === wake) {
        clearTimeout(this.routeTimer);
        this.routeTimer = -1;
        this.resumeRoute = undefined;
      }
    }
  }

  /** 日常导航没有文档回退，点击接管与目标到达分别确认。 */
  async loadWeb(url: string): Promise<NavigationResult> {
    this.cancel();
    const generation = this.navigationGeneration;
    if (!this.host.isNetworkReady()) { this.failure = 'policy'; return 'failed'; }
    if (!this.host.isControllerReady() || !this.host.isActive()) { return 'cancelled'; }
    const controller = this.host.controller();
    const sourceUrl = this.currentUrl;
    this.pendingGeneration = generation;
    this.unconfirmedUrl = url;
    let document: string = '';
    let result: NavigationResult = 'failed';
    let reason: string = 'timeout';
    const deadline = Date.now() + 3000;
    try {
      await this.waitRouteResult(Promise.resolve(this.host.cancelProfileNavigation()).then(() => 'ready'), deadline);
      while (generation === this.navigationGeneration && this.host.isActive() && this.host.isNetworkReady() &&
        this.host.isControllerReady() && controller === this.host.controller() && Date.now() < deadline) {
        if (this.blockedGeneration === generation) { reason = 'document_blocked'; break; }
        const raw = await this.waitRouteResult(controller.runJavaScript(clickRouteScript(url, generation, document, sourceUrl)), deadline);
        if (generation !== this.navigationGeneration || !this.host.isActive() || !this.host.isNetworkReady() ||
          !this.host.isControllerReady() || controller !== this.host.controller()) { return 'cancelled'; }
        if (raw === '' || Date.now() > deadline) { break; }
        const reply = JSON.parse(unquoteScriptResult(raw)) as RouteReply;
        if (document === '' && reply.method === 'history') {
          hilog.info(DOMAIN, TAG, 'event=route_link_unavailable generation=%{public}d', generation);
        }
        document = reply.document;
        if (this.blockedGeneration === generation) { reason = 'document_blocked'; break; }
        if (reply.status === 'arrived') { result = 'arrived'; break; }
        if (reply.status === 'cancelled') {
          hilog.info(DOMAIN, TAG, 'event=route_cancelled generation=%{public}d', generation);
          result = 'cancelled';
          break;
        }
        if (reply.status !== 'pending') { reason = reply.status; break; }
        reason = reply.evidence || 'target_not_arrived';
        if (Date.now() >= deadline) { break; }
        await this.waitRoute();
      }
      if (generation !== this.navigationGeneration || !this.host.isActive() || !this.host.isNetworkReady() ||
        !this.host.isControllerReady() || controller !== this.host.controller()) { return 'cancelled'; }
      await this.waitRouteResult(controller.runJavaScript(finishRouteScript(generation, result === 'failed')), deadline);
      if (generation !== this.navigationGeneration || !this.host.isActive() ||
        !this.host.isControllerReady() || controller !== this.host.controller()) { return 'cancelled'; }
    } catch (error) {
      reason = 'script_failed';
      hilog.warn(DOMAIN, TAG, 'event=route_script_failed generation=%{public}d error=%{public}s', generation, JSON.stringify(error));
      if (generation !== this.navigationGeneration || !this.host.isActive() || !this.host.isControllerReady() ||
        controller !== this.host.controller()) { return 'cancelled'; }
      result = 'failed';
      try { await this.waitRouteResult(controller.runJavaScript(finishRouteScript(generation, true)), deadline); } catch (cleanupError) {
        hilog.warn(DOMAIN, TAG, 'event=route_cleanup_failed error=%{public}s', JSON.stringify(cleanupError));
      }
    } finally {
      if (this.pendingGeneration === generation) { this.pendingGeneration = 0; }
    }
    if (generation !== this.navigationGeneration || !this.host.isActive() || !this.host.isControllerReady() ||
      controller !== this.host.controller()) { return 'cancelled'; }
    if (result === 'arrived') { this.failure = 'none'; this.unconfirmedUrl = ''; }
    if (result === 'failed') {
      hilog.warn(DOMAIN, TAG, 'event=route_failed generation=%{public}d reason=%{public}s', generation, reason);
      this.host.toast($r('app.string.navigation_failed'));
    }
    this.host.routeSettled();
    return result;
  }

  /** 仅供初始化、登录及明确要求新文档的既有业务使用。 */
  async loadDocument(url: string): Promise<void> {
    this.cancel();
    this.unconfirmedUrl = '';
    if (!this.host.isNetworkReady()) { this.failure = 'policy'; return; }
    if (!this.host.isControllerReady()) { return; }
    try {
      this.failure = 'none';
      this.progress = 0;
      this.host.documentStarted(url);
      this.host.controller().loadUrl(url);
    } catch (error) {
      this.failure = 'document';
      hilog.error(DOMAIN, TAG, 'event=document_navigation_failed error=%{public}s', JSON.stringify(error));
      this.host.toast($r('app.string.operation_failed'));
    }
  }
}
