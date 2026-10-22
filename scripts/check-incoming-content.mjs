import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';

const source = readFileSync(new URL('../entry/src/main/ets/common/IncomingContent.ets', import.meta.url), 'utf8');
const context = {
  url: { URL: { parseURL(value) { const parsed = new URL(value); parsed.params = parsed.searchParams; return parsed; } } }
};
const api = vm.runInNewContext(stripTypeScriptTypes(source.replace(/^import .*;\r?\n/gm, ''))
  .replace(/^export /gm, '') + ';({incomingLink,incomingShare})', context);
for (const [input, expected] of [
  ['twitter://status?id=1234567890123456789', 'https://x.com/i/web/status/1234567890123456789'],
  ['twitter://user?screen_name=Alice_1', 'https://x.com/Alice_1'],
  ['crux://status?id=123', 'https://x.com/i/web/status/123'],
  ['https://twitter.com/alice/status/123?ref=share', 'https://twitter.com/alice/status/123?ref=share']
]) {
  assert.equal(api.incomingLink(input).value, expected);
}
for (const input of ['https://x.com.evil.test/a', 'https://x.com@evil.test/a', 'https://user@x.com/a',
  'http://x.com/a', 'javascript:alert(1)', 'twitter://status?id=NaN', 'twitter://user?screen_name=a/b',
  'twitter://unknown', 'twitter://status/other?id=123', 'https://x.com:123/a']) {
  assert.throws(() => api.incomingLink(input), input);
}
assert.equal(api.incomingShare([{utd:'general.hyperlink',content:'https://x.com/alice'}]).kind,'link');
assert.equal(api.incomingShare([{utd:'general.plain-text',content:' https://x.com/alice\n'}]).kind,'link');
for (const value of ['https://example.com/article','分享标题\nhttps://x.com/alice','普通文字 😀']) {
  const result = api.incomingShare([{utd:'general.plain-text',content:value}]);
  assert.equal(result.kind,'compose'); assert.equal(result.value,value);
}
assert.equal(api.incomingShare([{utd:'general.text',content:'文字'},{utd:'general.hyperlink',content:'https://x.com/alice'}]).value,
  '文字\nhttps://x.com/alice');
for (const records of [[],[{utd:'general.image',uri:'file://image'}],[{utd:'general.plain-text',content:''}],
  [{utd:'general.hyperlink'}],[{utd:'general.text',content:'text'},{utd:'general.image',uri:'file://image'}]]) {
  assert.throws(() => api.incomingShare(records));
}

// 执行真实 Ability 入口，验证冷启动和再次唤起，以及异步分享不会覆盖待处理请求。
const abilitySource = readFileSync(new URL('../entry/src/main/ets/entryability/EntryAbility.ets',import.meta.url),'utf8')
  .replace(/^import .*;\r?\n/gm,'').replace('export default class','class');
const storage = new Map();
let resolveShare;
let initializeCount=0;
const ability = vm.runInNewContext(stripTypeScriptTypes(abilitySource)+';new EntryAbility()',{
  ...api, UIAbility:class {context={applicationInfo:{debug:false}}},
  hilog:{info(){},warn(){},error(){}},
  AppStorage:{get:key=>storage.get(key),setOrCreate:(key,value)=>storage.set(key,value)},
  web_webview:{WebviewController:{initializeWebEngine(){initializeCount++;}}},
  NetworkConfig:{getInstance:()=>({initialize(){}})},
  systemShare:{getSharedData:()=>new Promise(resolve=>{resolveShare=resolve;})}
});
for (const want of [{}, {uri:''}, {uri:' \n '}, {action:'ohos.want.action.home',uri:''}]) {
  await ability.handleIncomingWant(want);
  assert.equal(storage.size,0,'普通启动不产生分享内容或错误');
}
ability.onCreate({action:'ohos.want.action.viewData',uri:'twitter://status?id=42'},{});
assert.equal(initializeCount,1);
assert.equal(storage.get('incomingContent').value,'https://x.com/i/web/status/42');
ability.onNewWant({action:'ohos.want.action.viewData',uri:'twitter://status?id=43'},{});
assert.equal(storage.get('incomingContent').value,'https://x.com/i/web/status/42');
assert.equal(storage.get('incomingError'),1);
storage.set('incomingContent',{kind:'',value:''});
ability.onNewWant({action:'ohos.want.action.sendData'},{});
ability.onNewWant({action:'ohos.want.action.viewData',uri:'twitter://status?id=44'},{});
assert.equal(storage.get('incomingError'),2);
resolveShare({getRecords:()=>[{utd:'general.text',content:'待发布内容'}]});
await new Promise(resolve=>setImmediate(resolve));
assert.equal(storage.get('incomingContent').value,'待发布内容');
assert.equal(ability.receivingContent,false);
storage.set('incomingContent',{kind:'',value:''});
ability.onNewWant({action:'ohos.want.action.viewData',uri:'https://evil.test'},{});
assert.equal(storage.get('incomingContent').kind,'');
assert.equal(storage.get('incomingError'),3);
ability.onNewWant({uri:'crux://user?screen_name=alice'},{});
assert.equal(storage.get('incomingContent').value,'https://x.com/alice');

