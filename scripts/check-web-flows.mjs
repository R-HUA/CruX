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
const routes = load('WebConfig', ['routeIndexForUrl', 'profileHandleForUrl','usesNativeNavigation','usesNativeHeader','isTabRootPath','isPostDetailUrl','TWITTER_BOOKMARKS']);
const bookmarksPath = new URL(routes.TWITTER_BOOKMARKS).pathname;
assert.equal(routes.TWITTER_BOOKMARKS,'https://x.com/i/history','书签直接使用历史页的默认标签，避免旧入口重定向');
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
const scripts = load('WebChrome', ['fillComposerScript','clickPostButtonScript','POST_RESULT_SCRIPT','chromeScript','chromeFlagScript','chromeInsetsScript','chromeDocumentStartScript','chromeActiveScript','COMPOSER_READY_SCRIPT','ACCOUNT_SWITCH_SCRIPT','OWN_HANDLE_SCRIPT','profileBootstrapScript','clickRouteScript','cancelRouteScript','finishRouteScript','accountAvatarScript','accountAvatarDiagScript','PROFILE_LAYOUT_SCRIPT','PROFILE_MEDIA_SCRIPT','WEB_MODAL_SCRIPT']);
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
    return {tagName:'A',getAttribute:name=>name==='href'?href:null,hasAttribute:()=>false,getClientRects:()=>[{}],
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
    document:{head:{},documentElement:{},getElementById:()=>style,querySelector:()=>auth?{}:null,querySelectorAll:()=>[]},
    MutationObserver:class {constructor(callback){update=callback;}observe(){}disconnect(){}}
  };
  context.window.top=context.window;
  vm.runInNewContext(scripts.chromeDocumentStartScript(true),context);
  assert.equal(style.textContent.includes('FloatingActionButtons'),routes.usesNativeNavigation('https://x.com'+path),path);
  assert.equal(style.textContent.includes('TopNavBar'),routes.usesNativeHeader('https://x.com'+path),path);
  auth=true;update();assert.equal(style.textContent,'',path);
}
// head 尚未创建时，根节点即可承载隐藏顶栏的首屏样式。
let initialStyle;
const earlyContext={
  URL,window:{addEventListener(){}},location:{pathname:'/home',href:'https://x.com/home'},
  document:{head:null,documentElement:{appendChild:node=>{initialStyle=node;}},
    createElement:()=>({textContent:''}),getElementById:()=>initialStyle,querySelector:()=>null,querySelectorAll:()=>[]},
  MutationObserver:class {observe(){}disconnect(){}}
};
earlyContext.window.top=earlyContext.window;
vm.runInNewContext(scripts.chromeDocumentStartScript(true),earlyContext);
assert.ok(initialStyle.textContent.includes("header[role='banner']"));
// 回复直接使用当前详情的帖子编号，原帖是否被虚拟列表回收不影响面板显示。
const mainSource=readFileSync(new URL('../entry/src/main/ets/pages/MainTabs.ets',import.meta.url),'utf8');
const accountSource=readFileSync(new URL('../entry/src/main/ets/common/AccountSession.ets',import.meta.url),'utf8');
const unreadSource=readFileSync(new URL('../entry/src/main/ets/common/UnreadSession.ets',import.meta.url),'utf8');
const navigationSource=readFileSync(new URL('../entry/src/main/ets/common/WebNavigation.ets',import.meta.url),'utf8');
const accountMethod=name=>accountSource.match(new RegExp('^  (?:private )?(?:async )?'+name+'\\([\\s\\S]*?^  \\}', 'm'))[0];
const unreadMethod=name=>unreadSource.match(new RegExp('^  (?:private )?(?:async )?'+name+'\\([\\s\\S]*?^  \\}', 'm'))[0];
const navigationMethod=name=>navigationSource.match(new RegExp('^  (?:private )?(?:async )?'+name+'\\([\\s\\S]*?^  \\}', 'm'))[0];
const NavigationPage=vm.runInNewContext(stripTypeScriptTypes(navigationSource.replace(/^import .*;\r?\n/gm,'').replace('@Observed','')).replace(/^export /gm,'')+';WebNavigation',{
  clickRouteScript:scripts.clickRouteScript,cancelRouteScript:scripts.cancelRouteScript,finishRouteScript:scripts.finishRouteScript,unquoteScriptResult:value=>value,
  pathOf:url=>new URL(url).pathname,profileHandleForUrl:routes.profileHandleForUrl,
  Date,setTimeout,clearTimeout,
  hilog:{error(){},warn(){},info(){}},DOMAIN:0,TAG:'test',$r:value=>value
});
const navigationFor=(page,controller=page.controller)=>{
  const navigation=new NavigationPage();
  Object.assign(navigation,{currentUrl:page.navigation?.currentUrl??page.currentUrl??'',
    currentPath:page.navigation?.currentPath??page.currentPath??'',navigationGeneration:0,
    viewingHandle:'',failure:'none',progress:0,
    host:{isNetworkReady:()=>page.webNetworkReady!==false,controller:()=>controller,
      isControllerReady:()=>page.webControllerReady!==false,isActive:()=>page.pageAlive!==false&&!page.appBackground,
      documentStarted:url=>{page.pendingDocumentUrl=url;},routeSettled:()=>page.syncFromUrl?.(controller.getUrl?.()??navigation.currentUrl),
      cancelProfileNavigation:()=>page.account?.cancelProfileNavigation?.(),toast:value=>page.toast?.(value)}});
  return navigation;
};
const goRouteBody=mainSource.match(/private async goRoute\(index: number\): Promise<void> \{([\s\S]*?)\n  \}/)[1];
const goRoute=vm.runInNewContext(stripTypeScriptTypes('(async function(index){'+goRouteBody+'})'),{
  isTabRootPath:routes.isTabRootPath,routeIndexForUrl:routes.routeIndexForUrl,TWITTER_BASE:'https://x.com',TWITTER_ROUTES:['/home','/explore','/notifications','/i/chat'],scrollToTopScript:()=> 'scroll'});
const navigations=[],scrolls=[];
const navigationState={currentIndex:0,settingsOpen:false,settingsWeb:false,
  account:{settingsReadGeneration:0,cancelProfileNavigation(){}},tick(){},
  navigation:{currentPath:'/settings',cancel(){},loadWeb:async url=>{navigations.push(url);return 'arrived';}},
  webScript:async value=>scrolls.push(value)};
goRoute.call(navigationState,0);assert.deepEqual(navigations,['/home'],'二级页点击上次选中的标签仍须导航');
navigationState.navigation.currentPath='/home';goRoute.call(navigationState,0);assert.deepEqual(scrolls,['scroll']);
{
  let complete;
  const page={...navigationState,currentIndex:4,settingsOpen:true,
    account:{settingsReadGeneration:0,cancelProfileNavigation(){}},
    navigation:{currentPath:'/home',currentUrl:'https://x.com/explore',cancel(){},loadWeb:()=>new Promise(resolve=>{complete=resolve;})}};
  const pending=goRoute.call(page,1);assert.equal(page.settingsOpen,true);assert.equal(page.currentIndex,4);
  complete('failed');await pending;assert.equal(page.settingsOpen,true);assert.equal(page.currentIndex,4);
  const retry=goRoute.call(page,1);complete('arrived');await retry;
  assert.equal(page.settingsOpen,false);assert.equal(page.currentIndex,1);
  page.navigation.loadWeb=async()=> 'failed';await goRoute.call(page,2);
  assert.equal(page.currentIndex,0,'普通标签失败后按确认过的内容恢复，不能使用未确认的目标地址');
}
const modalMethods=['bottomChromeHeight','updateWebModal','modalBlocksNetworkReload'].map(name=>
  mainSource.match(new RegExp('^  private '+name+'\\([\\s\\S]*?^  \\}','m'))[0]).join('\n');
