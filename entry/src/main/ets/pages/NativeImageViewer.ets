import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { KeyCode } from '@kit.InputKit';
import { curves, window } from '@kit.ArkUI';
import { MediaAddress } from '../common/WebMedia';
import { MediaFile, MediaFiles } from '../common/MediaFiles';
import { WebImageDownloads } from '../common/WebImageDownloads';
import { FONT_FAMILY, S8, S12, S16, TOUCH_TARGET } from '../common/Theme';

/** 全窗口画布保留底层网页，只有悬浮操作栏避让系统区域。 */
@Component
export struct NativeImageViewer {
  items: MediaAddress[] = [];
  initialIndex: number = 0;
  webImages: WebImageDownloads | undefined = undefined;
  onClose: () => void = () => {};
  onRecover: () => void = () => {};
  onWeb: () => void = () => {};
  @State index: number = 0;
  @State loadedFiles: (MediaFile | undefined)[] = [];
  @State loadingIndices: number[] = [];
  @State failedIndices: number[] = [];
  @State busy: boolean = false;
  @State zoomed: boolean = false;
  @State chromeVisible: boolean = true;
  @State backdropOpacity: number = 1;
  @State dragging: boolean = false;
  @State topInset: number = 0;
  @State bottomInset: number = 0;
  @State leftInset: number = 0;
  @State rightInset: number = 0;
  private viewerWindow: window.Window | undefined = undefined;
  private previousBars: window.SystemBarProperties | undefined = undefined;
  private previousFullScreen: boolean = false;
  private windowReady: Promise<void> = Promise.resolve();
  private avoidChanged: (options: window.AvoidAreaOptions) => void = () => this.updateInsets();
  private files: MediaFiles = new MediaFiles();
  private alive: boolean = true;
  private swiper: SwiperController = new SwiperController();
  private chromeHideTimer: number = -1;

  aboutToAppear(): void {
    this.files = new MediaFiles(this.webImages);
    this.windowReady = this.prepareWindow();
    this.index = this.initialIndex;
    this.loadIndex(this.index);
    this.loadIndex(this.index + 1);
    // 首次浏览后让出画布；用户主动操作后由单击控制显隐。
    this.chromeHideTimer = setTimeout(() => {
      this.chromeHideTimer = -1;
      if (this.chromeVisible) { this.toggleChrome(); }
    }, 3000);
  }

  aboutToDisappear(): void {
    this.alive = false;
    clearTimeout(this.chromeHideTimer);
    this.windowReady.then(async () => {
      if (this.viewerWindow) {
        this.viewerWindow.off('avoidAreaChange', this.avoidChanged);
        if (this.previousBars) {
          await this.viewerWindow.setWindowLayoutFullScreen(this.previousFullScreen);
          await this.viewerWindow.setWindowSystemBarProperties(this.previousBars);
        }
      }
    }).catch((error: Error) => {
      hilog.error(0x0A11, 'OpenTwit', 'event=image_window_restore_failed error=%{public}s', error.message);
    });
    this.files.close().catch((error: Error) => {
      hilog.error(0x0A11, 'OpenTwit', 'event=image_cleanup_failed error=%{public}s', error.message);
    });
  }

  /** 模态内容覆盖状态栏；用真实窗口避让区负责一次性留白并恢复系统栏外观。 */
  private async prepareWindow(): Promise<void> {
    try {
      this.viewerWindow = await window.getLastWindow(this.getUIContext().getHostContext() as common.UIAbilityContext);
      if (!this.alive) { return; }
      this.previousBars = this.viewerWindow.getWindowSystemBarProperties();
      this.previousFullScreen = this.viewerWindow.getWindowProperties().isLayoutFullScreen;
      await this.viewerWindow.setWindowLayoutFullScreen(true);
      this.updateInsets();
      this.viewerWindow.on('avoidAreaChange', this.avoidChanged);
      await this.viewerWindow.setWindowSystemBarProperties({ statusBarColor: '#00000000', statusBarContentColor: '#FFFFFF',
        navigationBarColor: '#00000000', navigationBarContentColor: '#FFFFFF' });
    } catch (error) {
      hilog.error(0x0A11, 'OpenTwit', 'event=image_window_failed error=%{public}s', JSON.stringify(error));
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.operation_failed') });
    }
  }

