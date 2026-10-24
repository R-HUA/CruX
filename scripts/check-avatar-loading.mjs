import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';

const main = readFileSync(new URL('../entry/src/main/ets/pages/MainTabs.ets', import.meta.url), 'utf8');
const accountSource = readFileSync(new URL('../entry/src/main/ets/common/AccountSession.ets', import.meta.url), 'utf8')
  .replace(/^import[\s\S]*?;\r?\n/gm, '').replace(/^@Observed\r?\n/m, '').replace(/^export /gm, '');
const media = readFileSync(new URL('../entry/src/main/ets/common/MediaFiles.ets', import.meta.url), 'utf8')
  .replace(/^import .*;\r?\n/gm, '').replace(/^export /gm, '');
const mainMethod = name => {
  const found = main.match(new RegExp('^  (?:private )?(?:static )?(?:async )?' + name + '\\([\\s\\S]*?^  \\}', 'm'));
  assert.ok(found, 'Missing production method: ' + name);
  return found[0];
};
const accountMethod = name => {
  const found = accountSource.match(new RegExp('^  (?:private )?(?:static )?(?:async )?' + name + '\\([\\s\\S]*?^  \\}', 'm'));
  assert.ok(found, 'Missing production account method: ' + name);
  return found[0];
};
const accountMethods = ['activate', 'setBackground', 'dispose', 'initialize', 'authenticationRequired',
  'retryFailedAvatar', 'readProfileDetails', 'saveOwnHandle', 'saveAvatar', 'restoreAvatar', 'loadAvatar',
  'resetAvatar', 'avatarImageFailed', 'closeAvatarFiles', 'closeRetiredAvatarFiles', 'retireAvatarFiles',
  'parseHandle', 'discoverOwnProfile', 'closeWebDrawer', 'cancelProfileNavigation', 'acceptHandle',
  'finishDiscover', 'readSettingsAccount', 'readAvatar', 'retryAvatarRead', 'clearAvatarRetry', 'confirmCurrentAccount'];
const mainMethods = ['unquote', 'webScript', 'documentStarted', 'reloadCurrent', 'aboutToDisappear', 'applyPageChrome', 'updateChromeFlag', 'logChromeResult'];
// Execute the production account session, page lifecycle/chrome methods, and real MediaFiles downloader;
// only platform I/O is substituted.
const mainCode = stripTypeScriptTypes('class MainTabs {\n' + mainMethods.map(mainMethod).join('\n') + '\n}\n;MainTabs');
const png = Uint8Array.from([137, 80, 78, 71, 13, 10, 26, 10, 1, 2]).buffer;
const ok = () => ({ responseCode: 200, result: png });
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
};
const settle = () => new Promise(resolve => setImmediate(resolve));
let policy = { mode: 'auto', url: 'https://dns.example/dns-query' };
let responses = [], requests = [], frames = [], removed = [], logs = [], puts = [];
let jsResults = [], cache = new Map(), cacheRead;
let timerId = 0;
let fileStamp = Date.now();
const timers = new Map();
const prefs = {
  get: async key => cacheRead ? cacheRead.promise : cache.get(key) || '',
  put: async (key, value) => { cache.set(key, value); puts.push([key, value]); },
  flush: async () => {}
};
const decodeSource = readFileSync(new URL('../entry/src/main/ets/common/WebChrome.ets',import.meta.url),'utf8')
  .match(/export function unquoteScriptResult[\s\S]*?^}/m)[0].replace('export ', '');
