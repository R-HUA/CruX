import http from '@ohos.net.http';

export class TweetRecord {
  userName: string;
  handle: string;
  time: string;
  content: string;
  likes: number;
  reposts: number;
  replies: number;
  avatarUrl: string;
  tweetId: string;

  constructor(userName: string, handle: string, time: string, content: string, likes: number, reposts: number,
    replies: number, avatarUrl: string, tweetId: string) {
    this.userName = userName;
    this.handle = handle;
    this.time = time;
    this.content = content;
    this.likes = likes;
    this.reposts = reposts;
    this.replies = replies;
    this.avatarUrl = avatarUrl;
    this.tweetId = tweetId;
  }
}

export class TweetDetail {
  static async fetchOne(handle: string, id: string): Promise<TweetRecord | undefined> {
    let name: string = handle.startsWith('@') ? handle.substring(1) : handle;
    let fx: ESObject | undefined = await TweetDetail.getJson('https://api.fxtwitter.com/' + name + '/status/' + id);
    if (fx) {
      let mapped: TweetRecord | undefined = TweetDetail.mapStatus(fx, name, id);
      if (mapped) {
        return mapped;
      }
    }
    let oe: ESObject | undefined = await TweetDetail.getJson('https://publish.twitter.com/oembed?url=https://twitter.com/' +
      name + '/status/' + id);
    if (oe) {
      return TweetDetail.mapOembed(oe, name, id);
    }
    return undefined;
  }

  private static async getJson(url: string): Promise<ESObject | undefined> {
    try {
      let httpRequest = http.createHttp();
      let response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': 'OpenTwit-Web HarmonyOS WebView'
        },
        connectTimeout: 30000,
        readTimeout: 30000
      });
      if (response && response.responseCode === 200 && response.result) {
        return JSON.parse(response.result as string) as ESObject;
      }
    } catch (err) {
    }
    return undefined;
  }

  private static mapStatus(parsed: ESObject, handle: string, id: string): TweetRecord | undefined {
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
        time = TweetDetail.shortDate(tw['created_at'] as string);
      }
      return new TweetRecord(name, screen, time, text, likes, reposts, replies, avatarUrl, id);
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

  private static mapOembed(parsed: ESObject, handle: string, id: string): TweetRecord | undefined {
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
      let text: string = TweetDetail.stripTags(html.substring(gt + 1, pEnd));
      if (text === '') {
        return undefined;
      }
      let name: string = handle;
      if (rec['author_name']) {
        name = rec['author_name'] as string;
      }
      return new TweetRecord(name, '@' + handle, 'live', text, 0, 0, 0, '', id);
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
}
