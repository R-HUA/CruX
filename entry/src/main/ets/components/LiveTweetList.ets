import { TweetCard } from './TweetCard';
import { FONT_FAMILY } from '../common/Theme';

export interface LiveTweetItem {
  userName: string;
  handle: string;
  time: string;
  content: string;
  replies: number;
  reposts: number;
  likes: number;
  avatarUrl?: string;
  tweetId?: string;
}

@Component
export struct LiveTweetList {
  @Prop tweets: LiveTweetItem[] = [];
  @Prop isLoading: boolean = false;
  onRetry?: () => void;

  build() {
    if (this.isLoading) {
      Column({ space: 12 }) {
        LoadingProgress()
          .width(48)
          .height(48)
          .color($r('app.color.hw_primary'))
      }
      .width('100%')
      .padding(24)
      .alignItems(HorizontalAlign.Center)
    } else if (this.tweets.length === 0) {
      Column({ space: 12 }) {
        Text('Nothing here yet')
          .fontSize(15)
          .fontColor($r('app.color.hw_text_grey'))
          .fontFamily(FONT_FAMILY)
          .width('100%')
          .textAlign(TextAlign.Center)
        Button('Retry')
          .fontFamily(FONT_FAMILY)
          .onClick(() => {
            if (this.onRetry) {
              this.onRetry();
            }
          })
      }
      .width('100%')
      .padding(24)
      .alignItems(HorizontalAlign.Center)
    } else {
      List({ space: 8 }) {
        ForEach(this.tweets, (item: LiveTweetItem) => {
          ListItem() {
            TweetCard({
              userName: item.userName,
              handle: item.handle,
              time: item.time,
              content: item.content,
              replies: item.replies,
              reposts: item.reposts,
              likes: item.likes,
              avatarUrl: item.avatarUrl,
              tweetId: item.tweetId
            });
          }
        }, (item: LiveTweetItem) => item.handle + item.time + item.content);
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.hw_bg_light'))
    }
  }
}
