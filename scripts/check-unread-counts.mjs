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

// 未读结构沿用本地已有证据；账号与发布回执使用协议夹具，不代表真实账号验收。
const source = readFileSync(chrome, 'utf8');
const responseSource = readFileSync(join(here, '..', 'entry', 'src', 'main', 'ets', 'common', 'WebResponses.ets'), 'utf8');
const responseScript = eval(responseSource.match(/export const WEB_RESPONSE_SCRIPT: string = (`[\s\S]*?`);/)[1]);
const ownHandleScript = eval(source.match(/export const OWN_HANDLE_SCRIPT: string = (`[\s\S]*?`);/)[1]);
const clickPostButtonScript = vm.runInNewContext(stripTypeScriptTypes(source
  .match(/export function clickPostButtonScript[\s\S]*?^}\r?$/m)[0].replace('export ', '')) + ';clickPostButtonScript');
function browser(cookie = 'twid=u%3D42') {
  const stats = {sent:0,warnings:[],fetches:[],pageReads:0,clones:0};
  class Request {
    listeners = [];
    status = 200;
    responseType = '';
    open(method, url) { this.responseURL = new URL(url, 'https://x.com').href; return 'opened'; }
    addEventListener(name, callback, options) {
      assert.equal(name, 'loadend'); assert.equal(options.once, true);
      this.listeners.push(callback);
    }
    send() { stats.sent++; return 'original-result'; }
    complete(data) {
      if (this.responseType === 'json') this.response = data;
      else this.responseText = typeof data === 'string' ? data : JSON.stringify(data);
      for (const callback of this.listeners.splice(0)) callback.call(this);
    }
  }
  const document = {cookie,querySelectorAll:()=>[]};
  const window = {fetch(...args) { return new Promise((resolve,reject)=>stats.fetches.push({args,resolve,reject})); }};
  window.top = window;
  const context = vm.createContext({window,document,XMLHttpRequest:Request,URL,Date,
    location:{href:'https://x.com/home'},console:{warn:message=>stats.warnings.push(message)}});
  vm.runInContext(responseScript, context);
  vm.runInContext(responseScript, context);
  function xhr(op = 'ViewerBadgeCounts', method = op === 'CreateTweet' ? 'POST' : 'GET') {
    const request = new Request();
    assert.equal(request.open(method, '/i/api/graphql/current/' + op), 'opened');
    assert.equal(request.send(), 'original-result');
    return request;
  }
  function reply(index, data, options = {}) {
    const response = {ok:true,url:'https://x.com/i/api/graphql/current/ViewerBadgeCounts',
      json(){stats.pageReads++;return Promise.resolve(data);},
      clone(){stats.clones++;return {json:()=>options.body||Promise.resolve(data)};},...options};
    stats.fetches[index].resolve(response);
    return response;
  }
  return {stats,document,window,context,xhr,reply,Request};
}
const settleResponses = async () => { for(let i=0;i<8;i++)await Promise.resolve(); };
const b = browser(), window = b.window;
const response = (n, m) => ({data:{viewer_v2:{user_results:{result:{__typename:'User',badge_counts:{
  ntab_unread_count:n,xchat_unread_count:m,dm_unread_count:99,total_unread_count:105,is_from_urt:true
}}}}}});
let request = b.xhr(); request.complete(response(4, 2));
assert.equal(b.stats.sent, 1); assert.equal(run(script, {}, '', window), '4/2');
assert.equal(b.stats.warnings.length, 0);
// 返回零必须覆盖旧值，旧账号的在途结果不得回写。
request = b.xhr(); request.responseType = 'json'; request.complete(response(0, 0));
assert.equal(run(script, {}, '', window), '0/0');
request = b.xhr(); window.__otBadgeEpoch++; window.__otBadgeCounts = null; request.complete(response(9, 9));
assert.equal(run(script, {}, '', window), '-1/-1');
for (const [url, status] of [['https://other.example/i/api/graphql/current/ViewerBadgeCounts',200],
  ['https://x.com/i/api/graphql/current/OtherOperation',200],
  ['https://x.com/i/api/graphql/current/ViewerBadgeCounts',500]]) {
  request = new b.Request(); request.open('GET',url);request.status = status;
  request.send(); request.complete(response(8, 8));
  assert.equal(window.__otBadgeCounts, null);
}
for (const body of ['invalid', JSON.stringify(response(-1, 1)), JSON.stringify(response(1, '2'))]) {
  request = b.xhr(); request.complete(body);
  assert.equal(window.__otBadgeCounts, null);
}
assert.equal(b.stats.warnings.length, 3);
window.__otBadgeCounts = {notifications:5,messages:2,time:Date.now()-60001};
assert.equal(run(script, {[NOTIFICATIONS]:[element({text:'',attrs:{'aria-label':'Notifications (3 unread)'}})]}, '', window), '3/-1');
const newer = b.xhr(); request = b.xhr(); request.complete(response(2,1));newer.complete(response(9,9));
assert.equal(run(script, {}, '', window),'2/1','旧请求后返回也不能覆盖新计数');
// XHR 复用时，已取消请求的监听不能把新响应当成旧请求结果。
request = b.xhr(); request.open('GET','/unrelated');request.send();request.complete(response(8,8));
assert.equal(run(script, {}, '', window),'2/1');