  private updateInsets(): void {
    if (!this.viewerWindow) { return; }
    const system = this.viewerWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    const cutout = this.viewerWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
    const navigation = this.viewerWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
    const ui = this.getUIContext();
    this.topInset = ui.px2vp(Math.max(system.topRect.height, cutout.topRect.height));
    this.bottomInset = ui.px2vp(Math.max(system.bottomRect.height, cutout.bottomRect.height, navigation.bottomRect.height));
    this.leftInset = ui.px2vp(Math.max(system.leftRect.width, cutout.leftRect.width));
    this.rightInset = ui.px2vp(Math.max(system.rightRect.width, cutout.rightRect.width));
  }

  private currentFile(): MediaFile | undefined {
    return this.loadedFiles[this.index];
  }

  /** 每张图保留已完成的文件；整体替换数组，确保 V1 状态更新可观察。 */
  private async loadIndex(index: number): Promise<void> {
    if (index >= this.items.length || this.loadedFiles[index] || this.loadingIndices.includes(index)) { return; }
    this.loadingIndices = [...this.loadingIndices, index];
    this.failedIndices = this.failedIndices.filter((value: number) => value !== index);
    try {
      const file = await this.files.load(this.items[index], this.getUIContext().getHostContext() as common.UIAbilityContext);
      if (this.alive) {
        const loaded = this.loadedFiles.slice();
        loaded[index] = file;
        this.loadedFiles = loaded;
      }
    } catch (error) {
      if (this.alive) {
        this.chromeVisible = true;
        clearTimeout(this.chromeHideTimer);
        this.failedIndices = [...this.failedIndices, index];
        hilog.error(0x0A11, 'OpenTwit', 'event=image_load_failed error=%{public}s', JSON.stringify(error));
      }
    } finally {
      if (this.alive) { this.loadingIndices = this.loadingIndices.filter((value: number) => value !== index); }
    }
  }

