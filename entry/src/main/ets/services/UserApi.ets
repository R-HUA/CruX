import http from '@ohos.net.http';
import { hilog } from '@kit.PerformanceAnalysisKit';

export class UserProfileData {
  name: string = '';
  handle: string = '';
  bio: string = '';
  followers: number = 0;
  following: number = 0;
  avatarUrl: string = '';
  bannerUrl: string = '';

  constructor(name: string, handle: string, bio: string, followers: number, following: number,
    avatarUrl: string, bannerUrl: string) {
    this.name = name;
    this.handle = handle;
    this.bio = bio;
    this.followers = followers;
    this.following = following;
    this.avatarUrl = avatarUrl;
    this.bannerUrl = bannerUrl;
  }
}

export class UserApi {
  static async fetchUser(handle: string): Promise<UserProfileData | undefined> {
    let name: string = handle.startsWith('@') ? handle.substring(1) : handle;
    if (name === '') {
      return undefined;
    }
    try {
      let httpRequest = http.createHttp();
      let response = await httpRequest.request('https://api.fxtwitter.com/' + name, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': 'OpenTwit-Web HarmonyOS WebView'
        },
        connectTimeout: 30000,
        readTimeout: 30000
      });
      hilog.info(0x0000, 'OpenTwit', 'fetchUser handle=%{public}s code=%{public}d', name, response ? response.responseCode : -1);
      if (!response || response.responseCode !== 200 || !response.result) {
        return undefined;
      }
      let parsed: Record<string, ESObject> = JSON.parse(response.result as string) as Record<string, ESObject>;
      let userObj: ESObject | undefined = parsed['user'];
      if (!userObj) {
        return undefined;
      }
      let user: Record<string, ESObject> = userObj as Record<string, ESObject>;
      let screenName: string = name;
      if (user['screen_name']) {
        screenName = user['screen_name'] as string;
      }
      let displayName: string = screenName;
      if (user['name']) {
        displayName = user['name'] as string;
      }
      let bio: string = '';
      if (user['raw_description']) {
        bio = UserApi.asText(user['raw_description']);
      } else if (user['description']) {
        bio = UserApi.asText(user['description']);
      } else if (user['bio']) {
        bio = UserApi.asText(user['bio']);
      }
      let followers: number = 0;
      if (user['followers']) {
        followers = Number(user['followers']);
      } else if (user['followers_count']) {
        followers = Number(user['followers_count']);
      }
      let following: number = 0;
      if (user['following']) {
        following = Number(user['following']);
      } else if (user['friends']) {
        following = Number(user['friends']);
      } else if (user['friends_count']) {
        following = Number(user['friends_count']);
      }
      let avatarUrl: string = '';
      if (user['avatar_url']) {
        avatarUrl = user['avatar_url'] as string;
      }
      let bannerUrl: string = '';
      if (user['banner_url']) {
        bannerUrl = user['banner_url'] as string;
      }
      return new UserProfileData(displayName, '@' + screenName, bio, followers, following, avatarUrl, bannerUrl);
    } catch (err) {
      return undefined;
    }
  }

  private static asText(value: ESObject): string {
    if (typeof value === 'string') {
      return value as string;
    }
    try {
      let rec: Record<string, ESObject> = value as Record<string, ESObject>;
      if (rec['text']) {
        return rec['text'] as string;
      }
    } catch (err) {
    }
    return '';
  }
}
