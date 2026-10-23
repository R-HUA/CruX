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
  fillComposerScript: text => 'fill:' + text, clickPostButtonScript: owner => 'post:' + owner,
  clickRouteScript: url => 'route:' + url,
  cancelRouteScript: id => 'cancel:' + id, finishRouteScript: (id,rollback) => 'finish:' + id + ':' + rollback,
  web_webview: { WebviewController: class { loadUrl() {} } },
  hilog: { info() {}, warn() {}, error() {} } };
const composerSource = read('entry/src/main/ets/common/ComposerSession.ets')
  .replace(/^import[\s\S]*?;\r?\n/gm, '').replace(/^@Observed\r?\n/m, '').replace(/^export /gm, '');
const decodeSource = read('entry/src/main/ets/common/WebChrome.ets').match(/export function unquoteScriptResult[\s\S]*?^}/m)[0].replace('export ', '');
runtime.unquoteScriptResult = vm.runInNewContext(stripTypeScriptTypes(decodeSource) + ';unquoteScriptResult');
const ComposerSession = vm.runInNewContext(stripTypeScriptTypes(composerSource) + ';ComposerSession', runtime);
const methods = ['unquote','webScript','documentStarted','applyUserAgent'];
const Page = vm.runInNewContext(stripTypeScriptTypes('class MainTabs {\n' + methods.map(method).join('\n') + '\n}; MainTabs'), runtime);
const sessionClass = name => {
  const source = read('entry/src/main/ets/common/' + name + '.ets')
    .replace(/^import[\s\S]*?;\r?\n/gm, '').replace(/^@Observed\r?\n/m, '').replace(/^export /gm, '');
  return vm.runInNewContext(stripTypeScriptTypes('(function() {\n' + source + '\nreturn ' + name + ';})()'), runtime);
};
runtime.FrameCallback = class {};
const WebNavigation = sessionClass('WebNavigation');
const AccountSession = sessionClass('AccountSession');
const UnreadSession = sessionClass('UnreadSession');
function composer() {
  const session = new ComposerSession({
    getUIContext: () => ({ getHostContext: () => ({}), showAlertDialog() {} }),
    acceptHandle() {},
    confirmCurrentAccount: async () => 'Alice', toast: message => notices.push(message),
    putPreference: async (key, value) => {
      if (key === failKey) { throw Error('storage failed'); }
      writes.push([key, value]); store.set(key, value);
    }
  });
  Object.assign(session, { draft: '保留完整文本\nsecond line', composeOwner: 'alice',
    composeController: { runJavaScript: async () => 'ok', loadUrl() {} } });
  return session;
}
function page() {
  const p = new Page();
  p.navigation = new WebNavigation({ controller: () => p.controller, isNetworkReady: () => p.webNetworkReady,
    isControllerReady: () => p.webControllerReady,isActive:()=>p.pageAlive&&!p.appBackground,
    routeSettled() {},documentStarted: url => p.documentStarted(url),
    cancelProfileNavigation: () => p.account.cancelProfileNavigation(), toast: message => p.toast(message) });
  p.account = new AccountSession({ getUIContext: () => p.getUIContext(), webScript: script => p.webScript(script),
    url: () => p.navigation.currentUrl, isControllerReady: () => p.webControllerReady,
    isAuthenticationPage: () => p.authenticationPage, isRawWeb: () => p.rawWeb,
    webImages: () => p.webImages, currentIndex: () => p.currentIndex,
    isSettingsOpen: () => p.settingsOpen, isComposerOpen: () => p.composer.sheetOpen,
    accountChanged: () => p.unread.resetAccount(), loadWeb: (...args) => p.navigation.loadWeb(...args),
    toast: message => p.toast(message) });
  p.unread = new UnreadSession({ webScript: script => p.webScript(script), isControllerReady: () => p.webControllerReady, owner: () => p.account.ownHandle,
    url: () => p.navigation.currentUrl, isRawWeb: () => p.rawWeb, getUIContext: () => p.getUIContext(),
    putPreference: async () => {} });
  // 保留场景中的简洁赋值，实际状态与方法全部落到生产会话实例。
  for (const [owner, keys] of [
    [p.navigation, ['navigationGeneration', 'currentUrl', 'currentPath', 'failure', 'progress', 'loadWeb']],
    [p.account, ['profileNavigation', 'ownHandle', 'discovering', 'avatarReadRequest', 'avatarFailedUrl',
      'clearAvatarRetry', 'confirmCurrentAccount', 'acceptHandle', 'cancelProfileNavigation', 'closeWebDrawer']],
    [p.unread, ['unreadNotifications', 'unreadMessages', 'badgeShown', 'badgeSyncFailures', 'badgeSyncTarget',
      'badgeSyncing', 'notificationsAllowed', 'retryBadgeRead', 'syncLauncherBadge']]
  ]) {
    for (const key of keys) {
      Object.defineProperty(p, key, { get: () => typeof owner[key] === 'function' ? owner[key].bind(owner) : owner[key],
        set: value => { owner[key] = value; } });
    }
  }
  Object.defineProperty(p, 'hasError', {get: () => p.navigation.hasError,
    set: value => {p.navigation.failure = value ? 'document' : 'none';}});
  Object.assign(p, { composer: composer(), webNetworkReady: true, navigationGeneration: 0,
    profileNavigation: 0, pageAlive: true, appBackground: false, webControllerReady: true, webSession: 0,
    createBridge: () => ({}), armFirstLoadTimeout() {}, finishFirstLoad() {}, userAgent: () => 'mobile',
    getUIContext: () => ({ getHostContext: () => ({}), showAlertDialog() {} }),
    confirmCurrentAccount: async () => 'Alice', toast: message => notices.push(message) });
  return p;
}

