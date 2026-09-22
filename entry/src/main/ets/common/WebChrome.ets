// OpenTwit-Web runs the real x.com web app inside a native HarmonyOS shell.
// "Native" means the shell owns every piece of app chrome: title bar, menus,
// search field, tab bar / rail, compose sheet, progress, error and empty states.
// The scripts below remove x.com's own copy of that chrome (its top nav, its
// bottom nav and its floating compose button) so the two never double up, and
// they report page state back to the shell.
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
  "[data-testid='FloatingActionButtons_Tweet_Button']{display:none!important}" +
  // Wide layouts: x.com renders its desktop side navigation, whose account
  // button sits in the corner the shell's own rail occupies.
  "[data-testid='SideNav_AccountSwitcher_Button']{display:none!important}" +
  FONT_CSS;

// Handle of the account the page is signed in as, or ''. Exposed by the
// observer below as window.__otOwn(), which re-scans on every DOM mutation:
// x.com hydrates the navigation client-side, so the account links do not exist
// yet when onPageEnd fires and a single synchronous read always comes back
// empty on the mobile web.
export const OWN_HANDLE_SCRIPT: string = '(window.__otOwn?window.__otOwn():"")';

// How often the chrome pass may re-run when it is reacting to page mutations.
// The first pass stays immediate (no double chrome on first paint); only the
// re-runs are paced. x.com mutates its DOM continuously — timelines, and far
// more so on the chat screen — and every pass walks the document and forces
// layout, so an unpaced observer is a lot of work for nothing.
const CHROME_OBSERVER_MS: number = 250;

