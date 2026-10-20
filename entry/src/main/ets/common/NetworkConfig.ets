import web_webview from '@ohos.web.webview';
import { connection } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { url } from '@kit.ArkTS';

const DOMAIN: number = 0x0A11;
const TAG: string = 'OpenTwit';
const PREFS_NAME: string = 'opentwit_network';
const CONFIG_KEY: string = 'network_config_v1';
const PIN_TTL_SECONDS: number = 3600;
const VPN_DEBOUNCE_MS: number = 400;
export const MAX_CUSTOM_NODES: number = 8;
const MAX_NODE_NAME_LENGTH: number = 40;
const MAX_URL_LENGTH: number = 512;
export const FALLBACK_DOH_URL: string = 'https://cloudflare-dns.com/dns-query';

export type NetworkMode = 'off' | 'auto' | 'secure_only';
export type VpnState = 'active' | 'inactive' | 'unknown';
export type NetworkError = 'none' | 'name' | 'url' | 'ip' | 'duplicate' | 'limit' | 'not_found';

export interface DohNode {
  id: string;
  name: string;
  url: string;
  builtin: boolean;
  bootstrapHost: string;
  bootstrapIp: string;
}

export interface NetworkSnapshot {
  mode: NetworkMode;
  selectedNodeId: string;
  nodes: DohNode[];
  vpn: VpnState;
  suspended: boolean;
  dohActive: boolean;
  applyError: boolean;
  generation: number;
  syncImageDownloader: boolean;
  vpnAutoBypass: boolean;
}

export interface DohPolicy {
  mode: NetworkMode;
  url?: string;
}

export interface ActionResult {
  ok: boolean;
  error: NetworkError;
  saved: boolean;
}

interface CustomNodeData {
  id: string;
  name: string;
  url: string;
  bootstrapIp: string;
}

interface StoredConfig {
  schemaVersion: number;
  mode: NetworkMode;
  selectedNodeId: string;
  syncImageDownloader: boolean;
  vpnAutoBypass: boolean;
  customNodes: CustomNodeData[];
}

interface ParsedDohUrl {
  url: string;
  host: string;
  path: string;
  key: string;
}

export const DEFAULT_MODE: NetworkMode = 'auto';
export const DEFAULT_NODE_ID: string = 'cloudflare';

const BUILTIN_NODES: DohNode[] = [
  {
    id: 'cloudflare', name: 'Cloudflare', url: 'https://cloudflare-dns.com/dns-query',
    builtin: true, bootstrapHost: 'cloudflare-dns.com', bootstrapIp: '1.1.1.1'
  },
  {
    id: 'google', name: 'Google Public DNS', url: 'https://dns.google/dns-query',
    builtin: true, bootstrapHost: 'dns.google', bootstrapIp: '8.8.8.8'
  },
  {
    id: 'alidns', name: 'AliDNS', url: 'https://dns.alidns.com/dns-query',
    builtin: true, bootstrapHost: 'dns.alidns.com', bootstrapIp: '223.5.5.5'
  },
  {
    id: 'dnspod', name: 'DNSPod', url: 'https://doh.pub/dns-query',
    builtin: true, bootstrapHost: 'doh.pub', bootstrapIp: '1.12.12.12'
  }
];

function builtinNodes(): DohNode[] {
  const list: DohNode[] = [];
  for (let i = 0; i < BUILTIN_NODES.length; i++) {
    const item = BUILTIN_NODES[i];
    list.push({
      id: item.id, name: item.name, url: item.url, builtin: true,
      bootstrapHost: item.bootstrapHost, bootstrapIp: item.bootstrapIp
    });
  }
  return list;
}

export function parseDohUrl(raw: string): ParsedDohUrl | undefined {
  const value = raw.trim();
  if (value.length === 0 || value.length > MAX_URL_LENGTH || /\s/.test(value)) {
    return undefined;
  }
  try {
    const parsed = url.URL.parseURL(value);
    if (parsed.protocol !== 'https:' || parsed.hostname.length === 0) {
      return undefined;
    }
    if (parsed.username.length > 0 || parsed.password.length > 0) {
      return undefined;
    }
    if (parsed.hash.length > 0) {
      return undefined;
    }
    if (parsed.pathname.length === 0 || parsed.pathname === '/') {
      return undefined;
    }
    return {
      url: value,
      host: parsed.hostname,
      path: parsed.pathname,
      key: parsed.protocol + '//' + parsed.hostname.toLowerCase() + ':' + (parsed.port || '443') + parsed.pathname + parsed.search
    };
  } catch (err) {
    return undefined;
  }
}

