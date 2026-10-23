import web_webview from '@ohos.web.webview';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { pathOf, profileHandleForUrl } from './WebConfig';
import { clickRouteScript, unquoteScriptResult } from './WebChrome';

const DOMAIN: number = 0x0A11;
const TAG: string = 'OpenTwit';

/** 控制器可能因恢复而更换，跳转始终读取当前实例。 */
export interface NavigationHost {
  controller: () => web_webview.WebviewController;
  isControllerReady: () => boolean;
  documentStarted: (url: string) => void;
  isNetworkReady: () => boolean;
  cancelProfileNavigation: () => Promise<void>;
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
  progress: number = 0;
  private host: NavigationHost;

  constructor(host: NavigationHost) { this.host = host; }

  /** 仅在网页报告路由后同步，原生点击不提前伪造已到达状态。 */
  syncFromUrl(url: string): void {
    this.viewingHandle = profileHandleForUrl(url);
    this.currentPath = pathOf(url);
    this.currentUrl = url;
  }

  /** 常规入口沿用网页路由；明确允许时才建立新文档。 */
  async loadWeb(url: string, keepProfile: boolean = false, allowDocumentLoad: boolean = false, direct: boolean = false): Promise<void> {
    if (!this.host.isNetworkReady()) { this.failure = 'policy'; return; }
    if (!this.host.isControllerReady()) { return; }
    if (!keepProfile) { this.host.cancelProfileNavigation(); }
    const generation = ++this.navigationGeneration;
    const pageUrl = this.currentUrl;
    if (direct) {
      try {
        this.failure = 'none';
        this.progress = 0;
        this.host.documentStarted(url);
        this.host.controller().loadUrl(url);
        return;
      } catch (err) {
        this.failure = 'document';
        hilog.error(DOMAIN, TAG, 'event=direct_navigation_failed error=%{public}s', JSON.stringify(err));
        this.host.toast($r('app.string.operation_failed'));
      }
      return;
    }
    try {
      const deadline = Date.now() + 3000;
      while (generation === this.navigationGeneration && this.host.isNetworkReady() && this.host.isControllerReady()) {
        const result: string = unquoteScriptResult(await this.host.controller().runJavaScript(clickRouteScript(url)));
        if (generation !== this.navigationGeneration || !this.host.isNetworkReady()) { return; }
        if (result === 'cancelled') { return; }
        if (result === 'clicked' || result === 'same') { this.failure = 'none'; return; }
        if (result !== 'pending' || Date.now() >= deadline) { break; }
        await new Promise<void>((resolve) => { setTimeout(resolve, 100); });
      }
      if (generation !== this.navigationGeneration || !this.host.isNetworkReady() || !this.host.isControllerReady()) { return; }
      await this.host.controller().runJavaScript('window.__otRouteCancel&&window.__otRouteCancel()');
      hilog.warn(DOMAIN, TAG, 'event=page_route_unavailable');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'event=page_route_script_failed error=%{public}s', JSON.stringify(err));
    }
    if (generation !== this.navigationGeneration || !this.host.isNetworkReady() || !this.host.isControllerReady() || this.currentUrl !== pageUrl) { return; }
    if (allowDocumentLoad) {
      try {
        this.failure = 'none';
        this.progress = 0;
        this.host.documentStarted(url);
        this.host.controller().loadUrl(url);
        return;
      } catch (err) {
        this.failure = 'document';
        hilog.error(DOMAIN, TAG, 'event=document_navigation_failed error=%{public}s', JSON.stringify(err));
      }
    }
    this.host.toast($r('app.string.operation_failed'));
  }
}
