import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';

const source = name => stripTypeScriptTypes(readFileSync(new URL('../entry/src/main/ets/common/' + name + '.ets', import.meta.url), 'utf8')
  .replace(/^import .*;\r?\n/gm, '')).replace(/^export /gm, '');
const media = vm.runInNewContext(source('WebMedia') + ';({resolveMedia,MEDIA_CLICK_SCRIPT,MEDIA_ACTION_RESPONSE_SCRIPT,imageForQuality,mediaActionScript,restoreMediaOriginScript})');
for (const url of ['https://pbs.twimg.com/profile_images/a.jpg', 'https://pbs.twimg.com.evil/media/a',
  'http://pbs.twimg.com/media/a', 'https://pbs.twimg.com/tweet_video_thumb/a.jpg']) {
  assert.equal(media.resolveMedia(url), undefined);
}
assert.equal(media.resolveMedia('https://pbs.twimg.com/media/a.png:large').candidates[0], 'https://pbs.twimg.com/media/a?format=png&name=orig');
assert.equal(media.resolveMedia('https://pbs.twimg.com/media/a?format=webp&name=small').candidates[0], 'https://pbs.twimg.com/media/a?format=webp&name=orig');
assert.equal(media.resolveMedia('https://pbs.twimg.com/profile_images/123/avatar_normal.jpg').candidates[0],
  'https://pbs.twimg.com/profile_images/123/avatar.jpg');
assert.equal(media.resolveMedia('https://pbs.twimg.com/card_img/123/card?format=jpg&name=small').candidates.length,1);
assert.equal(media.resolveMedia('https://pbs.twimg.com/profile_images/123/avatar.gif').candidates[0],
  'https://pbs.twimg.com/profile_images/123/avatar.gif');

let handler, accepted = true, calls = 0, payload;
class Element {}
const urls = ['https://pbs.twimg.com/media/first?format=jpg&name=small','https://pbs.twimg.com/media/second?format=jpg&name=small'];
const images = urls.map(src => ({src, currentSrc:src}));
const links = images.map((image,i) => ({href:'https://x.com/alice/status/123/photo/'+(i+1),querySelector:()=>image,closest:()=>scope}));
const quote = {href:'https://x.com/bob/status/456/photo/1',querySelector:()=>({src:'https://pbs.twimg.com/media/quote?format=jpg'}),closest:()=>scope};
const scope = {isConnected:true,closest(){return this;},querySelector:()=>null,querySelectorAll:()=>[...links,quote,links[0]]};
const photo = {closest:s=>s==='a[href]'?links[1]:scope,querySelector:()=>images[1]};
const target = new Element(); target.closest=s=>s==='a[href]'?links[1]:photo;
const context = {Element,URL,location:{href:'https://x.com/alice/status/123'},window:{otNative:{onImages:p=>{calls++;payload=JSON.parse(p);return accepted;}}},document:{addEventListener:(_event,h)=>handler=h}};
vm.runInNewContext(media.MEDIA_CLICK_SCRIPT,context);
let prevented=0;
const event={button:0,target,preventDefault(){prevented++},stopImmediatePropagation(){}};
handler(event);
assert.deepEqual(payload,{urls,index:1,postId:'123',postUrl:'https://x.com/alice/status/123'}); assert.equal(prevented,1);
accepted=false; handler(event); assert.equal(prevented,1);
handler({...event,ctrlKey:true}); assert.equal(calls,2);
delete context.window.otNative; handler(event); assert.equal(prevented,1);
context.window.otNative = {onImages:p=>{payload=JSON.parse(p);return true;}};
const avatar = 'https://pbs.twimg.com/profile_images/123/avatar_normal.jpg';
target.closest = () => ({href:'https://x.com/alice/photo',querySelector:()=>({src:avatar})});
handler(event); assert.deepEqual(payload, {urls:[avatar],index:0}); assert.equal(prevented,2);

// 媒体网格没有 tweetPhoto 标记；只收集同帖照片并按照片序号排列。
const grid={querySelectorAll:()=>gridLinks};
const gridLinks=[4,1,2].map(slot=>({href:'https://x.com/alice/status/789/photo/'+slot,
  querySelector:()=>({currentSrc:'https://pbs.twimg.com/media/grid'+slot+'?format=jpg'}),
  closest:selector=>selector==='main'?grid:null}));