  private async act(action: string): Promise<void> {
    const file = this.currentFile();
    if (!file || this.busy) { return; }
    clearTimeout(this.chromeHideTimer);
    this.busy = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (action === 'save') {
        await this.files.save(context, file);
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.media_saved') });
      } else if (action === 'share') {
        await this.files.share(context, file);
      } else {
        await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, file.url));
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.media_copied') });
      }
    } catch (error) {
      hilog.error(0x0A11, 'OpenTwit', 'event=image_action_failed action=%{public}s error=%{public}s', action, JSON.stringify(error));
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.operation_failed') });
    } finally { this.busy = false; }
  }

  private formatBytes(bytes: number): string {
    return bytes >= 1024 * 1024 ? (bytes / (1024 * 1024)).toFixed(1) + ' MB' :
      Math.max(1, Math.round(bytes / 1024)) + ' KB';
  }

  private toggleChrome(): void {
    clearTimeout(this.chromeHideTimer);
    this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseInOut }, () => {
      this.chromeVisible = !this.chromeVisible;
    });
  }

  /** 放大图片的越界拖动在松手后切页，避免中途切换手势识别器。 */
  private turnPage(direction: number): void {
    const target = this.index + direction;
    if (this.busy || target < 0 || target >= this.items.length) { return; }
    if (direction > 0) { this.swiper.showNext(); } else { this.swiper.showPrevious(); }
  }

  @Builder
  glassButton(symbol: Resource, label: Resource, id: string, action: () => void) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph(symbol).fontSize(20).fontColor([Color.White])
    }
    .id(id).width(TOUCH_TARGET).height(TOUCH_TARGET)
    .backgroundColor('#66000000')
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.DARK })
    .border({ width: 0.5, color: '#26FFFFFF' })
    .enabled(id === 'image-close' || (this.loadedFiles[this.index] !== undefined && !this.busy))
    .opacity(id === 'image-close' || (this.loadedFiles[this.index] !== undefined && !this.busy) ? 1 : 0.38)
    .accessibilityText(label).onClick(action)
  }

  @Builder
  topBar() {
    Row() {
      this.glassButton($r('sys.symbol.xmark'), $r('app.string.media_close'), 'image-close', this.onClose)
      Blank()
      if (this.items.length > 1) {
        Text((this.index + 1) + ' / ' + this.items.length)
          .fontSize(13).fontFamily(FONT_FAMILY).fontWeight(FontWeight.Medium).fontColor(Color.White)
          .padding({ left: S12, right: S12, top: 6, bottom: 6 })
          .backgroundColor('#66000000').borderRadius(16)
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.DARK })
      }
    }
    .width('100%')
    .padding({ top: this.topInset + S8, bottom: S16, left: this.leftInset + S16, right: this.rightInset + S16 })
    .linearGradient({ direction: GradientDirection.Bottom, colors: [['#80000000', 0], ['#00000000', 1]] })
    .opacity(this.chromeVisible && !this.dragging ? 1 : 0)
    .hitTestBehavior(this.chromeVisible && !this.dragging ? HitTestMode.Transparent : HitTestMode.None)
  }

  @Builder
  metadata() {
    Row({ space: 6 }) {
      if (this.loadingIndices.includes(this.index)) {
        LoadingProgress().width(14).height(14).color(Color.White)
        Text($r('app.string.media_loading')).fontFamily(FONT_FAMILY).fontSize(11).fontColor('#B3FFFFFF')
      } else if (this.failedIndices.includes(this.index)) {
        Text($r('app.string.media_failed')).fontFamily(FONT_FAMILY).fontSize(11).fontColor('#B3FFFFFF')
      } else if (this.loadedFiles[this.index]) {
        Text(this.loadedFiles[this.index]!.originalSize ? $r('app.string.media_original_size') : $r('app.string.media_available_size'))
          .fontFamily(FONT_FAMILY).fontSize(11).fontColor('#B3FFFFFF')
        Text('· ' + this.loadedFiles[this.index]!.width + ' × ' + this.loadedFiles[this.index]!.height + ' · ' +
          this.loadedFiles[this.index]!.extension.toUpperCase() + ' · ' + this.formatBytes(this.loadedFiles[this.index]!.size))
          .fontFamily(FONT_FAMILY).fontSize(11).fontColor('#B3FFFFFF')
      }
    }
    .height(26).padding({ left: S12, right: S12 }).justifyContent(FlexAlign.Center)
    .backgroundColor('#4D000000').borderRadius(13)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THIN, { colorMode: ThemeColorMode.DARK })
  }

  @Builder
  bottomBar() {
    Column({ space: S12 }) {
      this.metadata()
      if (this.failedIndices.includes(this.index)) {
        Row({ space: S12 }) {
          Button($r('app.string.retry')).onClick(() => {
            if (this.webImages?.needsRecovery()) { this.onRecover(); }
            else { this.loadIndex(this.index); }
          })
          Button($r('app.string.media_view_web')).onClick(this.onWeb)
        }
      }
      Row({ space: 28 }) {
        Stack() {
          // 安全控件仅用其支持的样式；模糊材质在背后，不能遮盖控件或降低控件透明度。
          SaveButton({ icon: SaveIconStyle.FULL_FILLED, buttonType: ButtonType.Circle })
            .id('image-save').width(TOUCH_TARGET).height(TOUCH_TARGET).padding(12)
            .iconSize(20).iconColor(Color.White).backgroundColor('#66000000')
            .borderWidth(0.5).borderColor('#26FFFFFF')
            .enabled(this.currentFile() !== undefined && !this.busy && this.chromeVisible && !this.dragging)
            .onClick((_event: ClickEvent, result: SaveButtonOnClickResult) => {
              if (result === SaveButtonOnClickResult.SUCCESS) { this.act('save'); }
              else if (result === SaveButtonOnClickResult.TEMPORARY_AUTHORIZATION_FAILED) {
                hilog.error(0x0A11, 'OpenTwit', 'event=image_save_authorization_failed');
                this.getUIContext().getPromptAction().showToast({ message: $r('app.string.operation_failed') });
              }
            })
        }
        .borderRadius(TOUCH_TARGET / 2)
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.DARK })
        this.glassButton($r('sys.symbol.share'), $r('app.string.media_share'), 'image-share', () => this.act('share'))
        this.glassButton($r('sys.symbol.link'), $r('app.string.media_copy'), 'image-copy', () => this.act('copy'))
      }.justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .padding({ top: S16, bottom: this.bottomInset + S16, left: this.leftInset + S16, right: this.rightInset + S16 })
    .linearGradient({ direction: GradientDirection.Top, colors: [['#80000000', 0], ['#00000000', 1]] })
    .opacity(this.chromeVisible && !this.dragging ? 1 : 0)
    .hitTestBehavior(this.chromeVisible && !this.dragging ? HitTestMode.Transparent : HitTestMode.None)
  }

  build() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor(Color.Black).opacity(this.backdropOpacity)
        .hitTestBehavior(HitTestMode.None)
      Swiper(this.swiper) {
        ForEach(this.items, (item: MediaAddress, index: number) => {
          ZoomImage({
            source: this.loadedFiles[index] ? 'file://' + this.loadedFiles[index]!.path : '',
            pixelWidth: this.loadedFiles[index] ? this.loadedFiles[index]!.width : 0,
            pixelHeight: this.loadedFiles[index] ? this.loadedFiles[index]!.height : 0,
            active: index === this.index,
            onZoom: (zoomed: boolean) => { if (index === this.index) { this.zoomed = zoomed; } },
            onToggleChrome: () => this.toggleChrome(),
            onBackdrop: (opacity: number, dragging: boolean) => {
              if (index === this.index) { this.backdropOpacity = opacity; this.dragging = dragging; }
            },
            onPage: (direction: number) => this.turnPage(direction),
            onShare: () => this.act('share'), onClose: this.onClose
          })
        }, (item: MediaAddress) => item.id)
      }
      .index(this.index).loop(false).indicator(false).disableSwipe(this.zoomed || this.busy)
      .width('100%').height('100%')
      .onChange((index: number) => {
        this.index = index;
        this.zoomed = false;
        this.backdropOpacity = 1;
        this.dragging = false;
        this.loadIndex(index);
        this.loadIndex(index + 1);
      })
      Column() {
        this.topBar()
        Blank().hitTestBehavior(HitTestMode.None)
        this.bottomBar()
      }.width('100%').height('100%').hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%').height('100%')
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM,
      LayoutSafeAreaEdge.START, LayoutSafeAreaEdge.END])
    .onKeyEvent((event: KeyEvent) => {
      if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ESCAPE) { this.onClose(); return true; }
      return false;
    })
  }
}

