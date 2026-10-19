// OpenTwit-Web runs the real x.com web app inside a native HarmonyOS shell.
// 原生只替代已支持业务页面的导航和编辑入口，其余页面保留网页界面。
//
// All scripts are injected as strings through WebviewController.runJavaScript.

// CSS injected once per page. Tab roots lose X's own navigation rows; the
// floating compose button is always dropped because the shell provides a native
// one (only rendered while signed in).
// HarmonyOS Sans for every text node the web page draws. The shell is a
// HarmonyOS app, so X's own webfont (Chirp) is not used: the page inherits the
// platform family. Emoji, CJK and symbol fallbacks still resolve through the
// system stack behind HarmonyOS Sans.
const FONT_CSS: string =
  "*{font-family:'HarmonyOS Sans','HarmonyOS Sans SC','HarmonyOS Sans TC'," +
  "'HarmonyOS Sans Naskh Arabic UI',sans-serif!important}";

const CHROME_CSS: string =
  "nav[aria-label='Primary']{display:none!important}" +
  // 导航子项隐藏后，外壳仍有手势区 padding 和边框，必须一并移除。
  "[data-testid='BottomBar']:has(nav[aria-label='Primary']){display:none!important}" +
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

// 底部背景不避让，控件只保留一次手势区和小间距；共用规则不依赖某条媒体地址。
const WEB_SAFE_AREA_CSS: string =
  "[data-testid^='immersive-tweet-ui-content-container-']{bottom:0!important;" +
  "padding-bottom:env(safe-area-inset-bottom)!important}" +
  "[data-testid^='immersive-tweet-ui-content-container-']>:last-child{margin-bottom:4px!important}";

// 留白属于滚动内容，滑动后网页才能经过原生栏背面；登录和未知路由不应用。
const OVERLAY_CSS: string =
  'main[role="main"]{padding-top:var(--ot-top-inset,0px)!important;' +
  'padding-bottom:var(--ot-bottom-inset,0px)!important;}' +
  // 在不随下拉位移的列表容器裁剪，箭头随网页原有 transform 拉入后仍可见。
  'main[role="main"] div:has(>div>div>svg[aria-label="Pull to refresh"]){overflow:clip!important;}' +
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
    if(!window.__otInsetResize){window.__otInsetResize=true;window.addEventListener('resize',function(){window.__otUpdateInsets();});}
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

