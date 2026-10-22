import { FONT_FAMILY, S4, S12, TOUCH_TARGET } from '../common/Theme';
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
      if (this.bannerButtons) {
        return new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.REGULAR,
          interactive: true
        });
      }
      return new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
        interactive: true
      });
    } catch (e) {
      return undefined;
    }
  }

  build() {
    Row() {
      if (this.showBack) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.arrow_left')).fontSize(22)
            .fontColor([this.bannerButtons ? Color.White : $r('sys.color.ohos_id_color_text_primary')])
        }
        .width(40).height(40)
        .responseRegion({ x: -4, y: -4, width: TOUCH_TARGET, height: TOUCH_TARGET })
        .systemMaterial(this.buttonMaterial())
        .backgroundBlurStyle(!this.immersiveMaterial && this.bannerButtons ? BlurStyle.Thin : BlurStyle.NONE)
        .backgroundColor(Color.Transparent)
        .accessibilityText($r('app.string.back')).accessibilityLevel('yes').onClick(this.onBack)
      }
      Column({ space: 0 }) {
        Text(this.title).fontSize(20).fontFamily(FONT_FAMILY).fontWeight(FontWeight.Bold)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
        if (this.subtitle !== '') {
          Text(this.subtitle).fontSize(11).fontFamily(FONT_FAMILY).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        }
      }.alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Center).layoutWeight(1)
      .opacity(this.titleOpacity)
      .accessibilityLevel(this.titleOpacity === 0 ? 'no-hide-descendants' : 'auto')
      this.action()
    }
    .height(56).width('100%').alignItems(VerticalAlign.Center)
    .padding({ left: this.showBack ? S4 : S12, right: S4 })
    .translate({ y: -4 })
  }
}
