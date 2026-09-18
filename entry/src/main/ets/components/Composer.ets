import { FONT_FAMILY } from '../common/Theme';

const MAX_LENGTH: number = 280;

@Component
export struct Composer {
  @State draft: string = '';
  @Prop placeholder: string = '';
  onPost?: (content: string) => void;

  build() {
    Column({ space: 8 }) {
      TextArea({ placeholder: this.placeholder, text: this.draft })
        .placeholderFont({ family: FONT_FAMILY })
        .fontFamily(FONT_FAMILY)
        .fontSize(15)
        .width('100%')
        .height(120)
        .onChange((value: string) => {
          this.draft = value;
        })
      Row() {
        Text(this.draft.length.toString() + ' / ' + MAX_LENGTH.toString())
          .fontSize(13)
          .fontColor($r('app.color.hw_text_grey'))
          .fontFamily(FONT_FAMILY)
        Blank()
        Button('Post')
          .fontFamily(FONT_FAMILY)
          .enabled(this.draft.trim().length > 0)
          .onClick(() => {
            const text: string = this.draft.trim();
            if (text.length > 0) {
              if (this.onPost) {
                this.onPost(text);
              }
              this.draft = '';
            }
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(16)
    .borderRadius({ topLeft: 16, topRight: 16 })
    .backgroundColor($r('app.color.hw_bg_light'))
  }
}