/** 原生控件和网页去重共用路由判定，不以账号元素是否存在决定界面。 */
export function chromeScript(nativeNavigation: boolean, nativeHeader: boolean, url: string): string {
  return '(function(nav,header,url){try{' +
    'window.__otNativeNavigation=nav;window.__otNativeHeader=header;window.__otChromeUrl=url;' +
    'var css=document.getElementById(\'ot-hidenav\');' +
    'if(!css){css=document.createElement(\'style\');css.id=\'ot-hidenav\';' +
    'document.head.appendChild(css);}' +
    'window.__otApplyTop=function(){' +
    'var p=location.pathname.replace(/\\/$/,"")||"/";' +
    'var auth=document.querySelector(\'input[autocomplete="username"],input[autocomplete="current-password"],input[autocomplete="one-time-code"]\');' +
    'var rules=auth?"":' + JSON.stringify(WEB_SAFE_AREA_CSS) + ';' +
    'if(window.__otNativeNavigation&&!auth&&window.__otChromeUrl===String(location.href)){rules+=' + JSON.stringify(CHROME_CSS) + ';' +
    'if(window.__otInsetTop>0||window.__otInsetBottom>0)rules+=' + JSON.stringify(OVERLAY_CSS) + ';' +
    'if(window.__otNativeHeader){rules+=' + JSON.stringify(HEADER_CSS) + ';' +
    'if(p==="/home")rules+=' + JSON.stringify(HOME_TABS_CSS) + ';}}' +
    'if(css.textContent!==rules)css.textContent=rules;' +
    'if(window.__otAuth!==Boolean(auth)){' +
    'window.__otAuth=Boolean(auth);' +
    'if(window.otNative)window.otNative.onUrlChange("main",String(location.href));}};' +
    'window.__otOwn=function(){return ' + OWN_HANDLE_SCRIPT + ';};' +
    // x.com navigates like an app (history.pushState), which does not reload
    // the page and therefore never reaches the shell through the Web component
    // callbacks. Hook the history API and report every change to the native
    // bridge so the header, tab bar and back button stay in step.
    'if(!window.__otHist){window.__otHist=1;' +
    // SPA 地址已变化时先释放旧页规则，不能等待异步原生回调才显示详情顶部。
    'function otTell(){try{window.__otApplyTop();if(window.otNative&&window.otNative.onUrlChange){' +
    'window.otNative.onUrlChange("main",String(window.location.href));}}catch(_){}}' +
    'var otPush=history.pushState;' +
    'history.pushState=function(){var r=otPush.apply(this,arguments);otTell();return r;};' +
    'var otRep=history.replaceState;' +
    'history.replaceState=function(){var r=otRep.apply(this,arguments);otTell();return r;};' +
    'window.addEventListener("popstate",function(){otTell();});' +
    'window.addEventListener("hashchange",function(){otTell();});}' +
    'if(!window.__otObs){window.__otPend=0;' +
    'window.__otPass=function(){window.__otPend=0;try{' +
    'window.__otApplyTop&&window.__otApplyTop();' +
    '}catch(e){}};' +
    'window.__otObs=new MutationObserver(function(){' +
    'if(window.__otPend){return;}window.__otPend=1;' +
    'window.__otTimer=setTimeout(window.__otPass,' + CHROME_OBSERVER_MS + ');});' +
    'try{window.__otObs.observe(document.documentElement,{childList:true,subtree:true});}catch(e){}' +
    'window.addEventListener("pagehide",function(e){if(!e.persisted){window.__otObs.disconnect();clearTimeout(window.__otTimer);}}, {once:true});}' +
    'window.__otApplyTop();' +
    '}catch(e){}})(' + nativeNavigation + ',' + nativeHeader + ',' + JSON.stringify(url) + ');';
}

// Cheap follow-up used on in-page (SPA) navigations, which do not always fire
// onPageEnd: flips the tab-root flag and re-runs the removal pass.
export function chromeFlagScript(nativeNavigation: boolean, nativeHeader: boolean, url: string): string {
  return '(function(nav,header,url){try{window.__otNativeNavigation=nav;window.__otNativeHeader=header;window.__otChromeUrl=url;' +
    'window.__otApplyTop&&window.__otApplyTop();}catch(e){}})(' +
    nativeNavigation + ',' + nativeHeader + ',' + JSON.stringify(url) + ');';
}

export function scrollToTopScript(): string {
  return 'window.scrollTo({top:0,behavior:"smooth"});';
}

/** 保留网页回复上下文；评论区回收原帖后，等待其恢复再点击，不能回复可见的第一条评论。 */
export const REPLY_TO_POST_SCRIPT: string = `(function(){
  if(window.__otReplyPending)return;
  var path=location.pathname.toLowerCase(),y=window.scrollY,observer,timer;
  window.__otReplyPending=true;
  function finish(){
    if(observer)observer.disconnect();clearTimeout(timer);window.__otReplyPending=false;
  }
  function open(){
    if(location.pathname.toLowerCase()!==path){finish();return true;}
    var posts=document.querySelectorAll('article[data-testid="tweet"]');
    for(var i=0;i<posts.length;i++){
      var time=posts[i].querySelector('time');
      var link=time&&time.closest('a[href]');
      if(!link||new URL(link.href,location.href).pathname.toLowerCase()!==path)continue;
      var reply=posts[i].querySelector('[data-testid="reply"]');
      finish();window.scrollTo(0,y);
      if(!reply||reply.disabled||reply.getAttribute('aria-disabled')==='true')window.otNative.onReplyUnavailable();
      else reply.click();
      return true;
    }
    return false;
  }
  if(open())return;
  observer=new MutationObserver(open);
  observer.observe(document.documentElement,{childList:true,subtree:true});
  timer=setTimeout(function(){
    finish();
    if(location.pathname.toLowerCase()===path){window.scrollTo(0,y);window.otNative.onReplyUnavailable();}
  },3000);
  window.scrollTo(0,0);
})();`;

