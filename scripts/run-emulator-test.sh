#!/usr/bin/env bash
#
# run-emulator-test.sh — HarmonyOS emulator boot + HAP install + screenshot test.
#
# No third-party proxy tool is used. All network goes direct (no http_proxy set;
# Emulator install commands are invoked WITHOUT -http_proxy).
#
# Pipeline:
#   1. Put HarmonyOS bin dirs on PATH (hdc, Emulator wrapper, hvigorw)
#   2. hdc kill + hdc start (restart server)
#   3. Emulator -list (AVDs) + -imageList -downloaded true (downloaded images)
#   4. Launch AVD in background (if one exists)
#   5. hdc wait-for-device equivalent (poll `hdc list targets`)
#   6. hdc shell getprop (device fingerprint)
#   7. hvigorw assembleHap (skipped gracefully if no HarmonyOS project present)
#   8. hdc install <hap> (skipped gracefully if no HAP was built)
#   9. hdc shell aa start (skipped gracefully if no HAP was installed)
#  10. hdc shell screencap -> $SCREENSHOT_DIR (3 captures)
#
# Env overrides:
#   SCREENSHOT_DIR  default: ./screenshots
#   LOG_FILE        default: ./emulator-test.log (all output is tee'd there)
#   AVD_NAME        default: first AVD from `Emulator -list`; required to boot
#   HAP_PATH        default: entry/build/default/outputs/default/entry-default.hap
#   APP_BUNDLE      default: com.example.opentwitweb (used for `aa start`)
#   HDC_WAIT_SECS   default: 300
#
set -u
# NOTE: no `set -e`; every stage reports PASS/SKIP/FAIL and the run continues
# so the report always has a complete picture.

CLT="$HOME/Developer/command-line-tools"
TOOLCHAINS="$CLT/sdk/default/openharmony/toolchains"
export PATH="$TOOLCHAINS:$CLT/bin:$CLT/emulator:$PATH"
export DEVECO_SDK_HOME="$CLT/sdk"
export DEVECO_NODE_HOME="$CLT/tool/node"

SCREENSHOT_DIR="${SCREENSHOT_DIR:-./screenshots}"
LOG_FILE="${LOG_FILE:-./emulator-test.log}"
AVD_NAME="${AVD_NAME:-}"
HAP_PATH="${HAP_PATH:-entry/build/default/outputs/default/entry-default.hap}"
APP_BUNDLE="${APP_BUNDLE:-com.example.opentwitweb}"
HDC_WAIT_SECS="${HDC_WAIT_SECS:-300}"

mkdir -p "$SCREENSHOT_DIR"
exec > >(tee "$LOG_FILE") 2>&1

pass() { echo "[PASS] $1"; }
skip() { echo "[SKIP] $1"; }
fail() { echo "[FAIL] $1"; }

echo "=== 0. Tool versions ==="
command -v hdc && hdc --version || fail "hdc not found on PATH"
command -v Emulator && Emulator -version || fail "Emulator wrapper not found"
command -v hvigorw && hvigorw --version || fail "hvigorw not found"
echo "no proxy in use: http_proxy=${http_proxy:-<unset>} https_proxy=${https_proxy:-<unset>} all_proxy=${all_proxy:-<unset>}"

echo "=== 1. hdc kill + hdc start ==="
hdc kill; hdc start
pass "hdc server restarted"

echo "=== 2. List AVDs and downloaded images (direct, no -http_proxy flag) ==="
Emulator -list -details || fail "Emulator -list failed"
Emulator -imageList -downloaded true || fail "-imageList -downloaded failed"
if [ -z "$AVD_NAME" ]; then
  AVD_NAME="$(Emulator -list 2>/dev/null | grep -v '^\[' | grep -v '^$' | head -n 1 | xargs || true)"
fi
echo "AVD_NAME=${AVD_NAME:-<none>}"

