import { LiveTweetList, LiveTweetItem } from '../components/LiveTweetList';
import { Composer } from '../components/Composer';
import { WebCache } from '../viewmodels/WebCache';
import { WebTimeline } from '../services/WebTimeline';
import { TokenStore } from '../common/TokenStore';
import { LIGHT_THEME_COLOR } from '../common/Theme';

@Component
export struct Home {
  @State tweets: LiveTweetItem[] = [];
  @State isRefreshing: boolean = false;
  @State isLoading: boolean = true;
  @State showComposer: boolean = false;
  @State searchText: string = '';
  @State currentHandle: string = '';

  async loadTimeline() {
    try {
      // Everything from Twitter web: no API key, no mock data.
      // With no saved handle, load verified live posts from the web.
      const handle: string = await TokenStore.loadHandle(getContext(this));
      if (handle !== '') {
        this.currentHandle = handle;
        this.tweets = await WebCache.loadWeb(handle);
        if (this.tweets.length > 0) {
          return;
        }
      }
      // Handle lookup came back empty: show verified live posts instead.
      this.tweets = await WebTimeline.fetchStarterTimeline();
    } catch (e) {
      this.tweets = [];
    }
    this.isLoading = false;
  }

  aboutToAppear() {
    this.loadTimeline();
  }

  build() {
    Navigation() {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Column({ space: 8 }) {
          // SearchBar on top of the timeline
          Search({ value: $$this.searchText })
            .width('100%')
            .onSubmit(() => {
            })
            .onChange((value: string) => {
              this.searchText = value;
            })

          // Pull-to-refresh timeline driven by live data only
          Refresh({ refreshing: $$this.isRefreshing, friction: 62 }) {
            LiveTweetList({
              tweets: this.tweets,
              isLoading: this.isLoading,
              onRetry: () => {
                this.isLoading = true;
                this.loadTimeline();
              }
            })
          }
          .width('100%')
          .layoutWeight(1)
          .onRefreshing(() => {
            this.isRefreshing = true;
            this.loadTimeline().finally(() => {
              this.isRefreshing = false;
            });
          })
        }
        .width('100%')
        .height('100%')
        .backgroundColor(LIGHT_THEME_COLOR)

        // Floating Compose button (icon only, no text)
        Button() {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(24)
        }
        .width(56)
        .height(56)
        .borderRadius(28)
        .margin({ right: 16, bottom: 16 })
        .onClick(() => {
          this.showComposer = !this.showComposer;
        })

        if (this.showComposer) {
          Composer({
            onPost: (content: string) => {
              const mine: LiveTweetItem = {
                userName: this.currentHandle,
                handle: this.currentHandle,
                time: new Date().toLocaleTimeString(),
                content: content,
                likes: 0,
                reposts: 0,
                replies: 0
              };
              this.tweets.unshift(mine);
              this.showComposer = false;
            }
          })
        }
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .title('OpenTwit')
    .backgroundColor($r('app.color.hw_bg_light'))
  }
}
