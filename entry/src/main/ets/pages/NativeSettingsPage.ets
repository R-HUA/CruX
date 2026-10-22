import { S8, S12, S16 } from '../common/Theme';
import { ALL_TAB_IDS, PLATFORM_SETTINGS } from '../common/ClientSettings';
import { TWITTER_BOOKMARKS, pathOf } from '../common/WebConfig';
import { uiMaterial } from '@kit.ArkUI';

/** 设置页只呈现客户端配置；平台项目点击后交给原网页处理。 */
@Component
export struct NativeSettingsPage {
  @Link @Watch('pageChanged') page: string;
  scroller: ListScroller = new ListScroller();
  @Prop handle: string = '';
  @Prop displayName: string = '';
  @Prop bio: string = '';
  @Prop avatar: string = '';
  @Prop accountError: boolean = false;
  @Prop themeMode: string = 'system';
  @Prop materialLevel: string = 'adaptive';
  @Prop fontScale: number = 100;
  @Prop floating: boolean = true;
  @Prop autoHide: boolean = true;
  @Prop originalImages: boolean = true;
  @Prop enabledTabs: number[] = [0, 1, 2, 3, 4];
  @Prop tabOrder: number[] = [0, 1, 2, 3, 5, 4];
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
  onMaterialLevel: (level: string) => void = () => {};
  onFont: (scale: number) => void = () => {};
  onToggle: (key: string, value: boolean) => void = () => {};
  onTab: (id: number, value: boolean) => void = () => {};
  onReorder: (order: number[]) => void = () => {};
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

  private tabSymbol(id: number): Resource {
    if (id === 0) { return $r('sys.symbol.house_fill'); }
    if (id === 1) { return $r('sys.symbol.compass_circle_fill'); }
    if (id === 2) { return $r('sys.symbol.bell_fill'); }
    if (id === 3) { return $r('sys.symbol.envelope_fill'); }
    if (id === 5) { return $r('sys.symbol.wand_and_stars'); }
    return $r('sys.symbol.gearshape');
  }

  private platformLabel(index: number): Resource {
    if (index === 0) { return $r('app.string.platform_account'); }
    if (index === 1) { return $r('app.string.platform_security'); }
    if (index === 2) { return $r('app.string.platform_privacy'); }
    if (index === 3) { return $r('app.string.tab_notifications'); }
    if (index === 4) { return $r('app.string.platform_accessibility'); }
    return $r('app.string.platform_resources');
  }

  private themeLabel(mode: string): Resource {
    if (mode === 'light') { return $r('app.string.settings_theme_light'); }
    if (mode === 'dark') { return $r('app.string.settings_theme_dark'); }
    return $r('app.string.settings_theme_system');
  }

  private materialLabel(level: string): Resource {
    if (level === 'exquisite') { return $r('app.string.settings_material_exquisite'); }
    if (level === 'gentle') { return $r('app.string.settings_material_gentle'); }
    if (level === 'smooth') { return $r('app.string.settings_material_smooth'); }
    return $r('app.string.settings_material_adaptive');
  }

