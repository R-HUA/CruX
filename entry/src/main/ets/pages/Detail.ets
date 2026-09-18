import router from '@ohos.router';
import { TweetDetail, TweetRecord } from '../services/TweetDetail';
import { TweetCard } from '../components/TweetCard';
import { FONT_FAMILY } from '../common/Theme';

@Entry
@Component
export struct Detail {
  @State handle: string = '';
  @State tweetId: string = '';
  @State tweet: TweetRecord | undefined = undefined;

  async loadDetail(): Promise<void> {
    if (this.handle === '' || this.tweetId === '') {
      return;
    }
    try {
      this.tweet = await TweetDetail.fetchOne(this.handle, this.tweetId);
    } catch (e) {
      this.tweet = undefined;
    }
  }

  aboutToAppear(): void {
    let params = router.getParams() as Record<string, string>;
    if (params && params['handle']) {
      this.handle = params['handle'];
    }
    if (params && params['tweetId']) {
      this.tweetId = params['tweetId'];
    }
    this.loadDetail();
  }

  build() {
    Navigation() {
      Column({ space: 8 }) {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(22)
            .fontColor([$r('app.color.hw_primary')]);
          Text('Back')
            .fontSize(16)
            .fontColor($r('app.color.hw_primary'))
            .fontFamily(FONT_FAMILY);
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          router.back();
        })
        if (this.tweet) {
          TweetCard({
            userName: (this.tweet as TweetRecord).userName,
            handle: (this.tweet as TweetRecord).handle,
            time: (this.tweet as TweetRecord).time,
            content: (this.tweet as TweetRecord).content,
            likes: (this.tweet as TweetRecord).likes,
            reposts: (this.tweet as TweetRecord).reposts,
            replies: (this.tweet as TweetRecord).replies,
            avatarUrl: (this.tweet as TweetRecord).avatarUrl,
            tweetId: (this.tweet as TweetRecord).tweetId
          });
          Text((this.tweet as TweetRecord).replies.toString() + ' replies')
            .fontSize(14)
            .fontColor($r('app.color.hw_text_grey'))
            .fontFamily(FONT_FAMILY)
            .width('100%')
            .padding({ left: 12, top: 8 });
          Text('No replies yet')
            .fontSize(15)
            .fontColor($r('app.color.hw_text_grey'))
            .fontFamily(FONT_FAMILY)
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 24 });
        } else {
          Text('Loading post...')
            .fontSize(15)
            .fontColor($r('app.color.hw_text_grey'))
            .fontFamily(FONT_FAMILY)
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 32 });
        }
      }
      .width('100%')
      .height('100%')
      .padding(8)
      .backgroundColor($r('app.color.hw_bg_light'));
    }
    .title('Post')
    .titleMode(NavigationTitleMode.Full)
    .backgroundColor($r('app.color.hw_bg_light'));
  }
}
