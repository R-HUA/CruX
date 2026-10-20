import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';

const source = name => stripTypeScriptTypes(readFileSync(new URL('../entry/src/main/ets/common/' + name + '.ets', import.meta.url), 'utf8')
  .replace(/^import .*;\r?\n/gm, '')).replace(/^export /gm, '');
const production = ['WebMedia', 'WebImageDownloads', 'WebSystem', 'MediaFiles'].map(source).join('\n') +
  ';({WebImageDownloads,WebImageDownloadError,isWebImageUrl,installDownloads,MediaFiles,resolveMedia,removeExpiredDownloads})';
const png = Uint8Array.from([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 4]);
const url = 'https://pbs.twimg.com/media/example?format=jpg&name=orig';
const avatar = 'https://pbs.twimg.com/profile_images/123/avatar_normal.jpg';
const limit = 25 * 1024 * 1024;
const flush = async () => { for (let i = 0; i < 40; i++) { await Promise.resolve(); } };

function harness() {
  const storage = new Map(), handles = new Map(), timers = new Map(), logs = [];
  const dispatched = [], removed = [], reports = [], nativeOptions = [];
  let timerId = 0, fd = 0, inBefore = false, pickerCalls = 0, copied = 0, releases = 0, httpCalls = 0;
  let delegate, dispatchError, startError, readError, unlinkError, readGate, listError, nativeResponses = [];
  const controller = {
    setDownloadDelegate(value) { assert.equal(delegate, undefined); delegate = value; },
    startDownload(value) { dispatched.push(value); if (dispatchError) { throw dispatchError; } }
  };
  class Delegate {
    onBeforeDownload(callback) { this.before = callback; }
    onDownloadUpdated(callback) { this.updated = callback; }
    onDownloadFailed(callback) { this.failed = callback; }
    onDownloadFinish(callback) { this.finish = callback; }
  }
  const state = { sync: true, policy: { mode: 'secure_only', url: 'https://dns.example/dns-query' } };
  const runtime = { ArrayBuffer, Uint8Array, Map, Set, Promise, Date, Math, Number,
    setTimeout(callback, ms) { assert.equal(ms, 40000); timers.set(++timerId, callback); return timerId; },
    clearTimeout(id) { timers.delete(id); },
    webview: { WebDownloadDelegate: Delegate, WebDownloadErrorCode: { SERVER_BAD_CONTENT: 33 } },
    hilog: Object.fromEntries(['info', 'warn', 'error'].map(level => [level, (...args) => logs.push(args)])),
    NetworkConfig: { getInstance: () => ({ snapshot: () => ({ syncImageDownloader: state.sync }), getDohPolicy: () => state.policy }) },
    http: { RequestMethod: { GET: 0 }, HttpDataType: { ARRAY_BUFFER: 0 }, createHttp: () => ({
      request: async (_url, options) => { httpCalls++; nativeOptions.push(options); const response = nativeResponses.shift(); if (response instanceof Error) { throw response; } return response; }, destroy() {}
    }) },
    fileIo: { OpenMode: { READ_ONLY: 0, CREATE: 1, READ_WRITE: 2, TRUNC: 4 },
      listFile: async () => {
        if (listError) { throw listError; }
        return [...storage.keys()].filter(path => path.startsWith('/cache/')).map(path => path.slice(7));
      },
      stat: async path => { const entry = storage.get(path); if (!entry) { throw { code: 13900002 }; } return { size: entry.size ?? entry.bytes.length, mtime: Date.now() / 1000 }; },
      open: async (path, mode) => {
        if (mode & 1) { storage.set(path, { bytes: new Uint8Array() }); }
        if (!storage.has(path) && !path.startsWith('document:')) { throw { code: 13900002 }; }
        const file = { fd: ++fd }; handles.set(file.fd, { path, position: 0 }); return file;
      },
      read: async (file, bytes) => {
        if (readGate) { await readGate; }
        if (readError) { throw readError; }
        const handle = handles.get(file), data = storage.get(handle.path).bytes;
        const count = Math.min(5, bytes.byteLength, data.length - handle.position);
        new Uint8Array(bytes).set(data.subarray(handle.position, handle.position + count));
        handle.position += count; return count;
      },
      write: async (file, bytes) => {
        const handle = handles.get(file), old = storage.get(handle.path).bytes;
        const next = new Uint8Array(old.length + bytes.byteLength); next.set(old); next.set(new Uint8Array(bytes), old.length);
        storage.set(handle.path, { bytes: next }); return bytes.byteLength;
      },
      close: async file => { handles.delete(file.fd); },
      unlink: async path => { removed.push(path); if (unlinkError) { throw unlinkError; } if (!storage.delete(path)) { throw { code: 13900002 }; } },
      copyFile: async () => { copied++; }
    },
    image: { createImageSource: path => ({
      getImageInfo: async () => { assert.deepEqual(storage.get(path).bytes, png); return { size: { width: 20, height: 10 } }; },
      release: async () => { releases++; }
    }) },
    picker: { DocumentViewPicker: class { async save() { pickerCalls++; return ['document:saved']; } } }
  };
  const api = vm.runInNewContext(production, runtime);
  const images = new api.WebImageDownloads(controller, '/cache');
  api.installDownloads(controller, { cacheDir: '/cache' }, result => reports.push(result), images);
  let guid = 0;
  function item(value = url, options = {}) {
    return {
      guid: 'item-' + (++guid), original: value, url: value, total: png.length, received: 0, path: '', starts: 0, cancelled: 0, code: 20,
      ...options,
      getGuid() { return this.guid; }, getOriginalUrl() { return this.original; }, getUrl() { return this.url; },
      getTotalBytes() { return this.total; }, getReceivedBytes() { return this.received; },
      getFullPath() { return this.path; }, getLastErrorCode() { return this.code; }, getSuggestedFileName() { return 'picture.png'; },
      start(path) { assert.equal(inBefore, true, 'item.start must run inside onBeforeDownload'); this.starts++; if (startError) { throw startError; } this.path = path; storage.set(path, { bytes: png }); },
      cancel() { this.cancelled++; }
    };
  }
  return { ...api, images, controller, item, storage, handles, timers, dispatched, removed, reports, logs, nativeOptions, state,
    before(value) { inBefore = true; try { delegate.before(value); } finally { inBefore = false; } },
    beforeUsing(service, value) { inBefore = true; try { service.beforeDownload(value); } finally { inBefore = false; } },
    updated: value => delegate.updated(value), failed: value => delegate.failed(value), finish: value => delegate.finish(value),
    expire() { for (const callback of [...timers.values()]) { callback(); } },
    config(options) {
      if (Object.hasOwn(options, 'dispatchError')) { dispatchError = options.dispatchError; }
      if (Object.hasOwn(options, 'startError')) { startError = options.startError; }
      if (Object.hasOwn(options, 'readError')) { readError = options.readError; }
      if (Object.hasOwn(options, 'unlinkError')) { unlinkError = options.unlinkError; }
      if (Object.hasOwn(options, 'readGate')) { readGate = options.readGate; }
      if (Object.hasOwn(options, 'listError')) { listError = options.listError; }
      if (Object.hasOwn(options, 'nativeResponses')) { nativeResponses = options.nativeResponses; }
    },
    get pickerCalls() { return pickerCalls; }, get copied() { return copied; }, get releases() { return releases; }, get httpCalls() { return httpCalls; }
  };
}

