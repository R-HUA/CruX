import { RESERVED_ROOTS, SECONDARY_PATH_PATTERN, PROFILE_PATH_PATTERN } from './WebConfig';

// OpenTwit-Web runs the real x.com web app inside a native HarmonyOS shell.
// 原生只替代已支持业务页面的导航和编辑入口，其余页面保留网页界面。
//
// All scripts are injected as strings through WebviewController.runJavaScript.

// CSS injected once per page. Tab roots lose X's own navigation rows; the
// floating compose button is always dropped because the shell provides a native
// one (only rendered while signed in).
// 正文继承系统字体，代码块和图标保留网页自身的字体声明。
const FONT_CSS: string =
  "body{font-family:'HarmonyOS Sans','HarmonyOS Sans SC','HarmonyOS Sans TC'," +
  "'HarmonyOS Sans Naskh Arabic UI',sans-serif!important}";

// 业务标识和入口地址不随网页语言改变；aria-label 会被 X 翻译。
const PRIMARY_NAV_SELECTOR: string =
  "nav:has([data-testid='AppTabBar_Home_Link'])," +
  "[role='navigation']:has([data-testid='AppTabBar_Home_Link'])," +
  "nav:has(a[href='/home']):has(a[href='/notifications'])";
const BOTTOM_NAV_SELECTOR: string =
  "[data-testid='BottomBar']:has([data-testid='AppTabBar_Home_Link'])," +
  "[data-testid='BottomBar']:has(a[href='/home']):has(a[href='/notifications'])";
const CHROME_CSS: string =
  PRIMARY_NAV_SELECTOR + '{display:none!important}' +
  // 导航子项隐藏后，外壳仍有手势区 padding 和边框，必须一并移除。
  BOTTOM_NAV_SELECTOR + '{display:none!important}' +
  "[data-testid='FloatingActionButtons_Tweet_Button']{display:none!important}" +
  // Wide layouts: x.com renders its desktop side navigation, whose account
  // button sits in the corner the shell's own rail occupies.
  "[data-testid='SideNav_AccountSwitcher_Button']{display:none!important}" +
  FONT_CSS;

// 仅移除原生标题栏已替代的已知组件，不按位置隐藏网页内容。
const HEADER_CSS: string =
  "header[role='banner'],[data-testid='TopNavBar']{display:none!important}";
const HOME_TABS_CSS: string =
  // 多图轮播也使用 tablist，只隐藏含真实 tab 的导航，排除帖子内容。
  "nav[role='navigation'] [data-testid='ScrollSnap-SwipeableList']:has([role='tablist'] [role='tab']):not(article *){display:none!important}";
// 详情页的原生回复入口替代内嵌编辑单元，保留回复列表与帖子操作。
const REPLY_CSS: string = 'main [data-testid="inline_reply_offscreen"],' +
  'main [data-testid="cellInnerDiv"]:has([data-testid="tweetTextarea_0"]){display:none!important}';
// 读取实际画布色，网页主题仍由站点管理；透明背景继续读取根节点。
const REPORT_THEME_SCRIPT: string =
  'if(document.body&&window.otNative&&window.otNative.onTheme){' +
  'var bg=getComputedStyle(document.body).backgroundColor;' +
  'if(bg==="transparent"||bg==="rgba(0, 0, 0, 0)")bg=getComputedStyle(document.documentElement).backgroundColor;' +
  'if(/^rgb\\(\\d+,\\s*\\d+,\\s*\\d+\\)$/.test(bg)&&bg!==window.__otTheme){' +
  'window.__otTheme=bg;window.otNative.onTheme("main",bg);}}';
const PULL_CLIP_CSS: string = '[data-ot-pull-clip]{overflow:clip!important;}';

// 底部背景不避让，控件只保留一次手势区和小间距；共用规则不依赖某条媒体地址。
const WEB_SAFE_AREA_CSS: string =
  "[data-testid^='immersive-tweet-ui-content-container-']{bottom:0!important;" +
  "padding-bottom:env(safe-area-inset-bottom)!important}" +
  "[data-testid^='immersive-tweet-ui-content-container-']>:last-child{margin-bottom:4px!important}" +
  PULL_CLIP_CSS;

// 留白属于滚动内容，滑动后网页才能经过原生栏背面；登录和未知路由不应用。
const OVERLAY_CSS: string =
  'main[role="main"]{padding-top:var(--ot-top-inset,0px)!important;' +
  'padding-bottom:var(--ot-bottom-inset,0px)!important;}' +
  'html{scroll-padding-top:var(--ot-top-inset,0px);scroll-padding-bottom:var(--ot-bottom-inset,0px);}';

/** 根据 Web 实际视口换算 CSS 像素，避免桌面站点缩放后留白不足。 */
export function chromeInsetsScript(top: number, bottom: number, viewportWidth: number): string {
  return `(function(){
    window.__otInsetTop=${top};window.__otInsetBottom=${bottom};window.__otViewportWidth=${viewportWidth};
    window.__otUpdateInsets=function(){
      var scale=window.__otViewportWidth>0?window.innerWidth/window.__otViewportWidth:1;
      document.documentElement.style.setProperty('--ot-top-inset',(window.__otInsetTop*scale)+'px');
      document.documentElement.style.setProperty('--ot-bottom-inset',(window.__otInsetBottom*scale)+'px');
    };
    window.__otUpdateInsets();
    if(window.__otApplyTop)window.__otApplyTop();
    if(!window.__otInsetResize){window.__otInsetResize=true;window.addEventListener('resize',function(){
      window.__otUpdateInsets();if(window.__otApplyTop)window.__otApplyTop();});}
  })();`;
}

