import { notificationManager } from '@kit.NotificationKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { UIContext } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { UNREAD_COUNTS_SCRIPT, unquoteScriptResult } from './WebChrome';

const DOMAIN: number = 0x0A11;
const TAG: string = 'OpenTwit';
const NOTIFICATION_ASKED_KEY: string = 'notification_asked';
const BADGE_REFRESH_MS: number = 30000;
const BADGE_RETRY_MS: number = 1200;
const BADGE_RETRY_LIMIT: number = 6;
const NOTIFICATION_POLL_MS: number = 5000;
const NOTIFICATION_POLL_LIMIT: number = 6;

/** 计数读取使用当前页面和账号，避免将上下文复制成另一份状态。 */
export interface UnreadHost {
  webScript: (script: string) => Promise<string>;
  isControllerReady: () => boolean;
  owner: () => string;
  url: () => string;
  isRawWeb: () => boolean;
  getUIContext: () => UIContext;
  putPreference: (key: string, value: preferences.ValueType) => Promise<void>;
}

/** 页面角标、系统角标与轮询共用同一个账号归属。 */
@Observed
export class UnreadSession {
  // 未确认的读取保留上次计数，不能把读取失败解释为零条未读。
  unreadNotifications: number = 0;
  unreadMessages: number = 0;
  private badgeTimer: number = -1;
  private badgeRetryTimer: number = -1;
  private badgeRetries: number = 0;
  private badgeShown: number = -1;
  private badgeSyncing: boolean = false;
  private badgeSyncTarget: string = '';
  private badgeSyncFailures: number = 0;
  private notificationAsked: boolean = false;
  private notificationTimer: number = -1;
  private alive: boolean = false;
  private appBackground: boolean = false;
  private host: UnreadHost;

  constructor(host: UnreadHost) { this.host = host; }

  /** 权限询问记录沿用已有偏好，避免重复弹窗。 */
  async initialize(prefs: preferences.Preferences): Promise<void> {
    this.notificationAsked = await prefs.get(NOTIFICATION_ASKED_KEY, false) as boolean;
  }

  activate(background: boolean): void {
    this.alive = true;
    this.appBackground = background;
  }

  /** 暂停只回收定时器，不把最后一次计数误清为零。 */
  stop(): void {
    if (this.badgeTimer !== -1) { clearInterval(this.badgeTimer); this.badgeTimer = -1; }
    if (this.badgeRetryTimer !== -1) { clearTimeout(this.badgeRetryTimer); this.badgeRetryTimer = -1; }
    if (this.notificationTimer !== -1) { clearTimeout(this.notificationTimer); this.notificationTimer = -1; }
  }

  setBackground(background: boolean): void {
    this.appBackground = background;
    if (background) { this.stop(); }
    else if (this.alive) { this.armBadgeRefresh(); this.badgeRetries = 0; }
  }

  dispose(): void {
    this.alive = false;
    this.stop();
  }

  /** 账号或认证状态变化后，网页缓存和原生计数必须同时失效。 */
  resetAccount(resetLauncher: boolean = true): void {
    this.clearNetworkBadgeCounts();
    this.unreadNotifications = 0;
    this.unreadMessages = 0;
    if (resetLauncher) { this.badgeShown = -1; }
  }

  /** 账号、路由或生命周期变化后，旧网页返回的计数不再生效。 */
  refreshBadges(): void {
    if (!this.host.isControllerReady() || this.host.isRawWeb() || this.appBackground || !this.alive) { return; }
    const owner = this.host.owner();
    const pageUrl = this.host.url();
    try {
      this.host.webScript(UNREAD_COUNTS_SCRIPT).then((raw: string) => {
        if (this.appBackground || !this.alive || this.host.owner() !== owner || this.host.url() !== pageUrl) { return; }
        this.applyBadgeCounts(unquoteScriptResult(raw));
      }, (err: BusinessError) => {
        hilog.debug(DOMAIN, TAG, 'badge read failed: %{public}d %{public}s', err.code, err.message);
        this.retryBadgeRead();
      });
    } catch (err) {
      this.retryBadgeRead();
    }
  }