gridLinks.push({href:'https://x.com/bob/status/999/photo/1',querySelector:()=>images[0]});
target.closest=selector=>selector==='a[href]'?gridLinks[0]:null;
context.location={pathname:'/alice/media',href:'https://x.com/alice/media'};
Object.assign(context.window,{scrollX:0,scrollY:530});
handler(event);
assert.deepEqual(payload.urls,[1,2,4].map(slot=>'https://pbs.twimg.com/media/grid'+slot+'?format=jpg'));
assert.equal(payload.index,2);assert.equal(payload.postId,'789');
assert.equal(payload.postUrl,'https://x.com/alice/status/789');assert.equal(payload.origin.y,530);
assert.equal(payload.origin.url,context.location.href);
const gridScroll={scrollTop:0,scrollLeft:0};
const restoreContext={location:context.location,window:{scrollY:0,scrollTo(_x,y){this.scrollY=y;}},
  document:{querySelector:()=>gridScroll}};
assert.equal(vm.runInNewContext(media.restoreMediaOriginScript({...payload.origin,scrollSelector:'main',scrollTop:120}),restoreContext),'restored');
assert.equal(gridScroll.scrollTop,120);assert.equal(restoreContext.window.scrollY,530);
restoreContext.location={href:'https://x.com/home'};
assert.equal(vm.runInNewContext(media.restoreMediaOriginScript(payload.origin),restoreContext),'pending');

// 网页尺寸、自动原图候选和手动原图不能互相误用缓存。
const qualityAddress=media.resolveMedia(urls[0]);
const preview=media.imageForQuality(qualityAddress,false);
const automatic=media.imageForQuality(qualityAddress,true);
const explicit=media.imageForQuality(qualityAddress,true,true);
assert.deepEqual(Array.from(preview.candidates),[urls[0]]);
assert.notEqual(preview.id,automatic.id);assert.notEqual(automatic.id,explicit.id);
assert(explicit.candidates.every(url=>url.includes('name=orig')));
assert(automatic.candidates.some(url=>url.includes('name=large')));

// DOM 的乐观变色不足以完成互动；对应帖子请求成功后才返回完成。
let selected=false,networkSuccess=true,networkPending=false,postConnected=true,completeNetwork;
class Xhr {
  open(_method,url){this.url=url;}
  addEventListener(_event,callback){this.done=callback;}
  send(){
    completeNetwork=()=>{this.status=networkSuccess?200:403;this.responseText=JSON.stringify(networkSuccess?{data:{favorite_tweet:'Done'}}:{errors:[{}]});this.done.call(this);};
    if(!networkPending)completeNetwork();
  }
}
const postNode={get isConnected(){return postConnected;},querySelector(selector){
  if(!selector.includes('like'))return null;
  return {dataset:{testid:selected?'unlike':'like'},click(){selected=!selected;const xhr=new actionContext.XMLHttpRequest();
    xhr.open('POST','https://x.com/i/api/graphql/id/'+(selected?'FavoriteTweet':'UnfavoriteTweet'));
    xhr.send(JSON.stringify({variables:{tweet_id:'123'}}));}};
},querySelectorAll(){return [{closest:selector=>selector==='a[href]'?{href:'https://x.com/alice/status/123'}:postNode}];}};
const actionContext={XMLHttpRequest:Xhr,URL,location:{href:'https://x.com/home'},
  window:{__otMediaPost:{id:'123',node:postNode},fetch:async()=>{}},document:{cookie:'twid=u%3D1',querySelector:()=>null,querySelectorAll:()=>[]}};
actionContext.window.top=actionContext.window;
const action=(id,start)=>JSON.parse(vm.runInNewContext(media.mediaActionScript('123',id,'like',start),actionContext));
networkPending=true;assert.equal(action(1,true).status,'pending');
assert.equal(action(1,false).status,'pending','乐观选中不能提前返回成功');
completeNetwork();assert.equal(action(1,false).status,'done');assert.equal(action(1,false).liked,true);
selected=false;assert.equal(action(1,false).liked,true,'成功回执不依赖旧 DOM 乐观状态');
postConnected=false;assert.equal(action(1,false).status,'done','节点被替换仍保留已确认回执');
postConnected=true;selected=true;
networkPending=false;networkSuccess=false;action(2,true);assert.equal(action(2,false).status,'failed');
postConnected=false;assert.equal(action(3,true).status,'unavailable');
postConnected=true;assert.equal(JSON.parse(vm.runInNewContext(media.mediaActionScript('999',4,'like',true),actionContext)).status,'unavailable');

