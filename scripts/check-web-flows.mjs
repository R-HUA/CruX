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
const routes = load('WebConfig', ['routeIndexForUrl', 'profileHandleForUrl','usesNativeNavigation','usesNativeHeader','isTabRootPath','isPostDetailUrl']);
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
assert.equal(routes.usesNativeHeader('https://x.com/alice/status/123'),true);
assert.equal(routes.isPostDetailUrl('https://x.com/alice/status/123?ref=home'),true);
for (const url of ['https://x.com/alice/status/123/photo/1','https://x.com/alice/status/123/mediaViewer','https://example.com/alice/status/123']) {
  assert.equal(routes.isPostDetailUrl(url),false,url);
}
const scripts = load('WebChrome', ['fillComposerScript','CLICK_POST_BUTTON_SCRIPT','POST_RESULT_SCRIPT','chromeScript','chromeFlagScript','chromeInsetsScript','chromeDocumentStartScript','OWN_HANDLE_SCRIPT','profileBootstrapScript','clickRouteScript','accountAvatarScript']);
assert.equal(scripts.chromeDocumentStartScript(false),'');
new vm.Script(scripts.chromeDocumentStartScript(true));
// 回复直接使用当前详情的帖子编号，原帖是否被虚拟列表回收不影响面板显示。
const mainSource=readFileSync(new URL('../entry/src/main/ets/pages/MainTabs.ets',import.meta.url),'utf8');
const insetBody=mainSource.match(/private overlayTopInset\(\): number \{([\s\S]*?)\n  \}/)[1];
const topInset=vm.runInNewContext(stripTypeScriptTypes('(function(){'+insetBody+'})'),{
  HEADER_HEIGHT:56,HEADER_CONTENT_LIFT:4
});
const insetState={topInset:39,homeTabsHeight:28,overlaysWeb:()=>true,topChromeHeight:()=>56,isHomeRoot:()=>true};
assert.equal(topInset.call(insetState),77,'Home inset ends at the measured underline, not the full title bar');
insetState.homeTabsHeight=40;assert.equal(topInset.call(insetState),83,'Large text changes the measured boundary');
insetState.isHomeRoot=()=>false;assert.equal(topInset.call(insetState),95);
insetState.topChromeHeight=()=>0;assert.equal(topInset.call(insetState),0);
insetState.overlaysWeb=()=>false;assert.equal(topInset.call(insetState),0);
const replyMethod=mainSource.match(/private replyToPost\(\): void \{([\s\S]*?)\n  \}/)[1];
const reply=vm.runInNewContext(stripTypeScriptTypes('(function(){'+replyMethod+'})'),{
  TWITTER_BASE:'https://x.com',web_webview:{WebviewController:class{}}
});
const replyState={openingCompose:false,sheetOpen:false,currentPath:'/alice/status/123',composeOwner:'alice'};
reply.call(replyState);
assert.equal(replyState.sheetOpen,true);
assert.equal(replyState.composeUrl,'https://x.com/intent/tweet?in_reply_to=123');
assert.equal(replyState.webComposer,true);assert.equal(replyState.composeLoading,true);
assert.equal(replyState.composeOwner,'');
const replyController=replyState.composeController;
reply.call(replyState);assert.equal(replyState.composeController,replyController);
// 测试真实注入串，避免只测试一份复制的实现。
for (const value of ['中文\n第二段😀 https://x.com', '  两侧空格  ', 'a\r\nb']) {
  let text = '';
  const editor = { focus(){}, get innerText(){ return text; }, get textContent(){ return text; } };
  const wrapper={textContent:'外层容器'};
  const context = {document:{querySelector:selector=>selector==='[data-testid="tweetTextarea_0"][contenteditable="true"]'?editor:wrapper,
    execCommand:(_command,_ui,value)=>{text=value;return true;}}};
  assert.equal(vm.runInNewContext(scripts.fillComposerScript(value),context),'ok');
  assert.equal(wrapper.textContent,'外层容器');
}
assert.equal(vm.runInNewContext(scripts.fillComposerScript('12345678完整正文'),{
  document:{querySelector:()=>({focus(){},innerText:'12345678截断'}),execCommand:()=>true}
}),'mismatch');
assert.equal(vm.runInNewContext(scripts.fillComposerScript('内容'),{document:{querySelector:()=>null}}),'missing');
const failedEditor={focus(){},textContent:'原正文'};
assert.equal(vm.runInNewContext(scripts.fillComposerScript('内容'),{
  document:{querySelector:()=>failedEditor,execCommand:()=>false}
}),'error');
assert.equal(failedEditor.textContent,'原正文');
new vm.Script(scripts.chromeScript(true,true,'https://x.com/home'));
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
let chromeNotifications=0,observedOptions;
const chromeContext={window:{location,addEventListener(){},otNative:{onUrlChange(){chromeNotifications++;}}},location,
  history:{pushState(){},replaceState(){}},
  document:{documentElement:{},getElementById:()=>style,
    querySelector:()=>authVisible?{}:null,
    querySelectorAll:()=>[]},
  MutationObserver:class{observe(_root,options){observedOptions=options;}disconnect(){}},setTimeout(){},clearTimeout(){}};
