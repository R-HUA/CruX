import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { KeyCode } from '@kit.InputKit';
import { curves, uiMaterial, window } from '@kit.ArkUI';
import { visionImageAnalyzer } from '@kit.VisionKit';
import { MediaAddress, imageForQuality } from '../common/WebMedia';
import { MediaFile, MediaFiles } from '../common/MediaFiles';
import { WebImageDownloads } from '../common/WebImageDownloads';
import { FONT_FAMILY, S8, S12, S16, TOUCH_TARGET } from '../common/Theme';

/** 全窗口画布保留底层网页，只有悬浮操作栏避让系统区域。 */
@Component
export struct NativeImageViewer {
  items: MediaAddress[] = [];
  @Link index: number;
  originalImages: boolean = true;
  @Prop immersiveMaterial: boolean = false;
  @Link chromeVisible: boolean;
  @Link dragging: boolean;
  @Link detailsVisible: boolean;
  @Link currentLoadedFile: MediaFile | undefined;
  @Link busy: boolean;
  @Link moreOpen: boolean;
  @Prop footerOffset: number = 80;
  @Prop @Watch('shareRequested') shareTrigger: number = 0;
  @Link analyzerSelecting: boolean;
  @Prop @Watch('cancelRequested') cancelAnalyzerTrigger: number = 0;
  @State localCancelTrigger: number = 0;
  webImages: WebImageDownloads | undefined = undefined;
  onClose: () => void = () => {};
  onRecover: () => void = () => {};
  onWeb: () => void = () => {};
  @State loadedFiles: (MediaFile | undefined)[] = [];
  @State loadingIndices: number[] = [];
  @State failedIndices: number[] = [];
  @State zoomed: boolean = false;
  @State backdropOpacity: number = 1;
  @Prop topInset: number = 0;
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
    this.loadIndex(this.index);
    this.loadIndex(this.index + 1);
    this.resetChromeHideTimer();
  }

  aboutToDisappear(): void {
    this.alive = false;
    this.cancelAnalyzer();
    this.currentLoadedFile = undefined;
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
    const ui = this.getUIContext();
    this.topInset = ui.px2vp(Math.max(system.topRect.height, cutout.topRect.height));
    this.leftInset = ui.px2vp(Math.max(system.leftRect.width, cutout.leftRect.width));
    this.rightInset = ui.px2vp(Math.max(system.rightRect.width, cutout.rightRect.width));
  }

  private buttonMaterial(): uiMaterial.Material | undefined {
    if (!this.immersiveMaterial) {
      return undefined;
    }
    try {
      if (canIUse('SystemCapability.ArkUI.ArkUI.Full') && uiMaterial.isImmersiveMaterialSupported()) {
        return new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.REGULAR,
          interactive: true
        });
      }
    } catch (e) {
      return undefined;
    }
    return undefined;
  }

  private currentFile(): MediaFile | undefined {
    return this.loadedFiles[this.index];
  }

  /** 每张图保留已完成的文件；整体替换数组，确保 V1 状态更新可观察。 */
  private async loadIndex(index: number, original: boolean = false): Promise<void> {
    if (index >= this.items.length || (!original && this.loadedFiles[index]) || this.loadingIndices.includes(index)) { return; }
    this.loadingIndices = [...this.loadingIndices, index];
    this.failedIndices = this.failedIndices.filter((value: number) => value !== index);
    try {
      const address = imageForQuality(this.items[index], original || this.originalImages, original);
      const file = await this.files.load(address, this.getUIContext().getHostContext() as common.UIAbilityContext);
      if (this.alive) {
        const loaded = this.loadedFiles.slice();
        loaded[index] = file;
        this.loadedFiles = loaded;
        if (index === this.index) { this.currentLoadedFile = file; }
      }
    } catch (error) {
      if (this.alive) {
        this.chromeVisible = true;
        clearTimeout(this.chromeHideTimer);
        if (!this.loadedFiles[index]) { this.failedIndices = [...this.failedIndices, index]; }
        else { this.getUIContext().getPromptAction().showToast({ message: $r('app.string.operation_failed') }); }
        hilog.error(0x0A11, 'OpenTwit', 'event=image_load_failed error=%{public}s', JSON.stringify(error));
      }
    } finally {
      if (this.alive) { this.loadingIndices = this.loadingIndices.filter((value: number) => value !== index); }
    }
  }

  private async act(action: string): Promise<void> {
    const file = this.currentFile();
    if (!file || this.busy) {
      hilog.error(0x0A11, 'OpenTwit', 'event=image_action_failed action=%{public}s error=unavailable', action);
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.operation_failed'), duration: 2000 });
      return;
    }
    clearTimeout(this.chromeHideTimer);
    this.busy = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (action === 'save') {
        await this.files.save(context, file);
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.media_saved'), duration: 2000 });
      } else if (action === 'share') {
        await this.files.share(context, file);
      } else {
        await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, file.url));
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.media_copied'), duration: 2000 });
      }
    } catch (error) {
      hilog.error(0x0A11, 'OpenTwit', 'event=image_action_failed action=%{public}s error=%{public}s', action, JSON.stringify(error));
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.operation_failed'), duration: 2000 });
    } finally { this.busy = false; }
  }

  private shareRequested(): void { if (this.alive) { this.act('share'); } }

  private cancelRequested(): void {
    if (this.analyzerSelecting) {
      this.cancelAnalyzer();
    }
  }

  private cancelAnalyzer(): boolean {
    if (this.analyzerSelecting) {
      this.localCancelTrigger++;
      this.analyzerSelecting = false;
      if (this.chromeVisible) { this.resetChromeHideTimer(); }
      return true;
    }
    return false;
  }

  private onAnalyzerSelecting(selecting: boolean): void {
    this.analyzerSelecting = selecting;
    if (selecting) {
      clearTimeout(this.chromeHideTimer);
      this.chromeHideTimer = -1;
    } else if (this.chromeVisible) {
      this.resetChromeHideTimer();
    }
  }

  private resetChromeHideTimer(): void {
    clearTimeout(this.chromeHideTimer);
    if (!this.chromeVisible || this.analyzerSelecting) {
      this.chromeHideTimer = -1;
      return;
    }
    this.chromeHideTimer = setTimeout(() => {
      this.chromeHideTimer = -1;
      if (this.chromeVisible && !this.analyzerSelecting && !this.moreOpen && !this.detailsVisible) {
        this.toggleChrome();
      }
    }, 3000);
  }

  private toggleChrome(): void {
    clearTimeout(this.chromeHideTimer);
    if (this.detailsVisible) { this.detailsVisible = false; return; }
    this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseInOut }, () => {
      this.chromeVisible = !this.chromeVisible;
    });
    if (this.chromeVisible) {
      this.resetChromeHideTimer();
    }
  }

  private dismissDetails(): boolean {
    if (!this.detailsVisible) { return false; }
    this.detailsVisible = false;
    return true;
  }

  /** 放大图片的越界拖动在松手后切页，避免中途切换手势识别器。 */
  private turnPage(direction: number): void {
    if (this.analyzerSelecting) { return; }
    const target = this.index + direction;
    if (this.busy || target < 0 || target >= this.items.length) { return; }
    if (direction > 0) { this.swiper.showNext(); } else { this.swiper.showPrevious(); }
  }

  @Builder
  moreMenu() {
    Menu() {
      MenuItem() {
        Row() {
          SaveButton({ text: SaveDescription.SAVE_IMAGE, buttonType: ButtonType.Normal })
            .id('image-save').width('100%').height(TOUCH_TARGET).fontSize(16).padding(0)
            .align(Alignment.Start)
            .fontColor(Color.White).backgroundColor($r('app.color.image_menu_background'))
            .enabled(this.currentFile() !== undefined && !this.busy)
            .onClick(async (_event: ClickEvent, result: SaveButtonOnClickResult, error?: BusinessError<void>) => {
              this.moreOpen = false;
              if (result === SaveButtonOnClickResult.SUCCESS) {
                await this.act('save');
              } else {
                hilog.error(0x0A11, 'OpenTwit', 'event=image_save_authorization_failed result=%{public}d error=%{public}s',
                  result, error ? JSON.stringify(error) : 'none');
                this.getUIContext().getPromptAction().showToast({ message: $r('app.string.operation_failed'), duration: 2000 });
              }
            })
        }.width(220).height(TOUCH_TARGET).padding({ left: S12, right: S12 })
      }
      if (this.currentFile() && !this.currentFile()!.originalSize &&
        !this.items[this.index].id.startsWith('avatar-') && !this.items[this.index].id.startsWith('card-')) {
        MenuItem({ content: $r('app.string.media_load_original') }).contentFontColor(Color.White)
          .enabled(!this.busy && !this.loadingIndices.includes(this.index))
          .onClick(() => {
            this.moreOpen = false;
            this.cancelAnalyzer();
            this.loadIndex(this.index, true);
          })
      }
      MenuItem({ content: $r('app.string.media_details') }).contentFontColor(Color.White)
        .enabled(this.currentFile() !== undefined)
        .onClick(() => { this.moreOpen = false; this.detailsVisible = true; this.chromeVisible = true; })
      MenuItem({ content: $r('app.string.media_copy') }).contentFontColor(Color.White)
        .enabled(this.currentFile() !== undefined && !this.busy)
        .onClick(() => { this.moreOpen = false; this.act('copy'); })
    }
    .backgroundColor($r('app.color.image_menu_background'))
  }

  @Builder
  topBar() {
    Row() {
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(20)
          .fontColor([Color.White])
      }
      .id('image-close')
      .width(40).height(40)
      .responseRegion({ x: -4, y: -4, width: TOUCH_TARGET, height: TOUCH_TARGET })
      .backgroundColor(this.immersiveMaterial ? Color.Transparent : '#66000000')
      .backgroundBlurStyle(!this.immersiveMaterial ? BlurStyle.COMPONENT_THICK : BlurStyle.NONE,
        { colorMode: ThemeColorMode.DARK })
      .border(!this.immersiveMaterial ? { width: 0.5, color: '#26FFFFFF' } : { width: 0, color: Color.Transparent })
      .systemMaterial(this.buttonMaterial())
      .accessibilityText($r('app.string.media_close'))
      .accessibilityLevel('yes')
      .onClick(() => {
        if (this.cancelAnalyzer()) { return; }
        if (!this.dismissDetails()) { this.onClose(); }
      })

      Blank()

      if (this.items.length > 1) {
        Text((this.index + 1) + ' / ' + this.items.length)
          .fontSize(13).fontFamily(FONT_FAMILY).fontWeight(FontWeight.Medium).fontColor(Color.White)
          .padding({ left: S12, right: S12, top: 8, bottom: 8 })
          .borderRadius(16)
          .backgroundColor(this.immersiveMaterial ? Color.Transparent : '#66000000')
          .backgroundBlurStyle(!this.immersiveMaterial ? BlurStyle.COMPONENT_THICK : BlurStyle.NONE,
            { colorMode: ThemeColorMode.DARK })
          .border(!this.immersiveMaterial ? { width: 0.5, color: '#26FFFFFF' } : { width: 0, color: Color.Transparent })
          .systemMaterial(this.buttonMaterial())
      }

      Blank()

      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.more')).fontSize(20)
          .fontColor([Color.White])
      }
      .id('image-more')
      .width(40).height(40)
      .responseRegion({ x: -4, y: -4, width: TOUCH_TARGET, height: TOUCH_TARGET })
      .backgroundColor(this.immersiveMaterial ? Color.Transparent : '#66000000')
      .backgroundBlurStyle(!this.immersiveMaterial ? BlurStyle.COMPONENT_THICK : BlurStyle.NONE,
        { colorMode: ThemeColorMode.DARK })
      .border(!this.immersiveMaterial ? { width: 0.5, color: '#26FFFFFF' } : { width: 0, color: Color.Transparent })
      .systemMaterial(this.buttonMaterial())
      .accessibilityText($r('app.string.media_more'))
      .accessibilityLevel('yes')
      .onClick(() => {
        if (!this.dismissDetails()) { this.moreOpen = !this.moreOpen; }
      })
      .bindMenu(this.moreOpen, this.moreMenu, {
        placement: Placement.BottomRight,
        backgroundColor: $r('app.color.image_menu_background'),
        backgroundBlurStyle: BlurStyle.NONE,
        onAppear: () => { clearTimeout(this.chromeHideTimer); },
        onDisappear: () => { this.moreOpen = false; }
      })
    }
    .position({ top: 0, left: 0 })
    .width('100%')
    .padding({
      top: this.topInset + S8,
      left: this.leftInset + S12,
      right: this.rightInset + S12,
      bottom: S8
    })
    .opacity(this.chromeVisible && !this.dragging ? 1 : 0)
    .translate({ y: this.chromeVisible && !this.dragging ? 0 : -20 })
    .animation({ duration: 200, curve: Curve.EaseInOut })
    .hitTestBehavior(this.chromeVisible && !this.dragging ? HitTestMode.Default : HitTestMode.None)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column().width('100%').height('100%').backgroundColor(Color.Black).opacity(this.backdropOpacity)
        .hitTestBehavior(HitTestMode.None)
      Swiper(this.swiper) {
        ForEach(this.items, (item: MediaAddress, index: number) => {
          ZoomImage({
            source: this.loadedFiles[index] ? 'file://' + this.loadedFiles[index]!.path : '',
            pixelWidth: this.loadedFiles[index] ? this.loadedFiles[index]!.width : 0,
            pixelHeight: this.loadedFiles[index] ? this.loadedFiles[index]!.height : 0,
            isGif: this.loadedFiles[index]?.extension === 'gif',
            active: index === this.index,
            cancelTrigger: this.cancelAnalyzerTrigger + this.localCancelTrigger,
            onZoom: (zoomed: boolean) => { if (index === this.index) { this.zoomed = zoomed; } },
            onToggleChrome: () => this.toggleChrome(),
            onBackdrop: (opacity: number, dragging: boolean) => {
              if (index === this.index) { this.backdropOpacity = opacity; this.dragging = dragging; }
            },
            onPage: (direction: number) => this.turnPage(direction),
            onClose: this.onClose,
            onSelecting: (selecting: boolean) => {
              if (index === this.index) { this.onAnalyzerSelecting(selecting); }
            }
          })
        }, (item: MediaAddress) => item.id)
      }
      .index(this.index).loop(false).indicator(false)
      .cachedCount(1)
      .duration(260)
      .curve(Curve.Friction)
      .disableSwipe(this.zoomed || this.busy || this.analyzerSelecting)
      .width('100%').height('100%')
      .onAnimationStart((_index: number, targetIndex: number) => {
        if (this.analyzerSelecting) {
          this.cancelAnalyzer();
        }
        if (targetIndex !== this.index) {
          this.zoomed = false;
          this.detailsVisible = false;
          this.moreOpen = false;
        }
      })
      .onChange((index: number) => {
        if (this.analyzerSelecting) {
          this.cancelAnalyzer();
        }
        this.index = index;
        this.zoomed = false;
        this.backdropOpacity = 1;
        this.dragging = false;
        this.detailsVisible = false;
        this.moreOpen = false;
        this.currentLoadedFile = this.loadedFiles[index];
        this.loadIndex(index);
        this.loadIndex(index + 1);
      })
      this.topBar()
      if (this.detailsVisible && this.currentLoadedFile) {
        Column() {
          Blank()
          Text() {
            Span(this.currentLoadedFile!.originalSize ? $r('app.string.media_original_size') :
              $r('app.string.media_available_size'))
            Span(' · ' + this.currentLoadedFile!.width + ' × ' + this.currentLoadedFile!.height + ' · ' +
              this.currentLoadedFile!.extension.toUpperCase() + ' · ' +
              (this.currentLoadedFile!.size >= 1048576 ? (this.currentLoadedFile!.size / 1048576).toFixed(1) + ' MB' :
                Math.max(1, Math.round(this.currentLoadedFile!.size / 1024)) + ' KB'))
          }.fontSize(12).fontColor('#99FFFFFF').height(26).backgroundColor(Color.Black)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%').height('100%').padding({ left: S12, right: S12, bottom: this.footerOffset + S8 })
          .backgroundColor(Color.Transparent).hitTestBehavior(HitTestMode.None)
      }
      if (this.failedIndices.includes(this.index)) {
        Column({ space: S12 }) {
          Text($r('app.string.media_failed')).fontColor(Color.White)
          Button($r('app.string.retry')).onClick(() => {
            if (this.webImages?.needsRecovery()) { this.onRecover(); } else { this.loadIndex(this.index); }
          })
          Button($r('app.string.media_view_web')).onClick(this.onWeb)
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
      if (this.detailsVisible) {
        Column().width('100%').height('100%').backgroundColor(Color.Transparent)
          .onClick(() => { this.detailsVisible = false; })
      }
    }
    .width('100%').height(LayoutPolicy.matchParent)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM,
      LayoutSafeAreaEdge.START, LayoutSafeAreaEdge.END])
    .onKeyEvent((event: KeyEvent) => {
      if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ESCAPE) {
        if (this.cancelAnalyzer()) { return true; }
        if (!this.dismissDetails()) { this.onClose(); }
        return true;
      }
      return false;
    })
  }
}