export function chromeScript(ownHandle: string, tabRoot: boolean, band: number): string {
  // The shell draws the header on every page, so the page's own header rows are
  // always removed. "band" is how far down the page its header can sit — the
  // same row is near the top on a phone and much lower on a wide layout.
  return '(function(root,handle,B){try{' +
    'window.__otHandle=handle;window.__otBand=B;' +
    'var css=document.getElementById(\'ot-hidenav\');' +
    'if(!css){css=document.createElement(\'style\');css.id=\'ot-hidenav\';' +
    'css.textContent="' + CHROME_CSS + '";document.head.appendChild(css);}' +
    'window.__otApplyTop=function(){try{' +
    'var b=window.__otBand||B;' +
    'function H(e){try{if(!e||e.hasAttribute(\'data-ot-hide\'))return;' +
    'e.style.display=\'none\';e.setAttribute(\'data-ot-hide\',\'1\');}catch(_){}}' +
    'function R(e){try{return e.getBoundingClientRect();}catch(_){return null;}}' +
    'function T(e){var r=R(e);return r&&r.top<=b&&r.height>0&&r.height<160;}' +
    'function Q(s){try{return document.querySelector(s);}catch(_){return null;}}' +
    'function QA(s){try{return document.querySelectorAll(s);}catch(_){return [];}}' +
    'var hid=QA(\'[data-ot-hide]\');' +
    'var need=!hid||!hid.length;' +
    'if(!need){' +
    'var probes=[\'[data-testid^="SearchBox"]\',\'form[role="search"]\',\'a[href^="/settings"]\',' +
    '\'a[href="/messages/compose"]\',\'a[href="/home"]\',\'a[href="/"]\',' +
    '\'svg[aria-label="X"]\',\'a[aria-label="X"]\',\'a[aria-label="Home"]\',' +
    '\'a[href^="/premium"]\',\'a[href^="/i/premium"]\',\'a[href="/login"]\',' +
    '\'div[data-testid="TopNavBar"]\',\'[aria-label="TopNavBar"]\'];' +
    'for(var p=0;p<probes.length;p++){var pe=Q(probes[p]);if(!pe)continue;' +
    'var pr=R(pe);' +
    'if(pr&&pr.top<=b&&pr.height>8&&pr.width>0&&pe.style.display!==\'none\'){need=1;break;}}}' +
    'if(!need)return;' +
    'for(var u=0;u<hid.length;u++){try{hid[u].style.display=\'\';hid[u].removeAttribute(\'data-ot-hide\');}catch(_){}}' +
    'var tnb=Q(\'div[data-testid="TopNavBar"]\')||Q(\'[aria-label="TopNavBar"]\');' +
    'if(tnb){var tnt=0;try{tnt=tnb.querySelector(\'[role="tablist"]\')?1:0;}catch(_){} if(!tnt&&T(tnb))H(tnb);}' +
    'var s=Q(\'[data-testid^="SearchBox"]\')||Q(\'form[role="search"]\')||Q(\'[role="combobox"]\');' +
    // On a tab root the shell owns search, so the page's own search box goes
    // whatever row it landed in (it sits much lower on a wide layout than the
    // phone-tuned top band would cover).
    'if(s&&(root||T(s)))H(s);' +
    'var links=QA(\'a[href^="/settings"],a[href="/messages/compose"],a[href^="/premium"],a[href^="/i/premium"],a[href="/login"]\');' +
    'for(var i=0;i<links.length;i++){if(T(links[i]))H(links[i]);}' +
    'var logo=Q(\'a[href="/home"]\')||Q(\'a[href="/"]\')||Q(\'svg[aria-label="X"]\')||Q(\'a[aria-label="X"]\')||Q(\'a[aria-label="Home"]\');' +
    'if(logo){var lk=logo;try{lk=logo.closest(\'a\')||logo;}catch(_){}' +
    'if(root||T(lk))H(lk);}' +
    'if(window.__otHandle){' +
    'var als=QA(\'a[href]\');' +
    'for(var j=0;j<als.length;j++){try{var h=als[j].getAttribute(\'href\');' +
    'if(!h||h.toLowerCase()!==\'/\'+window.__otHandle)continue;' +
    'if(!als[j].querySelector(\'img\'))continue;' +
    'if(T(als[j]))H(als[j]);}catch(_){}}}' +
    'var ac=Q(\'[data-testid^="SearchBox"]\')||Q(\'form[role="search"]\')||Q(\'a[href="/home"]\')||Q(\'a[href="/"]\')||Q(\'svg[aria-label="X"]\');' +
    'if(ac){var ce=ac,guard=0,best=null;' +
    'while(ce&&ce!==document.body&&guard++<10){var cr=R(ce);' +
    'if(!cr||cr.height<=0||cr.height>=220||cr.top>b)break;' +
    'try{if(ce.querySelector(\'[role="tablist"]\'))break;}catch(_){}' +
    'try{if((ce.innerText||\'\').replace(/\\s+/g,\'\').length<60)best=ce;}catch(_){}' +
    'ce=ce.parentElement;}' +
    'if(best)H(best);}' +
    'var hdrs=QA(\'header,div[role="banner"]\');' +
    'for(var hb=0;hb<hdrs.length;hb++){try{' +
    'if(hdrs[hb].querySelector(\'[role="tablist"]\'))continue;' +
    'var htxt=(hdrs[hb].innerText||\'\').replace(/\\s+/g,\'\');' +
    'if(htxt.length>=100)continue;' +
    'if(T(hdrs[hb]))H(hdrs[hb]);}catch(_){}}' +
    // The page's own back bar (wide layouts keep one that sits outside the
    // header/banner rules). Its row goes; the tab row under it stays.
    'var bk=Q(\'[data-testid="app-bar-back"]\');' +
    'if(bk){var bp=bk.parentElement;if(bp&&T(bp))H(bp);}' +
    'var heads=QA(\'h1,h2\');' +
    'for(var m=0;m<heads.length;m++){try{var t=(heads[m].textContent||\'\').trim().toLowerCase();' +
    'if(t!==\'home\'&&t!==\'explore\'&&t!==\'notifications\'&&t!==\'messages\'&&t!==\'profile\')continue;' +
    'var hr=R(heads[m]);' +
    'if(hr&&hr.top<=b&&hr.height>8&&hr.height<160)H(heads[m]);}catch(_){}}' +
    '}catch(e){}};' +
    // Own-account handle. The page renders its navigation after hydration, so
    // this is installed here and re-run by the observer below instead of being
    // read once when the page first reports that it finished loading.
    'window.__otOwn=function(){try{' +
    // Once the handle is known there is nothing left to look for, and this runs
    // on every page mutation otherwise.
    'if(window.__otHandleValue){return window.__otHandleValue;}' +
    'var as=document.querySelectorAll("a[href]");' +
    'for(var i=0;i<as.length;i++){' +
    'var k=as[i].getAttribute("data-testid")||"";' +
    'if(k!=="AppTabBar_Profile_Link"&&k!=="DashButton_ProfileIcon_Link"&&k!=="SideNav_AccountSwitcher_Button")continue;' +
    'var h=as[i].getAttribute("href")||"";' +
    'if(h.charAt(0)!=="/"||h.length<2||h.length>16)continue;' +
    'var ok=1;' +
    'for(var j=1;j<h.length;j++){var c=h.charCodeAt(j);' +
    'if(!((c>=97&&c<=122)||(c>=65&&c<=90)||(c>=48&&c<=57)||c===95)){ok=0;break;}}' +
    'if(ok){window.__otHandleValue=h.substring(1);return window.__otHandleValue;}}' +
    '}catch(e){}return window.__otHandleValue||"";};' +
    // x.com navigates like an app (history.pushState), which does not reload
    // the page and therefore never reaches the shell through the Web component
    // callbacks. Hook the history API and report every change to the native
    // bridge so the header, tab bar and back button stay in step.
    'if(!window.__otHist){window.__otHist=1;' +
    'function otTell(){try{if(window.otNative&&window.otNative.onUrlChange){' +
    'window.otNative.onUrlChange(String(window.location.href));}}catch(_){}}' +
    'var otPush=history.pushState;' +
    'history.pushState=function(){var r=otPush.apply(this,arguments);otTell();return r;};' +
    'var otRep=history.replaceState;' +
    'history.replaceState=function(){var r=otRep.apply(this,arguments);otTell();return r;};' +
    'window.addEventListener("popstate",function(){otTell();});' +
    'window.addEventListener("hashchange",function(){otTell();});}' +
    'window.__otHideTop=true;' +
    'if(!window.__otObs){window.__otPend=0;' +
    'window.__otPass=function(){window.__otPend=0;try{' +
    'window.__otApplyTop&&window.__otApplyTop();' +
    'window.__otOwn&&window.__otOwn();}catch(e){}};' +
    'window.__otObs=new MutationObserver(function(){' +
    'if(window.__otPend){return;}window.__otPend=1;' +
    'setTimeout(window.__otPass,' + CHROME_OBSERVER_MS + ');});' +
    'try{window.__otObs.observe(document.documentElement,{childList:true,subtree:true});}catch(e){}}' +
    'window.__otApplyTop();' +
    'window.__otOwn();' +
    '}catch(e){}})(' + (tabRoot ? 'true' : 'false') + ',\'' + ownHandle + '\',' + band + ');';
}

