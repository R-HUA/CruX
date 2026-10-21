import { S8, S12, S16 } from '../common/Theme';
import { PLATFORM_SETTINGS } from '../common/ClientSettings';
import { TWITTER_BOOKMARKS, pathOf } from '../common/WebConfig';

/** 设置页只呈现客户端配置；平台项目点击后交给原网页处理。 */
@Component
export struct NativeSettingsPage {
  @Link @Watch('pageChanged') page: string;
  scroller: ListScroller = new ListScroller();
  @Prop handle: string = '';
  @Prop displayName: string = '';
  @Prop bio: string = '';
  @Prop avatar: string = '';
  @Prop accountLoading: boolean = false;
  @Prop accountError: boolean = false;
  @Prop themeMode: string = 'system';
  @Prop fontScale: number = 100;
  @Prop floating: boolean = true;
  @Prop autoHide: boolean = true;
  @Prop originalImages: boolean = true;
  @Prop enabledTabs: number[] = [0, 1, 2, 3, 4];
  @Prop customUa: string = '';
  @Prop desktop: boolean = false;
  @Prop desktopLocked: boolean = false;
  @Prop rawWeb: boolean = false;
  @Prop topOffset: number = 56;
  @Prop bottomOffset: number = 80;
  @Prop tabToggleGeneration: number = 0;
  @State uaDraft: string = '';
  onProfile: () => void = () => {};
  onRetryAccount: () => void = () => {};
  onSwitchAccount: () => void = () => {};
  onRoute: (path: string) => void = () => {};
  onTheme: (mode: string) => void = () => {};
  onFont: (scale: number) => void = () => {};
  onToggle: (key: string, value: boolean) => void = () => {};
  onTab: (id: number, value: boolean) => void = () => {};
  onUa: (value: string) => void = () => {};
  onClearCache: () => void = () => {};
  onDoh: () => void = () => {};
  onRawWeb: () => void = () => {};
  onScrollOffset: (offset: number) => void = () => {};

  aboutToAppear(): void { this.uaDraft = this.customUa; }

  private pageChanged(): void {
    this.scroller.scrollEdge(Edge.Top);
    this.onScrollOffset(0);
    if (this.page === 'network') { this.uaDraft = this.customUa; }
  }

  private label(id: number): Resource {
    if (id === 0) { return $r('app.string.tab_home'); }
    if (id === 1) { return $r('app.string.tab_explore'); }
    if (id === 2) { return $r('app.string.tab_notifications'); }
    if (id === 3) { return $r('app.string.tab_messages'); }
    if (id === 5) { return $r('app.string.tab_grok'); }
    return $r('app.string.tab_settings');
  }

  private platformLabel(index: number): Resource {
    if (index === 0) { return $r('app.string.platform_account'); }
    if (index === 1) { return $r('app.string.platform_security'); }
    if (index === 2) { return $r('app.string.platform_privacy'); }
    if (index === 3) { return $r('app.string.tab_notifications'); }
    if (index === 4) { return $r('app.string.platform_accessibility'); }
    return $r('app.string.platform_resources');
  }

  @Builder
  groupTitle(label: Resource) {
    Text(label).fontSize(14).fontColor($r('sys.color.ohos_id_color_text_secondary'))
      .width('100%').padding({ left: S16, right: S16, top: S12, bottom: S8 })
  }