// 仅从明确的本人资料入口读取账号；读不到时不能推断用户已退出登录。
export const OWN_HANDLE_SCRIPT: string = `(function(){
  var links=document.querySelectorAll('a[data-testid="AppTabBar_Profile_Link"],a[data-testid="DashButton_ProfileIcon_Link"]');
  for(var i=0;i<links.length;i++){
    var href=links[i].getAttribute('href')||'';
    if(/^\\/[A-Za-z0-9_]{1,15}$/.test(href))return href.substring(1);
  }
  var dialogs=document.querySelectorAll('[role="dialog"]');
  var found='';
  for(var d=0;d<dialogs.length;d++){
    var profiles=dialogs[d].querySelectorAll('a[href]');
    for(var j=0;j<profiles.length;j++){
      var path=profiles[j].getAttribute('href')||'';
      if(!/^\\/[A-Za-z0-9_]{1,15}$/.test(path))continue;
      var handle=path.substring(1);
      var label=(profiles[j].getAttribute('aria-label')||profiles[j].textContent||'').trim();
      if(!/^(Profile|个人资料|個人資料)$/.test(label))continue;
      if(found&&found.toLowerCase()!==handle.toLowerCase())return '';
      found=handle;
    }
  }
  return found;
})()`;

// How often the chrome pass may re-run when it is reacting to page mutations.
// The first pass stays immediate (no double chrome on first paint); only the
// re-runs are paced. x.com mutates its DOM continuously — timelines, and far
// more so on the chat screen — and every pass walks the document and forces
// layout, so an unpaced observer is a lot of work for nothing.
const CHROME_OBSERVER_MS: number = 250;

// 文档首帧、SPA 切页和资料测量必须使用同一组主页标签路径。
const PROFILE_HANDLE_SCRIPT: string = 'function(p){var match=new RegExp(' + JSON.stringify(PROFILE_PATH_PATTERN) + ').exec(p.toLowerCase());' +
  'if(!match)return "";var root="/"+match[1];return ' + JSON.stringify(RESERVED_ROOTS) + '[root]||' +
  '["/home","/explore","/search","/notifications","/messages"].indexOf(root)>=0?"":match[1];}';

// 等网页处理点击后再阻止链接的浏览器默认导航，尚未接管事件的链接不能重载文档。
const PAGE_CLICK_SCRIPT: string = `function(node){
  if(node.tagName!=='A'){node.click();return true;}
  var event=new MouseEvent('click',{bubbles:true,cancelable:true,view:window});
  var reached=false,handled=false;
  function stop(e){if(e===event){reached=true;handled=e.defaultPrevented;e.preventDefault();}}
  window.addEventListener('click',stop);
  try{node.dispatchEvent(event);}finally{window.removeEventListener('click',stop);}
  return reached?handled:event.defaultPrevented;
}`;

/** 通过网页分类菜单切换照片，同次访问不覆盖后续手动选择。 */
export const PROFILE_MEDIA_SCRIPT: string = `(function(){
  var path=location.pathname.replace(/\\/$/,'').toLowerCase();
  var handle=(${PROFILE_HANDLE_SCRIPT})(path);
  if(!handle||path!=='/'+handle+'/media'){window.__otPhotoEntry='';window.__otPhotoMenu='';return;}
  if(window.__otPhotoEntry===path)return;
  if(new URL(location.href).searchParams.has('filter')){window.__otPhotoEntry=path;return;}
  var activate=${PAGE_CLICK_SCRIPT};
  var menus=document.querySelectorAll('[role="menu"],[role="dialog"],[data-testid="Dropdown"]');
  for(var m=0;m<menus.length;m++){
    if(!menus[m].getClientRects().length)continue;
    var options=menus[m].querySelectorAll('[role="menuitem"],[role="menuitemradio"],[role="option"]');
    for(var o=0;o<options.length;o++){
      var option=options[o];
      var label=(option.getAttribute('aria-label')||option.textContent||'').trim();
      if(!/^(Photos|照片|相片|الصور)$/i.test(label)||!option.getClientRects().length)continue;
      window.__otPhotoEntry=path;activate(option);return;
    }
  }
  if(window.__otPhotoMenu===path)return;
  var tabs=document.querySelectorAll('main [role="tab"][aria-selected="true"][aria-haspopup="menu"]');
  for(var t=0;t<tabs.length;t++){
    var tabUrl=new URL(tabs[t].getAttribute('href'),location.href);
    if(tabUrl.pathname.replace(/\\/$/,'').toLowerCase()!==path||!tabs[t].getClientRects().length)continue;
    window.__otPhotoMenu=path;
    if(!activate(tabs[t]))window.__otPhotoMenu='';
    return;
  }
})()`;

/** 网页弹层绘制在 Web 内，原生底栏须随其显示状态让位。 */
export const WEB_MODAL_SCRIPT: string = `(function(){
  if(!window.otNative||!window.otNative.onWebModal)return;
  var nodes=document.querySelectorAll('[role="dialog"],[role="menu"],[aria-modal="true"],[data-testid="Dropdown"]');
  var open=false;
  for(var i=0;i<nodes.length;i++){
    if(nodes[i].getAttribute('aria-hidden')!=='true'&&nodes[i].getClientRects().length){open=true;break;}
  }
  var url=String(location.href);
  if(window.__otModalOpen!==open||window.__otModalUrl!==url){
    window.__otModalOpen=open;window.__otModalUrl=url;window.otNative.onWebModal(url,open);
  }
})()`;

