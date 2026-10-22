import web_webview from '@ohos.web.webview';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { KeyCode } from '@kit.InputKit';
import { UIContext } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TWITTER_BASE, TWITTER_COMPOSE } from './WebConfig';
import { fillComposerScript, COMPOSER_READY_SCRIPT, CLICK_POST_BUTTON_SCRIPT, POST_RESULT_SCRIPT,
  unquoteScriptResult } from './WebChrome';

const DOMAIN: number = 0x0A11;
const TAG: string = 'OpenTwit';
const PREFS_NAME: string = 'opentwit_web';
const COMPOSE_DRAFT_KEY: string = 'compose_draft';
const DRAFT_SAVE_DEBOUNCE_MS: number = 700;

/** 页面只提供账号确认和系统交互，草稿及发布过程由会话独占。 */
export interface ComposerHost {
  getUIContext: () => UIContext;
  confirmCurrentAccount: () => Promise<string>;
  acceptHandle: (handle: string, navigate: boolean) => void;
  putPreference: (key: string, value: preferences.ValueType) => Promise<void>;
  toast: (message: ResourceStr) => void;
}

/** 同一编辑会话持有状态、写入队列和定时器，关闭界面不丢失发布恢复标志。 */
@Observed
export class ComposerSession {
  // 展示状态与草稿共用同一个观察对象，页面不再维护镜像字段。
  sheetOpen: boolean = false;
  draft: string = '';
  webComposer: boolean = false;
  composeUrl: string = TWITTER_COMPOSE;
  composeLoading: boolean = true;
  composePreparing: boolean = false;
  posting: boolean = false;
  composeReady: boolean = false;
  // 编辑校验只允许最新版本改变发布资格。
  private composeSyncTimer: number = -1;
  private composeRevision: number = 0;
  postUncertain: boolean = false;
  private composeHandoff: boolean = false;
  composeMessage: ResourceStr = '';
  composeOwner: string = '';
  private legacyDraft: string = '';
  // 发布结果未知时保留恢复标志，停止轮询不等于撤销提交。
  private postTimer: number = -1;
  private postChecks: number = 0;
  private draftWrite: Promise<void> = Promise.resolve();
  openingCompose: boolean = false;
  composeController: web_webview.WebviewController = new web_webview.WebviewController();
  private draftSaveTimer: number = -1;

  private alive: boolean = true;
  private appBackground: boolean = false;
  private host: ComposerHost;

  constructor(host: ComposerHost) {
    this.host = host;
  }

  /** 页面重新出现时恢复生命周期，不重置未确认的发布。 */
  activate(background: boolean): void {
    this.alive = true;
    this.appBackground = background;
  }

  /** 旧版草稿仍需用户确认归属，不能直接归入当前账号。 */
  async initialize(prefs: preferences.Preferences): Promise<void> {
    this.legacyDraft = await prefs.get(COMPOSE_DRAFT_KEY, '') as string;
  }

  /** 前后台切换只暂停可恢复的检查，发布未知状态仍需保留。 */
  setBackground(background: boolean): void {
    this.appBackground = background;
    if (background) {
      this.stopPostCheck();
      this.clearComposeSync();
      if (this.composeOwner !== '' && !this.posting && !this.webComposer) { this.saveDraft(); }
    } else if (this.alive) {
      if (this.sheetOpen && !this.webComposer && !this.posting) { this.scheduleComposeSync(); }
      if (this.posting && this.postUncertain) { this.checkPostResult(); }
    }
  }

  /** 销毁时取消全部定时器并提交尚未防抖落盘的草稿。 */
  dispose(): void {
    this.alive = false;
    this.stopPostCheck();
    this.clearComposeSync();
    if (this.draftSaveTimer !== -1) {
      clearTimeout(this.draftSaveTimer);
      this.draftSaveTimer = -1;
      this.saveDraft();
    }
  }

  /** 文本只从此入口变更，校验和持久化使用同一份草稿。 */
  changeDraft(value: string): void {
    this.draft = value;
    this.scheduleDraftSave();
  }