// 缓存节点失效时只接受原帖自己的时间链接，不接受引用帖里的同号链接。
const replacementNode={...postNode,isConnected:true};
replacementNode.querySelectorAll=()=>[{closest:selector=>selector==='a[href]'?{href:'https://x.com/alice/status/123'}:replacementNode}];
postConnected=false;actionContext.document.querySelectorAll=()=>[replacementNode];
assert.equal(JSON.parse(vm.runInNewContext(media.mediaActionScript('123',0,'read',false),actionContext)).status,'ready');
replacementNode.querySelectorAll=()=>[{closest:selector=>selector==='a[href]'?{href:'https://x.com/alice/status/123'}:postNode}];
assert.equal(JSON.parse(vm.runInNewContext(media.mediaActionScript('123',0,'read',false),actionContext)).status,'unavailable');

// 文档开始安装后捕获网页保存的 fetch；观察者不得改变原请求返回的 Promise。
const settle=()=>new Promise(resolve=>setImmediate(resolve));
for(const [inputKind,actionName,operation,testId,receipt] of [
  ['string','like','FavoriteTweet','like',{favorite_tweet:'Done'}],
  ['url','like','FavoriteTweet','like',{favorite_tweet:'Done'}],
  ['request','like','FavoriteTweet','like',{favorite_tweet:'Done'}],
  ['string','like','UnfavoriteTweet','unlike',{unfavorite_tweet:'Done'}],
  ['request','bookmark','CreateBookmark','bookmark',{tweet_bookmark_put:'Done'}],
  ['url','bookmark','DeleteBookmark','removeBookmark',{tweet_bookmark_delete:'Done'}],
  ['string','repost','CreateRetweet','retweet',{create_retweet:{retweet_results:{result:{rest_id:'99'}}}}],
  ['request','repost','DeleteRetweet','unretweet',{unretweet:{source_tweet_results:{result:{rest_id:'123'}}}}]
]){
  let finish,originalTask,observedTask;
  let confirmation=false,confirmClicks=0;
  const fixture={URL,Promise,console,location:{href:'https://x.com/home'},XMLHttpRequest:class {open(){}send(){}},
    document:{cookie:'twid=u%3D1',querySelectorAll:()=>[],querySelector:()=>null},window:{}};
  fixture.window.top=fixture.window;
  fixture.window.fetch=()=>{originalTask=new Promise(resolve=>{finish=resolve;});return originalTask;};
  vm.runInNewContext(media.MEDIA_ACTION_RESPONSE_SCRIPT,fixture);
  const cachedFetch=fixture.window.fetch;
  vm.runInNewContext(media.MEDIA_ACTION_RESPONSE_SCRIPT,fixture);
  assert.equal(fixture.window.fetch,cachedFetch,'重复安装不重复包裹 fetch');
  const endpoint='https://x.com/i/api/graphql/test/'+operation,body=JSON.stringify({variables:{tweet_id:'123'}});
  const input=inputKind==='request'?{url:endpoint,method:'POST',clone:()=>({text:async()=>body})}:
    inputKind==='url'?new URL(endpoint):endpoint;
  const send=()=>{observedTask=cachedFetch(input,inputKind==='request'?undefined:{method:'POST',body});};
  const node={isConnected:true,querySelectorAll:()=>[{closest:selector=>selector==='a[href]'?
    {href:'https://x.com/alice/status/123'}:node}],querySelector:selector=>selector.includes('"'+
      (actionName==='like'?'like':actionName==='bookmark'?'bookmark':'retweet')+'"')?{dataset:{testid:testId},
    click(){if(actionName==='repost')confirmation=true;else send();}}:null};
  fixture.document.querySelector=selector=>confirmation&&selector.includes('retweetConfirm')?
    {click(){confirmation=false;confirmClicks++;send();}}:null;
  fixture.window.__otMediaPost={id:'123',node};
  const target=!['unlike','removeBookmark','unretweet'].includes(testId);
  const run=(start)=>JSON.parse(vm.runInNewContext(media.mediaActionScript('123',10,actionName,start,target),fixture));
  assert.equal(run(true).status,'pending');
  if(actionName==='repost'){assert.equal(run(false).status,'pending');assert.equal(confirmClicks,1);}
  assert.equal(observedTask,originalTask);
  await settle();
  finish({status:200,clone:()=>({json:async()=>({data:receipt,errors:[]})})});await settle();
  assert.equal(run(false).status,'done',inputKind);
  assert.equal(run(false)[actionName==='like'?'liked':actionName==='bookmark'?'bookmarked':'reposted'],target);
  fixture.document.cookie='twid=u%3D2';
  assert.equal(run(false).status,'unavailable','换账号不能消费旧回执');
}

