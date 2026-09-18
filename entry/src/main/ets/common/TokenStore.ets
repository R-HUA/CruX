import { preferences } from '@kit.ArkData';

export class TokenStore {
  private static readonly STORE_NAME: string = 'opentwit_auth';
  private static readonly TOKEN_KEY: string = 'twitter_token';
  private static readonly HANDLE_KEY: string = 'twitter_handle';

  private static async getStore(context: Context): Promise<preferences.Preferences> {
    return await preferences.getPreferences(context, TokenStore.STORE_NAME);
  }

  static async saveToken(context: Context, token: string): Promise<void> {
    const store: preferences.Preferences = await TokenStore.getStore(context);
    await store.put(TokenStore.TOKEN_KEY, token);
    await store.flush();
  }

  static async loadToken(context: Context): Promise<string> {
    const store: preferences.Preferences = await TokenStore.getStore(context);
    return await store.get(TokenStore.TOKEN_KEY, '') as string;
  }

  static async saveHandle(context: Context, handle: string): Promise<void> {
    const store: preferences.Preferences = await TokenStore.getStore(context);
    await store.put(TokenStore.HANDLE_KEY, handle);
    await store.flush();
  }

  static async loadHandle(context: Context): Promise<string> {
    const store: preferences.Preferences = await TokenStore.getStore(context);
    return await store.get(TokenStore.HANDLE_KEY, '') as string;
  }
}