// Handoff persists text and a recovery barrier before touching the webpage; a fresh page never submits it.
{
  const p = composer(), text = p.draft;
  p.composeController.runJavaScript = async () => {
    assert.equal(store.get('compose_draft:alice'), text);
    assert.ok(store.get('compose_handoff:alice'));
    return 'ok';
  };
  await p.openWebComposer();
  assert.equal(p.webComposer, true); assert.equal(p.draft, text); assert.equal(p.postUncertain, true);
  const restarted = composer();
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
  const p = composer(), text = p.draft;
  p.composeController.runJavaScript = async () => { if (failure === 'throw') { throw Error('DOM'); } return 'missing'; };
  if (failure === 'account') { p.host.confirmCurrentAccount = async () => 'bob'; }
  if (failure === 'owner') {
    p.composeOwner = '';
    p.composeController.runJavaScript = () => { throw Error('must not autofill unidentified account'); };
  }
  await p.openWebComposer(); assert.equal(p.webComposer, true); assert.equal(p.draft, text);
}
// A failed deletion leaves the recovery barrier in place.
{
  const p = composer(); p.postUncertain = true; p.composeHandoff = true;
  failKey = 'compose_draft:alice'; await p.clearHandoffDraft(); failKey = undefined;
  assert.equal(p.composeHandoff, true); assert.equal(p.postUncertain, true);
}
// 没有点击网页按钮时解除提交屏障，正文仍保留在同一账号的草稿中。
for (const result of ['missing','disabled','unavailable']) {
  const p=composer(),text=p.draft;
  Object.assign(p,{composeReady:true,composeLoading:false,sheetOpen:true});
  p.composeController.runJavaScript=async script=>script==='post:alice'?result:'ok';
  await p.postFromSheet();p.dispose();
  assert.equal(p.draft,text);assert.equal(p.posting,false);assert.equal(p.postUncertain,false);
  assert.equal(store.get('post_pending:alice'),false);assert.equal(store.get('compose_draft:alice'),text);
  assert.equal(p.composeMessage,'app.string.compose_submit_unavailable');
}
// 日常入口失败保留当前文档，只有显式文档操作使用独立入口。
for(const failure of ['missing','throw']) {
  const p = page(), loaded = [];
  p.controller = { runJavaScript: async () => { if(failure==='throw')throw Error('DOM');return 'missing'; },
    loadUrl: url => loaded.push(url) };
  p.userAgent = () => 'mobile'; await p.loadWeb('https://x.com/home');
  assert.deepEqual(loaded, []);
  await p.navigation.loadDocument('https://x.com/alice/status/123');
  assert.deepEqual(loaded, ['https://x.com/alice/status/123']);
}
{
  const p=page(),loaded=[],results=['pending','pending','arrived'];
  p.controller={runJavaScript:async script=>script.startsWith('route:')?JSON.stringify({status:results.shift(),document:'same',method:'link'}):'',loadUrl:url=>loaded.push(url)};
  await p.loadWeb('https://x.com/settings');assert.deepEqual(loaded,[]);assert.equal(results.length,0);
}
{
  const p=page(),loaded=[];
  p.controller={runJavaScript:async script=>script.startsWith('route:')?JSON.stringify({status:'cancelled',document:'same',method:'link'}):'',loadUrl:url=>loaded.push(url)};
  assert.equal(await p.loadWeb('https://x.com/alice/status/123'),'cancelled');assert.deepEqual(loaded,[],'用户切页取消后不补发外部导航');
}
const panel = read('entry/src/main/ets/pages/ComposerPanel.ets');
const more = panel.slice(panel.indexOf("Button($r('app.string.compose_more'))"), panel.indexOf('.onClick(this.onMore)'));
assert.doesNotMatch(more, /hasOwner|loading/);
const viewer = read('entry/src/main/ets/pages/NativeImageViewer.ets');
assert.doesNotMatch(viewer, /:\s*item\.source/);
assert.match(viewer, /needsRecovery\(\)/);
console.log('PASS: editor fallback, durable handoff, restart barrier, explicit recovery and local-only image display');