// 执行原生宿主的生产方法；仅替换网页通信、窗口控制和计时。
const mainSource=readFileSync(new URL('../entry/src/main/ets/pages/MainTabs.ets',import.meta.url),'utf8');
const mainMethod=name=>{
  const found=mainSource.match(new RegExp('^  (?:private )?(?:static )?(?:async )?'+name+'\\([\\s\\S]*?^  \\}', 'm'));
  assert.ok(found,'Missing viewer host method: '+name);return found[0];
};
let clock=0;
const MainTabs=vm.runInNewContext(stripTypeScriptTypes('class MainTabs{'+[
  'unquote','imageSessionCurrent','applyImagePostState','prepareImagePost','restoreImageOrigin','viewImagePost',
  'readBackImageAction','imagePostAction','performImagePostAction','imageViewerChanged','dismissImageDetails'
].map(mainMethod).join('\n')+'};MainTabs'),{
  unquoteScriptResult:value=>value,PROFILE_TIMEOUT_MS:10000,Date:{now:()=>clock},
  setTimeout:(callback,ms)=>{clock+=ms;queueMicrotask(callback);},
  mediaActionScript:(postId,id,action,start,target)=>JSON.stringify({postId,id,action,start,target}),
  restoreMediaOriginScript:origin=>JSON.stringify({restore:origin}),
  isSiteUrl:url=>url.startsWith('https://x.com/'),pathOf:url=>new URL(url).pathname,
  hilog:{info(){},warn(){},error(){}},DOMAIN:0,TAG:'test',$r:value=>value
});
const makeViewerPage=()=>{
  const page=new MainTabs(),postUrl='https://x.com/alice/status/123';
  Object.assign(page,{imageSession:1,imageActionSequence:0,imageViewerOpen:true,imageOwner:'alice',
    imageWebSession:1,webSession:1,pageAlive:true,appBackground:false,rawWeb:false,authenticationPage:false,
    webControllerReady:true,account:{ownHandle:'alice'},imagePost:{postId:'123',postUrl,liked:false,bookmarked:true,reposted:false},
    imagePostReady:true,imageBusy:false,imageUncertainActions:[],imageDetailsVisible:false,imageIndex:2,imageItems:urls,
    imageNavigation:-1,documentLoading:false,actionCalls:[],loads:[],toasts:[],quotes:[],refreshes:0,backs:0,
    navigation:{navigationGeneration:0,currentUrl:postUrl},webUrl:()=>page.navigation.currentUrl,
    webCanGoBack:()=>true,toast:message=>page.toasts.push(message),flushRenderRecovery(){},finishFirstLoad(){},
    documentStarted(){page.documentLoading=true;},
    composer:{openQuote:(...args)=>page.quotes.push(args)},
    serverLiked:true,serverReady:true,startedStatus:'pending'});
  page.navigation.loadDocument=async url=>{
    page.loads.push(url);page.navigation.navigationGeneration++;page.navigation.currentUrl=url;page.documentLoading=false;
  };
  page.controller={
    refresh(){page.refreshes++;page.documentLoading=false;},stop(){},
    backward(){page.backs++;page.navigation.currentUrl=page.returnOrigin.url;}
  };
  page.webScript=async script=>{
    if(!script.startsWith('{'))return '';
    const input=JSON.parse(script);
    if(input.restore)return 'restored';
    page.actionCalls.push(input);
    if(input.action==='read')return JSON.stringify({requestId:input.id,postId:input.postId,
      status:page.serverReady?'ready':'unavailable',liked:page.serverLiked,bookmarked:true,reposted:false});
    if(page.startedStatus==='pending')clock+=10001;
    return JSON.stringify({requestId:input.id,postId:input.postId,status:page.startedStatus,
      liked:true,bookmarked:true,reposted:false,quoteUrl:'https://x.com/compose/post?quote=123'});
  };
  return page;
};
let viewerPage=makeViewerPage();
await viewerPage.performImagePostAction('like');
assert.equal(viewerPage.imagePost.liked,true);assert.equal(viewerPage.toasts.length,0);
assert.equal(viewerPage.refreshes,1);assert.equal(viewerPage.loads.length,0,'同一原帖回读必须刷新，不新增历史项');
assert.equal(viewerPage.actionCalls.filter(call=>call.start).length,1,'回执未知不重复提交');

