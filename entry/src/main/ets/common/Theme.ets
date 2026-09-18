// HarmonyOS visual system tokens for OpenTwit-Web.
// Uses HarmonyOS Sans as the app-wide font family.

export const FONT_FAMILY: string = 'HarmonyOS Sans';
export const FONT_TITLE: number = 20;
export const FONT_BODY: number = 16;
export const RADIUS: number = 16;
export const S4: number = 4;
export const S8: number = 8;
export const S12: number = 12;
export const S16: number = 16;

export const LIGHT_THEME_COLOR: string = '#FFFFFF';
export const DARK_THEME_COLOR: string = '#000000';

@Entry
@Component
export struct ThemeProvider {
  @Provide themeColor: Resource = $r('app.color.hw_bg_light');
  @Provide fontFamily: string = FONT_FAMILY;

  build() {
  }
}

// Apply light theme tokens. Caller stores the returned color via @Provide.
export function applyLight(): Resource {
  return $r('app.color.hw_bg_light');
}

// Apply dark theme tokens. Caller stores the returned color via @Provide.
export function applyDark(): Resource {
  return $r('app.color.hw_bg_dark');
}
