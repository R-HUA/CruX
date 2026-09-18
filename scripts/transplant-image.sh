#!/usr/bin/env bash
# transplant-image.sh — bring a HarmonyOS Phone image from elsewhere on this Mac into the emulator images dir, then list images and create the OpenTwit AVD.
# Search record (mdfind + find across /Users, /Applications, ~/Library for emulator/system-image/.img):
#   Emulator binaries: ~/Developer/command-line-tools/bin/Emulator, ~/Developer/command-line-tools/emulator/Emulator
#   Android (NOT HarmonyOS) system-images: ~/Library/Android/sdk/system-images/android-37.1/google_apis_playstore_ps16k/arm64-v8a/*.img
#   Android AVD imgs (NOT HarmonyOS): ~/.android/avd/Medium_Phone.avd/*.img
#   Unrelated device imgs: ~/Developer/a20e-root/*.img, ~/Developer/lisa-root/*.img
#   Huawei emulator cache holds only .emu_config: ~/Library/Caches/Huawei/Emulator6.1/.emu_config
#   No HarmonyOS Phone system-image or image zip found anywhere on this Mac.
#   Emulator images dir target: ~/Developer/command-line-tools/emulator
set -u
export PATH="$HOME/Developer/command-line-tools/sdk/default/openharmony/toolchains:$HOME/Developer/command-line-tools/bin:$HOME/Developer/command-line-tools/emulator:$PATH"
DST="$HOME/Developer/command-line-tools/emulator"; mkdir -p "$DST"; FOUND=""; for CAND in $(mdfind "kMDItemDisplayName == '*HarmonyOS*Phone*image*'cos(1)" 2>/dev/null) $(find /Users /Applications "$HOME/Library" -maxdepth 6 -iname "*harmony*phone*image*" 2>/dev/null); do if [ -f "$CAND" ]; then case "$CAND" in *.zip) echo "unzipping HarmonyOS image $CAND -> $DST"; unzip -q -o "$CAND" -d "$DST" && FOUND="$CAND";; *) echo "copying HarmonyOS image $CAND -> $DST/ preserving structure"; cp -pR "$CAND" "$DST/" && FOUND="$CAND";; esac; fi; done; if [ -z "$FOUND" ]; then echo "transplant: no HarmonyOS Phone image found on this Mac; nothing copied"; fi
Emulator -imageList -downloaded true
Emulator -create OpenTwit_Phone_API24 -deviceType Phone -osVersion "HarmonyOS 6.1.1"
