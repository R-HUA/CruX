import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';

const read = path => readFileSync(new URL('../' + path, import.meta.url), 'utf8');
const main = read('entry/src/main/ets/pages/MainTabs.ets');
const method = name => {
  const found = main.match(new RegExp('^  (?:private )?(?:static )?(?:async )?' + name + '\\([\\s\\S]*?^  \\}', 'm'));
  assert.ok(found, name);
  return found[0];
};
const store = new Map(), writes = [], notices = [];
let failKey;
const prefs = { get: async (key, fallback) => store.has(key) ? store.get(key) : fallback };
const runtime = { Promise, Date, setTimeout, clearTimeout, DOMAIN: 1, TAG: 'test', PREFS_NAME: 'web', COMPOSE_DRAFT_KEY: 'compose_draft',
  TWITTER_COMPOSE: 'https://x.com/compose/post', OWN_HANDLE_SCRIPT:'owner', $r: key => key,
  preferences: { getPreferences: async () => prefs },
  fillComposerScript: text => 'fill:' + text, clickRouteScript: url => 'route:' + url,
  web_webview: { WebviewController: class {} },
  hilog: { info() {}, warn() {}, error() {} } };
const methods = ['unquote', 'persistDraft', 'openWebComposer', 'openCompose', 'loadWeb', 'clearPendingPost', 'clearHandoffDraft'];
const Page = vm.runInNewContext(stripTypeScriptTypes('class MainTabs {\n' + methods.map(method).join('\n') + '\n}; MainTabs'), runtime);
function page() {
  const p = new Page();
  Object.assign(p, { draft: '保留完整文本\nsecond line', composeOwner: 'alice', posting: false, postUncertain: false,
    webNetworkReady: true, navigationGeneration: 0, profileNavigation: 0, avatarAlive: true,
    appBackground: false, cancelProfileNavigation() {},
    composeHandoff: false, composeRevision: 0, draftSaveTimer: -1, draftWrite: Promise.resolve(), sheetOpen: false,
    getUIContext: () => ({ getHostContext: () => ({}), showAlertDialog() {} }),
    clearComposeSync() { this.composeRevision++; }, scheduleComposeSync() {}, acceptHandle() {},
    confirmCurrentAccount: async () => 'Alice', toast: message => notices.push(message),
    putPreference: async (key, value) => {
      if (key === failKey) { throw Error('storage failed'); }
      writes.push([key, value]); store.set(key, value);
    },
    composeController: { runJavaScript: async () => 'ok', loadUrl() {} } });
  return p;
}