// 第 12 节确认的结构：负 top 的绝对定位指示器 → 位移层 → 不移动的列表外层。
// 从定位层识别边界，不依赖刷新图标的语言，也不要求 svg 紧贴固定层级。
const PULL_CLIP_SCRIPT: string = `(function(enabled){
  var clips=[];
  var icons=enabled?document.querySelectorAll('main[role="main"] svg[aria-label]'):[];
  for(var i=0;i<icons.length;i++){
    if(icons[i].closest('article,header,nav,[role="dialog"]'))continue;
    var main=icons[i].closest('main[role="main"]');
    for(var node=icons[i].parentElement;node&&node!==main;node=node.parentElement){
      var style=getComputedStyle(node);
      if(style.position!=='absolute'||!(parseFloat(style.top)<0))continue;
      for(var moving=node.parentElement;moving&&moving!==main;moving=moving.parentElement){
        if(!moving.querySelector('article,[data-testid="cellInnerDiv"]')&&moving.children.length<2)continue;
        var clip=moving.parentElement;
        if(clip&&clip!==main&&main.contains(clip)&&clips.indexOf(clip)<0)clips.push(clip);
        break;
      }
      break;
    }
  }
  var previous=window.__otPullClips||[];
  for(var j=0;j<previous.length;j++){
    if(clips.indexOf(previous[j])<0)previous[j].removeAttribute('data-ot-pull-clip');
  }
  for(var k=0;k<clips.length;k++){
    if(!clips[k].hasAttribute('data-ot-pull-clip'))clips[k].setAttribute('data-ot-pull-clip','');
  }
  window.__otPullClips=clips;
  return clips.length;
})`;

/** 文档创建时先去重导航；原生确认后交给完整脚本维护。 */
export function chromeDocumentStartScript(enabled: boolean): string {
  if (!enabled) { return ''; }
  return '(function(){if(window!==window.top)return;' +
    'var update=function(){if(window.__otChromePaused||!document.head)return;' +
    'var p=location.pathname.replace(/\\/$/,"").toLowerCase()||"/";' +
    'var secondary=new RegExp(' + JSON.stringify(SECONDARY_PATH_PATTERN) + ').test(p);' +
    'var profile=Boolean((' + PROFILE_HANDLE_SCRIPT + ')(p));' +
    'var detail=/^\\/(?:[a-z0-9_]{1,15}|i\\/web)\\/status\\/\\d+$/.test(p);' +
    'var nav=secondary||profile||detail||p==="/home"||/^\\/(explore|search|notifications|messages|i\\/chat)(\\/|$)/.test(p);' +
    'var header=secondary||profile||detail||["/home","/notifications"].indexOf(p)>=0;' +
    'var auth=document.querySelector(\'input[autocomplete="username"],input[autocomplete="current-password"],input[autocomplete="one-time-code"]\');' +
    'var css=document.getElementById("ot-initial-chrome");' +
    'if(!css){css=document.createElement("style");css.id="ot-initial-chrome";document.head.appendChild(css);}' +
    'var rules=nav&&!auth?' + JSON.stringify(CHROME_CSS) + ':"";' +
    'if(nav&&header&&!auth)rules+=' + JSON.stringify(HEADER_CSS) + ';' +
    'if(p==="/home"&&!auth)rules+=' + JSON.stringify(HOME_TABS_CSS + PULL_CLIP_CSS) + ';' +
    'if(detail&&!auth)rules+=' + JSON.stringify(REPLY_CSS) + ';' +
    'if(css.textContent!==rules)css.textContent=rules;' +
    PULL_CLIP_SCRIPT + '(p==="/home"&&!auth);if(!auth){' + PROFILE_MEDIA_SCRIPT + ';}' + WEB_MODAL_SCRIPT + ';' + REPORT_THEME_SCRIPT + '};' +
    'var observer=new MutationObserver(function(){if(window.__otObs){observer.disconnect();return;}update();});' +
    'window.__otInitialObserver=observer;window.__otInitialUpdate=update;' +
    'observer.observe(document,{childList:true,subtree:true});update();' +
    'window.addEventListener("pagehide",function(){observer.disconnect();},{once:true});})();';
}

// 查询参数、片段及站点别名不改变外壳归属；不同路径仍须等待原生确认。
const CHROME_ROUTE_KEY: string = 'function(value){return String(value)' +
  '.replace(/^https:\\/\\/(?:www\\.)?(?:x|twitter)\\.com(?=[/?#]|$)/i,"")' +
  '.split(/[?#]/)[0].replace(/\\/$/,"").toLowerCase()||"/";}';

// 坐标保留在文档空间，原生滚动回调可直接计算过渡，不必每帧跨进程测量。
export const PROFILE_LAYOUT_SCRIPT: string = `(function(active){
  if(!window.otNative||!window.otNative.onProfileLayout)return;
  var path=location.pathname.replace(/\\/$/,'').toLowerCase();
  var account=(${PROFILE_HANDLE_SCRIPT})(path);
  if(!active||!account)return;
  path='/'+account;
  var y=window.scrollY;
  var result={url:String(location.href),width:window.innerWidth,viewWidth:window.__otViewportWidth||0,
    scrollY:y,ready:false,hasBanner:false,bannerBottom:0,identityBottom:0,name:'',handle:''};
  var names=document.querySelectorAll('main [data-testid="UserName"]');
  for(var i=0;i<names.length;i++){
    var node=names[i];
    if(node.closest('article,header,nav,[role="dialog"],[data-testid="TopNavBar"]'))continue;
    var labels=node.querySelectorAll('[dir]'),handle=null;
    for(var j=0;j<labels.length;j++){
      var candidate=(labels[j].textContent||'').trim().match(/^@([A-Za-z0-9_]{1,15})$/);
      if(candidate&&'/'+candidate[1].toLowerCase()===path){handle=candidate;break;}
    }
    if(!handle||'/'+handle[1].toLowerCase()!==path)continue;
    var identity=node.getBoundingClientRect();
    if(identity.width<=0||identity.height<=0)continue;
    var banner=document.querySelector('main a[href="/'+handle[1]+'/header_photo"]')||
      document.querySelector('main a[href="'+path+'/header_photo"]');
    // 无横幅时等待实际资料区离开覆盖区域，不凭固定高度提前产生模糊。
    var boundary=(banner||node.parentElement).getBoundingClientRect();
    result.ready=true;result.hasBanner=Boolean(banner);result.bannerBottom=Math.round((boundary.bottom+y)*100)/100;
    result.identityBottom=Math.round((identity.bottom+y)*100)/100;
    result.name=(labels[0].textContent||'').trim();result.handle=handle[1];break;
  }
  var key=JSON.stringify([result.url,result.width,result.viewWidth,result.ready,result.hasBanner,result.bannerBottom,
    result.identityBottom,result.name,result.handle]);
  if(key!==window.__otProfileLayout){window.__otProfileLayout=key;window.otNative.onProfileLayout(JSON.stringify(result));}
})`;

