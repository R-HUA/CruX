import { common } from '@kit.AbilityKit';
import {
  ActionResult, displayDohUrl, DohNode, MAX_CUSTOM_NODES, NetworkConfig,
  NetworkError, NetworkMode, NetworkSnapshot
} from '../common/NetworkConfig';
import { DohProbe, ProbeResult, ProbeStatus } from '../common/DohProbe';
import { FONT_FAMILY, RADIUS, S12, S16, S4, S8 } from '../common/Theme';

type ProbeStateValue = 'idle' | 'testing' | ProbeStatus;

interface NodeProbeState {
  id: string;
  status: ProbeStateValue;
  latencyMs: number;
}

@Component
export struct NetworkSettingsSheet {
  @State snapshot: NetworkSnapshot = NetworkConfig.getInstance().snapshot();
  @State probes: NodeProbeState[] = [];
  @State showAddForm: boolean = false;
  @State customName: string = '';
  @State customUrl: string = 'https://';
  @State customBootstrap: string = '';
  @State formError: ResourceStr = '';
  @State formErrorVisible: boolean = false;
  @State testingAll: boolean = false;
  private probe: DohProbe = new DohProbe();
  private unsubscribe: (() => void) | undefined = undefined;
  private closed: boolean = false;

  aboutToAppear(): void {
    this.closed = false;
    this.testingAll = false;
    if (this.unsubscribe !== undefined) {
      this.unsubscribe();
      this.unsubscribe = undefined;
    }
    const host = this.getUIContext().getHostContext();
    if (host !== undefined) {
      NetworkConfig.getInstance().ensureInitialized(host as common.Context);
    }
    this.snapshot = NetworkConfig.getInstance().snapshot();
    this.resetProbes();
    this.unsubscribe = NetworkConfig.getInstance().subscribe((snap: NetworkSnapshot) => {
      this.snapshot = snap;
    });
  }

  aboutToDisappear(): void {
    this.closed = true;
    if (this.unsubscribe !== undefined) {
      this.unsubscribe();
      this.unsubscribe = undefined;
    }
    this.probe.cancel();
  }

  private resetProbes(): void {
    const list: NodeProbeState[] = [];
    const nodes = this.snapshot.nodes;
    for (let i = 0; i < nodes.length; i++) {
      list.push({ id: nodes[i].id, status: 'idle', latencyMs: -1 });
    }
    this.probes = list;
  }

  private probeState(id: string): NodeProbeState {
    for (let i = 0; i < this.probes.length; i++) {
      if (this.probes[i].id === id) {
        return this.probes[i];
      }
    }
    return { id: id, status: 'idle', latencyMs: -1 };
  }

  private updateProbe(id: string, status: ProbeStateValue, latencyMs: number): void {
    const next: NodeProbeState[] = [];
    let found = false;
    for (let i = 0; i < this.probes.length; i++) {
      const item = this.probes[i];
      if (item.id === id) {
        next.push({ id: id, status: status, latencyMs: latencyMs });
        found = true;
      } else {
        next.push({ id: item.id, status: item.status, latencyMs: item.latencyMs });
      }
    }
    if (!found) {
      next.push({ id: id, status: status, latencyMs: latencyMs });
    }
    this.probes = next;
  }

  private async testNode(node: DohNode): Promise<void> {
    if (this.probeState(node.id).status === 'testing') {
      return;
    }
    this.updateProbe(node.id, 'testing', -1);
    const result: ProbeResult = await this.probe.probe(node.url);
    if (this.closed) {
      return;
    }
    this.updateProbe(node.id, result.status, result.latencyMs);
  }

  private async testAll(): Promise<void> {
    if (this.testingAll) {
      return;
    }
    this.testingAll = true;
    const tasks: Promise<void>[] = [];
    const nodes = this.snapshot.nodes;
    for (let i = 0; i < nodes.length; i++) {
      tasks.push(this.testNode(nodes[i]));
    }
    await Promise.all(tasks);
    if (!this.closed) {
      this.testingAll = false;
    }
  }