echo "=== 3. Launch emulator in background ==="
if [ -n "$AVD_NAME" ]; then
  # No -http_proxy flag: direct connection per policy.
  nohup Emulator -start "$AVD_NAME" > "$SCREENSHOT_DIR/../emulator-boot.log" 2>&1 &
  echo "emulator PID: $!"
  pass "launch requested for AVD '$AVD_NAME'"
else
  skip "no AVD exists; cannot launch. Create one after downloading an image, e.g.: Emulator -create -name Phone_API13 -deviceType Phone -osVersion \"HarmonyOS 5.0.1(13)\""
fi

echo "=== 4. Wait for device ==="
DEVICE_KEY=""
i=0
while [ "$i" -lt "$HDC_WAIT_SECS" ]; do
  OUT="$(hdc list targets 2>&1 || true)"
  echo "$OUT"
  # A connected device line is non-empty and not "[Empty]".
  if echo "$OUT" | grep -qv '^\[Empty\]' && echo "$OUT" | grep -q '[^[:space:]]'; then
    DEVICE_KEY="$(echo "$OUT" | grep -v '^\[' | grep -v '^$' | head -n 1 | xargs)"
    pass "device online: $DEVICE_KEY"
    break
  fi
  sleep 5
  i=$((i + 5))
done
if [ -z "$DEVICE_KEY" ]; then
  fail "no device appeared within ${HDC_WAIT_SECS}s (hdc list targets shows [Empty])"
fi

echo "=== 5. Device fingerprint ==="
if [ -n "$DEVICE_KEY" ]; then
  hdc shell getprop 2>&1 | head -n 40 || fail "getprop failed"
  hdc shell getprop hw_sc.build.os.version 2>&1 || true
  hdc shell getprop ro.build.version.sdk 2>&1 || true
  pass "getprop captured"
else
  skip "no device; getprop not attempted"
fi

echo "=== 6. Build HAP ==="
if [ -f "hvigorw" ] || [ -f "hvigor/hvigorw" ] || command -v hvigorw >/dev/null; then
  if [ -d "entry" ] && [ -d "AppScope" ]; then
    hvigorw --no-daemon assembleHap 2>&1 | tail -n 20 && pass "assembleHap finished" || fail "assembleHap failed"
  else
    skip "no HarmonyOS project (AppScope/entry) in $(pwd); build not attempted"
  fi
else
  skip "hvigorw wrapper not present in project; build not attempted"
fi

echo "=== 7. Install HAP ==="
if [ -n "$DEVICE_KEY" ] && [ -f "$HAP_PATH" ]; then
  hdc install "$HAP_PATH" && pass "hdc install $HAP_PATH" || fail "hdc install failed"
else
  skip "install not attempted (device='${DEVICE_KEY:-none}', hap='$HAP_PATH' exists=$([ -f "$HAP_PATH" ] && echo yes || echo no))"
fi

echo "=== 8. Launch app ==="
if [ -n "$DEVICE_KEY" ] && [ -f "$HAP_PATH" ]; then
  hdc shell aa start -b "$APP_BUNDLE" -a EntryAbility && pass "aa start $APP_BUNDLE" || fail "aa start failed"
else
  skip "aa start not attempted (no installed HAP)"
fi

echo "=== 9. Screenshots (3) ==="
for n in 1 2 3; do
  OUT_PNG="$SCREENSHOT_DIR/screenshot-$n.png"
  if [ -n "$DEVICE_KEY" ]; then
    if hdc shell screencap -p "/data/local/tmp/screenshot-$n.png" 2>&1; then
      hdc file recv "/data/local/tmp/screenshot-$n.png" "$OUT_PNG" 2>&1 && pass "captured $OUT_PNG" || fail "recv screenshot-$n failed"
    else
      fail "screencap $n failed on device"
    fi
  else
    skip "device absent; screenshot $OUT_PNG not captured"
  fi
  sleep 2
done

echo "=== DONE. Log: $LOG_FILE  Screenshots: $SCREENSHOT_DIR ==="
