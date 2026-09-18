import { RADIUS, S12 } from './Theme';

@Component
export struct HarmonyCard {
  @BuilderParam content: () => void;

  build() {
    Column() {
      if (this.content !== undefined) {
        this.content()
      }
    }
    .backgroundColor($r('app.color.hw_card_light'))
    .borderRadius(RADIUS)
    .padding(S12)
    .width('100%')
  }
}