/** 图片在全窗口内变换；普通横滑由 Swiper 处理，放大越界松手后切图。 */
@Component
struct ZoomImage {
  @Prop source: string = '';
  @Prop pixelWidth: number = 0;
  @Prop pixelHeight: number = 0;
  @Prop @Watch('reset') active: boolean = false;
  onZoom: (zoomed: boolean) => void = () => {};
  onToggleChrome: () => void = () => {};
  onBackdrop: (opacity: number, dragging: boolean) => void = () => {};
  onPage: (direction: number) => void = () => {};
  onShare: () => void = () => {};
  onClose: () => void = () => {};
  @State scaleValue: number = 1;
  @State x: number = 0;
  @State y: number = 0;
  @State widthValue: number = 0;
  @State heightValue: number = 0;
  private startScale: number = 1;
  private startX: number = 0;
  private startY: number = 0;
  private dismissing: boolean = false;
  private pinching: boolean = false;

  private reset(): void {
    this.scaleValue = 1;
    this.x = 0;
    this.y = 0;
    this.dismissing = false;
    this.onZoom(false);
    this.onBackdrop(1, false);
  }

  private animateReset(): void {
    this.getUIContext().animateTo({ curve: curves.springMotion(0.32, 0.82) }, () => this.reset());
  }

  private finishPinch(): void {
    this.pinching = false;
    if (this.scaleValue < 1.08) { this.animateReset(); }
    else { this.clamp(); this.onZoom(true); }
  }