// 执行完整会话：销毁时保存最新草稿、清理计时器，并拒绝旧网页校验结果。
{
  let timerId = 0, finishFill;
  const timers = new Map();
  const Session = vm.runInNewContext(stripTypeScriptTypes(composerSource) + ';ComposerSession', {
    ...runtime, COMPOSER_READY_SCRIPT: 'ready', POST_RESULT_SCRIPT: 'result',
    setTimeout: callback => { const id = ++timerId; timers.set(id, callback); return id; },
    clearTimeout: id => timers.delete(id)
  });
  const p = new Session(composer().host);
  Object.assign(p, { composeOwner: 'alice', sheetOpen: true, composeLoading: false,
    composeController: { runJavaScript: () => new Promise(resolve => { finishFill = resolve; }) } });
  p.changeDraft('第一份');
  const validationId = p.composeSyncTimer;
  const validation = timers.get(validationId); timers.delete(validationId);
  const pending = validation();
  p.changeDraft('最后一份');
  p.dispose();
  finishFill('ok'); await pending; await p.draftWrite;
  assert.equal(store.get('compose_draft:alice'), '最后一份');
  assert.equal(timers.size, 0, '销毁后不能重新创建校验或草稿定时器');
  assert.equal(p.composeReady, false);

  // 后台只暂停结果轮询，不解除已提交操作的未知状态；前台恢复确认。
  const posting = new Session(composer().host);
  let reads = 0;
  Object.assign(posting, { posting: true, postUncertain: true,
    composeController: { runJavaScript: async () => { reads++; return 'submitted'; } } });
  await posting.checkPostResult();
  assert.equal(timers.size, 1);
  posting.setBackground(true);
  assert.equal(timers.size, 0); assert.equal(posting.postUncertain, true); assert.equal(posting.posting, true);
  posting.setBackground(false); await Promise.resolve(); await Promise.resolve();
  assert.equal(reads, 2);
  posting.dispose(); assert.equal(timers.size, 0);
}
console.log('PASS: composer lifetime, latest draft flush, stale validation and background post recovery');

// Real startup reaches its final mount state even when optional material/window APIs fail.
const extraMethods = ['aboutToAppear', 'openOwnProfile', 'isHomeRoot', 'recoverMediaWeb', 'reloadCurrent'];
const extra = Object.fromEntries(extraMethods.map(name => {
  const code = method(name).replace(/^  (?:private )?/, '');
  return [name, code];
}));
let networkListener, badgeError, badgeGate, netApplyError=false;
const badgeCalls = [], waits = [];
const net = { ensureInitialized() {}, snapshot: () => ({ generation: 1, mode: 'secure_only', suspended: false, applyError: netApplyError }),
  subscribe(callback) { networkListener = callback; return () => {}; } };