const ModalPage=vm.runInNewContext(stripTypeScriptTypes('class ModalPage{'+modalMethods+'};ModalPage'),{
  isSecondaryUrl:()=>false,isPostDetailUrl:()=>false,FLOATING_BAR_HEIGHT:58,BAR_HEIGHT:56});
const modalPage=new ModalPage();let insetChanges=0,resumedReloads=0;
Object.assign(modalPage,{webModalOpen:false,showsNativeNavigation:()=>true,isWide:false,floatingBar:true,bottomInset:24,
  navigation:{currentUrl:'https://x.com/home'},account:{discovering:false},composer:{sheetOpen:false},
  syncChromeInsets(){insetChanges++;},flushNetworkReload(){resumedReloads++;}});
assert.equal(modalPage.bottomChromeHeight(),82);
modalPage.updateWebModal(true);assert.equal(modalPage.bottomChromeHeight(),0);assert.equal(modalPage.modalBlocksNetworkReload(),true);
modalPage.updateWebModal(true);assert.equal(insetChanges,1);
modalPage.updateWebModal(false);assert.equal(modalPage.bottomChromeHeight(),82);assert.equal(resumedReloads,1);
const insetBody=mainSource.match(/private overlayTopInset\(\): number \{([\s\S]*?)\n  \}/)[1];
const topInset=vm.runInNewContext(stripTypeScriptTypes('(function(){'+insetBody+'})'),{
  HEADER_HEIGHT:56,HEADER_CONTENT_LIFT:4
});
const insetState={topInset:39,homeTabsHeight:28,navigation:{viewingHandle:''},overlaysWeb:()=>true,topChromeHeight:()=>56,isHomeRoot:()=>true};
assert.equal(topInset.call(insetState),77,'Home inset ends at the measured underline, not the full title bar');
insetState.homeTabsHeight=40;assert.equal(topInset.call(insetState),83,'Large text changes the measured boundary');
insetState.isHomeRoot=()=>false;assert.equal(topInset.call(insetState),95);
insetState.navigation.viewingHandle='alice';assert.equal(topInset.call(insetState),0,'Profile banner has no top inset');
insetState.navigation.viewingHandle='';assert.equal(topInset.call(insetState),95,'Leaving a profile restores the other page inset');
insetState.topChromeHeight=()=>0;assert.equal(topInset.call(insetState),0);
insetState.overlaysWeb=()=>false;assert.equal(topInset.call(insetState),0);

// 真实边界与滚动统一为 vp；标题和模糊独立变化，并连续反向恢复。
const profileMethods=['syncHeaderBlur','resetHeaderBlur','resetProfileLayout','receiveProfileLayout','profileBannerButtons'].map(name=>
  mainSource.match(new RegExp('^  private '+name+'\\([\\s\\S]*?^  \\}', 'm'))[0]).join('\n');
const ProfilePage=vm.runInNewContext(stripTypeScriptTypes('class ProfilePage{'+profileMethods+'};ProfilePage'),{
  HEADER_HEIGHT:56,HEADER_BLUR_DISTANCE:32,hilog:{error(){}},DOMAIN:0,TAG:''});
const profilePage=new ProfilePage();let blurOffset=0;
Object.assign(profilePage,{viewingHandle:'alice',webWidth:440,topInset:39,pageAlive:true,appBackground:false,rawWeb:false,
  currentUrl:'https://x.com/alice',webUrl:()=>profilePage.currentUrl,lastBlurOffset:0,
  blurScroller:{scrollTo:({yOffset,animation})=>{assert.equal(animation,false);blurOffset=yOffset;}}});
profilePage.navigation={get currentUrl(){return profilePage.currentUrl;},get viewingHandle(){return profilePage.viewingHandle;}};
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
{
  identityHeight=80;measure();profileContext.window.__otApplyTop=measure;
  const StatePage=vm.runInNewContext(stripTypeScriptTypes('class StatePage{'+
    mainSource.match(/^  private readPageState\([\s\S]*?^  \}/m)[0]+'};StatePage'),{
    MainTabs:{unquote:value=>value,stripSiteSuffix:value=>value},hilog:{warn(){}},DOMAIN:0,TAG:''});
  const page=new StatePage();
  Object.assign(page,{navigation:{currentUrl:'https://x.com/bob',viewingHandle:'bob',isNavigating:true},
    profileLayout:undefined,settingsOpen:false,pageAlive:true,appBackground:false,
    account:{readAvatar(){},discoverOwnProfile(){}},readHomeTab(){},isOwnProfile:()=>false,webCanGoBack:()=>true,
    webScript:async script=>script.includes('window.__otProfileLayout')?vm.runInNewContext(script,profileContext):'false'});
  const count=profileReports.length;page.readPageState();
  assert.equal(profileReports.length,count,'在途导航不提前更新原生主页布局');
  page.navigation.isNavigating=false;page.readPageState();
  assert.equal(profileReports.length,count+1,'确认到达后重报曾被忽略的同一份主页布局');
  page.profileLayout={};page.readPageState();assert.equal(profileReports.length,count+1,'已接收的主页布局不反复重报');
  await Promise.resolve();
}
// 控制器未绑定时所有方法同步抛错，覆盖重建与绑定之间的真实平台边界。
let recoveryTime=100000,applies=0;
const recoveryTasks=[];
class UnboundController {
  attached=false; calls=[]; url='https://x.com/home';
  call(name){assert.ok(this.attached,'17100001: '+name);this.calls.push(name);}
  runJavaScript(){this.call('script');return Promise.resolve('ok');}
  getUrl(){this.call('url');return this.url;}
  accessBackward(){this.call('history');return true;}
  setCustomUserAgent(){this.call('ua');}
  backward(){this.call('back');}
  loadUrl(url){this.call('load');this.url=url;}
  refresh(){this.call('refresh');}
}
const bridgeSource=mainSource.match(/^class PageBridge \{[\s\S]*?^\}/m)[0];
const recoveryMethod=name=>mainSource.match(new RegExp('^  (?:private )?(?:async )?'+name+'\\([\\s\\S]*?^  \\}','m'))[0];
const recoveryRuntime={Date:{now:()=>recoveryTime},Promise,DOMAIN:1,TAG:'test',
  hilog:{debug(){},info(){},error(){},warn(){}},$r:key=>key,
  isSiteUrl:url=>/^https:\/\/(?:www\.)?(?:x|twitter)\.com(?:\/|$)/.test(url),
  isAuthUrl:url=>/^https:\/\/accounts\.google\.com\//.test(url),
  web_webview:{WebviewController:UnboundController},NetworkConfig:{getInstance:()=>({ensureApplied(){applies++;}})},
  setTimeout:fn=>{recoveryTasks.push(fn);return 1;},ThemeColorMode:{DARK:1,LIGHT:2,SYSTEM:0},
  chromeInsetsScript:()=>'',appearanceScript:()=>'',MEDIA_CLICK_SCRIPT:'',chromeActiveScript:()=>''};
