import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';

function load(name, exports) {
  const path = new URL('../entry/src/main/ets/common/' + name + '.ets', import.meta.url);
  const source = readFileSync(path, 'utf8').replace(/^import .*;\r?\n/gm, '');
  const js = stripTypeScriptTypes(source).replace(/^export /gm, '');
  const context = name === 'WebChrome' ? load('WebConfig', ['RESERVED_ROOTS','SECONDARY_PATH_PATTERN','PROFILE_PATH_PATTERN']) : {};
  return vm.runInNewContext(js + ';({' + exports.join(',') + '})', context);
}
const routes = load('WebConfig', ['routeIndexForUrl', 'profileHandleForUrl','usesNativeNavigation','usesNativeHeader','isTabRootPath','isPostDetailUrl']);
for (const [path, expected] of [['/home',0],['/search?q=a',1],['/notifications',2],['/messages/42',3],['/i/chat',3],['/someone',-1],['/i/grok',5],['/grok',5],['/i/flow/login',-1],['/settings',-1],['/someone/status/123',-1]]) {
  assert.equal(routes.routeIndexForUrl('https://x.com' + path), expected, path);
}
assert.equal(routes.routeIndexForUrl('https://example.com/home'), -1);
assert.equal(routes.profileHandleForUrl('https://x.com/settings'), '');
assert.equal(routes.profileHandleForUrl('https://x.com.evil.test/alice'), '');
for(const tab of ['with_replies','reposts','highlights','articles','media','likes']){
  const url='https://x.com/Alice/'+tab;
  assert.equal(routes.profileHandleForUrl(url),'alice');
  assert.equal(routes.routeIndexForUrl(url),-1);
  assert.equal(routes.usesNativeNavigation(url),true);
  assert.equal(routes.usesNativeHeader(url),true);
}
for(const path of ['/home/media','/i/media','/alice/media/unknown','/alice/followers','/alice/status/1']){
  assert.equal(routes.profileHandleForUrl('https://x.com'+path),'',path);
}
for(const path of ['/home','/search?q=中文','/notifications','/messages/42','/i/chat','/alice','/alice/status/123','/settings','/settings/profile','/i/bookmarks','/i/history','/alice/lists']){
  assert.equal(routes.usesNativeNavigation('https://x.com'+path),true,path);
}
for(const path of ['/','/i/flow/login','/login','/unknown/path']){
  assert.equal(routes.usesNativeNavigation('https://x.com'+path),false,path);
}
assert.equal(routes.usesNativeNavigation('https://example.com/home'),false);
assert.equal(routes.isTabRootPath('/search'),true);
for(const path of ['/i/flow/login','/explore','/explore/tabs/for-you','/search?q=中文',
  '/messages','/messages/42','/i/chat','/i/chat/conversations/42']){
  assert.equal(routes.usesNativeHeader('https://x.com'+path),false,path);
}
assert.equal(routes.usesNativeHeader('https://x.com/home'),true);
assert.equal(routes.usesNativeHeader('https://x.com/alice'),true);
assert.equal(routes.usesNativeHeader('https://x.com/i/bookmarks'),true);
assert.equal(routes.isTabRootPath('/settings/profile'),false);
assert.equal(routes.usesNativeHeader('https://x.com/alice/status/123'),true);
assert.equal(routes.isPostDetailUrl('https://x.com/alice/status/123?ref=home'),true);
assert.equal(routes.isPostDetailUrl('https://x.com/i/web/status/123'),true);
for (const url of ['https://x.com/alice/status/123/photo/1','https://x.com/alice/status/123/mediaViewer','https://example.com/alice/status/123']) {
  assert.equal(routes.isPostDetailUrl(url),false,url);
}
const scripts = load('WebChrome', ['fillComposerScript','CLICK_POST_BUTTON_SCRIPT','POST_RESULT_SCRIPT','chromeScript','chromeFlagScript','chromeInsetsScript','chromeDocumentStartScript','chromeActiveScript','COMPOSER_READY_SCRIPT','ACCOUNT_SWITCH_SCRIPT','OWN_HANDLE_SCRIPT','profileBootstrapScript','clickRouteScript','accountAvatarScript','accountAvatarDiagScript','PROFILE_LAYOUT_SCRIPT','PROFILE_MEDIA_SCRIPT','WEB_MODAL_SCRIPT']);
assert.equal(scripts.chromeDocumentStartScript(false),'');
// 模拟网页处理事件后，浏览器是否还会执行链接的默认导航。
function clickRuntime() {
  const handlers=new Set();
  const window={addEventListener:(_name,fn)=>handlers.add(fn),removeEventListener:(_name,fn)=>handlers.delete(fn)};
  class MouseEvent {
    constructor(){this.defaultPrevented=false;}
    preventDefault(){this.defaultPrevented=true;}
  }
  function anchor(href,handle) {
    return {tagName:'A',getAttribute:name=>name==='href'?href:null,getClientRects:()=>[{}],
      dispatchEvent(event){handle?.(event);for(const listener of handlers)listener(event);
        assert.equal(event.defaultPrevented,true,'网页未接管的点击也不能触发整页加载');}};
  }
  return {window,MouseEvent,anchor};
}
const mediaClicks=clickRuntime();
let mediaMenuOpen=false,menuReady=false,photoClicks=0,dropdownClicks=0,tabReady=false;
const menuPhoto={tagName:'DIV',textContent:'照片',getAttribute:()=>null,getClientRects:()=>[{}],
  click(){photoClicks++;mediaMenuOpen=false;}};
const menu={getAttribute:()=>null,getClientRects:()=>mediaMenuOpen?[{}]:[],querySelectorAll:()=>menuReady?[menuPhoto]:[]};
const videoTab=mediaClicks.anchor('/alice/media',event=>{event.preventDefault();dropdownClicks++;mediaMenuOpen=true;});
const mediaContext={...mediaClicks,URL,location:{pathname:'/alice/media',href:'https://x.com/alice/media'},
  document:{querySelectorAll:selector=>selector.startsWith('[role="menu"]')?[menu]:tabReady?[videoTab]:[]}};
const selectPhotos=()=>vm.runInNewContext(scripts.PROFILE_MEDIA_SCRIPT,mediaContext);
selectPhotos();assert.equal(dropdownClicks,0);
tabReady=true;selectPhotos();assert.equal(dropdownClicks,1);assert.equal(photoClicks,0);
selectPhotos();assert.equal(dropdownClicks,1,'等待菜单挂载时不反复开关');
menuReady=true;selectPhotos();assert.equal(photoClicks,1);assert.equal(mediaMenuOpen,false);
mediaMenuOpen=true;selectPhotos();assert.equal(photoClicks,1,'同次访问保留用户后续手动选择');
mediaMenuOpen=false;
mediaContext.location.pathname='/alice';selectPhotos();
mediaContext.location.pathname='/alice/media';selectPhotos();selectPhotos();
assert.equal(dropdownClicks,2);assert.equal(photoClicks,2,'重新进入媒体页默认照片');
for(const filter of ['photo','video','unknown','']){
  mediaContext.window.__otPhotoEntry='';mediaContext.location.href='https://x.com/alice/media?filter='+filter;
  selectPhotos();assert.equal(dropdownClicks,2,'保留显式筛选参数');
}
mediaContext.location.href='https://x.com/alice/media';selectPhotos();assert.equal(dropdownClicks,2);
for(const path of ['/i/media','/home/media','/alice/status/1','/alice']){
  mediaContext.location.pathname=path;mediaContext.location.href='https://x.com'+path;selectPhotos();
  assert.equal(dropdownClicks,2,'不接管非用户媒体页');
}
mediaMenuOpen=true;
const modalReports=[];
const modalContext={window:{otNative:{onWebModal:(url,open)=>modalReports.push([url,open])}},
  location:{href:'https://x.com/alice/media'},document:{querySelectorAll:()=>[menu]}};