  @Builder
  linkRow(label: Resource, action: () => void) {
    ListItem({ style: ListItemStyle.CARD }) {
      Row({ space: S12 }) {
        Text(label).fontSize(16).fontColor($r('sys.color.ohos_id_color_text_primary')).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16)
          .fontColor([$r('sys.color.ohos_id_color_text_tertiary')])
      }.width('100%').constraintSize({ minHeight: 52 }).padding({ left: S16, right: S16, top: S12, bottom: S12 })
    }.height(undefined).onClick(action)
  }

  @Builder
  toggleRow(label: Resource, value: boolean, key: string, enabled: boolean = true) {
    ListItem({ style: ListItemStyle.CARD }) {
      Row({ space: S12 }) {
        Text(label).fontSize(16).fontColor($r('sys.color.ohos_id_color_text_primary')).layoutWeight(1)
          .opacity(enabled ? 1 : 0.4)
        Toggle({ type: ToggleType.Switch, isOn: value }).enabled(enabled)
          .onChange((checked: boolean) => { if (checked !== value) { this.onToggle(key, checked); } })
      }.width('100%').constraintSize({ minHeight: 52 }).padding({ left: S16, right: S16, top: S8, bottom: S8 })
    }.height(undefined)
  }

  @Builder
  accountCard() {
    Column({ space: S12 }) {
      Row({ space: S16 }) {
        if (this.avatar !== '') {
          Image(this.avatar).width(56).height(56).borderRadius(28).objectFit(ImageFit.Cover)
        } else {
          SymbolGlyph($r('sys.symbol.person_crop_circle_fill')).fontSize(56)
            .fontColor([$r('sys.color.ohos_id_color_text_secondary')])
        }
        Column({ space: 4 }) {
          Text(this.displayName || this.handle).fontSize(20).fontWeight(FontWeight.Medium)
          if (this.handle !== '') {
            Text('@' + this.handle).fontSize(14)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          }
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%')
      if (this.accountLoading) { LoadingProgress().width(24).height(24) }
      if (this.accountError) {
        Button($r('app.string.settings_account_retry')).onClick(this.onRetryAccount)
      }
      if (this.bio !== '') { Text(this.bio).fontSize(14).width('100%') }
      Button($r('app.string.settings_enter_profile')).buttonStyle(ButtonStyleMode.TEXTUAL)
        .fontSize(16).alignSelf(ItemAlign.Start).onClick(this.onProfile)
    }.width('100%').padding(S16).backgroundColor($r('sys.color.comp_background_list_card')).borderRadius(16)
  }

  @Builder
  rootPage() {
    ListItem() { this.accountCard() }.margin({ left: S12, right: S12 })
    ListItem() { this.groupTitle($r('app.string.settings_account_group')) }
    ListItemGroup({ style: ListItemGroupStyle.CARD }) {
      this.linkRow($r('app.string.menu_bookmarks'), () => this.onRoute(pathOf(TWITTER_BOOKMARKS)))
      if (this.handle !== '') {
        this.linkRow($r('app.string.menu_lists'), () => this.onRoute('/' + this.handle + '/lists'))
      }
      this.linkRow($r('app.string.menu_switch_account'), this.onSwitchAccount)
    }.divider({ strokeWidth: 0.5, startMargin: S16, endMargin: S16 })
    ListItem() { this.groupTitle($r('app.string.settings_client_group')) }
    ListItemGroup({ style: ListItemGroupStyle.CARD }) {
      this.linkRow($r('app.string.settings_appearance'), () => { this.page = 'appearance'; })
      this.linkRow($r('app.string.settings_network'), () => { this.page = 'network'; })
    }.divider({ strokeWidth: 0.5, startMargin: S16, endMargin: S16 })
    ListItem() { this.groupTitle($r('app.string.settings_platform_group')) }
    ListItemGroup({ style: ListItemGroupStyle.CARD }) {
      ForEach(PLATFORM_SETTINGS, (path: string, index: number) => {
        this.linkRow(this.platformLabel(index), () => this.onRoute(path))
      }, (path: string) => path)
    }.divider({ strokeWidth: 0.5, startMargin: S16, endMargin: S16 })
  }

  @Builder
  appearancePage() {
    ListItem() { this.groupTitle($r('app.string.settings_theme')) }
    ListItemGroup({ style: ListItemGroupStyle.CARD }) {
      ForEach(['system', 'light', 'dark'], (mode: string, index: number) => {
        ListItem({ style: ListItemStyle.CARD }) {
          Row({ space: S12 }) {
            Text(index === 0 ? $r('app.string.settings_theme_system') : index === 1 ?
              $r('app.string.settings_theme_light') : $r('app.string.settings_theme_dark'))
              .fontSize(16).fontColor($r('sys.color.ohos_id_color_text_primary')).layoutWeight(1)
            Radio({ value: mode, group: 'client-theme' }).checked(this.themeMode === mode)
              .onChange((checked: boolean) => { if (checked && this.themeMode !== mode) { this.onTheme(mode); } })
          }.width('100%').constraintSize({ minHeight: 52 }).padding({ left: S16, right: S16, top: S8, bottom: S8 })
        }.height(undefined).onClick(() => { if (this.themeMode !== mode) { this.onTheme(mode); } })
      })
    }.divider({ strokeWidth: 0.5, startMargin: S16, endMargin: S16 })
    ListItemGroup({ style: ListItemGroupStyle.CARD }) {
      ListItem({ style: ListItemStyle.CARD }) {
        Column({ space: S12 }) {
          Row() {
            Text($r('app.string.settings_font')).fontSize(16).layoutWeight(1)
            Text(this.fontScale + '%').fontSize(16).fontColor($r('sys.color.ohos_id_color_text_secondary'))
          }.width('100%')
          Slider({ value: this.fontScale, min: 80, max: 150, step: 10 })
            .height(40)
            .onChange((value: number, mode: SliderChangeMode) => {
              if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) { this.onFont(value); }
            })
        }.padding(S16).width('100%')
      }.height(undefined)
    }.margin({ left: S12, right: S12, top: S12 })
    ListItem() { this.groupTitle($r('app.string.settings_display')) }
    ListItemGroup({ style: ListItemGroupStyle.CARD }) {
    this.toggleRow($r('app.string.appearance_floating'), this.floating, 'floating_bar')
    this.toggleRow($r('app.string.appearance_auto_hide'), this.autoHide, 'auto_hide_bar')
    this.toggleRow($r('app.string.settings_original'), this.originalImages, 'original_images')
    }.divider({ strokeWidth: 0.5, startMargin: S16, endMargin: S16 })
    ListItem() { this.groupTitle($r('app.string.settings_tabs')) }
    ListItemGroup({ style: ListItemGroupStyle.CARD }) {
    ForEach([0, 1, 2, 3, 5, 4], (id: number) => {
      ListItem({ style: ListItemStyle.CARD }) {
        Row({ space: S12 }) {
          Text(this.label(id)).fontSize(16).fontColor($r('sys.color.ohos_id_color_text_primary')).layoutWeight(1)
            .opacity(id === 2 || id === 3 || id === 5 ? 1 : 0.4)
          Toggle({ type: ToggleType.Switch, isOn: this.enabledTabs.includes(id) }).id('settings-tab-' + id)
            .enabled(id === 2 || id === 3 || id === 5)
            .onChange((value: boolean) => { if (value !== this.enabledTabs.includes(id)) { this.onTab(id, value); } })
        }.width('100%').constraintSize({ minHeight: 52 }).padding({ left: S16, right: S16, top: S8, bottom: S8 })
      }.height(undefined)
    }, (id: number) => id + '-' + this.tabToggleGeneration)
    }.divider({ strokeWidth: 0.5, startMargin: S16, endMargin: S16 })
  }

  @Builder
  networkPage() {
    ListItemGroup({ style: ListItemGroupStyle.CARD }) {
    this.linkRow($r('app.string.settings_doh'), this.onDoh)
    this.linkRow($r('app.string.settings_clear_cache'), this.onClearCache)
    }.divider({ strokeWidth: 0.5, startMargin: S16, endMargin: S16 })
    ListItem() { this.groupTitle($r('app.string.settings_browser')) }
    ListItemGroup({ style: ListItemGroupStyle.CARD }) {
    this.toggleRow($r('app.string.desktop_site'), this.desktop || this.desktopLocked, 'desktop_site', !this.desktopLocked)
    ListItem({ style: ListItemStyle.CARD }) {
    Column({ space: S12 }) {
      Text($r('app.string.settings_ua')).fontSize(16).width('100%')
      TextArea({ text: this.uaDraft, placeholder: $r('app.string.settings_ua_placeholder') })
        .height(100).maxLength(1024).onChange((value: string) => { this.uaDraft = value; })
      Button($r('app.string.settings_save')).onClick(() => this.onUa(this.uaDraft))
    }.width('100%').padding(S16)
    }.height(undefined)
    this.linkRow(this.rawWeb ? $r('app.string.show_native_shell') : $r('app.string.show_original_page'), this.onRawWeb)
    }.divider({ strokeWidth: 0.5, startMargin: S16, endMargin: S16 })
  }

  build() {
    List({ scroller: this.scroller }) {
        if (this.page === 'appearance') { this.appearancePage() }
        else if (this.page === 'network') { this.networkPage() }
        else { this.rootPage() }
    }.width('100%').constraintSize({ maxWidth: 720 }).height('100%')
      .contentStartOffset(this.topOffset + S8).contentEndOffset(this.bottomOffset + S16)
      .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
      .scrollBar(BarState.Auto)
      .onDidScroll(() => { this.onScrollOffset(Math.max(0, this.scroller.currentOffset().yOffset)); })
  }
}
