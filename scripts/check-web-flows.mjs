import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';

function load(name, exports) {
  const path = new URL('../entry/src/main/ets/common/' + name + '.ets', import.meta.url);
  const source = readFileSync(path, 'utf8').replace(/^import .*;\r?\n/gm, '');
  const js = stripTypeScriptTypes(source).replace(/^export /gm, '');
  return vm.runInNewContext(js + ';({' + exports.join(',') + '})');
}
const routes = load('WebConfig', ['routeIndexForUrl', 'profileHandleForUrl']);
for (const [path, expected] of [['/home',0],['/search?q=a',1],['/notifications',2],['/messages/42',3],['/i/chat',3],['/someone',4],['/i/flow/login',-1],['/settings',-1],['/someone/status/123',-1]]) {
  assert.equal(routes.routeIndexForUrl('https://x.com' + path), expected, path);
}
assert.equal(routes.routeIndexForUrl('https://example.com/home'), -1);
assert.equal(routes.profileHandleForUrl('https://x.com/settings'), '');
assert.equal(routes.profileHandleForUrl('https://x.com.evil.test/alice'), '');
const scripts = load('WebChrome', ['fillComposerScript','CLICK_POST_BUTTON_SCRIPT','POST_RESULT_SCRIPT','chromeScript']);
// 测试真实注入串，避免只测试一份复制的实现。
for (const value of ['中文\n第二段😀 https://x.com', '  两侧空格  ', 'a\r\nb']) {
  let text = '';
  const editor = { focus(){}, get innerText(){ return text; }, get textContent(){ return text; } };
  const context = {document:{querySelector:()=>editor,execCommand:(_command,_ui,value)=>{text=value;return true;}}};
  assert.equal(vm.runInNewContext(scripts.fillComposerScript(value),context),'ok');
}
assert.equal(vm.runInNewContext(scripts.fillComposerScript('12345678完整正文'),{
  document:{querySelector:()=>({focus(){},innerText:'12345678截断'}),execCommand:()=>true}
}),'mismatch');
assert.equal(vm.runInNewContext(scripts.fillComposerScript('内容'),{document:{querySelector:()=>null}}),'missing');
new vm.Script(scripts.chromeScript('alice',true,140));
// 相同 DOM 不能因重复设置样式而持续触发自身观察器。
let cssWrites=0, cssText='', authVisible=false;
const style={get textContent(){return cssText;},set textContent(value){cssText=value;cssWrites++;}};
const location={pathname:'/home',href:'https://x.com/home'};
const chromeContext={window:{location,addEventListener(){},otNative:{onUrlChange(){}}},location,
  history:{pushState(){},replaceState(){}},
  document:{documentElement:{},getElementById:()=>style,
    querySelector:()=>authVisible?{}:null,
    querySelectorAll:()=>[{getAttribute:name=>name==='data-testid'?'AppTabBar_Profile_Link':'/alice'}]},
  MutationObserver:class{observe(){}disconnect(){}},setTimeout(){},clearTimeout(){}};
vm.runInNewContext(scripts.chromeScript('alice',true,140),chromeContext);
const initialWrites=cssWrites;
chromeContext.window.__otApplyTop();assert.equal(cssWrites,initialWrites);
authVisible=true;chromeContext.window.__otApplyTop();assert.equal(cssText,'');

function posting({ disabled=false, missing=false, throws=false }={}) {
  let clicks=0; let observe; let timeout; let toasts=[];
  const button={disabled,getAttribute:()=>null,click(){clicks++;if(throws)throw Error('click');}};
  const window={addEventListener(){}};
  const context={window,document:{documentElement:{},querySelector:()=>missing?null:button,querySelectorAll:()=>toasts},
    MutationObserver:class{constructor(callback){observe=callback;}observe(){}disconnect(){}},setTimeout(callback){timeout=callback;}};
  return {run:()=>vm.runInNewContext(scripts.CLICK_POST_BUTTON_SCRIPT,context),window,
    count:()=>clicks,expire:()=>timeout(),toast(text,link=true){toasts=[{textContent:text,querySelector:()=>link?{}:null}];observe();}};
}
let p=posting();assert.equal(p.run(),'submitted');assert.equal(p.window.__otPostState,'submitted');
assert.equal(p.run(),'unknown');assert.equal(p.count(),1);
p.toast('Something went wrong',false);assert.equal(p.window.__otPostState,'submitted');
p.expire();assert.equal(p.window.__otPostState,'unknown');
p=posting();p.run();p.toast('Your post was sent.',false);assert.equal(p.window.__otPostState,'submitted');
p.toast('Your post was sent.',true);assert.equal(p.window.__otPostState,'confirmed');
p=posting({disabled:true});assert.equal(p.run(),'disabled');assert.equal(p.count(),0);
p=posting({missing:true});assert.equal(p.run(),'missing');assert.equal(p.count(),0);
p=posting({throws:true});assert.equal(p.run(),'unknown');assert.equal(p.count(),1);
const media=load('WebSystem',['mediaAcceptTypes','isSiteUrl','isAuthUrl']);
assert.deepEqual(Array.from(media.mediaAcceptTypes(['.jpg,image/png'])),['image/jpeg','image/png']);
assert.deepEqual(Array.from(media.mediaAcceptTypes(['application/pdf'])),[]);
assert.equal(media.isSiteUrl('https://x.com.evil.test/'),false);
assert.equal(media.isAuthUrl('https://accounts.google.com/o/oauth2/auth'),true);
console.log('PASS: route classification, full text transfer, submission results and file type boundaries');