// Handoff persists text and a recovery barrier before touching the webpage; a fresh page never submits it.
{
  const p = page(), text = p.draft;
  p.composeController.runJavaScript = async () => {
    assert.equal(store.get('compose_draft:alice'), text);
    assert.ok(store.get('compose_handoff:alice'));
    return 'ok';
  };
  await p.openWebComposer();
  assert.equal(p.webComposer, true); assert.equal(p.draft, text); assert.equal(p.postUncertain, true);
  const restarted = page();
  await restarted.openCompose();
  assert.equal(restarted.draft, text); assert.equal(restarted.composeHandoff, true);
  assert.equal(restarted.postUncertain, true); assert.equal(restarted.webComposer, false);
  await restarted.clearPendingPost();
  assert.equal(restarted.postUncertain, false); assert.equal(store.get('compose_draft:alice'), text);
  await p.clearHandoffDraft();
  assert.equal(store.get('compose_draft:alice'), ''); assert.equal(store.get('compose_handoff:alice'), '');
}
// DOM failure, account mismatch and missing native identity still expose the real editor and preserve text.
for (const failure of ['missing', 'throw', 'account', 'owner']) {
  const p = page(), text = p.draft;
  p.composeController.runJavaScript = async () => { if (failure === 'throw') { throw Error('DOM'); } return 'missing'; };
  if (failure === 'account') { p.confirmCurrentAccount = async () => 'bob'; }
  if (failure === 'owner') {
    p.composeOwner = '';
    p.composeController.runJavaScript = () => { throw Error('must not autofill unidentified account'); };
  }
  await p.openWebComposer(); assert.equal(p.webComposer, true); assert.equal(p.draft, text);
}
// A failed deletion leaves the recovery barrier in place.
{
  const p = page(); p.postUncertain = true; p.composeHandoff = true;
  failKey = 'compose_draft:alice'; await p.clearHandoffDraft(); failKey = undefined;
  assert.equal(p.composeHandoff, true); assert.equal(p.postUncertain, true);
}
// 常规入口无论缺少链接还是脚本失败，都保留当前文档；外部新地址才允许建立文档。
for(const failure of ['missing','throw']) {
  const p = page(), loaded = [];
  p.controller = { runJavaScript: async () => { if(failure==='throw')throw Error('DOM');return 'missing'; },
    loadUrl: url => loaded.push(url) };
  p.userAgent = () => 'mobile'; await p.loadWeb('https://x.com/home');
  assert.deepEqual(loaded, []);
  await p.loadWeb('https://x.com/alice/status/123',false,true);
  assert.deepEqual(loaded, ['https://x.com/alice/status/123']);
}
{
  const p=page(),loaded=[],results=['pending','pending','clicked'];
  p.controller={runJavaScript:async()=>results.shift(),loadUrl:url=>loaded.push(url)};
  await p.loadWeb('https://x.com/settings');assert.deepEqual(loaded,[]);assert.equal(results.length,0);
}
{
  const p=page(),loaded=[];
  p.controller={runJavaScript:async()=> 'cancelled',loadUrl:url=>loaded.push(url)};
  await p.loadWeb('https://x.com/alice/status/123',false,true);assert.deepEqual(loaded,[],'用户切页取消后不补发外部导航');
}
const panel = read('entry/src/main/ets/pages/ComposerPanel.ets');
const more = panel.slice(panel.indexOf("Button($r('app.string.compose_more'))"), panel.indexOf('.onClick(this.onMore)'));
assert.doesNotMatch(more, /hasOwner|loading/);
const viewer = read('entry/src/main/ets/pages/NativeImageViewer.ets');
assert.doesNotMatch(viewer, /:\s*item\.source/);
assert.match(viewer, /needsRecovery\(\)/);
console.log('PASS: editor fallback, durable handoff, restart barrier, explicit recovery and local-only image display');

// Real startup reaches its final mount state even when optional material/window APIs fail.
const extraMethods = ['aboutToAppear', 'openOwnProfile', 'cancelProfileNavigation', 'isHomeRoot', 'syncLauncherBadge', 'recoverMediaWeb'];
const extra = Object.fromEntries(extraMethods.map(name => {
  const code = method(name).replace(/^  (?:private )?/, '');
  return [name, code];
}));
let networkListener, badgeError, badgeGate;
const badgeCalls = [], waits = [];
const net = { ensureInitialized() {}, snapshot: () => ({ generation: 1, mode: 'secure_only', suspended: false, applyError: false }),
  subscribe(callback) { networkListener = callback; return () => {}; } };
Object.assign(runtime, { PROFILE_TIMEOUT_MS: 10000, BADGE_RETRY_LIMIT: 3,
  TWITTER_ROUTES: ['https://x.com/home'], NOTIFICATION_ASKED_KEY: 'asked', FLOATING_BAR_KEY: 'floating',
  AUTO_HIDE_BAR_KEY: 'hide', DESKTOP_MODE_KEY: 'desktop', OWN_HANDLE_KEY: 'owner',
  hdsMaterial: { getSystemMaterialTypes() { throw Error('unsupported'); } },
  window: { getLastWindow: async () => { throw Error('window unavailable'); } },
  removeExpiredDownloads: async () => {}, NetworkConfig: { getInstance: () => net },
  notificationManager: { async setBadgeNumber(total) { badgeCalls.push(total); if (badgeGate) { await badgeGate; } if (badgeError) { throw badgeError; } } },
  setTimeout: callback => { waits.push(callback); return waits.length; },
  isSiteUrl: () => true });