  private syncImagesEnabled(): boolean {
    return this.snapshot.mode !== 'off' && !this.snapshot.suspended;
  }

  private async applyMode(mode: NetworkMode): Promise<void> {
    const result: ActionResult = await NetworkConfig.getInstance().setMode(mode);
    if (!result.saved) {
      this.toast($r('app.string.network_save_failed'));
    }
  }

  private requestMode(mode: NetworkMode): void {
    if (this.snapshot.mode === mode) {
      return;
    }
    if (mode === 'secure_only') {
      AlertDialog.show({
        title: $r('app.string.network_mode_secure_confirm_title'),
        message: $r('app.string.network_mode_secure_confirm_message'),
        primaryButton: {
          value: $r('app.string.network_mode_confirm'),
          action: () => {
            this.applyMode(mode);
          }
        },
        secondaryButton: {
          value: $r('app.string.network_custom_cancel'),
          action: () => {
          }
        }
      });
      return;
    }
    this.applyMode(mode);
  }

  private async selectNode(id: string): Promise<void> {
    const result = await NetworkConfig.getInstance().selectNode(id);
    if (!result.ok) {
      this.toast($r('app.string.network_custom_error_save'));
    } else if (!result.saved) {
      this.toast($r('app.string.network_save_failed'));
    }
  }

  private async setSyncImages(value: boolean): Promise<void> {
    const result = await NetworkConfig.getInstance().setSyncImageDownloader(value);
    if (!result.saved) {
      this.toast($r('app.string.network_save_failed'));
    }
  }

  private async setVpnBypass(value: boolean): Promise<void> {
    const result = await NetworkConfig.getInstance().setVpnAutoBypass(value);
    if (!result.saved) {
      this.toast($r('app.string.network_save_failed'));
    }
  }

  private confirmDelete(node: DohNode): void {
    AlertDialog.show({
      title: $r('app.string.network_node_delete'),
      message: node.name,
      primaryButton: {
        value: $r('app.string.network_node_delete'),
        action: () => {
          this.deleteNode(node.id);
        }
      },
      secondaryButton: {
        value: $r('app.string.network_custom_cancel'),
        action: () => {
        }
      }
    });
  }

  private async deleteNode(id: string): Promise<void> {
    const result = await NetworkConfig.getInstance().removeCustomNode(id);
    if (!result.ok) {
      this.toast($r('app.string.network_custom_error_save'));
    } else if (!result.saved) {
      this.toast($r('app.string.network_save_failed'));
    }
  }

  private async addNode(): Promise<void> {
    this.formErrorVisible = false;
    const result = await NetworkConfig.getInstance().addCustomNode(
      this.customName, this.customUrl, this.customBootstrap);
    if (!result.ok) {
      this.formError = this.errorFor(result.error);
      this.formErrorVisible = true;
      return;
    }
    if (!result.saved) {
      this.toast($r('app.string.network_save_failed'));
    }
    this.customName = '';
    this.customUrl = 'https://';
    this.customBootstrap = '';
    this.showAddForm = false;
  }

  private errorFor(error: NetworkError): ResourceStr {
    if (error === 'name') {
      return $r('app.string.network_custom_error_name');
    }
    if (error === 'url') {
      return $r('app.string.network_custom_error_url');
    }
    if (error === 'ip') {
      return $r('app.string.network_custom_error_ip');
    }
    if (error === 'duplicate') {
      return $r('app.string.network_custom_error_duplicate');
    }
    if (error === 'limit') {
      return $r('app.string.network_custom_error_limit', MAX_CUSTOM_NODES);
    }
    return $r('app.string.network_custom_error_save');
  }

  private toggleAddForm(): void {
    this.showAddForm = !this.showAddForm;
    this.formErrorVisible = false;
  }

