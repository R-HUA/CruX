import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { systemShare } from '@kit.ShareKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MediaAddress } from './WebMedia';
import { DohPolicy, NetworkConfig } from './NetworkConfig';
import { WebImageDownloadError, WebImageDownloads, WebImageRequest } from './WebImageDownloads';

export interface MediaFile {
  path: string;
  url: string;
  extension: string;
  width: number;
  height: number;
  size: number;
  originalSize: boolean;
}

interface CachedImageFile {
  path: string;
  size: number;
  mtime: number;
}

/** 以响应字节识别格式，不能用请求地址推断实际文件类型。 */
export function imageExtension(buffer: ArrayBuffer): string {
  const b = new Uint8Array(buffer);
  if (b.length >= 8 && b[0] === 137 && b[1] === 80 && b[2] === 78 && b[3] === 71 &&
    b[4] === 13 && b[5] === 10 && b[6] === 26 && b[7] === 10) { return 'png'; }
  if (b.length >= 3 && b[0] === 255 && b[1] === 216 && b[2] === 255) { return 'jpg'; }
  if (b.length >= 12 && b[0] === 82 && b[1] === 73 && b[2] === 70 && b[3] === 70 &&
    b[8] === 87 && b[9] === 69 && b[10] === 66 && b[11] === 80) { return 'webp'; }
  if (b.length >= 6 && b[0] === 71 && b[1] === 73 && b[2] === 70 && b[3] === 56 &&
    (b[4] === 55 || b[4] === 57) && b[5] === 97) { return 'gif'; }
  throw new Error('Unsupported image response');
}

/** 缓存仅属于当前查看会话；关闭时取消网络并等待读写结束后释放。 */
export class MediaFiles {
  private closed: boolean = false;
  private requests: http.HttpRequest[] = [];
  private files: string[] = [];
  private downloads: Map<string, Promise<MediaFile>> = new Map();
  private operations: Promise<void>[] = [];
  private stamp: string = Date.now().toString();
  // 首次下载前统一回收上次进程残留，避免并发查看会话互删临时文件。
  private static cacheCleanup: Promise<void> | undefined = undefined;
  private webImages: WebImageDownloads | undefined;
  private webRequests: WebImageRequest[] = [];

  constructor(webImages?: WebImageDownloads) {
    this.webImages = webImages;
  }

  load(address: MediaAddress, context: common.UIAbilityContext): Promise<MediaFile> {
    const existing = this.downloads.get(address.id);
    if (existing) { return existing; }
    const task = this.download(address, context.cacheDir);
    this.downloads.set(address.id, task);
    return task;
  }