const runtime = {
  unquoteScriptResult: vm.runInNewContext(stripTypeScriptTypes(decodeSource) + ';unquoteScriptResult'),
  ...vm.runInNewContext(stripTypeScriptTypes(readFileSync(new URL('../entry/src/main/ets/common/WebMedia.ets',import.meta.url),'utf8'))
    .replace(/^export /gm,'')+';({resolveMedia})'),
  ArrayBuffer, Uint8Array, Map, Promise, Date: { now: () => ++fileStamp }, FrameCallback: class {},
  DOMAIN: 0x0A11, TAG: 'OpenTwit', PREFS_NAME: 'opentwit_web', AVATAR_KEY: 'own_avatar',
  OWN_HANDLE_SCRIPT: 'owner', profileBootstrapScript: () => 'bootstrap',
  profileUrl: handle => 'https://x.com/' + handle, pathOf: url => new URL(url).pathname,
  isSiteUrl: url => /^https:\/\/x\.com\//.test(url), accountDetailsScript: handle => 'account:' + handle,
  setTimeout: callback => { const id = ++timerId; timers.set(id, callback); return id; },
  clearTimeout: id => timers.delete(id), clearInterval,
  AVATAR_RETRY_MS: 1200, AVATAR_RETRY_LIMIT: 6, PROFILE_TIMEOUT_MS: 10000, OWN_HANDLE_KEY: 'own_handle',
  preferences: { getPreferences: async () => prefs },
  NetworkConfig: { getInstance: () => ({ getDohPolicy: () => policy }) },
  accountAvatarScript: () => 'avatar', accountAvatarDiagScript: () => 'diag',
  chromeScript: () => 'apply', chromeFlagScript: () => 'flag',
  appearanceScript: () => 'appearance',
  usesNativeNavigation: () => true, usesNativeHeader: () => true,
  http: { RequestMethod: { GET: 0 }, HttpDataType: { ARRAY_BUFFER: 0 }, createHttp: () => {
    let record;
    return {
      async request(url, options) {
        record = { url, options, destroyed: false }; requests.push(record);
        assert.ok(responses.length, 'Unexpected image request');
        const result = responses.shift();
        if (result instanceof Error) { throw result; }
        return result?.promise ? result.promise : result;
      },
      destroy() { if (record) { record.destroyed = true; } }
    };
  } },
  fileIo: { OpenMode: { CREATE: 1, READ_WRITE: 2, TRUNC: 4 }, listFile: async () => [],
    open: async () => ({ fd: 1 }), write: async (_fd, buffer) => buffer.byteLength,
    close: async () => {}, unlink: async path => { removed.push(path); } },
  image: { createImageSource: () => ({ getImageInfo: async () => ({ size: { width: 32, height: 32 } }),
    release: async () => {} }) },
  hilog: Object.fromEntries(['debug', 'info', 'warn', 'error'].map(level =>
    [level, (...args) => logs.push({ level, args })]))
};
runtime.MediaFiles = vm.runInNewContext(stripTypeScriptTypes(media) + ';MediaFiles', runtime);
runtime.AccountSession = vm.runInNewContext(stripTypeScriptTypes(accountSource) + ';AccountSession', runtime);
const MainTabs = vm.runInNewContext(mainCode + ';MainTabs', runtime);
const context = { cacheDir: '/cache' };
const makePage = () => {
  const page = new MainTabs();
  Object.assign(page, { rawWeb: false, authenticationPage: false, webNetworkReady: true, currentIndex: 0,
    webControllerReady: true, settingsOpen: false, pageAlive: true, appBackground: false,
    webSession: 0, refreshing: false, imageViewerOpen: false, failedWebUrl: '', webSource: 'https://x.com/home',
    networkReloadTimer: -1, firstLoadTimer: -1, pageStateTimer: -1, networkUnsubscribe: undefined,
    shellWindow: undefined, wideListener: undefined, avoidChanged() {},
    navigation: { currentUrl: 'https://x.com/home', navigationGeneration: 0, hasError: false, progress: 0, cancel() {} },
    composer: { sheetOpen: false, dispose() {} }, unread: { dispose() {}, stop() {} },
    getUIContext: () => ({ getHostContext: () => context, postFrameCallback: frame => frames.push(frame) }),
    stopBackgroundWork() {}, recoverMediaWeb() {}, syncChromeInsets() {}, armFirstLoadTimeout() {}, toast() {}, refreshes: 0,
    webImages: undefined });
  page.account = new runtime.AccountSession({
    getUIContext: () => page.getUIContext(), webScript: script => page.webScript(script),
    url: () => page.navigation.currentUrl, isAuthenticationPage: () => page.authenticationPage,
    isRawWeb: () => page.rawWeb, webImages: () => page.webImages, currentIndex: () => page.currentIndex,
    isControllerReady: () => page.webControllerReady, isSettingsOpen: () => page.settingsOpen,
    isComposerOpen: () => page.composer.sheetOpen, accountChanged: () => {},
    loadWeb: (url, keepProfile, allowDocumentLoad, direct) =>
      page.navigation.loaded.push([url, keepProfile, allowDocumentLoad, direct]),
    toast: message => page.toast(message)
  });
  page.navigation.loaded = [];
  page.account.ownHandle = 'alice';
  page.account.activate(false);
  for (const field of ['ownHandle', 'avatarUrl', 'avatarPath', 'avatarFailedUrl', 'avatarGeneration',
    'avatarReadRequest', 'avatarRetryTimer', 'avatarRetries', 'avatarFiles', 'retiredAvatarFiles']) {
    Object.defineProperty(page, field, {
      get() { return this.account[field]; }, set(value) { this.account[field] = value; }
    });
  }
  Object.defineProperty(page, 'currentUrl', {
    get() { return this.navigation.currentUrl; }, set(value) { this.navigation.currentUrl = value; }
  });
  for (const name of accountMethods.filter(name => name !== 'parseHandle')) {
    page[name] = (...args) => page.account[name](...args);
  }
  page.controller = {
    runJavaScript(script) {
      if (script === 'diag') { return Promise.resolve('"[]"'); }
      if (script === 'appearance') { return Promise.resolve(''); }
      assert.ok(jsResults.length, 'Unexpected JavaScript request');
      const result = jsResults.shift();
      if (result instanceof Error) { return Promise.reject(result); }
      return result?.promise ? result.promise : Promise.resolve(result);
    },
    refresh() { page.refreshes++; }
  };
  return page;
};
const read = async (page, url) => { jsResults.push(JSON.stringify(url)); page.readAvatar(); await settle(); };
const retry = async (page, url) => {
  const callback = timers.get(page.avatarRetryTimer);
  assert.ok(callback, 'Expected an avatar retry');
  timers.delete(page.avatarRetryTimer);
  jsResults.push(JSON.stringify(url)); callback(); await settle();
};
const flushFrames = async () => { while (frames.length) { frames.shift().onIdle(2000000); } await settle(); };
const urlA = 'https://pbs.twimg.com/profile_images/1/first_normal.jpg';
const urlB = 'https://pbs.twimg.com/profile_images/2/second_normal.jpg';

