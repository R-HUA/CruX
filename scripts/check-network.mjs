import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';

const root = new URL('../', import.meta.url);
const read = (path) => readFileSync(new URL(path, root), 'utf8');

const locales = ['base', 'zh_CN', 'ar'];
const keySets = locales.map((locale) => {
  const data = JSON.parse(read('entry/src/main/resources/' + locale + '/element/string.json'));
  return new Set(data.string.map((entry) => entry.name));
});
const baseKeys = keySets[0];
for (let i = 1; i < keySets.length; i++) {
  assert.deepEqual([...baseKeys].sort(), [...keySets[i]].sort(),
    'string keys must match between ' + locales[0] + ' and ' + locales[i]);
}

const moduleJson = read('entry/src/main/module.json5');
assert(moduleJson.includes('ohos.permission.GET_NETWORK_INFO'), 'GET_NETWORK_INFO permission missing');
assert(baseKeys.has('network_info_reason'), 'network_info_reason string missing');

// setHttpDns silently reports "web engine is nullptr" and applies nothing, so
// the engine must exist before the first DoH configuration and page load.
const ability = read('entry/src/main/ets/entryability/EntryAbility.ets');
const engineAt = ability.indexOf('this.initializeWebEngine()');
const applyAt = ability.indexOf('NetworkConfig.getInstance().initialize');
const loadAt = ability.indexOf('loadContent');
assert(engineAt >= 0 && applyAt > engineAt,
  'ArkWeb engine must initialize before NetworkConfig applies DoH');
assert(applyAt < loadAt, 'DoH must be configured before loadContent');

const networkConfig = read('entry/src/main/ets/common/NetworkConfig.ets');
assert(networkConfig.includes("DEFAULT_MODE: NetworkMode = 'auto'"), 'DoH default must be AUTO');
assert(networkConfig.includes("DEFAULT_NODE_ID: string = 'cloudflare'"), 'default node must be Cloudflare');
assert(networkConfig.includes('setHttpDns'), 'setHttpDns is not wired');
assert(networkConfig.includes('setHostIP'), 'setHostIP is not wired');
assert(networkConfig.includes('clearHostIP'), 'clearHostIP is not wired');
assert(networkConfig.includes('getDohPolicy'), 'MediaFiles policy hook missing');
assert(!/hilog[^\n]*\.url/.test(networkConfig), 'NetworkConfig must not log node URLs');
assert(!/supportsEch|echEnabled|echReady|Encrypted Client Hello/.test(networkConfig),
  'ECH must not be implemented as a fake setting');

const probe = read('entry/src/main/ets/common/DohProbe.ets');
assert(probe.includes('buildAddressQuery'), 'DoH A query builder missing');
assert(probe.includes('application/dns-message'), 'DoH media type missing');
assert(probe.includes('BASIC_URL_SAFE'), 'base64url encoding missing');
assert(!/hilog[^\n]*(nodeUrl|probeUrl)/.test(probe), 'DoH probe must not log endpoint URLs');

const probeSource = stripTypeScriptTypes(probe.replace(/^import .*;\r?\n/gm, ''))
  .replace(/^export /gm, '');
let captured = undefined;
let respond = async () => ({ responseCode: 200,
  result: Uint8Array.from([0, 0, 0x81, 0x80, 0, 0, 0, 0, 0, 0, 0, 0]).buffer });
let destroyed = 0;
const probeRuntime = {
  ArrayBuffer, Uint8Array, Map, Promise, Date,
  util: {
    Type: { BASIC_URL_SAFE: 1 },
    Base64Helper: class {
      encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64url') + '='; }
    }
  },
  http: {
    RequestMethod: { GET: 0 },
    HttpDataType: { ARRAY_BUFFER: 0 },
    createHttp: () => ({
      request: async (url, options) => { captured = { url, options }; return respond(); },
      destroy: () => { destroyed++; }
    })
  },
  hilog: { info() {}, warn() {} }
};
const probed = vm.runInNewContext(probeSource + ';({buildAddressQuery,readRcode,DohProbe})', probeRuntime);
assert.deepEqual(Array.from(probed.buildAddressQuery('x.com')),
  [0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 120, 3, 99, 111, 109, 0, 0, 1, 0, 1],
  'A query wire format is wrong');
assert.equal(probed.buildAddressQuery('bad..host').length, 0, 'invalid host must not build a query');
assert.equal(probed.readRcode(Uint8Array.from([0, 0, 0x81, 0x82, 0, 0, 0, 0, 0, 0, 0, 0]).buffer), 2);
assert.equal(probed.readRcode(new ArrayBuffer(4)), -1);