/** 复用网页现有链接的路由事件，避免原生标签每次重载整个文档。 */
export function clickRouteScript(url: string): string {
  return `(function(target){
    var wanted=new URL(target,location.href);
    var links=document.querySelectorAll('a[href]');
    for(var i=0;i<links.length;i++){
      var link=new URL(links[i].getAttribute('href'),location.href);
      if(link.origin===wanted.origin&&link.pathname===wanted.pathname&&link.search===wanted.search&&
        links[i].getAttribute('target')!=='_blank'){
        links[i].click();return 'clicked';
      }
    }
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

// Signed-in avatar, read off the account's own profile page. Timeline avatars
// are much smaller, so the size test keeps those out.
export const AVATAR_SCRIPT: string =
  '(function(){try{' +
  'var im=document.querySelectorAll(\'img[src*="profile_images"]\');' +
  'for(var i=0;i<im.length;i++){' +
  'var r=im[i].getBoundingClientRect();' +
  'if(r.width>=60){return String(im[i].getAttribute("src")||"");}}' +
  'return "";}catch(e){return "";}})()';

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
    'var e=document.querySelector(\'[data-testid^="tweetTextarea_0"]\')||' +
    'document.querySelector(\'div[role="textbox"][contenteditable="true"]\')||' +
    'document.querySelector(\'[contenteditable="true"]\');' +
    'if(!e)return \'missing\';' +
    'e.focus();' +
    'try{var s=window.getSelection();var r=document.createRange();' +
    'r.selectNodeContents(e);s.removeAllRanges();s.addRange(r);}catch(_){}' +
    'var ok=false;' +
    'try{ok=document.execCommand(\'insertText\',false,t);}catch(_){ok=false;}' +
    'if(!ok){e.textContent=t;' +
    'try{e.dispatchEvent(new InputEvent(\'input\',{bubbles:true,inputType:\'insertText\',data:t}));}catch(_){}}' +
    'var got=(e.innerText||e.textContent||\'\');' +
    'return got.replace(/\\r\\n?/g,"\\n")===t.replace(/\\r\\n?/g,"\\n")?\'ok\':\'mismatch\';' +
    '}catch(err){return \'error\';}})(' + JSON.stringify(text) + ');';
}

/** 移动网页需打开账号抽屉才能确认本人资料入口，导航沿用网页点击事件。 */
export function profileBootstrapScript(navigate: boolean): string {
  return '(function(navigate){try{' +
  'var btn=null;' +
  'btn=document.querySelector("[data-testid=DashButton_ProfileIcon_Link],[data-testid=SideNav_AccountSwitcher_Button]");' +
  'window.__otBoot="";' +
  'if(!btn){return "nobutton";}' +
  'var opened=!document.querySelector("[role=dialog]");' +
  'if(opened){try{btn.click();}catch(e){return "noclick";}}' +
  'setTimeout(function(){try{' +
  'window.__otBoot=' + OWN_HANDLE_SCRIPT + ';' +
  'if(navigate&&window.__otBoot){var links=document.querySelectorAll("[role=dialog] a[href]");' +
  'for(var i=0;i<links.length;i++){if(links[i].getAttribute("href").toLowerCase()==="/"+window.__otBoot.toLowerCase()){' +
  'links[i].click();return;}}}' +
  'if(opened){var dialog=document.querySelector("[role=dialog]");' +
  'if(dialog){var close=dialog.querySelector("[data-testid=app-bar-close]");' +
  'if(close)close.click();else btn.click();}}' +
  '}catch(e){window.__otBoot="";}},1500);' +
  'return "armed";' +
  '}catch(e){window.__otBoot="";return "err";}})(' + navigate + ')';
}