/** 图片在全窗口内变换；普通横滑由 Swiper 处理，放大越界松手后切图。 */
@Component
struct ZoomImage {
  @Prop @Watch('sourceChanged') source: string = '';
  @Prop pixelWidth: number = 0;
  @Prop pixelHeight: number = 0;
  @Prop isGif: boolean = false;
  @Prop @Watch('activeChanged') active: boolean = false;
  @Prop @Watch('cancelRequested') cancelTrigger: number = 0;
  onZoom: (zoomed: boolean) => void = () => {};
  onToggleChrome: () => void = () => {};
  onBackdrop: (opacity: number, dragging: boolean) => void = () => {};
  onPage: (direction: number) => void = () => {};
  onClose: () => void = () => {};
  onSelecting: (selecting: boolean) => void = () => {};
  @State scaleValue: number = 1;
  @State x: number = 0;
  @State y: number = 0;
  @State widthValue: number = 0;
  @State heightValue: number = 0;
  @State displayFailed: boolean = false;
  @State imageKey: number = 0;
  @State analyzerEnabled: boolean = false;
  @State selecting: boolean = false;
  private startScale: number = 1;
  private startX: number = 0;
  private startY: number = 0;
  private dismissing: boolean = false;
  private pinching: boolean = false;
  private aiController: visionImageAnalyzer.VisionImageAnalyzerController | undefined = undefined;
  private aiOptions: ImageAIOptions | undefined = undefined;
  private supportTypes: ImageAnalyzerType[] = [];
  private generation: number = 0;
  private visibilityCallback: ((visibility: visionImageAnalyzer.ImageAnalyzerVisibility) => void) | undefined = undefined;
  private textChangeCallback: ((text: string) => void) | undefined = undefined;
  private subjectChangeCallback: ((subjects: visionImageAnalyzer.Subject[]) => void) | undefined = undefined;
  private failedCallback: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    if (this.active) {
      this.setupAnalyzer();
    }
  }

  aboutToDisappear(): void {
    this.teardownAnalyzer();
  }

  private activeChanged(): void {
    this.reset();
    if (this.active) {
      this.setupAnalyzer();
    } else {
      this.teardownAnalyzer();
    }
  }

  private sourceChanged(): void {
    this.displayFailed = false;
    this.imageKey++;
    if (this.active) {
      this.setupAnalyzer();
    }
  }

  private cancelRequested(): void {
    if (this.selecting && this.aiController) {
      try {
        if (canIUse('SystemCapability.AI.VisionImageAnalyzer')) {
          this.aiController.setImageAnalyzerVisibility(visionImageAnalyzer.ImageAnalyzerVisibility.HIDDEN);
        }
      } catch (e) {
        hilog.warn(0x0A11, 'OpenTwit', 'event=analyzer_cancel_failed error=%{public}s', JSON.stringify(e));
      }
      this.updateSelecting(false);
    }
  }

  private updateSelecting(selected: boolean): void {
    if (this.selecting !== selected) {
      this.selecting = selected;
      this.onSelecting(selected);
    }
  }

  private setupAnalyzer(): void {
    this.teardownAnalyzer();
    if (!this.active || this.isGif || this.source === '' || this.displayFailed) {
      return;
    }
    const currentGen = ++this.generation;
    try {
      if (canIUse('SystemCapability.AI.VisionImageAnalyzer')) {
        const controller = new visionImageAnalyzer.VisionImageAnalyzerController();
        const types = controller.getImageAnalyzerSupportTypes();
        if (currentGen !== this.generation || !this.active) {
          return;
        }
        if (types && types.length > 0) {
          this.supportTypes = types;
          this.aiController = controller;
          this.aiOptions = { types: types, aiController: controller };
          this.bindAnalyzerListeners(controller, currentGen);
          this.analyzerEnabled = true;
          return;
        }
      }
    } catch (e) {
      hilog.warn(0x0A11, 'OpenTwit', 'event=analyzer_init_failed error=%{public}s', JSON.stringify(e));
    }
    this.analyzerEnabled = false;
  }

  private bindAnalyzerListeners(controller: visionImageAnalyzer.VisionImageAnalyzerController, gen: number): void {
    this.visibilityCallback = (visibility: visionImageAnalyzer.ImageAnalyzerVisibility) => {
      if (gen !== this.generation || !this.active) { return; }
      this.updateSelecting(visibility === visionImageAnalyzer.ImageAnalyzerVisibility.SHOWN);
    };
    this.textChangeCallback = (text: string) => {
      if (gen !== this.generation || !this.active) { return; }
      this.updateSelecting(text.length > 0);
    };
    this.subjectChangeCallback = (subjects: visionImageAnalyzer.Subject[]) => {
      if (gen !== this.generation || !this.active) { return; }
      this.updateSelecting(subjects.length > 0);
    };
    this.failedCallback = () => {
      if (gen !== this.generation || !this.active) { return; }
      this.updateSelecting(false);
      this.analyzerEnabled = false;
    };

    try {
      controller.on('imageAnalyzerVisibilityChange', this.visibilityCallback);
      controller.on('selectedTextChange', this.textChangeCallback);
      controller.on('selectedSubjectsChange', this.subjectChangeCallback);
      controller.on('analyzerFailed', this.failedCallback);
    } catch (e) {
      hilog.warn(0x0A11, 'OpenTwit', 'event=analyzer_listener_bind_failed error=%{public}s', JSON.stringify(e));
    }
  }

  private teardownAnalyzer(): void {
    this.generation++;
    this.updateSelecting(false);
    this.analyzerEnabled = false;
    if (this.aiController) {
      try {
        if (canIUse('SystemCapability.AI.VisionImageAnalyzer')) {
          if (this.visibilityCallback) {
            this.aiController.off('imageAnalyzerVisibilityChange', this.visibilityCallback);
            this.visibilityCallback = undefined;
          }
          if (this.textChangeCallback) {
            this.aiController.off('selectedTextChange', this.textChangeCallback);
            this.textChangeCallback = undefined;
          }
          if (this.subjectChangeCallback) {
            this.aiController.off('selectedSubjectsChange', this.subjectChangeCallback);
            this.subjectChangeCallback = undefined;
          }
          if (this.failedCallback) {
            this.aiController.off('analyzerFailed', this.failedCallback);
            this.failedCallback = undefined;
          }
          this.aiController.setImageAnalyzerVisibility(visionImageAnalyzer.ImageAnalyzerVisibility.HIDDEN);
        }
      } catch (e) {
        hilog.warn(0x0A11, 'OpenTwit', 'event=analyzer_cleanup_failed error=%{public}s', JSON.stringify(e));
      }
      this.aiController = undefined;
      this.aiOptions = undefined;
    }
  }

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
    if (this.pinching || this.selecting) { return; }
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
      if (this.source !== '' && !this.displayFailed) {
        if (this.aiOptions !== undefined) {
          Image(this.source, this.aiOptions)
            .key(this.source + '-' + this.imageKey)
            .width('100%').height('100%').objectFit(ImageFit.Contain)
            .scale({ x: this.scaleValue, y: this.scaleValue }).translate({ x: this.x, y: this.y })
            .draggable(false)
            .autoResize(!this.isGif)
            .enableAnalyzer(this.analyzerEnabled)
            .onComplete(() => {
              this.displayFailed = false;
            })
            .onError((_err: ImageError) => {
              hilog.error(0x0A11, 'OpenTwit', 'event=image_display_failed source=%{public}s', this.source);
              this.teardownAnalyzer();
              this.displayFailed = true;
            })
        } else {
          Image(this.source)
            .key(this.source + '-' + this.imageKey)
            .width('100%').height('100%').objectFit(ImageFit.Contain)
            .scale({ x: this.scaleValue, y: this.scaleValue }).translate({ x: this.x, y: this.y })
            .draggable(false)
            .autoResize(!this.isGif)
            .enableAnalyzer(false)
            .onComplete(() => {
              this.displayFailed = false;
            })
            .onError((_err: ImageError) => {
              hilog.error(0x0A11, 'OpenTwit', 'event=image_display_failed source=%{public}s', this.source);
              this.teardownAnalyzer();
              this.displayFailed = true;
            })
        }
      }
      if (this.displayFailed) {
        Column({ space: S12 }) {
          Text($r('app.string.media_failed')).fontColor(Color.White)
          Button($r('app.string.retry')).onClick(() => {
            this.displayFailed = false;
            this.imageKey++;
            if (this.active) {
              this.setupAnalyzer();
            }
          })
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
    }.width('100%').height('100%')
    .onAreaChange((_old: Area, area: Area) => {
      this.widthValue = Number(area.width); this.heightValue = Number(area.height);
      if (this.scaleValue > 1) { this.clamp(); }
    })
    .gesture(GestureGroup(GestureMode.Parallel,
      GestureGroup(GestureMode.Exclusive,
        TapGesture({ count: 2 }).onAction((event: GestureEvent) => {
          if (this.selecting) { return; }
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
        TapGesture({ count: 1 }).onAction(() => {
          if (this.selecting) { return; }
          this.onToggleChrome();
        })
      ),
      PinchGesture({ fingers: 2 })
        .onActionStart(() => {
          if (this.selecting) { return; }
          this.pinching = true;
          this.dismissing = false;
          this.startScale = this.scaleValue;
          this.onBackdrop(1, false);
          this.onZoom(true);
        })
        .onActionUpdate((event: GestureEvent) => {
          if (this.selecting) { return; }
          this.scaleValue = Math.max(0.75, Math.min(5, this.startScale * event.scale));
          this.clamp();
        })
        .onActionEnd(() => this.finishPinch())
        .onActionCancel(() => this.finishPinch()),
      PanGesture({ fingers: 1, direction: PanDirection.All }).tag('image-pan')
        .onActionStart(() => {
          if (this.selecting) { return; }
          this.startX = this.x; this.startY = this.y;
          this.dismissing = this.scaleValue <= 1.01;
        })
        .onActionUpdate((event: GestureEvent) => {
          if (this.pinching || this.selecting) { return; }
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
      if (this.selecting) { return GestureJudgeResult.REJECT; }
      if (recognizer.getTag() === 'image-pan' && this.scaleValue <= 1.01) {
        const pan = event as PanGestureEvent;
        if (Math.abs(pan.offsetX) >= Math.abs(pan.offsetY) || pan.offsetY <= 0) { return GestureJudgeResult.REJECT; }
      }
      return GestureJudgeResult.CONTINUE;
    })
  }
}
