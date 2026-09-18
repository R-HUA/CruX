import router from '@ohos.router';
import { WebTimeline } from '../services/WebTimeline';
import { HandleLookup, FoundUser } from '../services/HandleLookup';
import { TokenStore } from '../common/TokenStore';
import { FONT_FAMILY } from '../common/Theme';
import { TweetCard } from '../components/TweetCard';
import { TweetData } from '../services/WebTimeline';

@Component
export struct Explore {
  @State query: string = '';
  @State selectedTab: number = 0;
  @State tweets: TweetData[] = [];
  @State handle: string = '';
  @State foundUser: FoundUser | undefined = undefined;

  async searchUser(value: string): Promise<void> {
    try {
      this.foundUser = await HandleLookup.lookup(value);
    } catch (e) {
      this.foundUser = undefined;
    }
  }

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

  getForYou(): TweetData[] {
    const q: string = this.query.trim().toLowerCase();
    if (q === '') {
      return this.tweets;
    }
    return this.tweets.filter((t: TweetData) => {
      return t.content.toLowerCase().indexOf(q) >= 0 || t.handle.toLowerCase().indexOf(q) >= 0;
    });
  }

  getTrending(): TweetData[] {
    const q: string = this.query.trim().toLowerCase();
    return this.tweets.filter((t: TweetData) => {
      const isTrend: boolean = t.content.indexOf('#') >= 0;
      if (!isTrend) {
        return false;
      }
      if (q === '') {
        return true;
      }
      return t.content.toLowerCase().indexOf(q) >= 0 || t.handle.toLowerCase().indexOf(q) >= 0;
    });
  }

  build() {
    Navigation() {
      Column({ space: 8 }) {
        Search({ value: this.query, placeholder: 'Search posts' })
          .width('92%')
          .margin({ top: 8 })
          .backgroundColor($r('app.color.hw_bg_light'))
          .onChange((value: string) => {
            this.query = value;
          })
          .onSubmit((value: string) => {
            this.query = value;
            this.searchUser(value);
          })
        Button('Search')
          .width('92%')
          .backgroundColor($r('app.color.hw_primary'))
          .onClick(() => {
            this.searchUser(this.query);
          })
        if (this.foundUser !== undefined) {
          Row() {
            Column({ space: 2 }) {
              Text((this.foundUser as FoundUser).name)
                .fontSize(16)
                .fontColor($r('app.color.hw_text_primary'))
                .fontFamily(FONT_FAMILY)
                .width('100%');
              Text((this.foundUser as FoundUser).handle)
                .fontSize(13)
                .fontColor($r('app.color.hw_text_grey'))
                .fontFamily(FONT_FAMILY)
                .width('100%');
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start);
          }
          .width('92%')
          .padding(12)
          .backgroundColor($r('app.color.hw_card_light'))
          .borderRadius(12)
          .onClick(() => {
            router.pushUrl({ url: 'pages/UserProfile', params: { handle: (this.foundUser as FoundUser).handle } });
          })
        }
        Tabs({ barPosition: BarPosition.Start, index: this.selectedTab }) {
          TabContent() {
            Column() {
              if (this.getForYou().length === 0) {
                Text(this.handle === '' ? 'Sign in to load live posts' : 'No results yet')
                  .fontSize(15)
                  .fontColor($r('app.color.hw_text_grey'))
                  .fontFamily(FONT_FAMILY)
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .margin({ top: 32 });
              } else {
                List({ space: 0 }) {
                  ForEach(this.getForYou(), (item: TweetData, index: number) => {
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
            .height('100%');
          }.tabBar('For You')

          TabContent() {
            Column() {
              if (this.getTrending().length === 0) {
                Text(this.handle === '' ? 'Sign in to load live trends' : 'No trending posts yet')
                  .fontSize(15)
                  .fontColor($r('app.color.hw_text_grey'))
                  .fontFamily(FONT_FAMILY)
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .margin({ top: 32 });
              } else {
                List({ space: 0 }) {
                  ForEach(this.getTrending(), (item: TweetData, index: number) => {
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
            .height('100%');
          }.tabBar('Trending')
        }
        .width('100%')
        .layoutWeight(1)
        .backgroundColor($r('app.color.hw_bg_light'))
        .onChange((index: number) => {
          this.selectedTab = index;
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.hw_bg_light'));
    }
    .title('Explore')
    .titleMode(NavigationTitleMode.Full)
    .backgroundColor($r('app.color.hw_bg_light'));
  }
}
