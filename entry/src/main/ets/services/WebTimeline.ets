import http from '@ohos.net.http';
import { hilog } from '@kit.PerformanceAnalysisKit';

export class TweetData {
  userName: string;
  handle: string;
  time: string;
  content: string;
  likes: number;
  reposts: number;
  replies: number;
  avatarUrl: string = '';
  tweetId: string = '';

  constructor(userName: string, handle: string, time: string, content: string, likes: number, reposts: number) {
    this.userName = userName;
    this.handle = handle;
    this.time = time;
    this.content = content;
    this.likes = likes;
    this.reposts = reposts;
    this.replies = 0;
  }
}

class CacheEntry {
  tweets: TweetData[] = [];
  timestamp: number = 0;
}

export class StarterRef {
  handle: string;
  id: string;
  constructor(handle: string, id: string) {
    this.handle = handle;
    this.id = id;
  }
}

export class WebTimeline {
  static userAgent: string = 'OpenTwit-Web HarmonyOS WebView';
  private static cache: Record<string, CacheEntry> = {};
  private static CACHE_TTL_MS: number = 15 * 60 * 1000;

  private static normalize(handle: string): string {
    return handle.startsWith('@') ? handle.substring(1) : handle;
  }

  private static isFresh(entry: CacheEntry | undefined): boolean {
    if (!entry) {
      return false;
    }
    return (Date.now() - entry.timestamp) < WebTimeline.CACHE_TTL_MS;
  }