const reportModal=()=>vm.runInNewContext(scripts.WEB_MODAL_SCRIPT,modalContext);
reportModal();reportModal();assert.deepEqual(modalReports,[[modalContext.location.href,true]]);
mediaMenuOpen=false;reportModal();assert.equal(modalReports.at(-1)[1],false,'菜单关闭后报告恢复底栏');
mediaMenuOpen=true;menu.getAttribute=()=> 'true';reportModal();assert.equal(modalReports.length,2,'忽略隐藏的菜单');
new vm.Script(scripts.chromeDocumentStartScript(true));
// 文档开始阶段与原生路由一致；登录表单出现时不得隐藏其导航。
for (const path of ['/home','/explore','/search','/notifications','/messages','/messages/42',
  '/i/chat','/i/chat/conversations/42','/alice','/alice/status/123','/settings','/settings/profile','/i/bookmarks','/i/history',
  '/alice/lists','/alice/with_replies','/alice/reposts','/alice/highlights','/alice/articles','/alice/media','/alice/likes',
  '/i/web/status/123','/i/flow/login','/grok','/unknown/path','/home/unknown','/invalid-handle','/']) {
  const style = {textContent:''};
  let auth = false;
  let update;
  const context = {
    URL,window:{addEventListener(){}}, location:{pathname:path,href:'https://x.com'+path,replace(){}},
    document:{head:{},getElementById:()=>style,querySelector:()=>auth?{}:null,querySelectorAll:()=>[]},
    MutationObserver:class {constructor(callback){update=callback;}observe(){}disconnect(){}}
  };
  context.window.top=context.window;
  vm.runInNewContext(scripts.chromeDocumentStartScript(true),context);
  assert.equal(style.textContent.includes('FloatingActionButtons'),routes.usesNativeNavigation('https://x.com'+path),path);
  assert.equal(style.textContent.includes('TopNavBar'),routes.usesNativeHeader('https://x.com'+path),path);
  auth=true;update();assert.equal(style.textContent,'',path);
}
// 回复直接使用当前详情的帖子编号，原帖是否被虚拟列表回收不影响面板显示。
const mainSource=readFileSync(new URL('../entry/src/main/ets/pages/MainTabs.ets',import.meta.url),'utf8');
const goRouteBody=mainSource.match(/private goRoute\(index: number\): void \{([\s\S]*?)\n  \}/)[1];
const goRoute=vm.runInNewContext(stripTypeScriptTypes('(function(index){'+goRouteBody+'})'),{
  isTabRootPath:routes.isTabRootPath,TWITTER_ROUTES:['/home','/explore','/notifications','/i/chat'],scrollToTopScript:()=> 'scroll'});
const navigations=[],scrolls=[];
const navigationState={currentIndex:0,currentPath:'/settings',cancelProfileNavigation(){},tick(){},
  loadWeb:url=>navigations.push(url),controller:{runJavaScript:value=>scrolls.push(value)}};
goRoute.call(navigationState,0);assert.deepEqual(navigations,['/home'],'二级页点击上次选中的标签仍须导航');
navigationState.currentPath='/home';goRoute.call(navigationState,0);assert.deepEqual(scrolls,['scroll']);
const modalMethods=['bottomChromeHeight','updateWebModal','modalBlocksNetworkReload'].map(name=>
  mainSource.match(new RegExp('^  private '+name+'\\([\\s\\S]*?^  \\}','m'))[0]).join('\n');
const ModalPage=vm.runInNewContext(stripTypeScriptTypes('class ModalPage{'+modalMethods+'};ModalPage'),{
  isSecondaryUrl:()=>false,isPostDetailUrl:()=>false,FLOATING_BAR_HEIGHT:58,BAR_HEIGHT:56});
const modalPage=new ModalPage();let insetChanges=0,resumedReloads=0;
Object.assign(modalPage,{webModalOpen:false,showsNativeNavigation:()=>true,isWide:false,floatingBar:true,bottomInset:24,
  syncChromeInsets(){insetChanges++;},flushNetworkReload(){resumedReloads++;}});
assert.equal(modalPage.bottomChromeHeight(),82);
modalPage.updateWebModal(true);assert.equal(modalPage.bottomChromeHeight(),0);assert.equal(modalPage.modalBlocksNetworkReload(),true);
modalPage.updateWebModal(true);assert.equal(insetChanges,1);
modalPage.updateWebModal(false);assert.equal(modalPage.bottomChromeHeight(),82);assert.equal(resumedReloads,1);
const insetBody=mainSource.match(/private overlayTopInset\(\): number \{([\s\S]*?)\n  \}/)[1];
const topInset=vm.runInNewContext(stripTypeScriptTypes('(function(){'+insetBody+'})'),{
  HEADER_HEIGHT:56,HEADER_CONTENT_LIFT:4
});
const insetState={topInset:39,homeTabsHeight:28,viewingHandle:'',overlaysWeb:()=>true,topChromeHeight:()=>56,isHomeRoot:()=>true};
assert.equal(topInset.call(insetState),77,'Home inset ends at the measured underline, not the full title bar');
insetState.homeTabsHeight=40;assert.equal(topInset.call(insetState),83,'Large text changes the measured boundary');
insetState.isHomeRoot=()=>false;assert.equal(topInset.call(insetState),95);
insetState.viewingHandle='alice';assert.equal(topInset.call(insetState),0,'Profile banner has no top inset');
insetState.viewingHandle='';assert.equal(topInset.call(insetState),95,'Leaving a profile restores the other page inset');
insetState.topChromeHeight=()=>0;assert.equal(topInset.call(insetState),0);
insetState.overlaysWeb=()=>false;assert.equal(topInset.call(insetState),0);

// 真实边界与滚动统一为 vp；标题和模糊独立变化，并连续反向恢复。
const profileMethods=['syncHeaderBlur','resetHeaderBlur','resetProfileLayout','receiveProfileLayout','profileBannerButtons'].map(name=>
  mainSource.match(new RegExp('^  private '+name+'\\([\\s\\S]*?^  \\}', 'm'))[0]).join('\n');
const ProfilePage=vm.runInNewContext(stripTypeScriptTypes('class ProfilePage{'+profileMethods+'};ProfilePage'),{
  HEADER_HEIGHT:56,HEADER_BLUR_DISTANCE:32,hilog:{error(){}},DOMAIN:0,TAG:''});
const profilePage=new ProfilePage();let blurOffset=0;
Object.assign(profilePage,{viewingHandle:'alice',webWidth:440,topInset:39,avatarAlive:true,appBackground:false,rawWeb:false,
  currentUrl:'https://x.com/alice',controller:{getUrl:()=>profilePage.currentUrl},lastBlurOffset:0,
  blurScroller:{scrollTo:({yOffset,animation})=>{assert.equal(animation,false);blurOffset=yOffset;}}});
profilePage.resetProfileLayout();profilePage.syncHeaderBlur(1000);
assert.equal(blurOffset,0);assert.equal(profilePage.profileTitleOpacity,0);
const layout={url:profilePage.currentUrl,width:880,viewWidth:440,scrollY:0,ready:true,hasBanner:true,
  bannerBottom:400,identityBottom:640,name:'Alice',handle:'Alice'};
