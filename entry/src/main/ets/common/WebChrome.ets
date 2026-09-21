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
const CHROME_CSS: string =
  "nav[aria-label='Primary']{display:none!important}" +
  "[data-testid='FloatingActionButtons_Tweet_Button']{display:none!important}";

// Finds the signed-in user's own profile link in X's navigation and returns its
// href (always /handle), else ''. Used once after sign-in to learn the handle,
// which the native Profile tab and title then use.
export const DISCOVER_OWN_HANDLE_SCRIPT: string =
  '(function(){try{' +
  'var b=document.querySelectorAll(\'nav a[href^="/"]\');' +
  'var pool=(b&&b.length)?b:(function(){var c=document.querySelector(\'div[data-testid="primaryColumn"]\');' +
  'return c?c.querySelectorAll(\'a[href^="/"]\'):[];})();' +
  'var r={\'/home\':1,\'/explore\':1,\'/notifications\':1,\'/messages\':1,\'/grok\':1,\'/communities\':1,' +
  '\'/premium\':1,\'/verified-organizations\':1,\'/jobs\':1,\'/login\':1,\'/signup\':1};' +
  'for(var i=0;i<pool.length;i++){var h=pool[i].getAttribute(\'href\');if(!h)continue;' +
  'h=h.split(\'?\')[0].split(\'#\')[0];' +
  'if(r[h]||h.indexOf(\'/i/\')===0||h.indexOf(\'/settings\')===0)continue;' +
  'if(h.length>1&&h.length<17&&h.charAt(0)===\'/\'){var ok=1;' +
  'for(var j=1;j<h.length;j++){var ch=h.charAt(j);' +
  'if(!((ch>=\'a\'&&ch<=\'z\')||(ch>=\'A\'&&ch<=\'Z\')||(ch>=\'0\'&&ch<=\'9\')||ch===\'_\')){ok=0;break;}}' +
  'if(ok)return h;}}return \'\';}catch(e){return \'\';}})()';

// Installs the chrome CSS plus a MutationObserver-driven top-chrome remover.
// X re-renders client-side after onPageEnd fires, so a one-shot removal is not
// enough. tabRoot=true means the current URL is a tab root, where the native
// header replaces X's header row; sub-pages keep their own header (back button,
// profile name) because the shell shows a back button only for web history.
export function chromeScript(ownHandle: string, tabRoot: boolean): string {
  return '(function(root,handle){try{' +
    'window.__otHandle=handle;' +
    'var css=document.getElementById(\'ot-hidenav\');' +
    'if(!css){css=document.createElement(\'style\');css.id=\'ot-hidenav\';' +
    'css.textContent="' + CHROME_CSS + '";document.head.appendChild(css);}' +
    'window.__otApplyTop=function(){try{' +
    'function H(e){try{if(!e||e.hasAttribute(\'data-ot-hide\'))return;' +
    'e.style.display=\'none\';e.setAttribute(\'data-ot-hide\',\'1\');}catch(_){}}' +
    'function R(e){try{return e.getBoundingClientRect();}catch(_){return null;}}' +
    'function T(e){var r=R(e);return r&&r.top<=120&&r.height>0&&r.height<160;}' +
    'function Q(s){try{return document.querySelector(s);}catch(_){return null;}}' +
    'function QA(s){try{return document.querySelectorAll(s);}catch(_){return [];}}' +
    'if(!window.__otHideTop){' +
    'var olds=QA(\'[data-ot-hide]\');' +
    'for(var k=0;k<olds.length;k++){try{olds[k].style.display=\'\';olds[k].removeAttribute(\'data-ot-hide\');}catch(_){}}' +
    'return;}' +
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
    'if(pr&&pr.top<=120&&pr.height>8&&pr.width>0&&pe.style.display!==\'none\'){need=1;break;}}}' +
    'if(!need)return;' +
    'for(var u=0;u<hid.length;u++){try{hid[u].style.display=\'\';hid[u].removeAttribute(\'data-ot-hide\');}catch(_){}}' +
    'var tnb=Q(\'div[data-testid="TopNavBar"]\')||Q(\'[aria-label="TopNavBar"]\');' +
    'if(tnb){var tnt=0;try{tnt=tnb.querySelector(\'[role="tablist"]\')?1:0;}catch(_){} if(!tnt&&T(tnb))H(tnb);}' +
    'var s=Q(\'[data-testid^="SearchBox"]\')||Q(\'form[role="search"]\')||Q(\'[role="combobox"]\');' +
    'if(s&&T(s))H(s);' +
    'var links=QA(\'a[href^="/settings"],a[href="/messages/compose"],a[href^="/premium"],a[href^="/i/premium"],a[href="/login"]\');' +
    'for(var i=0;i<links.length;i++){if(T(links[i]))H(links[i]);}' +
    'var logo=Q(\'a[href="/home"]\')||Q(\'a[href="/"]\')||Q(\'svg[aria-label="X"]\')||Q(\'a[aria-label="X"]\')||Q(\'a[aria-label="Home"]\');' +
    'if(logo){var lk=logo;try{lk=logo.closest(\'a\')||logo;}catch(_){} if(T(lk))H(lk);}' +
    'if(window.__otHandle){' +
    'var als=QA(\'a[href]\');' +
    'for(var j=0;j<als.length;j++){try{var h=als[j].getAttribute(\'href\');' +
    'if(!h||h.toLowerCase()!==\'/\'+window.__otHandle)continue;' +
    'if(!als[j].querySelector(\'img\'))continue;' +
    'if(T(als[j]))H(als[j]);}catch(_){}}}' +
    'var ac=Q(\'[data-testid^="SearchBox"]\')||Q(\'form[role="search"]\')||Q(\'a[href="/home"]\')||Q(\'a[href="/"]\')||Q(\'svg[aria-label="X"]\');' +
    'if(ac){var ce=ac,guard=0,best=null;' +
    'while(ce&&ce!==document.body&&guard++<10){var cr=R(ce);' +
    'if(!cr||cr.height<=0||cr.height>=220||cr.top>120)break;' +
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
    'var heads=QA(\'h1,h2\');' +
    'for(var m=0;m<heads.length;m++){try{var t=(heads[m].textContent||\'\').trim().toLowerCase();' +
    'if(t!==\'home\'&&t!==\'explore\'&&t!==\'notifications\'&&t!==\'messages\'&&t!==\'profile\')continue;' +
    'var hr=R(heads[m]);' +
    'if(hr&&hr.top<=120&&hr.height>8&&hr.height<160)H(heads[m]);}catch(_){}}' +
    '}catch(e){}};' +
    'window.__otHideTop=root;' +
    'if(!window.__otObs){window.__otObs=new MutationObserver(' +
    'function(){try{window.__otApplyTop&&window.__otApplyTop();}catch(e){}});' +
    'try{window.__otObs.observe(document.documentElement,{childList:true,subtree:true});}catch(e){}}' +
    'window.__otApplyTop();' +
    '}catch(e){}})(' + (tabRoot ? 'true' : 'false') + ',\'' + ownHandle + '\');';
}

// Cheap follow-up used on in-page (SPA) navigations, which do not always fire
// onPageEnd: flips the tab-root flag and re-runs the removal pass.
export function chromeFlagScript(tabRoot: boolean): string {
  return '(function(f){try{window.__otHideTop=f;' +
    'window.__otApplyTop&&window.__otApplyTop();}catch(e){}})(' +
    (tabRoot ? 'true' : 'false') + ');';
}

export function scrollToTopScript(): string {
  return 'window.scrollTo({top:0,behavior:"smooth"});';
}

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
