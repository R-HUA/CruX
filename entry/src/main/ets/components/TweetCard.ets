import router from '@ohos.router';
import { FONT_FAMILY } from '../common/Theme';

@Component
export struct TweetCard {
  @Prop userName: string;
  @Prop handle: string;
  @Prop time: string;
  @Prop content: string;
  @Prop replies: number = 0;
  @Prop reposts: number;
  @Prop likes: number;
  @Prop avatarUrl: string = '';
  @Prop tweetId: string = '';

  build() {
    Column() {
      Row({ space: 12 }) {
        if (this.avatarUrl !== '') {
          Image(this.avatarUrl)
            .width(44)
            .height(44)
            .borderRadius(22)
            .onClick(() => {
              router.pushUrl({ url: 'pages/UserProfile', params: { handle: this.handle } });
            })
        } else {
          Stack({ alignContent: Alignment.Center }) {
            Circle({ width: 44, height: 44 })
              .fill($r('app.color.hw_primary'))
            Text(this.userName.charAt(0))
              .fontSize(20)
              .fontColor(Color.White)
              .fontFamily(FONT_FAMILY)
          }
          .onClick(() => {
            router.pushUrl({ url: 'pages/UserProfile', params: { handle: this.handle } });
          })
        }

        Column({ space: 6 }) {
          Row({ space: 6 }) {
            Text(this.userName)
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontFamily(FONT_FAMILY)
              .maxLines(1)
            Text(this.handle)
              .fontSize(13)
              .fontColor($r('app.color.hw_text_grey'))
              .fontFamily(FONT_FAMILY)
              .maxLines(1)
            Text(this.time)
              .fontSize(13)
              .fontColor($r('app.color.hw_text_grey'))
              .fontFamily(FONT_FAMILY)
              .maxLines(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text(this.content)
            .fontSize(15)
            .fontFamily(FONT_FAMILY)
            .width('100%')

          Row({ space: 24 }) {
            Text(this.replies.toString())
              .fontSize(13)
              .fontColor($r('app.color.hw_text_grey'))
              .fontFamily(FONT_FAMILY)
            Text(this.reposts.toString())
              .fontSize(13)
              .fontColor($r('app.color.hw_text_grey'))
              .fontFamily(FONT_FAMILY)
            Text(this.likes.toString())
              .fontSize(13)
              .fontColor($r('app.color.hw_text_grey'))
              .fontFamily(FONT_FAMILY)
          }
          .width('100%')
          .margin({ top: 4 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .onClick(() => {
          router.pushUrl({ url: 'pages/Detail', params: { handle: this.handle, tweetId: this.tweetId } });
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
    .padding(12)
    .borderRadius(16)
    .backgroundColor($r('app.color.hw_bg_light'))
  }
}
