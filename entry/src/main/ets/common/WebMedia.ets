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

/** 媒体网格恢复使用原页面和实际滚动容器的位置。 */
export interface MediaOrigin {
  url: string;
  x: number;
  y: number;
  scrollSelector: string;
  scrollTop: number;
  scrollLeft: number;
}

export interface MediaActionResult {
  requestId: number;
  postId: string;
  status: 'ready' | 'unavailable' | 'pending' | 'done' | 'failed' | 'unknown' | 'cancelled' | 'quote';
  liked?: boolean;
  bookmarked?: boolean;
  reposted?: boolean;
  quoteUrl?: string;
  target?: boolean;
}

/** 被动确认网页发出的互动请求，避免将乐观变色当作服务端成功。 */
export const MEDIA_ACTION_RESPONSE_SCRIPT: string = `(function(){
  if(window!==window.top||window.__otMediaResponseHook)return;
  window.__otMediaResponseHook=true;
  function owner(){return (/(?:^|;\\s*)twid=([^;]*)/.exec(document.cookie||'')||[])[1]||'';}
  window.__otMediaOwner=owner;
  function request(action,url,method,body){
    if(!action||window.__otMediaAction!==action||action.owner!==owner()||method!=='POST'||typeof body!=='string')return null;
    try{
      var route=new URL(url,location.href);
      if(route.protocol!=='https:'||!/^(?:www\\.)?(?:x|twitter)\\.com$/.test(route.hostname))return null;
      var operation=route.pathname.match(/^\\/i\\/api\\/graphql\\/[^/]+\\/([^/]+)$/);
      var expected=action.action==='like'?(action.target?'FavoriteTweet':'UnfavoriteTweet'):
        action.action==='bookmark'?(action.target?'CreateBookmark':'DeleteBookmark'):
        action.action==='repost'?(action.target?'CreateRetweet':'DeleteRetweet'):'';
      if(!operation||operation[1]!==expected)return null;
      var variables=JSON.parse(body).variables;
      if(!variables||String(variables.tweet_id||variables.source_tweet_id)!==action.postId)return null;
      action.operation=expected;action.sent=true;
      return action;
    }catch(error){console.warn('CruX event=image_action_request_unreadable');return null;}
  }
  function response(action,status,data){
    if(!action||window.__otMediaAction!==action||action.owner!==owner())return;
    if((status>=400&&status<500&&status!==408)||(data&&Array.isArray(data.errors)&&data.errors.length)){
      action.failed=true;return;
    }
    if(status<200||status>=300||!data||!data.data)return;
    var keys={FavoriteTweet:'favorite_tweet',UnfavoriteTweet:'unfavorite_tweet',CreateBookmark:'tweet_bookmark_put',
      DeleteBookmark:'tweet_bookmark_delete',CreateRetweet:'create_retweet',DeleteRetweet:'unretweet'};
    var receipt=data.data[keys[action.operation]];
    if(receipt==='Done'||(receipt&&typeof receipt==='object'&&Object.keys(receipt).length))action.ack=true;
  }
  var send=XMLHttpRequest.prototype.send;
  var open=XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open=function(method,url){
    var result=open.apply(this,arguments);
    this.__otMediaUrl=String(url);this.__otMediaMethod=String(method).toUpperCase();return result;
  };
  XMLHttpRequest.prototype.send=function(body){
    var action=request(window.__otMediaAction,this.__otMediaUrl||'',this.__otMediaMethod,body);
    if(action)this.addEventListener('loadend',function(){
      response(action,this.status,null);
      try{response(action,this.status,this.responseType==='json'?this.response:JSON.parse(this.responseText));}
      catch(error){console.warn('CruX event=image_action_response_unreadable');}
    },{once:true});
    return send.apply(this,arguments);
  };
  var fetch=window.fetch;
  if(typeof fetch==='function')window.fetch=function(input,options){
    var pending=window.__otMediaAction;
    var url=input&&input.url||String(input),method=String(options&&options.method||input&&input.method||'GET').toUpperCase();
    var body;
    if(pending){
      if(options&&typeof options.body==='string')body=Promise.resolve(options.body);
      else if(input&&typeof input.clone==='function'){
        try{body=input.clone().text();}catch(error){console.warn('CruX event=image_action_request_unreadable');}
      }
    }
    var task=fetch.apply(this,arguments);
    if(body)body.then(function(text){
      var action=request(pending,url,method,text);
      if(!action)return;
      task.then(function(res){
        response(action,res.status,null);
        try{res.clone().json().then(function(data){response(action,res.status,data);},
          function(){console.warn('CruX event=image_action_response_unreadable');});}
        catch(error){console.warn('CruX event=image_action_response_unreadable');}
      },function(){console.warn('CruX event=image_action_transport_unknown');});
    },function(){console.warn('CruX event=image_action_request_unreadable');});
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

/** 时间链接确认帖子归属，引用内容不能充当原帖操作区域。 */
const MEDIA_POST_NODE_SCRIPT: string = `function(id){
  function owns(node){
    return node&&node.isConnected&&Array.from(node.querySelectorAll('a[href] time')).some(function(time){
      var link=time.closest('a[href]');
      return time.closest('article[data-testid="tweet"]')===node&&link&&
        new RegExp('^/(?:[A-Za-z0-9_]{1,15}|i/web)/status/'+id+'$').test(new URL(link.href,location.href).pathname);
    });
  }
  var post=window.__otMediaPost;
  if(post&&post.id===id&&owns(post.node))return post.node;
  var nodes=document.querySelectorAll('article[data-testid="tweet"]');
  for(var i=0;i<nodes.length;i++)if(owns(nodes[i])){
    window.__otMediaPost={id:id,node:nodes[i]};return nodes[i];
  }
  return null;
}`;

/** 读取和动作共用严格的原帖定位；回读不触发点击。 */
export function mediaActionScript(postId: string, requestId: number, action: string, start: boolean,
  target?: boolean): string {
  return MEDIA_ACTION_RESPONSE_SCRIPT + `(function(){
    var result={requestId:${requestId},postId:${JSON.stringify(postId)},status:'unavailable'};
    var node=(${MEDIA_POST_NODE_SCRIPT})(result.postId),action=${JSON.stringify(action)};
    function state(){
      if(!node)return;
      var like=node.querySelector('[data-testid="like"],[data-testid="unlike"]');
      var bookmark=node.querySelector('[data-testid="bookmark"],[data-testid="removeBookmark"]');
      var repost=node.querySelector('[data-testid="retweet"],[data-testid="unretweet"]');
      if(like)result.liked=like.dataset.testid==='unlike';
      if(bookmark)result.bookmarked=bookmark.dataset.testid==='removeBookmark';
      if(repost)result.reposted=repost.dataset.testid==='unretweet';
    }
    state();
    if(action==='read'){result.status=node&&!window.__otMediaReadbackBlocked?'ready':'unavailable';return JSON.stringify(result);}
    var pending=window.__otMediaAction;
    if(!${start}&&pending&&pending.id===result.requestId&&pending.postId===result.postId&&pending.action===action&&
      pending.owner===window.__otMediaOwner()){
      if(pending.failed){result.status='failed';return JSON.stringify(result);}
      if(pending.ack){
        result[action==='like'?'liked':action==='bookmark'?'bookmarked':'reposted']=pending.target;
        result.target=pending.target;result.status='done';return JSON.stringify(result);
      }
    }
    if(!node)return JSON.stringify(result);
    if(${start}){
      var selector=action==='like'?'[data-testid="like"],[data-testid="unlike"]':action==='bookmark'?
        '[data-testid="bookmark"],[data-testid="removeBookmark"]':'[data-testid="retweet"],[data-testid="unretweet"]';
      var button=node.querySelector(selector);
      if(!button||button.disabled)return JSON.stringify(result);
      var initial=action==='like'?result.liked:action==='bookmark'?result.bookmarked:result.reposted;
      var target=${target === undefined ? 'undefined' : String(target)};
      if(action!=='quote'&&typeof initial!=='boolean')return JSON.stringify(result);
      if(typeof target!=='boolean')target=!initial;
      result.target=target;
      if(action!=='quote'&&initial===target){result.status='done';return JSON.stringify(result);}
      window.__otMediaAction={id:result.requestId,postId:result.postId,action:action,owner:window.__otMediaOwner(),
        target:target,confirmed:false,ack:false,failed:false,sent:false};
      button.click();result.status='pending';return JSON.stringify(result);
    }
    if(!pending||pending.id!==result.requestId||pending.action!==action||pending.owner!==window.__otMediaOwner())return JSON.stringify(result);
    result.target=pending.target;
    if(action==='quote'){
      var link=document.querySelector('[role="menu"] a[href*="/compose/"],[data-testid="Dropdown"] a[href*="/compose/"]');
      if(link){result.status='quote';result.quoteUrl=link.href;}else result.status='pending';
      return JSON.stringify(result);
    }
    if(action==='repost'&&!pending.confirmed){
      var confirm=document.querySelector('[data-testid="retweetConfirm"],[data-testid="unretweetConfirm"]');
      if(confirm){pending.confirmed=true;confirm.click();}
    }
    result.status='pending';
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

/** 路由和内容就绪后恢复位置，虚拟列表未展开时由宿主继续等待。 */
export function restoreMediaOriginScript(origin: MediaOrigin): string {
  return `(function(origin){
    if(String(location.href)!==origin.url)return 'pending';
    window.scrollTo(origin.x,origin.y);
    var node=origin.scrollSelector?document.querySelector(origin.scrollSelector):null;
    if(origin.scrollSelector&&!node)return 'pending';
    if(node){node.scrollTop=origin.scrollTop;node.scrollLeft=origin.scrollLeft;}
    return Math.abs(window.scrollY-origin.y)<=1&&(!node||Math.abs(node.scrollTop-origin.scrollTop)<=1)?'restored':'pending';
  })(` + JSON.stringify(origin) + ')';
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
    var link=target&&target.closest('a[href]');
    if(!link&&photo)link=photo.closest('a[href]');
    if(!link||!window.otNative||!window.otNative.onImages)return;
    var route=new URL(link.href,location.href);
    var match=route.pathname.match(/^\\/(?:[A-Za-z0-9_]{1,15}|i\\/web)\\/status\\/(\\d+)\\/photo\\/([1-4])$/);
    if(!match)return;
    var node=link.closest('article[data-testid="tweet"]');
    var scope=node||link.closest('main')||link;
    var links=Array.from(scope.querySelectorAll('a[href]'));
    if(scope===link)links=[link];
    var photos=[];
    links.forEach(function(a){
      var p=new URL(a.href,location.href).pathname;
      var slot=new RegExp('^/(?:[A-Za-z0-9_]{1,15}|i/web)/status/'+match[1]+'/photo/([1-4])$').exec(p);
      if(!slot)return;
      if(node&&a.closest('article[data-testid="tweet"]')!==node)return;
      var img=a.querySelector('[data-testid="tweetPhoto"] img')||a.querySelector('img');
      var src=img&&(img.currentSrc||img.src);
      if(src&&/^https:\\/\\/pbs\\.twimg\\.com\\/media\\//.test(src)&&
        !photos.some(function(item){return item.slot===Number(slot[1])||item.src===src;}))photos.push({slot:Number(slot[1]),src:src});
    });
    photos.sort(function(a,b){return a.slot-b.slot;});
    var urls=photos.map(function(item){return item.src;});
    var image=link.querySelector('img');
    var index=image?urls.indexOf(image.currentSrc||image.src):-1;
    if(index<0||urls.length>4)return;
    var payload={urls:urls,index:index,postId:match[1],
      postUrl:route.origin+route.pathname.replace(/\\/photo\\/\\d+$/,'')};
    if(node){
      var like=node.querySelector('[data-testid="like"],[data-testid="unlike"]');
      var bookmark=node.querySelector('[data-testid="bookmark"],[data-testid="removeBookmark"]');
      var repost=node.querySelector('[data-testid="retweet"],[data-testid="unretweet"]');
      if(like)payload.liked=like.dataset.testid==='unlike';
      if(bookmark)payload.bookmarked=bookmark.dataset.testid==='removeBookmark';
      if(repost)payload.reposted=repost.dataset.testid==='unretweet';
      window.__otMediaPost={id:match[1],node:node};
    }
    if(String(location.href)!==payload.postUrl){
      var origin={url:String(location.href),x:window.scrollX,y:window.scrollY,scrollSelector:'',scrollTop:0,scrollLeft:0};
      for(var parent=link.parentElement;parent&&parent!==document.scrollingElement;parent=parent.parentElement){
        var style=getComputedStyle(parent);
        if(!/(auto|scroll)/.test(style.overflowY)||parent.scrollHeight<=parent.clientHeight)continue;
        var path=[],part=parent;
        while(part){
          var segment=part.tagName.toLowerCase();
          if(part.parentElement)segment+=':nth-child('+(Array.prototype.indexOf.call(part.parentElement.children,part)+1)+')';
          path.unshift(segment);part=part.parentElement;
        }
        origin.scrollSelector=path.join('>');origin.scrollTop=parent.scrollTop;origin.scrollLeft=parent.scrollLeft;break;
      }
      payload.origin=origin;
    }
    if(window.otNative.onImages(JSON.stringify(payload))===true){
      e.preventDefault();e.stopImmediatePropagation();
    }
  },true);
})();`;