let page = makePage();
responses.push(Error('DoH failed'), ok());
await read(page, urlA);
assert.match(page.avatarPath, /^file:\/\/\/cache\/x-image-\d+-avatar_\d+\.png$/);
assert.equal(requests.length, 2);
assert.equal(requests[0].url,'https://pbs.twimg.com/profile_images/1/first_400x400.jpg','账号头像优先请求高清方图');
assert.equal(requests[0].options.dnsOverHttps, policy.url);
assert.equal(requests[1].options.dnsOverHttps, undefined);
const firstPath = page.avatarPath;
await read(page, urlA); await read(page, urlA);
assert.equal(requests.length, 2, 'Polling the same source must reuse its loaded file');
await read(page, urlA.replace('_normal','_400x400'));await read(page,urlA.replace('_normal',''));
assert.equal(requests.length,2,'同一头像的不同网页尺寸复用已下载的高清资源');assert.equal(page.avatarPath,firstPath);
assert.equal(puts.length, 1, 'Unchanged source must not rewrite preferences on every poll');
responses.push(ok()); await read(page, urlB);
assert.notEqual(page.avatarPath, firstPath, 'Different URL must use a different file/cache identity');
assert.ok(!removed.includes(firstPath.slice(7)), 'Displayed source must survive until the replacement render');
await flushFrames(); assert.ok(removed.includes(firstPath.slice(7)));
const secondPath = page.avatarPath;
page.avatarImageFailed(firstPath); assert.equal(page.avatarPath, secondPath, 'Ignore stale Image callbacks');
page.avatarImageFailed(secondPath);
assert.equal(page.avatarPath, ''); assert.equal(page.avatarFailedUrl, urlB);
const requestCount = requests.length;
await read(page, urlB); assert.equal(requests.length, requestCount, 'Failure does not create a polling retry loop');
responses.push(ok()); page.reloadCurrent(); await settle();
assert.equal(page.refreshes, 1); assert.notEqual(page.avatarPath, secondPath);
await flushFrames(); assert.ok(removed.includes(secondPath.slice(7)));
page.aboutToDisappear(); await settle();
assert.equal(page.avatarPath, ''); assert.equal(page.avatarFiles, undefined);