/** Query strings can carry provider tokens; never show them in the panel. */
export function displayDohUrl(raw: string): string {
  const parsed = parseDohUrl(raw);
  if (parsed === undefined) {
    return raw;
  }
  return 'https://' + parsed.host + parsed.path;
}

export function isIpAddress(value: string): boolean {
  const text = value.trim();
  if (text.length === 0) {
    return false;
  }
  const v4 = /^(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})$/;
  const match = v4.exec(text);
  if (match !== null) {
    for (let i = 1; i <= 4; i++) {
      const part = Number(match[i]);
      if (part < 0 || part > 255) {
        return false;
      }
    }
    return true;
  }
  if (text.indexOf(':') < 0 || text.length > 45) {
    return false;
  }
  if (text.includes(':::') || text.split('::').length > 2) { return false; }
  const compressed = text.includes('::');
  if (!compressed && (text.startsWith(':') || text.endsWith(':'))) { return false; }
  const groups = text.split(':').filter((part: string) => part.length > 0);
  let count = 0;
  for (let i = 0; i < groups.length; i++) {
    const part = groups[i];
    if (part.includes('.')) {
      if (i !== groups.length - 1 || !text.endsWith(part) || !isIpAddress(part)) { return false; }
      count += 2;
    } else {
      if (!/^[0-9a-fA-F]{1,4}$/.test(part)) { return false; }
      count++;
    }
  }
  return compressed ? count < 8 : count === 8;
}

export class NetworkConfig {
  private static instance: NetworkConfig = new NetworkConfig();

  private prefs: preferences.Preferences | undefined = undefined;
  private initialized: boolean = false;
  private mode: NetworkMode = DEFAULT_MODE;
  private selectedNodeId: string = DEFAULT_NODE_ID;
  private syncImageDownloader: boolean = true;
  private vpnAutoBypass: boolean = true;
  private customNodes: CustomNodeData[] = [];
  private nodes: DohNode[] = builtinNodes();
  private vpn: VpnState = 'unknown';
  private suspended: boolean = false;
  private dohActive: boolean = false;
  private applyError: boolean = false;
  private generation: number = 0;
  private pinned: Map<string, string> = new Map<string, string>();
  private listeners: Array<(snapshot: NetworkSnapshot) => void> = [];
  private netConn: connection.NetConnection | undefined = undefined;
  private vpnTimer: number = -1;

  static getInstance(): NetworkConfig {
    return NetworkConfig.instance;
  }