  private toast(message: ResourceStr): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (err) {
    }
  }

  private activeNodeName(): string {
    const nodes = this.snapshot.nodes;
    for (let i = 0; i < nodes.length; i++) {
      if (nodes[i].id === this.snapshot.selectedNodeId) {
        return nodes[i].name;
      }
    }
    return '';
  }

  private statusModeLabel(): Resource {
    if (this.snapshot.suspended) {
      return $r('app.string.network_status_paused');
    }
    if (this.snapshot.mode === 'off') {
      return $r('app.string.network_status_mode_off');
    }
    if (this.snapshot.mode === 'secure_only') {
      return $r('app.string.network_status_mode_secure');
    }
    return $r('app.string.network_status_mode_auto');
  }

  private vpnLabel(): Resource {
    if (this.snapshot.vpn === 'active') {
      return $r('app.string.network_vpn_active');
    }
    if (this.snapshot.vpn === 'inactive') {
      return $r('app.string.network_vpn_inactive');
    }
    return $r('app.string.network_vpn_unknown');
  }

  private modeDescription(): Resource {
    if (this.snapshot.mode === 'off') {
      return $r('app.string.network_mode_off_desc');
    }
    if (this.snapshot.mode === 'secure_only') {
      return $r('app.string.network_mode_secure_desc');
    }
    return $r('app.string.network_mode_auto_desc');
  }

  private probeColor(state: NodeProbeState): ResourceColor {
    if (state.status === 'ok') {
      if (state.latencyMs <= 150) {
        return $r('sys.color.ohos_id_color_emphasize');
      }
      if (state.latencyMs <= 400) {
        return $r('sys.color.ohos_id_color_warning');
      }
      return $r('sys.color.ohos_id_color_alert');
    }
    if (state.status === 'idle' || state.status === 'testing') {
      return $r('sys.color.ohos_id_color_text_secondary');
    }
    return $r('sys.color.ohos_id_color_alert');
  }

  private probeLabel(state: NodeProbeState): ResourceStr {
    if (state.status === 'ok') {
      return $r('app.string.network_node_ms', state.latencyMs);
    }
    if (state.status === 'unreachable') {
      return $r('app.string.network_node_unreachable');
    }
    if (state.status === 'bad_response') {
      return $r('app.string.network_node_bad_response');
    }
    if (state.status === 'rcode') {
      return $r('app.string.network_node_rcode');
    }
    if (state.status === 'testing') {
      return $r('app.string.network_node_testing');
    }
    return $r('app.string.network_node_untested');
  }

  @Builder
  groupTitle(title: ResourceStr) {
    Text(title)
      .fontSize(13)
      .fontFamily(FONT_FAMILY)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('sys.color.ohos_id_color_text_secondary'))
      .padding({ left: S12 })
  }

  @Builder
  statusCard() {
    Column({ space: 10 }) {
      Row({ space: S12 }) {
        SymbolGlyph(this.snapshot.dohActive
          ? $r('sys.symbol.checkmark_shield_fill')
          : $r('sys.symbol.lock_shield'))
          .fontSize(30)
          .fontColor([this.snapshot.dohActive
            ? $r('sys.color.ohos_id_color_emphasize')
            : $r('sys.color.ohos_id_color_text_secondary')])
        Column({ space: 3 }) {
          Text($r('app.string.network_status_title'))
            .fontSize(16)
            .fontFamily(FONT_FAMILY)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
          Text(this.statusModeLabel())
            .fontSize(13)
            .fontFamily(FONT_FAMILY)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Row() {
        Text($r('app.string.network_status_node'))
          .fontSize(14)
          .fontFamily(FONT_FAMILY)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        Blank()
        Text(this.activeNodeName())
          .fontSize(14)
          .fontFamily(FONT_FAMILY)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')

      Row() {
        Text($r('app.string.network_status_vpn'))
          .fontSize(14)
          .fontFamily(FONT_FAMILY)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        Blank()
        Text(this.vpnLabel())
          .fontSize(14)
          .fontFamily(FONT_FAMILY)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
      }
      .width('100%')

      if (this.snapshot.applyError) {
        Divider()
          .strokeWidth(0.5)
          .color($r('sys.color.ohos_id_color_list_separator'))
        Text($r('app.string.network_status_apply_failed'))
          .fontSize(12)
          .fontFamily(FONT_FAMILY)
          .fontColor($r('sys.color.ohos_id_color_alert'))
        Button($r('app.string.network_retry'))
          .type(ButtonType.Capsule)
          .height(32)
          .fontSize(13)
          .fontFamily(FONT_FAMILY)
          .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .onClick(() => {
            NetworkConfig.getInstance().retryApply();
          })
      }
    }
    .width('100%')
    .padding(S16)
    .borderRadius(RADIUS)
    .backgroundColor($r('sys.color.ohos_id_color_list_card_bg'))
  }

  @Builder
  modeCard() {
    Column({ space: 10 }) {
      Text($r('app.string.network_mode_title'))
        .fontSize(16)
        .fontFamily(FONT_FAMILY)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
        .width('100%')
      Row({ space: S8 }) {
        this.modeChip($r('app.string.network_mode_off'), 'off')
        this.modeChip($r('app.string.network_mode_auto'), 'auto')
        this.modeChip($r('app.string.network_mode_secure'), 'secure_only')
      }
      .width('100%')
      Text(this.modeDescription())
        .fontSize(12)
        .fontFamily(FONT_FAMILY)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        .width('100%')
      if (this.snapshot.suspended) {
        Text($r('app.string.network_mode_vpn_note'))
          .fontSize(12)
          .fontFamily(FONT_FAMILY)
          .fontColor($r('sys.color.ohos_id_color_warning'))
          .width('100%')
      }
    }
    .width('100%')
    .padding(S16)
    .borderRadius(RADIUS)
    .backgroundColor($r('sys.color.ohos_id_color_list_card_bg'))
  }

  @Builder
  modeChip(label: ResourceStr, mode: NetworkMode) {
    Button(label)
      .type(ButtonType.Capsule)
      .layoutWeight(1)
      .height(36)
      .fontSize(13)
      .fontFamily(FONT_FAMILY)
      .fontWeight(this.snapshot.mode === mode ? FontWeight.Bold : FontWeight.Medium)
      .fontColor(this.snapshot.mode === mode
        ? Color.White
        : $r('sys.color.ohos_id_color_text_primary'))
      .backgroundColor(this.snapshot.mode === mode
        ? $r('sys.color.ohos_id_color_emphasize')
        : $r('sys.color.ohos_id_color_button_normal'))
      .onClick(() => {
        this.requestMode(mode);
      })
  }

  @Builder
  settingToggleRow(symbol: Resource, title: ResourceStr, subtitle: ResourceStr,
    isOn: boolean, enabled: boolean, onChange: (value: boolean) => void) {
    Row({ space: S12 }) {
      SymbolGlyph(symbol)
        .fontSize(22)
        .fontColor([$r('sys.color.ohos_id_color_text_primary')])
        .width(24)
      Column({ space: 3 }) {
        Text(title)
          .fontSize(16)
          .fontFamily(FONT_FAMILY)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
        Text(subtitle)
          .fontSize(12)
          .fontFamily(FONT_FAMILY)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .maxLines(3)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .enabled(enabled)
        .onChange(onChange)
    }
    .width('100%')
    .padding({ left: S16, right: S16, top: 14, bottom: 14 })
    .opacity(enabled ? 1.0 : 0.45)
  }

  @Builder
  behaviorCard() {
    Column({ space: 0 }) {
      this.settingToggleRow(
        $r('sys.symbol.globe_badge_heart'),
        $r('app.string.network_sync_images'),
        $r('app.string.network_sync_images_desc'),
        this.snapshot.syncImageDownloader,
        this.syncImagesEnabled(),
        (value: boolean) => {
          this.setSyncImages(value);
        })
      Divider()
        .strokeWidth(0.5)
        .color($r('sys.color.ohos_id_color_list_separator'))
        .margin({ left: 52, right: S16 })
      this.settingToggleRow(
        $r('sys.symbol.arrow_left_arrow_right'),
        $r('app.string.network_vpn_bypass'),
        $r('app.string.network_vpn_bypass_desc'),
        this.snapshot.vpnAutoBypass,
        true,
        (value: boolean) => {
          this.setVpnBypass(value);
        })
    }
    .width('100%')
    .borderRadius(RADIUS)
    .backgroundColor($r('sys.color.ohos_id_color_list_card_bg'))
  }

  @Builder
  nodesSection() {
    Column({ space: S8 }) {
      Row({ space: S16 }) {
        this.groupTitle($r('app.string.network_nodes_title'))
        Blank()
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(14)
            .fontColor([$r('sys.color.ohos_id_color_emphasize')])
          Text(this.testingAll
            ? $r('app.string.network_nodes_testing_all')
            : $r('app.string.network_nodes_test_all'))
            .fontSize(13)
            .fontFamily(FONT_FAMILY)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.ohos_id_color_emphasize'))
        }
        .onClick(() => {
          this.testAll();
        })
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(14)
            .fontColor([$r('sys.color.ohos_id_color_emphasize')])
          Text($r('app.string.network_nodes_add'))
            .fontSize(13)
            .fontFamily(FONT_FAMILY)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.ohos_id_color_emphasize'))
        }
        .onClick(() => {
          this.toggleAddForm();
        })
      }
      .width('100%')
      .padding({ left: 0, right: S12 })

      Column({ space: 0 }) {
        ForEach(this.snapshot.nodes, (node: DohNode, index: number) => {
          if (index > 0) {
            Divider()
              .strokeWidth(0.5)
              .color($r('sys.color.ohos_id_color_list_separator'))
              .margin({ left: 48, right: S16 })
          }
          this.nodeRow(node)
        }, (node: DohNode) => node.id)
      }
      .width('100%')
      .borderRadius(RADIUS)
      .clip(true)
      .backgroundColor($r('sys.color.ohos_id_color_list_card_bg'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  nodeRow(node: DohNode) {
    Row({ space: S12 }) {
      Radio({ value: node.id, group: 'doh_nodes' })
        .checked(this.snapshot.selectedNodeId === node.id)
        .onChange((checked: boolean) => {
          if (checked) {
            this.selectNode(node.id);
          }
        })
      Column({ space: 3 }) {
        Row({ space: 6 }) {
          Text(node.name)
            .fontSize(16)
            .fontFamily(FONT_FAMILY)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (!node.builtin) {
            Text($r('app.string.network_node_custom'))
              .fontSize(10)
              .fontFamily(FONT_FAMILY)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .borderRadius(4)
              .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
          }
        }
        Text(displayDohUrl(node.url) + (node.bootstrapIp.length > 0 ? ' · IP ' + node.bootstrapIp : ''))
          .fontSize(12)
          .fontFamily(FONT_FAMILY)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .onClick(() => {
        this.selectNode(node.id);
      })
      this.probeBadge(node)
      if (!node.builtin) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.trash_fill'))
            .fontSize(16)
            .fontColor([$r('sys.color.ohos_id_color_alert')])
        }
        .width(32)
        .height(32)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.confirmDelete(node);
        })
      }
    }
    .width('100%')
    .padding({ left: S12, right: S12, top: 12, bottom: 12 })
  }

  @Builder
  probeBadge(node: DohNode) {
    Row({ space: S4 }) {
      if (this.probeState(node.id).status === 'testing') {
        LoadingProgress()
          .width(16)
          .height(16)
          .color($r('sys.color.ohos_id_color_emphasize'))
        Text($r('app.string.network_node_testing'))
          .fontSize(11)
          .fontFamily(FONT_FAMILY)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
      } else {
        Row()
          .width(6)
          .height(6)
          .borderRadius(3)
          .backgroundColor(this.probeColor(this.probeState(node.id)))
        Text(this.probeLabel(this.probeState(node.id)))
          .fontSize(11)
          .fontFamily(FONT_FAMILY)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.probeColor(this.probeState(node.id)))
        if (this.probeState(node.id).status === 'idle') {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(12)
            .fontColor([$r('sys.color.ohos_id_color_text_secondary')])
        }
      }
    }
    .height(28)
    .padding({ left: 8, right: 8 })
    .borderRadius(10)
    .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
    .accessibilityText($r('app.string.network_node_test'))
    .onClick(() => {
      this.testNode(node);
    })
  }

  @Builder
  addNodeCard() {
    Column({ space: 10 }) {
      Text($r('app.string.network_custom_title'))
        .fontSize(16)
        .fontFamily(FONT_FAMILY)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
        .width('100%')
      TextInput({ text: this.customName, placeholder: $r('app.string.network_custom_name') })
        .height(40)
        .fontSize(14)
        .fontFamily(FONT_FAMILY)
        .onChange((value: string) => {
          this.customName = value;
        })
      TextInput({ text: this.customUrl, placeholder: $r('app.string.network_custom_url') })
        .height(40)
        .fontSize(14)
        .fontFamily(FONT_FAMILY)
        .direction(Direction.Ltr)
        .onChange((value: string) => {
          this.customUrl = value;
        })
      TextInput({ text: this.customBootstrap, placeholder: $r('app.string.network_custom_bootstrap') })
        .height(40)
        .fontSize(14)
        .fontFamily(FONT_FAMILY)
        .direction(Direction.Ltr)
        .onChange((value: string) => {
          this.customBootstrap = value;
        })
      if (this.formErrorVisible) {
        Text(this.formError)
          .fontSize(12)
          .fontFamily(FONT_FAMILY)
          .fontColor($r('sys.color.ohos_id_color_alert'))
          .width('100%')
      }
      Row({ space: S12 }) {
        Button($r('app.string.network_custom_cancel'))
          .type(ButtonType.Capsule)
          .layoutWeight(1)
          .fontFamily(FONT_FAMILY)
          .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .onClick(() => {
            this.showAddForm = false;
            this.formErrorVisible = false;
          })
        Button($r('app.string.network_custom_save'))
          .type(ButtonType.Capsule)
          .layoutWeight(1)
          .fontFamily(FONT_FAMILY)
          .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
          .onClick(() => {
            this.addNode();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(S16)
    .borderRadius(RADIUS)
    .backgroundColor($r('sys.color.ohos_id_color_list_card_bg'))
  }

  @Builder
  notesSection() {
    Column({ space: S8 }) {
      Text($r('app.string.network_note_title'))
        .fontSize(13)
        .fontFamily(FONT_FAMILY)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
      Text($r('app.string.network_note_sni'))
        .fontSize(12)
        .fontFamily(FONT_FAMILY)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
      Text($r('app.string.network_note_provider'))
        .fontSize(12)
        .fontFamily(FONT_FAMILY)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
      Text($r('app.string.network_note_secure'))
        .fontSize(12)
        .fontFamily(FONT_FAMILY)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
      Text($r('app.string.network_note_vpn'))
        .fontSize(12)
        .fontFamily(FONT_FAMILY)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
      Text($r('app.string.network_note_images'))
        .fontSize(12)
        .fontFamily(FONT_FAMILY)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
      Text($r('app.string.network_note_domestic'))
        .fontSize(12)
        .fontFamily(FONT_FAMILY)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
      Text($r('app.string.network_reload_note'))
        .fontSize(12)
        .fontFamily(FONT_FAMILY)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: S12, right: S12 })
  }

  build() {
    Column({ space: 0 }) {
      Row() {
        Text($r('app.string.network_title'))
          .fontSize(20)
          .fontFamily(FONT_FAMILY)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
      }
      .width('100%')
      .padding({ left: 20, right: 56, top: S16, bottom: S12 })

      Scroll() {
        Column({ space: S16 }) {
          this.statusCard()
          this.modeCard()
          this.behaviorCard()
          this.nodesSection()
          if (this.showAddForm) {
            this.addNodeCard()
          }
          this.notesSection()
        }
        .width('100%')
        .padding({ left: S16, right: S16, bottom: 32 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
  }
}