// 高清方图不存在时尝试原尺寸，不再降级为网页的小图。
page=makePage();policy={mode:'off'};
responses.push({responseCode:404},ok());
const qualityStart=requests.length;await read(page,urlA);
assert.deepEqual(requests.slice(qualityStart).map(item=>item.url),[
  'https://pbs.twimg.com/profile_images/1/first_400x400.jpg','https://pbs.twimg.com/profile_images/1/first.jpg']);
assert.notEqual(page.avatarPath,'');page.aboutToDisappear();await settle();

// 小档位也必须规整到同一张头像，不能拼成 mini_400x400。
for (const suffix of ['mini','x96','200x200']) {
  page=makePage();responses.push(ok());
  const start=requests.length;
  await read(page,urlA.replace('_normal','_'+suffix));
  assert.equal(requests[start].url,'https://pbs.twimg.com/profile_images/1/first_400x400.jpg');
  await read(page,urlA);
  assert.equal(requests.length,start+1,'同一头像的尺寸变化不重复下载');
  page.aboutToDisappear();await settle();
}

// 两个高清候选均不存在时，不请求 normal/bigger，也不撤下已显示的头像。
page=makePage();responses.push(ok());await read(page,urlA);
const retainedPath=page.avatarPath;
const pendingReplacement=deferred();responses.push(pendingReplacement);
const replacementStart=requests.length;await read(page,urlB);
assert.equal(page.avatarPath,retainedPath,'下载过程中保留同账号头像');
await flushFrames();assert.ok(!removed.includes(retainedPath.slice(7)));
responses.push({responseCode:404});pendingReplacement.resolve({responseCode:404});await settle();
assert.equal(page.avatarPath,retainedPath,'下载失败仍保留旧图');
assert.equal(page.avatarFailedUrl,urlB);
assert.deepEqual(requests.slice(replacementStart).map(item=>item.url),[
  'https://pbs.twimg.com/profile_images/2/second_400x400.jpg','https://pbs.twimg.com/profile_images/2/second.jpg']);
responses.push(ok());await retry(page,urlB);
assert.notEqual(page.avatarPath,retainedPath);
await flushFrames();assert.ok(removed.includes(retainedPath.slice(7)));
const displayedBeforeLeaving=page.avatarPath,pendingBeforeLeaving=deferred();responses.push(pendingBeforeLeaving);
await read(page,urlA);const requestBeforeLeaving=requests.at(-1);
page.aboutToDisappear();await settle();
assert.equal(page.avatarPath,'');assert.equal(requestBeforeLeaving.destroyed,true);
pendingBeforeLeaving.resolve(ok());await settle();await flushFrames();
assert.equal(page.avatarPath,'');assert.ok(removed.includes(displayedBeforeLeaving.slice(7)));

// 默认资源既不能从网页进入下载，也不能通过旧缓存恢复。
const defaultAvatar='https://abs.twimg.com/sticky/default_profile_images/default_profile_normal.png';
page=makePage();const beforeDefault=requests.length;await read(page,defaultAvatar);
assert.equal(page.avatarUrl,'');assert.equal(page.avatarPath,'');
cache.set('own_avatar:alice',defaultAvatar);await page.restoreAvatar('alice');await settle();
assert.equal(requests.length,beforeDefault);
responses.push(ok());await retry(page,urlA);
const realPath=page.avatarPath;await read(page,defaultAvatar);
assert.equal(page.avatarPath,realPath);assert.equal(page.avatarUrl,urlA);
page.aboutToDisappear();await settle();cache.clear();