const allowed = harness();
for (const value of [url, avatar, 'https://abs.twimg.com/sticky/default_profile_images/default_profile_normal.png']) {
  assert.equal(allowed.isWebImageUrl(value), true);
}
for (const value of ['https://example.com/photo.png', 'http://pbs.twimg.com/media/a', 'https://pbs.twimg.com.evil/media/a',
  'https://pbs.twimg.com@evil.com/media/a', 'https://pbs.twimg.com:443/media/a', 'https://pbs.twimg.com/media/../secret',
  'https://pbs.twimg.com/media/%2e%2e/secret', 'https://pbs.twimg.com/tweet_video_thumb/a.jpg', 'https://abs.twimg.com/media/a']) {
  assert.equal(allowed.isWebImageUrl(value), false);
  await assert.rejects(allowed.images.request(value).result, error => error.stage === 'url');
}
assert.equal(allowed.dispatched.length, 0); await allowed.images.close();

// Process leftovers are reclaimed, and a failed first cleanup can retry in the same media session.
{
  const h = harness();
  h.storage.set('/cache/web-download-123-1', { bytes: png }); h.storage.set('/cache/unrelated', { bytes: png });
  await h.removeExpiredDownloads('/cache');
  assert.equal(h.storage.has('/cache/web-download-123-1'), false); assert.equal(h.storage.has('/cache/unrelated'), true);
  const files = new h.MediaFiles(h.images), address = { id: 'cleanup', candidates: [url] };
  h.config({ listError: Error('temporary I/O failure') });
  await assert.rejects(files.load(address, { cacheDir: '/cache' }), /temporary I\/O/);
  h.config({ listError: undefined });
  const retry = files.load(address, { cacheDir: '/cache' }); await flush();
  const picture = h.item(); h.before(picture); await h.finish(picture); await retry;
  await files.close(); await h.images.close();
}