const ExtraPage = vm.runInNewContext(stripTypeScriptTypes('class ExtraPage {\n' + Object.values(extra).join('\n') + '\n};ExtraPage'), runtime);
const tick = async () => { for (let i = 0; i < 30; i++) { await Promise.resolve(); } };
// Navigation already waiting on JavaScript must not use a rebuilt controller or bypass a policy block.
for (const transition of ['blocked', 'rebuilt']) {
  const p = page(), loaded = []; let rejectRoute;
  p.controller = { runJavaScript: () => new Promise((_resolve, reject) => { rejectRoute = reject; }),
    setCustomUserAgent() {}, loadUrl: url => loaded.push(url) };
  p.userAgent = () => 'mobile';
  const navigation = p.loadWeb('https://x.com/explore'); await tick();
  if (transition === 'blocked') { p.webNetworkReady = false; p.navigationGeneration++; p.hasError = true; }
  else { ExtraPage.prototype.recoverMediaWeb.call(p, false, false); p.controller.loadUrl = url => loaded.push(url); }
  rejectRoute(Error('old script')); await navigation;
  assert.deepEqual(loaded, []);
  if (transition === 'blocked') { assert.equal(p.hasError, true); }
}
{
  const p = page();
  Object.assign(p, { avatarAlive: true, ownHandle: '',
    bridge: Object.fromEntries(['setImageHandler','setProfileHandler','setThemeHandler','setHandler','setModalHandler'].map(name => [name, () => {}])),
    applyBreakpoints() {}, armFirstLoadTimeout() {}, armBadgeRefresh() {}, syncChromeInsets() {},
    recoverMediaWeb: ExtraPage.prototype.recoverMediaWeb });
  await ExtraPage.prototype.aboutToAppear.call(p);
  assert.equal(p.preferencesReady, true); assert.equal(p.webNetworkReady, true);
  networkListener({ generation: 2, mode: 'secure_only', suspended: false, applyError: true });
  assert.equal(p.webNetworkReady, false); assert.equal(p.hasError, true); assert.equal(p.incomingControllerReady, false);
  p.webSession = 0;
  networkListener({ generation: 3, mode: 'secure_only', suspended: false, applyError: false });
  assert.equal(p.webNetworkReady, true); assert.equal(p.webSession, 1);
  const failedContext = page(); failedContext.getUIContext = () => { throw Error('context'); };
  await ExtraPage.prototype.aboutToAppear.call(failedContext);
  assert.equal(failedContext.preferencesReady, true);
}
// 当前页面直接确认账号，不为个人资料固定绕回首页；取消后的身份读取不能导航。
{
  const p = page(), accepted = [];
  Object.assign(p, { currentPath: '/search', incomingControllerReady: false,
    controller:{runJavaScript:async()=> 'Alice'},
    isHomeRoot: ExtraPage.prototype.isHomeRoot, cancelProfileNavigation: ExtraPage.prototype.cancelProfileNavigation,
    loadWeb: async () => {throw Error('不得绕回主页');}, acceptHandle: (...args) => accepted.push(args) });
  await ExtraPage.prototype.openOwnProfile.call(p);
  assert.deepEqual(accepted, [['Alice', true]]);
  let finish;
  p.currentPath='/home';p.controller.runJavaScript=async()=> '';
  p.confirmCurrentAccount = () => new Promise(resolve => { finish = resolve; });
  const stale = ExtraPage.prototype.openOwnProfile.call(p); await tick();
  p.cancelProfileNavigation(); p.currentPath = '/explore'; finish('old'); await stale;
  assert.equal(accepted.length, 1); assert.equal(p.discovering, false);
}
// 移动页没有本人资料链接时，保留从网页首页抽屉确认账号的流程。
{
  const p=page(),accepted=[];
  Object.assign(p,{currentPath:'/search',incomingControllerReady:false,
    controller:{runJavaScript:async()=> ''},isHomeRoot:ExtraPage.prototype.isHomeRoot,
    cancelProfileNavigation:ExtraPage.prototype.cancelProfileNavigation,
    loadWeb:async(url,keepProfile)=>{assert.equal(url,'https://x.com/home');assert.equal(keepProfile,true);},
    acceptHandle:(...args)=>accepted.push(args)});
  const navigating=ExtraPage.prototype.openOwnProfile.call(p);await tick();
  assert.equal(accepted.length,0);p.currentPath='/home';waits.shift()();await navigating;
  assert.deepEqual(accepted,[['Alice',true]]);
}
// Launcher state commits only after success, serializes writes, and bounds failures for an unchanged count.
{
  const p = page(); let retried = 0;
  Object.assign(p, { ownHandle: 'alice', unreadNotifications: 2, unreadMessages: 1, badgeShown: -1,
    badgeSyncFailures: 0, badgeSyncTarget: '', badgeSyncing: false,
    notificationsAllowed: () => true, retryBadgeRead() { retried++; }, syncLauncherBadge: ExtraPage.prototype.syncLauncherBadge });
  badgeError = Error('system busy'); await p.syncLauncherBadge();
  assert.equal(p.badgeShown, -1); assert.equal(retried, 1);
  badgeError = undefined; await p.syncLauncherBadge(); assert.equal(p.badgeShown, 3);
  let release;
  badgeGate = new Promise(resolve => { release = resolve; }); p.unreadMessages = 3;
  const first = p.syncLauncherBadge(); const before = badgeCalls.length;
  await p.syncLauncherBadge(); assert.equal(badgeCalls.length, before);
  p.unreadMessages = 4; badgeGate = undefined; release(); await first; await tick();
  assert.equal(p.badgeShown, 6);
  badgeError = Error('still busy'); p.unreadMessages = 5;
  for (let i = 0; i < 5; i++) { await p.syncLauncherBadge(); }
  assert.equal(p.badgeSyncFailures, 3); assert.equal(badgeCalls.filter(total => total === 7).length, 3);
  badgeError = undefined;
}