const doh = new probed.DohProbe();
const ok = await doh.probe('https://cloudflare-dns.com/dns-query');
assert.equal(ok.status, 'ok');
assert.equal(ok.rcode, 0);
assert(ok.latencyMs >= 1, 'probe must report elapsed time');
assert(captured.url.startsWith('https://cloudflare-dns.com/dns-query?dns='), 'probe URL shape is wrong');
assert(!captured.url.endsWith('='), 'base64url padding must be stripped');
assert.equal(captured.options.header.Accept, 'application/dns-message');
assert.equal(captured.options.dnsOverHttps, undefined, 'probe must not recurse through DoH');
assert.equal(captured.options.usingCache, false);

respond = async () => ({ responseCode: 200,
  result: Uint8Array.from([0, 0, 0x81, 0x83, 0, 0, 0, 0, 0, 0, 0, 0]).buffer });
assert.equal((await doh.probe('https://dns.google/dns-query')).status, 'rcode');
respond = async () => ({ responseCode: 500, result: new ArrayBuffer(12) });
assert.equal((await doh.probe('https://dns.google/dns-query')).status, 'bad_response');
respond = async () => { throw Object.assign(new Error('offline'), { code: 201 }); };
assert.equal((await doh.probe('https://dns.google/dns-query')).status, 'unreachable');
assert.equal(destroyed, 4, 'each probe request must be destroyed');

const media = read('entry/src/main/ets/common/MediaFiles.ets');
assert(media.includes('dnsOverHttps'), 'image downloader does not use dnsOverHttps');
assert(media.includes('media_doh_fallback'), 'AUTO DoH fallback is missing');
assert(media.includes("policy.mode !== 'auto'"), 'SECURE_ONLY must not fall back');

const sheet = read('entry/src/main/ets/pages/NetworkSettingsSheet.ets');
assert(sheet.includes('NetworkSettingsSheet'), 'sheet component missing');
assert(!/supportsEch|echEnabled|echReady|Encrypted Client Hello/.test(sheet),
  'ECH UI must not be shipped');
assert(!/#[0-9a-fA-F]{3,8}\b/.test(sheet), 'network sheet must use system colors');

const main = read('entry/src/main/ets/pages/MainTabs.ets');
assert(main.includes('this.networkSettingsSheet()'), 'network sheet is not mounted');
assert(main.includes('bindSheet($$this.networkOpen'), 'network sheet host missing');
assert(main.includes("app.string.network_title"), 'network menu entry missing');
assert(main.includes('this.settingsPill()'), 'pre-login settings pill missing');
assert(main.includes('bindMenu(this.settingsMenu)'), 'settings menu is not bound');
assert(main.includes('app.string.settings_title'), 'settings pill label missing');
assert(main.includes('settingsPillVisible'), 'settings pill visibility rule missing');
assert(!main.includes('networkSecureOnly'), 'secure-only gating must not hide error recovery');
assert(main.includes('network_open_settings'), 'error screen network settings button missing');

const flushStart = main.indexOf('private flushNetworkReload');
const recoverStart = main.indexOf('private recoverAfterNetworkChange');
assert(flushStart >= 0 && recoverStart > flushStart, 'network reload methods missing');
const flushBody = main.substring(flushStart, recoverStart);
assert(!flushBody.includes('authenticationPage'), 'network reload must not drop auth pages');
assert(!flushBody.includes('firstLoadDone'), 'network reload must not drop the first load');
const recoverBody = main.substring(recoverStart, main.indexOf('@Builder', recoverStart));
assert(recoverBody.includes('reloadCurrent()'), 'network recovery must reload the current page');
assert(recoverBody.includes('TWITTER_ROUTES[0]'), 'network recovery needs a first-load fallback');
assert(recoverBody.includes('armFirstLoadTimeout()'), 'first-load watchdog must be re-armed');

const sourceFiles = [
  'entry/src/main/ets/pages/MainTabs.ets',
  'entry/src/main/ets/pages/NetworkSettingsSheet.ets'
];
const referenced = new Set();
for (const file of sourceFiles) {
  const source = read(file);
  const matches = source.matchAll(/app\.string\.((?:network|settings|appearance)_[a-z0-9_]+)/g);
  for (const match of matches) {
    referenced.add(match[1]);
  }
}
for (const key of referenced) {
  assert(baseKeys.has(key), 'referenced string missing: ' + key);
}
assert(baseKeys.has('settings_title'), 'settings_title string missing');

const sysResource = 'D:/Program Files/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/sysResource.js';
if (existsSync(sysResource)) {
  const symbols = readFileSync(sysResource, 'utf8');
  for (const name of ['lock_shield', 'checkmark_shield_fill', 'globe_badge_heart',
    'arrow_left_arrow_right', 'arrow_clockwise', 'plus', 'trash_fill',
    'gearshape', 'paintbrush_fill']) {
    assert(new RegExp('\\b' + name + ':').test(symbols), 'system symbol missing: ' + name);
  }
}

console.log('Network permission, strings, DoH wiring, fallback and symbol checks passed.');
