// OpenTwit-Web design tokens.
//
// Colours are intentionally NOT declared here: the shell uses the HarmonyOS
// system colour resources ($r('sys.color.ohos_id_color_*')) so light/dark
// adaptation, high-contrast modes and future theme changes are handled by the
// system instead of a hand-maintained copy of the palette.
//
// Typography: the app never overrides the font family — HarmonyOS Sans (and
// the user's font-size / bold-text accessibility settings) apply by default.

// Spacing scale (vp).
export const S4: number = 4;
export const S8: number = 8;
export const S12: number = 12;
export const S16: number = 16;

// Corner radius used by cards and sheets (vp).
export const RADIUS: number = 16;

// Loading indicator drawn above the web content (vp).
export const PROGRESS_HEIGHT: number = 2;

// Minimum touch target for the bottom navigation (vp) — HarmonyOS asks for
// 48vp so the bar stays usable with large fonts and for motor-impaired users.
export const TOUCH_TARGET: number = 48;

// Width of the bottom bar (vp).
export const BAR_HEIGHT: number = 56;

// Width of the side navigation rail used on wide (tablet / unfolded
// foldable / 2in1) layouts (vp).
export const RAIL_WIDTH: number = 88;

// Width breakpoint at which the bottom bar turns into a side rail (vp).
export const WIDE_BREAKPOINT: number = 840;