viewerPage=makeViewerPage();viewerPage.serverLiked=false;
await viewerPage.performImagePostAction('like');
assert.equal(viewerPage.imagePost.liked,false);
assert.deepEqual(Array.from(viewerPage.imageUncertainActions),['like']);
assert.deepEqual(viewerPage.toasts,['app.string.media_action_unknown']);
await viewerPage.performImagePostAction('like');
assert.equal(viewerPage.actionCalls.filter(call=>call.start).length,1,'未知结果不能再次切换');
viewerPage.imageUncertainActions.push('bookmark');
await viewerPage.performImagePostAction('like');await viewerPage.performImagePostAction('bookmark');
assert.equal(viewerPage.actionCalls.filter(call=>call.start).length,1,'多个未知动作不能互相解除限制');

viewerPage=makeViewerPage();viewerPage.startedStatus='failed';
await viewerPage.performImagePostAction('like');
assert.deepEqual(viewerPage.toasts,['app.string.operation_failed']);assert.equal(viewerPage.refreshes,0);
assert.equal(viewerPage.imagePost.liked,false);

viewerPage=makeViewerPage();viewerPage.startedStatus='done';
viewerPage.webScript=async script=>{
  const input=JSON.parse(script);
  return JSON.stringify({requestId:input.id,postId:input.postId,status:'done',liked:true});
};
await viewerPage.performImagePostAction('like');
assert.equal(viewerPage.imagePost.bookmarked,true,'节点丢失时仅合并有回执的字段');

viewerPage=makeViewerPage();let finishOld;
viewerPage.webScript=()=>new Promise(resolve=>{finishOld=resolve;});
const oldAction=viewerPage.performImagePostAction('like');
viewerPage.imageSession++;viewerPage.imageBusy=true;
finishOld(JSON.stringify({requestId:1,postId:'123',status:'done',liked:true}));await oldAction;
assert.equal(viewerPage.imagePost.liked,false);assert.equal(viewerPage.imageBusy,true,'旧回调不能清除新会话忙碌状态');
assert.equal(viewerPage.toasts.length,0);
for(const invalidate of [page=>{page.account.ownHandle='bob';},page=>{page.navigation.navigationGeneration++;}]){
  viewerPage=makeViewerPage();let finish;
  viewerPage.webScript=()=>new Promise(resolve=>{finish=resolve;});
  const pending=viewerPage.performImagePostAction('like');invalidate(viewerPage);
  finish(JSON.stringify({requestId:1,postId:'123',status:'done',liked:true}));await pending;
  assert.equal(viewerPage.imagePost.liked,false);assert.equal(viewerPage.toasts.length,0);
}

viewerPage=makeViewerPage();viewerPage.startedStatus='quote';
await viewerPage.performImagePostAction('quote');
assert.equal(viewerPage.quotes.length,1);assert.equal(viewerPage.imagePost.bookmarked,true);
assert.equal(viewerPage.imagePost.liked,false,'引用不能覆盖互动状态');