// 旧图解码错误不能将正在下载的新地址标为失败或取消新下载。
page=makePage();responses.push(ok());await read(page,urlA);
const decodingPath=page.avatarPath,decodingReplacement=deferred();responses.push(decodingReplacement);
await read(page,urlB);page.avatarImageFailed(decodingPath);
assert.equal(page.avatarFailedUrl,'');assert.equal(page.avatarRetryTimer,-1);
decodingReplacement.resolve(ok());await settle();
assert.notEqual(page.avatarPath,'');assert.equal(page.avatarUrl,urlB);
page.aboutToDisappear();await settle();

// A rejected download must be retried with a new session and the current DNS policy.
page = makePage(); policy = { mode: 'secure_only', url: 'https://dns.example/secure' };
responses.push(Error('private https://x.com/alice secret-message'));
await read(page, urlA);
assert.equal(page.avatarFailedUrl, urlA); assert.equal(page.avatarPath, '');
assert.equal(responses.length, 0, 'SECURE_ONLY must not issue a system-DNS fallback');
const failedRequests = requests.length;
await read(page, urlA); assert.equal(requests.length, failedRequests);
policy = { mode: 'off' }; responses.push(ok());
await retry(page, urlA);
assert.notEqual(page.avatarPath, ''); assert.equal(requests.at(-1).options.dnsOverHttps, undefined);
assert.equal(page.avatarRetryTimer, -1);assert.equal(page.avatarRetries, 1);
page.clearAvatarRetry();assert.equal(page.avatarRetries,0);
page.aboutToDisappear(); await settle();

// 水合延迟、持续失败都只有六次重试，重复页面通知不会重新打开失败循环。
page = makePage(); await read(page, '');
responses.push(ok()); await retry(page, urlA);
assert.notEqual(page.avatarPath, '');assert.equal(page.avatarRetryTimer, -1);
page.aboutToDisappear();await settle();
page = makePage(); responses.push(Error('network'));await read(page, urlA);
for(let i=0;i<6;i++){responses.push(Error('network'));await retry(page,urlA);}
assert.equal(page.avatarRetries,6);assert.equal(page.avatarRetryTimer,-1);
const exhaustedRequests=requests.length;
await read(page,urlA);assert.equal(requests.length,exhaustedRequests);assert.equal(page.avatarRetryTimer,-1);
page.aboutToDisappear();await settle();
page = makePage();await read(page,'');
page.authenticationPage=true;page.resetAvatar();
assert.equal(page.avatarRetryTimer,-1);assert.equal(page.avatarRetries,0);
page.aboutToDisappear();await settle();

// 下载完成但原生渲染持续失败，也不能无限重启预算。
page=makePage();responses.push(ok());await read(page,urlA);
for(let i=0;i<6;i++){
  page.avatarImageFailed(page.avatarPath);responses.push(ok());await retry(page,urlA);
}
page.avatarImageFailed(page.avatarPath);
assert.equal(page.avatarRetries,6);assert.equal(page.avatarRetryTimer,-1);
page.aboutToDisappear();await settle();

// 上次账号仅预热头像；重复确认同一账号不作废正在读取的请求。
page = makePage();page.ownHandle='';cache.set('own_avatar:alice',urlA);responses.push(ok());
await page.restoreAvatar('alice',true);await settle();
assert.equal(page.ownHandle,'');assert.notEqual(page.avatarPath,'');
page.aboutToDisappear();await settle();cache.clear();
page=makePage();const sameAccountRead=deferred();jsResults.push(sameAccountRead);page.readAvatar();
page.acceptHandle('ALICE',false);responses.push(ok());sameAccountRead.resolve(JSON.stringify(urlA));await settle();
assert.notEqual(page.avatarPath,'');page.aboutToDisappear();await settle();

