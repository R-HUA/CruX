import { WebTimeline } from '../services/WebTimeline';
import { TokenStore } from '../common/TokenStore';
import { FONT_FAMILY } from '../common/Theme';
import { TweetData } from '../services/WebTimeline';

@Component
export struct Messages {
  @State tweets: TweetData[] = [];
  @State handle: string = '';

  async loadLive(): Promise<void> {
    try {
      const saved: string = await TokenStore.loadHandle(getContext(this));
      this.handle = saved;
      if (saved !== '') {
        this.tweets = await WebTimeline.fetchByHandle(saved);
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

  getConversations(): TweetData[] {
    const seen: Record<string, boolean> = {};
    const result: TweetData[] = [];
    for (let i: number = 0; i < this.tweets.length; i++) {
      const t: TweetData = this.tweets[i];
      if (!seen[t.handle]) {
        seen[t.handle] = true;
        result.push(t);
      }
    }
    return result;
  }

  build() {
    Navigation() {
      Column() {
        if (this.getConversations().length === 0) {
          Text(this.handle === '' ? 'Sign in to load messages' : 'No messages yet')
            .fontSize(15)
            .fontColor($r('app.color.hw_text_grey'))
            .fontFamily(FONT_FAMILY)
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 32 });
        } else {
          List({ space: 0 }) {
            ForEach(this.getConversations(), (item: TweetData, index: number) => {
              ListItem() {
                Row({ space: 12 }) {
                  Stack({ alignContent: Alignment.Center }) {
                    Circle({ width: 44, height: 44 })
                      .fill($r('app.color.hw_primary'));
                    Text(item.handle.length > 1 ? item.handle.charAt(1).toUpperCase() : '')
                      .fontSize(20)
                      .fontColor(Color.White)
                      .fontFamily(FONT_FAMILY);
                  }
                  Column({ space: 4 }) {
                    Text(item.handle)
                      .fontSize(15)
                      .fontWeight(FontWeight.Medium)
                      .fontFamily(FONT_FAMILY)
                      .maxLines(1);
                    Text(item.content)
                      .fontSize(14)
                      .fontColor($r('app.color.hw_text_grey'))
                      .fontFamily(FONT_FAMILY)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis });
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start);
                  Text(item.time)
                    .fontSize(12)
                    .fontColor($r('app.color.hw_text_grey'))
                    .fontFamily(FONT_FAMILY);
                }
                .width('100%')
                .padding(12)
                .alignItems(VerticalAlign.Top);
              }
            }, (item: TweetData, index: number) => item.handle + index.toString());
          }
          .width('100%')
          .layoutWeight(1)
          .backgroundColor($r('app.color.hw_bg_light'));
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.hw_bg_light'));
    }
    .title('Messages')
    .titleMode(NavigationTitleMode.Full)
    .backgroundColor($r('app.color.hw_bg_light'));
  }
}
