/** 只观察网页已有请求，响应读取失败不能改变网页自身的请求结果。 */
export const WEB_RESPONSE_SCRIPT: string = `(function(){
  if(window!==window.top||window.__otResponseHook)return;
  window.__otResponseHook=true;
  window.__otBadgeEpoch=window.__otBadgeEpoch||0;
  var owner='',accountEpoch=0,sequence=0,accountSequence=0,badgeSequence=0,post=null,postToken=0;
  function warn(operation){console.warn('CruX event=web_response_invalid operation='+operation);}
  function cookieOwner(){
    var match=/(?:^|;\\s*)twid=([^;]*)/.exec(document.cookie||'');
    if(!match)return '';
    try{
      var id=/^(?:u=(\\d+)|"u=(\\d+)")$/.exec(decodeURIComponent(match[1]));
      return id?(id[1]||id[2]):'';
    }catch(error){warn('account_cookie');return '';}
  }
  function currentOwner(){
    var next=cookieOwner();
    if(next!==owner){
      owner=next;accountEpoch++;window.__otBadgeEpoch++;window.__otBadgeCounts=null;window.__otResponseAccount=null;
      if(post)window.__otPostState='unknown';
    }
    return owner;
  }
  window.__otReadAccount=function(){
    var id=currentOwner(),account=window.__otResponseAccount;
    return id&&account&&account.id===id?account.handle:'';
  };
  window.__otBeginPost=function(handle){
    if(!/^[A-Za-z0-9_]{1,15}$/.test(handle))return 0;
    var id=currentOwner();
    var account=window.__otResponseAccount;
    if(account&&account.id===id&&account.handle.toLowerCase()!==handle.toLowerCase())return 0;
    if(window.__otPostState==='submitted'||window.__otPostState==='unknown')return 0;
    post={token:++postToken,owner:id,handle:handle.toLowerCase(),request:0};
    window.__otPostToken=post.token;window.__otPostState='submitted';return post.token;
  };
  window.__otReadPost=function(){currentOwner();return window.__otPostState||'unknown';};
  function operation(value,method){
    try{
      var url=new URL(value,location.href);
      if(url.protocol!=='https:'||!/^(?:www\\.)?(?:x|twitter)\\.com$/.test(url.hostname))return '';
      var match=/^\\/i\\/api\\/graphql\\/[^/]+\\/(ViewerBadgeCounts|HomeTimeline|HomeLatestTimeline|CreateTweet)$/.exec(url.pathname);
      if(!match||method!==(match[1]==='CreateTweet'?'POST':'GET'))return '';
      return match[1];
    }catch(error){warn('request_url');return '';}
  }
  function start(op){
    var id=currentOwner(),request=++sequence;
    var context={operation:op,owner:id,accountEpoch:accountEpoch,epoch:window.__otBadgeEpoch,sequence:request,post:null};
    if(op==='CreateTweet'&&post&&window.__otPostState==='submitted'&&!post.request){
      post.request=request;context.post=post;
    }
    return context;
  }
  function userHandle(user){
    var handle=user&&((user.core&&user.core.screen_name)||(user.legacy&&user.legacy.screen_name));
    return typeof handle==='string'&&/^[A-Za-z0-9_]{1,15}$/.test(handle)?handle:'';
  }
  function readAccount(data,id,request){
    if(!id||request<accountSequence)return;
    var pending=[data],found='';
    while(pending.length){
      var value=pending.pop();
      if(!value||typeof value!=='object')continue;
      if(value.__typename==='User'&&value.rest_id===id){
        var handle=userHandle(value);
        if(handle){
          if(found&&found.toLowerCase()!==handle.toLowerCase())throw new Error('Conflicting account');
          found=handle;
        }
      }
      Object.keys(value).forEach(function(key){if(value[key]&&typeof value[key]==='object')pending.push(value[key]);});
    }
    if(!found)return;
    accountSequence=request;
    var previous=window.__otResponseAccount;
    window.__otResponseAccount={id:id,handle:found};
    if((!previous||previous.handle!==found)&&window.otNative&&window.otNative.onUrlChange){
      window.otNative.onUrlChange('main',String(location.href));
    }
  }
  function apply(context,data){
    if(context.owner!==currentOwner()||context.accountEpoch!==accountEpoch)return;
    try{
      if(data.errors&&data.errors.length)throw new Error('GraphQL errors');
      if(context.operation==='CreateTweet'){
        if(!context.post||context.post!==post||context.sequence!==post.request)return;
        var tweet=data.data.create_tweet.tweet_results.result;
        if(tweet.__typename==='TweetWithVisibilityResults')tweet=tweet.tweet;
        var author=tweet.core.user_results.result;
        if(tweet.__typename!=='Tweet'||typeof tweet.rest_id!=='string'||!/^\\d+$/.test(tweet.rest_id)||
          author.__typename!=='User'||typeof author.rest_id!=='string'||!/^\\d+$/.test(author.rest_id)||
          userHandle(author).toLowerCase()!==post.handle||(post.owner&&author.rest_id!==post.owner)){
          throw new Error('Post receipt mismatch');
        }
        window.__otPostState='confirmed';return;
      }
      if(context.epoch!==window.__otBadgeEpoch)return;
      readAccount(data,context.owner,context.sequence);
      if(context.operation!=='ViewerBadgeCounts'||context.sequence<badgeSequence)return;
      var counts=data.data.viewer_v2.user_results.result.badge_counts;
      var n=counts.ntab_unread_count,m=counts.xchat_unread_count;
      if(!Number.isSafeInteger(n)||n<0||!Number.isSafeInteger(m)||m<0)throw new Error('Invalid badge counts');
      badgeSequence=context.sequence;
      window.__otBadgeCounts={notifications:n,messages:m,time:Date.now()};
    }catch(error){warn(context.operation);}
  }
  var requests=new WeakMap(),open=XMLHttpRequest.prototype.open,send=XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open=function(method,url){
    var result=open.apply(this,arguments);
    requests.set(this,{operation:operation(url,String(method).toUpperCase()),method:String(method).toUpperCase()});
    return result;
  };
  XMLHttpRequest.prototype.send=function(){
    var request=requests.get(this);
    if(request&&request.operation){
      var context=start(request.operation);
      this.addEventListener('loadend',function(){
        if(requests.get(this)!==request||this.status<200||this.status>=300||
          operation(this.responseURL,request.method)!==context.operation)return;
        try{
          if(this.responseType===''||this.responseType==='text')apply(context,JSON.parse(this.responseText));
          else if(this.responseType==='json')apply(context,this.response);
        }catch(error){warn(context.operation);}
      },{once:true});
    }
    return send.apply(this,arguments);
  };
  var fetch=window.fetch;
  if(typeof fetch==='function')window.fetch=function(input,init){
    var method=String(init&&init.method||input&&input.method||'GET').toUpperCase();
    var op=operation(input&&input.url||input,method),context=op?start(op):null;
    return fetch.apply(this,arguments).then(function(response){
      if(context&&response.ok&&operation(response.url,method)===op){
        try{response.clone().json().then(function(data){apply(context,data);},function(){warn(op);});}
        catch(error){warn(op);}
      }
      return response;
    });
  };
})();`;