  /** 网络策略撤销网页时保留已提交操作的未知状态。 */
  networkBlocked(): void {
    this.clearComposeSync();
    if (this.posting) { this.markPostUnknown(); }
  }

  /** 网络恢复后使用新控制器，沿用当前编辑入口。 */
  resetController(): void {
    this.composeController = new web_webview.WebviewController();
  }

  /** 新文档不能沿用旧编辑器的可发布状态。 */
  pageStarted(): void {
    this.composeLoading = true;
    this.clearComposeSync();
  }

  /** 网页加载完成后重新校验当前正文。 */
  pageFinished(): void {
    this.composeLoading = false;
    this.scheduleComposeSync();
  }

  /** 网页退出不代表已经提交的帖子发布失败。 */
  renderExited(): void {
    this.composeLoading = false;
    if (this.posting) { this.markPostUnknown(); }
    this.composeMessage = $r('app.string.editor_failed');
  }

  /** 控制器绑定失败时保留草稿并显示既有错误状态。 */
  controllerFailed(): void {
    this.composeMessage = $r('app.string.editor_failed');
  }

  /** 回复沿用网页上下文，不读取或覆盖原生账号草稿。 */
  openReply(postId: string): void {
    if (this.openingCompose || this.sheetOpen) { return; }
    this.composeOwner = '';
    this.resetController();
    this.composeUrl = TWITTER_BASE + '/intent/tweet?in_reply_to=' + postId;
    this.composeLoading = true;
    this.composePreparing = false;
    this.composeMessage = '';
    this.webComposer = true;
    this.posting = false;
    this.sheetOpen = true;
  }

  /** 引用入口由主页面确认，会话仅承接已确认的网页编辑地址。 */
  openQuote(url: string, owner: string): void {
    this.composeOwner = owner;
    this.resetController();
    this.composeUrl = url;
    this.composeLoading = true;
    this.webComposer = true;
    this.sheetOpen = true;
  }

