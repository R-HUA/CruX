import { common } from '@kit.AbilityKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { systemShare } from '@kit.ShareKit';
import webview from '@ohos.web.webview';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { WebImageDownloads } from './WebImageDownloads';

/** 只将站内业务留在当前页面，普通外链交给浏览器。 */
export function isSiteUrl(value: string): boolean {
  return /^https:\/\/(www\.)?(x|twitter)\.com([/?#]|$)/i.test(value);
}

/** 认证页面需留给网页完成当前会话，不按普通外链处理。 */
export function isAuthUrl(value: string): boolean {
  return /^https:\/\/(accounts\.google\.com|appleid\.apple\.com)([/?#]|$)/i.test(value);
}

/** 系统相册只接管可准确表达的媒体类型，其余由 ArkWeb 默认选择器处理。 */
export function mediaAcceptTypes(types: string[]): string[] {
  const result: string[] = [];
  const extensions: Record<string, string> = {
    '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png',
    '.gif': 'image/gif', '.webp': 'image/webp', '.mp4': 'video/mp4', '.mov': 'video/quicktime'
  };
  for (const item of types) {
    for (const part of item.split(',')) {
      const type = part.trim().toLowerCase();
      const normalized = extensions[type] || type;
      if (!/^(image|video)\/[a-z0-9.*+-]+$/.test(normalized)) { return []; }
      if (result.indexOf(normalized) < 0) { result.push(normalized); }
    }
  }
  return result.length <= 10 ? result : [];
}

/** 每个文件请求只答复一次；取消为空列表，异常另外提示。 */
export async function chooseMedia(event: OnShowFileSelectorEvent, types: string[],
  failed: () => void): Promise<void> {
  let uris: string[] = [];
  try {
    const options = new photoAccessHelper.PhotoSelectOptions();
    options.mimeTypeFilter = { mimeTypeArray: types };
    options.maxSelectNumber = event.fileSelector.getMode() === FileSelectorMode.FileOpenMultipleMode ? 500 : 1;
    const result = await new photoAccessHelper.PhotoViewPicker().select(options);
    uris = result.photoUris;
  } catch (err) {
    hilog.error(0x0A11, 'OpenTwit', 'event=file_select_failed error=%{public}s', JSON.stringify(err));
    failed();
  }
  event.result.handleFileList(uris);
}

/** 分享真实链接，不重新组织网页业务数据。 */
export async function sharePage(context: common.UIAbilityContext, link: string): Promise<void> {
  if (!canIUse('SystemCapability.Collaboration.SystemShare')) {
    throw new Error('System share is unavailable');
  }
  const data = new systemShare.SharedData({ utd: 'general.hyperlink', content: link });
  await new systemShare.ShareController(data).show(context, { anchor: 'page-share' });
}

/** 仅回收本应用拥有的下载文件；已被系统移除等同回收完成。 */
async function removeDownload(path: string): Promise<void> {
  try { await fileIo.unlink(path); } catch (error) {
    if ((error as BusinessError).code !== 13900002) { throw error as Error; }
  }
}

/** 启动时清理上次进程留下的普通下载，不触碰当前下载代理的文件。 */
export async function removeExpiredDownloads(directory: string): Promise<void> {
  const names = await fileIo.listFile(directory);
  for (const name of names) {
    if (!/^web-download-\d+-\d+$/.test(name)) { continue; }
    await removeDownload(directory + '/' + name);
  }
}

/** 下载由 ArkWeb 保留会话，完成后由用户选择保存位置。 */
export function installDownloads(controller: webview.WebviewController, context: common.UIAbilityContext,
  report: (result: string) => void, images?: WebImageDownloads): webview.WebDownloadDelegate {
  const delegate = new webview.WebDownloadDelegate();
  let sequence: number = 0;
  const paths: Map<string, string> = new Map();
  delegate.onBeforeDownload((item: webview.WebDownloadItem) => {
    if (images && images.beforeDownload(item)) { return; }
    try {
      const path = context.cacheDir + '/web-download-' + Date.now() + '-' + (++sequence);
      paths.set(item.getGuid(), path);
      item.start(path);
    } catch (err) {
      hilog.error(0x0A11, 'OpenTwit', 'event=download_start_failed error=%{public}s', JSON.stringify(err));
      report('failed');
      const path = paths.get(item.getGuid());
      if (path) {
        removeDownload(path).then(() => { paths.delete(item.getGuid()); }).catch((error: Error) => {
          hilog.error(0x0A11, 'OpenTwit', 'event=download_cleanup_failed error=%{public}s', error.message);
          report('cleanup_failed');
        });
      }
    }
  });
  delegate.onDownloadUpdated((item: webview.WebDownloadItem) => {
    if (images) { images.downloadUpdated(item); }
  });
  delegate.onDownloadFailed(async (item: webview.WebDownloadItem) => {
    if (images && images.downloadFailed(item)) { return; }
    hilog.error(0x0A11, 'OpenTwit', 'event=download_failed code=%{public}d', item.getLastErrorCode());
    report('failed');
    const path = paths.get(item.getGuid());
    if (path) {
      try { await removeDownload(path); paths.delete(item.getGuid()); } catch (error) {
        hilog.error(0x0A11, 'OpenTwit', 'event=download_cleanup_failed error=%{public}s', JSON.stringify(error));
        report('cleanup_failed');
      }
    }
  });
  delegate.onDownloadFinish(async (item: webview.WebDownloadItem) => {
    if (images && images.downloadFinish(item)) { return; }
    const path: string = item.getFullPath();
    let result: string = 'cancelled';
    try {
      const selected = await new picker.DocumentViewPicker(context).save({ newFileNames: [item.getSuggestedFileName()] });
      if (selected.length > 0) {
        const destination = await fileIo.open(selected[0], fileIo.OpenMode.READ_WRITE);
        try {
          await fileIo.copyFile(path, destination.fd);
        } finally {
          await fileIo.close(destination);
        }
        result = 'saved';
      }
    } catch (err) {
      hilog.error(0x0A11, 'OpenTwit', 'event=download_save_failed error=%{public}s', JSON.stringify(err));
      result = 'failed';
    } finally {
      try { await removeDownload(path); paths.delete(item.getGuid()); } catch (err) {
        hilog.error(0x0A11, 'OpenTwit', 'event=download_cleanup_failed error=%{public}s', JSON.stringify(err));
        result = 'cleanup_failed';
      }
    }
    report(result);
  });
  controller.setDownloadDelegate(delegate);
  return delegate;
}
