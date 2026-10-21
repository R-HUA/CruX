/** 底栏使用稳定标识，开关只改变呈现顺序，不改变路由含义。 */
export const DEFAULT_TABS: number[] = [0, 1, 2, 3, 4];

export const PLATFORM_SETTINGS: string[] = [
  '/settings/account', '/settings/security_and_account_access', '/settings/privacy_and_safety',
  '/settings/notifications', '/settings/accessibility_display_and_languages', '/settings/about'
];

/** 页面配色只在当前客户端生效，不写入 X 账号偏好。 */
export function appearanceScript(mode: string): string {
  return `(function(){
    window.__otAppearanceMode=${JSON.stringify(mode)};
    if(!window.__otAppearanceApply){
      window.__otAppearanceApply=function(){
        if(!document.head)return;
        var dark=window.__otAppearanceMode==='dark'||(window.__otAppearanceMode==='system'&&matchMedia('(prefers-color-scheme: dark)').matches);
        var bg=dark?'#000000':'#ffffff',fg=dark?'#e7e9ea':'#0f1419',secondary=dark?'#71767b':'#536471';
        var style=document.getElementById('ot-client-appearance');
        if(!style){style=document.createElement('style');style.id='ot-client-appearance';document.head.appendChild(style);}
        var css='html,body,[data-testid="primaryColumn"],[data-testid="sidebarColumn"],[data-testid="TopNavBar"],[role="dialog"],[role="menu"]{background-color:'+bg+'!important;color:'+fg+'!important;color-scheme:'+(dark?'dark':'light')+'}';
        var exclude=':not(button):not([role="button"]):not(button *):not([role="button"] *)';
        css+='[style*="background-color: rgb(255, 255, 255)"]'+exclude+',[style*="background-color: rgb(0, 0, 0)"]'+exclude+',[style*="background-color: rgb(21, 32, 43)"]'+exclude+'{background-color:'+bg+'!important}';
        css+='[style*="color: rgb(15, 20, 25)"]'+exclude+',[style*="color: rgb(231, 233, 234)"]'+exclude+',[style*="color: rgb(247, 249, 249)"]'+exclude+'{color:'+fg+'!important}';
        css+='[style*="color: rgb(83, 100, 113)"],[style*="color: rgb(113, 118, 123)"]{color:'+secondary+'!important}';
        if(style.textContent!==css)style.textContent=css;
      };
      matchMedia('(prefers-color-scheme: dark)').addEventListener('change',window.__otAppearanceApply);
      new MutationObserver(window.__otAppearanceApply).observe(document,{childList:true,subtree:true});
    }
    window.__otAppearanceApply();
  })();`;
}

/** 只读取已确认账号的资料头，避免把时间线作者误作本人。 */
export function accountDetailsScript(handle: string): string {
  return `(function(){
    if(location.pathname.toLowerCase()!=='/'+${JSON.stringify(handle.toLowerCase())})return '';
    var names=Array.from(document.querySelectorAll('main [data-testid="UserName"]'));
    var node=names.find(function(n){return !n.closest('article')&&n.textContent.toLowerCase().indexOf('@'+${JSON.stringify(handle.toLowerCase())})>=0;});
    if(!node)return '';
    var name=node.querySelector('[dir]'),bio=document.querySelector('main [data-testid="UserDescription"]');
    return JSON.stringify({handle:${JSON.stringify(handle)},name:name?name.textContent.trim():'',bio:bio?bio.textContent.trim():''});
  })()`;
}
