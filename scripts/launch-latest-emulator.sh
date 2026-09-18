#!/usr/bin/env bash
# launch-latest-emulator.sh — boot OpenTwit_Phone_API24 and test the built HAP.
set -u
CLT="$HOME/Developer/command-line-tools"
TOOLCHAINS="$CLT/sdk/default/openharmony/toolchains"
export PATH="$TOOLCHAINS:$CLT/bin:$CLT/emulator:$PATH"
export DEVECO_SDK_HOME="$CLT/sdk"
AVD_NAME="${AVD_NAME:-OpenTwit_Phone_API24}"
HAP_PATH="${HAP_PATH:-entry/build/default/outputs/default/entry-default.hap}"
APP_BUNDLE="${APP_BUNDLE:-com.example.opentwit}"
HDC_WAIT_SECS="${HDC_WAIT_SECS:-300}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-./screenshots}"
mkdir -p "$SCREENSHOT_DIR"
hdc kill; hdc start
nohup Emulator -start "$AVD_NAME" > "$SCREENSHOT_DIR/../emulator-boot.log" 2>&1 &
echo "emulator launch requested for AVD '$AVD_NAME' (pid $!)"
DEVICE_SERIAL=""
i=0
while [ "$i" -lt "$HDC_WAIT_SECS" ]; do
  OUT="$(hdc list targets 2>&1 || true)"
  echo "$OUT"
  if echo "$OUT" | grep -qv '^\[Empty\]' && echo "$OUT" | grep -q '[^[:space:]]'; then
    DEVICE_SERIAL="$(echo "$OUT" | grep -v '^\[' | grep -v '^$' | head -n 1 | xargs)"
    echo "device online: $DEVICE_SERIAL"
    break
  fi
  sleep 5
  i=$((i + 5))
done
echo "DEVICE_SERIAL=${DEVICE_SERIAL:-<none>}"
if [ -n "$DEVICE_SERIAL" ] && [ -f "$HAP_PATH" ]; then
  hdc install "$HAP_PATH"
  hdc shell aa start -b "$APP_BUNDLE" -a EntryAbility || true
  hdc shell screencap -p /data/local/tmp/latest.png && hdc file recv /data/local/tmp/latest.png "$SCREENSHOT_DIR/latest.png"
else
  echo "install/aa-start/screencap skipped (device='${DEVICE_SERIAL:-none}', hap='$HAP_PATH' exists=$([ -f "$HAP_PATH" ] && echo yes || echo no))"
fi