/** 原生控件和网页去重共用路由判定，不以账号元素是否存在决定界面。 */
export function chromeScript(nativeNavigation: boolean, nativeHeader: boolean, url: string): string {
  return '(function(nav,header,url){try{' +
    'var routeKey=' + CHROME_ROUTE_KEY + ';' +
    'var clipPull=' + PULL_CLIP_SCRIPT + ';' +
    'if(routeKey(url)===routeKey(location.href)){' +
    'window.__otNativeNavigation=nav;window.__otNativeHeader=header;window.__otChromeUrl=url;}' +
    'var css=document.getElementById(\'ot-hidenav\');' +
    'if(!css){css=document.createElement(\'style\');css.id=\'ot-hidenav\';' +
    'document.head.appendChild(css);}' +
    'var initial=document.getElementById("ot-initial-chrome");if(initial&&initial!==css)initial.remove();' +
    'if(window.__otInitialObserver){window.__otInitialObserver.disconnect();window.__otInitialObserver=null;}' +
    'window.__otApplyTop=function(){' +
    'if(window.__otChromePaused)return;' +
    REPORT_THEME_SCRIPT +
    'var p=location.pathname.replace(/\\/$/,"")||"/";' +
    'var auth=document.querySelector(\'input[autocomplete="username"],input[autocomplete="current-password"],input[autocomplete="one-time-code"]\');' +
    'var active=window.__otNativeNavigation&&!auth&&routeKey(window.__otChromeUrl)===routeKey(location.href);' +
    'window.__otPullMatches=clipPull(active&&(window.__otInsetTop>0||p==="/home"));' +
    'var rules=auth?"":' + JSON.stringify(WEB_SAFE_AREA_CSS) + ';' +
    'if(active){rules+=' + JSON.stringify(CHROME_CSS) + ';' +
    'if(window.__otInsetTop>0||window.__otInsetBottom>0||(' + PROFILE_HANDLE_SCRIPT + ')(p))rules+=' + JSON.stringify(OVERLAY_CSS) + ';' +
    'if(window.__otNativeHeader){rules+=' + JSON.stringify(HEADER_CSS) + ';' +
    'if(/^\\/(?:[a-z0-9_]{1,15}|i\\/web)\\/status\\/\\d+$/i.test(p))rules+=' + JSON.stringify(REPLY_CSS) + ';' +
    'if(p==="/home")rules+=' + JSON.stringify(HOME_TABS_CSS) + ';}}' +
    'if(css.textContent!==rules)css.textContent=rules;' +
    'if(!auth){' + PROFILE_MEDIA_SCRIPT + ';}' + WEB_MODAL_SCRIPT + ';' +
    'if(window.__otAuth!==Boolean(auth)){' +
    'window.__otAuth=Boolean(auth);' +
    'if(window.otNative)window.otNative.onUrlChange("main",String(location.href));}' +
    // 首屏图片可能晚于页面完成才挂载，头像变化时复用页面状态读取通道。
    'var avatar=auth?"":' + accountAvatarScript('') + ';' +
    'if(avatar!==window.__otAccountAvatar){window.__otAccountAvatar=avatar;' +
    'if(avatar&&window.otNative)window.otNative.onUrlChange("main",String(location.href));}' +
    PROFILE_LAYOUT_SCRIPT + '(active&&window.__otNativeHeader);};' +
    'window.__otOwn=function(){return ' + OWN_HANDLE_SCRIPT + ';};' +
    // x.com navigates like an app (history.pushState), which does not reload
    // the page and therefore never reaches the shell through the Web component
    // callbacks. Hook the history API and report every change to the native
    // bridge so the header, tab bar and back button stay in step.
    'if(!window.__otHist){window.__otHist=1;' +
    // SPA 地址已变化时先释放旧页规则，不能等待异步原生回调才显示详情顶部。
    'function otTell(){try{if(window.__otChromePaused)return;window.__otApplyTop();if(window.otNative&&window.otNative.onUrlChange){' +
    'window.otNative.onUrlChange("main",String(window.location.href));}}catch(_){}}' +
    'var otPush=history.pushState;' +
    'history.pushState=function(){var r=otPush.apply(this,arguments);otTell();return r;};' +
    'var otRep=history.replaceState;' +
    'history.replaceState=function(){var r=otRep.apply(this,arguments);otTell();return r;};' +
    'window.addEventListener("popstate",function(){otTell();});' +
    'window.addEventListener("hashchange",function(){otTell();});}' +
    // x.com 的下拉刷新只把内容平移回去，document 会残留约一个标题栏高度的
    // scrollY，刷新后的首条内容因此停进原生标题栏。下拉手势结束后把这种
    // 顶部残留滚回 0；只处理从顶部附近向下拉的手势，不干扰正常滚动。
    'if(!window.__otPullFix&&document.addEventListener){window.__otPullFix=1;' +
    'var otPullStart=0,otPullY=0,otPulled=false,otTouch=false,otPullTimers=[],otPullPath="";' +
    'var otClearPullTimers=function(){for(var i=0;i<otPullTimers.length;i++){clearTimeout(otPullTimers[i]);}otPullTimers=[];};' +
    'window.__otClearPullTimers=otClearPullTimers;' +
    'var otSettleTop=function(){if(otTouch||location.pathname!==otPullPath){return;}if(window.scrollY>0&&window.scrollY<200){window.scrollTo(0,0);}};' +
    'document.addEventListener("touchstart",function(e){otTouch=true;otClearPullTimers();' +
    'if(!e.touches||!e.touches.length){return;}otPullStart=window.scrollY;otPullY=e.touches[0].clientY;otPulled=false;otPullPath=location.pathname;},{passive:true,capture:true});' +
    'document.addEventListener("touchmove",function(e){if(!e.touches||!e.touches.length){return;}' +
    'if(otPullStart<=100&&e.touches[0].clientY-otPullY>24){otPulled=true;}},{passive:true,capture:true});' +
    'document.addEventListener("touchend",function(){otTouch=false;if(!otPulled){return;}otPulled=false;' +
    'otPullTimers=[setTimeout(otSettleTop,500),setTimeout(otSettleTop,1200),setTimeout(otSettleTop,2000)];},{passive:true,capture:true});' +
    'document.addEventListener("touchcancel",function(){otTouch=false;otPulled=false;otClearPullTimers();},{passive:true,capture:true});}' +
    'if(!window.__otObs){window.__otPend=0;' +
    'window.__otPass=function(){window.__otPend=0;try{' +
    'window.__otApplyTop&&window.__otApplyTop();' +
    '}catch(e){}};' +
    'window.__otObserveOptions={childList:true,subtree:true,characterData:true,attributes:true,attributeFilter:["src","srcset","style","href","aria-selected","aria-expanded","aria-hidden","hidden"]};' +
    'window.__otObs=new MutationObserver(function(){' +
    WEB_MODAL_SCRIPT + ';' +
    // 进入首页或替换加载占位时，裁剪先于下一帧；其余修饰仍合并到节流回调。
    'if(location.pathname.replace(/\\/$/,"").toLowerCase()==="/home"&&!document.querySelector(' +
    '\'input[autocomplete="username"],input[autocomplete="current-password"],input[autocomplete="one-time-code"]\')){' +
    'window.__otPullMatches=clipPull(true);}' +
    'if(window.__otPend){return;}window.__otPend=1;' +
    'window.__otTimer=setTimeout(window.__otPass,' + CHROME_OBSERVER_MS + ');});' +
    'window.__otObs.observe(document.documentElement,window.__otObserveOptions);' +
    'window.addEventListener("pagehide",function(e){if(!e.persisted){window.__otObs.disconnect();clearTimeout(window.__otTimer);}}, {once:true});}' +
    'window.__otChromeReport=function(){return JSON.stringify({' +
    'navigation:Boolean(window.__otNativeNavigation&&!window.__otAuth&&routeKey(window.__otChromeUrl)===routeKey(location.href)),' +
    'header:Boolean(window.__otNativeHeader),navMatches:document.querySelectorAll(' + JSON.stringify(PRIMARY_NAV_SELECTOR) + ').length,' +
    'pullMatches:window.__otPullMatches||0,avatarFound:Boolean(window.__otAccountAvatar)});};' +
    'window.__otApplyTop();return window.__otChromeReport();' +
    '}catch(e){return JSON.stringify({error:String(e)});}})(' + nativeNavigation + ',' + nativeHeader + ',' + JSON.stringify(url) + ');';
}

