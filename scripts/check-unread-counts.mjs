#!/usr/bin/env node
// Checks the unread-count script the shell injects into x.com.
//
// UNREAD_COUNTS_SCRIPT in entry/src/main/ets/common/WebChrome.ets is a string
// of JavaScript, so nothing type-checks it: this extracts it the same way the
// ArkTS build will, then runs it against a stub DOM covering the shapes the
// page can hand back. No device, no network.
//
//   node scripts/check-unread-counts.mjs

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';

const here = dirname(fileURLToPath(import.meta.url));
const chrome = join(here, '..', 'entry', 'src', 'main', 'ets', 'common', 'WebChrome.ets');
const unreadSessionPath = join(here, '..', 'entry', 'src', 'main', 'ets', 'common', 'UnreadSession.ets');

function extractScript() {
  const source = readFileSync(chrome, 'utf8').replace(/\r\n/g, '\n');
  const marker = 'export const UNREAD_COUNTS_SCRIPT: string =';
  const start = source.indexOf(marker);
  if (start < 0) {
    throw new Error(`UNREAD_COUNTS_SCRIPT not found in ${chrome}`);
  }
  const declaration = source.slice(source.indexOf('=', start) + 1);
  const end = declaration.indexOf("';\n");
  if (end < 0) {
    throw new Error('could not find the end of the UNREAD_COUNTS_SCRIPT literal');
  }
  const literal = declaration.slice(0, end + 1);
  // ArkTS string concatenation is JavaScript string concatenation, so this is
  // exactly the source the WebView receives.
  return eval(literal);
}

function element(options = {}) {
  return {
    getAttribute(name) {
      return options.attrs?.[name] ?? null;
    },
    textContent: options.text ?? '',
    querySelectorAll() {
      return options.kids ?? [];
    }
  };
}

function run(script, bySelector, title, window = {}) {
  const document = {
    title,
    querySelectorAll(selector) {
      return bySelector[selector] ?? [];
    }
  };
  return new Function('document', 'window', `return ${script}`)(document, window);
}

const NOTIFICATIONS = 'a[href="/notifications"],[data-testid="AppTabBar_Notifications_Link"]';
const MESSAGES = 'a[href="/messages"],a[href="/i/chat"],'
  + '[data-testid="AppTabBar_DirectMessage_Link"],[data-testid="AppTabBar_Messages_Link"]';

// "-1" is the load-bearing part of the contract: it means the page has not
// published that entry yet, and the shell must keep the count it already has
// rather than clearing the badge (which is what made badges drop out while
// moving between tabs).
const cases = [
  ['English accessible labels', {
    [NOTIFICATIONS]: [element({ attrs: { 'aria-label': 'Notifications (3 unread notifications)' }, text: 'Notifications' })],
    [MESSAGES]: [element({ attrs: { 'aria-label': 'Direct Messages (2 unread conversations)' }, text: 'Messages' })]
  }, '', '3/2'],
  ['Arabic-Indic digits', {
    [NOTIFICATIONS]: [element({ attrs: { 'aria-label': 'الإشعارات (٣ إشعارات غير مقروءة)' } })],
    [MESSAGES]: [element({ attrs: { 'aria-label': 'الرسائل المباشرة (١٢ محادثة غير مقروءة)' } })]
  }, '', '3/12'],
  ['counter drawn as its own badge node', {
    [NOTIFICATIONS]: [element({ attrs: { 'aria-label': 'Notifications' }, kids: [element({ text: '\n  4\n' })] })],
    [MESSAGES]: [element({ attrs: { 'aria-label': 'Messages' } })]
  }, '', '4/0'],
  ['entries present but nothing unread', {
    [NOTIFICATIONS]: [element({ attrs: { 'aria-label': 'Notifications' }, text: 'Notifications' })],
    [MESSAGES]: [element({ attrs: { 'aria-label': 'Messages' }, text: 'Messages' })]
  }, '', '0/0'],
  ['title prefix fills in for a missing notification entry', {
    [NOTIFICATIONS]: [], [MESSAGES]: [element({ attrs: { 'aria-label': 'Messages' } })]
  }, '(7) Home / X', '7/0'],
  ['mid-load: nothing published yet', { [NOTIFICATIONS]: [], [MESSAGES]: [] }, '', '-1/-1'],
  ['mid-load on a page with a stale title', { [NOTIFICATIONS]: [], [MESSAGES]: [] }, 'Home / X', '-1/-1'],
  ['signed out', { [NOTIFICATIONS]: [], [MESSAGES]: [] }, 'X. It’s what’s happening / X', '-1/-1'],
  ['labelled entry wins over an unlabelled one', {
    [NOTIFICATIONS]: [
      element({ attrs: { 'aria-label': 'Home (New unread posts)' }, text: 'Home' }),
      element({ attrs: { 'aria-label': 'Notifications (9 unread notifications)' }, text: 'Notifications' })
    ],
    [MESSAGES]: [element({ attrs: { 'aria-label': 'Messages' } })]
  }, '', '9/0']
];

