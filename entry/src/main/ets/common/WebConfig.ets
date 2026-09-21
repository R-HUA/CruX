// OpenTwit-Web: full Twitter web endpoints + native HarmonyOS shell.
// Single-source routes for the WebView container. Full x.com parity:
// timeline, explore, notifications, DMs, profile, login — all via web.

export const TWITTER_BASE: string = 'https://x.com';
export const TWITTER_HOME: string = 'https://x.com/home';
export const TWITTER_EXPLORE: string = 'https://x.com/explore';
export const TWITTER_NOTIFICATIONS: string = 'https://x.com/notifications';
export const TWITTER_MESSAGES: string = 'https://x.com/messages';
export const TWITTER_COMPOSE: string = 'https://x.com/compose/post';
export const TWITTER_LOGIN: string = 'https://x.com/i/flow/login';
export const TWITTER_SIGNUP: string = 'https://x.com/i/flow/signup';
export const TWITTER_DM_COMPOSE: string = 'https://x.com/messages/compose';
export const TWITTER_NOTIF_SETTINGS: string = 'https://x.com/settings/notifications';
export const TWITTER_EDIT_PROFILE: string = 'https://x.com/settings/profile';

export const TWITTER_ROUTES: string[] = [
  TWITTER_HOME,
  TWITTER_EXPLORE,
  TWITTER_NOTIFICATIONS,
  TWITTER_MESSAGES,
  TWITTER_EDIT_PROFILE
];

// Tab labels are localised resources, not literals: the shell renders them in
// the navigation bar and in the Navigation title, so they must follow the
// system language. See resources/<qualifier>/element/string.json.
export const TAB_COUNT: number = 5;

// Desktop-class mobile UA so x.com serves the full mobile web app,
// tagged so breakages can be traced back to this port.
export const TWITTER_UA: string =
  'Mozilla/5.0 (Linux; HarmonyOS; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) ' +
  'Chrome/120.0 Mobile Safari/537.36 OpenTwit-Web/1.0 HarmonyOS';

// Desktop user agent. Needed for the parts of x.com that the mobile web path
// refuses to serve — notably "email sign-up is only available in the app",
// which blocks creating an account without the native X app.
export const TWITTER_UA_DESKTOP: string =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) ' +
  'Chrome/120.0.0.0 Safari/537.36 OpenTwit-Web/1.0 HarmonyOS';

export function userAgentFor(desktop: boolean): string {
  return desktop ? TWITTER_UA_DESKTOP : TWITTER_UA;
}

export function searchUrl(query: string): string {
  return TWITTER_BASE + '/search?q=' + encodeURIComponent(query);
}

export function profileUrl(handle: string): string {
  const clean: string = handle.charAt(0) === '@' ? handle.substring(1) : handle;
  return TWITTER_BASE + '/' + clean;
}

// Lowercase path of an x.com URL without query/hash/trailing slash.
export function pathOf(url: string): string {
  let lower: string = url.toLowerCase();
  let path: string = '/';
  const scheme: number = lower.indexOf('://');
  if (scheme >= 0) {
    const slash: number = lower.indexOf('/', scheme + 3);
    path = slash >= 0 ? lower.substring(slash) : '/';
  } else if (lower.charAt(0) === '/') {
    path = lower;
  }
  const q: number = path.indexOf('?');
  if (q >= 0) {
    path = path.substring(0, q);
  }
  const h: number = path.indexOf('#');
  if (h >= 0) {
    path = path.substring(0, h);
  }
  if (path.length > 1 && path.charAt(path.length - 1) === '/') {
    path = path.substring(0, path.length - 1);
  }
  return path;
}

// Single-segment product roots that are NOT profiles.
const RESERVED_ROOTS: Record<string, boolean> = {
  '/grok': true,
  '/communities': true,
  '/premium': true,
  '/verified-organizations': true,
  '/jobs': true,
  '/login': true,
  '/signup': true,
  '/logout': true,
  '/tos': true,
  '/privacy': true,
  '/cookies': true,
  '/about': true,
  '/safety': true,
  '/blog': true,
  '/developers': true,
  '/ads': true,
  '/business': true,
  '/download': true,
  '/account': true,
  '/intent': true,
  '/oauth': true,
  '/share': true
};

// Map an x.com URL to a tab index so in-page navigation keeps the native
// bar in sync. Returns -1 when the page belongs to no tab (tweet detail,
// lists, …) so the highlight stays put instead of snapping to Home.
export function routeIndexForUrl(url: string): number {
  const path: string = pathOf(url);
  if (path === '/' || path === '/home') {
    return 0;
  }
  if (path === '/explore' || path.indexOf('/explore/') === 0 ||
    path === '/search' || path.indexOf('/search/') === 0) {
    return 1;
  }
  if (path === '/settings/notifications' || path.indexOf('/settings/notifications/') === 0) {
    return 2;
  }
  if (path === '/notifications' || path.indexOf('/notifications/') === 0) {
    return 2;
  }
  if (path === '/messages' || path.indexOf('/messages/') === 0) {
    return 3;
  }
  // Only the profile editor belongs to the Profile tab; other /settings and /i
  // pages (login flow, tweet detail, lists, …) must not steal the highlight.
  if (path === '/settings/profile') {
    return 4;
  }
  if (path.indexOf('/', 1) < 0) {
    if (RESERVED_ROOTS[path]) {
      return -1;
    }
    return 4;
  }
  return -1;
}

// Handle segment for profile pages (/someuser), else ''.
export function profileHandleForUrl(url: string): string {
  const path: string = pathOf(url);
  if (path.indexOf('/', 1) >= 0 || path.length < 2 || path.length > 16) {
    return '';
  }
  if (path === '/home' || path === '/explore' || path === '/notifications' ||
    path === '/messages' || path === '/search' || path === '/settings' || path === '/i') {
    return '';
  }
  if (RESERVED_ROOTS[path]) {
    return '';
  }
  const seg: string = path.substring(1);
  for (let i: number = 0; i < seg.length; i++) {
    const ch: string = seg.charAt(i);
    const ok: boolean = (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch === '_';
    if (!ok) {
      return '';
    }
  }
  return seg;
}

// Tab roots whose web top chrome (logo row / search row) is hidden because
// the native header already covers it. Subpages keep their web header
// (back button, profile name) since native has no back control.
export function isTabRootPath(path: string): boolean {
  return path === '/' || path === '/home' || path === '/explore' ||
    path === '/notifications' || path === '/messages';
}
