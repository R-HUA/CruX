import { FONT_FAMILY, S4, S12, TOUCH_TARGET } from '../common/Theme';

/** 只承载已由原生替代的页面标题，业务输入交互留在网页。 */
@Component
export struct NativeTopBar {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop showBack: boolean = false;
  @Prop titleOpacity: number = 1;
  @Prop bannerButtons: boolean = false;
  onBack: () => void = () => {};
  @BuilderParam action: () => void;

  build() {
    Row() {
      if (this.showBack) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.arrow_left')).fontSize(22)
            .fontColor([this.bannerButtons ? Color.White : $r('sys.color.ohos_id_color_text_primary')])
        }
        .width(TOUCH_TARGET).height(TOUCH_TARGET)
        .backgroundColor(this.bannerButtons ? '#59000000' : Color.Transparent)
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