const RecoveryPage=vm.runInNewContext(stripTypeScriptTypes(bridgeSource+';class RecoveryPage{'+[
  'webScript','webUrl','webCanGoBack','applyUserAgent','documentStarted','reloadCurrent','recoverMediaWeb',
  'renderExited','flushRenderRecovery','modalBlocksNetworkReload','syncChromeInsets','onBackPress','createBridge','imageViewerChanged','interceptExternal'
].map(recoveryMethod).join('\n')+'};RecoveryPage'),recoveryRuntime);
const webCallback=(name,session=0)=>{
  const body=mainSource.slice(mainSource.indexOf('  webView(session: number)')).match(new RegExp('\\.'+name+'\\(\\((?:event|_old: Area, area: Area)\\) => \\{([\\s\\S]*?)\\n      \\}\\)'))[1];
  return vm.runInNewContext(stripTypeScriptTypes('(function(event,area){'+body+'})'),{...recoveryRuntime,session});
};
const begin=webCallback('onPageBegin'),receiveError=webCallback('onErrorReceive'),pageEnd=webCallback('onPageEnd');
const renderExited=webCallback('onRenderExited');
const errorState=new RecoveryPage();
Object.assign(errorState,{webSession:0,webControllerReady:true,webNetworkReady:true,pendingDocumentUrl:'',
  webSource:'https://x.com/home',controller:new UnboundController(),pageAlive:true,appBackground:false,
  failedWebUrl:'',imageViewerOpen:true,lastRenderRecovery:0,renderRecoveryPending:false,retrying:false,
  incomingPageReady:false,incomingContent:{kind:''},webWidth:400,
  navigation:{failure:'none',progress:0,currentUrl:'https://x.com/home',viewingHandle:'',navigationGeneration:0,
    cancel(){this.navigationGeneration++;},get hasError(){return this.failure!=='none';}},
  account:{discovering:false,cancelProfileNavigation(){},retryFailedAvatar(){}},composer:{sheetOpen:false},
  resetProfileLayout(){this.reset=true;},armFirstLoadTimeout(){},updateWebModal(){},userAgent:()=>'',
  finishFirstLoad(){this.firstLoadDone=true;this.documentLoading=false;},toast(){},syncFromUrl(){},
  applyPageChrome(){},schedulePageStateRead(){},saveWebSession(){},overlaysWeb:()=>false,overlayTopInset:()=>0,
  bottomChromeHeight:()=>0});
errorState.controller.attached=true;
// 设备时间线：图片拖拽形成 file 主框架导航，必须在 ArkWeb 提交错误页前取消。
const draggedFile='file:///data/storage/el2/base/cache/segmented-image.png';
const intercepted=[];
errorState.openExternal=target=>{intercepted.push(target);};
const loadRequest=(target,mainFrame=true)=>({data:{getRequestUrl:()=>target,isMainFrame:()=>mainFrame}});
for(const target of [draggedFile,'FILE:///data/image.png']) {
  assert.equal(errorState.interceptExternal(loadRequest(target)),true,'取消图片拖入引起的本地文件导航');
}
assert.equal(errorState.interceptExternal(loadRequest(draggedFile,false)),false,'不接管子资源请求');
for(const target of ['https://x.com/home','https://twitter.com/alice','https://accounts.google.com/o/oauth2/auth']) {
  assert.equal(errorState.interceptExternal(loadRequest(target)),false,'站内与登录导航保持放行');
}
assert.equal(errorState.interceptExternal(loadRequest('https://example.com/article')),true);
assert.deepEqual(intercepted,['https://example.com/article']);
const routeReports=[];
errorState.syncFromUrl=url=>routeReports.push(url);
// 即使平台补发本地地址的生命周期事件，也不能污染失败地址、路由或重试目标。
const initialBridge=errorState.createBridge(0);
for(const url of [draggedFile,'arkweb-error://webdata/']) {
  begin.call(errorState,{url});
  assert.equal(errorState.failedWebUrl,'');
  assert.equal(errorState.pendingDocumentUrl,'');
  initialBridge.onUrlChange('main',url);
  errorState.controller.url=url;
  pageEnd.call(errorState,{url});
  assert.equal(errorState.failedWebUrl,'');
  assert.equal(errorState.incomingPageReady,false);
}
assert.deepEqual(routeReports,[]);
assert.equal(errorState.navigation.currentUrl,'https://x.com/home');
assert.equal(errorState.webSource,'https://x.com/home');
errorState.controller.url='https://x.com/home';
console.log('PASS: dragged file navigation is cancelled and cannot replace route or retry targets');
begin.call(errorState,{url:'https://x.com'});
assert.equal(errorState.reset,true);assert.equal(errorState.documentLoading,true);
// 重定向结束仍清空待加载地址，随后迟到的主框架错误不能覆盖已有页面。
pageEnd.call(errorState,{url:'https://x.com/home'});
assert.equal(errorState.pendingDocumentUrl,'');assert.equal(errorState.documentLoading,false);
const failure=(url,mainFrame=true,code=-105)=>({
  request:{getRequestUrl:()=>url,isMainFrame:()=>mainFrame},error:{getErrorCode:()=>code}
});
for(const event of [failure('https://pbs.twimg.com/media/photo.jpg'),failure('https://x.com/explore'),
  failure('https://x.com/home',false),failure('https://x.com/home',true,-3)]){
  receiveError.call(errorState,event);
  assert.equal(errorState.navigation.hasError,false);
  assert.equal(errorState.failedWebUrl,'');
}
receiveError.call(errorState,failure('https://x.com/home'));
assert.equal(errorState.navigation.hasError,false,'文档结束后的错误不盖页面');
errorState.documentStarted('https://x.com/alice#posts');
receiveError.call(errorState,failure('https://x.com/home'));
assert.equal(errorState.navigation.hasError,false,'新导航期间忽略上一页的延迟错误');
receiveError.call(errorState,failure('https://x.com/alice'));
assert.equal(errorState.navigation.hasError,true,'新文档失败时控制器仍指向旧地址也必须显示错误');
assert.equal(errorState.failedWebUrl,'https://x.com/alice');
errorState.controller.getUrl=()=> 'https://x.com/alice';
errorState.navigation.currentUrl='https://x.com/alice';
pageEnd.call(errorState,{url:'https://x.com/alice'});
assert.equal(errorState.navigation.hasError,true);
assert.equal(errorState.incomingPageReady,false,'失败后的结束回调不能假报网页可用');
errorState.webSession=1;errorState.navigation.failure='none';errorState.failedWebUrl='';
for(const [callback,event] of [[receiveError,failure('https://x.com/alice')],[renderExited,{detail:1}],
  [pageEnd,{url:'https://x.com/alice'}],[begin,{url:'https://x.com/alice'}]]){
  callback.call(errorState,event);
  assert.equal(errorState.navigation.hasError,false,'旧 WebView 回调不能破坏重试后新建的页面');
  assert.equal(errorState.failedWebUrl,'');
}
errorState.webSession=0;
errorState.bridge=errorState.createBridge(0);
const oldBridge=errorState.bridge;
renderExited.call(errorState,{detail:1});
assert.equal(errorState.navigation.hasError,false,'查看器打开时渲染退出不覆盖图片');
assert.equal(errorState.renderRecoveryPending,true);assert.equal(errorState.webSession,0);
errorState.imageViewerOpen=false;errorState.imageViewerChanged();recoveryTasks.shift()();
assert.equal(errorState.webSession,1,'关闭查看器后只重建一次');
const rebuilding=errorState.controller;
webCallback('onAreaChange',1).call(errorState,null,{width:400});
oldBridge.onTheme('main','rgb(1, 2, 3)');
errorState.bridge.onTheme('main','rgb(1, 2, 3)');
errorState.settingsWeb=true;assert.equal(errorState.onBackPress(),true);errorState.settingsWeb=false;
errorState.reloadCurrent();errorState.reloadCurrent();
assert.equal(errorState.webSession,1);assert.deepEqual(rebuilding.calls,[]);
await assert.rejects(errorState.webScript('test'),/not attached/);
assert.equal(errorState.webUrl(),'');assert.equal(errorState.webCanGoBack(),false);
errorState.webControllerReady=true;rebuilding.attached=true;
oldBridge.onTheme('main','rgb(1, 2, 3)');assert.deepEqual(rebuilding.calls,[],'旧代理绑定后仍被拒绝');
begin.call(errorState,{url:'https://x.com/home'}); // 旧回调不能解除新会话的重试锁。
assert.equal(errorState.retrying,true);
webCallback('onPageBegin',1).call(errorState,{url:'https://x.com/home'});assert.equal(errorState.retrying,false);
// 30 秒内再次退出才显示渲染错误；手动重试也防止重复重建。
webCallback('onRenderExited',1).call(errorState,{detail:1});assert.equal(errorState.navigation.failure,'render');
errorState.reloadCurrent();errorState.reloadCurrent();assert.equal(errorState.webSession,2);assert.equal(applies,0);
errorState.webControllerReady=true;errorState.controller.attached=true;errorState.retrying=false;
errorState.navigation.failure='document';errorState.failedWebUrl='https://x.com/alice';
errorState.reloadCurrent();errorState.reloadCurrent();
assert.equal(errorState.webSession,2);assert.deepEqual(errorState.controller.calls,['load']);assert.equal(applies,0);
// 同步的平台异常转为拒绝的 Promise；布局及异步调用方可以统一捕获。
errorState.controller.attached=false;
await assert.rejects(errorState.webScript('test'),/17100001/);
console.log('PASS: document errors, redirects, deferred render recovery, unbound controller and retry deduplication');
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
const composerSource=readFileSync(new URL('../entry/src/main/ets/common/ComposerSession.ets',import.meta.url),'utf8');
const replySessionMethods=['openReply','resetController'].map(name=>composerSource.match(new RegExp('^  '+name+'\\([\\s\\S]*?^  \\}', 'm'))[0]).join('\n');
const ReplySession=vm.runInNewContext(stripTypeScriptTypes('class ReplySession{'+replySessionMethods+'};ReplySession'),{
  TWITTER_BASE:'https://x.com',web_webview:{WebviewController:class{}}
});
const replyState={navigation:{currentPath:'/alice/status/123'},composer:new ReplySession()};
reply.call(replyState);
assert.equal(replyState.composer.sheetOpen,true);
assert.equal(replyState.composer.composeUrl,'https://x.com/intent/tweet?in_reply_to=123');
assert.equal(replyState.composer.webComposer,true);assert.equal(replyState.composer.composeLoading,true);
assert.equal(replyState.composer.composeOwner,'');
const replyController=replyState.composer.composeController;
reply.call(replyState);assert.equal(replyState.composer.composeController,replyController);
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
assert.equal(vm.runInNewContext(scripts.OWN_HANDLE_SCRIPT,{window:{},document:accountDocument}),'');
const accountContext={window:{},document:accountDocument,setTimeout:()=>1,clearTimeout(){},
  MutationObserver:class{constructor(callback){accountChanged=callback;}observe(){}disconnect(){}}};