// Recovery does not depend on an old callback arriving; the old delegate still owns any later callback.
{
  const h = harness(), old = h.images.request(url);
  const rejected = assert.rejects(old.result, error => error.stage === 'timeout'); h.expire(); await rejected;
  assert.equal(h.images.needsRecovery(), true);
  const dispatched = [], replacement = new h.WebImageDownloads({ startDownload: value => dispatched.push(value) }, '/cache');
  const retry = replacement.request(url), picture = h.item();
  h.beforeUsing(replacement, picture); replacement.downloadFinish(picture); await retry.result;
  const late = h.item(); h.before(late); assert.equal(late.cancelled, 1); assert.equal(late.starts, 0);
  assert.deepEqual(dispatched, [url]); assert.equal(h.pickerCalls, 0);
  await replacement.close(); await h.images.close();
}

// Every intercepted image reaches the same downloader classification and local byte pipeline.
for (const value of [url, avatar, 'https://pbs.twimg.com/card_img/123/card?format=jpg&name=small',
  'https://pbs.twimg.com/amplify_video_thumb/123/img/cover.jpg', 'https://pbs.twimg.com/ext_tw_video_thumb/123/cover.jpg']) {
  const h = harness(), address = h.resolveMedia(value), files = new h.MediaFiles(h.images);
  for (const candidate of address.candidates) { assert.equal(h.isWebImageUrl(candidate), true); }
  const result = files.load(address, { cacheDir: '/cache' }); await flush();
  const picture = h.item(address.candidates[0]); h.before(picture); await h.finish(picture);
  const file = await result;
  assert.deepEqual(h.storage.get(file.path).bytes, png);
  if (value.includes('_thumb/') || value.includes('/card_img/')) { assert.equal(file.originalSize, false); }
  await files.close(); await h.images.close();
}

// A definite dispatch failure can retry without waiting for a callback that will never arrive.
{
  const h = harness(); h.config({ dispatchError: { code: 17100001 } });
  await assert.rejects(h.images.request(url).result, error => error.stage === 'dispatch');
  h.config({ dispatchError: undefined });
  const retry = h.images.request(url), picture = h.item(); h.before(picture); await h.finish(picture); await retry.result;
  assert.equal(h.images.needsRecovery(), false); await h.images.close();
}

