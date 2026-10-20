import webview from '@ohos.web.webview';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { isMediaDownloadUrl } from './WebMedia';

const IMAGE_LIMIT: number = 25 * 1024 * 1024;
const IMAGE_TIMEOUT: number = 40000;

export function isWebImageUrl(url: string): boolean {
  return isMediaDownloadUrl(url);
}

/** ArkWeb 的下载错误码不等同 HTTP 状态码。 */
export class WebImageDownloadError extends Error {
  stage: string;
  code: number;

  constructor(stage: string, code: number) {
    super('ArkWeb image failure: stage=' + stage + ' code=' + code);
    this.stage = stage;
    this.code = code;
  }

  canTryNextCandidate(): boolean {
    // 33 表示服务器没有所请求的数据，范围比 HTTP 404 宽；仅对它尝试其他图片规格。
    return this.stage === 'download' && this.code === webview.WebDownloadErrorCode.SERVER_BAD_CONTENT;
  }
}

export interface WebImageRequest {
  result: Promise<ArrayBuffer>;
  cancel: () => void;
}

interface ImageSubscriber {
  resolve: (bytes: ArrayBuffer) => void;
  reject: (error: WebImageDownloadError) => void;
  settled: boolean;
}

interface ImageTransfer {
  url: string;
  path: string;
  guid: string;
  item: webview.WebDownloadItem | undefined;
  subscribers: ImageSubscriber[];
  timer: number;
  started: boolean;
  finishing: boolean;
  done: boolean;
}

/** 复用页面所属 Web 的网络和会话；不另设 DNS，也不注册第二个下载代理。 */
export class WebImageDownloads {
  private controller: webview.WebviewController;
  private directory: string;
  private closed: boolean = false;
  private sequence: number = 0;
  private stamp: string = Date.now().toString() + '-' + Math.floor(Math.random() * 1000000).toString();
  private byUrl: Map<string, ImageTransfer> = new Map();
  // 已结束的 GUID 仍归图片服务，防止迟到回调进入普通文件保存流程。
  private byGuid: Map<string, ImageTransfer> = new Map();
  private ordinary: Set<string> = new Set();
  private paths: Set<string> = new Set();
  private operations: Promise<void>[] = [];

  constructor(controller: webview.WebviewController, directory: string) {
    this.controller = controller;
    this.directory = directory;
  }

  request(url: string): WebImageRequest {
    if (this.closed || !isWebImageUrl(url)) {
      return { result: Promise.reject(new WebImageDownloadError(this.closed ? 'closed' : 'url', 0)), cancel: () => {} };
    }
    let transfer = this.byUrl.get(url);
    if (transfer && transfer.done) {
      // startDownload 不返回任务标识；取消后尚无 GUID 时，不能把旧回调误认成新请求。
      return { result: Promise.reject(new WebImageDownloadError('pending_cancel', 40)), cancel: () => {} };
    }
    const created: boolean = transfer === undefined;
    if (!transfer) {
      transfer = { url: url, path: this.directory + '/x-web-image-' + this.stamp + '-' + (++this.sequence) + '.tmp',
        guid: '', item: undefined, subscribers: [], timer: -1, started: false, finishing: false, done: false };
      this.byUrl.set(url, transfer);
    }
    const task: ImageTransfer = transfer;
    const subscriber: ImageSubscriber = { resolve: (_bytes: ArrayBuffer) => {},
      reject: (_error: WebImageDownloadError) => {}, settled: false };
    const result = new Promise<ArrayBuffer>((resolve, reject) => {
      subscriber.resolve = resolve;
      subscriber.reject = reject;
    });
    task.subscribers.push(subscriber);
    if (created) {
      task.timer = setTimeout(() => this.fail(task, new WebImageDownloadError('timeout', 21), true), IMAGE_TIMEOUT);
      try { this.controller.startDownload(url); } catch (error) {
        this.fail(task, new WebImageDownloadError('dispatch', (error as BusinessError).code || 0), true);
        // 同步参数或控制器错误表示未派发，无需等候不会到达的 GUID。
        this.byUrl.delete(url);
      }
    }
    return { result: result, cancel: () => {
      if (subscriber.settled) { return; }
      subscriber.settled = true;
      subscriber.reject(new WebImageDownloadError('cancel', 40));
      task.subscribers = task.subscribers.filter((value: ImageSubscriber) => value !== subscriber);
      if (task.subscribers.length === 0) { this.fail(task, new WebImageDownloadError('cancel', 40), true); }
    } };
  }

  /** 无 GUID 的已派发任务只能随所属 Web 一起重建，避免旧回调认领新请求。 */
  needsRecovery(): boolean {
    return Array.from(this.byUrl.values()).some((task: ImageTransfer) => task.done && task.guid === '');
  }

  beforeDownload(item: webview.WebDownloadItem): boolean {
    const task = this.find(item);
    if (!task) { this.ordinary.add(item.getGuid()); return false; }
    if (task.done) { this.cancelItem(item); this.queueCleanup(task.path); return true; }
    if (!isWebImageUrl(item.getUrl())) {
      this.fail(task, new WebImageDownloadError('redirect', 24), true);
    } else if (this.exceedsLimit(item)) {
      this.fail(task, new WebImageDownloadError('size', 6), true);
    } else if (!task.started) {
      try {
        task.started = true;
        this.paths.add(task.path);
        item.start(task.path);
      } catch (error) {
        this.fail(task, new WebImageDownloadError('start', (error as BusinessError).code || 0), true);
      }
    }
    return true;
  }