assert.equal(vm.runInNewContext(scripts.profileBootstrapScript(false),accountContext),'armed');
assert.equal(accountContext.window.__otBoot,'alice');assert.equal(menuOpen,false);assert.equal(clicks,2);
menuOpen=true;assert.equal(vm.runInNewContext(scripts.OWN_HANDLE_SCRIPT,{window:{},document:accountDocument}),'alice');
ambiguous=true;dialog.textContent='@alice @bob';
assert.equal(vm.runInNewContext(scripts.OWN_HANDLE_SCRIPT,{window:{},document:accountDocument}),'');
ambiguous=false;menuOpen=false;
assert.equal(vm.runInNewContext(scripts.profileBootstrapScript(true),accountContext),'armed');
assert.equal(profileClicks,1);assert.equal(menuOpen,false);
profileReady=false;
assert.equal(vm.runInNewContext(scripts.profileBootstrapScript(false),accountContext),'armed');
assert.equal(accountContext.window.__otBoot,'');
profileReady=true;accountChanged();
assert.equal(accountContext.window.__otBoot,'alice');assert.equal(menuOpen,false);
// 保留真实地址与已渲染内容两份独立状态，不能通过改地址让夹具自动切页。
function routeRuntime(start='/home') {
  const listeners=new Map(),stack=[{url:'https://x.com'+start,state:{key:'source'}}];
  let cursor=0,rendered=start,heading=start,landmark={},links=[],identities;
  const emit=(type,event)=>{for(const fn of [...(listeners.get(type)||[])])fn(event);};
  const window={addEventListener(type,fn){if(!listeners.has(type))listeners.set(type,new Set());listeners.get(type).add(fn);},
    removeEventListener(type,fn){listeners.get(type)?.delete(fn);},dispatchEvent(event){emit(event.type,event);}};
  class MouseEvent {constructor(type,options){this.type=type;Object.assign(this,options);this.defaultPrevented=false;}preventDefault(){this.defaultPrevented=true;}}
  const location={href:stack[0].url,get origin(){return new URL(this.href).origin;}};
  const link=(href,handle)=>({tagName:'A',hasAttribute:()=>false,getAttribute:name=>name==='href'?href:name==='aria-current'?'page':null,
    dispatchEvent(event){handle?.(event);emit('click',event);assert.equal(event.defaultPrevented,true);}});
  const main={querySelectorAll(selector){
      if(selector==='h1,h2,[role="heading"]')return [{textContent:heading}];
      if(selector==='[data-testid="UserName"]')return identities||[{textContent:'30225094@'+rendered.split('/')[1],closest:()=>null}];
      if(selector==='a[aria-current],a[aria-selected="true"]')return [link(rendered)];
      if(selector==='article[data-testid="tweet"] a[href]')return rendered.includes('/status/')?[link(rendered)]:[];
      throw Error('unexpected content selector: '+selector);
    },querySelector(selector){
      if(selector==='[data-testid="UserName"]')return {textContent:'@'+rendered.split('/')[1]};
      if(selector==='[data-testid="SearchBox_Search_Input"]')return {value:new URL(rendered,location.href).searchParams.get('q')||''};
      return landmark;
    }};
  const document={title:start+' / X',querySelector:()=>main,querySelectorAll(selector){
    assert.equal(selector,'a[href]','日常导航只查找最终链接，不查菜单');return links;
  }};
  const history={get state(){return stack[cursor].state;},pushes:0,backs:0,
    pushState(state,_unused,path){this.pushes++;stack.splice(++cursor);stack.push({url:new URL(path,location.href).href,state});location.href=stack[cursor].url;},
    back(){this.backs++;if(cursor>0){location.href=stack[--cursor].url;emit('popstate',{type:'popstate',state:this.state});}}};
  const context={URL,window,location,document,history,MouseEvent,PopStateEvent:MouseEvent};
  const run=script=>vm.runInNewContext(script,context);
  return {context,window,location,history,link,run,setLinks(value){links=value;},
    render(path,empty=false){rendered=path;heading=path;landmark={empty};document.title=path+' / X';},
    setHeading(value){heading=value;},setIdentities(value){identities=value;},
    step(path,id=1,documentId=''){return JSON.parse(run(scripts.clickRouteScript(new URL(path,location.href).href,id,documentId)));},
    controller:{getUrl:()=>location.href,runJavaScript:async script=>run(script),loadUrl(){throw Error('SPA 不得加载新文档');}}};
}
{
  const runtime=routeRuntime();let clicks=0;
  runtime.setLinks([runtime.link('/i/chat',event=>{event.preventDefault();clicks++;})]);
  assert.equal(runtime.step('/i/chat').status,'pending');
  assert.equal(runtime.step('/i/chat').status,'pending');
  assert.equal(clicks,1,'已接管链接不重复点击');assert.equal(runtime.history.pushes,0,'已接管后不再补发 History');
  runtime.location.href='https://x.com/i/chat';assert.equal(runtime.step('/i/chat').status,'pending','旧内容不能因地址改变而成功');
  runtime.context.document.title='/i/chat / X';assert.equal(runtime.step('/i/chat').status,'pending','仅更新标题仍不能用旧内容冒充到达');
  runtime.context.document.title='/home / X';
  runtime.render('/i/chat');assert.equal(runtime.step('/i/chat').status,'arrived');
  runtime.run(scripts.finishRouteScript(1,false));
}
{
  const runtime=routeRuntime();runtime.step('/rhua0016');runtime.render('/rhua0016');
  runtime.context.document.title='/home / X';runtime.setHeading('/home');
  assert.equal(runtime.step('/rhua0016').status,'arrived','真实账号标识已经到达时不依赖标题同步变化，数字显示名不能阻断账号匹配');
}
{
  const runtime=routeRuntime();runtime.step('/rhua0016');runtime.render('/rhua0016');
  runtime.setIdentities([{textContent:'@rhua0016',closest:()=>({tagName:'ARTICLE'})}]);
  assert.equal(runtime.step('/rhua0016').evidence,'profile_identity_missing','时间线里的本人帖子不能冒充主页身份区');
  runtime.setIdentities([{textContent:'@other',closest:()=>null},{textContent:'30225094@rhua0016',closest:()=>null}]);
  assert.equal(runtime.step('/rhua0016').status,'arrived','检查真实资料身份区，而不是仅检查第一个账号节点');
}
for(const path of [bookmarksPath,'/i/history/likes','/rhua0016/lists','/settings/account',
  '/settings/security_and_account_access','/settings/privacy_and_safety','/settings/notifications',
  '/settings/accessibility_display_and_languages','/settings/about']){
  const runtime=routeRuntime();runtime.step(path);runtime.render(path,true);
  runtime.context.document.title='/home / X';
  assert.equal(runtime.step(path).status,'arrived','标题更新滞后时，目标内容及页面标题节点仍可确认到达: '+path);
}
{
  const runtime=routeRuntime();runtime.setLinks([runtime.link('/explore')]);
  const reply=runtime.step('/explore');assert.equal(reply.method,'history');assert.equal(reply.status,'pending');
  assert.equal(runtime.history.pushes,1);assert.notEqual(runtime.history.state.key,'source');
  runtime.step('/explore',1,reply.document);assert.equal(runtime.history.pushes,1,'轮询不重复 pushState');
  runtime.render('/explore',true);assert.equal(runtime.step('/explore').status,'arrived','空列表也可完成切页');
}
for(const path of ['/home','/explore','/notifications','/i/chat','/alice','/alice/with_replies','/alice/media',
  bookmarksPath,'/i/history/likes','/alice/lists','/settings/account','/settings/security_and_account_access',
  '/settings/privacy_and_safety','/settings/notifications','/settings/accessibility_display_and_languages',
  '/settings/about','/search?q=one','/alice/status/123']){
  const runtime=routeRuntime('/other');
  assert.equal(runtime.step(path).status,'pending',path);
  runtime.render(path);assert.equal(runtime.step(path).status,'arrived',path);
  assert.equal(runtime.history.pushes,1,path);
}
{
  const runtime=routeRuntime('/search?q=old');const target='/search?q=new#results';
  const first=runtime.step(target);assert.equal(first.status,'pending');
  runtime.render('/search?q=old');assert.equal(runtime.step(target).status,'pending','搜索参数须与页面输入一致');
  runtime.render(target);assert.equal(runtime.step(target).status,'arrived');
  assert.equal(runtime.step(target,1,'other-document').status,'document_changed');
}
{
  const runtime=routeRuntime();runtime.step('/i/bookmarks');runtime.run(scripts.finishRouteScript(1,true));
  assert.equal(runtime.history.backs,1);assert.equal(runtime.location.href,'https://x.com/home');
  runtime.step('/i/history/likes',2);runtime.run(scripts.cancelRouteScript(3));
  runtime.run(scripts.finishRouteScript(2,true));assert.equal(runtime.history.backs,1,'新请求取消后旧请求不得回退');
  assert.equal(runtime.step('/i/history/likes',2).status,'cancelled');
  assert.equal(runtime.step('/i/history/likes',3).status,'pending','取消后同一目标的旧内容不能按原地导航成功');
}
{
  const runtime=routeRuntime();runtime.step('/i/bookmarks');runtime.history.back();
  assert.equal(runtime.step('/i/bookmarks').status,'cancelled','用户返回后不能重新发出旧导航');
  runtime.run(scripts.finishRouteScript(1,true));assert.equal(runtime.history.backs,1);
}
{
  const runtime=routeRuntime();runtime.step('/i/bookmarks');
  runtime.location.href=routes.TWITTER_BOOKMARKS;runtime.render(bookmarksPath,true);
  assert.equal(runtime.step('/i/bookmarks').status,'redirected','旧书签地址重定向后仍须按完整目标检查，入口应直接使用最终地址');
}
{
  const runtime=routeRuntime();runtime.step('/i/bookmarks');runtime.location.href='https://x.com/i/flow/login';
  assert.equal(runtime.step('/i/bookmarks').status,'redirected');
  runtime.run(scripts.finishRouteScript(1,true));assert.equal(runtime.history.backs,0,'重定向不能盲目回退');
  assert.equal(runtime.step('https://example.com/home',2).status,'cross_origin');
}
{
  const runtime=routeRuntime(),notices=[];
  const page={controller:runtime.controller,toast:value=>notices.push(value)};
  const nav=navigationFor(page);nav.host.routeSettled=()=>nav.syncFromUrl(runtime.location.href);
  const pending=nav.loadWeb('https://x.com/i/bookmarks');
  await new Promise(resolve=>setTimeout(resolve,0));
  assert.equal(nav.isNavigating,true);nav.syncFromUrl(runtime.location.href);
  assert.equal(nav.currentPath,'','地址已经更新时不提前提交原生栏');
  assert.equal(nav.interceptDocument(),true);
  assert.equal(await pending,'failed');assert.equal(runtime.history.backs,1);assert.equal(notices.length,1);
  assert.equal(nav.interceptDocument(),false);
}
{
  const runtime=routeRuntime(),page={controller:runtime.controller,toast(){}};
  const nav=navigationFor(page);nav.syncFromUrl(runtime.location.href);
  nav.host.routeSettled=()=>nav.syncFromUrl(runtime.location.href);
  runtime.setLinks([runtime.link('/explore',event=>{event.preventDefault();runtime.location.href='https://x.com/explore';})]);
  const pending=nav.loadWeb('https://x.com/explore');
  await new Promise(resolve=>setTimeout(resolve,0));nav.interceptDocument();
  assert.equal(await pending,'failed');assert.equal(nav.currentPath,'/home');
  nav.syncFromUrl(runtime.location.href);
  assert.equal(nav.currentUrl,'https://x.com/explore');assert.equal(nav.currentPath,'/home','失败后的地址回调不能确认旧内容');
  nav.syncFromUrl(runtime.location.href,true);assert.equal(nav.currentPath,'/explore','显式文档加载完成可重新确认地址');
}
{
  const runtime=routeRuntime(),page={controller:runtime.controller,toast(){}};
  const nav=navigationFor(page);let release;
  nav.host.cancelProfileNavigation=()=>new Promise(resolve=>{release=resolve;});
  const pending=nav.loadWeb('https://x.com/explore');
  nav.cancel();assert.equal(await pending,'cancelled','取消不能被主页清理回调阻塞');
  release();assert.equal(runtime.history.pushes,0);
}
{
  const runtime=routeRuntime(),page={controller:runtime.controller,toast(){}};
  const nav=navigationFor(page);let release;
  const run=runtime.controller.runJavaScript;
  runtime.controller.runJavaScript=script=>script.includes('(target,id,expectedDocument,sourceUrl)')
    ?new Promise(resolve=>{release=()=>resolve(run(script));}):run(script);
  const first=nav.loadWeb('https://x.com/explore');await new Promise(resolve=>setTimeout(resolve,0));
  runtime.controller.runJavaScript=run;
  const second=nav.loadWeb('https://x.com/notifications');
  assert.equal(await first,'cancelled');release();
  await new Promise(resolve=>setTimeout(resolve,0));runtime.render('/notifications');
  assert.equal(await second,'arrived','迟到的旧脚本不能清理新请求或覆盖页面');
  assert.equal(runtime.history.pushes,1);assert.equal(runtime.history.backs,0);
}
for(const change of ['return','background','controller','account']){
  const runtime=routeRuntime();const page={controller:runtime.controller,toast(){throw Error('取消不应提示失败');}};
  const nav=navigationFor(page);nav.host.controller=()=>page.controller;
  const pending=nav.loadWeb('https://x.com/i/history/likes');
  await new Promise(resolve=>setTimeout(resolve,0));
  if(change==='background')page.appBackground=true;
  if(change==='controller')page.controller={runJavaScript:async()=>'',loadUrl(){throw Error('no document');}};
  nav.cancel();assert.equal(await pending,'cancelled',change);assert.equal(runtime.history.backs,0,change);
}
{
  const runtime=routeRuntime(),page={controller:runtime.controller,toast(){throw Error('已到达主页不能提示失败');}};
  const nav=navigationFor(page);nav.syncFromUrl(runtime.location.href);
  nav.host.routeSettled=()=>nav.syncFromUrl(runtime.location.href);
  const pending=nav.loadWeb('https://x.com/rhua0016');await new Promise(resolve=>setTimeout(resolve,0));
  runtime.render('/rhua0016');runtime.setHeading('/home');runtime.context.document.title='/home / X';
  assert.equal(await pending,'arrived');assert.equal(nav.currentPath,'/rhua0016');assert.equal(nav.viewingHandle,'rhua0016');
  assert.equal(runtime.history.backs,0,'实际主页已到达时不回退首页');
}
{
  const runtime=routeRuntime(),notices=[];const page={controller:runtime.controller,toast:value=>notices.push(value)};
  const nav=navigationFor(page);nav.host.routeSettled=()=>nav.syncFromUrl(runtime.location.href);
  assert.equal(await nav.loadWeb('https://x.com/i/bookmarks'),'failed','旧内容保持三秒须超时失败');
  assert.equal(runtime.history.pushes,1);assert.equal(runtime.history.backs,1);assert.equal(notices.length,1);
}
console.log('PASS: SPA final links, History once, stale content, empty pages, route parameters, cancellation, rollback and document blocking');
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
const defaultAvatar='https://abs.twimg.com/sticky/default_profile_images/default_profile_normal.png';
avatarContext.document.querySelectorAll=selector=>selector.startsWith('[data-testid="DashButton_ProfileIcon_Link"]')?
  [avatarRoot(defaultAvatar),avatarRoot(ownAvatar)]:[];
