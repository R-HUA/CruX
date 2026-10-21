import { FONT_FAMILY, RAIL_WIDTH, S4, S16, TOUCH_TARGET } from '../common/Theme';

/** 横向标签栏和宽屏侧栏共用同一套呈现，导航决策仍由页面负责。 */
@Component
export struct NativeBottomBar {
  @Prop currentIndex: number = 0;
  @Prop notifications: number = 0;
  @Prop messages: number = 0;
  @Prop wide: boolean = false;
  @Prop labels: Resource[] = [];
  @Prop enabledTabs: number[] = [0, 1, 2, 3, 4];
  @State pressedIndex: number = -1;
  onSelect: (index: number) => void = () => {};

  private symbol(index: number): Resource {
    if (index === 0) { return $r('sys.symbol.house_fill'); }
    if (index === 1) { return $r('sys.symbol.compass_circle_fill'); }
    if (index === 2) { return $r('sys.symbol.bell_fill'); }
    if (index === 3) { return $r('sys.symbol.envelope_fill'); }
    if (index === 5) { return $r('sys.symbol.wand_and_stars'); }
    return $r('sys.symbol.gearshape');
  }

  private badge(index: number): number {
    if (index === this.currentIndex) { return 0; }
    return index === 2 ? this.notifications : index === 3 ? this.messages : 0;
  }

  @Builder
  item(index: number) {
    Column({ space: S4 }) {
      Badge({ count: this.badge(index), position: BadgePosition.RightTop, style: { fontSize: 10, badgeSize: 16 } }) {
        SymbolGlyph(this.symbol(index)).fontSize(this.wide ? 26 : 23)
          .fontColor([this.currentIndex === index ? $r('sys.color.ohos_id_color_emphasize') :
            $r('sys.color.ohos_id_color_text_secondary')])
      }
      Text(this.labels[index]).fontSize(11).fontFamily(FONT_FAMILY).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontWeight(this.currentIndex === index ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.currentIndex === index ? $r('sys.color.ohos_id_color_emphasize') :
          $r('sys.color.ohos_id_color_text_secondary'))
    }
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    .width(this.wide ? RAIL_WIDTH : undefined).height(this.wide ? TOUCH_TARGET + S16 : TOUCH_TARGET)
    .borderRadius(24).backgroundColor(Color.Transparent)
    .scale({ x: this.pressedIndex === index ? 0.92 : 1, y: this.pressedIndex === index ? 0.92 : 1 })
    .animation({ duration: 150, curve: Curve.FastOutSlowIn }).layoutWeight(this.wide ? 0 : 1)
    .hoverEffect(HoverEffect.Highlight).accessibilityText(this.labels[index])
    .accessibilityDescription(this.labels[index]).accessibilitySelected(this.currentIndex === index)
    .accessibilityLevel('yes')
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) { this.pressedIndex = index; }
      if (event.type === TouchType.Up || event.type === TouchType.Cancel) { this.pressedIndex = -1; }
    })
    .onClick(() => { this.onSelect(index); })
  }

  build() {
    Flex({ direction: this.wide ? FlexDirection.Column : FlexDirection.Row,
      justifyContent: this.wide ? FlexAlign.Center : FlexAlign.SpaceBetween, alignItems: ItemAlign.Center }) {
      ForEach(this.enabledTabs, (id: number) => { this.item(id) }, (id: number) => id.toString())
    }.width('100%').height('100%')
  }
}