  private async download(address: MediaAddress, directory: string): Promise<MediaFile> {
    if (!MediaFiles.cacheCleanup) { MediaFiles.cacheCleanup = this.removeExpired(directory); }
    await MediaFiles.cacheCleanup;
    const policy: DohPolicy = NetworkConfig.getInstance().getDohPolicy();
    const useWeb: boolean = this.webImages !== undefined && NetworkConfig.getInstance().snapshot().syncImageDownloader;
    for (const candidate of address.candidates) {
      if (this.closed) { throw new Error('Media session closed'); }
      let buffer: ArrayBuffer;
      if (useWeb) {
        try { buffer = await this.requestWebImage(candidate); } catch (error) {
          if (error instanceof WebImageDownloadError && error.canTryNextCandidate()) { continue; }
          throw error as Error;
        }
      } else {
        const response = await this.requestImage(candidate, policy);
        // 只对资源不存在继续候选链；鉴权、限流及服务错误直接向用户暴露。
        if (response.responseCode === 404) { continue; }
        if (response.responseCode !== 200 || !(response.result instanceof ArrayBuffer)) {
          throw new Error('Image HTTP status ' + response.responseCode);
        }
        buffer = response.result as ArrayBuffer;
      }
      if (this.closed) { throw new Error('Media session closed'); }
      const extension = imageExtension(buffer);
      const path = directory + '/x-image-' + this.stamp + '-' + address.id + '.' + extension;
      const file = await fileIo.open(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      this.files.push(path);
      try {
        let written = 0;
        while (written < buffer.byteLength) {
          const count = await fileIo.write(file.fd, buffer.slice(written));
          if (count <= 0) { throw new Error('Image write made no progress'); }
          written += count;
        }
      } finally { await fileIo.close(file); }
      const source = image.createImageSource(path);
      try {
        const info = await source.getImageInfo();
        hilog.info(0x0A11, 'OpenTwit', 'event=image_downloaded bytes=%{public}d', buffer.byteLength);
        return { path: path, url: candidate, extension: extension, width: info.size.width,
          height: info.size.height, size: buffer.byteLength, originalSize: /[?&]name=orig(?:&|$)/.test(candidate) };
      } finally { await source.release(); }
    }
    throw new Error('Image resource unavailable');
  }

  /** 同步打开时只使用页面下载通道，失败不跨到另一个 DNS/网络上下文。 */
  private async requestWebImage(url: string): Promise<ArrayBuffer> {
    const service = this.webImages;
    if (!service) { throw new Error('Web image service unavailable'); }
    const request = service.request(url);
    this.webRequests.push(request);
    try { return await request.result; } finally {
      const index = this.webRequests.indexOf(request);
      if (index >= 0) { this.webRequests.splice(index, 1); }
    }
  }

  /** Network Kit 的 DoH 不会自动回退；只有 AUTO 模式允许同一候选改走系统 DNS。 */
  private async requestImage(url: string, policy: DohPolicy): Promise<http.HttpResponse> {
    if (policy.mode !== 'off' && policy.url !== undefined) {
      try {
        return await this.sendRequest(url, policy.url);
      } catch (error) {
        if (policy.mode !== 'auto' || this.closed) { throw error as Error; }
        const code = (error as BusinessError).code;
        hilog.warn(0x0A11, 'OpenTwit', 'event=media_doh_fallback code=%{public}d', code);
      }
    }
    return this.sendRequest(url, undefined);
  }

  private async sendRequest(url: string, dohUrl: string | undefined): Promise<http.HttpResponse> {
    const request = http.createHttp();
    this.requests.push(request);
    try {
      return await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        maxLimit: 25 * 1024 * 1024,
        connectTimeout: 10000,
        readTimeout: 30000,
        dnsOverHttps: dohUrl
      });
    } finally {
      const index = this.requests.indexOf(request);
      if (index >= 0) {
        this.requests.splice(index, 1);
        request.destroy();
      }
    }
  }

  /** 首次下载前回收过期残留，剩余残留按最早修改时间收敛至 128 MiB。 */
  private async removeExpired(directory: string): Promise<void> {
    const names = await fileIo.listFile(directory);
    const retained: CachedImageFile[] = [];
    let total: number = 0;
    for (const name of names) {
      if (!/^x-image-\d+-[A-Za-z0-9_-]+\.(jpg|png|webp|gif)$/.test(name) &&
        !/^x-web-image-\d+-\d+-\d+\.tmp$/.test(name)) { continue; }
      const path = directory + '/' + name;
      const stat = await fileIo.stat(path);
      if (Date.now() / 1000 - stat.mtime > 86400) {
        await fileIo.unlink(path);
      } else {
        retained.push({ path: path, size: stat.size, mtime: stat.mtime });
        total += stat.size;
      }
    }
    retained.sort((left: CachedImageFile, right: CachedImageFile) => left.mtime - right.mtime);
    for (const file of retained) {
      if (total <= 128 * 1024 * 1024) { break; }
      await fileIo.unlink(file.path);
      total -= file.size;
    }
  }

  /** 安全控件授权后直接提交缓存文件，不经过像素解码和重新编码。 */
  save(context: common.UIAbilityContext, file: MediaFile): Promise<void> {
    const task = this.saveFile(context, file);
    this.operations.push(task);
    return task;
  }

  private async saveFile(context: common.UIAbilityContext, file: MediaFile): Promise<void> {
    const helper = photoAccessHelper.getPhotoAccessHelper(context);
    try {
      const change = photoAccessHelper.MediaAssetChangeRequest.createImageAssetRequest(context, fileUri.getUriFromPath(file.path));
      await helper.applyChanges(change);
      hilog.info(0x0A11, 'OpenTwit', 'event=image_saved');
    } finally { await helper.release(); }
  }

  share(context: common.UIAbilityContext, file: MediaFile): Promise<void> {
    if (!canIUse('SystemCapability.Collaboration.SystemShare')) { throw new Error('System share is unavailable'); }
    const data = new systemShare.SharedData({
      utd: file.extension === 'jpg' ? 'general.jpeg' : file.extension === 'png' ? 'general.png' :
        file.extension === 'gif' ? 'general.gif' : 'general.webp',
      uri: fileUri.getUriFromPath(file.path)
    });
    const task = new systemShare.ShareController(data).show(context, { anchor: 'image-share' });
    this.operations.push(task);
    return task;
  }

  async close(): Promise<void> {
    this.closed = true;
    for (const request of this.webRequests.slice()) { request.cancel(); }
    const active = this.requests.slice();
    this.requests = [];
    for (const request of active) { request.destroy(); }
    // 各操作的失败由调用界面提示；此处等待所有分支结束以避免删除正在使用的文件。
    await Promise.allSettled(Array.from(this.downloads.values()));
    await Promise.allSettled(this.operations);
    for (const path of this.files) { await fileIo.unlink(path); }
    this.files = [];
  }
}