// 模态界面不被外部请求打断；冷启动文字只在网页就绪后交给编辑器。
const main = readFileSync(new URL('../entry/src/main/ets/pages/MainTabs.ets',import.meta.url),'utf8');
const consumeBody=main.match(/private onIncomingContentChanged\(\): void \{([\s\S]*?)\n  \}/)[1];
const consume=vm.runInNewContext(stripTypeScriptTypes('(function(){'+consumeBody+'})'),{
  $r:key=>key, hilog:{error(){}},DOMAIN:0,TAG:'test'
});
const opened=[],notices=[];
const state={incomingContent:{kind:'compose',value:'文字'},incomingControllerReady:false,incomingPageReady:false,
  modalBlocksNetworkReload:()=>false,fullScreen:false,
  composer:{openingCompose:false,openCompose:value=>opened.push(value)},toast:value=>notices.push(value),
  navigation:{loadWeb(value,keepProfile,allowDocumentLoad){assert.equal(keepProfile,false);assert.equal(allowDocumentLoad,true);opened.push(value);}},
  controller:{loadUrl(){throw Error('必须先尝试页内导航');}}};
consume.call(state);assert.equal(state.incomingContent.value,'文字');
state.incomingControllerReady=true;consume.call(state);assert.equal(opened.length,0);
state.incomingPageReady=true;consume.call(state);assert.deepEqual(opened,['文字']);
consume.call(state);assert.equal(opened.length,1);
state.incomingContent={kind:'link',value:'https://x.com/alice'};state.modalBlocksNetworkReload=()=>true;
consume.call(state);assert.equal(opened.length,1);assert.equal(notices.at(-1),'app.string.incoming_busy');
state.modalBlocksNetworkReload=()=>false;state.incomingPageReady=false;
state.incomingContent={kind:'link',value:'https://x.com/alice'};
consume.call(state);assert.equal(state.incomingContent.kind,'link','冷启动链接等待网页路由就绪');
state.incomingPageReady=true;consume.call(state);assert.equal(opened.at(-1),'https://x.com/alice');

const sessionSource=readFileSync(new URL('../entry/src/main/ets/common/ComposerSession.ets',import.meta.url),'utf8');
const composeBody=sessionSource.match(/async openCompose\(sharedText: string = ''\): Promise<void> \{([\s\S]*?)\n  \}/)[1];
let existingDraft='',uncertain=false,dialog,saved=[];
const compose=vm.runInNewContext(stripTypeScriptTypes('(async function(sharedText){'+composeBody+'})'),{
  $r:key=>key,hilog:{error(){}},DOMAIN:0,TAG:'test',TWITTER_COMPOSE:'https://x.com/compose/post',
  PREFS_NAME:'test',COMPOSE_DRAFT_KEY:'draft',web_webview:{WebviewController:class{}},
  preferences:{getPreferences:async()=>({get:async key=>key.startsWith('post_pending:')?uncertain:
    key.startsWith('compose_handoff:')?'':existingDraft})}
});
const composerState=()=>({openingCompose:false,sheetOpen:false,legacyDraft:'',host:{confirmCurrentAccount:async()=>'alice',
  getUIContext:()=>({getHostContext:()=>({}),showAlertDialog:value=>{dialog=value;}}),
  acceptHandle(){},toast:value=>notices.push(value)},clearComposeSync(){},scheduleComposeSync(){},
  async persistDraft(){saved.push(this.draft);},saveDraft(){saved.push(this.draft);}});
let composer=composerState();await compose.call(composer,'外部文字');
assert.equal(composer.draft,'外部文字');assert.deepEqual(saved,['外部文字']);
existingDraft='旧草稿';saved=[];composer=composerState();await compose.call(composer,'新分享');
assert.equal(composer.draft,'旧草稿');assert.equal(saved.length,0);
dialog.primaryButton.action();assert.equal(composer.draft,'旧草稿');
dialog.secondaryButton.action();assert.equal(composer.draft,'旧草稿\n新分享');
uncertain=true;dialog=undefined;composer=composerState();await compose.call(composer,'新分享');
assert.equal(composer.draft,'旧草稿');assert.equal(dialog,undefined);
assert.equal(notices.at(-1),'app.string.incoming_busy');

const manifest=JSON.parse(readFileSync(new URL('../entry/src/main/module.json5',import.meta.url),'utf8')
  .replace(/^\s*\/\/.*$/gm,''));
const skills=manifest.module.abilities[0].skills;
assert.equal(skills.length,4);
assert.equal(skills[1].actions[0],'ohos.want.action.sendData');
assert.ok(skills[1].uris.every(uri=>uri.scheme==='file'&&uri.maxFileSupported===1));
assert.equal(skills[3].domainVerify,false);
assert.ok(skills[3].uris.every(uri=>uri.scheme==='https'&&!('domainVerify' in uri)));
console.log('PASS: incoming links, share routing, cold/warm Want handling, pending requests and modal boundaries');