/** 后台停止外壳的 DOM 扫描；恢复时先补一次状态，再继续观察。 */
export function chromeActiveScript(active: boolean): string {
  return '(function(active){window.__otChromePaused=!active;' +
    'if(active)window.__otProfileLayout=null;' +
    'if(window.__otClearPullTimers)window.__otClearPullTimers();' +
    'if(window.__otInitialObserver){window.__otInitialObserver.disconnect();if(active){' +
    'window.__otInitialUpdate();window.__otInitialObserver.observe(document,{childList:true,subtree:true});}}' +
    'if(!window.__otObs)return;' +
    'clearTimeout(window.__otTimer);window.__otPend=0;window.__otObs.disconnect();' +
    'if(active){window.__otApplyTop();window.__otObs.observe(document.documentElement,window.__otObserveOptions);}' +
    '})(' + active + ');';
}

/** 发布资格由网页按当前账号和文本计算，原生不复制站点的字数规则。 */
export const COMPOSER_READY_SCRIPT: string = `(function(){
  var b=document.querySelector('[data-testid="tweetButton"]')||document.querySelector('[data-testid="tweetButtonInline"]');
  return Boolean(b&&!b.disabled&&b.getAttribute('aria-disabled')!=='true');
})()`;

/** 调用网页已有账号控件，账号和登录会话继续由 X 管理。 */
export const ACCOUNT_SWITCH_SCRIPT: string = `(function(){
  var button=document.querySelector('[data-testid="SideNav_AccountSwitcher_Button"],'+
    '[data-testid="DashButton_ProfileIcon_Link"]');
  if(!button)return 'missing';button.click();return 'opened';
})()`;

// Cheap follow-up used on in-page (SPA) navigations, which do not always fire
// onPageEnd: flips the tab-root flag and re-runs the removal pass.
export function chromeFlagScript(nativeNavigation: boolean, nativeHeader: boolean, url: string): string {
  return '(function(nav,header,url){try{var routeKey=' + CHROME_ROUTE_KEY + ';' +
    'if(routeKey(url)!==routeKey(location.href))return;' +
    'window.__otNativeNavigation=nav;window.__otNativeHeader=header;window.__otChromeUrl=url;' +
    'window.__otApplyTop&&window.__otApplyTop();return window.__otChromeReport&&window.__otChromeReport();' +
    '}catch(e){return JSON.stringify({error:String(e)});}})(' +
    nativeNavigation + ',' + nativeHeader + ',' + JSON.stringify(url) + ');';
}

export function scrollToTopScript(): string {
  return 'window.scrollTo({top:0,behavior:"smooth"});';
}