// One delegate serves native images and normal downloads; bytes and file ownership stay real.
{
  const h = harness(), first = h.images.request(url), second = h.images.request(url), other = h.images.request(avatar);
  assert.deepEqual(h.dispatched, [url, avatar]);
  const picture = h.item(), face = h.item(avatar);
  h.before(picture); h.before(face); assert.notEqual(picture.path, face.path);
  await h.finish(face); await h.finish(picture);
  assert.deepEqual(new Uint8Array(await first.result), png);
  assert.deepEqual(new Uint8Array(await second.result), png);
  assert.deepEqual(new Uint8Array(await other.result), png);
  assert.equal(h.storage.size, 0); assert.equal(h.handles.size, 0); assert.equal(h.timers.size, 0);
  assert.equal(h.pickerCalls, 0); assert.deepEqual(h.reports, []);
  // Duplicate terminal callbacks are consumed, even after a new same-URL task is queued.
  const again = h.images.request(url); const rejected = assert.rejects(again.result, error => error.stage === 'closed');
  await h.finish(picture); h.failed(picture); await flush(); assert.equal(h.pickerCalls, 0);
  await h.images.close(); await rejected;
  const late = h.item(); h.before(late); assert.equal(late.cancelled, 1); assert.equal(late.starts, 0);
  await h.finish(late); await flush(); assert.equal(h.pickerCalls, 0);
}

// Cancelling one subscriber preserves a concurrent consumer; cancelling all stops the transport.
{
  const h = harness(), first = h.images.request(url), second = h.images.request(url), picture = h.item();
  h.before(picture);
  const rejected = assert.rejects(first.result, error => error.stage === 'cancel'); first.cancel(); await rejected;
  assert.equal(picture.cancelled, 0); await h.finish(picture); assert.deepEqual(new Uint8Array(await second.result), png);
  const third = h.images.request(avatar), face = h.item(avatar); h.before(face);
  const stopped = assert.rejects(third.result, error => error.stage === 'cancel'); third.cancel(); await stopped; await flush();
  assert.equal(face.cancelled, 1); assert.equal(h.storage.size, 0); assert.equal(h.timers.size, 0);
  await h.images.close();
}

// Cancellation before the GUID is known quarantines late callbacks, including redirects.
for (const action of ['cancel', 'timeout', 'close']) {
  const h = harness(), request = h.images.request(url);
  const rejected = assert.rejects(request.result, error => error.stage === (action === 'close' ? 'closed' : action));
  if (action === 'cancel') { request.cancel(); } else if (action === 'timeout') { h.expire(); } else { await h.images.close(); }
  await rejected;
  assert.equal(h.images.needsRecovery(), true);
  if (action !== 'close') { await assert.rejects(h.images.request(url).result, error => error.stage === 'pending_cancel'); }
  const late = h.item(url, { url: 'https://example.com/redirected' });
  h.before(late); assert.equal(late.starts, 0); assert.equal(late.cancelled, 1);
  await h.finish(late); h.failed(late); await flush(); assert.equal(h.pickerCalls, 0); assert.deepEqual(h.reports, []);
  if (action !== 'close') {
    const retry = h.images.request(url), current = h.item(); h.before(current); await h.finish(current); await retry.result;
  }
  await h.images.close();
}

// Bound tasks time out as well, release native items, and retain callback ownership.
{
  const h = harness(), request = h.images.request(url), picture = h.item(); h.before(picture);
  const rejected = assert.rejects(request.result, error => error.stage === 'timeout'); h.expire(); await rejected; await flush();
  assert.equal(picture.cancelled, 1); assert.equal(h.storage.size, 0); await h.finish(picture); await flush();
  assert.equal(h.pickerCalls, 0); await h.images.close();
}

// Close waits for an in-flight file read before returning; a cancelled reader cannot publish bytes.
{
  const h = harness(); let release;
  h.config({ readGate: new Promise(resolve => { release = resolve; }) });
  const request = h.images.request(url), picture = h.item(); h.before(picture); await h.finish(picture); await flush();
  assert.equal(h.handles.size, 1);
  const rejected = assert.rejects(request.result, error => error.stage === 'cancel'); request.cancel(); await rejected;
  let closed = false; const closing = h.images.close().then(() => { closed = true; });
  await flush(); assert.equal(closed, false); release(); await closing;
  assert.equal(h.handles.size, 0); assert.equal(h.storage.size, 0); assert.equal(h.pickerCalls, 0);
}

