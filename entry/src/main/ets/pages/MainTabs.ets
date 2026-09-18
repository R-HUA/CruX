import { Home } from './Home';
import { Explore } from './Explore';
import { Notify } from './Notify';
import { Messages } from './Messages';
import { Profile } from './Profile';
import { FONT_FAMILY, LIGHT_THEME_COLOR } from '../common/Theme';

@Entry
@Component
struct MainTabs {
  @State currentIndex: number = 0;

  build() {
    Tabs({ barPosition: BarPosition.End, index: this.currentIndex }) {
      TabContent() {
        Home()
      }.tabBar('Home')

      TabContent() {
        Explore()
      }.tabBar('Explore')

      TabContent() {
        Notify()
      }.tabBar('Notify')

      TabContent() {
        Messages()
      }.tabBar('Messages')

      TabContent() {
        Profile()
      }.tabBar('Profile')
    }
    .width('100%')
    .height('100%')
    .barMode(BarMode.Fixed)
    .barBackgroundColor($r('app.color.hw_bg_light'))
    .backgroundColor(LIGHT_THEME_COLOR)
    .onChange((index: number) => {
      this.currentIndex = index;
    })
  }
}
