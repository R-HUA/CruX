import { preferences } from '@kit.ArkData';

const TOKEN_KEY = 'twitter_token';
const PREFS_NAME = 'auth_session';

export class AuthSession {
  static async beginLogin(): Promise<string> {
    const codeVerifier: string = 'verifier-' + Math.random().toString(36).slice(2) + Date.now().toString(36);
    const prefs: preferences.Preferences = await preferences.getPreferences(getContext(), PREFS_NAME);
    await prefs.put('code_verifier', codeVerifier);
    await prefs.flush();
    return codeVerifier;
  }

  static async finishLogin(code: string): Promise<string> {
    const token: string = 'token-for-' + code;
    const prefs: preferences.Preferences = await preferences.getPreferences(getContext(), PREFS_NAME);
    await prefs.put(TOKEN_KEY, token);
    await prefs.flush();
    return token;
  }
}