Object.assign(runtime, { PROFILE_TIMEOUT_MS: 10000, BADGE_RETRY_LIMIT: 3,
  TWITTER_ROUTES: ['https://x.com/home'], NOTIFICATION_ASKED_KEY: 'asked', FLOATING_BAR_KEY: 'floating',
  AUTO_HIDE_BAR_KEY: 'hide', DESKTOP_MODE_KEY: 'desktop', OWN_HANDLE_KEY: 'owner',
  hdsMaterial: { getSystemMaterialTypes() { throw Error('unsupported'); } },
  window: { getLastWindow: async () => { throw Error('window unavailable'); } },
  removeExpiredDownloads: async () => {}, NetworkConfig: { getInstance: () => net },
  notificationManager: { async setBadgeNumber(total) { badgeCalls.push(total); if (badgeGate) { await badgeGate; } if (badgeError) { throw badgeError; } } },
  setTimeout: callback => { waits.push(callback); return waits.length; },
  setInterval: () => 1, clearInterval() {},
  profileUrl: handle => 'https://x.com/' + handle,
  isSiteUrl: () => true });
const ExtraPage = vm.runInNewContext(stripTypeScriptTypes('class ExtraPage {\n' + Object.values(extra).join('\n') + '\n};ExtraPage'), runtime);
const tick = async () => { for (let i = 0; i < 30; i++) { await Promise.resolve(); } };
// Navigation already waiting on JavaScript must not use a rebuilt controller or bypass a policy block.
for (const transition of ['blocked', 'rebuilt']) {
  const p = page(), loaded = []; let rejectRoute;
  p.controller = { runJavaScript: script => script.startsWith('route:')?new Promise((_resolve, reject) => { rejectRoute = reject; }):Promise.resolve(''),
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
  Object.assign(p, { pageAlive: true, ownHandle: '',
    bridge: Object.fromEntries(['setImageHandler','setProfileHandler','setThemeHandler','setHandler','setModalHandler'].map(name => [name, () => {}])),
    applyBreakpoints() {}, armFirstLoadTimeout() {}, armBadgeRefresh() {}, syncChromeInsets() {},
    recoverMediaWeb: ExtraPage.prototype.recoverMediaWeb });
  await ExtraPage.prototype.aboutToAppear.call(p);
  assert.equal(p.preferencesReady, true); assert.equal(p.webNetworkReady, true);
  networkListener({ generation: 2, mode: 'secure_only', suspended: false, applyError: true });
  assert.equal(p.webNetworkReady, false); assert.equal(p.hasError, true); assert.equal(p.webControllerReady, false);
  p.webSession = 0;
  networkListener({ generation: 3, mode: 'secure_only', suspended: false, applyError: false });
  assert.equal(p.webNetworkReady, true); assert.equal(p.webSession, 1);
  const failedContext = page(); failedContext.getUIContext = () => { throw Error('context'); };
  await ExtraPage.prototype.aboutToAppear.call(failedContext);
  assert.equal(failedContext.preferencesReady, true);
}
// 文档失败沿用已绑定控制器；只有策略失败重配网络，应用仍失败时不能放行。
for (const scenario of ['page_failed', 'apply_recovered', 'apply_failed']) {
  const p = page();
  let applies = 0, refreshes = 0;
  netApplyError=false;
  Object.assign(p, { pageAlive: true, ownHandle: '',
    bridge: Object.fromEntries(['setImageHandler','setProfileHandler','setThemeHandler','setHandler','setModalHandler'].map(name => [name, () => {}])),
    applyBreakpoints() {}, armFirstLoadTimeout() {}, armBadgeRefresh() {}, syncChromeInsets() {},
    recoverMediaWeb: ExtraPage.prototype.recoverMediaWeb });
  await ExtraPage.prototype.aboutToAppear.call(p);
  Object.assign(p, { failure: scenario === 'page_failed' ? 'document' : 'policy', webNetworkReady: scenario === 'page_failed', webSession: 0,
    currentUrl: 'https://x.com/home', webSource: 'https://x.com/home',
    failedWebUrl: 'https://x.com/alice/status/123', rawWeb: false,
    controller: { refresh() { refreshes++; }, loadUrl(url) {p.loadedUrl=url;} } });
  net.ensureApplied = () => {
    applies++;
    netApplyError=scenario === 'apply_failed';
    networkListener({ generation: 1, mode: 'secure_only', suspended: false, applyError: scenario === 'apply_failed' });
  };
  ExtraPage.prototype.reloadCurrent.call(p);
  if(scenario === 'page_failed') {
    assert.equal(applies,0);assert.equal(p.webSession,0);
    assert.equal(p.loadedUrl,'https://x.com/alice/status/123');
    assert.equal(p.hasError,false);continue;
  }
  assert.equal(applies, 1);
  assert.equal(refreshes, 0, '错误页不能重复刷新失败控制器或刷新尚未绑定的新控制器');
  if (scenario === 'apply_failed') {
    assert.equal(p.webSession, 0);
    assert.equal(p.hasError, true);
    assert.equal(p.webNetworkReady, false);
    net.ensureApplied = () => {netApplyError=false;networkListener({ generation: 1, mode: 'secure_only', suspended: false, applyError: false });};
    ExtraPage.prototype.reloadCurrent.call(p);
  }
  assert.equal(p.webSession, 1, '策略恢复订阅和重试入口只能重建一次');
  assert.equal(p.webSource, 'https://x.com/alice/status/123');
  assert.equal(p.hasError, false);
  assert.equal(p.webNetworkReady, true);
}
{
  const p = page(); let refreshes = 0;
  net.ensureApplied = () => { throw Error('正常刷新不重配网络'); };
  Object.assign(p, { hasError: false, webNetworkReady: true, avatarReadRequest: 0,
    avatarFailedUrl: '', clearAvatarRetry() {}, controller: { refresh() { refreshes++; } } });
  ExtraPage.prototype.reloadCurrent.call(p);
  assert.equal(refreshes, 1);
}
console.log('PASS: cause-specific retries preserve URLs, rebuild once, and keep strict-mode failures blocked');

// 当前页面直接确认账号，不为个人资料固定绕回首页；取消后的身份读取不能导航。
{
  const p = page(), accepted = [],targets=[];
  Object.assign(p, { currentPath: '/search', webControllerReady: true,
    controller:{runJavaScript:async()=> 'Alice'},
    isHomeRoot: ExtraPage.prototype.isHomeRoot,
    loadWeb: async url => {targets.push(url);return 'arrived';}, acceptHandle: (...args) => accepted.push(args) });
  await ExtraPage.prototype.openOwnProfile.call(p);
  assert.deepEqual(accepted, [['Alice', false]]);assert.deepEqual(targets,['https://x.com/Alice']);
  let finish;
  p.currentPath='/home';p.controller.runJavaScript=async script=>script==='owner'?new Promise(resolve=>{finish=resolve;}):'';
  const stale = ExtraPage.prototype.openOwnProfile.call(p); await tick();
  p.cancelProfileNavigation(); p.currentPath = '/explore'; finish('old'); await stale;
  assert.equal(accepted.length, 1); assert.equal(p.discovering, false);
}
// 无法读取当前身份时明确失败，不绕回首页或打开抽屉。
{
  const p=page(),accepted=[];
  Object.assign(p,{currentPath:'/search',webControllerReady:true,
    controller:{runJavaScript:async()=> ''},isHomeRoot:ExtraPage.prototype.isHomeRoot,
    loadWeb:async()=>{throw Error('身份未确认时不得导航');},
    acceptHandle:(...args)=>accepted.push(args)});
  await ExtraPage.prototype.openOwnProfile.call(p);
  assert.equal(accepted.length,0);assert.equal(notices.at(-1),'app.string.account_unconfirmed');
}
// Launcher state commits only after success, serializes writes, and bounds failures for an unchanged count.
{
  const p = page(); let retried = 0;
  Object.assign(p, { ownHandle: 'alice', unreadNotifications: 2, unreadMessages: 1, badgeShown: -1,
    badgeSyncFailures: 0, badgeSyncTarget: '', badgeSyncing: false,
    notificationsAllowed: () => true, retryBadgeRead() { retried++; } });
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
  for (let i = 0; i < 8; i++) { await p.syncLauncherBadge(); }
  assert.equal(p.badgeSyncFailures, 6); assert.equal(badgeCalls.filter(total => total === 7).length, 6);
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