profilePage.receiveProfileLayout(JSON.stringify(layout));
for(const [y,blur,title] of [[0,0,0],[105,0,0],[129,0.5,0],[153,1,0],[225,1,0],
  [233,1,0.15625],[241,1,0.5],[257,1,1],[241,1,0.5],[129,0.5,0],[0,0,0]]){
  profilePage.syncHeaderBlur(y);assert.equal(profilePage.profileBlurProgress,blur,'blur at '+y);
  assert.equal(profilePage.profileTitleOpacity,title,'title at '+y);assert.equal(blurOffset,blur*32);
}
profilePage.receiveProfileLayout(JSON.stringify({...layout,scrollY:482}));
assert.equal(profilePage.lastScrollY,241);assert.equal(profilePage.profileTitleOpacity,0.5,'Restored scroll is used without scrolling the page');
profilePage.currentUrl='https://x.com/bob';profilePage.viewingHandle='bob';profilePage.resetProfileLayout();
profilePage.receiveProfileLayout(JSON.stringify(layout));
assert.equal(profilePage.profileTitleOpacity,0);assert.equal(profilePage.profileLayout,undefined,'Old page geometry is rejected');
profilePage.receiveProfileLayout(JSON.stringify({...layout,url:profilePage.currentUrl,handle:'bob',viewWidth:600}));
assert.equal(profilePage.profileLayout,undefined,'Old viewport geometry is rejected');
profilePage.receiveProfileLayout(JSON.stringify({...layout,url:profilePage.currentUrl,handle:'bob',ready:false}));
assert.equal(blurOffset,0);assert.equal(profilePage.profileBannerButtons(),true);
profilePage.receiveProfileLayout(JSON.stringify({...layout,url:profilePage.currentUrl,handle:'bob',hasBanner:false}));
assert.equal(profilePage.profileBannerButtons(),false,'No banner keeps readable theme icons and status text');
profilePage.viewingHandle='';profilePage.syncHeaderBlur(16);assert.equal(blurOffset,16,'Other pages retain the original transition');

// 资料节点在 SPA 切页时必须与地址中的账号一致，无横幅取实际资料区边界。
let profileY=0,hasBanner=true,domHandle='Alice',identityHeight=80,profileReports=[];
const nameNode={querySelectorAll:()=>[{textContent:'Alice'},{get textContent(){return '@'+domHandle;}}],closest:()=>null,
  getBoundingClientRect:()=>({width:408,height:identityHeight,bottom:320-profileY}),
  parentElement:{getBoundingClientRect:()=>({bottom:520-profileY})}};
const profileContext={window:{innerWidth:440,__otViewportWidth:440,get scrollY(){return profileY;},
  otNative:{onProfileLayout:value=>profileReports.push(JSON.parse(value))}},
  location:{pathname:'/alice',href:'https://x.com/alice'},
  document:{querySelectorAll:()=>[nameNode],querySelector:()=>hasBanner?{getBoundingClientRect:()=>({bottom:200-profileY})}:null}};
const measure=()=>vm.runInNewContext(scripts.PROFILE_LAYOUT_SCRIPT+'(true)',profileContext);
measure();assert.equal(profileReports.at(-1).bannerBottom,200);assert.equal(profileReports.at(-1).identityBottom,320);
for(const tab of ['with_replies','media','articles']){
  profileContext.location={pathname:'/alice/'+tab,href:'https://x.com/alice/'+tab};measure();
  assert.equal(profileReports.at(-1).ready,true,'子标签沿用同一资料区测量');
}
profileContext.location={pathname:'/alice',href:'https://x.com/alice'};measure();
const reportsBeforeScroll=profileReports.length;
profileY=100;measure();assert.equal(profileReports.length,reportsBeforeScroll,'Scrolling does not repeatedly send unchanged document geometry');
hasBanner=false;measure();assert.equal(profileReports.at(-1).bannerBottom,520);assert.equal(profileReports.at(-1).hasBanner,false);
profileContext.location={pathname:'/bob',href:'https://x.com/bob'};measure();assert.equal(profileReports.at(-1).ready,false);
domHandle='bob';measure();assert.equal(profileReports.at(-1).ready,true);assert.equal(profileReports.at(-1).scrollY,100);
identityHeight=0;measure();assert.equal(profileReports.at(-1).ready,false,'Loading placeholders cannot reveal the title');
const pageBegin=mainSource.match(/\.onPageBegin\(\(\) => \{([\s\S]*?)\n      \}\)/)[1];
const begin=vm.runInNewContext('(function(){'+pageBegin+'})');
const loadingState={webNetworkReady:true,documentLoading:false,incomingPageReady:true,hasError:true,resetProfileLayout(){this.reset=true;},armFirstLoadTimeout(){},updateWebModal(){}};
begin.call(loadingState);
assert.equal(loadingState.reset,true);assert.equal(loadingState.documentLoading,true);assert.equal(loadingState.hasError,false);
loadingState.documentLoading=false;loadingState.webNetworkReady=false;begin.call(loadingState);
assert.equal(loadingState.documentLoading,false,'网络策略阻断时不启动加载遮罩');
let loadTimeout;
const loadingMethods=['armFirstLoadTimeout','finishFirstLoad'].map(name=>mainSource.match(new RegExp('^  private '+name+'\\([\\s\\S]*?^  \\}','m'))[0]).join('\n');
const LoadingPage=vm.runInNewContext(stripTypeScriptTypes('class LoadingPage{'+loadingMethods+'};LoadingPage'),{
  FIRST_LOAD_TIMEOUT_MS:12000,setTimeout:fn=>{loadTimeout=fn;return 1;},clearTimeout(){}});