const olderFetch = window.fetch('/i/api/graphql/current/ViewerBadgeCounts');
const newerFetch = window.fetch({url:'https://x.com/i/api/graphql/current/ViewerBadgeCounts',method:'GET'});
const freshResponse = b.reply(1,response(6,3));assert.equal(await newerFetch,freshResponse);
await settleResponses();b.reply(0,response(8,8));await olderFetch;await settleResponses();
assert.equal(run(script, {}, '', window),'6/3');
assert.equal(b.stats.pageReads,0,'旁路解析不能消费页面响应正文');
assert.deepEqual(await freshResponse.json(),response(6,3));assert.equal(b.stats.pageReads,1);
const failure = Error('offline'), failedFetch = window.fetch('/unrelated');
b.stats.fetches[2].reject(failure);await assert.rejects(failedFetch,error=>error===failure);
const malformed = window.fetch('/i/api/graphql/current/ViewerBadgeCounts');
const malformedResponse = b.reply(3,null,{body:Promise.reject(Error('invalid JSON'))});
assert.equal(await malformed,malformedResponse);await settleResponses();
assert.equal(run(script, {}, '', window),'6/3');assert.equal(b.stats.warnings.length,4);
const badClone = window.fetch('/i/api/graphql/current/ViewerBadgeCounts');
const unclonable = b.reply(4,null,{clone(){throw Error('used body');}});
assert.equal(await badClone,unclonable);assert.equal(b.stats.warnings.length,5);

const user = (id,handle) => ({__typename:'User',rest_id:id,core:{screen_name:handle}});
const initialAccount = (id,entities) => ({session:{user_id:id},entities:{users:{entities}}});
const initialized=browser();
initialized.window.__INITIAL_STATE__=initialAccount('42',{'42':{screen_name:'Alice'},'7':{screen_name:'Bob'}});
assert.equal(vm.runInContext(ownHandleScript,initialized.context),'Alice','没有资料链接和本人帖子时，从当前会话的初始化实体读取账号');
assert.equal(initialized.stats.sent,0);assert.equal(initialized.stats.fetches.length,0,'账号读取不发起额外请求');
initialized.xhr('HomeTimeline').complete({data:{}});
assert.equal(initialized.window.__otReadAccount(),'Alice');
initialized.xhr('HomeTimeline').complete({data:user('42','Renamed')});
assert.equal(initialized.window.__otReadAccount(),'Renamed','新响应优先于文档初始化时的旧账号名');
initialized.document.cookie='twid=u%3D7';
assert.equal(vm.runInContext(ownHandleScript,initialized.context),'','切换账号后不能使用旧会话或其他缓存实体');
initialized.window.__INITIAL_STATE__=initialAccount('7',{'7':{screen_name:'Bob'}});
assert.equal(initialized.window.__otReadAccount(),'Bob');
for(const initial of [undefined,{},initialAccount('7',{'42':{screen_name:'Alice'}}),
  initialAccount('42',{}),initialAccount('42',{'42':{screen_name:'invalid-handle'}})]){
  const missing=browser();missing.window.__INITIAL_STATE__=initial;
  assert.equal(vm.runInContext(ownHandleScript,missing.context),'','缺失、账号不符或无效实体不能作为本人账号');
}
for(const cookie of ['','twid=invalid','twid=%E0%A4%A']){
  const missing=browser(cookie);missing.window.__INITIAL_STATE__=initialAccount('42',{'42':{screen_name:'Alice'}});
  assert.equal(vm.runInContext(ownHandleScript,missing.context),'','不可读的当前会话不能凭初始化实体确认账号');
}
const timeline = (...users) => ({data:{home:{home_timeline_urt:{instructions:users.map(author=>({
  entries:[{content:{itemContent:{tweet_results:{result:{core:{user_results:{result:author}}}}}}}]
}))}}}});
request = b.xhr('HomeTimeline');request.complete(timeline(user('7','other'),user('42','Alice')));
assert.equal(vm.runInContext(ownHandleScript,b.context),'Alice','只使用与 twid 对应的用户对象');
const oldIdentity = b.xhr('HomeTimeline');
request = b.xhr('HomeLatestTimeline');request.complete(timeline({__typename:'User',rest_id:'42',legacy:{screen_name:'Renamed'}}));
oldIdentity.complete(timeline(user('42','Alice')));assert.equal(window.__otReadAccount(),'Renamed');
request=b.xhr('HomeTimeline');b.document.cookie='twid=u%3D7';
assert.equal(window.__otReadAccount(),'');assert.equal(window.__otBadgeCounts,null);
request.complete(timeline(user('42','Alice')));assert.equal(window.__otReadAccount(),'');
request=b.xhr('HomeTimeline');request.complete(timeline(user('42','Alice'),user('7','Bob')));
assert.equal(window.__otReadAccount(),'Bob');
const anonymous=browser('');anonymous.xhr('HomeTimeline').complete(timeline(user('42','Alice')));
assert.equal(anonymous.window.__otReadAccount(),'','没有可读账号 ID 时不能从时间线作者猜测当前账号');

