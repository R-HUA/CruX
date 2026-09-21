#!/usr/bin/env bash
# Sign the built HAP with the OpenHarmony test signing material that ships in
# the SDK's toolchains/lib directory.
#
# What this produces: a HAP whose signature chain is "OpenHarmony Application
# Release" (issued by "OpenHarmony Application CA"), with a signed provisioning
# profile that names this bundle. That is the standard *test* identity: a device
# or emulator image that trusts the OpenHarmony test root accepts it, a retail
# Huawei device (which trusts AGC-issued certificates instead) does not. For an
# AppGallery release, swap in the AGC-issued .p12/.cer/.p7b for this bundle.
#
# Usage: scripts/sign-hap.sh [unsigned.hap] [out.hap]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK_LIB="${OH_SDK_LIB:-$HOME/Developer/command-line-tools/sdk/default/openharmony/toolchains/lib}"
JAVA_BIN="${JAVA_BIN:-/opt/homebrew/opt/openjdk@17/bin/java}"
KEYTOOL_BIN="${KEYTOOL_BIN:-/opt/homebrew/opt/openjdk@17/bin/keytool}"

IN_HAP="${1:-$REPO_ROOT/entry/build/default/outputs/default/entry-default-unsigned.hap}"
OUT_HAP="${2:-$REPO_ROOT/dist/OpenTwit-Web-1.0.0-signed.hap}"

BUNDLE_NAME="com.opentwit.web"
KEYSTORE="$SDK_LIB/OpenHarmony.p12"
PROFILE_CERT="$SDK_LIB/OpenHarmonyProfileRelease.pem"
SIGN_TOOL="$SDK_LIB/hap-sign-tool.jar"
STORE_PWD="123456"
APP_ALIAS="openharmony application release"
PROFILE_ALIAS="openharmony application profile release"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$IN_HAP" ] || { echo "missing input hap: $IN_HAP" >&2; exit 1; }
[ -f "$KEYSTORE" ] || { echo "missing keystore: $KEYSTORE" >&2; exit 1; }

echo "== 1/5 app signing cert chain"
# The keystore holds the app key together with a self-signed copy of its
# certificate; the certificate devices trust is the CA-issued one embedded in
# the profile template. Same public key, so that is the chain to sign with.
python3 - "$SDK_LIB" "$WORK" <<'PY'
import json, sys, pathlib
lib, work = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
template = json.load(open(lib / 'UnsgnedReleasedProfileTemplate.json'))
(work / 'app_leaf.pem').write_text(template['bundle-info']['distribution-certificate'])
print('  leaf: OpenHarmony Application Release (issued by OpenHarmony Application CA)')
PY
"$KEYTOOL_BIN" -exportcert -alias "cacert" -keystore "$KEYSTORE" -storetype PKCS12 \
  -storepass "$STORE_PWD" -rfc -file "$WORK/ca.pem" >/dev/null
"$KEYTOOL_BIN" -exportcert -alias "openharmony application root ca" -keystore "$KEYSTORE" \
  -storetype PKCS12 -storepass "$STORE_PWD" -rfc -file "$WORK/root.pem" >/dev/null
cat "$WORK/app_leaf.pem" "$WORK/ca.pem" "$WORK/root.pem" > "$WORK/app_chain.pem"

echo "== 2/5 provisioning profile for $BUNDLE_NAME"
python3 - "$SDK_LIB" "$WORK" "$BUNDLE_NAME" <<'PY'
import json, sys, time, uuid, pathlib
lib, work, bundle = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
profile = json.load(open(lib / 'UnsgnedReleasedProfileTemplate.json'))
profile['bundle-info']['bundle-name'] = bundle
# The template's own window expired in 2023; re-date it to the certificate's.
profile['validity'] = {'not-before': int(time.time()) - 3600, 'not-after': 2524607999}
profile['uuid'] = str(uuid.uuid4())
json.dump(profile, open(work / 'profile.json', 'w'), indent=4)
print('  bundle:', bundle, '| distribution:', profile['app-distribution-type'])
PY

echo "== 3/5 sign the profile"
"$JAVA_BIN" -jar "$SIGN_TOOL" sign-profile \
  -mode localSign -keyAlias "$PROFILE_ALIAS" -keyPwd "$STORE_PWD" \
  -profileCertFile "$PROFILE_CERT" -inFile "$WORK/profile.json" \
  -signAlg SHA256withECDSA -keystoreFile "$KEYSTORE" -keystorePwd "$STORE_PWD" \
  -outFile "$WORK/profile.p7b" 2>&1 | tail -2

echo "== 4/5 sign the hap"
mkdir -p "$(dirname "$OUT_HAP")"
"$JAVA_BIN" -jar "$SIGN_TOOL" sign-app \
  -mode localSign -keyAlias "$APP_ALIAS" -keyPwd "$STORE_PWD" \
  -appCertFile "$WORK/app_chain.pem" -profileFile "$WORK/profile.p7b" \
  -inFile "$IN_HAP" -signAlg SHA256withECDSA -keystoreFile "$KEYSTORE" \
  -keystorePwd "$STORE_PWD" -inForm zip -compatibleVersion 12 \
  -outFile "$OUT_HAP" 2>&1 | tail -2

echo "== 5/5 verify"
"$JAVA_BIN" -jar "$SIGN_TOOL" verify-app -inFile "$OUT_HAP" \
  -outCertChain "$WORK/verify-chain.cer" -outProfile "$WORK/verify-profile.p7b" 2>&1 | tail -3
ls -la "$OUT_HAP"
