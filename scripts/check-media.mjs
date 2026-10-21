import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';

const source = name => stripTypeScriptTypes(readFileSync(new URL('../entry/src/main/ets/common/' + name + '.ets', import.meta.url), 'utf8')
  .replace(/^import .*;\r?\n/gm, '')).replace(/^export /gm, '');
const media = vm.runInNewContext(source('WebMedia') + ';({resolveMedia,MEDIA_CLICK_SCRIPT,imageForQuality,mediaActionScript})');
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
const links = images.map((image,i) => ({href:'https://x.com/alice/status/123/photo/'+(i+1),querySelector:()=>image}));
const quote = {href:'https://x.com/bob/status/456/photo/1',querySelector:()=>({src:'https://pbs.twimg.com/media/quote?format=jpg'})};
const scope = {isConnected:true,closest(){return this;},querySelector:()=>null,querySelectorAll:()=>[...links,quote,links[0]]};
const photo = {closest:s=>s==='a[href]'?links[1]:scope,querySelector:()=>images[1]};
const target = new Element(); target.closest=s=>s==='a[href]'?links[1]:photo;
const context = {Element,URL,location:{href:'https://x.com/home'},window:{otNative:{onImages:p=>{calls++;payload=JSON.parse(p);return accepted;}}},document:{addEventListener:(_event,h)=>handler=h}};
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
}};
const actionContext={XMLHttpRequest:Xhr,URL,location:{href:'https://x.com/home'},
  window:{__otMediaPost:{id:'123',node:postNode},fetch:async()=>{}},document:{querySelector:()=>null}};
const action=(id,start)=>JSON.parse(vm.runInNewContext(media.mediaActionScript('123',id,'like',start),actionContext));
networkPending=true;assert.equal(action(1,true).status,'pending');
assert.equal(action(1,false).status,'pending','乐观选中不能提前返回成功');
completeNetwork();assert.equal(action(1,false).status,'done');assert.equal(action(1,false).liked,true);
networkPending=false;networkSuccess=false;action(2,true);assert.equal(action(2,false).status,'failed');
postConnected=false;assert.equal(action(3,true).status,'unavailable');
postConnected=true;assert.equal(JSON.parse(vm.runInNewContext(media.mediaActionScript('999',4,'like',true),actionContext)).status,'unavailable');

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
console.log('Media address, click ownership, byte preservation, cache, DoH and error boundary checks passed.');
