import { FONT_FAMILY, S4, S8, S12, S16 } from '../common/Theme';

/** 编辑状态由页面持有，面板只呈现输入和操作，避免持久化与布局相互耦合。 */
@Component
export struct ComposerPanel {
  @Link draft: string;
  @Prop ready: boolean = false;
  @Prop posting: boolean = false;
  @Prop uncertain: boolean = false;
  @Prop preparing: boolean = false;
  @Prop loading: boolean = true;
  @Prop hasOwner: boolean = false;
  @Prop message: ResourceStr = '';
  onClose: () => void = () => {};
  onPost: () => void = () => {};
  onMore: () => void = () => {};
  onVerify: () => void = () => {};
  onDraftChange: () => void = () => {};
  onComposeKey: (event: KeyEvent) => boolean = () => false;

  build() {
    Column({ space: 0 }) {
      Row() {
        Button($r('app.string.compose_cancel'))
          .buttonStyle(ButtonStyleMode.TEXTUAL).fontFamily(FONT_FAMILY)
          .fontColor($r('sys.color.ohos_id_color_text_primary')).onClick(this.onClose)
        Blank()
        Text($r('app.string.compose_title'))
          .fontSize(17).fontFamily(FONT_FAMILY).fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
        Blank()
        Button($r('app.string.compose_post'))
          .buttonStyle(ButtonStyleMode.EMPHASIZED).fontFamily(FONT_FAMILY)
          .enabled(this.ready && this.draft.trim() !== '' && !this.posting && !this.uncertain &&
            !this.preparing && !this.loading && this.hasOwner)
          .onClick(this.onPost)
      }
      .width('100%').padding({ left: S8, right: S8, top: S8, bottom: S8 })
      .alignItems(VerticalAlign.Center)
      Divider().strokeWidth(0.5).color($r('sys.color.ohos_id_color_list_separator'))
      Row() {
        Blank()
        Button($r('app.string.compose_more'))
          .buttonStyle(ButtonStyleMode.TEXTUAL).fontFamily(FONT_FAMILY)
          .enabled(!this.posting && !this.uncertain && !this.preparing)
          .onClick(this.onMore)
      }
      .width('100%').padding({ left: S16, right: S8, top: S4, bottom: S4 })
      .alignItems(VerticalAlign.Center)
      if (this.message !== '') { Text(this.message).fontSize(14).padding(S12) }
      if (this.preparing || this.loading) { LoadingProgress().width(28).height(28).margin(S12) }
      if (this.uncertain) { Button($r('app.string.post_verify')).onClick(this.onVerify) }
      TextArea({ text: $$this.draft, placeholder: $r('app.string.compose_placeholder') })
        .width('100%').layoutWeight(1).fontFamily(FONT_FAMILY).fontSize(18)
        .backgroundColor(Color.Transparent).padding({ left: S16, right: S16, top: S12 })
        .enabled(!this.posting && !this.uncertain && !this.preparing && this.hasOwner)
        .onChange(this.onDraftChange).onKeyPreIme(this.onComposeKey).defaultFocus(true)
    }
    .width('100%').height('100%').backgroundColor($r('sys.color.ohos_id_color_background'))
  }
}