const script = extractScript();
let failed = 0;
for (const [name, bySelector, title, expected] of cases) {
  let actual;
  try {
    actual = run(script, bySelector, title);
  } catch (err) {
    actual = `threw ${err.message}`;
  }
  const ok = actual === expected;
  if (!ok) {
    failed += 1;
  }
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}: got ${JSON.stringify(actual)}, want ${JSON.stringify(expected)}`);
}

// 使用只读实测的响应结构验证主路径，不在测试中发起网络请求。
const source = readFileSync(chrome, 'utf8');
const responseScript = eval(source.match(/export const UNREAD_RESPONSE_SCRIPT: string = (`[\s\S]*?`);/)[1]);
let sent = 0, warnings = 0;
class Request {
  listeners = [];
  status = 200;
  responseType = '';
  responseURL = 'https://x.com/i/api/graphql/current/ViewerBadgeCounts';
  addEventListener(name, callback, options) {
    assert.equal(name, 'load'); assert.equal(options.once, true);
    this.listeners.push(callback);
  }
  send() { sent++; return 'original-result'; }
  complete() { for (const callback of this.listeners.splice(0)) callback.call(this); }
}
const window = {}; window.top = window;
const runtime = { window, XMLHttpRequest: Request, URL, Date, console: {warn(){warnings++;}} };
vm.runInNewContext(responseScript, runtime);
vm.runInNewContext(responseScript, runtime);
const response = (n, m) => ({data:{viewer_v2:{user_results:{result:{__typename:'User',badge_counts:{
  ntab_unread_count:n,xchat_unread_count:m,dm_unread_count:99,total_unread_count:105,is_from_urt:true
}}}}}});
let request = new Request(); request.responseText = JSON.stringify(response(4, 2));
assert.equal(request.send(), 'original-result'); request.complete();
assert.equal(sent, 1); assert.equal(run(script, {}, '', window), '4/2');
assert.equal(warnings, 0);
// 返回零必须覆盖旧值，旧账号的在途结果不得回写。
request = new Request(); request.responseType = 'json'; request.response = response(0, 0);
request.send(); request.complete(); assert.equal(run(script, {}, '', window), '0/0');
request = new Request(); request.responseText = JSON.stringify(response(9, 9)); request.send();
window.__otBadgeEpoch++; window.__otBadgeCounts = null; request.complete();
assert.equal(run(script, {}, '', window), '-1/-1');
for (const [url, status] of [['https://other.example/i/api/graphql/current/ViewerBadgeCounts',200],
  ['https://x.com/i/api/graphql/current/OtherOperation',200],
  ['https://x.com/i/api/graphql/current/ViewerBadgeCounts',500]]) {
  request = new Request(); request.responseURL = url; request.status = status;
  request.responseText = JSON.stringify(response(8, 8)); request.send(); request.complete();
  assert.equal(window.__otBadgeCounts, null);
}
for (const body of ['invalid', JSON.stringify(response(-1, 1)), JSON.stringify(response(1, '2'))]) {
  request = new Request(); request.responseText = body; request.send(); request.complete();
  assert.equal(window.__otBadgeCounts, null);
}
assert.equal(warnings, 3);
window.__otBadgeCounts = {notifications:5,messages:2,time:Date.now()-60001};
assert.equal(run(script, {[NOTIFICATIONS]:[element({text:'',attrs:{'aria-label':'Notifications (3 unread)'}})]}, '', window), '3/-1');
console.log('Passive XHR counts, account changes, response boundaries and stale response fallback passed.');

// Run the production session against platform doubles; page DOM checks above remain independent.
const unreadSource = readFileSync(unreadSessionPath, 'utf8')
  .replace(/^import .*;\r?\n/gm, '')
  .replace(/^@Observed\r?\n/m, '')
  .replace(/^export /gm, '');
const decodeSource = readFileSync(chrome, 'utf8')
  .match(/export function unquoteScriptResult[\s\S]*?^}/m)[0]
  .replace('export ', '');
const unquoteScriptResult = vm.runInNewContext(stripTypeScriptTypes(decodeSource) + ';unquoteScriptResult');
let nextTimer = 0;
const intervals = new Map();
const timeouts = new Map();
const unreadRuntime = {
  UNREAD_COUNTS_SCRIPT: 'badge-counts', unquoteScriptResult, Date, Promise,
  setInterval(callback) { const id = ++nextTimer; intervals.set(id, callback); return id; },
  clearInterval(id) { intervals.delete(id); },
  setTimeout(callback) { const id = ++nextTimer; timeouts.set(id, callback); return id; },
  clearTimeout(id) { timeouts.delete(id); },
  notificationManager: { async setBadgeNumber() {}, isNotificationEnabledSync: () => true },
  hilog: { debug() {}, info() {}, warn() {} }, DOMAIN: 1, TAG: 'test'
};
const UnreadSession = vm.runInNewContext(
  stripTypeScriptTypes(unreadSource) + ';UnreadSession', unreadRuntime);
let owner = 'alice';
let pageUrl = 'https://x.com/home';
let runJavaScript = async () => '"4/2"';
const session = new UnreadSession({
  controller: () => ({ runJavaScript }), owner: () => owner, url: () => pageUrl,
  isRawWeb: () => false, getUIContext: () => ({}), putPreference: async () => {}
});
const settle = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };
session.activate(false);
session.refreshBadges();
await settle();
assert.equal(session.unreadNotifications, 4);
assert.equal(session.unreadMessages, 2);

runJavaScript = async () => '"-1/3"';
session.refreshBadges();
await settle();
assert.equal(session.unreadNotifications, 4, 'unpublished notification count must retain the previous badge');
assert.equal(session.unreadMessages, 3);
assert.equal(timeouts.size, 1, 'partial counts schedule a bounded reread');

session.armBadgeRefresh();
let finishRead;
runJavaScript = () => new Promise(resolve => { finishRead = resolve; });
session.refreshBadges();
session.setBackground(true);
assert.equal(intervals.size, 0, 'backgrounding clears the periodic badge timer');
assert.equal(timeouts.size, 0, 'backgrounding clears the retry timer');
finishRead('"9/9"');
await settle();
assert.equal(session.unreadNotifications, 4, 'a read finishing in background cannot replace the badge');
assert.equal(session.unreadMessages, 3);

session.setBackground(false);
runJavaScript = async () => '"-1/-1"';
session.refreshBadges();
await settle();
assert.equal(timeouts.size, 1, 'an unpublished count schedules a retry before disposal');
let finishDisposedRead;
runJavaScript = () => new Promise(resolve => { finishDisposedRead = resolve; });
session.refreshBadges();
session.dispose();
assert.equal(intervals.size, 0, 'disposing clears the periodic badge timer');
assert.equal(timeouts.size, 0, 'disposing clears the pending retry timer');
finishDisposedRead('"8/8"');
await settle();
assert.equal(session.unreadNotifications, 4, 'a read finishing after disposal cannot replace the badge');
assert.equal(session.unreadMessages, 3);
console.log('UnreadSession production flow and lifecycle checks passed.');
console.log(failed === 0 ? '\nall cases passed' : `\n${failed} case(s) failed`);
process.exit(failed === 0 ? 0 : 1);
