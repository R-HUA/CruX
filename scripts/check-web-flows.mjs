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
const routes = load('WebConfig', ['routeIndexForUrl', 'profileHandleForUrl','usesNativeNavigation','usesNativeHeader','isTabRootPath']);
for (const [path, expected] of [['/home',0],['/search?q=a',1],['/notifications',2],['/messages/42',3],['/i/chat',3],['/someone',4],['/i/flow/login',-1],['/settings',-1],['/someone/status/123',-1]]) {
  assert.equal(routes.routeIndexForUrl('https://x.com' + path), expected, path);
}
assert.equal(routes.routeIndexForUrl('https://example.com/home'), -1);
assert.equal(routes.profileHandleForUrl('https://x.com/settings'), '');
assert.equal(routes.profileHandleForUrl('https://x.com.evil.test/alice'), '');
for(const path of ['/home','/search?q=中文','/notifications','/messages/42','/i/chat','/alice','/alice/status/123']){
  assert.equal(routes.usesNativeNavigation('https://x.com'+path),true,path);
}
for(const path of ['/','/i/flow/login','/login','/settings','/settings/profile','/unknown/path']){
  assert.equal(routes.usesNativeNavigation('https://x.com'+path),false,path);
}
assert.equal(routes.usesNativeNavigation('https://example.com/home'),false);
assert.equal(routes.isTabRootPath('/search'),true);
for(const path of ['/explore','/search?q=中文','/i/flow/login','/alice']){
  assert.equal(routes.usesNativeHeader('https://x.com'+path),false,path);
}
assert.equal(routes.usesNativeHeader('https://x.com/home'),true);
const scripts = load('WebChrome', ['fillComposerScript','CLICK_POST_BUTTON_SCRIPT','POST_RESULT_SCRIPT','chromeScript','OWN_HANDLE_SCRIPT','profileBootstrapScript','clickRouteScript']);
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
new vm.Script(scripts.chromeScript(true,true));
// 当前移动网页资料入口是无 href 的按钮，原生导航不能依赖它返回账号名。
let profileClicks=0;
const profileLink={textContent:'Profile',getAttribute:name=>name==='href'?'/alice':null,
  click(){profileClicks++;menuOpen=false;}};
let menuOpen=false, ambiguous=false, clicks=0;
const profileButton={click(){menuOpen=!menuOpen;clicks++;}};
const dialog={textContent:'Profile',querySelector:()=>null,querySelectorAll:()=>ambiguous?
  [profileLink,{textContent:'Profile',getAttribute:name=>name==='href'?'/bob':null}]:[profileLink]};
const accountDocument={
  querySelectorAll:selector=>selector==='[role="dialog"]'?(menuOpen?[dialog]:[]):
    selector==='[role=dialog] a[href]'&&menuOpen?[profileLink]:[],
  querySelector:selector=>selector==='[role=dialog]'?(menuOpen?dialog:null):profileButton
};
assert.equal(vm.runInNewContext(scripts.OWN_HANDLE_SCRIPT,{document:accountDocument}),'');
const accountContext={window:{},document:accountDocument,setTimeout:callback=>callback()};
assert.equal(vm.runInNewContext(scripts.profileBootstrapScript(false),accountContext),'armed');
assert.equal(accountContext.window.__otBoot,'alice');assert.equal(menuOpen,false);assert.equal(clicks,2);
menuOpen=true;assert.equal(vm.runInNewContext(scripts.OWN_HANDLE_SCRIPT,{document:accountDocument}),'alice');
ambiguous=true;dialog.textContent='@alice @bob';
assert.equal(vm.runInNewContext(scripts.OWN_HANDLE_SCRIPT,{document:accountDocument}),'');
ambiguous=false;menuOpen=false;
assert.equal(vm.runInNewContext(scripts.profileBootstrapScript(true),accountContext),'armed');
assert.equal(profileClicks,1);assert.equal(menuOpen,false);
let routeClicks=0;
const link={getAttribute:name=>name==='href'?'/i/chat':null,click(){routeClicks++;}};
const routeContext={URL,location:{href:'https://x.com/home'},document:{querySelectorAll:()=>[link]}};
assert.equal(vm.runInNewContext(scripts.clickRouteScript('https://x.com/i/chat'),routeContext),'clicked');
assert.equal(routeClicks,1);
assert.equal(vm.runInNewContext(scripts.clickRouteScript('https://x.com/search?q=a'),routeContext),'missing');
assert.equal(routeClicks,1);
// 相同 DOM 不能因重复设置样式而持续触发自身观察器。
let cssWrites=0, cssText='', authVisible=false;
const style={get textContent(){return cssText;},set textContent(value){cssText=value;cssWrites++;}};
const location={pathname:'/home',href:'https://x.com/home'};
const chromeContext={window:{location,addEventListener(){},otNative:{onUrlChange(){}}},location,
  history:{pushState(){},replaceState(){}},
  document:{documentElement:{},getElementById:()=>style,
    querySelector:()=>authVisible?{}:null,
    querySelectorAll:()=>[]},
  MutationObserver:class{observe(){}disconnect(){}},setTimeout(){},clearTimeout(){}};
vm.runInNewContext(scripts.chromeScript(true,true),chromeContext);
assert.match(cssText,/TopNavBar/);assert.match(cssText,/FloatingActionButtons_Tweet_Button/);
const initialWrites=cssWrites;
chromeContext.window.__otApplyTop();assert.equal(cssWrites,initialWrites);
authVisible=true;chromeContext.window.__otApplyTop();assert.equal(cssText,'');
// 搜索页必须保留网页输入框及候选列表，仍只去重底部导航和发帖入口。
authVisible=false;location.pathname='/search';location.href='https://x.com/search?q=中文';
vm.runInNewContext(scripts.chromeScript(true,false),chromeContext);
assert.doesNotMatch(cssText,/TopNavBar|role='banner'|tablist/);
assert.match(cssText,/FloatingActionButtons_Tweet_Button/);
authVisible=false;vm.runInNewContext(scripts.chromeScript(false,false),chromeContext);assert.equal(cssText,'');

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