  initialize(context: common.Context): void {
    if (this.initialized) {
      return;
    }
    try {
      this.prefs = preferences.getPreferencesSync(context, { name: PREFS_NAME });
    } catch (err) {
      const error = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'event=network_prefs_failed code=%{public}d', error.code);
    }
    this.loadConfig();
    this.vpn = this.detectVpnSync();
    this.suspended = false;
    this.recomputeSuspended(this.vpn);
    this.applyNow();
    this.startVpnWatch();
    this.initialized = true;
    hilog.info(DOMAIN, TAG, 'event=network_init mode=%{public}s node=%{public}s vpn=%{public}s',
      this.mode, this.selectedNodeId, this.vpn);
    this.emit();
  }

  ensureInitialized(context: common.Context): void {
    if (!this.initialized) {
      this.initialize(context);
    }
  }

  ensureApplied(): void {
    if (this.initialized) {
      this.applyNow(true);
    }
  }

  refresh(): void {
    if (!this.initialized) {
      return;
    }
    const state = this.detectVpnSync();
    this.updateVpnState(state, true);
  }

  dispose(): void {
    if (this.netConn !== undefined) {
      try {
        this.netConn.unregister((err: BusinessError) => {
          if (err) {
            hilog.debug(DOMAIN, TAG, 'event=vpn_unregister_failed code=%{public}d', err.code);
          }
        });
      } catch (err) {
        const error = err as BusinessError;
        hilog.debug(DOMAIN, TAG, 'event=vpn_unregister_failed code=%{public}d', error.code);
      }
      this.netConn = undefined;
    }
    if (this.vpnTimer !== -1) {
      clearTimeout(this.vpnTimer);
      this.vpnTimer = -1;
    }
    this.clearPins();
    this.listeners = [];
    this.prefs = undefined;
    this.initialized = false;
  }

  snapshot(): NetworkSnapshot {
    const nodes: DohNode[] = [];
    for (let i = 0; i < this.nodes.length; i++) {
      const node = this.nodes[i];
      nodes.push({
        id: node.id, name: node.name, url: node.url, builtin: node.builtin,
        bootstrapHost: node.bootstrapHost, bootstrapIp: node.bootstrapIp
      });
    }
    return {
      mode: this.mode, selectedNodeId: this.selectedNodeId, nodes: nodes,
      vpn: this.vpn, suspended: this.suspended, dohActive: this.dohActive,
      applyError: this.applyError, generation: this.generation,
      syncImageDownloader: this.syncImageDownloader, vpnAutoBypass: this.vpnAutoBypass
    };
  }

  subscribe(listener: (snapshot: NetworkSnapshot) => void): () => void {
    this.listeners.push(listener);
    return () => {
      const index = this.listeners.indexOf(listener);
      if (index >= 0) {
        this.listeners.splice(index, 1);
      }
    };
  }

  getDohPolicy(): DohPolicy {
    if (!this.syncImageDownloader || this.suspended || this.mode === 'off') {
      return { mode: 'off' };
    }
    const node = this.activeNode();
    if (node.url.length === 0) {
      return { mode: 'off' };
    }
    return { mode: this.mode, url: node.url };
  }

  isSecureOnly(): boolean {
    return this.mode === 'secure_only';
  }

  async setMode(mode: NetworkMode): Promise<ActionResult> {
    if (this.mode === mode) {
      return { ok: true, error: 'none', saved: true };
    }
    this.mode = mode;
    this.generation++;
    this.applyNow();
    this.emit();
    const saved = await this.save();
    return { ok: true, error: 'none', saved: saved };
  }

  async setSyncImageDownloader(value: boolean): Promise<ActionResult> {
    this.syncImageDownloader = value;
    this.emit();
    const saved = await this.save();
    return { ok: true, error: 'none', saved: saved };
  }

  async setVpnAutoBypass(value: boolean): Promise<ActionResult> {
    if (this.vpnAutoBypass === value) {
      return { ok: true, error: 'none', saved: true };
    }
    const wasSuspended = this.suspended;
    this.vpnAutoBypass = value;
    this.recomputeSuspended(this.vpn);
    if (this.suspended !== wasSuspended) {
      this.generation++;
    }
    this.applyNow();
    this.emit();
    const saved = await this.save();
    return { ok: true, error: 'none', saved: saved };
  }

  async selectNode(id: string): Promise<ActionResult> {
    if (this.findNode(id) === undefined) {
      return { ok: false, error: 'not_found', saved: false };
    }
    if (this.selectedNodeId === id) {
      return { ok: true, error: 'none', saved: true };
    }
    this.selectedNodeId = id;
    this.generation++;
    this.applyNow();
    this.emit();
    const saved = await this.save();
    return { ok: true, error: 'none', saved: saved };
  }

  async addCustomNode(name: string, rawUrl: string, bootstrapIp: string): Promise<ActionResult> {
    const nodeName = name.trim();
    if (nodeName.length === 0 || nodeName.length > MAX_NODE_NAME_LENGTH) {
      return { ok: false, error: 'name', saved: false };
    }
    const parsed = parseDohUrl(rawUrl);
    if (parsed === undefined) {
      return { ok: false, error: 'url', saved: false };
    }
    const ip = bootstrapIp.trim();
    if (ip.length > 0 && !isIpAddress(ip)) {
      return { ok: false, error: 'ip', saved: false };
    }
    if (this.customNodes.length >= MAX_CUSTOM_NODES) {
      return { ok: false, error: 'limit', saved: false };
    }
    if (this.urlExists(parsed.key) || this.customUrlExists(parsed.key)) {
      return { ok: false, error: 'duplicate', saved: false };
    }
    let id = 'custom_' + Date.now().toString() + '_' + Math.floor(Math.random() * 10000).toString();
    while (this.findNode(id) !== undefined || this.customIdExists(id)) {
      id = 'custom_' + Date.now().toString() + '_' + Math.floor(Math.random() * 10000).toString();
    }
    this.customNodes.push({ id: id, name: nodeName, url: parsed.url, bootstrapIp: ip });
    this.rebuildNodes();
    this.selectedNodeId = id;
    this.generation++;
    this.applyNow();
    this.emit();
    const saved = await this.save();
    return { ok: true, error: 'none', saved: saved };
  }

  async removeCustomNode(id: string): Promise<ActionResult> {
    let index = -1;
    for (let i = 0; i < this.customNodes.length; i++) {
      if (this.customNodes[i].id === id) {
        index = i;
        break;
      }
    }
    if (index < 0) {
      return { ok: false, error: 'not_found', saved: false };
    }
    this.customNodes.splice(index, 1);
    if (this.selectedNodeId === id) {
      this.selectedNodeId = DEFAULT_NODE_ID;
      this.generation++;
    }
    this.rebuildNodes();
    this.applyNow();
    this.emit();
    const saved = await this.save();
    return { ok: true, error: 'none', saved: saved };
  }

  async restoreSystemDns(): Promise<ActionResult> {
    return this.setMode('off');
  }

  retryApply(): ActionResult {
    this.applyNow();
    this.emit();
    return { ok: !this.applyError, error: 'none', saved: true };
  }

  private loadConfig(): void {
    this.mode = DEFAULT_MODE;
    this.selectedNodeId = DEFAULT_NODE_ID;
    this.syncImageDownloader = true;
    this.vpnAutoBypass = true;
    this.customNodes = [];
    this.rebuildNodes();
    if (this.prefs === undefined) {
      return;
    }
    let raw = '';
    try {
      raw = this.prefs.getSync(CONFIG_KEY, '') as string;
    } catch (err) {
      const error = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'event=network_config_read_failed code=%{public}d', error.code);
      return;
    }
    if (raw.length === 0) {
      return;
    }
    try {
      const stored = JSON.parse(raw) as StoredConfig;
      if (stored.mode === 'off' || stored.mode === 'auto' || stored.mode === 'secure_only') {
        this.mode = stored.mode;
      }
      if (typeof stored.syncImageDownloader === 'boolean') {
        this.syncImageDownloader = stored.syncImageDownloader;
      }
      if (typeof stored.vpnAutoBypass === 'boolean') {
        this.vpnAutoBypass = stored.vpnAutoBypass;
      }
      if (typeof stored.selectedNodeId === 'string' && stored.selectedNodeId.length > 0) {
        this.selectedNodeId = stored.selectedNodeId;
      }
      if (Array.isArray(stored.customNodes)) {
        const items = stored.customNodes as CustomNodeData[];
        for (let i = 0; i < items.length && this.customNodes.length < MAX_CUSTOM_NODES; i++) {
          const item: CustomNodeData | null | undefined = items[i];
          if (item === null || item === undefined) {
            continue;
          }
          if (typeof item.id !== 'string' || item.id.length === 0 ||
            typeof item.name !== 'string' || typeof item.url !== 'string') {
            continue;
          }
          const name = item.name.trim();
          if (name.length === 0) {
            continue;
          }
          const parsed = parseDohUrl(item.url);
          if (parsed === undefined) {
            continue;
          }
          const ip = typeof item.bootstrapIp === 'string' ? item.bootstrapIp.trim() : '';
          if (ip.length > 0 && !isIpAddress(ip)) {
            continue;
          }
          if (this.findNode(item.id) !== undefined || this.customIdExists(item.id) ||
            this.urlExists(parsed.key) || this.customUrlExists(parsed.key)) {
            continue;
          }
          this.customNodes.push({
            id: item.id, name: name.substring(0, MAX_NODE_NAME_LENGTH), url: parsed.url, bootstrapIp: ip
          });
        }
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'event=network_config_invalid');
      this.mode = DEFAULT_MODE;
      this.selectedNodeId = DEFAULT_NODE_ID;
      this.syncImageDownloader = true;
      this.vpnAutoBypass = true;
      this.customNodes = [];
    }
    this.rebuildNodes();
    if (this.findNode(this.selectedNodeId) === undefined) {
      this.selectedNodeId = DEFAULT_NODE_ID;
    }
  }

  private rebuildNodes(): void {
    const list = builtinNodes();
    for (let i = 0; i < this.customNodes.length; i++) {
      const item = this.customNodes[i];
      const parsed = parseDohUrl(item.url);
      list.push({
        id: item.id, name: item.name, url: item.url, builtin: false,
        bootstrapHost: parsed === undefined ? '' : parsed.host, bootstrapIp: item.bootstrapIp
      });
    }
    this.nodes = list;
  }

  private findNode(id: string): DohNode | undefined {
    for (let i = 0; i < this.nodes.length; i++) {
      if (this.nodes[i].id === id) {
        return this.nodes[i];
      }
    }
    return undefined;
  }

  private activeNode(): DohNode {
    const node = this.findNode(this.selectedNodeId);
    if (node !== undefined) {
      return node;
    }
    return this.nodes.length > 0 ? this.nodes[0] : builtinNodes()[0];
  }

  private urlExists(key: string): boolean {
    for (let i = 0; i < this.nodes.length; i++) {
      const parsed = parseDohUrl(this.nodes[i].url);
      if (parsed !== undefined && parsed.key === key) {
        return true;
      }
    }
    return false;
  }

  private customUrlExists(key: string): boolean {
    for (let i = 0; i < this.customNodes.length; i++) {
      const parsed = parseDohUrl(this.customNodes[i].url);
      if (parsed !== undefined && parsed.key === key) {
        return true;
      }
    }
    return false;
  }

  private customIdExists(id: string): boolean {
    for (let i = 0; i < this.customNodes.length; i++) {
      if (this.customNodes[i].id === id) {
        return true;
      }
    }
    return false;
  }

  private applyNow(forcePins: boolean = false): void {
    const node = this.activeNode();
    const configUrl = node.url.length > 0 ? node.url : FALLBACK_DOH_URL;
    const requestedActive = this.mode !== 'off' && !this.suspended;
    try {
      if (!requestedActive) {
        this.clearPins();
        web_webview.WebviewController.setHttpDns(web_webview.SecureDnsMode.OFF, configUrl);
        this.applyError = false;
        this.dohActive = false;
        hilog.info(DOMAIN, TAG, 'event=doh_apply mode=off node=%{public}s vpn=%{public}s',
          node.id, this.vpn);
        return;
      }
      this.syncPins(node, forcePins);
      const secureMode = this.mode === 'secure_only'
        ? web_webview.SecureDnsMode.SECURE_ONLY
        : web_webview.SecureDnsMode.AUTO;
      web_webview.WebviewController.setHttpDns(secureMode, configUrl);
      this.applyError = false;
      this.dohActive = true;
      hilog.info(DOMAIN, TAG, 'event=doh_apply mode=%{public}s node=%{public}s vpn=%{public}s',
        this.mode, node.id, this.vpn);
    } catch (err) {
      const error = err as BusinessError;
      this.applyError = true;
      this.dohActive = false;
      hilog.error(DOMAIN, TAG, 'event=doh_apply_failed code=%{public}d mode=%{public}s node=%{public}s',
        error.code, this.mode, node.id);
    }
  }

  private syncPins(node: DohNode, force: boolean): void {
    const desired = new Map<string, string>();
    if (node.bootstrapHost.length > 0 && node.bootstrapIp.length > 0 && !isIpAddress(node.bootstrapHost)) {
      desired.set(node.bootstrapHost, node.bootstrapIp);
    }
    const stale: string[] = [];
    this.pinned.forEach((_ip: string, host: string) => {
      if (!desired.has(host)) {
        stale.push(host);
      }
    });
    for (let i = 0; i < stale.length; i++) {
      this.clearPin(stale[i]);
    }
    desired.forEach((ip: string, host: string) => {
      if (!force && this.pinned.get(host) === ip) {
        return;
      }
      try {
        web_webview.WebviewController.setHostIP(host, ip, PIN_TTL_SECONDS);
        this.pinned.set(host, ip);
        hilog.info(DOMAIN, TAG, 'event=host_pin action=set host=%{public}s ok=true', host);
      } catch (err) {
        const error = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'event=host_pin action=set host=%{public}s ok=false code=%{public}d',
          host, error.code);
      }
    });
  }

  private clearPin(host: string): void {
    try {
      web_webview.WebviewController.clearHostIP(host);
      hilog.info(DOMAIN, TAG, 'event=host_pin action=clear host=%{public}s ok=true', host);
    } catch (err) {
      const error = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'event=host_pin action=clear host=%{public}s ok=false code=%{public}d',
        host, error.code);
    }
    this.pinned.delete(host);
  }

  private clearPins(): void {
    const hosts: string[] = [];
    this.pinned.forEach((_ip: string, host: string) => {
      hosts.push(host);
    });
    for (let i = 0; i < hosts.length; i++) {
      this.clearPin(hosts[i]);
    }
    this.pinned.clear();
  }

  private detectVpnSync(): VpnState {
    try {
      const nets = connection.getAllNetsSync();
      for (let i = 0; i < nets.length; i++) {
        const caps = connection.getNetCapabilitiesSync(nets[i]);
        if (caps.bearerTypes.indexOf(connection.NetBearType.BEARER_VPN) >= 0) {
          return 'active';
        }
      }
      return 'inactive';
    } catch (err) {
      const error = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'event=vpn_detect_failed code=%{public}d', error.code);
      return 'unknown';
    }
  }

  /** unknown keeps the previous suspension so a transient query failure cannot unpause DoH. */
  private recomputeSuspended(state: VpnState): void {
    if (!this.vpnAutoBypass) {
      this.suspended = false;
      return;
    }
    if (state === 'active') {
      this.suspended = true;
      return;
    }
    if (state === 'inactive') {
      this.suspended = false;
    }
  }

  private updateVpnState(state: VpnState, force: boolean): void {
    const previousVpn = this.vpn;
    const previousSuspended = this.suspended;
    this.vpn = state;
    this.recomputeSuspended(state);
    const changed = previousVpn !== state || previousSuspended !== this.suspended;
    if (changed || force) {
      if (this.mode !== 'off' && previousSuspended !== this.suspended) { this.generation++; }
      this.applyNow(force);
      hilog.info(DOMAIN, TAG, 'event=vpn_state state=%{public}s suspended=%{public}s',
        this.vpn, String(this.suspended));
      this.emit();
    }
  }

  private startVpnWatch(): void {
    try {
      const conn = connection.createNetConnection();
      conn.on('netAvailable', (_handle: connection.NetHandle) => {
        this.scheduleVpnCheck();
      });
      conn.on('netLost', (_handle: connection.NetHandle) => {
        this.scheduleVpnCheck();
      });
      conn.on('netCapabilitiesChange', (_info: connection.NetCapabilityInfo) => {
        this.scheduleVpnCheck();
      });
      conn.register((err: BusinessError) => {
        if (err) {
          hilog.warn(DOMAIN, TAG, 'event=vpn_register_failed code=%{public}d', err.code);
        }
      });
      this.netConn = conn;
    } catch (err) {
      const error = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'event=vpn_monitor_unavailable code=%{public}d', error.code);
    }
  }

  private scheduleVpnCheck(): void {
    if (this.vpnTimer !== -1) {
      clearTimeout(this.vpnTimer);
    }
    this.vpnTimer = setTimeout(() => {
      this.vpnTimer = -1;
      this.updateVpnState(this.detectVpnSync(), false);
    }, VPN_DEBOUNCE_MS);
  }

  private async save(): Promise<boolean> {
    if (this.prefs === undefined) {
      return false;
    }
    const custom: CustomNodeData[] = [];
    for (let i = 0; i < this.customNodes.length; i++) {
      const item = this.customNodes[i];
      custom.push({ id: item.id, name: item.name, url: item.url, bootstrapIp: item.bootstrapIp });
    }
    const stored: StoredConfig = {
      schemaVersion: 1,
      mode: this.mode,
      selectedNodeId: this.selectedNodeId,
      syncImageDownloader: this.syncImageDownloader,
      vpnAutoBypass: this.vpnAutoBypass,
      customNodes: custom
    };
    try {
      await this.prefs.put(CONFIG_KEY, JSON.stringify(stored));
      await this.prefs.flush();
      hilog.info(DOMAIN, TAG, 'event=network_config_saved ok=true');
      return true;
    } catch (err) {
      const error = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'event=network_config_saved ok=false code=%{public}d', error.code);
      return false;
    }
  }

  private emit(): void {
    const snapshot = this.snapshot();
    const listeners = this.listeners.slice();
    for (let i = 0; i < listeners.length; i++) {
      listeners[i](snapshot);
    }
  }
}