assert.equal(vm.runInNewContext(scripts.accountAvatarScript(''),avatarContext),ownAvatar,'跳过临时默认图继续读取真实头像');
avatarContext.document.querySelectorAll=selector=>selector.startsWith('[data-testid="DashButton_ProfileIcon_Link"]')?
  [avatarRoot(defaultAvatar)]:[];
assert.equal(vm.runInNewContext(scripts.accountAvatarScript(''),avatarContext),'');
avatarContext.document.querySelectorAll=selector=>selector.startsWith('[data-testid="DashButton_ProfileIcon_Link"]')?
  [{...avatarRoot(''),querySelectorAll:()=>[{currentSrc:defaultAvatar,getAttribute:name=>name==='src'?ownAvatar:''}]}]:[];
assert.equal(vm.runInNewContext(scripts.accountAvatarScript(''),avatarContext),ownAvatar,'currentSrc 为默认图时仍读取 src');
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
  navigation:{currentUrl:'https://x.com/home'},tabsController:{applyHideAnimation:()=>animations.push('hide'),
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
for(const excluded of [{isWide:true},{autoHideBar:false},{navigation:{currentUrl:'https://x.com/alice/status/123'}}]){
  startCollapsed();Object.assign(scroll,excluded);sample(500);sample(600);assert.equal(scroll.barsCollapsed,false);
  assert.deepEqual(animations,['show']);
  Object.assign(scroll,{isWide:false,autoHideBar:true,navigation:{currentUrl:'https://x.com/home'}});
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
const pillState={firstLoadDone:true,navigation:{hasError:false,currentUrl:'https://x.com/alice/about',currentPath:'/alice/about'},
  authenticationPage:false,composer:{sheetOpen:false},account:{discovering:false},
  showsNativeNavigation:()=>false,isMediaViewer:()=>false};
for(const path of ['/alice/about','/settings','/settings/your_twitter_data/account','/unknown/path']){
  pillState.navigation.currentPath=path;pillState.navigation.currentUrl='https://x.com'+path;
  assert.equal(pill.call(pillState),false,path);
}
pillState.authenticationPage=true;
assert.equal(pill.call(pillState),false,'A stale auth read cannot expose the pill on a normal page');
pillState.authenticationPage=false;
for(const path of ['/','/login','/signup','/i/flow/login','/i/flow/signup']){
  pillState.navigation.currentPath=path;pillState.navigation.currentUrl='https://x.com'+path;
  assert.equal(pill.call(pillState),true,path);
}
pillState.navigation.currentPath='/unknown/path';pillState.navigation.currentUrl='https://x.com/unknown/path';
pillState.firstLoadDone=false;assert.equal(pill.call(pillState),true);
pillState.firstLoadDone=true;pillState.navigation.hasError=true;assert.equal(pill.call(pillState),false,'错误页已有网络设置，不重复显示悬浮入口');
pillState.rawWeb=true;assert.equal(pill.call(pillState),false,'直接网页模式同样只保留错误页设置入口');
pillState.rawWeb=false;pillState.navigation.hasError=false;
pillState.showsNativeNavigation=()=>true;assert.equal(pill.call(pillState),false);
pillState.showsNativeNavigation=()=>false;
for(const state of ['fullScreen','imageViewerOpen','networkOpen','settingsOpen','discovering']) {
  if(state==='discovering')pillState.account.discovering=true;
  else pillState[state]=true;
  assert.equal(pill.call(pillState),false,state);
  if(state==='discovering')pillState.account.discovering=false;
  else pillState[state]=false;
}
pillState.composer.sheetOpen=true;assert.equal(pill.call(pillState),false,'sheetOpen');pillState.composer.sheetOpen=false;
pillState.rawWeb=true;assert.equal(pill.call(pillState),true,'Original web mode keeps its return entry');

// 头像下载、缓存和异步状态测试见 check-avatar-loading.mjs，使用生产下载器覆盖平台 I/O 边界。

function posting({ disabled=false, missing=false, throws=false, hook=true }={}) {
  let clicks=0; let timeout;
  const button={disabled,getAttribute:()=>null,click(){clicks++;if(throws)throw Error('click');}};
  const window={};
  if(hook)window.__otBeginPost=owner=>{assert.equal(owner,'alice');window.__otPostState='submitted';window.__otPostToken=1;return 1;};
  const context={window,document:{querySelector:()=>missing?null:button,
    querySelectorAll(){throw Error('发布结果不能再读取 Toast');}},setTimeout(callback){timeout=callback;}};
  return {run:()=>vm.runInNewContext(scripts.clickPostButtonScript('alice'),context),window,
    count:()=>clicks,expire:()=>timeout()};
}
let p=posting();assert.equal(p.run(),'submitted');assert.equal(p.window.__otPostState,'submitted');
assert.equal(p.run(),'unknown');assert.equal(p.count(),1);
p.expire();assert.equal(p.window.__otPostState,'unknown');
p=posting();p.run();p.window.__otPostState='confirmed';p.expire();assert.equal(p.window.__otPostState,'confirmed');
p=posting({disabled:true});assert.equal(p.run(),'disabled');assert.equal(p.count(),0);
p=posting({missing:true});assert.equal(p.run(),'missing');assert.equal(p.count(),0);
p=posting({hook:false});assert.equal(p.run(),'unavailable');assert.equal(p.count(),0);
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
const fabState={navigation:{currentPath:'/home',hasError:false},isHomeRoot,showsNativeNavigation:()=>true,firstLoadDone:true};
assert.equal(fabVisible.call(fabState),true);
for (const path of ['/explore','/search','/notifications','/i/chat','/messages/compose','/alice','/alice/status/123','/settings']) {
  fabState.navigation.currentPath=path;assert.equal(fabVisible.call(fabState),false,path);
}
fabState.navigation.currentPath='/home';fabState.navigation.hasError=true;assert.equal(fabVisible.call(fabState),false);
fabState.navigation.hasError=false;fabState.firstLoadDone=false;assert.equal(fabVisible.call(fabState),false);
// 新草稿使旧异步校验失效，后台不再发起校验。
let syncTask, resolveFill;
const composeValidationContext={DRAFT_SAVE_DEBOUNCE_MS:700,COMPOSER_READY_SCRIPT:scripts.COMPOSER_READY_SCRIPT,
  fillComposerScript:scripts.fillComposerScript,$r:key=>key,unquoteScriptResult:value=>value,
  clearTimeout(){},setTimeout:callback=>{syncTask=callback;return 1;},hilog:{warn(){}},DOMAIN:1,TAG:'test'};
const method=name=>composerSource.match(new RegExp('private '+name+'\\([^)]*\\): void \\{([\\s\\S]*?)\\n  \\}'))[1];
const syncCompose=vm.runInNewContext(stripTypeScriptTypes('(function(){'+method('scheduleComposeSync')+'})'),composeValidationContext);
const clearCompose=vm.runInNewContext(stripTypeScriptTypes('(function(){'+method('clearComposeSync')+'})'),composeValidationContext);
const composing={composeRevision:0,composeSyncTimer:-1,alive:true,appBackground:false,sheetOpen:true,webComposer:false,
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
Object.assign(client,{enabledTabs:[0,1,2,3,4],currentIndex:0,settingsReadGeneration:0,
  account:{discovering:false,settingsReadGeneration:0,accountName:'Alice',accountLoading:false,accountError:false,
    cancelProfileNavigation(){}},incomingPageReady:true,resetChromeScroll(){},resetProfileLayout(){},
  putPreference:async(key,value)=>{if(failedSave)throw Error('disk');saved.push([key,value]);},toast(){notices++;}});
client.navigation=navigationFor({...client,currentUrl:'https://x.com/home',toast:client.toast},
  {loadUrl:url=>{client.loaded=url;},runJavaScript:async()=>''});
client.navigation.host.controller=()=>({loadUrl:url=>{client.loaded=url;},runJavaScript:async()=>''});
client.navigation.loadWeb=async url=>{client.loaded=url;return 'arrived';};
client.openSettings();assert.equal(client.currentIndex,4);assert.equal(client.settingsOpen,true);
client.syncFromUrl('https://x.com/alice');assert.equal(client.currentIndex,4,'后台读取本人资料不抢占设置标签');
client.openSettingsRoute('/settings/notifications');client.syncFromUrl('https://x.com/settings/notifications');
assert.equal(client.currentIndex,4,'设置子页保持来源标签');
client.settingsOpen=true;await client.leaveSettings();assert.equal(client.currentIndex,0);assert.equal(client.loaded,'https://x.com/home');
client.openSettings();client.navigation.loadWeb=async()=> 'failed';
await client.leaveSettings();assert.equal(client.settingsOpen,true);assert.equal(client.currentIndex,4,'返回来源失败时保留设置界面');
client.navigation.loadWeb=async()=> 'arrived';await client.leaveSettings();
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
const navMethods = ['openSettingsRoute', 'openOwnProfile', 'onBackPress', 'reorderTabs', 'setMaterialLevel', 'currentHdsMaterialLevel'].map(name =>
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
NavTestPage.prototype.webControllerReady=true;
NavTestPage.prototype.webScript=async function(script){return this.controller.runJavaScript(script);};
NavTestPage.prototype.webCanGoBack=function(){return this.controller.accessBackward();};

const accountMethods=['closeWebDrawer','cancelProfileNavigation','acceptHandle','finishDiscover'].map(accountMethod).join('\n');
const AccountPage=vm.runInNewContext(stripTypeScriptTypes('class AccountPage{'+accountMethods+'};AccountPage'),{
  profileUrl:handle=>'https://x.com/'+handle,$r:value=>value,hilog:{warn(){}},DOMAIN:0,TAG:'test'
});
const accountFor=(page,overrides={})=>{
  const account=new AccountPage();
  Object.assign(account,{profileNavigation:0,settingsReadGeneration:0,discovering:false,ownHandle:'',accountName:'',accountBio:'',
    host:{isControllerReady:()=>!!page.controller,getUIContext:()=>({getHostContext:()=>({})}),
      webScript:async script=>page.controller.runJavaScript(script),loadWeb:(...args)=>page.navigation.loadWeb(...args),
      accountChanged:()=>page.unread?.resetAccount?.(),toast:value=>page.toast?.(value)},
    saveOwnHandle(){},restoreAvatar(){},readAvatar(){},resetAvatar(){},confirmCurrentAccount:async()=>'',...overrides});
  return account;
};
const UnreadPage=vm.runInNewContext(stripTypeScriptTypes('class UnreadPage{'+
  ['resetAccount','clearNetworkBadgeCounts'].map(unreadMethod).join('\n')+'};UnreadPage'),{
  DOMAIN:0,TAG:'test',hilog:{warn(){}}
});
const unreadFor=page=>{
  const unread=new UnreadPage();
  Object.assign(unread,{unreadNotifications:0,unreadMessages:0,badgeShown:-1,
    host:{isControllerReady:()=>true,webScript:async script=>page.controller.runJavaScript(script)}});
  return unread;
};

// 原生设置在目标确认后才收起，失败或被新意图取消时仍保留原入口。
{
  const nav = new NavTestPage();
  const targets = [];
  Object.assign(nav, {
    pageAlive: true, appBackground: false,
    webNetworkReady: true,
    settingsOpen: true,
    settingsWeb: false,
    settingsWebUrl: '',
    settingsWebRoot: '',
    currentUrl: 'https://x.com/home',
    controller: {
      loadUrl: () => { throw Error('日常入口不得整页加载'); },
      runJavaScript: async () => ''
    },
    toast() {}
  });
  nav.account=accountFor(nav,{cancelProfileNavigation:async()=>{},closeWebDrawer:async()=>{}});
  nav.navigation=navigationFor(nav);

  let settle;
  nav.navigation.loadWeb=async url=>{targets.push(url);return new Promise(resolve=>{settle=resolve;});};
  const opening=nav.openSettingsRoute(bookmarksPath);
  assert.equal(nav.settingsWeb,false);assert.equal(nav.settingsOpen,true,'等待期间保留设置');
  settle('arrived');await opening;
  assert.equal(nav.settingsWeb,true);assert.equal(nav.settingsOpen,false);
  assert.equal(nav.settingsWebRoot, routes.TWITTER_BOOKMARKS);
  nav.navigation.loadWeb=async url=>{targets.push(url);return 'arrived';};
  for(const path of ['/i/history/likes',...appearance.PLATFORM_SETTINGS]){
    nav.settingsOpen=true;nav.settingsWeb=false;
    await nav.openSettingsRoute(path);
    assert.equal(nav.settingsWeb,true,path);assert.equal(nav.settingsOpen,false,path);
    assert.equal(nav.settingsWebRoot,'https://x.com'+path);
  }
  nav.account.ownHandle = 'alice';
  nav.settingsOpen = true;
  await nav.openOwnProfile();
  assert.equal(nav.settingsWeb, true);
  assert.equal(nav.settingsWebRoot, 'https://x.com/alice');
  assert.equal(targets.at(-1),'https://x.com/alice');
  nav.settingsOpen=true;nav.settingsWeb=false;nav.navigation.loadWeb=async()=> 'failed';
  await nav.openSettingsRoute('/settings/account');
  assert.equal(nav.settingsOpen,true);assert.equal(nav.settingsWeb,false);
  nav.navigation.loadWeb=async()=>new Promise(resolve=>{settle=resolve;});
  const stale=nav.openSettingsRoute('/i/bookmarks');nav.account.settingsReadGeneration++;
  settle('arrived');await stale;assert.equal(nav.settingsOpen,true);
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
    host:{isControllerReady:()=>true},
    controller: {
      runJavaScript: async s => { cancelScriptRun = s; }
    }
  });
  const account=accountFor(nav,{profileNavigation:nav.profileNavigation,discovering:nav.discovering,
    host:{isControllerReady:()=>true,webScript:async script=>nav.controller.runJavaScript(script)}});
  await account.cancelProfileNavigation();
  assert.equal(account.profileNavigation, 6);
  assert.equal(account.discovering, false);
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
      pageAlive: true,
      appBackground: false,
      ownHandle: '',
      isHomeRoot: () => true,
      toast: () => {},
      controller: {
        runJavaScript: async (s) => {
          if (s.includes('__otBootCancel')) return '';
          if (raceNav.account?.profileNavigation === 1) {
            await firstPromise;
            return '"alice"';
          }
          return '"bob"';
        }
      }
    });
    raceNav.account=accountFor(raceNav,{profileNavigation:0,discovering:false,ownHandle:'',
      cancelProfileNavigation:async function(){this.profileNavigation++;this.discovering=false;},
      acceptHandle:function(handle,navigate){this.ownHandle=handle;assert.equal(navigate,false);}});
    raceNav.navigation=navigationFor(raceNav);
    raceNav.navigation.loadWeb=async url=>{directLoads.push(url);return 'arrived';};

    const p1 = raceNav.openOwnProfile();
    // 等待一个微任务周期，让 p1 完成初始清理并进入资料脚本读取中
    await new Promise(r => setTimeout(r, 0));
    const p2 = raceNav.openOwnProfile();
    await p2;
    assert.equal(raceNav.account.ownHandle, 'bob');
    assert.deepEqual(directLoads, ['https://x.com/bob']);

    resolveFirst();
    await p1;
    assert.equal(raceNav.account.ownHandle, 'bob', '旧请求不得覆盖新请求账号');
    assert.equal(raceNav.account.profileNavigation, 2, '旧请求结束不得递增世代');
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
      pageAlive: true,
      appBackground: false,
      ownHandle: '',
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
    errNav.account=accountFor(errNav,{profileNavigation:0,discovering:false,ownHandle:'',
      cancelProfileNavigation:async function(){this.profileNavigation++;this.discovering=false;},
      closeWebDrawer:async()=>{drawerClosed=true;}});
    errNav.navigation=navigationFor(errNav);

    await errNav.openOwnProfile();
    assert.equal(toastMsg, 'app.string.account_unconfirmed', '识别异常必须提示 account_unconfirmed');
    assert.equal(drawerClosed, false, '本人入口只读取当前文档，不打开网页抽屉');
    assert.equal(errNav.account.discovering, false, '识别异常后 discovering 必须恢复 false');
  }
}