  downloadUpdated(item: webview.WebDownloadItem): boolean {
    const task = this.find(item);
    if (!task) { return false; }
    if (task.done) { this.cancelItem(item); this.queueCleanup(task.path); }
    else if (!isWebImageUrl(item.getUrl())) { this.fail(task, new WebImageDownloadError('redirect', 24), true); }
    else if (this.exceedsLimit(item)) { this.fail(task, new WebImageDownloadError('size', 6), true); }
    return true;
  }

  downloadFailed(item: webview.WebDownloadItem): boolean {
    const task = this.find(item);
    if (!task) { return false; }
    if (task.done) { this.queueCleanup(task.path); }
    else { this.fail(task, new WebImageDownloadError('download', item.getLastErrorCode()), false); }
    return true;
  }

  downloadFinish(item: webview.WebDownloadItem): boolean {
    const task = this.find(item);
    if (!task) { return false; }
    if (task.done) { this.queueCleanup(task.path); return true; }
    if (task.finishing) { return true; }
    if (!task.started || item.getFullPath() !== task.path) {
      this.fail(task, new WebImageDownloadError('path', 1), true);
    } else if (!isWebImageUrl(item.getUrl())) {
      this.fail(task, new WebImageDownloadError('redirect', 24), true);
    } else if (this.exceedsLimit(item)) {
      this.fail(task, new WebImageDownloadError('size', 6), true);
    } else {
      task.finishing = true;
      const operation = this.readCompleted(task).catch((error: Error) => {
        this.fail(task, error instanceof WebImageDownloadError ? error :
          new WebImageDownloadError('read', (error as BusinessError).code || 0), false);
      });
      this.track(operation);
    }
    return true;
  }

  private find(item: webview.WebDownloadItem): ImageTransfer | undefined {
    const guid = item.getGuid();
    const known = this.byGuid.get(guid);
    if (known) { if (!known.done) { known.item = item; } return known; }
    if (this.ordinary.has(guid)) { return undefined; }
    const original = item.getOriginalUrl();
    const task = this.byUrl.get(original.length > 0 ? original : item.getUrl());
    if (!task || task.guid.length > 0) { return undefined; }
    task.guid = guid;
    task.item = task.done ? undefined : item;
    this.byGuid.set(guid, task);
    if (task.done) { this.byUrl.delete(task.url); }
    return task;
  }

  private exceedsLimit(item: webview.WebDownloadItem): boolean {
    return item.getTotalBytes() > IMAGE_LIMIT || item.getReceivedBytes() > IMAGE_LIMIT;
  }

  private async readCompleted(task: ImageTransfer): Promise<void> {
    const stat = await fileIo.stat(task.path);
    if (!Number.isSafeInteger(stat.size) || stat.size <= 0 || stat.size > IMAGE_LIMIT) {
      throw new WebImageDownloadError('size', 6);
    }
    const bytes = new Uint8Array(stat.size);
    const file = await fileIo.open(task.path, fileIo.OpenMode.READ_ONLY);
    try {
      let received = 0;
      while (received < bytes.length) {
        if (task.done) { return; }
        const chunk = new ArrayBuffer(Math.min(64 * 1024, bytes.length - received));
        const count = await fileIo.read(file.fd, chunk);
        if (count <= 0 || count > chunk.byteLength) { throw new WebImageDownloadError('read', 13); }
        bytes.set(new Uint8Array(chunk, 0, count), received);
        received += count;
      }
    } finally { await fileIo.close(file); }
    await this.cleanup(task.path);
    if (task.done) { return; }
    this.settle(task);
    const subscribers = task.subscribers;
    task.subscribers = [];
    for (const subscriber of subscribers) {
      subscriber.settled = true;
      subscriber.resolve(bytes.buffer as ArrayBuffer);
    }
  }

  private settle(task: ImageTransfer): void {
    task.done = true;
    task.item = undefined;
    clearTimeout(task.timer);
    if (task.guid.length > 0) { this.byUrl.delete(task.url); }
  }

  private fail(task: ImageTransfer, error: WebImageDownloadError, cancel: boolean): void {
    if (task.done) { return; }
    const item = task.item;
    this.settle(task);
    const subscribers = task.subscribers;
    task.subscribers = [];
    for (const subscriber of subscribers) { subscriber.settled = true; subscriber.reject(error); }
    hilog.warn(0x0A11, 'OpenTwit', 'event=web_image_failed stage=%{public}s code=%{public}d', error.stage, error.code);
    if (cancel && item) { this.cancelItem(item); }
    this.queueCleanup(task.path);
  }

  private cancelItem(item: webview.WebDownloadItem): void {
    try { item.cancel(); } catch (error) {
      hilog.warn(0x0A11, 'OpenTwit', 'event=web_image_failed stage=cancel code=%{public}d', (error as BusinessError).code || 0);
    }
  }

  private async cleanup(path: string): Promise<void> {
    try { await fileIo.unlink(path); } catch (error) {
      if ((error as BusinessError).code !== 13900002) {
        throw new WebImageDownloadError('cleanup', (error as BusinessError).code || 0);
      }
    }
    this.paths.delete(path);
  }

  private queueCleanup(path: string): void {
    this.paths.add(path);
    this.track(this.cleanup(path).catch((error: WebImageDownloadError) => {
      hilog.warn(0x0A11, 'OpenTwit', 'event=web_image_failed stage=%{public}s code=%{public}d', error.stage, error.code);
    }));
  }

  private track(operation: Promise<void>): void {
    this.operations.push(operation);
    operation.then(() => {
      const index = this.operations.indexOf(operation);
      if (index >= 0) { this.operations.splice(index, 1); }
    });
  }

  async close(): Promise<void> {
    this.closed = true;
    for (const task of this.byUrl.values()) { this.fail(task, new WebImageDownloadError('closed', 41), true); }
    await Promise.allSettled(this.operations);
    for (const path of Array.from(this.paths)) { await this.cleanup(path); }
    this.operations = [];
  }
}
