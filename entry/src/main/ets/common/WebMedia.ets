/** 帖子图片和头像可直接查看；卡片仍保留点击导航，仅长按查看图片。 */
export interface MediaAddress {
  id: string;
  source: string;
  candidates: string[];
}

export interface MediaPostState {
  postId: string;
  postUrl: string;
  liked?: boolean;
  bookmarked?: boolean;
  reposted?: boolean;
}

export interface MediaActionResult {
  requestId: number;
  postId: string;
  status: string;
  liked?: boolean;
  bookmarked?: boolean;
  reposted?: boolean;
  quoteUrl?: string;
}

/** 被动确认网页发出的互动请求，避免将乐观变色当作服务端成功。 */
export const MEDIA_ACTION_RESPONSE_SCRIPT: string = `(function(){
  if(window.__otMediaResponseHook)return;
  window.__otMediaResponseHook=true;
  function request(url,body){
    var action=window.__otMediaAction;
    if(!action||!body||typeof body!=='string')return null;
    var path=new URL(url,location.href).pathname,operation=path.substring(path.lastIndexOf('/')+1);
    var allowed=action.action==='like'?['FavoriteTweet','UnfavoriteTweet']:action.action==='bookmark'?
      ['CreateBookmark','DeleteBookmark']:action.action==='repost'?['CreateRetweet','DeleteRetweet']:[];
    if(allowed.indexOf(operation)<0)return null;
    try{
      var variables=JSON.parse(body).variables;
      if(!variables||String(variables.tweet_id||variables.source_tweet_id)!==action.postId)return null;
      return action;
    }catch(error){action.failed=true;return null;}
  }
  function response(action,status,data){
    if(!action||window.__otMediaAction!==action)return;
    if(status!==200||!data||data.errors||!data.data){action.failed=true;return;}
    action.ack=true;
  }
  var send=XMLHttpRequest.prototype.send;
  var open=XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open=function(method,url){this.__otMediaUrl=String(url);return open.apply(this,arguments);};
  XMLHttpRequest.prototype.send=function(body){
    var action=request(this.__otMediaUrl||'',body);
    if(action)this.addEventListener('loadend',function(){
      try{response(action,this.status,this.responseType==='json'?this.response:JSON.parse(this.responseText));}
      catch(error){action.failed=true;}
    },{once:true});
    return send.apply(this,arguments);
  };
  var fetch=window.fetch;
  window.fetch=function(input,options){
    var action=request(typeof input==='string'?input:input.url,options&&options.body);
    var task=fetch.apply(this,arguments);
    if(action)task.then(function(res){res.clone().json().then(function(data){response(action,res.status,data);},function(){action.failed=true;});},function(){action.failed=true;});
    return task;
  };
})();`;

/** 手动原图与网页尺寸使用不同缓存键，失败不冒充成功加载原图。 */
export function imageForQuality(address: MediaAddress, original: boolean, explicit: boolean = false): MediaAddress {
  if (!address.id.startsWith('avatar-') && !address.id.startsWith('card-')) {
    return { id: address.id + (original ? (explicit ? '-original-only' : '-original-auto') : '-preview'), source: address.source,
      candidates: original ? (explicit ? address.candidates.filter((url: string) => /[?&]name=orig(?:&|$)/.test(url)) :
        address.candidates) : [address.source] };
  }
  return address;
}

/** 动作只作用于打开图片时捕获的原帖节点，不搜索其他相似帖子。 */
export function mediaActionScript(postId: string, requestId: number, action: string, start: boolean): string {
  return MEDIA_ACTION_RESPONSE_SCRIPT + `(function(){
    var post=window.__otMediaPost;
    var result={requestId:${requestId},postId:${JSON.stringify(postId)},status:'unavailable'};
    if(!post||post.id!==result.postId||!post.node.isConnected)return JSON.stringify(result);
    var node=post.node;
    function state(){
      var like=node.querySelector('[data-testid="like"],[data-testid="unlike"]');
      var bookmark=node.querySelector('[data-testid="bookmark"],[data-testid="removeBookmark"]');
      var repost=node.querySelector('[data-testid="retweet"],[data-testid="unretweet"]');
      if(like)result.liked=like.dataset.testid==='unlike';
      if(bookmark)result.bookmarked=bookmark.dataset.testid==='removeBookmark';
      if(repost)result.reposted=repost.dataset.testid==='unretweet';
    }
    state();
    var action=${JSON.stringify(action)};
    if(${start}){
      var selector=action==='like'?'[data-testid="like"],[data-testid="unlike"]':action==='bookmark'?
        '[data-testid="bookmark"],[data-testid="removeBookmark"]':'[data-testid="retweet"],[data-testid="unretweet"]';
      var button=node.querySelector(selector);
      if(!button||button.disabled)return JSON.stringify(result);
      window.__otMediaAction={id:result.requestId,postId:result.postId,action:action,initial:action==='like'?result.liked:action==='bookmark'?result.bookmarked:result.reposted,confirmed:false,ack:false,failed:false};
      button.click();result.status='pending';return JSON.stringify(result);
    }
    var pending=window.__otMediaAction;
    if(!pending||pending.id!==result.requestId)return JSON.stringify(result);
    if(pending.failed){result.status='failed';return JSON.stringify(result);}
    if(action==='quote'){
      var link=document.querySelector('[role="menu"] a[href*="/compose/"],[data-testid="Dropdown"] a[href*="/compose/"]');
      if(link){result.status='quote';result.quoteUrl=link.href;}else result.status='pending';
      return JSON.stringify(result);
    }
    if(action==='repost'&&!pending.confirmed){
      var confirm=document.querySelector('[data-testid="retweetConfirm"],[data-testid="unretweetConfirm"]');
      if(confirm){pending.confirmed=true;confirm.click();}
    }
    var current=action==='like'?result.liked:action==='bookmark'?result.bookmarked:result.reposted;
    result.status=pending.ack&&typeof current==='boolean'&&current!==pending.initial?'done':'pending';
    return JSON.stringify(result);
  })()`;
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
    const large = original.replace(/(\.[a-z]+)$/i, '_400x400$1');
    const candidates = original === source ? [source] : [original];
    if (large !== source && original !== source) { candidates.push(large); }
    if (original !== source) { candidates.push(source); }
    return { id: 'avatar-' + avatar[1] + '-' + avatar[2], source: source,
      candidates: candidates };
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
    var node=scope.closest('article[data-testid="tweet"]');
    var payload={urls:urls,index:index};
    if(node){
      var like=node.querySelector('[data-testid="like"],[data-testid="unlike"]');
      var bookmark=node.querySelector('[data-testid="bookmark"],[data-testid="removeBookmark"]');
      var repost=node.querySelector('[data-testid="retweet"],[data-testid="unretweet"]');
      payload.postId=match[1];payload.postUrl=route.origin+route.pathname.replace(/\\/photo\\/\\d+$/,'');
      if(like)payload.liked=like.dataset.testid==='unlike';
      if(bookmark)payload.bookmarked=bookmark.dataset.testid==='removeBookmark';
      if(repost)payload.reposted=repost.dataset.testid==='unretweet';
      window.__otMediaPost={id:match[1],node:node};
    }
    if(window.otNative.onImages(JSON.stringify(payload))===true){
      e.preventDefault();e.stopImmediatePropagation();
    }
  },true);
})();`;
