import http from '@ohos.net.http';

export class FoundUser {
  name: string;
  handle: string;
  avatarUrl: string;
  bio: string;
  followers: number;

  constructor(name: string, handle: string, avatarUrl: string, bio: string, followers: number) {
    this.name = name;
    this.handle = handle;
    this.avatarUrl = avatarUrl;
    this.bio = bio;
    this.followers = followers;
  }
}

export class HandleLookup {
  static async lookup(query: string): Promise<FoundUser | undefined> {
    try {
      let name: string = query.trim();
      if (name.startsWith('@')) {
        name = name.substring(1);
      }
      if (name === '') {
        return undefined;
      }
      let httpRequest = http.createHttp();
      let response = await httpRequest.request('https://api.fxtwitter.com/' + name, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': 'OpenTwit-Web HarmonyOS WebView'
        },
        connectTimeout: 30000,
        readTimeout: 30000
      });
      if (!response || response.responseCode !== 200 || !response.result) {
        return undefined;
      }
      let parsed: Record<string, ESObject> = JSON.parse(response.result as string) as Record<string, ESObject>;
      let userObj: ESObject | undefined = parsed['user'];
      if (!userObj) {
        return undefined;
      }
      let user: Record<string, ESObject> = userObj as Record<string, ESObject>;
      let displayName: string = name;
      if (user['name']) {
        displayName = user['name'] as string;
      }
      let screenName: string = name;
      if (user['screen_name']) {
        screenName = user['screen_name'] as string;
      }
      let avatar: string = '';
      if (user['avatar_url']) {
        avatar = user['avatar_url'] as string;
      }
      let bio: string = '';
      if (user['description']) {
        bio = user['description'] as string;
      } else if (user['bio']) {
        bio = user['bio'] as string;
      }
      let followers: number = 0;
      if (user['followers'] !== undefined) {
        followers = Number(user['followers']);
      } else if (user['followers_count'] !== undefined) {
        followers = Number(user['followers_count']);
      }
      return new FoundUser(displayName, '@' + screenName, avatar, bio, followers);
    } catch (err) {
      return undefined;
    }
    return undefined;
  }
}