// Failure can precede onBeforeDownload; original URL wins over a redirected current URL.
{
  const h = harness(), request = h.images.request(url), missing = h.item(url, { code: 33, url: avatar });
  const rejected = assert.rejects(request.result, error => error.code === 33); h.failed(missing); await rejected;
  await h.finish(missing); await flush(); assert.equal(h.pickerCalls, 0);
  const current = h.images.request(url), unrelated = h.item('https://example.com/redirect', { url });
  h.before(unrelated); await h.finish(unrelated); assert.equal(h.pickerCalls, 1);
  const picture = h.item('', { url }); h.before(picture); await h.finish(picture); await current.result;
  await h.images.close();
}

for (const phase of ['before', 'updated', 'finish', 'stat']) {
  const h = harness(), request = h.images.request(url), picture = h.item();
  const rejected = assert.rejects(request.result, error => error.stage === 'size' && error.code === 6);
  if (phase === 'before') { picture.total = limit + 1; h.before(picture); }
  else {
    picture.total = -1; h.before(picture);
    if (phase === 'stat') { h.storage.get(picture.path).size = limit + 1; await h.finish(picture); }
    else { picture.received = limit + 1; if (phase === 'updated') { h.updated(picture); } else { await h.finish(picture); } }
  }
  await rejected; await flush(); assert.equal(h.storage.size, 0); assert.equal(h.pickerCalls, 0); await h.images.close();
}

for (const code of [20, 21, 30, 33, 34, 35, 36, 37, 38, 39, 40]) {
  const h = harness(), request = h.images.request(url), picture = h.item(url, { code }); h.before(picture);
  const rejected = assert.rejects(request.result, error => error.stage === 'download' && error.code === code && error.canTryNextCandidate() === (code === 33));
  h.failed(picture); await rejected; await flush(); assert.equal(h.storage.size, 0); assert.deepEqual(h.reports, []);
  assert.ok(h.logs.some(entry => entry.includes('download') && entry.includes(code)));
  assert.equal(JSON.stringify(h.logs).includes('https://'), false); await h.images.close();
}

// Dispatch, path assignment, redirects, read failures and cleanup errors remain distinguishable.
for (const stage of ['dispatch', 'start', 'redirect', 'path', 'read', 'cleanup']) {
  const h = harness();
  if (stage === 'dispatch') { h.config({ dispatchError: { code: 17100001 } }); }
  if (stage === 'start') { h.config({ startError: { code: 401 } }); }
  if (stage === 'read') { h.config({ readError: { code: 13900005 } }); }
  if (stage === 'cleanup') { h.config({ unlinkError: { code: 13900015 } }); }
  const request = h.images.request(url), picture = h.item();
  const rejected = assert.rejects(request.result, error => error.stage === stage);
  if (stage === 'redirect') { picture.url = 'https://example.com/evil.png'; }
  if (stage !== 'dispatch') { h.before(picture); }
  if (stage === 'path') { picture.path = '/unrelated'; h.storage.set('/unrelated', { bytes: png }); }
  if (['path', 'read', 'cleanup'].includes(stage)) { await h.finish(picture); }
  await rejected; await flush();
  if (stage === 'cleanup') { await assert.rejects(h.images.close(), error => error.stage === 'cleanup'); h.config({ unlinkError: undefined }); }
  await h.images.close(); assert.equal(h.pickerCalls, 0); assert.equal(h.handles.size, 0);
  if (stage === 'path') { assert.equal(h.storage.has('/unrelated'), true); }
  else { assert.equal(h.storage.size, 0); }
}

// Ordinary downloads retain their picker/copy/report behavior, even for the same CDN URL.
{
  const h = harness(), ordinary = h.item('https://example.com/report.pdf'); h.before(ordinary); await h.finish(ordinary);
  assert.equal(h.pickerCalls, 1); assert.equal(h.copied, 1); assert.deepEqual(h.reports, ['saved']);
  const cdn = h.item(); h.before(cdn);
  const request = h.images.request(url); await h.finish(cdn);
  assert.equal(h.pickerCalls, 2); const picture = h.item(); h.before(picture); await h.finish(picture); await request.result;
  const failure = h.item('https://example.com/broken.pdf'); h.before(failure); h.failed(failure);
  assert.deepEqual(h.reports, ['saved', 'saved', 'failed']); await h.images.close();
}

