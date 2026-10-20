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
const runtime = { Promise, Date, clearTimeout, DOMAIN: 1, TAG: 'test', PREFS_NAME: 'web', COMPOSE_DRAFT_KEY: 'compose_draft',
  TWITTER_COMPOSE: 'https://x.com/compose/post', $r: key => key,
  preferences: { getPreferences: async () => prefs },
  fillComposerScript: text => 'fill:' + text, clickRouteScript: url => 'route:' + url,
  web_webview: { WebviewController: class {} },
  hilog: { warn() {}, error() {} } };
const methods = ['unquote', 'persistDraft', 'openWebComposer', 'openCompose', 'loadWeb', 'clearPendingPost', 'clearHandoffDraft'];
const Page = vm.runInNewContext(stripTypeScriptTypes('class MainTabs {\n' + methods.map(method).join('\n') + '\n}; MainTabs'), runtime);
function page() {
  const p = new Page();
  Object.assign(p, { draft: '保留完整文本\nsecond line', composeOwner: 'alice', posting: false, postUncertain: false,
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
// A broken enhancement falls back to an ordinary navigation through the same Web controller.
{
  const p = page(), loaded = [];
  p.controller = { runJavaScript: async () => { throw Error('DOM'); }, setCustomUserAgent() {}, loadUrl: url => loaded.push(url) };
  p.userAgent = () => 'mobile'; await p.loadWeb('https://x.com/home');
  assert.deepEqual(loaded, ['https://x.com/home']);
}
const panel = read('entry/src/main/ets/pages/ComposerPanel.ets');
const more = panel.slice(panel.indexOf("Button($r('app.string.compose_more'))"), panel.indexOf('.onClick(this.onMore)'));
assert.doesNotMatch(more, /hasOwner|loading/);
const viewer = read('entry/src/main/ets/pages/NativeImageViewer.ets');
assert.doesNotMatch(viewer, /:\s*item\.source/);
assert.match(viewer, /needsRecovery\(\)/);
console.log('PASS: editor fallback, durable handoff, restart barrier, explicit recovery and local-only image display');