// Out-of-order page reads cannot overwrite a newer URL or a switched account.
page = makePage();
const oldRead = deferred(); jsResults.push(oldRead); page.readAvatar();
responses.push(ok()); await read(page, urlB);
oldRead.resolve(JSON.stringify(urlA)); await settle();
assert.equal(page.avatarUrl, urlB);
const switchedRead = deferred(); jsResults.push(switchedRead); page.readAvatar();
jsResults.push('""'); page.acceptHandle('bob', false); await settle();
switchedRead.resolve(JSON.stringify(urlA)); await settle();
assert.equal(page.avatarUrl, '');

// A read from another page or a pre-login state cannot populate the current avatar.
for (const change of [{ currentUrl: 'https://x.com/bob' }, { authenticationPage: true }]) {
  const stalePage = makePage();
  const pending = deferred(); jsResults.push(pending); stalePage.readAvatar();
  Object.assign(stalePage, change);
  pending.resolve(JSON.stringify(urlA)); await settle();
  assert.equal(stalePage.avatarUrl, '');
  stalePage.aboutToDisappear(); await settle();
}

// Replacing the URL within one account also invalidates an unfinished download.
const outdated = deferred(); responses.push(outdated);
const outdatedLoad = page.loadAvatar(urlA); await settle();
const outdatedRequest = requests.at(-1);
responses.push(ok()); await page.loadAvatar(urlB);
const replacementPath = page.avatarPath;
assert.equal(outdatedRequest.destroyed, true);
outdated.resolve(ok()); await outdatedLoad; await settle();
assert.equal(page.avatarPath, replacementPath);
page.resetAvatar(); await flushFrames();

// An older in-flight download is cancelled; late completion cannot repopulate the avatar.
const download = deferred(); responses.push(download);
const loading = page.loadAvatar(urlA); await settle();
const oldRequest = requests.at(-1);
page.resetAvatar(); page.ownHandle = 'carol';
assert.equal(oldRequest.destroyed, true);
responses.push(ok()); await page.loadAvatar(urlB);
const latestPath = page.avatarPath;
download.resolve(ok()); await loading; await settle();
assert.equal(page.avatarPath, latestPath);
page.aboutToDisappear(); await settle();

// Account A -> B -> A must not resurrect a preference read from the first A session.
page = makePage(); cacheRead = deferred();
const restoring = page.restoreAvatar('alice'); await settle();
page.resetAvatar(); page.ownHandle = 'bob'; page.resetAvatar(); page.ownHandle = 'alice';
cacheRead.resolve(urlA); await restoring; cacheRead = undefined;
assert.equal(page.avatarUrl, '');
cache.set('own_avatar:alice', urlA); responses.push(ok());
await page.restoreAvatar('alice'); await settle(); assert.notEqual(page.avatarPath, '');
responses.push(ok()); await page.loadAvatar(urlB);
await page.restoreAvatar('alice'); await settle();
assert.equal(page.avatarUrl, urlB, 'Cached source cannot replace a freshly observed avatar');
page.aboutToDisappear(); await settle();

// Leaving while a page read/download is pending blocks subsequent state writes.
page = makePage(); const leavingRead = deferred(); jsResults.push(leavingRead); page.readAvatar();
page.aboutToDisappear(); leavingRead.resolve(JSON.stringify(urlA)); await settle();
assert.equal(page.avatarUrl, '');
page = makePage(); const leavingDownload = deferred(); responses.push(leavingDownload);
const leavingLoad = page.loadAvatar(urlA); await settle();
page.aboutToDisappear(); assert.equal(requests.at(-1).destroyed, true);
leavingDownload.resolve(ok()); await leavingLoad; await settle();
assert.equal(page.avatarPath, '');