const loadingPage=new LoadingPage();loadingPage.firstLoadTimer=-1;loadingPage.documentLoading=true;
loadingPage.armFirstLoadTimeout();loadTimeout();assert.equal(loadingPage.documentLoading,false,'加载遮罩超时后可退出');
loadingPage.documentLoading=true;loadingPage.finishFirstLoad();assert.equal(loadingPage.documentLoading,false);
assert.match(mainSource,/onAreaChange\([\s\S]*?this.webWidth !== Number\(area.width\)[\s\S]*?this.resetProfileLayout\(\)/);
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
let menuOpen=false, ambiguous=false, clicks=0, profileReady=true, accountChanged;
const profileButton={click(){menuOpen=!menuOpen;clicks++;}};
const dialog={textContent:'Profile',querySelector:()=>null,querySelectorAll:()=>ambiguous?
  [profileLink,{textContent:'Profile',getAttribute:name=>name==='href'?'/bob':null}]:[profileLink]};
const accountDocument={
  querySelectorAll:selector=>selector==='[role="dialog"]'?(menuOpen?[dialog]:[]):
    selector==='[role=dialog] a[href]'&&menuOpen?[profileLink]:[],
  querySelector:selector=>selector==='[role=dialog]'?(menuOpen?dialog:null):(profileReady?profileButton:null)
};
assert.equal(vm.runInNewContext(scripts.OWN_HANDLE_SCRIPT,{document:accountDocument}),'');
const accountContext={window:{},document:accountDocument,setTimeout:()=>1,clearTimeout(){},
  MutationObserver:class{constructor(callback){accountChanged=callback;}observe(){}disconnect(){}}};
assert.equal(vm.runInNewContext(scripts.profileBootstrapScript(false),accountContext),'armed');
assert.equal(accountContext.window.__otBoot,'alice');assert.equal(menuOpen,false);assert.equal(clicks,2);
menuOpen=true;assert.equal(vm.runInNewContext(scripts.OWN_HANDLE_SCRIPT,{document:accountDocument}),'alice');
ambiguous=true;dialog.textContent='@alice @bob';
assert.equal(vm.runInNewContext(scripts.OWN_HANDLE_SCRIPT,{document:accountDocument}),'');
ambiguous=false;menuOpen=false;
assert.equal(vm.runInNewContext(scripts.profileBootstrapScript(true),accountContext),'armed');
assert.equal(profileClicks,1);assert.equal(menuOpen,false);
profileReady=false;
assert.equal(vm.runInNewContext(scripts.profileBootstrapScript(false),accountContext),'armed');
assert.equal(accountContext.window.__otBoot,'');
profileReady=true;accountChanged();
assert.equal(accountContext.window.__otBoot,'alice');assert.equal(menuOpen,false);
let routeClicks=0;
const routeEvents=clickRuntime();
let routeLinks=[routeEvents.anchor('/i/chat',event=>{event.preventDefault();routeClicks++;})],routeControls=[];
const routeContext={...routeEvents,URL,location:{href:'https://x.com/home'},
  document:{querySelectorAll:selector=>selector==='a[href]'?routeLinks:routeControls,querySelector:()=>null}};
assert.equal(vm.runInNewContext(scripts.clickRouteScript('https://x.com/i/chat'),routeContext),'clicked');
assert.equal(routeClicks,1);
assert.equal(vm.runInNewContext(scripts.clickRouteScript('https://x.com/search?q=a'),routeContext),'missing');
assert.equal(routeClicks,1);
assert.equal(vm.runInNewContext(scripts.clickRouteScript('https://x.com/home'),routeContext),'same');
routeLinks=[routeEvents.anchor('/explore')];
assert.equal(vm.runInNewContext(scripts.clickRouteScript('https://x.com/explore'),routeContext),'pending','未绑定路由的链接不得整页跳转');
routeLinks=[];
let expanded=false,menuOpens=0;
const moreControl={tagName:'BUTTON',getAttribute:()=>expanded?'true':'false',click(){expanded=!expanded;menuOpens++;}};
routeControls=[moreControl];
assert.equal(vm.runInNewContext(scripts.clickRouteScript('https://x.com/settings'),routeContext),'pending');
assert.equal(vm.runInNewContext(scripts.clickRouteScript('https://x.com/settings'),routeContext),'pending');
assert.equal(menuOpens,1,'等待菜单挂载期间不反复点击');
routeLinks=[routeEvents.anchor('/settings',event=>{event.preventDefault();routeClicks++;expanded=false;})];
assert.equal(vm.runInNewContext(scripts.clickRouteScript('https://x.com/settings'),routeContext),'clicked');
assert.equal(routeClicks,2);
routeLinks=[];
assert.equal(vm.runInNewContext(scripts.clickRouteScript('https://x.com/alice/lists'),routeContext),'pending');
routeContext.location.href='https://x.com/notifications';
assert.equal(vm.runInNewContext(scripts.clickRouteScript('https://x.com/alice/lists'),routeContext),'cancelled','用户已切页时取消旧菜单导航');
routeControls=[];
for(const path of ['/home','/explore','/notifications','/i/chat','/alice','/alice/with_replies','/alice/reposts',
  '/alice/media','/i/history','/alice/lists','/settings','/settings/profile','/settings/notifications','/search?q=a']){
  routeContext.location.href='https://x.com/other';
  routeLinks=[routeEvents.anchor(path,event=>event.preventDefault())];
  assert.equal(vm.runInNewContext(scripts.clickRouteScript('https://x.com'+path),routeContext),'clicked',path);
}
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
// 搜索与私信保留官网完整顶栏，首帧和 SPA 切页后都只去重底部导航与发帖入口。
for (const path of ['/explore','/search?q=中文','/i/chat','/i/chat/conversations/42','/messages/42']) {
  authVisible=false;location.pathname=path.split('?')[0];location.href='https://x.com'+path;
  vm.runInNewContext(scripts.chromeScript(true,routes.usesNativeHeader(location.href),location.href),chromeContext);
  assert.doesNotMatch(cssText,/TopNavBar|role='banner'|form\[role="search"\]|tablist/,path);
  assert.match(cssText,/FloatingActionButtons_Tweet_Button/,path);
}
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
const image=src=>({currentSrc:src,getAttribute:()=>src,matches:()=>true});
const avatarRoot=src=>({querySelectorAll:()=>[image(src)],matches:()=>false,closest:()=>null});
const avatarContext={location:{pathname:'/home'},document:{querySelectorAll:selector=>
  selector.startsWith('[data-testid="DashButton_ProfileIcon_Link"]')?[avatarRoot(ownAvatar)]:[]}};
assert.equal(vm.runInNewContext(scripts.accountAvatarScript(''),avatarContext),ownAvatar);
for(const [kind,node] of [
  ['background',{style:{backgroundImage:'url("'+ownAvatar+'")'},getAttribute:()=>''}],
  ['svg-image',{getAttribute:name=>name==='href'?ownAvatar:''}]
]){
  avatarContext.document.querySelectorAll=selector=>selector.startsWith('[data-testid="DashButton_ProfileIcon_Link"]')?
    [{...avatarRoot(''),querySelectorAll:()=>[node]}]:[];
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
assert.equal(observedOptions.characterData,true);
assert.deepEqual(Array.from(observedOptions.attributeFilter),['src','srcset','style','href','aria-selected','aria-expanded','aria-hidden','hidden']);
avatarContext.location.pathname='/alice';
avatarContext.document.querySelectorAll=selector=>selector==='a[href]'?
  [{getAttribute:()=>'/alice/photo',...avatarRoot(ownAvatar)},
    {getAttribute:()=>'/bob/photo',...avatarRoot(otherAvatar)}]:[];
assert.equal(vm.runInNewContext(scripts.accountAvatarScript('Alice'),avatarContext),ownAvatar);
avatarContext.location.pathname='/bob';
assert.equal(vm.runInNewContext(scripts.accountAvatarScript('alice'),avatarContext),'');

// 根节点图片、大小写账号匹配，以及顶栏候选均受内容区域排除规则约束。
avatarContext.location.pathname='/home';
const rootImage={...image(ownAvatar),querySelectorAll:()=>[],closest:()=>null};
avatarContext.document.querySelectorAll=selector=>selector.startsWith('[data-testid="DashButton_ProfileIcon_Link"]')?[rootImage]:[];
assert.equal(vm.runInNewContext(scripts.accountAvatarScript(''),avatarContext),ownAvatar);
const candidate={...avatarRoot(ownAvatar),getAttribute:name=>name==='data-testid'?'UserAvatar-Container-ALIce':'',
  closest:selector=>selector.startsWith('header')?{}:null};
avatarContext.document.querySelectorAll=selector=>selector.includes('UserAvatar-Container-')?[candidate]:[];
assert.equal(vm.runInNewContext(scripts.accountAvatarScript('alice'),avatarContext),ownAvatar);
assert.equal(vm.runInNewContext(scripts.accountAvatarScript(''),avatarContext),ownAvatar);
candidate.closest=()=>null;
assert.equal(vm.runInNewContext(scripts.accountAvatarScript(''),avatarContext),'','Unknown account outside header is ignored');
candidate.closest=selector=>selector.startsWith('article')?{}:null;
assert.equal(vm.runInNewContext(scripts.accountAvatarScript('alice'),avatarContext),'','Known account in timeline is ignored');
avatarContext.document.querySelectorAll=()=>[{...avatarRoot(otherAvatar),closest:()=>({})}];
assert.equal(vm.runInNewContext(scripts.accountAvatarScript(''),avatarContext),'','Controls in timeline are ignored');
const diagnosticImage={...image(ownAvatar),tagName:'IMG',parentElement:{tagName:'DIV',getAttribute:()=> 'UserAvatar-Container-private_user'}};
const diagnosticRoot={...avatarRoot(''),tagName:'BUTTON',querySelectorAll:selector=>selector.startsWith('img')?[diagnosticImage]:[]};
const diagnostic=vm.runInNewContext(scripts.accountAvatarDiagScript(),{
  document:{querySelectorAll:()=>[diagnosticRoot]},getComputedStyle:()=>({display:'none',visibility:'visible'})});
assert.match(diagnostic,/pbs.twimg.com/);assert.match(diagnostic,/UserAvatar-Container-\*/);
assert.ok(!diagnostic.includes('private_user'));assert.ok(!diagnostic.includes(ownAvatar));

// 执行生产方法，方向抖动、网页偏移调整和惯性结束均不能重复触发动画。
const scrollMethods=['handleWebTouch','handleWebScroll','resetChromeScroll','setBarsCollapsed','onBarsCollapsedChanged'].map(name=>
  mainSource.match(new RegExp('^  private '+name+'\\([\\s\\S]*?^  \\}', 'm'))[0]).join('\n');
const TouchType={Down:0,Up:1,Move:2,Cancel:3};
let scrollTime=1000;
const animations=[];
const ScrollPage=vm.runInNewContext(stripTypeScriptTypes('class ScrollPage{'+scrollMethods+'};ScrollPage'),{
  TouchType,isPostDetailUrl:routes.isPostDetailUrl,Date:{now:()=>scrollTime},HdsAnimationMode:{SCROLL_ANIMATION:0}});
const scroll=new ScrollPage();
Object.assign(scroll,{overlaysWeb:()=>true,syncHeaderBlur(){},resetHeaderBlur(){},autoHideBar:true,isWide:false,
  currentUrl:'https://x.com/home',tabsController:{applyHideAnimation:()=>animations.push('hide'),
    applyShowAnimation:()=>animations.push('show')}});
let collapsed=false;
Object.defineProperty(scroll,'barsCollapsed',{get:()=>collapsed,set(value){collapsed=value;scroll.onBarsCollapsedChanged();}});
const touch=(type,y=0,x=0)=>scroll.handleWebTouch({type,touches:type===TouchType.Up||type===TouchType.Cancel?[]:[{x,y}]});
const sample=(y,gap=16)=>{scrollTime+=gap;scroll.handleWebScroll(y);};
const start=(hidden=true)=>{scroll.resetChromeScroll();scroll.lastScrollY=500;scroll.setBarsCollapsed(hidden);animations.length=0;};
const startCollapsed=()=>start();
startCollapsed();
for(let i=0;i<8;i++){touch(TouchType.Down);touch(TouchType.Move,8);sample(scroll.lastScrollY-8);touch(TouchType.Up);}
assert.equal(scroll.barsCollapsed,true,'Separate short gestures cannot accumulate');
touch(TouchType.Down);touch(TouchType.Move,54);sample(scroll.lastScrollY-54);
assert.equal(scroll.barsCollapsed,true);touch(TouchType.Move,56);sample(scroll.lastScrollY-2);
assert.equal(scroll.barsCollapsed,false,'56 vp within one downward gesture expands');
assert.deepEqual(animations,['show']);
startCollapsed();touch(TouchType.Down);touch(TouchType.Move,7);sample(490);
assert.equal(scroll.webTouchDirection,0,'Initial intent requires 8 vp');
touch(TouchType.Move,8);sample(489);
for(let i=1;i<=55;i++){touch(TouchType.Move,i+8);sample(489-i);}
assert.equal(scroll.barsCollapsed,false,'Slow one-vp samples must preserve deliberate scrolling distance');
assert.deepEqual(animations,['show']);

startCollapsed();touch(TouchType.Down);touch(TouchType.Move,60);sample(440);
touch(TouchType.Move,100);sample(486);
assert.equal(scroll.barsCollapsed,false,'A content offset increase cannot hide while the finger still drags downward');
touch(TouchType.Move,98);sample(484);
assert.equal(scroll.webTouchDirection,1,'A 2 vp jitter must not reverse intent');
touch(TouchType.Move,101);sample(420);
touch(TouchType.Move,94);sample(470);
assert.equal(scroll.webTouchDirection,1,'Reversal requires 8 vp measured from the latest finger extremum');
assert.deepEqual(animations,['show'],'Continued downward browsing sends no extra animation commands');
touch(TouchType.Move,93);sample(514);
assert.equal(scroll.webTouchDirection,-1);assert.equal(scroll.barsCollapsed,false,'44 vp alone does not exceed the collapse threshold');
sample(515);sample(600);
assert.deepEqual(animations,['show','hide'],'A deliberate reversal collapses once');
touch(TouchType.Move,101);sample(544);sample(500);
assert.deepEqual(animations,['show','hide','show'],'A second deliberate reversal expands once');

startCollapsed();touch(TouchType.Down);touch(TouchType.Move,30);sample(470);
touch(TouchType.Move,28);sample(480);touch(TouchType.Move,60);sample(454);
assert.equal(scroll.barsCollapsed,false,'Opposite page adjustment and finger jitter do not discard valid expansion distance');
startCollapsed();touch(TouchType.Down);touch(TouchType.Move,20);sample(480);touch(TouchType.Up);sample(400);
assert.equal(scroll.barsCollapsed,true,'Reverse inertia cannot expand');
startCollapsed();touch(TouchType.Down);touch(TouchType.Up);sample(400);
assert.equal(scroll.barsCollapsed,true,'A tap cannot enable programmatic scroll');
startCollapsed();touch(TouchType.Down);touch(TouchType.Move,5,80);sample(400);
assert.equal(scroll.barsCollapsed,true,'Horizontal movement cannot expand');
startCollapsed();touch(TouchType.Down);touch(TouchType.Move,-10);sample(400);
assert.equal(scroll.barsCollapsed,true,'Upward finger movement cannot expand');
touch(TouchType.Cancel);sample(300);assert.equal(scroll.barsCollapsed,true);
start(false);touch(TouchType.Down);touch(TouchType.Move,-20);sample(520);touch(TouchType.Up);
sample(545,200);sample(600);
assert.equal(scroll.barsCollapsed,true,'Upward drag inertia may finish collapsing, including a 200 ms interval');
assert.deepEqual(animations,['hide']);
for(const stop of ['idle','reverse','newTouch','cancel','multitouch','releaseAfterIdle']){
  start(false);touch(TouchType.Down);touch(TouchType.Move,-20);sample(520);
  if(stop==='releaseAfterIdle')scrollTime+=201;
  touch(TouchType.Up);
  if(stop==='idle')sample(521,201);
  if(stop==='reverse')sample(519);
  if(stop==='newTouch')touch(TouchType.Down);
  if(stop==='cancel')touch(TouchType.Cancel);
  if(stop==='multitouch')scroll.handleWebTouch({type:TouchType.Move,touches:[{x:0,y:0},{x:10,y:10}]});
  sample(600);
  assert.equal(scroll.barsCollapsed,false,'Inertia qualification ends: '+stop);
  assert.deepEqual(animations,[],stop);
}
startCollapsed();touch(TouchType.Down);touch(TouchType.Move,30);sample(470,300);
touch(TouchType.Move,60);sample(440,300);
assert.equal(scroll.barsCollapsed,false,'A slow active drag does not expire like inertia');
startCollapsed();sample(47);sample(46);
assert.equal(scroll.barsCollapsed,false,'Top region always shows navigation');
assert.deepEqual(animations,['show'],'Top-region callbacks must not restart the show animation');
for(const excluded of [{isWide:true},{autoHideBar:false},{currentUrl:'https://x.com/alice/status/123'}]){
  startCollapsed();Object.assign(scroll,excluded);sample(500);sample(600);assert.equal(scroll.barsCollapsed,false);
  assert.deepEqual(animations,['show']);
  Object.assign(scroll,{isWide:false,autoHideBar:true,currentUrl:'https://x.com/home'});
}
startCollapsed();scroll.overlaysWeb=()=>false;sample(500);assert.equal(scroll.barsCollapsed,false);
startCollapsed();scroll.resetChromeScroll();scroll.resetChromeScroll();
assert.deepEqual(animations,['show'],'Page and appearance resets show the bar only once');
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
for(const state of ['fullScreen','imageViewerOpen','sheetOpen','networkOpen','settingsOpen','discovering']) {
  pillState[state]=true;assert.equal(pill.call(pillState),false,state);pillState[state]=false;
}
pillState.rawWeb=true;assert.equal(pill.call(pillState),true,'Original web mode keeps its return entry');

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

// 发布资格跟随网页按钮；不以字符数替代站点按账号应用的规则。
for (const [button, expected] of [[null,false],[{disabled:true,getAttribute:()=>null},false],
  [{disabled:false,getAttribute:()=> 'true'},false],[{disabled:false,getAttribute:()=>null},true]]) {
  assert.equal(vm.runInNewContext(scripts.COMPOSER_READY_SCRIPT,{document:{querySelector:()=>button}}),expected);
}
let disconnected=0, resumed=0, applied=0, pullCleared=0;
const lifecycle={window:{__otObs:{disconnect(){disconnected++;},observe(){resumed++;}},
  __otApplyTop(){applied++;},__otClearPullTimers(){pullCleared++;},__otPend:1,__otTimer:42},
  clearTimeout(){},document:{documentElement:{}}};
vm.runInNewContext(scripts.chromeActiveScript(false),lifecycle);
assert.equal(lifecycle.window.__otChromePaused,true);assert.equal(disconnected,1);
assert.equal(lifecycle.window.__otPend,0);assert.equal(resumed,0);
vm.runInNewContext(scripts.chromeActiveScript(true),lifecycle);
assert.equal(lifecycle.window.__otChromePaused,false);assert.equal(resumed,1);assert.equal(applied,1);
assert.equal(pullCleared,2);
const themeColors=[];
chromeContext.document.body={};chromeContext.getComputedStyle=()=>({backgroundColor:'rgb(21, 32, 43)'});
chromeContext.window.otNative.onTheme=(_source,color)=>themeColors.push(color);
chromeContext.window.__otApplyTop();chromeContext.window.__otApplyTop();
assert.deepEqual(themeColors,['rgb(21, 32, 43)']);
chromeContext.getComputedStyle=()=>({backgroundColor:'rgb(255, 255, 255)'});
chromeContext.window.__otApplyTop();assert.equal(themeColors.length,2);
// 不再以原生提交拼接搜索 URL，候选与提交完整交由网页自己的搜索交互处理。
assert.doesNotMatch(mainSource,/submitSearch|src=typed_query/);
const topBarSource=readFileSync(new URL('../entry/src/main/ets/pages/NativeTopBar.ets',import.meta.url),'utf8');
assert.match(topBarSource,/@Prop titleOpacity: number = 1/);
assert.match(topBarSource,/\.opacity\(this.titleOpacity\)/);
assert.doesNotMatch(topBarSource,/\bSearch\(/);
// 验证界面实际使用的按钮条件，避免沿用来源标签时在非首页显示发帖入口。
const fabExpression=mainSource.match(/if \((this\.showsNativeNavigation\(\) && this\.isHomeRoot\(\)[^\r\n]*)\) \{\r?\n\s*this\.composeFab\(\)/)[1];
const fabVisible=vm.runInNewContext('(function(){return '+fabExpression+';})');
const homeBody=mainSource.match(/private isHomeRoot\(\): boolean \{([\s\S]*?)\n  \}/)[1];
const isHomeRoot=vm.runInNewContext('(function(){'+homeBody+'})');
const fabState={currentPath:'/home',isHomeRoot,showsNativeNavigation:()=>true,hasError:false,firstLoadDone:true};
assert.equal(fabVisible.call(fabState),true);
for (const path of ['/explore','/search','/notifications','/i/chat','/messages/compose','/alice','/alice/status/123','/settings']) {
  fabState.currentPath=path;assert.equal(fabVisible.call(fabState),false,path);
}
fabState.currentPath='/home';fabState.hasError=true;assert.equal(fabVisible.call(fabState),false);
fabState.hasError=false;fabState.firstLoadDone=false;assert.equal(fabVisible.call(fabState),false);
// 新草稿使旧异步校验失效，后台不再发起校验。
let syncTask, resolveFill;
const composeValidationContext={DRAFT_SAVE_DEBOUNCE_MS:700,COMPOSER_READY_SCRIPT:scripts.COMPOSER_READY_SCRIPT,
  fillComposerScript:scripts.fillComposerScript,$r:key=>key,MainTabs:{unquote:value=>value},
  clearTimeout(){},setTimeout:callback=>{syncTask=callback;return 1;},hilog:{warn(){}},DOMAIN:1,TAG:'test'};
const method=name=>mainSource.match(new RegExp('private '+name+'\\([^)]*\\): void \\{([\\s\\S]*?)\\n  \\}'))[1];
const syncCompose=vm.runInNewContext(stripTypeScriptTypes('(function(){'+method('scheduleComposeSync')+'})'),composeValidationContext);
const clearCompose=vm.runInNewContext(stripTypeScriptTypes('(function(){'+method('clearComposeSync')+'})'),composeValidationContext);
const composing={composeRevision:0,composeSyncTimer:-1,appBackground:false,sheetOpen:true,webComposer:false,
  composeLoading:false,composePreparing:false,posting:false,postUncertain:false,draft:'第一份',composeOwner:'alice',
  composeController:{runJavaScript:()=>new Promise(resolve=>{resolveFill=resolve;})},clearComposeSync:clearCompose};
syncCompose.call(composing);const oldValidation=syncTask();
composing.draft='第二份';syncCompose.call(composing);resolveFill('ok');await oldValidation;
assert.equal(composing.composeReady,false);
composing.composeController.runJavaScript=async script=>script===scripts.COMPOSER_READY_SCRIPT?'true':'ok';
await syncTask();assert.equal(composing.composeReady,true);
composing.appBackground=true;syncTask=undefined;syncCompose.call(composing);
assert.equal(syncTask,undefined);assert.equal(composing.composeReady,false);
console.log('PASS: webpage search/chat headers, home-only compose, webpage validation, stale draft results, theme and background observers');

// 使用生产导航和持久化方法验证设置来源、动态底栏及主页选中态。
const clientMethods=['setTabEnabled','syncFromUrl','openSettings','leaveSettings','openSettingsRoute'].map(name=>
  mainSource.match(new RegExp('^  private (?:async )?'+name+'\\([\\s\\S]*?^  \\}','m'))[0]).join('\n');
const ClientPage=vm.runInNewContext(stripTypeScriptTypes('class ClientPage{'+clientMethods+'};ClientPage'),{
  TWITTER_ROUTES:['https://x.com/home'],TWITTER_BASE:'https://x.com',routeIndexForUrl:routes.routeIndexForUrl,
  profileHandleForUrl:routes.profileHandleForUrl,pathOf:url=>new URL(url).pathname,$r:value=>value,
  hilog:{error(){}},DOMAIN:0,TAG:'test'
});
const client=new ClientPage();const saved=[];let failedSave=false;let notices=0;
Object.assign(client,{enabledTabs:[0,1,2,3,4],currentIndex:0,currentUrl:'https://x.com/home',settingsReadGeneration:0,
  accountName:'Alice',incomingPageReady:true,resetChromeScroll(){},resetProfileLayout(){},
  putPreference:async(key,value)=>{if(failedSave)throw Error('disk');saved.push([key,value]);},toast(){notices++;},loadWeb(url){this.loaded=url;}});
client.openSettings();assert.equal(client.currentIndex,4);assert.equal(client.settingsOpen,true);
client.syncFromUrl('https://x.com/alice');assert.equal(client.currentIndex,4,'后台读取本人资料不抢占设置标签');
client.openSettingsRoute('/settings/notifications');client.syncFromUrl('https://x.com/settings/notifications');
assert.equal(client.currentIndex,4,'设置子页保持来源标签');
client.settingsOpen=true;client.leaveSettings();assert.equal(client.currentIndex,0);assert.equal(client.loaded,'https://x.com/home');
client.syncFromUrl('https://x.com/alice');assert.equal(client.currentIndex,0,'个人主页不改变标签选中态');
await client.setTabEnabled(5,true);assert.equal(saved.length,0);assert.equal(notices,1);
await client.setTabEnabled(2,false);await client.setTabEnabled(5,true);
assert.deepEqual(Array.from(client.enabledTabs),[0,1,3,5,4]);
await client.setTabEnabled(0,false);assert.deepEqual(Array.from(client.enabledTabs),[0,1,3,5,4]);
failedSave=true;await client.setTabEnabled(3,false);assert.deepEqual(Array.from(client.enabledTabs),[0,1,3,5,4]);

const appearance=load('ClientSettings',['appearanceScript','accountDetailsScript','PLATFORM_SETTINGS']);
assert.equal(appearance.PLATFORM_SETTINGS.length,6);
let applySystemTheme;const themeStyle={textContent:''};const themeMedia={matches:false,addEventListener(_event,callback){applySystemTheme=callback;}};
const themeContext={window:{},matchMedia:()=>themeMedia,document:{head:{},getElementById:()=>themeStyle},
  MutationObserver:class{observe(){}}};
vm.runInNewContext(appearance.appearanceScript('dark'),themeContext);assert(themeStyle.textContent.includes('#000000'));
vm.runInNewContext(appearance.appearanceScript('light'),themeContext);assert(themeStyle.textContent.includes('#ffffff'));
vm.runInNewContext(appearance.appearanceScript('system'),themeContext);themeMedia.matches=true;applySystemTheme();
assert(themeStyle.textContent.includes('#000000'));assert(!themeStyle.textContent.includes('invert('));
assert.equal(vm.runInNewContext(appearance.accountDetailsScript('alice'),{location:{pathname:'/bob'}}),'');
assert.equal(vm.runInNewContext(appearance.accountDetailsScript('alice'),{location:{pathname:'/bob'}}),'');
console.log('PASS: native settings origins, stable navigation items, persistence failure, local theme and account boundaries');

// 验证指定入口直接导航、身份识别取消与抽屉清理、设置加载不导航、返回设置、旧账号结果失效、后台弹层不影响原生底栏、排序及五项上限、偏好持久化。
const navMethods = ['closeWebDrawer', 'loadWeb', 'openSettingsRoute', 'openOwnProfile', 'cancelProfileNavigation', 'acceptHandle', 'onBackPress', 'reorderTabs', 'setMaterialLevel', 'currentHdsMaterialLevel'].map(name =>
  mainSource.match(new RegExp('^  (?:private )?(?:async )?' + name + '\\([\\s\\S]*?^  \\}', 'm'))[0]).join('\n');
const NavTestPage = vm.runInNewContext(stripTypeScriptTypes('class NavTestPage {\n' + navMethods + '\n};NavTestPage'), {
  TWITTER_ROUTES: ['https://x.com/home'],
  TWITTER_BASE: 'https://x.com',
  PROFILE_TIMEOUT_MS: 10000,
  hdsMaterial: { MaterialLevel: { ADAPTIVE: 0, EXQUISITE: 1, GENTLE: 2, SMOOTH: 3 } },
  clickRouteScript: scripts.clickRouteScript,
  OWN_HANDLE_SCRIPT: scripts.OWN_HANDLE_SCRIPT,
  profileBootstrapScript: scripts.profileBootstrapScript,
  profileUrl: handle => 'https://x.com/' + handle,
  MainTabs: { unquote: val => typeof val === 'string' && val.startsWith('"') ? JSON.parse(val) : val },
  hilog: { error() {}, warn() {}, info() {} },
  DOMAIN: 0, TAG: 'test',
  $r: v => v
});

// 1. 指定入口直接导航 (Direct navigation on specified entries)
{
  const nav = new NavTestPage();
  const directUrls = [], scriptRuns = [];
  Object.assign(nav, {
    webNetworkReady: true,
    navigationGeneration: 0,
    profileNavigation: 0,
    settingsOpen: true,
    settingsWeb: false,
    settingsWebUrl: '',
    settingsWebRoot: '',
    currentUrl: 'https://x.com/home',
    cancelProfileNavigation() {},
    controller: {
      loadUrl: url => directUrls.push(url),
      runJavaScript: async s => { scriptRuns.push(s); return 'clicked'; }
    },
    toast() {}
  });

  // 书签与平台设置直接导航
  nav.openSettingsRoute('/i/bookmarks');
  assert.equal(nav.settingsWeb, true);
  assert.equal(nav.settingsOpen, false);
  assert.equal(nav.settingsWebRoot, 'https://x.com/i/bookmarks');
  assert.deepEqual(directUrls, ['https://x.com/i/bookmarks']);
  assert.equal(scriptRuns.length, 0, '直接导航不执行网页链接脚本');

  // 平台设置直接导航
  directUrls.length = 0;
  nav.openSettingsRoute('/settings/your_twitter_data');
  assert.equal(nav.settingsWeb, true);
  assert.equal(nav.settingsOpen, false);
  assert.equal(nav.settingsWebRoot, 'https://x.com/settings/your_twitter_data');
  assert.deepEqual(directUrls, ['https://x.com/settings/your_twitter_data']);

  // 本人主页在账号已知时直接导航
  directUrls.length = 0;
  nav.ownHandle = 'alice';
  nav.settingsOpen = true;
  await nav.openOwnProfile();
  assert.equal(nav.settingsWeb, true);
  assert.equal(nav.settingsWebRoot, 'https://x.com/alice');
  assert.deepEqual(directUrls, ['https://x.com/alice']);
}

// 2. 身份识别取消与抽屉清理 (Identity confirmation cancellation & failure drawer cleanup)
{
  // 网页端 profileBootstrapScript 的 stop() 行为
  let dialogOpen = false;
  let closeClicked = false;
  const mockBtn = { click: () => { dialogOpen = true; } };
  const mockDialog = {
    querySelector: sel => sel === '[data-testid=app-bar-close]' ? { click: () => { closeClicked = true; dialogOpen = false; } } : null
  };
  let obsDisconnected = false;
  const cancelDoc = {
    querySelector: sel => sel === '[role=dialog]' ? (dialogOpen ? mockDialog : null) : mockBtn,
    querySelectorAll: () => []
  };
  const cancelContext = {
    window: {},
    document: cancelDoc,
    setTimeout: () => 123,
    clearTimeout: () => {},
    MutationObserver: class {
      observe() {}
      disconnect() { obsDisconnected = true; }
    }
  };
  vm.runInNewContext(scripts.profileBootstrapScript(false), cancelContext);
  assert.equal(dialogOpen, true, '启动脚本点击头像按钮打开抽屉');
  assert.ok(typeof cancelContext.window.__otBootCancel === 'function');
  cancelContext.window.__otBootCancel();
  assert.equal(obsDisconnected, true, '取消时必须断开 MutationObserver');
  assert.equal(closeClicked, true, '取消时必须关闭抽屉');

  // 原生 cancelProfileNavigation 递增世代、重置 discovering 并调用 __otBootCancel
  const nav = new NavTestPage();
  let cancelScriptRun = '';
  Object.assign(nav, {
    profileNavigation: 5,
    discovering: true,
    incomingControllerReady: true,
    controller: {
      runJavaScript: async s => { cancelScriptRun = s; }
    }
  });
  await nav.cancelProfileNavigation();
  assert.equal(nav.profileNavigation, 6);
  assert.equal(nav.discovering, false);
  assert.match(cancelScriptRun, /__otBootCancel/);

  // 连续多次调用 openOwnProfile 时，旧请求返回不得取消新请求
  {
    const raceNav = new NavTestPage();
    let resolveFirst;
    const firstPromise = new Promise(r => { resolveFirst = r; });
    const directLoads = [];
    Object.assign(raceNav, {
      profileNavigation: 0,
      discovering: false,
      avatarAlive: true,
      appBackground: false,
      ownHandle: '',
      incomingControllerReady: true,
      isHomeRoot: () => true,
      loadWeb: (url) => { directLoads.push(url); },
      acceptHandle: (h) => { raceNav.ownHandle = h; directLoads.push('https://x.com/' + h); },
      toast: () => {},
      controller: {
        runJavaScript: async (s) => {
          if (s.includes('__otBootCancel')) return '';
          if (raceNav.profileNavigation === 1) {
            await firstPromise;
            return '"alice"';
          }
          return '"bob"';
        }
      }
    });

    const p1 = raceNav.openOwnProfile();
    // 等待一个微任务周期，让 p1 完成初始清理并进入资料脚本读取中
    await new Promise(r => setTimeout(r, 0));
    const p2 = raceNav.openOwnProfile();
    await p2;
    assert.equal(raceNav.ownHandle, 'bob');
    assert.deepEqual(directLoads, ['https://x.com/bob']);

    resolveFirst();
    await p1;
    assert.equal(raceNav.ownHandle, 'bob', '旧请求不得覆盖新请求账号');
    assert.equal(raceNav.profileNavigation, 2, '旧请求结束不得递增世代');
    assert.deepEqual(directLoads, ['https://x.com/bob'], '旧请求不得额外触发导航');
  }

  // 识别发生异常时，代际匹配必须提示未确认并清理抽屉
  {
    const errNav = new NavTestPage();
    let toastMsg = '';
    let drawerClosed = false;
    Object.assign(errNav, {
      profileNavigation: 0,
      discovering: false,
      avatarAlive: true,
      appBackground: false,
      ownHandle: '',
      incomingControllerReady: true,
      toast: (msg) => { toastMsg = msg; },
      controller: {
        runJavaScript: async (s) => {
          if (s.includes('__otBootCancel')) {
            drawerClosed = true;
            return '';
          }
          throw new Error('network failure');
        }
      }
    });

    await errNav.openOwnProfile();
    assert.equal(toastMsg, 'app.string.account_unconfirmed', '识别异常必须提示 account_unconfirmed');
    assert.equal(drawerClosed, true, '识别异常必须清理网页抽屉');
    assert.equal(errNav.discovering, false, '识别异常后 discovering 必须恢复 false');
  }
}

// 3. 设置加载不导航 (Settings opening does not navigate background webview)
{
  const navClient = new ClientPage();
  let navUrl = '';
  Object.assign(navClient, {
    currentIndex: 0,
    currentUrl: 'https://x.com/home',
    settingsOpen: false,
    resetChromeScroll() {},
    resetProfileLayout() {},
    loadWeb: url => { navUrl = url; }
  });
  navClient.openSettings();
  assert.equal(navClient.settingsOpen, true);
  assert.equal(navClient.currentIndex, 4);
  assert.equal(navUrl, '', '打开原生设置不得导航背景网页');
}

// 4. 返回设置 (Back button from web project returns to native settings)
{
  const nav = new NavTestPage();
  let backwardCalled = false;
  Object.assign(nav, {
    settingsWeb: true,
    settingsOpen: false,
    settingsWebRoot: 'https://x.com/settings/your_twitter_data',
    currentUrl: 'https://x.com/settings/your_twitter_data',
    hasError: false,
    cancelProfileNavigation() {},
    controller: {
      accessBackward: () => true,
      backward: () => { backwardCalled = true; }
    }
  });

  // 在 settingsWebRoot 处点击返回，应回到原生设置
  const handledRoot = nav.onBackPress();
  assert.equal(handledRoot, true);
  assert.equal(nav.settingsWeb, false);
  assert.equal(nav.settingsOpen, true);
  assert.equal(backwardCalled, false);

  // 网页加载失败时返回，也应回到原生设置
  nav.settingsWeb = true;
  nav.settingsOpen = false;
  nav.hasError = true;
  nav.currentUrl = 'https://x.com/settings/other';
  const handledError = nav.onBackPress();
  assert.equal(handledError, true);
  assert.equal(nav.settingsWeb, false);
  assert.equal(nav.settingsOpen, true);
  assert.equal(nav.hasError, false);

  // 深层网页有历史记录时，返回后退历史
  nav.settingsWeb = true;
  nav.settingsOpen = false;
  nav.hasError = false;
  nav.currentUrl = 'https://x.com/settings/subpage';
  const handledBack = nav.onBackPress();
  assert.equal(handledBack, true);
  assert.equal(backwardCalled, true);
  assert.equal(nav.settingsWeb, true);
}

// 5. 旧账号结果失效 (Stale account details invalidated when handle changes)
{
  const nav = new NavTestPage();
  let avatarReset = false;
  Object.assign(nav, {
    ownHandle: 'alice',
    accountName: 'Alice Old',
    accountBio: 'Old Bio',
    unreadNotifications: 5,
    unreadMessages: 2,
    badgeShown: 7,
    cancelProfileNavigation() {},
    resetAvatar() { avatarReset = true; },
    clearNetworkBadgeCounts() {},
    saveOwnHandle() {},
    restoreAvatar() {},
    readAvatar() {},
    finishDiscover() {}
  });

  // 账号改变时，清空资料、头像、未读计数
  nav.acceptHandle('bob', false);
  assert.equal(nav.ownHandle, 'bob');
  assert.equal(nav.accountName, '');
  assert.equal(nav.accountBio, '');
  assert.equal(nav.unreadNotifications, 0);
  assert.equal(nav.unreadMessages, 0);
  assert.equal(nav.badgeShown, -1);
  assert.equal(avatarReset, true);
}

// 6. 后台弹层不影响原生底栏 (Background web modal does not affect bottom bar when settingsOpen is true)
{
  const bgModalPage = new ModalPage();
  Object.assign(bgModalPage, {
    webModalOpen: false,
    settingsOpen: true,
    showsNativeNavigation: () => true,
    isWide: false,
    floatingBar: true,
    bottomInset: 24,
    syncChromeInsets() {},
    flushNetworkReload() {}
  });
  // 原生设置打开时，即使后台网页触发弹层，底栏高度保持不变
  assert.equal(bgModalPage.bottomChromeHeight(), 82);
  bgModalPage.updateWebModal(true);
  assert.equal(bgModalPage.bottomChromeHeight(), 82, '原生设置显示时后台弹层不得清空底栏高度');
  bgModalPage.settingsOpen = false;
  assert.equal(bgModalPage.bottomChromeHeight(), 0, '退出设置后正常响应网页弹层隐藏');
}

// 7. 排序及五项上限 (Reordering tabs and 5-item limit enforcement)
{
  const nav = new NavTestPage();
  const prefsSaved = [];
  let noticeTriggered = 0;
  Object.assign(nav, {
    tabOrder: [0, 1, 2, 3, 5, 4],
    enabledTabs: [0, 1, 2, 3, 4],
    putPreference: async (k, v) => { prefsSaved.push([k, v]); },
    toast: () => { noticeTriggered++; }
  });

  // 拖动排序
  await nav.reorderTabs([0, 3, 1, 2, 5, 4]);
  assert.deepEqual(nav.tabOrder, [0, 3, 1, 2, 5, 4]);
  assert.deepEqual(nav.enabledTabs, [0, 3, 1, 2, 4], '启用项顺序跟随新排列');
  assert.equal(prefsSaved.some(p => p[0] === 'tab_order'), true);

  // 必选项 (0, 1, 4) 不得被禁用
  await client.setTabEnabled(0, false);
  await client.setTabEnabled(1, false);
  await client.setTabEnabled(4, false);
  assert.ok(client.enabledTabs.includes(0));
  assert.ok(client.enabledTabs.includes(1));
  assert.ok(client.enabledTabs.includes(4));

  // 启用第 6 项受限
  client.enabledTabs = [0, 1, 2, 3, 4];
  const noticesBefore = notices;
  await client.setTabEnabled(5, true);
  assert.equal(notices, noticesBefore + 1, '达到 5 项上限时提示不能启用更多');
  assert.deepEqual(client.enabledTabs, [0, 1, 2, 3, 4]);
}

// 8. 偏好持久化 (Preference persistence: material_level, tab_order, enabled_tabs)
{
  const nav = new NavTestPage();
  const prefsMap = new Map();
  Object.assign(nav, {
    materialLevel: 'adaptive',
    putPreference: async (k, v) => { prefsMap.set(k, v); },
    toast() {}
  });

  await nav.setMaterialLevel('exquisite');
  assert.equal(nav.materialLevel, 'exquisite');
  assert.equal(prefsMap.get('material_level'), 'exquisite');
  assert.equal(nav.currentHdsMaterialLevel(), 1); // EXQUISITE

  await nav.setMaterialLevel('gentle');
  assert.equal(nav.currentHdsMaterialLevel(), 2); // GENTLE

  await nav.setMaterialLevel('smooth');
  assert.equal(nav.currentHdsMaterialLevel(), 3); // SMOOTH

  await nav.setMaterialLevel('adaptive');
  assert.equal(nav.currentHdsMaterialLevel(), 0); // ADAPTIVE
}

console.log('PASS: direct navigation, cancellation drawer cleanup, settings independence, back-to-settings, stale account invalidation, background modal isolation, reorder/5-limit, and preference persistence');