  private clearNetworkBadgeCounts(): void {
    if (!this.host.isControllerReady()) { return; }
    this.host.webScript('window.__otBadgeEpoch=(window.__otBadgeEpoch||0)+1;window.__otBadgeCounts=null;')
      .catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'event=badge_reset_failed code=%{public}d', err.code);
      });
  }

  private applyBadgeCounts(counts: string): void {
    const cut: number = counts.indexOf('/');
    if (cut <= 0) {
      this.retryBadgeRead();
      return;
    }
    const notifications: number = Number.parseInt(counts.substring(0, cut), 10);
    const messages: number = Number.parseInt(counts.substring(cut + 1), 10);
    if (Number.isNaN(notifications) || Number.isNaN(messages)) {
      this.retryBadgeRead();
      return;
    }
    if (notifications >= 0) {
      this.unreadNotifications = notifications;
    }
    if (messages >= 0) {
      this.unreadMessages = messages;
    }
    if (notifications < 0 || messages < 0) {
      this.retryBadgeRead();
    } else {
      this.badgeRetries = 0;
    }
    this.syncLauncherBadge();
  }

  private retryBadgeRead(): void {
    if (this.appBackground || !this.alive || this.badgeRetryTimer !== -1 || this.badgeRetries >= BADGE_RETRY_LIMIT) {
      return;
    }
    this.badgeRetries++;
    this.badgeRetryTimer = setTimeout(() => {
      this.badgeRetryTimer = -1;
      this.refreshBadges();
    }, BADGE_RETRY_MS);
  }

  private async syncLauncherBadge(): Promise<void> {
    const total: number = this.unreadNotifications + this.unreadMessages;
    const target = this.host.owner() + ':' + total;
    if (target !== this.badgeSyncTarget) { this.badgeSyncTarget = target; this.badgeSyncFailures = 0; }
    if (this.badgeSyncFailures >= BADGE_RETRY_LIMIT) { return; }
    if (this.badgeSyncing || total === this.badgeShown) {
      return;
    }
    if (total > 0 && !this.notificationsAllowed()) {
      // HarmonyOS treats the app-icon badge as a notification surface — its own
      // permission dialog lists "角标 / badge" among the reminder modes — so
      // nothing lands on the icon until the account allows notifications.
      this.askForNotificationsOnce();
      return;
    }
    const owner = this.host.owner();
    this.badgeSyncing = true;
    hilog.info(DOMAIN, TAG, 'launcher badge -> %{public}d', total);
    try {
      await notificationManager.setBadgeNumber(total);
      if (owner === this.host.owner()) { this.badgeShown = total; }
      this.badgeSyncFailures = 0;
      hilog.info(DOMAIN, TAG, 'event=launcher_badge_applied total=%{public}d', total);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'event=launcher_badge_failed error=%{public}s', JSON.stringify(err));
      this.badgeSyncFailures++;
      if (this.badgeSyncFailures < BADGE_RETRY_LIMIT) { this.retryBadgeRead(); }
    } finally {
      this.badgeSyncing = false;
      if (owner !== this.host.owner() || total !== this.unreadNotifications + this.unreadMessages) { this.syncLauncherBadge(); }
    }
  }

  private notificationsAllowed(): boolean {
    try {
      return notificationManager.isNotificationEnabledSync();
    } catch (err) {
      return false;
    }
  }

  private askForNotificationsOnce(): void {
    if (this.notificationAsked) {
      return;
    }
    this.notificationAsked = true;
    this.saveNotificationAsked();
    this.retryLauncherBadgeWhenAllowed(0);
    const host: common.Context | undefined = this.host.getUIContext().getHostContext();
    if (host === undefined) {
      return;
    }
    try {
      notificationManager.requestEnableNotification(host as common.UIAbilityContext)
        .then(() => {
          hilog.info(DOMAIN, TAG, '%{public}s', 'notifications allowed for the icon badge');
          this.badgeShown = -1;
          this.syncLauncherBadge();
        })
        .catch((err: BusinessError) => {
          hilog.info(DOMAIN, TAG, 'notifications declined (%{public}d): icon badge stays off', err.code);
        });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'notification request failed: %{public}s', JSON.stringify(err));
    }
  }

  private retryLauncherBadgeWhenAllowed(attempt: number): void {
    if (this.appBackground || !this.alive || attempt >= NOTIFICATION_POLL_LIMIT) {
      return;
    }
    this.notificationTimer = setTimeout(() => {
      this.notificationTimer = -1;
      if (this.notificationsAllowed()) {
        this.badgeShown = -1;
        this.syncLauncherBadge();
        return;
      }
      this.retryLauncherBadgeWhenAllowed(attempt + 1);
    }, NOTIFICATION_POLL_MS);
  }

  armBadgeRefresh(): void {
    if (this.appBackground) { return; }
    if (this.badgeTimer !== -1) {
      clearInterval(this.badgeTimer);
    }
    this.badgeTimer = setInterval(() => {
      this.badgeRetries = 0;
      this.refreshBadges();
    }, BADGE_REFRESH_MS);
  }

  private saveNotificationAsked(): void {
    this.host.putPreference(NOTIFICATION_ASKED_KEY, true).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'event=preference_save_failed error=%{public}s', err.message);
    });
  }
}