  private static async getJson(url: string): Promise<ESObject | undefined> {
    try {
      let httpRequest = http.createHttp();
      let response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': WebTimeline.userAgent
        },
        connectTimeout: 300000,
        readTimeout: 300000
      });
      hilog.info(0x0000, 'OpenTwit', 'getJson url=%{public}s code=%{public}d', url, response ? response.responseCode : -1);
      if (response && response.responseCode === 200 && response.result) {
        return JSON.parse(response.result as string) as ESObject;
      }
    } catch (err) {
    }
    return undefined;
  }

  static async fetchByHandle(handle: string): Promise<TweetData[]> {
    let name: string = WebTimeline.normalize(handle);
    let key: string = '@' + name;
    let cached: CacheEntry | undefined = WebTimeline.cache[key];
    if (WebTimeline.isFresh(cached)) {
      return (cached as CacheEntry).tweets;
    }
    let tweets: TweetData[] = await WebTimeline.fetchLive(key, name);
    WebTimeline.cache[key] = { tweets: tweets, timestamp: Date.now() } as CacheEntry;
    return tweets;
  }

  private static async fetchLive(key: string, name: string): Promise<TweetData[]> {
    // fxtwitter first: reachable without a key. Syndication second:
    // official Twitter web endpoint for networks where it responds.
    let fxParsed: ESObject | undefined = await WebTimeline.getJson('https://api.fxtwitter.com/' + name);
    if (fxParsed) {
      let fxTweets: TweetData[] = WebTimeline.mapItems(fxParsed, key);
      if (fxTweets.length > 0) {
        return fxTweets;
      }
    }
    let parsed: ESObject | undefined = await WebTimeline.getJson('https://syndication.twitter.com/timeline/profile/' + name);
    if (parsed) {
      return WebTimeline.mapItems(parsed, key);
    }
    return [];
  }

  static async fetchTrends(): Promise<string[]> {
    let parsed: ESObject | undefined = await WebTimeline.getJson('https://syndication.twitter.com/timeline/trends');
    let trends: string[] = WebTimeline.mapTrends(parsed);
    if (trends.length > 0) {
      return trends;
    }
    let fallback: ESObject | undefined = await WebTimeline.getJson('https://api.fxtwitter.com/trends');
    return WebTimeline.mapTrends(fallback);
  }

  static async fetchNotifications(handle: string): Promise<TweetData[]> {
    let name: string = WebTimeline.normalize(handle);
    let parsed: ESObject | undefined = await WebTimeline.getJson('https://syndication.twitter.com/timeline/notifications/' + name);
    if (parsed) {
      let tweets: TweetData[] = WebTimeline.mapItems(parsed, '@' + name);
      if (tweets.length > 0) {
        return tweets;
      }
    }
    let fallback: ESObject | undefined = await WebTimeline.getJson('https://api.fxtwitter.com/' + name + '/notifications');
    if (fallback) {
      return WebTimeline.mapItems(fallback, '@' + name);
    }
    return [];
  }

  static async fetchMessages(handle: string): Promise<TweetData[]> {
    let name: string = WebTimeline.normalize(handle);
    let parsed: ESObject | undefined = await WebTimeline.getJson('https://syndication.twitter.com/timeline/messages/' + name);
    if (parsed) {
      let tweets: TweetData[] = WebTimeline.mapItems(parsed, '@' + name);
      if (tweets.length > 0) {
        return tweets;
      }
    }
    let fallback: ESObject | undefined = await WebTimeline.getJson('https://api.fxtwitter.com/' + name + '/messages');
    if (fallback) {
      return WebTimeline.mapItems(fallback, '@' + name);
    }
    return [];
  }

  static async fetchStarterTimeline(): Promise<TweetData[]> {
    let key: string = '@starter';
    let cached: CacheEntry | undefined = WebTimeline.cache[key];
    if (WebTimeline.isFresh(cached)) {
      return (cached as CacheEntry).tweets;
    }
    let refs: StarterRef[] = [
      new StarterRef('elonmusk', '1518623997054918657'),
      new StarterRef('BarackObama', '1221552460768202756'),
      new StarterRef('JoeBiden', '1325118992785223682'),
      new StarterRef('GretaThunberg', '1608056944501178368'),
      new StarterRef('BTS_twt', '1256648835272605697'),
      new StarterRef('IncredibleCulk', '1298730289737293824'),
      new StarterRef('TwitterDev', '1460323737035677698'),
      new StarterRef('jack', '20')
    ];
    // One batch: a slow network costs one batch, not one batch per post.
    let pending: Promise<TweetData | undefined>[] = [];
    for (let i: number = 0; i < refs.length; i++) {
      pending.push(WebTimeline.fetchStatus(refs[i].handle, refs[i].id));
    }
    hilog.info(0x0000, 'OpenTwit', 'starter batch start count=%{public}d', pending.length);
    let done: (TweetData | undefined)[] = await Promise.all(pending);
    hilog.info(0x0000, 'OpenTwit', 'starter batch done');
    let tweets: TweetData[] = [];
    for (let i: number = 0; i < done.length; i++) {
      if (done[i]) {
        tweets.push(done[i] as TweetData);
      }
    }
    WebTimeline.cache[key] = { tweets: tweets, timestamp: Date.now() } as CacheEntry;
    return tweets;
  }

  public static async fetchStatus(handle: string, id: string): Promise<TweetData | undefined> {
    let fx: ESObject | undefined = await WebTimeline.getJson('https://api.fxtwitter.com/' + handle + '/status/' + id);
    if (fx) {
      let mapped: TweetData | undefined = WebTimeline.mapStatus(fx, handle);
      if (mapped) {
        return mapped;
      }
    }
    let oe: ESObject | undefined = await WebTimeline.getJson('https://publish.twitter.com/oembed?url=https://twitter.com/' + handle + '/status/' + id);
    if (oe) {
      return WebTimeline.mapOembed(oe, handle);
    }
    return undefined;
  }

  private static mapStatus(parsed: ESObject, handle: string): TweetData | undefined {
    try {
      let rec: Record<string, ESObject> = parsed as Record<string, ESObject>;
      let twObj: ESObject | undefined = rec['tweet'];
      if (!twObj) {
        return undefined;
      }
      let tw: Record<string, ESObject> = twObj as Record<string, ESObject>;
      if (!tw['text']) {
        return undefined;
      }
      let text: string = tw['text'] as string;
      let name: string = handle;
      let screen: string = '@' + handle;
      let avatarUrl: string = '';
      let tweetId: string = '';
      if (tw['author']) {
        let ar: Record<string, ESObject> = (tw['author'] as Record<string, ESObject>);
        if (ar['name']) {
          name = ar['name'] as string;
        }
        if (ar['screen_name']) {
          screen = '@' + (ar['screen_name'] as string);
        }
        if (ar['avatar_url']) {
          avatarUrl = ar['avatar_url'] as string;
        }
      }
      let likes: number = 0;
      if (tw['likes']) {
        likes = Number(tw['likes']);
      }
      let reposts: number = 0;
      if (tw['retweets']) {
        reposts = Number(tw['retweets']);
      }
      let replies: number = 0;
      if (tw['replies']) {
        replies = Number(tw['replies']);
      }
      let time: string = 'live';
      if (tw['created_at']) {
        time = WebTimeline.shortDate(tw['created_at'] as string);
      }
      if (tw['id_str']) {
        tweetId = tw['id_str'] as string;
      } else if (tw['id']) {
        tweetId = String(tw['id']);
      }
      let tweet: TweetData = new TweetData(name, screen, time, text, likes, reposts);
      tweet.replies = replies;
      tweet.avatarUrl = avatarUrl;
      tweet.tweetId = tweetId;
      return tweet;
    } catch (err) {
      return undefined;
    }
  }

  private static shortDate(created: string): string {
    let parts: string[] = created.split(' ');
    if (parts.length >= 6) {
      return parts[1] + ' ' + parts[2] + ', ' + parts[5];
    }
    return 'live';
  }

  private static mapOembed(parsed: ESObject, handle: string): TweetData | undefined {
    try {
      let rec: Record<string, ESObject> = parsed as Record<string, ESObject>;
      if (!rec['html']) {
        return undefined;
      }
      let html: string = rec['html'] as string;
      let pStart: number = html.indexOf('<p');
      if (pStart < 0) {
        return undefined;
      }
      let gt: number = html.indexOf('>', pStart);
      let pEnd: number = html.indexOf('</p>', gt);
      if (gt < 0 || pEnd < 0) {
        return undefined;
      }
      let text: string = WebTimeline.stripTags(html.substring(gt + 1, pEnd));
      if (text === '') {
        return undefined;
      }
      let name: string = handle;
      if (rec['author_name']) {
        name = rec['author_name'] as string;
      }
      return new TweetData(name, '@' + handle, 'live', text, 0, 0);
    } catch (err) {
      return undefined;
    }
  }

  private static stripTags(html: string): string {
    let out: string = '';
    let inTag: boolean = false;
    for (let i: number = 0; i < html.length; i++) {
      let ch: string = html.charAt(i);
      if (ch === '<') {
        inTag = true;
        continue;
      }
      if (ch === '>') {
        inTag = false;
        out += ' ';
        continue;
      }
      if (!inTag) {
        out += ch;
      }
    }
    out = out.split('&amp;').join('&');
    out = out.split('&lt;').join('<');
    out = out.split('&gt;').join('>');
    out = out.split('&#39;').join('\'');
    out = out.split('&quot;').join('"');
    out = out.split('&#x27;').join('\'');
    return out;
  }

  private static mapTrends(parsed: ESObject | undefined): string[] {
    if (!parsed) {
      return [];
    }
    try {
      let record: Record<string, ESObject> = parsed as Record<string, ESObject>;
      let items: ESObject[] | undefined = undefined;
      if (record['trends']) {
        items = record['trends'] as ESObject[];
      } else if (record['timeline']) {
        items = record['timeline'] as ESObject[];
      } else if (Array.isArray(parsed)) {
        items = parsed as ESObject[];
      }
      if (!items) {
        return [];
      }
      let trends: string[] = [];
      for (let i: number = 0; i < items.length; i++) {
        let entry: Record<string, ESObject> = items[i] as Record<string, ESObject>;
        if (entry['name']) {
          trends.push(entry['name'] as string);
        } else if (entry['text']) {
          trends.push(entry['text'] as string);
        }
      }
      return trends;
    } catch (err) {
      return [];
    }
  }

  private static mapItems(parsed: ESObject, handle: string): TweetData[] {
    let tweets: TweetData[] = [];
    try {
      let items: ESObject[] = [];
      if (parsed && (parsed as Record<string, ESObject>)['tweets']) {
        items = ((parsed as Record<string, ESObject>)['tweets']) as ESObject[];
      } else if (parsed && (parsed as Record<string, ESObject>)['timeline']) {
        items = ((parsed as Record<string, ESObject>)['timeline']) as ESObject[];
      } else if (Array.isArray(parsed)) {
        items = parsed as ESObject[];
      }
      for (let i: number = 0; i < items.length; i++) {
        let item: ESObject = items[i];
        let record: Record<string, ESObject> = item as Record<string, ESObject>;
        let text: string = '';
        if (record['text']) {
          text = record['text'] as string;
        } else if (record['full_text']) {
          text = record['full_text'] as string;
        } else if (record['content']) {
          text = record['content'] as string;
        } else {
          continue;
        }
        let tweetId: string = '';
        if (record['id_str']) {
          tweetId = record['id_str'] as string;
        } else if (record['id']) {
          tweetId = String(record['id']);
        }
        let tweet: TweetData = new TweetData(handle, handle, 'now', text, 0, 0);
        tweet.avatarUrl = '';
        tweet.tweetId = tweetId;
        tweets.push(tweet);
      }
    } catch (err) {
      return [];
    }
    return tweets;
  }
}