/** 复用网页导航及其菜单；菜单尚未挂载时由原生等待，不回退到整页加载。 */
export function clickRouteScript(url: string): string {
  return `(function(target){
    var wanted=new URL(target,location.href);
    if(window.__otRouteRequest&&window.__otRouteRequest.target!==wanted.href)window.__otRouteCancel();
    if(wanted.href===location.href)return 'same';
    if(!window.__otRouteRequest){
      window.__otRouteRequest={target:wanted.href,start:location.href,opener:null};
      window.__otRouteCancel=function(){
        var request=window.__otRouteRequest;window.__otRouteRequest=null;
        if(!request||!request.opener||request.start!==location.href)return;
        var close=document.querySelector('[role="dialog"] [data-testid="app-bar-close"]');
        if(close)close.click();
        else if(request.opener.getAttribute('aria-expanded')==='true')request.opener.click();
      };
    }
    var request=window.__otRouteRequest;
    if(request.start!==location.href){window.__otRouteCancel();return 'cancelled';}
    var activate=${PAGE_CLICK_SCRIPT};
    var links=document.querySelectorAll('a[href]');
    for(var i=0;i<links.length;i++){
      var link=new URL(links[i].getAttribute('href'),location.href);
      if(link.origin===wanted.origin&&link.pathname===wanted.pathname&&link.search===wanted.search&&
        links[i].getAttribute('target')!=='_blank'){
        if(!activate(links[i]))return 'pending';
        window.__otRouteRequest=null;return 'clicked';
      }
    }
    var menuTarget=/^\\/(settings(?:\\/|$)|i\\/(bookmarks|history)(?:\\/|$)|[a-z0-9_]{1,15}(?:\\/lists)?$)/i.test(wanted.pathname);
    if(menuTarget){
      if(request.opener)return 'pending';
      var controls=document.querySelectorAll('[data-testid="DashButton_ProfileIcon_Link"],'+
        '[data-testid="AppTabBar_More_Menu"]');
      for(var c=0;c<controls.length;c++){
        if(controls[c].tagName==='A')continue;
        request.opener=controls[c];controls[c].click();return 'pending';
      }
    }
    window.__otRouteCancel();
    return 'missing';
  })(` + JSON.stringify(url) + ')';
}

// The shell draws the "For you / Following" switcher natively on Home. x.com
// keeps its own tab row in the DOM (the shell hides it), so switching is a
// programmatic click on the matching tab rather than a route change: the page
// swaps timelines in place, exactly as it does when its own row is used.
export function selectHomeTabScript(index: number): string {
  return '(function(i){try{' +
    'var tl=document.querySelector(\'[data-testid="ScrollSnap-List"]\')||' +
    'document.querySelector(\'[role="tablist"]\');' +
    'if(!tl)return "missing";' +
    'var t=tl.querySelectorAll(\'[role="tab"]\');' +
    'if(!t||!t.length)return "notabs";' +
    'if(t.length<=i)return "short";' +
    'if(t[i].getAttribute(\'aria-selected\')===\'true\')return "same";' +
    't[i].click();return "ok";}catch(e){return "error";}})(' + index + ');';
}

// Index of the selected Home timeline tab, or -1 when the page is not Home.
export const HOME_TAB_SCRIPT: string =
  '(function(){try{' +
  'var tl=document.querySelector(\'[data-testid="ScrollSnap-List"]\');' +
  'if(!tl)return -1;' +
  'var t=tl.querySelectorAll(\'[role="tab"]\');' +
  'for(var i=0;i<t.length;i++){if(t[i].getAttribute(\'aria-selected\')===\'true\')return i;}' +
  'return -1;}catch(e){return -1;}})()';

/** 优先读取明确的当前账号控件，不从时间线或他人资料中按图片尺寸猜头像。 */
export function accountAvatarScript(handle: string): string {
  return `(function(handle){
    function avatar(root){
      if(!root)return '';
      var selector='img,image,[style*="background-image"]';
      var images=Array.from(root.querySelectorAll(selector));
      if(root.matches(selector))images.unshift(root);
      for(var i=0;i<images.length;i++){
        var background=images[i].style&&images[i].style.backgroundImage||'';
        var match=/^url\\(["']?(.*?)["']?\\)$/.exec(background);
        var src=String(images[i].currentSrc||images[i].getAttribute('src')||images[i].getAttribute('href')||
          (match?match[1]:''));
        if(/^https:\\/\\/(pbs|abs)\\.twimg\\.com\\/(profile_images|sticky\\/default_profile_images)\\//i.test(src))return src;
      }
      return '';
    }
    var controls=document.querySelectorAll('[data-testid="DashButton_ProfileIcon_Link"],'+
      '[data-testid="SideNav_AccountSwitcher_Button"],[data-testid="AppTabBar_Profile_Link"]');
    var content='article,[data-testid="cellInnerDiv"],[data-testid="tweet"]';
    for(var i=0;i<controls.length;i++){
      if(controls[i].closest(content))continue;
      var src=avatar(controls[i]);if(src)return src;
    }
    var candidates=document.querySelectorAll(handle?'[data-testid^="UserAvatar-Container-"],a[href]':
      'header[role="banner"] [data-testid^="UserAvatar-Container-"],'+
      '[data-testid="TopNavBar"] [data-testid^="UserAvatar-Container-"]');
    var topAvatar='';
    for(var c=0;c<candidates.length;c++){
      var node=candidates[c];
      if(node.closest(content))continue;
      var id=(node.getAttribute('data-testid')||'').toLowerCase();
      var href=(node.getAttribute('href')||'').toLowerCase();
      if(handle&&(id==='useravatar-container-'+handle.toLowerCase()||href==='/'+handle.toLowerCase())){
        var ownControl=avatar(node);if(ownControl)return ownControl;
      }
      if(id.indexOf('useravatar-container-')!==0||
        !node.closest('header[role="banner"],[data-testid="TopNavBar"]'))continue;
      var top=avatar(node);
      if(topAvatar&&top&&topAvatar!==top)return '';
      if(top)topAvatar=top;
    }
    if(topAvatar)return topAvatar;
    var path=location.pathname.replace(/\\/$/,'').toLowerCase();
    if(handle&&path==='/'+handle.toLowerCase()){
      var links=document.querySelectorAll('a[href]');
      for(var j=0;j<links.length;j++){
        if(links[j].closest(content))continue;
        if((links[j].getAttribute('href')||'').toLowerCase()===path+'/photo'){
          var own=avatar(links[j]);if(own)return own;
        }
      }
    }
    return '';
  })(` + JSON.stringify(handle) + ')';
}

