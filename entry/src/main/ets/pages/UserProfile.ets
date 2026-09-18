import router from '@ohos.router';
import { UserApi, UserProfileData } from '../services/UserApi';
import { FONT_FAMILY } from '../common/Theme';

@Entry
@Component
export struct UserProfile {
  @State handle: string = '';
  @State profile: UserProfileData | undefined = undefined;
  @State isLoading: boolean = true;

  async loadUser(): Promise<void> {
    try {
      let params = router.getParams() as Record<string, ESObject>;
      if (params && params['handle']) {
        this.handle = params['handle'] as string;
      }
      if (this.handle === '') {
        this.isLoading = false;
        return;
      }
      this.profile = await UserApi.fetchUser(this.handle);
    } catch (e) {
      this.profile = undefined;
    }
    this.isLoading = false;
  }

  aboutToAppear(): void {
    this.loadUser();
  }

  private static initialOf(handle: string): string {
    if (handle === '') {
      return '';
    }
    let name: string = handle.startsWith('@') ? handle.substring(1) : handle;
    if (name === '') {
      return '';
    }
    return name.charAt(0).toUpperCase();
  }

  build() {
    Navigation() {
      Column({ space: 0 }) {
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
        .padding({ left: 8, top: 4 })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          router.back();
        })
        Stack({ alignContent: Alignment.BottomStart }) {
          if (this.profile && this.profile.bannerUrl !== '') {
            Image(this.profile.bannerUrl)
              .width('100%')
              .height(120)
                .objectFit(ImageFit.Cover)
                .alt($r('app.media.app_icon'));
          } else {
            Column()
              .width('100%')
              .height(120)
              .backgroundColor($r('app.color.hw_primary'));
          }
          Row({ space: 12 }) {
            Stack({ alignContent: Alignment.Center }) {
              Circle({ width: 80, height: 80 })
                .fill(Color.White);
              if (this.profile && this.profile.avatarUrl !== '') {
                Image(this.profile.avatarUrl)
                  .width(72)
                  .height(72)
                  .borderRadius(36)
                  .objectFit(ImageFit.Cover)
                  .alt($r('app.media.app_icon'));
              } else {
                Circle({ width: 72, height: 72 })
                  .fill($r('app.color.hw_primary'));
                Text(UserProfile.initialOf(this.handle))
                  .fontSize(28)
                  .fontColor(Color.White)
                  .fontFamily(FONT_FAMILY);
              }
            }
          }
          .padding({ left: 16, bottom: 12 })
          .align(Alignment.BottomStart);
        }
        .width('100%')
        .height(140);

        Column({ space: 6 }) {
          if (this.isLoading) {
            Text('Loading profile...')
              .fontSize(15)
              .fontColor($r('app.color.hw_text_grey'))
              .fontFamily(FONT_FAMILY);
          } else if (this.profile) {
            Text(this.profile.name)
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontFamily(FONT_FAMILY);
            Text(this.profile.handle)
              .fontSize(14)
              .fontColor($r('app.color.hw_text_grey'))
              .fontFamily(FONT_FAMILY);
            Text(this.profile.bio)
              .fontSize(15)
              .fontFamily(FONT_FAMILY);
            Row({ space: 16 }) {
              Text(this.profile.followers + ' Followers')
                .fontSize(14)
                .fontColor($r('app.color.hw_text_grey'))
                .fontFamily(FONT_FAMILY);
              Text(this.profile.following + ' Following')
                .fontSize(14)
                .fontColor($r('app.color.hw_text_grey'))
                .fontFamily(FONT_FAMILY);
            }
            .margin({ top: 8 });
            Text('No posts yet — timeline is empty')
              .fontSize(15)
              .fontColor($r('app.color.hw_text_grey'))
              .fontFamily(FONT_FAMILY)
              .margin({ top: 16 });
          } else {
            Text(this.handle)
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontFamily(FONT_FAMILY);
            Text('Could not load this profile')
              .fontSize(15)
              .fontColor($r('app.color.hw_text_grey'))
              .fontFamily(FONT_FAMILY);
            Text('No posts yet — timeline is empty')
              .fontSize(15)
              .fontColor($r('app.color.hw_text_grey'))
              .fontFamily(FONT_FAMILY)
              .margin({ top: 16 });
          }
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start);
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.hw_bg_light'));
    }
    .title(this.handle === '' ? 'Profile' : this.handle)
    .titleMode(NavigationTitleMode.Full)
    .backgroundColor($r('app.color.hw_bg_light'));
  }
}
