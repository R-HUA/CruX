import { WebTimeline } from '../services/WebTimeline';
import { TokenStore } from '../common/TokenStore';
import { FONT_FAMILY } from '../common/Theme';
import { TweetCard } from '../components/TweetCard';
import { TweetData } from '../services/WebTimeline';

@Component
export struct Notify {
  @State tweets: TweetData[] = [];
  @State handle: string = '';

  async loadLive(): Promise<void> {
    try {
      const saved: string = await TokenStore.loadHandle(getContext(this));
      this.handle = saved;
      if (saved !== '') {
        const live: TweetData[] = await WebTimeline.fetchByHandle(saved);
        this.tweets = live.filter((t: TweetData) => t.content.indexOf('@') >= 0);
      } else {
        this.tweets = [];
      }
    } catch (e) {
      this.tweets = [];
    }
  }

  aboutToAppear(): void {
    this.loadLive();
  }

  build() {
    Navigation() {
      Column() {
        if (this.tweets.length === 0) {
          Text(this.handle === '' ? 'Sign in to load notifications' : 'No notifications yet')
            .fontSize(15)
            .fontColor($r('app.color.hw_text_grey'))
            .fontFamily(FONT_FAMILY)
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 32 });
        } else {
          List({ space: 0 }) {
            ForEach(this.tweets, (item: TweetData, index: number) => {
              ListItem() {
                TweetCard({
                  userName: item.userName,
                  handle: item.handle,
                  time: item.time,
                  content: item.content,
                  likes: item.likes,
                  reposts: item.reposts
                });
              }
            }, (item: TweetData, index: number) => item.handle + item.time + item.content + index.toString());
          }
          .width('100%')
          .layoutWeight(1);
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.hw_bg_light'));
    }
    .title('Notifications')
    .titleMode(NavigationTitleMode.Full)
    .backgroundColor($r('app.color.hw_bg_light'));
  }
}