// MediaFiles uses the real service, preserves bytes through ImageKit, and never crosses transports on failure.
{
  const h = harness(), files = new h.MediaFiles(h.images), address = { id: 'real', candidates: [url, avatar] };
  const result = files.load(address, { cacheDir: '/cache' }); await flush();
  const picture = h.item(); h.before(picture); await h.finish(picture); const file = await result;
  assert.equal(file.extension, 'png'); assert.equal(file.width, 20); assert.equal(file.originalSize, true);
  assert.equal(h.httpCalls, 0); assert.equal(h.releases, 1); assert.deepEqual(h.storage.get(file.path).bytes, png);
  assert.equal(await files.load(address, { cacheDir: '/cache' }), file);
  await files.close(); await h.images.close(); assert.equal(h.storage.size, 0);
}
{
  const h = harness(), files = new h.MediaFiles(h.images);
  const result = files.load({ id: 'invalid', candidates: [url, avatar] }, { cacheDir: '/cache' });
  const rejected = assert.rejects(result, /Unsupported image response/); await flush();
  const picture = h.item(); h.before(picture); h.storage.get(picture.path).bytes = new Uint8Array(12); await h.finish(picture);
  await rejected; assert.deepEqual(h.dispatched, [url]); assert.equal(h.httpCalls, 0);
  await files.close(); await h.images.close(); assert.equal(h.storage.size, 0);
}
for (const code of [20, 30, 34, 36]) {
  const h = harness(), files = new h.MediaFiles(h.images);
  const result = files.load({ id: 'failed', candidates: [url, avatar] }, { cacheDir: '/cache' });
  const rejected = assert.rejects(result, error => error.code === code); await flush();
  const picture = h.item(url, { code }); h.before(picture); h.failed(picture); await rejected;
  assert.deepEqual(h.dispatched, [url]); assert.equal(h.httpCalls, 0);
  const retry = files.load({ id: 'failed', candidates: [url, avatar] }, { cacheDir: '/cache' }); await flush();
  const next = h.item(); h.before(next); await h.finish(next); await retry;
  assert.deepEqual(h.dispatched, [url, url]); await files.close(); await h.images.close();
}
{
  const h = harness(), files = new h.MediaFiles(h.images);
  const result = files.load({ id: 'candidate', candidates: [url, avatar] }, { cacheDir: '/cache' }); await flush();
  const missing = h.item(url, { code: 33 }); h.before(missing); h.failed(missing); await flush();
  assert.deepEqual(h.dispatched, [url, avatar]); const face = h.item(avatar); h.before(face); await h.finish(face);
  assert.equal((await result).originalSize, false); assert.equal(h.httpCalls, 0); await files.close(); await h.images.close();
}
{
  const h = harness(), files = new h.MediaFiles(h.images);
  const result = files.load({ id: 'cancelled', candidates: [url] }, { cacheDir: '/cache' });
  const rejected = assert.rejects(result, error => error.stage === 'cancel'); await flush();
  const picture = h.item(); h.before(picture); await files.close(); await rejected;
  assert.equal(picture.cancelled, 1); await h.images.close();
}
for (const injected of [false, true]) {
  const h = harness(); h.state.sync = !injected;
  h.config({ nativeResponses: [{ responseCode: 200, result: png.buffer }] });
  const files = new h.MediaFiles(injected ? h.images : undefined);
  await files.load({ id: 'native', candidates: [url] }, { cacheDir: '/cache' });
  assert.equal(h.httpCalls, 1); assert.deepEqual(h.dispatched, []);
  assert.equal(h.nativeOptions[0].dnsOverHttps, 'https://dns.example/dns-query');
  await files.close(); await h.images.close();
}
console.log('ArkWeb image routing, real bytes, concurrent cancellation, timeout, limits, cleanup, errors and normal download checks passed.');