// 设置主动确认账号；缺少身份入口时展示错误，旧读取不能取消新的资料请求。
page=makePage();page.ownHandle='';page.settingsOpen=true;
page.account.restoreAvatar=()=>{};page.account.readAvatar=()=>{};
jsResults.push('', 'armed', 'alice', '', '');
await page.readSettingsAccount();await settle();
assert.equal(page.ownHandle,'alice');assert.equal(page.account.accountError,false);assert.equal(page.account.accountLoading,false);
page.aboutToDisappear();await settle();
page=makePage();page.ownHandle='';page.settingsOpen=true;
jsResults.push('', 'err', '');await page.readSettingsAccount();
assert.equal(page.account.accountError,true);assert.equal(page.account.accountLoading,false);
page.aboutToDisappear();await settle();
page=makePage();page.ownHandle='';page.settingsOpen=true;
const oldIdentity=deferred();jsResults.push(oldIdentity);
const oldSettings=page.readSettingsAccount();await settle();
page.settingsOpen=false;page.account.settingsReadGeneration++;page.account.profileNavigation++;
const newerProfile=page.account.profileNavigation;oldIdentity.resolve('alice');await oldSettings;
assert.equal(page.ownHandle,'');assert.equal(page.account.profileNavigation,newerProfile,'过期设置读取不能取消新资料请求');
page.aboutToDisappear();await settle();

// Injection diagnostics are asynchronous, useful, and exclude page/user content.
page = makePage();
const report = { navigation: true, header: true, navMatches: 2, pullMatches: 1, avatarFound: true };
jsResults.push(JSON.stringify(JSON.stringify({ ...report, url: urlA, account: 'secret-message' })));
page.applyPageChrome(page.currentUrl); await settle();
assert.ok(logs.some(log => log.level === 'debug' && log.args.includes(JSON.stringify(report))));
jsResults.push(Error('https://x.com/alice secret-message')); page.updateChromeFlag(page.currentUrl); await settle();
assert.ok(logs.some(log => log.level === 'warn' && log.args[2].includes('chrome_injection_failed')));
page.logChromeResult('apply', JSON.stringify({ error: 'TypeError: https://x.com/alice secret-message' }));
assert.ok(logs.some(log => log.level === 'warn' && log.args.includes('TypeError')));
assert.ok(!JSON.stringify(logs).includes('secret-message'));
assert.ok(!JSON.stringify(logs).includes(urlA));
const avatarItem=main.match(/ForEach\(\$\$\.path === '' \? \[\] : \[\$\$\.path\], \(path: string\) => \{([\s\S]*?)\n      \}, \(path: string\) => path\)/);
assert.ok(avatarItem,'头像以实际文件路径保持图片实例与回调身份');
const imageEvents=new Map(),avatarErrors=[];
const avatarOwner={account:{avatarPath:'/new',clearAvatarRetry(){},avatarImageFailed:path=>avatarErrors.push(path)}};
const renderAvatarItem=vm.runInNewContext(stripTypeScriptTypes('(function(path: string){'+avatarItem[1]+'})'),{
  ImageFit:{Cover:1},Image(path){const image={width(){return this;},height(){return this;},borderRadius(){return this;},objectFit(){return this;},
    onComplete(fn){return this;},onError(fn){imageEvents.set(path,fn);return this;}};return image;}
});
renderAvatarItem.call(avatarOwner,'/old');renderAvatarItem.call(avatarOwner,'/new');imageEvents.get('/old')();
assert.deepEqual(avatarErrors,['/old'],'旧 Image 的迟到错误必须携带旧路径，不能读取更新后的头像路径');
assert.equal((main.match(/this\.accountPicture\(\{ path: this\.account\.avatarPath \}\)/g) || []).length, 2);
assert.ok(accountMethod('acceptHandle').includes('this.resetAvatar()'));
const composerSource = readFileSync(new URL('../entry/src/main/ets/common/ComposerSession.ets',import.meta.url),'utf8');
assert.ok(composerSource.includes('this.host.acceptHandle(handle, false)'));
assert.equal(responses.length, 0); assert.equal(jsResults.length, 0);
await flushFrames();
console.log('Avatar production loading, DNS reuse, cache, refresh retry, lifecycle, races and private diagnostics passed.');
