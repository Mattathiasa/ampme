#!/usr/bin/env bash
# Creates the release signing key for Ampme and prints the four GitHub
# secrets that make CI sign every APK with it.
#
# Run this on YOUR machine (not in CI, not in a shared session): the key
# is what proves an update comes from you, and Android refuses to install
# an update signed with a different one. Back the .jks file up somewhere
# safe (a password manager works) — if it is lost, existing users must
# uninstall to update.
#
# Usage: tool/make_keystore.sh [OUT.jks]     (default: ./ampme-release.jks)
#
# Then, in GitHub: Settings → Secrets and variables → Actions → New
# repository secret, once for each line printed below.
set -euo pipefail

OUT=${1:-ampme-release.jks}
[ -e "$OUT" ] && { echo "$OUT already exists; refusing to overwrite it." >&2; exit 1; }
command -v keytool >/dev/null || { echo "keytool (a JDK) is required." >&2; exit 1; }

ALIAS=ampme
# Random 32-character hex passwords (safe in a shell and in GitHub secrets).
rand() { od -An -tx1 -N16 /dev/urandom | tr -d ' \n'; }
STORE_PASS=$(rand)
KEY_PASS=$STORE_PASS   # PKCS12 keystores use one password for both

keytool -genkeypair -v -storetype PKCS12 -keystore "$OUT" \
  -alias "$ALIAS" -keyalg RSA -keysize 4096 -validity 10000 \
  -storepass "$STORE_PASS" -keypass "$KEY_PASS" \
  -dname "CN=Ampme, O=Ampme" >/dev/null

echo "Keystore written to: $OUT   (keep it safe; never commit it)"
echo
echo "Add these four repository secrets:"
echo
echo "ANDROID_KEYSTORE_BASE64=$(base64 <"$OUT" | tr -d '\n')"
echo "KEYSTORE_PASSWORD=$STORE_PASS"
echo "KEY_ALIAS=$ALIAS"
echo "KEY_PASSWORD=$KEY_PASS"