// Cheap follow-up used on in-page (SPA) navigations, which do not always fire
// onPageEnd: flips the tab-root flag and re-runs the removal pass.
export function chromeFlagScript(tabRoot: boolean, band: number): string {
  return '(function(f,B){try{window.__otHideTop=f;window.__otBand=B;' +
    'window.__otApplyTop&&window.__otApplyTop();}catch(e){}})(' +
    (tabRoot ? 'true' : 'false') + ',' + band + ');';
}

export function scrollToTopScript(): string {
  return 'window.scrollTo({top:0,behavior:"smooth"});';
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
export const CLICK_POST_BUTTON_SCRIPT: string =
  '(function(){try{' +
  'var b=document.querySelector(\'[data-testid="tweetButton"]\')||' +
  'document.querySelector(\'[data-testid="tweetButtonInline"]\')||' +
  'document.querySelector(\'button[data-testid="tweetButton"]\');' +
  'if(!b)return \'missing\';' +
  'if(b.getAttribute(\'aria-disabled\')===\'true\'||b.disabled)return \'disabled\';' +
  'b.click();return \'ok\';}catch(e){return \'error\';}})()';

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
    'var head=t.substring(0,t.length>8?8:t.length);' +
    'return (head===\'\'||got.indexOf(head)>=0)?\'ok\':\'empty\';' +
    '}catch(err){return \'error\';}})(' + JSON.stringify(text) + ');';
}

// The mobile web renders the account entry as a button with no href, so the
// handle only exists inside the account menu that button opens. This opens the
// menu, reads the handle, closes it again, and leaves the answer in
// window.__otBoot. The shell covers the page with a native panel while it runs,
// so the user sees a HarmonyOS spinner rather than a menu flashing open.
export const PROFILE_BOOTSTRAP_SCRIPT: string =
  '(function(){try{' +
  'var btn=null;' +
  'var ds=document.querySelectorAll("[data-testid]");' +
  'for(var i=0;i<ds.length;i++){' +
  'if((ds[i].getAttribute("data-testid")||"")==="DashButton_ProfileIcon_Link"){btn=ds[i];break;}}' +
  'window.__otBoot="";' +
  'if(!btn){return "nobutton";}' +
  'try{btn.click();}catch(e){return "noclick";}' +
  'setTimeout(function(){try{' +
  'var r={"/home":1,"/explore":1,"/notifications":1,"/messages":1,"/i":1,"/grok":1,' +
  '"/communities":1,"/premium":1,"/jobs":1,"/login":1,"/signup":1,"/settings":1,' +
  '"/logout":1,"/compose":1,"/search":1,"/tos":1,"/privacy":1,"/about":1,"/intent":1};' +
  'var as=document.querySelectorAll("a[href]");' +
  'for(var j=0;j<as.length;j++){' +
  'var h=as[j].getAttribute("href")||"";' +
  'if(h.charAt(0)!=="/"||h.length<2||h.length>16){continue;}' +
  'if(r[h]){continue;}' +
  'var ok=1;' +
  'for(var k=1;k<h.length;k++){var c=h.charCodeAt(k);' +
  'if(!((c>=97&&c<=122)||(c>=65&&c<=90)||(c>=48&&c<=57)||c===95)){ok=0;break;}}' +
  'if(ok){window.__otBoot=h.substring(1);break;}}' +
  'window.__otBootAll=(window.__otBoot||"none")+"/"+as.length;' +
  'try{btn.click();}catch(e){}' +
  '}catch(e){window.__otBoot="";}},1500);' +
  'return "armed";' +
  '}catch(e){window.__otBoot="";return "err";}})()';