  private finishPan(event: GestureEvent): void {
    if (this.pinching) { return; }
    if (this.dismissing) {
      if (this.y > 110 || (this.y > 24 && event.velocityY > 900)) {
        this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut,
          onFinish: () => { if (this.active) { this.onClose(); } } }, () => {
          this.onBackdrop(0, true);
          this.scaleValue = 0.68;
          this.y += 160;
        });
      } else { this.animateReset(); }
    } else if (Math.abs(event.offsetX) > Math.abs(event.offsetY) * 1.15) {
      const rawX = this.startX + event.offsetX;
      const limit = this.bound(true);
      if (rawX > limit + 64) { this.onPage(-1); }
      else if (rawX < -limit - 64) { this.onPage(1); }
    }
  }

  private bound(horizontal: boolean): number {
    const ratio = this.pixelWidth > 0 && this.pixelHeight > 0 ?
      Math.min(this.widthValue / this.pixelWidth, this.heightValue / this.pixelHeight) : 1;
    const dimension = horizontal ? (this.pixelWidth > 0 ? this.pixelWidth * ratio : this.widthValue) :
      (this.pixelHeight > 0 ? this.pixelHeight * ratio : this.heightValue);
    return Math.max(0, (dimension * this.scaleValue - (horizontal ? this.widthValue : this.heightValue)) / 2);
  }

  private clamp(): void {
    this.x = Math.max(-this.bound(true), Math.min(this.bound(true), this.x));
    this.y = Math.max(-this.bound(false), Math.min(this.bound(false), this.y));
  }

  build() {
    Stack() {
      if (this.source !== '') {
        Image(this.source).width('100%').height('100%').objectFit(ImageFit.Contain)
          .scale({ x: this.scaleValue, y: this.scaleValue }).translate({ x: this.x, y: this.y })
          .draggable(false)
      }
    }.width('100%').height('100%')
    .onAreaChange((_old: Area, area: Area) => {
      this.widthValue = Number(area.width); this.heightValue = Number(area.height);
      if (this.scaleValue > 1) { this.clamp(); }
    })
    .gesture(GestureGroup(GestureMode.Parallel,
      GestureGroup(GestureMode.Exclusive,
        TapGesture({ count: 2 }).onAction((event: GestureEvent) => {
          if (this.scaleValue > 1.01) { this.animateReset(); return; }
          this.getUIContext().animateTo({ duration: 280, curve: Curve.FastOutSlowIn }, () => {
            this.scaleValue = 2.5;
            if (event.fingerList.length > 0) {
              this.x = (this.widthValue / 2 - event.fingerList[0].localX) * 1.5;
              this.y = (this.heightValue / 2 - event.fingerList[0].localY) * 1.5;
            }
            this.clamp(); this.onZoom(true);
          });
        }),
        TapGesture({ count: 1 }).onAction(() => this.onToggleChrome()),
        LongPressGesture().onAction(() => this.onShare())
      ),
      PinchGesture({ fingers: 2 })
        .onActionStart(() => {
          this.pinching = true;
          this.dismissing = false;
          this.startScale = this.scaleValue;
          this.onBackdrop(1, false);
          this.onZoom(true);
        })
        .onActionUpdate((event: GestureEvent) => {
          this.scaleValue = Math.max(0.75, Math.min(5, this.startScale * event.scale));
          this.clamp();
        })
        .onActionEnd(() => this.finishPinch())
        .onActionCancel(() => this.finishPinch()),
      PanGesture({ fingers: 1, direction: PanDirection.All }).tag('image-pan')
        .onActionStart(() => {
          this.startX = this.x; this.startY = this.y;
          this.dismissing = this.scaleValue <= 1.01;
        })
        .onActionUpdate((event: GestureEvent) => {
          if (this.pinching) { return; }
          if (this.dismissing) {
            this.x = event.offsetX * 0.85;
            this.y = Math.max(0, event.offsetY);
            const ratio = Math.min(this.y / 380, 1);
            this.scaleValue = 1 - ratio * 0.32;
            this.onBackdrop(1 - ratio, true);
          } else {
            this.x = this.startX + event.offsetX;
            this.y = this.startY + event.offsetY;
            this.clamp();
          }
        })
        .onActionEnd((event: GestureEvent) => this.finishPan(event))
        .onActionCancel(() => { if (this.dismissing && !this.pinching) { this.animateReset(); } })
    ))
    .onGestureRecognizerJudgeBegin((event: BaseGestureEvent, recognizer: GestureRecognizer) => {
      if (recognizer.getTag() === 'image-pan' && this.scaleValue <= 1.01) {
        const pan = event as PanGestureEvent;
        if (Math.abs(pan.offsetX) >= Math.abs(pan.offsetY) || pan.offsetY <= 0) { return GestureJudgeResult.REJECT; }
      }
      return GestureJudgeResult.CONTINUE;
    })
  }
}
