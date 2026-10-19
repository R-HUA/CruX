/** 仅接管帖子静态图片，头像、视频封面和其他地址仍由网页处理。 */
export interface MediaAddress {
  id: string;
  source: string;
  candidates: string[];
}

export function resolveMedia(source: string): MediaAddress | undefined {
  const match = /^https:\/\/pbs\.twimg\.com\/media\/([A-Za-z0-9_-]+)(?:\.(jpg|jpeg|png|webp))?(?::(?:orig|large|medium|small|thumb|4096x4096))?(?:\?([^#]*))?$/i.exec(source);
  if (!match) { return undefined; }
  const formatMatch = /(?:^|&)format=(jpg|jpeg|png|webp)(?:&|$)/i.exec(match[3] || '');
  const format = (formatMatch ? formatMatch[1] : match[2] || 'jpg').toLowerCase().replace('jpeg', 'jpg');
  const formats = format === 'png' ? ['png', 'jpg'] : format === 'webp' ? ['webp', 'jpg', 'png'] : ['jpg', 'png'];
  const base = 'https://pbs.twimg.com/media/' + match[1];
  const candidates: string[] = formats.map((value: string) => base + '?format=' + value + '&name=orig');
  candidates.push(base + '?format=' + format + '&name=4096x4096');
  candidates.push(base + '?format=' + format + '&name=large');
  if (candidates.indexOf(source) < 0) { candidates.push(source); }
  return { id: match[1], source: source, candidates: candidates };
}

/** 先确认原生层接收成功再阻断网页；同帖引用卡片不会混入当前相册。 */
export const MEDIA_CLICK_SCRIPT: string = `(function(){
  if(window.__otMediaHooked)return;
  window.__otMediaHooked=true;
  document.addEventListener('click',function(e){
    if(e.button!==0||e.ctrlKey||e.metaKey||e.shiftKey||e.altKey)return;
    var target=e.target instanceof Element?e.target:null;
    var photo=target&&target.closest('[data-testid="tweetPhoto"]');
    var link=photo&&photo.closest('a[href]');
    if(!photo||!link||!window.otNative||!window.otNative.onImages)return;
    var route=new URL(link.href,location.href);
    var match=route.pathname.match(/^\\/[^/]+\\/status\\/(\\d+)\\/photo\\/\\d+$/);
    if(!match)return;
    var scope=photo.closest('article[data-testid="tweet"]')||photo;
    var links=Array.from(scope.querySelectorAll('a[href]'));
    if(scope===photo)links=[link];
    var urls=[];
    links.forEach(function(a){
      var p=new URL(a.href,location.href).pathname;
      if(!new RegExp('^/[^/]+/status/'+match[1]+'/photo/[0-9]+$').test(p))return;
      var img=a.querySelector('[data-testid="tweetPhoto"] img')||a.querySelector('img');
      var src=img&&(img.currentSrc||img.src);
      if(src&&/^https:\\/\\/pbs\\.twimg\\.com\\/media\\//.test(src)&&urls.indexOf(src)<0)urls.push(src);
    });
    var image=photo.querySelector('img');
    var index=image?urls.indexOf(image.currentSrc||image.src):-1;
    if(index<0||urls.length>4)return;
    if(window.otNative.onImages(JSON.stringify({urls:urls,index:index}))===true){
      e.preventDefault();e.stopImmediatePropagation();
    }
  },true);
})();`;
