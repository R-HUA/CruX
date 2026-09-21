#!/usr/bin/env bash
# audit-capture.sh - tap a device location and capture a snapshot for UI review.
# Usage: audit-capture.sh <name> [tapX tapY]
set -u
export PATH="$HOME/Developer/command-line-tools/sdk/default/openharmony/toolchains:$PATH"
T="${T:-127.0.0.1:5555}"
OUT="${OUT:-screenshots/audit}"
mkdir -p "$OUT"
NAME="$1"; shift
if [ "$#" -ge 2 ]; then
  hdc -t "$T" shell uitest uiInput click "$1" "$2" >/dev/null 2>&1
  sleep "${WAIT:-3}"
fi
hdc -t "$T" shell snapshot_display -f "/data/local/tmp/$NAME.jpeg" >/dev/null 2>&1
hdc -t "$T" file recv "/data/local/tmp/$NAME.jpeg" "$OUT/$NAME.jpeg" >/dev/null 2>&1
echo "$OUT/$NAME.jpeg"