const origin={url:'https://x.com/alice/media',x:0,y:530,scrollSelector:'',scrollTop:0,scrollLeft:0};
viewerPage=makeViewerPage();viewerPage.navigation.currentUrl=origin.url;viewerPage.imageOrigin=origin;
const originalScript=viewerPage.webScript;
viewerPage.webScript=async script=>{
  if(script.startsWith('{')&&JSON.parse(script).action==='read'&&viewerPage.navigation.currentUrl===origin.url)
    return JSON.stringify({requestId:0,postId:'123',status:'unavailable'});
  return originalScript(script);
};
await viewerPage.prepareImagePost(1);
assert.equal(viewerPage.imagePostReady,true);assert.deepEqual(viewerPage.loads,[viewerPage.imagePost.postUrl]);
assert.equal(viewerPage.imageIndex,2);assert.equal(viewerPage.imageItems,urls);
viewerPage.returnOrigin=origin;viewerPage.imageViewerOpen=false;viewerPage.imageViewerChanged();await settle();
assert.equal(viewerPage.backs,1);assert.equal(viewerPage.navigation.currentUrl,origin.url);

viewerPage=makeViewerPage();viewerPage.navigation.currentUrl=origin.url;viewerPage.returnOrigin=origin;
viewerPage.imageOrigin=origin;viewerPage.imageNavigation=0;viewerPage.documentLoading=true;
viewerPage.imageViewerOpen=false;viewerPage.imageViewerChanged();await settle();
assert.equal(viewerPage.backs,0,'原帖尚未提交时不能误退到更早的页面');
assert.equal(viewerPage.documentLoading,false);

viewerPage=makeViewerPage();viewerPage.imageOrigin=origin;viewerPage.imageNavigation=0;
await viewerPage.viewImagePost();viewerPage.imageViewerChanged();await settle();
assert.equal(viewerPage.imageViewerOpen,false);assert.equal(viewerPage.backs,0,'查看原帖保留当前帖子');
assert.equal(viewerPage.imageOrigin,undefined);

