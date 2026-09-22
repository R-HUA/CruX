import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display, window } from '@kit.ArkUI';
import web_webview from '@ohos.web.webview';

const DOMAIN = 0x0000;
// Same store the page uses for the account handle, avatar and composer draft.
const PREFS_NAME: string = 'opentwit_web';
const WINDOW_SIZED_KEY: string = 'pc_window_sized';
// Below this the display is phone-shaped, so there is no desktop window to set.
const DESKTOP_MIN_WIDTH_VP: number = 1000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    this.enableWebDevToolsForDebugBuilds();
  }

  // ArkWeb's DevTools bridge is what `hdc fport` + CDP attach to. It is a
  // debugging surface, so it is switched on only for a debug build and stays
  // off in anything signed for release.
  private enableWebDevToolsForDebugBuilds(): void {
    if (!this.context.applicationInfo.debug) {
      return;
    }
    try {
      web_webview.WebviewController.setWebDebuggingAccess(true);
      hilog.info(DOMAIN, 'testTag', '%{public}s', 'Web DevTools enabled (debug build)');
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, 'testTag', 'setWebDebuggingAccess failed: %{public}d %{public}s', e.code, e.message);
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');
    windowStage.loadContent('pages/MainTabs', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
      }
    });
    this.applyDesktopWindowDefault(windowStage);
  }

  // A 2in1 desktop hands a new app the phone-shaped window it was written for,
  // which is the wrong first impression for a shell that goes wide at 840 vp.
  // So on the first launch on a desktop the window is sized like a desktop app
  // — most of the screen, capped so an ultrawide display does not get a
  // letterbox — and centred; afterwards the size belongs to the user, and the
  // window manager remembers it.
  private async applyDesktopWindowDefault(windowStage: window.WindowStage): Promise<void> {
    if (deviceInfo.deviceType !== '2in1') {
      return;
    }
    try {
      const prefs: preferences.Preferences = await preferences.getPreferences(this.context, PREFS_NAME);
      const sized: boolean = await prefs.get(WINDOW_SIZED_KEY, false) as boolean;
      if (sized) {
        return;
      }
      const main: window.Window = windowStage.getMainWindowSync();
      const screen: display.Display = display.getDefaultDisplaySync();
      // Work in vp: the shell's breakpoints are vp, so the target must be too.
      // (getWindowLimits is the platform ceiling — 2880 vp on this PC — not the
      // size of the screen, so the display is the honest reference.)
      const scale: number = screen.densityDPI / 160;
      const screenWidthVp: number = screen.width / scale;
      const screenHeightVp: number = screen.height / scale;
      if (screenWidthVp < DESKTOP_MIN_WIDTH_VP) {
        // A phone-shaped display: leave it alone, and do not spend the one shot.
        hilog.info(DOMAIN, 'testTag', 'desktop sizing skipped: display is %{public}d vp wide',
          Math.round(screenWidthVp));
        return;
      }
      await prefs.put(WINDOW_SIZED_KEY, true);
      await prefs.flush();
      const targetWidthVp: number = Math.min(screenWidthVp * 0.85, 1440);
      const targetHeightVp: number = Math.min(screenHeightVp * 0.9, 960);
      const widthPx: number = Math.round(targetWidthVp * scale);
      const heightPx: number = Math.round(targetHeightVp * scale);
      await main.resize(widthPx, heightPx);
      // Resizing alone leaves the window hanging over the screen edge it grew
      // towards, so put it back in the middle of the display.
      await main.moveWindowTo(Math.max(0, Math.round((screen.width - widthPx) / 2)),
        Math.max(0, Math.round((screen.height - heightPx) / 2)));
      hilog.info(DOMAIN, 'testTag', 'desktop window sized to %{public}dx%{public}d px (%{public}dx%{public}d vp)',
        widthPx, heightPx, Math.round(targetWidthVp), Math.round(targetHeightVp));
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, 'testTag', 'desktop window sizing skipped: %{public}d %{public}s', e.code, e.message);
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }
}