// 3. 设置加载不导航 (Settings opening does not navigate background webview)
{
  const navClient = new ClientPage();
  let navUrl = '';
  Object.assign(navClient, {
    currentIndex: 0,
    settingsOpen: false,
    account:{accountError:false,cancelProfileNavigation(){}},
    resetChromeScroll() {},
    resetProfileLayout() {},
    navigation: {currentUrl:'https://x.com/home',cancel(){},loadWeb: url => { navUrl = url; }}
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
    composer: { sheetOpen: false },
    settingsWeb: true,
    settingsOpen: false,
    settingsWebRoot: 'https://x.com/settings/your_twitter_data',
    navigation:{currentUrl:'https://x.com/settings/your_twitter_data',hasError:false,cancel(){}},
    controller: {
      accessBackward: () => true,
      backward: () => { backwardCalled = true; }
    }
  });
  nav.account=accountFor(nav,{cancelProfileNavigation:async()=>{}});
  nav.navigation=navigationFor(nav);

  // 在 settingsWebRoot 处点击返回，应回到原生设置
  const handledRoot = nav.onBackPress();
  assert.equal(handledRoot, true);
  assert.equal(nav.settingsWeb, false);
  assert.equal(nav.settingsOpen, true);
  assert.equal(backwardCalled, false);

  // 网页加载失败时返回，也应回到原生设置
  nav.settingsWeb = true;
  nav.settingsOpen = false;
  nav.navigation.failure = 'document';
  nav.navigation.currentUrl = 'https://x.com/settings/other';
  const handledError = nav.onBackPress();
  assert.equal(handledError, true);
  assert.equal(nav.settingsWeb, false);
  assert.equal(nav.settingsOpen, true);
  assert.equal(nav.navigation.hasError, false);

  // 深层网页有历史记录时，返回后退历史
  nav.settingsWeb = true;
  nav.settingsOpen = false;
  nav.navigation.failure = 'none';
  nav.navigation.currentUrl = 'https://x.com/settings/subpage';
  const handledBack = nav.onBackPress();
  assert.equal(handledBack, true);
  assert.equal(backwardCalled, true);
  assert.equal(nav.settingsWeb, true);
}

// 5. 旧账号结果失效 (Stale account details invalidated when handle changes)
{
  const nav = new NavTestPage();
  let avatarReset = false;
  Object.assign(nav,{controller:{runJavaScript:async()=>''}});
  const unread=unreadFor(nav);
  unread.unreadNotifications=5;unread.unreadMessages=2;unread.badgeShown=7;
  nav.unread=unread;
  nav.account=accountFor(nav,{ownHandle:'alice',accountName:'Alice Old',accountBio:'Old Bio',resetAvatar(){avatarReset=true;},
    host:{isControllerReady:()=>false,controller:()=>nav.controller,
      accountChanged:()=>nav.unread.resetAccount()}});

  // 账号改变时，清空资料、头像、未读计数
  nav.account.acceptHandle('bob', false);
  assert.equal(nav.account.ownHandle, 'bob');
  assert.equal(nav.account.accountName, '');
  assert.equal(nav.account.accountBio, '');
  assert.equal(nav.unread.unreadNotifications, 0);
  assert.equal(nav.unread.unreadMessages, 0);
  assert.equal(nav.unread.badgeShown, -1);
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

console.log('PASS: SPA navigation, settings confirmation, back-to-settings, stale account invalidation, background modal isolation, reorder/5-limit, and preference persistence');
