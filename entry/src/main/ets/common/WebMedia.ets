/** 帖子图片和头像可直接查看；卡片仍保留点击导航，仅长按查看图片。 */
export interface MediaAddress {
  id: string;
  source: string;
  candidates: string[];
}

/** 默认头像只供账号图标下载，不接管网页中的点击。 */
export function isMediaDownloadUrl(source: string): boolean {
  return resolveMedia(source) !== undefined ||
    /^https:\/\/abs\.twimg\.com\/sticky\/default_profile_images\/[A-Za-z0-9_-]+\.(png|jpg|jpeg|webp)$/i.test(source);
}

export function resolveMedia(source: string): MediaAddress | undefined {
  const avatar = /^https:\/\/pbs\.twimg\.com\/profile_images\/([0-9]+)\/([A-Za-z0-9_-]+)\.(jpg|jpeg|png|webp|gif)$/i.exec(source);
  if (avatar) {
    const original = source.replace(/_(normal|bigger|400x400)(?=\.[a-z]+$)/i, '');
    return { id: 'avatar-' + avatar[1] + '-' + avatar[2], source: source,
      candidates: original === source ? [source] : [original, source] };
  }
  if (/\s|\\|\/\.\.?(\/|\?|$)/.test(source)) { return undefined; }
  const card = /^https:\/\/pbs\.twimg\.com\/(card_img|amplify_video_thumb|ext_tw_video_thumb)\/([A-Za-z0-9_/-]+)(?:\.(jpg|jpeg|png|webp))?(?:\?[^#]*)?$/i.exec(source);
  if (card) {
    return { id: 'card-' + card[1] + '-' + card[2].replace(/\//g, '-'), source: source, candidates: [source] };
  }
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
    var avatarLink=target&&target.closest('a[href]');
    if(avatarLink&&/^\\/[A-Za-z0-9_]{1,15}\\/photo$/.test(new URL(avatarLink.href,location.href).pathname)){
      var avatar=avatarLink.querySelector('img');
      var source=avatar&&(avatar.currentSrc||avatar.src);
      if(source&&/^https:\\/\\/pbs\\.twimg\\.com\\/profile_images\\//.test(source)&&window.otNative&&window.otNative.onImages&&
        window.otNative.onImages(JSON.stringify({urls:[source],index:0}))===true){
        e.preventDefault();e.stopImmediatePropagation();
      }
      return;
    }
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