/** 只报告控件结构和图片域名，避免将账号、图片地址或页面正文写入日志。 */
export function accountAvatarDiagScript(): string {
  return `(function(){
    var selectors=['[data-testid="DashButton_ProfileIcon_Link"]',
      '[data-testid="SideNav_AccountSwitcher_Button"]','[data-testid="AppTabBar_Profile_Link"]',
      'header[role="banner"]','[data-testid="TopNavBar"]','nav[role="navigation"]'];
    return JSON.stringify(selectors.map(function(selector){
      var nodes=Array.from(document.querySelectorAll(selector));
      return {selector:selector,count:nodes.length,nodes:nodes.map(function(node){
        var style=getComputedStyle(node);
        var images=Array.from(node.querySelectorAll('img,image,[style*="background-image"]'));
        if(node.matches('img,image,[style*="background-image"]'))images.unshift(node);
        return {tag:node.tagName,display:style.display,visibility:style.visibility,
          avatars:node.querySelectorAll('[data-testid^="UserAvatar-Container-"]').length,
          images:images.map(function(img){
            var background=img.style&&img.style.backgroundImage||'';
            var match=/^url\\(["']?(.*?)["']?\\)$/.exec(background);
            var src=img.currentSrc||img.getAttribute('src')||img.getAttribute('href')||(match?match[1]:'');
            var host=/^https:\\/\\/([^/]+)/i.exec(src);
            var parent=img.parentElement;
            var id=parent&&parent.getAttribute('data-testid')||'';
            return {tag:img.tagName,host:host?(/^(pbs|abs)\\.twimg\\.com$/i.test(host[1])?host[1]:'other'):'empty',
              parentTag:parent?parent.tagName:'',parentTestId:id.indexOf('UserAvatar-Container-')===0?
                'UserAvatar-Container-*':(/^(DashButton_ProfileIcon_Link|SideNav_AccountSwitcher_Button|AppTabBar_Profile_Link)$/.test(id)?id:'other')};
          })};
      })};
    }));
  })()`;
}

/** 被动读取网页已有的计数响应，不发起额外请求，也不改变响应内容。 */
export const UNREAD_RESPONSE_SCRIPT: string = `(function(){
  if(window!==window.top||window.__otBadgeHook)return;
  window.__otBadgeHook=true;
  window.__otBadgeEpoch=0;
  var send=XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send=function(){
    var epoch=window.__otBadgeEpoch;
    this.addEventListener('load',function(){
      if(epoch!==window.__otBadgeEpoch||this.status!==200)return;
      try{
        var url=new URL(this.responseURL);
        if(url.hostname!=='x.com'||!/^\\/i\\/api\\/graphql\\/[^/]+\\/ViewerBadgeCounts$/.test(url.pathname))return;
        var data=this.responseType==='json'?this.response:JSON.parse(this.responseText);
        var counts=data.data.viewer_v2.user_results.result.badge_counts;
        var n=counts.ntab_unread_count,m=counts.xchat_unread_count;
        if(!Number.isSafeInteger(n)||n<0||!Number.isSafeInteger(m)||m<0)throw new Error('Invalid badge counts');
        window.__otBadgeCounts={notifications:n,messages:m,time:Date.now()};
      }catch(error){console.warn('CruX unread response invalid');}
    },{once:true});
    return send.apply(this,arguments);
  };
})();`;

// Unread counters for the shell's own tab bar and for the launcher badge.
//
// The counts belong to x.com, and the page already publishes them twice, so the
// shell reads rather than guesses: every navigation entry carries the number in
// its accessible label — x.com's own templates are "Notifications (%d unread
// notifications)" and "Direct Messages (%d unread conversations)" — and the
// tabs that draw a numeric badge put the same number in a text node. The
// wording follows the page language while the number stays a number, so this
// parses the digits out of either form. The title is the last resort for
// notifications, which x.com prefixes on every route: "(3) Home / X".
//
// Returns "<notifications>/<messages>". A count is 0 when the page has that
// navigation entry and nothing unread, and **-1 when there is no such entry at
// all** — a page that is still loading or has not hydrated its navigation yet.
// The shell keeps the last known count on -1 rather than treating "not yet" as
// "nothing unread", which is what made the badges drop out while moving between
// tabs.
export const UNREAD_COUNTS_SCRIPT: string =
  '(function(){try{' +
  // 响应只在一分钟内优先使用；站点未提供有效响应时继续读取原有页面入口。
  'var cached=window.__otBadgeCounts;' +
  'if(cached&&Date.now()-cached.time<60000)return cached.notifications+"/"+cached.messages;' +
  // An Arabic page formats counts with Arabic-Indic digits; normalise before
  // parsing so the number survives a localised page.
  'function dg(v){return String(v)' +
  '.replace(/[\\u0660-\\u0669]/g,function(c){return String(c.charCodeAt(0)-1632);})' +
  '.replace(/[\\u06f0-\\u06f9]/g,function(c){return String(c.charCodeAt(0)-1776);});}' +
  'function cnt(sel){' +
  'var ns=document.querySelectorAll(sel);' +
  'if(!ns.length){return -1;}' +
  'for(var i=0;i<ns.length;i++){' +
  'var lab=dg(ns[i].getAttribute("aria-label")||"");' +
  'var m=lab.match(/\\(\\s*(\\d{1,4})/)||lab.match(/^\\s*(\\d{1,4})\\s*$/);' +
  'if(!m){' +
  'var kids=ns[i].querySelectorAll("*");' +
  'for(var k=0;k<kids.length;k++){' +
  'var t=dg((kids[k].textContent||"").trim());' +
  'if(/^\\d{1,4}$/.test(t)){m=[t,t];break;}}}' +
  'if(m){var n=parseInt(m[1],10);if(n>0){return n;}}}' +
  'return 0;}' +
  // The mobile web puts both counts on its own (hidden) tab row; the desktop
  // layout keeps them on the side navigation. Both are matched by href so a
  // renamed test id cannot break the read.
  'var n=cnt(\'a[href="/notifications"],[data-testid="AppTabBar_Notifications_Link"]\');' +
  'var m=cnt(\'a[href="/messages"],a[href="/i/chat"],' +
  '[data-testid="AppTabBar_DirectMessage_Link"],[data-testid="AppTabBar_Messages_Link"]\');' +
  // x.com prefixes the notification count on every route it knows about:
  // "(3) Home / X". Only consulted when the navigation entry itself is missing.
  'if(n<0){var tm=dg(document.title||"").match(/^\\((\\d{1,4})\\)/);if(tm){n=parseInt(tm[1],10);}}' +
  'return n+"/"+m;' +
  '}catch(e){return "";}})()';

