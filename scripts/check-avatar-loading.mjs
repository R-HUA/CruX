import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';

const main = readFileSync(new URL('../entry/src/main/ets/pages/MainTabs.ets', import.meta.url), 'utf8');
const media = readFileSync(new URL('../entry/src/main/ets/common/MediaFiles.ets', import.meta.url), 'utf8')
  .replace(/^import .*;\r?\n/gm, '').replace(/^export /gm, '');
const method = name => {
  const found = main.match(new RegExp('^  (?:private )?(?:static )?(?:async )?' + name + '\\([\\s\\S]*?^  \\}', 'm'));
  assert.ok(found, 'Missing production method: ' + name);
  return found[0];
};
const prefix = main.slice(main.indexOf('struct MainTabs {'), main.indexOf('  onWillApplyTheme('));
const fields = prefix.split('\n').filter(line =>
  /^\s+(?:@State )?(?:private )?(?:avatar\w*|retiredAvatarFiles|ownHandle|rawWeb|authenticationPage|currentUrl|hasError|progress|refreshing)\s*:/.test(line))
  .map(line => line.replace('@State ', '')).join('\n');
const methods = ['unquote', 'loadAvatar', 'resetAvatar', 'avatarImageFailed', 'closeAvatarFiles',
  'closeRetiredAvatarFiles', 'retireAvatarFiles', 'readAvatar', 'restoreAvatar', 'saveAvatar',
  'acceptHandle', 'reloadCurrent', 'aboutToDisappear', 'applyPageChrome', 'updateChromeFlag', 'logChromeResult'];
const cleanup = main.match(/^class AvatarCleanupFrame extends FrameCallback \{[\s\S]*?^\}/m)[0];
// Execute the production methods and real MediaFiles downloader; only platform I/O is substituted.
const code = stripTypeScriptTypes(media + '\n' + cleanup + '\nclass MainTabs {\n' + fields + '\n' +
  methods.map(method).join('\n') + '\n}\n;MainTabs');
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
const prefs = {
  get: async key => cacheRead ? cacheRead.promise : cache.get(key) || '',
  put: async (key, value) => { cache.set(key, value); puts.push([key, value]); },
  flush: async () => {}
};
const runtime = {
  ArrayBuffer, Uint8Array, Map, Promise, Date, FrameCallback: class {},
  DOMAIN: 0x0A11, TAG: 'OpenTwit', PREFS_NAME: 'opentwit_web', AVATAR_KEY: 'own_avatar',
  clearTimeout, clearInterval,
  preferences: { getPreferences: async () => prefs },
  NetworkConfig: { getInstance: () => ({ getDohPolicy: () => policy }) },
  accountAvatarScript: () => 'avatar', chromeScript: () => 'apply', chromeFlagScript: () => 'flag',
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
const MainTabs = vm.runInNewContext(code, runtime);
const context = { cacheDir: '/cache' };
const makePage = () => {
  const page = new MainTabs();
  Object.assign(page, { avatarAlive: true, ownHandle: 'alice', currentUrl: 'https://x.com/home',
    getUIContext: () => ({ getHostContext: () => context, postFrameCallback: frame => frames.push(frame) }),
    saveOwnHandle() {}, finishDiscover() {}, stopPostCheck() {}, syncChromeInsets() {},
    toast() {}, refreshes: 0, networkReloadTimer: -1, firstLoadTimer: -1, badgeTimer: -1,
    badgeRetryTimer: -1, draftSaveTimer: -1 });
  page.controller = {
    runJavaScript() {
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
const flushFrames = async () => { while (frames.length) { frames.shift().onIdle(2000000); } await settle(); };
const urlA = 'https://pbs.twimg.com/profile_images/1/first_normal.jpg';
const urlB = 'https://pbs.twimg.com/profile_images/2/second_normal.jpg';

let page = makePage();
responses.push(Error('DoH failed'), ok());
await read(page, urlA);
assert.match(page.avatarPath, /^file:\/\/\/cache\/x-image-\d+-avatar_\d+\.png$/);
assert.equal(requests.length, 2);
assert.equal(requests[0].options.dnsOverHttps, policy.url);
assert.equal(requests[1].options.dnsOverHttps, undefined);
const firstPath = page.avatarPath;
await read(page, urlA); await read(page, urlA);
assert.equal(requests.length, 2, 'Polling the same source must reuse its loaded file');
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

// A rejected download must be retried with a new session and the current DNS policy.
page = makePage(); policy = { mode: 'secure_only', url: 'https://dns.example/secure' };
responses.push(Error('private https://x.com/alice secret-message'));
await read(page, urlA);
assert.equal(page.avatarFailedUrl, urlA); assert.equal(page.avatarPath, '');
assert.equal(responses.length, 0, 'SECURE_ONLY must not issue a system-DNS fallback');
const failedRequests = requests.length;
await read(page, urlA); assert.equal(requests.length, failedRequests);
policy = { mode: 'off' }; responses.push(ok());
page.reloadCurrent(); await settle();
assert.notEqual(page.avatarPath, ''); assert.equal(requests.at(-1).options.dnsOverHttps, undefined);
page.aboutToDisappear(); await settle();

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
assert.match(main, /accountPicture\(path: string\)[\s\S]*?Image\(path\)/);
assert.equal((main.match(/this\.accountPicture\(this\.avatarPath\)/g) || []).length, 2);
assert.ok(method('acceptHandle').includes('this.resetAvatar()'));
assert.ok(method('openCompose').includes('this.acceptHandle(handle, false)'));
assert.equal(responses.length, 0); assert.equal(jsResults.length, 0);
await flushFrames();
console.log('Avatar production loading, DNS reuse, cache, refresh retry, lifecycle, races and private diagnostics passed.');