// Run the production network parser and effective-policy transitions with platform calls substituted.
let applyFails = false;
const networkSource = read('entry/src/main/ets/common/NetworkConfig.ets').replace(/^import .*;\r?\n/gm, '').replace(/^export /gm, '');
const network = vm.runInNewContext(stripTypeScriptTypes(networkSource) + ';({NetworkConfig,parseDohUrl,isIpAddress})', {
  Map, Date, url: { URL: { parseURL: raw => new URL(raw) } }, hilog: runtime.hilog,
  web_webview: { SecureDnsMode: { OFF: 0, AUTO: 1, SECURE_ONLY: 2 }, WebviewController: {
    setHttpDns() { if (applyFails) { throw { code: 17100001 }; } }, setHostIP() {}, clearHostIP() {} } }
});
for (const ip of ['::', '::1', '2001:db8::1', '1:2:3:4:5:6:7:8', '::ffff:192.0.2.1', '1.2.3.4']) {
  assert.equal(network.isIpAddress(ip), true, ip);
}
for (const ip of ['1:2:3', '1:::2', '1::2::3', ':1:2:3:4:5:6:7', '1:2:3:4:5:6:7:8::', '12345::', '::ffff:999.1.1.1', '192.0.2.1::', '01.2.3.4']) {
  assert.equal(network.isIpAddress(ip), false, ip);
}
assert.equal(network.parseDohUrl('https://dns.example/dns-query').key, network.parseDohUrl('https://dns.example:443/dns-query').key);
assert.notEqual(network.parseDohUrl('https://dns.example/dns-query').key, network.parseDohUrl('https://dns.example:444/dns-query').key);
const config = network.NetworkConfig.getInstance(); config.mode = 'secure_only';
config.updateVpnState('active', false); assert.equal(config.snapshot().generation, 1);
config.updateVpnState('inactive', false); assert.equal(config.snapshot().generation, 2);
config.updateVpnState('unknown', true); assert.equal(config.snapshot().generation, 2);
applyFails = true; config.applyNow();
assert.equal(config.snapshot().dohActive, false); assert.equal(config.snapshot().applyError, true);
assert.equal(config.getDohPolicy().mode, 'secure_only');
console.log('PASS: optional startup failure, forced-policy mount gate, slow navigation, stale cancellation, badge retry and network validation');
