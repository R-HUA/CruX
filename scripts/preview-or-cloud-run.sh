export PATH="$HOME/Developer/command-line-tools/sdk/default/openharmony/toolchains:$HOME/Developer/command-line-tools/bin:$HOME/Developer/command-line-tools/sdk/default/openharmony/previewer/common/bin:$PATH"
# preview-or-cloud-run.sh — run OpenTwit without downloading a system image.
# Stage 1 (above): PATH for hdc/toolchains + DevEco bin + Previewer bin.
# Stage 2: USB device check via hdc list targets. Stage 3: Previewer launch of
# the entry ability. Stage 4: hdc install fallback for a USB real device.
# Safe by default: prints versions + device status and exits 0. Pass --launch
# to actually start the Previewer (needs a built HAP), --hap <path> to point
# at a specific HAP. POSIX sh compatible (no shebang so line 1 stays the export).
set -u
CLT="${DEVECO_CLI_HOME:-$HOME/Developer/command-line-tools}"
SDK="$CLT/sdk/default/openharmony"
PREVIEWER_BIN="$SDK/previewer/common/bin/Previewer"
HDC_BIN="$SDK/toolchains/hdc"
BUNDLE="${APP_BUNDLE:-com.example.opentwit}"
HAP_PATH="${HAP_PATH:-entry/build/default/outputs/default/entry-default.hap}"
DO_LAUNCH="no"
if [ "${1:-}" = "--launch" ]; then DO_LAUNCH="yes"; fi
if [ "${1:-}" = "--hap" ] && [ -n "${2:-}" ]; then HAP_PATH="$2"; fi
if [ "${3:-}" = "--launch" ] || [ "${2:-}" = "--launch" ]; then DO_LAUNCH="yes"; fi
echo "=== Previewer version (no system image needed) ==="
grep -E "Version|HarmonyOS SDK|apiVersion" "$CLT/version.txt" 2>/dev/null || echo "version.txt not found under $CLT"
if [ -x "$HDC_BIN" ]; then "$HDC_BIN" --version 2>&1; else hdc --version 2>&1 || echo "hdc not found on PATH"; fi
if [ -x "$PREVIEWER_BIN" ]; then echo "previewer binary present: $PREVIEWER_BIN"; else echo "previewer binary MISSING at $PREVIEWER_BIN"; fi
echo "=== USB devices: hdc list targets ==="
TARGETS="$(hdc list targets 2>&1 || true)"
echo "$TARGETS"
HAVE_DEVICE="yes"
case "$TARGETS" in *[Ee]mpty*|"") HAVE_DEVICE="no" ;; esac
if [ ! -d "$HOME/Library/Huawei" ]; then echo "(~/Library/Huawei absent: no Huawei USB helper state)"; fi
echo "=== Previewer launch (entry ability EntryAbility, bundle $BUNDLE) ==="
if [ "$DO_LAUNCH" = "yes" ]; then
  if [ -f "$HAP_PATH" ]; then "$PREVIEWER_BIN" -j "$HAP_PATH"; else echo "no HAP at $HAP_PATH; build first, then re-run with --launch"; fi
else
  echo "dry-run (use --launch to start GUI); would run: $PREVIEWER_BIN -j $HAP_PATH"
fi
echo "=== USB fallback: hdc install + aa start ==="
if [ "$HAVE_DEVICE" = "yes" ] && [ -f "$HAP_PATH" ]; then
  hdc install "$HAP_PATH" && hdc shell aa start -b "$BUNDLE" -a EntryAbility
else
  echo "USB fallback skipped (device online: $HAVE_DEVICE, hap: $HAP_PATH)"
fi