  private moveTab(from: number, to: number): void {
    if (from === to || from < 0 || to < 0 || from >= this.tabOrder.length || to >= this.tabOrder.length) { return; }
    const newOrder = this.tabOrder.slice();
    const item = newOrder.splice(from, 1)[0];
    newOrder.splice(to, 0, item);
    this.onReorder(newOrder);
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

  private themeOptions(): Array<SelectOption> {
    return [
      { value: $r('app.string.settings_theme_system') },
      { value: $r('app.string.settings_theme_light') },
      { value: $r('app.string.settings_theme_dark') }
    ];
  }

  private themeIndex(mode: string): number {
    if (mode === 'light') { return 1; }
    if (mode === 'dark') { return 2; }
    return 0;
  }

  private materialOptions(): Array<SelectOption> {
    return [
      { value: $r('app.string.settings_material_adaptive') },
      { value: $r('app.string.settings_material_exquisite') },
      { value: $r('app.string.settings_material_gentle') },
      { value: $r('app.string.settings_material_smooth') }
    ];
  }

  private materialIndex(level: string): number {
    if (level === 'exquisite') { return 1; }
    if (level === 'gentle') { return 2; }
    if (level === 'smooth') { return 3; }
    return 0;
  }

  private emptyMaterial(): uiMaterial.Material | undefined {
    try {
      if (canIUse('SystemCapability.ArkUI.ArkUI.Full')) {
        return uiMaterial.Material.empty;
      }
    } catch (e) {
      // ignore
    }
    return undefined;
  }

  @Builder
  themeRow() {
    ListItem({ style: ListItemStyle.CARD }) {
      Row({ space: S12 }) {
        Text($r('app.string.settings_theme')).fontSize(16).fontColor($r('sys.color.ohos_id_color_text_primary')).layoutWeight(1)
        Select(this.themeOptions())
          .value(this.themeLabel(this.themeMode))
          .selected(this.themeIndex(this.themeMode))
          .font({ size: 14 })
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .selectedOptionFont({ size: 14 })
          .optionFont({ size: 14 })
          .backgroundColor(Color.Transparent)
          .backgroundBlurStyle(BlurStyle.NONE)
          .systemMaterial(this.emptyMaterial())
          .shadow({ radius: 0, color: Color.Transparent })
          .borderWidth(0)
          .borderRadius(0)
          .padding({ left: 0, right: 0, top: 0, bottom: 0 })
          .menuAlign(MenuAlignType.END)
          .onSelect((index: number) => {
            const mode = index === 1 ? 'light' : index === 2 ? 'dark' : 'system';
            this.themeMode = mode;
            this.onTheme(mode);
          })
      }
      .width('100%').constraintSize({ minHeight: 52 })
      .padding({ left: S16, right: S16, top: 4, bottom: 4 })
    }
    .height(undefined)
  }

  @Builder
  materialRow() {
    ListItem({ style: ListItemStyle.CARD }) {
      Row({ space: S12 }) {
        Text($r('app.string.settings_immersive_light')).fontSize(16).fontColor($r('sys.color.ohos_id_color_text_primary')).layoutWeight(1)
        Select(this.materialOptions())
          .value(this.materialLabel(this.materialLevel))
          .selected(this.materialIndex(this.materialLevel))
          .font({ size: 14 })
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .selectedOptionFont({ size: 14 })
          .optionFont({ size: 14 })
          .backgroundColor(Color.Transparent)
          .backgroundBlurStyle(BlurStyle.NONE)
          .systemMaterial(this.emptyMaterial())
          .shadow({ radius: 0, color: Color.Transparent })
          .borderWidth(0)
          .borderRadius(0)
          .padding({ left: 0, right: 0, top: 0, bottom: 0 })
          .menuAlign(MenuAlignType.END)
          .onSelect((index: number) => {
            const level = index === 1 ? 'exquisite' : index === 2 ? 'gentle' : index === 3 ? 'smooth' : 'adaptive';
            this.materialLevel = level;
            this.onMaterialLevel(level);
          })
      }
      .width('100%').constraintSize({ minHeight: 52 })
      .padding({ left: S16, right: S16, top: 4, bottom: 4 })
    }
    .height(undefined)
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
          Text(this.displayName || (this.handle ? '@' + this.handle : '') || $r('app.string.menu_view_profile'))
            .fontSize(20).fontWeight(FontWeight.Medium)
          if (this.handle !== '') {
            Text('@' + this.handle).fontSize(14)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          }
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16)
          .fontColor([$r('sys.color.ohos_id_color_text_tertiary')])
      }.width('100%')
      if (this.accountError) {
        Button($r('app.string.settings_account_retry')).onClick(this.onRetryAccount)
      }
      if (this.bio !== '') { Text(this.bio).fontSize(14).width('100%') }
    }
    .width('100%').padding(S16).backgroundColor($r('sys.color.comp_background_list_card')).borderRadius(16)
    .onClick(() => { this.onProfile(); })
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
      this.linkRow($r('app.string.settings_bottom_bar'), () => { this.page = 'tabs'; })
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
    ListItem() { this.groupTitle($r('app.string.appearance_title')) }
    ListItemGroup({ style: ListItemGroupStyle.CARD }) {
      this.themeRow()
      this.materialRow()
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
      this.toggleRow($r('app.string.settings_original'), this.originalImages, 'original_images')
    }.divider({ strokeWidth: 0.5, startMargin: S16, endMargin: S16 })
  }

  @Builder
  tabItemRow(id: number, index: number) {
    ListItem({ style: ListItemStyle.CARD }) {
      Row({ space: S12 }) {
        SymbolGlyph(this.tabSymbol(id)).fontSize(20)
          .fontColor([$r('sys.color.ohos_id_color_emphasize')])
        Text(this.label(id)).fontSize(16)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .layoutWeight(1)

        if (index > 0) {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.arrow_up')).fontSize(14)
              .fontColor([$r('sys.color.ohos_id_color_text_secondary')])
          }
          .width(28).height(28).backgroundColor(Color.Transparent)
          .onClick(() => { this.moveTab(index, index - 1); })
        }
        if (index < this.tabOrder.length - 1) {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.arrow_down')).fontSize(14)
              .fontColor([$r('sys.color.ohos_id_color_text_secondary')])
          }
          .width(28).height(28).backgroundColor(Color.Transparent)
          .onClick(() => { this.moveTab(index, index + 1); })
        }

        if (id === 0 || id === 1 || id === 4) {
          Toggle({ type: ToggleType.Switch, isOn: true }).enabled(false)
            .id('settings-tab-' + id)
        } else {
          Toggle({ type: ToggleType.Switch, isOn: this.enabledTabs.includes(id) })
            .id('settings-tab-' + id)
            .onChange((checked: boolean) => {
              if (checked !== this.enabledTabs.includes(id)) {
                this.onTab(id, checked);
              }
            })
        }

        SymbolGlyph($r('sys.symbol.line_3_horizontal')).fontSize(16)
          .fontColor([$r('sys.color.ohos_id_color_text_tertiary')])
      }
      .width('100%').constraintSize({ minHeight: 52 })
      .padding({ left: S16, right: S16, top: S8, bottom: S8 })
    }
    .height(undefined)
    .draggable(true)
  }

  @Builder
  tabsPage() {
    ListItem() { this.groupTitle($r('app.string.settings_display')) }
    ListItemGroup({ style: ListItemGroupStyle.CARD }) {
      this.toggleRow($r('app.string.appearance_floating'), this.floating, 'floating_bar')
      this.toggleRow($r('app.string.appearance_auto_hide'), this.autoHide, 'auto_hide_bar')
    }.divider({ strokeWidth: 0.5, startMargin: S16, endMargin: S16 })

    ListItem() { this.groupTitle($r('app.string.settings_tabs')) }
    ListItemGroup({ style: ListItemGroupStyle.CARD }) {
      ForEach(this.tabOrder, (id: number, index: number) => {
        this.tabItemRow(id, index)
      }, (id: number) => id.toString())
      .onMove((from: number, to: number) => {
        this.moveTab(from, to);
      })
    }
    .divider({ strokeWidth: 0.5, startMargin: S16, endMargin: S16 })
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
      else if (this.page === 'tabs') { this.tabsPage() }
      else if (this.page === 'network') { this.networkPage() }
      else { this.rootPage() }
    }
    .width('100%').constraintSize({ maxWidth: 720 }).height('100%')
    .contentStartOffset(this.topOffset + S8).contentEndOffset(this.bottomOffset + S16)
    .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
    .scrollBar(BarState.Auto)
    .onDidScroll(() => { this.onScrollOffset(Math.max(0, this.scroller.currentOffset().yOffset)); })
  }
}