  /** 当前账号确认后才读取其草稿，旧草稿需要用户确认归属。 */
  async openCompose(sharedText: string = ''): Promise<void> {
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
      const handle: string = await this.host.confirmCurrentAccount();
      if (!this.sheetOpen) { return; }
      if (!/^[A-Za-z0-9_]{1,15}$/.test(handle)) {
        this.composeMessage = $r('app.string.account_unconfirmed');
        return;
      }
      const owner: string = handle.toLowerCase();
      const ctx = this.host.getUIContext().getHostContext() as common.UIAbilityContext;
      const prefs = await preferences.getPreferences(ctx, PREFS_NAME);
      const draft = await prefs.get(COMPOSE_DRAFT_KEY + ':' + owner, '') as string;
      const uncertain = await prefs.get('post_pending:' + owner, false) as boolean;
      const handoff = await prefs.get('compose_handoff:' + owner, '') as string;
      if (!this.sheetOpen) { return; }
      this.composeOwner = owner;
      this.host.acceptHandle(handle, false);
      this.draft = draft;
      this.composeHandoff = handoff !== '';
      this.postUncertain = uncertain || this.composeHandoff;
      this.composeMessage = this.composeHandoff ? $r('app.string.compose_handoff') :
        this.postUncertain ? $r('app.string.post_unknown') : '';
      if (sharedText !== '') {
        if (this.postUncertain) {
          this.host.toast($r('app.string.incoming_busy'));
        } else if (draft === '') {
          this.draft = sharedText;
          await this.persistDraft();
        } else {
          this.host.getUIContext().showAlertDialog({
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
        this.host.getUIContext().showAlertDialog({
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
      await this.host.putPreference(COMPOSE_DRAFT_KEY, '');
      this.legacyDraft = '';
      this.scheduleComposeSync();
    } catch (err) {
      this.host.toast($r('app.string.draft_save_failed'));
    }
  }

  /** 按账号串行保存快照，后续编辑不能被较早的写入覆盖。 */
  private persistDraft(): Promise<void> {
    if (this.composeOwner === '') { return Promise.resolve(); }
    const key = COMPOSE_DRAFT_KEY + ':' + this.composeOwner;
    const value = this.draft;
    // 顺序写入防止较早的防抖任务覆盖后续草稿；每次失败仍由调用方显示。
    const save = (): Promise<void> => this.host.putPreference(key, value);
    this.draftWrite = this.draftWrite.then(save, save);
    return this.draftWrite;
  }

  /** 网页编辑器可能另有未保存内容，关闭前继续要求用户确认。 */
  closeCompose(): void {
    if (this.posting) { return; }
    if (this.webComposer) {
      this.host.getUIContext().showAlertDialog({
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
      this.host.toast($r('app.string.draft_save_failed'));
    }
  }

  private stopPostCheck(): void {
    if (this.postTimer !== -1) { clearTimeout(this.postTimer); this.postTimer = -1; }
  }

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
    if (!this.alive || this.appBackground || !this.sheetOpen || this.webComposer || this.composeLoading || this.composePreparing ||
      this.posting || this.postUncertain || this.draft.trim() === '' || this.composeOwner === '') { return; }
    const revision = this.composeRevision;
    const text = this.draft;
    this.composeSyncTimer = setTimeout(async () => {
      this.composeSyncTimer = -1;
      try {
        const filled = unquoteScriptResult(await this.composeController.runJavaScript(fillComposerScript(text)));
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
      this.host.toast($r('app.string.draft_save_failed'));
    });
  }

  /** 消费编辑快捷键，避免关闭或发布事件再次传递给输入框。 */
  composeKey(event: KeyEvent): boolean {
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
    if (event.metaKey === 1 || ComposerSession.ctrlDown(event)) {
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

  /** 先保存提交意图；未知结果不得自动重发或清空草稿。 */
  async postFromSheet(): Promise<void> {
    if (!this.composeReady || this.draft.trim() === '' || this.posting || this.postUncertain || this.webComposer ||
      this.composePreparing || this.composeLoading || this.composeOwner === '') { return; }
    this.posting = true;
    this.clearComposeSync();
    this.composeMessage = '';
    if (this.draftSaveTimer !== -1) { clearTimeout(this.draftSaveTimer); this.draftSaveTimer = -1; }
    try {
      await this.persistDraft();
      const account = await this.host.confirmCurrentAccount();
      if (account.toLowerCase() !== this.composeOwner) {
        this.composeMessage = $r('app.string.account_changed');
        this.posting = false;
        return;
      }
      const filled = unquoteScriptResult(await this.composeController.runJavaScript(fillComposerScript(this.draft)));
      if (filled !== 'ok') {
        this.composeMessage = $r('app.string.compose_fill_failed');
        this.posting = false;
        return;
      }
      await this.host.putPreference('post_pending:' + this.composeOwner, true);
      this.postUncertain = true;
      const result = unquoteScriptResult(await this.composeController.runJavaScript(CLICK_POST_BUTTON_SCRIPT));
      if (result === 'missing' || result === 'disabled') {
        await this.host.putPreference('post_pending:' + this.composeOwner, false);
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

  /** 只有确认成功才清空草稿，超时和读取失败保留待核对状态。 */
  private async checkPostResult(): Promise<void> {
    if (this.appBackground || !this.alive) { return; }
    try {
      const result = unquoteScriptResult(await this.composeController.runJavaScript(POST_RESULT_SCRIPT));
      if (result === 'confirmed') {
        // 先落盘清除草稿，再解除待确认标记，避免进程退出后重复发送。
        await this.draftWrite;
        await this.host.putPreference(COMPOSE_DRAFT_KEY + ':' + this.composeOwner, '');
        await this.host.putPreference('post_pending:' + this.composeOwner, false);
        if (this.draftSaveTimer !== -1) { clearTimeout(this.draftSaveTimer); this.draftSaveTimer = -1; }
        this.draft = '';
        this.postUncertain = false;
        this.posting = false;
        this.sheetOpen = false;
        this.host.toast($r('app.string.compose_post_sent'));
        return;
      }
      if (result === 'unknown' || ++this.postChecks >= 16) { this.markPostUnknown(); return; }
      if (!this.appBackground && this.alive) { this.postTimer = setTimeout(() => { this.checkPostResult(); }, 1000); }
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

  /** 未知结果只能由用户核对后解除限制，不能自动重发。 */
  async resolveUnknownPost(): Promise<void> {
    if (this.composeHandoff) {
      this.host.getUIContext().showAlertDialog({
        title: $r('app.string.compose_handoff_title'), message: $r('app.string.compose_handoff_message'),
        buttons: [
          { value: $r('app.string.compose_cancel'), action: () => {} },
          { value: $r('app.string.post_checked'), action: () => { this.clearPendingPost(); } },
          { value: $r('app.string.compose_handoff_clear'), action: () => { this.clearHandoffDraft(); } }
        ]
      });
      return;
    }
    this.host.getUIContext().showAlertDialog({
      title: $r('app.string.post_unknown_title'),
      message: $r('app.string.post_check_message'),
      primaryButton: { value: $r('app.string.compose_cancel'), action: () => {} },
      secondaryButton: { value: $r('app.string.post_checked'), action: () => { this.clearPendingPost(); } }
    });
  }

  private async clearPendingPost(): Promise<void> {
    try {
      await this.host.putPreference('post_pending:' + this.composeOwner, false);
      await this.host.putPreference('compose_handoff:' + this.composeOwner, '');
      this.composeHandoff = false;
      this.postUncertain = false;
      this.composeMessage = '';
      this.composeController.loadUrl(TWITTER_COMPOSE);
    } catch (err) { this.host.toast($r('app.string.operation_failed')); }
  }

  /** 只有用户确认发布或放弃后删除移交快照，先删正文再解除发布限制。 */
  private async clearHandoffDraft(): Promise<void> {
    try {
      await this.draftWrite;
      await this.host.putPreference(COMPOSE_DRAFT_KEY + ':' + this.composeOwner, '');
      await this.host.putPreference('post_pending:' + this.composeOwner, false);
      await this.host.putPreference('compose_handoff:' + this.composeOwner, '');
      this.draft = '';
      this.composeHandoff = false;
      this.postUncertain = false;
      this.composeMessage = '';
      this.composeController.loadUrl(TWITTER_COMPOSE);
    } catch (error) { this.host.toast($r('app.string.draft_save_failed')); }
  }

  /** 手动移交正文时保留本地恢复副本。 */
  async copyComposeDraft(): Promise<void> {
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.draft));
      this.host.toast($r('app.string.media_copied'));
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'event=draft_copy_failed error=%{public}s', JSON.stringify(error));
      this.host.toast($r('app.string.operation_failed'));
    }
  }

  /** 先保存恢复屏障，再将编辑权交给真实网页。 */
  async openWebComposer(): Promise<void> {
    if (this.posting || this.postUncertain) { return; }
    this.posting = true;
    this.clearComposeSync();
    if (this.draftSaveTimer !== -1) { clearTimeout(this.draftSaveTimer); this.draftSaveTimer = -1; }
    try {
      await this.persistDraft();
      if (this.draft !== '' && this.composeOwner !== '') {
        // 账号键关联正文，移交标识区分同一账号后续新建的草稿；恢复时必须由用户确认。
        await this.host.putPreference('compose_handoff:' + this.composeOwner, Date.now().toString() + '-' + this.composeRevision);
        this.composeHandoff = true;
        this.postUncertain = true;
        const account = await this.host.confirmCurrentAccount();
        if (account.toLowerCase() !== this.composeOwner) { throw new Error('Compose account unconfirmed'); }
        const result = unquoteScriptResult(await this.composeController.runJavaScript(fillComposerScript(this.draft)));
        if (result !== 'ok') { throw new Error('Compose text transfer failed'); }
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'event=compose_handoff_failed error=%{public}s', JSON.stringify(err));
      this.host.toast($r('app.string.compose_manual_transfer'));
    } finally {
      // 自动填充失败仍允许用户进入真实网页；恢复副本不因显示网页而删除。
      this.webComposer = true;
      this.posting = false;
    }
  }
}
