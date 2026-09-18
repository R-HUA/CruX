import { WebTimeline, TweetData } from '../services/WebTimeline';

class HandleEntry {
  tweets: TweetData[] = [];
  timestamp: number = 0;
}

export class WebCache {
  private static entries: Record<string, HandleEntry> = {};
  private static CACHE_TTL_MS: number = 15 * 60 * 1000;

  static isFresh(handle: string): boolean {
    let entry: HandleEntry | undefined = WebCache.entries[handle];
    if (!entry) {
      return false;
    }
    return (Date.now() - entry.timestamp) < WebCache.CACHE_TTL_MS;
  }

  static async loadWeb(handle: string): Promise<TweetData[]> {
    let entry: HandleEntry | undefined = WebCache.entries[handle];
    if (entry && WebCache.isFresh(handle)) {
      return entry.tweets;
    }
    let tweets: TweetData[] = [];
    try {
      tweets = await WebTimeline.fetchByHandle(handle);
    } catch (err) {
      tweets = [];
    }
    WebCache.entries[handle] = { tweets: tweets, timestamp: Date.now() } as HandleEntry;
    return tweets;
  }
}
