// OpenTwit-Web: full Twitter web endpoints + native HarmonyOS shell.
// Single-source routes for the WebView container. Full x.com parity:
// timeline, explore, notifications, DMs, profile, login — all via web.

export const TWITTER_BASE: string = 'https://x.com';
export const TWITTER_HOME: string = 'https://x.com/home';
export const TWITTER_EXPLORE: string = 'https://x.com/explore';
export const TWITTER_NOTIFICATIONS: string = 'https://x.com/notifications';
// 与当前账号网页底栏的真实私信入口保持一致。
export const TWITTER_MESSAGES: string = 'https://x.com/i/chat';
export const TWITTER_SETTINGS: string = 'https://x.com/settings';
export const TWITTER_BOOKMARKS: string = 'https://x.com/i/bookmarks';
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
  TWITTER_HOME
];

// Tab labels are localised resources, not literals: the shell renders them in
// the navigation bar and in the Navigation title, so they must follow the
// system language. See resources/<qualifier>/element/string.json.
export const TAB_COUNT: number = 5;

// Desktop-class mobile UA so x.com serves the full mobile web app,
// tagged so breakages can be traced back to this port.
export const TWITTER_UA: string =
  'Mozilla/5.0 (Linux; HarmonyOS; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) ' +
  'Chrome/120.0 Mobile Safari/537.36 CruX-Web/1.0 HarmonyOS';

// Desktop user agent. Needed for the parts of x.com that the mobile web path
// refuses to serve — notably "email sign-up is only available in the app",
// which blocks creating an account without the native X app.
export const TWITTER_UA_DESKTOP: string =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) ' +
  'Chrome/120.0.0.0 Safari/537.36 CruX-Web/1.0 HarmonyOS';

export function userAgentFor(desktop: boolean): string {
  return desktop ? TWITTER_UA_DESKTOP : TWITTER_UA;
}

export function profileUrl(handle: string): string {
  const clean: string = handle.charAt(0) === '@' ? handle.substring(1) : handle;
  return TWITTER_BASE + '/' + clean;
}

// Account-scoped pages the shell reaches from its own native account menu, so
// the user never has to hunt for them inside the web UI.
export function listsUrl(handle: string): string {
  const clean: string = handle.charAt(0) === '@' ? handle.substring(1) : handle;
  return TWITTER_BASE + '/' + clean + '/lists';
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
export const RESERVED_ROOTS: Record<string, boolean> = {
  '/settings': true,
  '/i': true,
  '/compose': true,
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
  if (!/^https:\/\/(www\.)?(x|twitter)\.com([/?#]|$)/i.test(url)) {
    return -1;
  }
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
  // The mobile web routes direct messages through /i/chat.
  if (path === '/messages' || path.indexOf('/messages/') === 0 ||
    path === '/i/chat' || path.indexOf('/i/chat/') === 0) {
    return 3;
  }
  // Only the profile editor belongs to the Profile tab; other /settings and /i
  // pages (login flow, tweet detail, lists, …) must not steal the highlight.
  if (path === '/settings/profile') {
    return 4;
  }
  if (profileHandleForUrl(url) !== '') {
    return 4;
  }
  return -1;
}

// Handle segment for profile pages (/someuser), else ''.
export function profileHandleForUrl(url: string): string {
  if (!/^https:\/\/(www\.)?(x|twitter)\.com([/?#]|$)/i.test(url)) {
    return '';
  }
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

// 标签根页面用于返回顺序判定，搜索页仍保留网页搜索交互。
export function isTabRootPath(path: string): boolean {
  return path === '/' || path === '/home' || path === '/explore' ||
    path === '/search' || path === '/notifications' || path === '/messages' ||
    path === '/i/chat';
}

// 与文档初始脚本共用路径规则，避免首帧和原生栏采用不同边界。
export const SECONDARY_PATH_PATTERN: string = '^/(settings(?:/.*)?|i/bookmarks(?:/.*)?|i/lists(?:/.*)?|[a-z0-9_]{1,15}/lists(?:/.*)?)$';

/** 二级业务页保留原生返回入口，不显示主标签栏。 */
export function isSecondaryUrl(url: string): boolean {
  return /^https:\/\/(www\.)?(x|twitter)\.com\//i.test(url) &&
    new RegExp(SECONDARY_PATH_PATTERN).test(pathOf(url));
}

/** 只在已支持的业务页面提供原生导航，登录和未知页面保留网页界面。 */
export function usesNativeNavigation(url: string): boolean {
  const path: string = pathOf(url);
  return path !== '/' &&
    (routeIndexForUrl(url) >= 0 || isPostDetailUrl(url) || isSecondaryUrl(url));
}

/** 帖子详情使用返回栏和回复入口，不沿用来源标签页的菜单。 */
export function isPostDetailUrl(url: string): boolean {
  return /^https:\/\/(www\.)?(x|twitter)\.com\//i.test(url) &&
    /^\/(?:[a-z0-9_]{1,15}|i\/web)\/status\/\d+$/.test(pathOf(url));
}

/** 搜索框和候选项由网页一起管理，避免原生输入与网页搜索状态分离。 */
export function usesNativeHeader(url: string): boolean {
  const path: string = pathOf(url);
  return isPostDetailUrl(url) || isSecondaryUrl(url) || profileHandleForUrl(url) !== '' ||
    (usesNativeNavigation(url) && isTabRootPath(path) &&
    path !== '/explore' && path !== '/search');
}