const receipt = (author = user('42','Alice'),id='123') => ({data:{create_tweet:{tweet_results:{result:{
  __typename:'Tweet',rest_id:id,core:{user_results:{result:author}}
}}}}});
const posted=browser();let postRequest,expirePost;
posted.context.setTimeout=callback=>{expirePost=callback;};
posted.document.querySelector=()=>({disabled:false,getAttribute:()=>null,click(){postRequest=posted.xhr('CreateTweet');}});
assert.equal(vm.runInContext(clickPostButtonScript('alice'),posted.context),'submitted');
assert.equal(vm.runInContext(clickPostButtonScript('alice'),posted.context),'unknown');
postRequest.complete(receipt());assert.equal(posted.window.__otReadPost(),'confirmed');
expirePost();assert.equal(posted.window.__otReadPost(),'confirmed');
for(const body of [{errors:[{code:1}],...receipt()},receipt(user('7','Bob')),receipt(user('7','Alice')),
  receipt(user('42','Alice'),''),{data:{create_tweet:{}}}]){
  const rejected=browser();rejected.window.__otBeginPost('alice');rejected.xhr('CreateTweet').complete(body);
  assert.notEqual(rejected.window.__otReadPost(),'confirmed','无有效回执或账号不符时必须保留待核对状态');
  assert.equal(rejected.stats.warnings.length,1);
}
const unarmed=browser(),inflight=unarmed.xhr('CreateTweet');
unarmed.window.__otBeginPost('alice');inflight.complete(receipt());
assert.notEqual(unarmed.window.__otReadPost(),'confirmed','提交前已有请求不能确认本次发布');
const first=unarmed.xhr('CreateTweet'),second=unarmed.xhr('CreateTweet');
second.complete(receipt());assert.notEqual(unarmed.window.__otReadPost(),'confirmed');
first.complete(receipt());assert.equal(unarmed.window.__otReadPost(),'confirmed');
const switched=browser();switched.window.__otBeginPost('alice');request=switched.xhr('CreateTweet');
switched.document.cookie='twid=u%3D7';switched.window.__otReadAccount();
switched.document.cookie='twid=u%3D42';request.complete(receipt());
assert.equal(switched.window.__otReadPost(),'unknown','切回相同账号也不能接收已失效的旧发布回执');
const fetchPost=browser();fetchPost.window.__otBeginPost('alice');
const sentPost=fetchPost.window.fetch('/i/api/graphql/current/CreateTweet',{method:'POST'});
fetchPost.reply(0,receipt(),{url:'https://x.com/i/api/graphql/current/CreateTweet'});
await sentPost;await settleResponses();assert.equal(fetchPost.window.__otReadPost(),'confirmed');
const mainSource=readFileSync(join(here,'..','entry','src','main','ets','pages','MainTabs.ets'),'utf8');
assert.match(mainSource.slice(mainSource.indexOf('Web({ src: this.composer.composeUrl')),
  /javaScriptOnDocumentStart\(\[\{ script: WEB_RESPONSE_SCRIPT/,'发帖文档必须在网页请求前安装监听');
console.log('Passive XHR/fetch, response ownership, order, body preservation and post receipt checks passed.');

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
  webScript: async script => runJavaScript(script), isControllerReady: () => true, owner: () => owner, url: () => pageUrl,
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