assert.match(mainSource,/javaScriptOnDocumentStart\(\[\{ script:[^\n]*MEDIA_ACTION_RESPONSE_SCRIPT/);
const png = Uint8Array.from([137,80,78,71,13,10,26,10,1,2,3,4]).buffer;
let responses=[],requests=0,writes=[],removed=[],failWrite=false;
let dohPolicy={mode:'off',url:undefined};
let syncImageDownloader=true;
let requestOptions=[];
const runtime={ArrayBuffer,Uint8Array,Map,Promise,Date,canIUse:()=>true,
  NetworkConfig:{getInstance:()=>({getDohPolicy:()=>dohPolicy,snapshot:()=>({syncImageDownloader})})},
  http:{RequestMethod:{GET:0},HttpDataType:{ARRAY_BUFFER:0},createHttp:()=>({
    request:async(_url,options)=>{requests++; requestOptions.push(options); const response=responses.shift(); if(response instanceof Error)throw response; return response;},destroy(){}})},
  fileIo:{OpenMode:{CREATE:1,READ_WRITE:2,TRUNC:4},listFile:async()=>[],open:async()=>({fd:1}),
    write:async(_fd,b)=>{if(failWrite)throw Error('Disk full'); const n=Math.min(5,b.byteLength);writes.push(...new Uint8Array(b).slice(0,n));return n;},
    close:async()=>{},unlink:async p=>removed.push(p)},
  image:{createImageSource:()=>({getImageInfo:async()=>({size:{width:20,height:10}}),release:async()=>{}})},
  hilog:{info(){},warn(){}}};
const {MediaFiles,imageExtension}=vm.runInNewContext(source('MediaFiles')+';({MediaFiles,imageExtension})',runtime);
assert.equal(imageExtension(png),'png'); assert.throws(()=>imageExtension(new ArrayBuffer(12)));
assert.equal(imageExtension(Uint8Array.from([71,73,70,56,57,97]).buffer),'gif');
responses=[{responseCode:404},{responseCode:200,result:png}];
let session=new MediaFiles();
const address=media.resolveMedia(urls[0]);
let file=await session.load(address,{cacheDir:'/cache'});
assert.equal(file.extension,'png'); assert.equal(file.originalSize,true); assert.equal(requests,2);
assert.deepEqual(writes,Array.from(new Uint8Array(png)));
assert.equal(await session.load(address,{cacheDir:'/cache'}),file); assert.equal(requests,2);
await session.close(); assert.equal(removed.length,1);
for(const response of [{responseCode:403},{responseCode:429},Error('Network failed')]){
  responses=[response];requests=0;session=new MediaFiles();
  await assert.rejects(session.load(address,{cacheDir:'/cache'})); assert.equal(requests,1); await session.close();
}
responses=[{responseCode:200,result:png}];requests=0;failWrite=true;session=new MediaFiles();
await assert.rejects(session.load(address,{cacheDir:'/cache'}));assert.equal(requests,1);await session.close();failWrite=false;
responses=[...address.candidates.slice(0,-1).map(()=>({responseCode:404})),{responseCode:200,result:png}];
session=new MediaFiles();file=await session.load(address,{cacheDir:'/cache'});
assert.equal(file.originalSize,false);await session.close();
removed=[];
runtime.fileIo.listFile=async()=>['x-image-1-old.jpg','x-image-2-recent.png','unrelated.jpg'];
runtime.fileIo.stat=async p=>({mtime:p.includes('-old.')?0:Date.now()/1000,size:1024});
MediaFiles.cacheCleanup=undefined;
responses=[{responseCode:200,result:png}];session=new MediaFiles();
await session.load(address,{cacheDir:'/cache'});
assert.deepEqual(removed,['/cache/x-image-1-old.jpg']);await session.close();
removed=[];
runtime.fileIo.listFile=async()=>['x-web-image-1-2-3.tmp','x-web-image-1-2-4.tmp','x-web-image-unrelated.tmp'];
runtime.fileIo.stat=async p=>({mtime:p.endsWith('-3.tmp')?0:Date.now()/1000,size:1024});
MediaFiles.cacheCleanup=undefined;
responses=[{responseCode:200,result:png}];session=new MediaFiles();
await session.load(address,{cacheDir:'/cache'});
assert.deepEqual(removed,['/cache/x-web-image-1-2-3.tmp']);await session.close();
// 模拟新进程的残留文件；容量清理只删模块文件，按最老文件优先。
removed=[];MediaFiles.cacheCleanup=undefined;
runtime.fileIo.listFile=async()=>['x-image-1-a.jpg','x-image-2-b.png','x-image-3-c.gif','unrelated.bin'];
runtime.fileIo.stat=async p=>({mtime:Date.now()/1000-(p.includes('-a.')?3:p.includes('-b.')?2:1),size:60*1024*1024});
responses=[{responseCode:200,result:png}];session=new MediaFiles();await session.load(address,{cacheDir:'/cache'});
assert.deepEqual(removed,['/cache/x-image-1-a.jpg']);await session.close();
runtime.fileIo.listFile=async()=>[];

// DoH policy: OFF sends no dnsOverHttps, AUTO retries once without it,
// SECURE_ONLY must not fall back to system DNS.
dohPolicy={mode:'off',url:undefined};
responses=[{responseCode:200,result:png}];requests=0;requestOptions=[];
session=new MediaFiles();await session.load(address,{cacheDir:'/cache'});
assert.equal(requests,1);assert.equal(requestOptions[0].dnsOverHttps,undefined);await session.close();
dohPolicy={mode:'auto',url:'https://dns.example/dns-query'};
responses=[Error('DoH failed'),{responseCode:200,result:png}];requests=0;requestOptions=[];
session=new MediaFiles();file=await session.load(address,{cacheDir:'/cache'});
assert.equal(requests,2);
assert.equal(requestOptions[0].dnsOverHttps,'https://dns.example/dns-query');
assert.equal(requestOptions[1].dnsOverHttps,undefined);
await session.close();
dohPolicy={mode:'secure_only',url:'https://dns.example/dns-query'};
responses=[Error('DoH failed')];requests=0;requestOptions=[];
session=new MediaFiles();
await assert.rejects(session.load(address,{cacheDir:'/cache'}));
assert.equal(requests,1);
assert.equal(requestOptions[0].dnsOverHttps,'https://dns.example/dns-query');
await session.close();
console.log('Media grid, receipt confirmation, unknown results, viewer return, cancellation, byte preservation and download checks passed.');