vm.runInNewContext(scripts.chromeScript(true,true,location.href),chromeContext);
assert.match(cssText,/TopNavBar/);assert.match(cssText,/FloatingActionButtons_Tweet_Button/);
const initialWrites=cssWrites;
chromeContext.window.__otApplyTop();assert.equal(cssWrites,initialWrites);
authVisible=true;chromeContext.window.__otApplyTop();assert.equal(cssText,'');
// 首页进入详情时，即使原生回调尚未返回或旧回调迟到，也不能隐藏网页返回和标题。
authVisible=false;location.pathname='/alice/status/123';location.href='https://x.com/alice/status/123';
chromeContext.history.pushState();
assert.doesNotMatch(cssText,/display:none/);
vm.runInNewContext(scripts.chromeScript(true,true,'https://x.com/home'),chromeContext);
assert.doesNotMatch(cssText,/display:none/);
vm.runInNewContext(scripts.chromeFlagScript(true,true,'https://x.com/home'),chromeContext);
assert.doesNotMatch(cssText,/display:none/);
vm.runInNewContext(scripts.chromeFlagScript(true,false,location.href),chromeContext);
assert.doesNotMatch(cssText,/TopNavBar|role='banner'/);
assert.match(cssText,/FloatingActionButtons_Tweet_Button/);
// 新页已确认后，迟到的旧页回调不能覆盖已确认的导航和标题状态。
vm.runInNewContext(scripts.chromeScript(true,true,'https://x.com/home'),chromeContext);
vm.runInNewContext(scripts.chromeFlagScript(true,true,'https://x.com/home'),chromeContext);
assert.match(cssText,/FloatingActionButtons_Tweet_Button/);
assert.doesNotMatch(cssText,/TopNavBar|role='banner'/);
// 搜索页必须保留网页输入框及候选列表，仍只去重底部导航和发帖入口。
authVisible=false;location.pathname='/search';location.href='https://x.com/search?q=中文';
vm.runInNewContext(scripts.chromeScript(true,false,location.href),chromeContext);
assert.doesNotMatch(cssText,/TopNavBar|role='banner'|tablist/);
assert.match(cssText,/FloatingActionButtons_Tweet_Button/);
authVisible=false;vm.runInNewContext(scripts.chromeScript(false,false,location.href),chromeContext);
assert.doesNotMatch(cssText,/display:none/);
// 视频遮罩应铺到底；避让放进内容内部，不能影响登录、图片和未知页面。
location.pathname='/alice/status/123/mediaViewer';
vm.runInNewContext(scripts.chromeScript(false,false,location.href),chromeContext);
assert.match(cssText,/bottom:0!important;padding-bottom:env\(safe-area-inset-bottom\)/);
assert.doesNotMatch(cssText,/display:none/);
assert.match(cssText,/>:last-child\{margin-bottom:4px/);
const safeAreaCss=cssText;
authVisible=true;chromeContext.window.__otApplyTop();assert.equal(cssText,'');
authVisible=false;location.pathname='/alice/status/123/photo/1';
chromeContext.window.__otApplyTop();assert.equal(cssText,safeAreaCss);
location.pathname='/unknown/path';chromeContext.window.__otApplyTop();assert.equal(cssText,safeAreaCss);

// 使用真实注入代码验证视口缩放、重复同步、私信释放以及登录/路由切换时的留白归属。
const insets=new Map();
chromeContext.document.documentElement.style={setProperty:(key,value)=>insets.set(key,value)};
chromeContext.window.innerWidth=980;
location.pathname='/home';location.href='https://x.com/home';
vm.runInNewContext(scripts.chromeScript(true,true,location.href),chromeContext);
vm.runInNewContext(scripts.chromeInsetsScript(48,70,400),chromeContext);
assert.ok(Math.abs(parseFloat(insets.get('--ot-top-inset'))-117.6)<0.001);
assert.equal(parseFloat(insets.get('--ot-bottom-inset')),171.5);
assert.match(cssText,/main\[role="main"\]/);
// URL 编码、追踪参数、hash、站点别名及尾斜杠不应释放同一路径的去重与裁剪规则。
for(const url of ['https://x.com/home?lang=zh#timeline','https://x.com/home/',
  'https://www.twitter.com/home?ref=app']) {
  vm.runInNewContext(scripts.chromeFlagScript(true,true,url),chromeContext);
  assert.match(cssText,/BottomBar/);
  assert.match(cssText,/data-ot-pull-clip/);
  assert.match(cssText,/overflow:clip/);
}
location.pathname='/search';location.href='https://x.com/search?q=%E4%B8%AD%E6%96%87';
vm.runInNewContext(scripts.chromeScript(true,false,'https://x.com/search?q=中文'),chromeContext);
assert.match(cssText,/BottomBar/);
assert.doesNotMatch(cssText,/TopNavBar/);
location.pathname='/home';location.href='https://x.com/home';
vm.runInNewContext(scripts.chromeScript(true,true,location.href),chromeContext);
chromeContext.window.innerWidth=400;chromeContext.window.__otUpdateInsets();
assert.equal(insets.get('--ot-top-inset'),'48px');
vm.runInNewContext(scripts.chromeInsetsScript(0,0,400),chromeContext);
assert.doesNotMatch(cssText,/main\[role="main"\]/);
vm.runInNewContext(scripts.chromeInsetsScript(48,70,400),chromeContext);
authVisible=true;chromeContext.window.__otApplyTop();assert.equal(cssText,'');
authVisible=false;location.pathname='/unknown/path';location.href='https://x.com/unknown/path';
chromeContext.history.pushState();assert.doesNotMatch(cssText,/--ot-top-inset|--ot-bottom-inset/);

// 头像只能来自账号控件或确认本人的资料头像，不读取大尺寸的时间线或他人头像。
const ownAvatar='https://pbs.twimg.com/profile_images/123/own_normal.jpg';
const otherAvatar='https://pbs.twimg.com/profile_images/456/other.jpg';
const image=src=>({currentSrc:src,getAttribute:()=>src});
const avatarRoot=src=>({querySelectorAll:()=>[image(src)]});
const avatarContext={location:{pathname:'/home'},document:{querySelectorAll:selector=>
  selector==='a[href]'?[]:[avatarRoot(ownAvatar)]}};
assert.equal(vm.runInNewContext(scripts.accountAvatarScript(''),avatarContext),ownAvatar);
for(const [kind,node] of [
  ['background',{style:{backgroundImage:'url("'+ownAvatar+'")'},getAttribute:()=>''}],
  ['svg-image',{getAttribute:name=>name==='href'?ownAvatar:''}]
]){
  avatarContext.document.querySelectorAll=()=>[{querySelectorAll:()=>[node]}];
  assert.equal(vm.runInNewContext(scripts.accountAvatarScript(''),avatarContext),ownAvatar,kind);
}
avatarContext.document.querySelectorAll=()=>[];
assert.equal(vm.runInNewContext(scripts.accountAvatarScript('alice'),avatarContext),'');

// 首屏 DOM 与图片 src 延后就绪时通知原生重新读取；相同头像不会触发回调循环。
const beforeAvatar=chromeNotifications;
chromeContext.document.querySelectorAll=selector=>selector.startsWith('[data-testid="DashButton_ProfileIcon_Link"]')?[avatarRoot(ownAvatar)]:[];
chromeContext.window.__otPass();assert.equal(chromeNotifications,beforeAvatar+1);
chromeContext.window.__otPass();assert.equal(chromeNotifications,beforeAvatar+1);
chromeContext.document.querySelectorAll=()=>[];
assert.equal(observedOptions.attributes,true);
assert.deepEqual(Array.from(observedOptions.attributeFilter),['src','srcset']);
avatarContext.location.pathname='/alice';
avatarContext.document.querySelectorAll=selector=>selector==='a[href]'?
  [{getAttribute:()=>'/alice/photo',...avatarRoot(ownAvatar)},
    {getAttribute:()=>'/bob/photo',...avatarRoot(otherAvatar)}]:[];
assert.equal(vm.runInNewContext(scripts.accountAvatarScript('Alice'),avatarContext),ownAvatar);
avatarContext.location.pathname='/bob';
assert.equal(vm.runInNewContext(scripts.accountAvatarScript('alice'),avatarContext),'');
avatarContext.location.pathname='/alice';
avatarContext.document.querySelectorAll=selector=>selector==='a[href]'?
  [{getAttribute:()=>'/alice/photo',...avatarRoot('https://pbs.twimg.com.evil.test/profile_images/a.jpg')}]:[];
assert.equal(vm.runInNewContext(scripts.accountAvatarScript('alice'),avatarContext),'');

// 执行实际胶囊显示方法，账号信息等正常网页不再出现额外设置入口。
const pillBody=mainSource.match(/private settingsPillVisible\(\): boolean \{([\s\S]*?)\n  \}/)[1];
const pill=vm.runInNewContext(stripTypeScriptTypes('(function(){'+pillBody+'})'),{
  isSiteUrl:url=>/^https:\/\/x\.com\//.test(url)
});
const pillState={firstLoadDone:true,hasError:false,authenticationPage:false,
  currentUrl:'https://x.com/alice/about',currentPath:'/alice/about',
  showsNativeNavigation:()=>false,isMediaViewer:()=>false};
for(const path of ['/alice/about','/settings','/settings/your_twitter_data/account','/unknown/path']){
  pillState.currentPath=path;pillState.currentUrl='https://x.com'+path;
  assert.equal(pill.call(pillState),false,path);
}
pillState.authenticationPage=true;
assert.equal(pill.call(pillState),false,'A stale auth read cannot expose the pill on a normal page');
pillState.authenticationPage=false;
for(const path of ['/','/login','/signup','/i/flow/login','/i/flow/signup']){
  pillState.currentPath=path;pillState.currentUrl='https://x.com'+path;
  assert.equal(pill.call(pillState),true,path);
}
pillState.currentPath='/unknown/path';pillState.currentUrl='https://x.com/unknown/path';
pillState.firstLoadDone=false;assert.equal(pill.call(pillState),true);
pillState.firstLoadDone=true;pillState.hasError=true;assert.equal(pill.call(pillState),true);
pillState.showsNativeNavigation=()=>true;assert.equal(pill.call(pillState),false);
pillState.showsNativeNavigation=()=>false;
for(const state of ['fullScreen','imageViewerOpen','sheetOpen','networkOpen','appearanceOpen','discovering','rawWeb']) {
  pillState[state]=true;assert.equal(pill.call(pillState),false,state);pillState[state]=false;
}

// 头像下载、缓存和异步状态测试见 check-avatar-loading.mjs，使用生产下载器覆盖平台 I/O 边界。

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