// Native "Post" action for the compose sheet: clicks x.com's own submit button.
// Returns 'missing' when the page has not rendered one yet, so the shell can
// tell the user instead of failing silently.
/** 仅网页在本次提交后生成的成功提示与帖子链接可确认发布。 */
export const CLICK_POST_BUTTON_SCRIPT: string = `(function(){
  var b=document.querySelector('[data-testid="tweetButton"]')||document.querySelector('[data-testid="tweetButtonInline"]');
  if(!b)return 'missing';
  if(b.disabled||b.getAttribute('aria-disabled')==='true')return 'disabled';
  if(window.__otPostState==='submitted'||window.__otPostState==='unknown')return 'unknown';
  var before=new Set(Array.from(document.querySelectorAll('[data-testid="toast"]')));
  window.__otPostState='submitted';
  var observer=new MutationObserver(function(){
    var toasts=document.querySelectorAll('[data-testid="toast"]');
    for(var i=0;i<toasts.length;i++){
      var t=toasts[i];
      if(before.has(t))continue;
      var text=t.textContent||'';
      var link=t.querySelector('a[href*="/status/"]');
      if(link && /Your post was sent|Your Tweet was sent|帖子已发送|帖子已發送|推文已发送|推文已發送/.test(text)){
        window.__otPostState='confirmed';observer.disconnect();return;
      }
    }
  });
  observer.observe(document.documentElement,{childList:true,subtree:true,characterData:true});
  window.addEventListener('pagehide',function(){observer.disconnect();},{once:true});
  setTimeout(function(){observer.disconnect();if(window.__otPostState==='submitted')window.__otPostState='unknown';},15000);
  try{b.click();return 'submitted';}catch(e){observer.disconnect();window.__otPostState='unknown';return 'unknown';}
})()`;

export const POST_RESULT_SCRIPT: string = 'window.__otPostState||"unknown"';

// Pushes the text typed in the native composer into x.com's own editor, so the
// native sheet posts through the real web session (DraftJS state, character
// counting, threads, per-account length rules) without the user ever seeing the
// web composer.
//
// Returns 'ok' when the editor reports the text back, 'missing' when the
// composer has not rendered yet — the shell then falls back to the web sheet so
// nothing the user typed is lost.
export function fillComposerScript(text: string): string {
  return '(function(t){try{' +
    'var e=document.querySelector(\'[data-testid="tweetTextarea_0"][contenteditable="true"]\');' +
    'if(!e)return \'missing\';' +
    'e.focus();' +
    'try{var s=window.getSelection();var r=document.createRange();' +
    'r.selectNodeContents(e);s.removeAllRanges();s.addRange(r);}catch(_){}' +
    'var ok=false;' +
    'try{ok=document.execCommand(\'insertText\',false,t);}catch(_){ok=false;}' +
    'if(!ok)return \'error\';' +
    'var got=(e.innerText||e.textContent||\'\');' +
    'return got.replace(/\\r\\n?/g,"\\n")===t.replace(/\\r\\n?/g,"\\n")?\'ok\':\'mismatch\';' +
    '}catch(err){return \'error\';}})(' + JSON.stringify(text) + ');';
}

/** 移动网页需打开账号抽屉才能确认本人资料入口，导航沿用网页点击事件。 */
export function profileBootstrapScript(navigate: boolean): string {
  return '(function(navigate){try{' +
  'if(window.__otBootCancel)window.__otBootCancel();' +
  'var btn=null,opened=false,launched=false,done=false,observer=null,timer=0;' +
  'window.__otBoot="";' +
  'function stop(){if(done)return;done=true;if(observer)observer.disconnect();clearTimeout(timer);' +
  'if(opened){var dialog=document.querySelector("[role=dialog]");' +
  'if(dialog){var close=dialog.querySelector("[data-testid=app-bar-close]");' +
  'if(close)close.click();else btn.click();}}}' +
  'window.__otBootCancel=stop;' +
  'function read(){if(done)return;try{' +
  'if(!launched){btn=document.querySelector("[data-testid=DashButton_ProfileIcon_Link],[data-testid=SideNav_AccountSwitcher_Button]");' +
  'if(!btn)return;launched=true;opened=!document.querySelector("[role=dialog]");if(opened)btn.click();}' +
  'window.__otBoot=' + OWN_HANDLE_SCRIPT + ';' +
  'if(!window.__otBoot)return;' +
  'if(navigate&&window.__otBoot){var links=document.querySelectorAll("[role=dialog] a[href]");' +
  'for(var i=0;i<links.length;i++){if(links[i].getAttribute("href").toLowerCase()==="/"+window.__otBoot.toLowerCase()){' +
  'links[i].click();break;}}}stop();' +
  '}catch(e){window.__otBoot="";stop();}}' +
  'observer=new MutationObserver(read);observer.observe(document.documentElement,{childList:true,subtree:true,attributes:true});' +
  'timer=setTimeout(stop,10000);read();' +
  'return "armed";' +
  '}catch(e){window.__otBoot="";return "err";}})(' + navigate + ')';
}
