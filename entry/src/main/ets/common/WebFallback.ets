import web_webview from '@ohos.web.webview';

// Web parity fallback: wraps the system Web component pointed at https://x.com.
@Component
export struct WebViewFallback {
  controller: web_webview.WebviewController = new web_webview.WebviewController();

  build() {
    Column() {
      Web({ src: 'https://x.com', controller: this.controller })
        .width('100%')
        .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}
