import { FONT_FAMILY, S8, S12, TOUCH_TARGET } from '../common/Theme';
import { uiMaterial } from '@kit.ArkUI';

/** 只承载已由原生替代的页面标题，业务输入交互留在网页。 */
@Component
export struct NativeTopBar {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop showBack: boolean = false;
  @Prop titleOpacity: number = 1;
  @Prop bannerButtons: boolean = false;
  @Prop immersiveMaterial: boolean = false;
  onBack: () => void = () => {};
  @BuilderParam action: () => void = this.emptyAction;

  @Builder
  emptyAction() {}

  private buttonMaterial(): uiMaterial.Material | undefined {
    if (!this.immersiveMaterial) {
      return undefined;
    }
    try {
      if (canIUse('SystemCapability.ArkUI.ArkUI.Full') && uiMaterial.isImmersiveMaterialSupported()) {
        if (this.bannerButtons) {
          return new uiMaterial.ImmersiveMaterial({
            style: uiMaterial.ImmersiveStyle.REGULAR,
            materialColor: '#59000000',
            interactive: true
          });
        }
        return new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
          interactive: true
        });
      }
    } catch (e) {
      return undefined;
    }
    return undefined;
  }

  build() {
    Row() {
      if (this.showBack) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.arrow_left')).fontSize(20)
            .fontColor([this.bannerButtons ? Color.White : $r('sys.color.ohos_id_color_text_primary')])
        }
        .width(40).height(40)
        .margin({ right: S8 })
        .responseRegion({ x: -4, y: -4, width: TOUCH_TARGET, height: TOUCH_TARGET })
        .backgroundColor(this.bannerButtons ? '#59000000' : $r('sys.color.comp_background_tertiary'))
        .backgroundBlurStyle(this.bannerButtons ? BlurStyle.COMPONENT_THICK : BlurStyle.NONE,
          { colorMode: ThemeColorMode.DARK })
        .systemMaterial(this.buttonMaterial())
        .accessibilityText($r('app.string.back')).accessibilityLevel('yes').onClick(this.onBack)
      }
      Column({ space: 2 }) {
        Text(this.title).fontSize(this.subtitle !== '' ? 17 : 20).fontFamily(FONT_FAMILY).fontWeight(FontWeight.Bold)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor(this.bannerButtons ? Color.White : $r('sys.color.ohos_id_color_text_primary'))
        if (this.subtitle !== '') {
          Text(this.subtitle).fontSize(12).fontFamily(FONT_FAMILY).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor(this.bannerButtons ? '#CCFFFFFF' : $r('sys.color.ohos_id_color_text_secondary'))
        }
      }.alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Center).layoutWeight(1)
      .opacity(this.titleOpacity)
      .accessibilityLevel(this.titleOpacity === 0 ? 'no-hide-descendants' : 'auto')
      this.action()
    }
    .height(56).width('100%').alignItems(VerticalAlign.Center)
    .padding({ left: S12, right: S12 })
  }
}
