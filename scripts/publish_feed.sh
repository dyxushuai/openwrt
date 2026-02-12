#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/publish_feed.sh \
    --artifacts-dir <dir> \
    --site-dir <dir> \
    --key-name <name.pub> \
    --sdk-url <url> \
    --sdk-dir-glob <glob>

Environment:
  APK_SIGN_PRIVATE_KEY_B64  Base64-encoded private key for index signing
  APK_SIGN_PUBLIC_KEY       Public key content to publish under keys/<key-name>

Description:
  Assemble per-arch APK artifacts into a feed layout, generate signed
  packages.adb indexes, and produce checksums.
EOF
}

ARTIFACTS_DIR=""
SITE_DIR=""
KEY_NAME=""
SDK_URL=""
SDK_DIR_GLOB=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifacts-dir) ARTIFACTS_DIR="${2:-}"; shift 2 ;;
    --site-dir) SITE_DIR="${2:-}"; shift 2 ;;
    --key-name) KEY_NAME="${2:-}"; shift 2 ;;
    --sdk-url) SDK_URL="${2:-}"; shift 2 ;;
    --sdk-dir-glob) SDK_DIR_GLOB="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$ARTIFACTS_DIR" ]] || { echo "Missing --artifacts-dir" >&2; exit 1; }
[[ -n "$SITE_DIR" ]] || { echo "Missing --site-dir" >&2; exit 1; }
[[ -n "$KEY_NAME" ]] || { echo "Missing --key-name" >&2; exit 1; }
[[ -n "$SDK_URL" ]] || { echo "Missing --sdk-url" >&2; exit 1; }
[[ -n "$SDK_DIR_GLOB" ]] || { echo "Missing --sdk-dir-glob" >&2; exit 1; }
[[ -d "$ARTIFACTS_DIR" ]] || { echo "Artifacts dir not found: $ARTIFACTS_DIR" >&2; exit 1; }
[[ -n "${APK_SIGN_PRIVATE_KEY_B64:-}" ]] || { echo "Missing APK_SIGN_PRIVATE_KEY_B64" >&2; exit 1; }
[[ -n "${APK_SIGN_PUBLIC_KEY:-}" ]] || { echo "Missing APK_SIGN_PUBLIC_KEY" >&2; exit 1; }
for cmd in curl tar find sha256sum; do
  command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 1; }
done

ARTIFACTS_DIR="$(cd "$ARTIFACTS_DIR" && pwd -P)"
mkdir -p "$SITE_DIR"
SITE_DIR="$(cd "$SITE_DIR" && pwd -P)"
mkdir -p "$SITE_DIR/keys"
mkdir -p "$SITE_DIR/checksums"

printf '%s' "$APK_SIGN_PUBLIC_KEY" > "$SITE_DIR/keys/$KEY_NAME"

WORK_DIR="$(mktemp -d)"
KEY_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR" "$KEY_DIR"' EXIT
printf '%s' "$APK_SIGN_PRIVATE_KEY_B64" | base64 -d > "$KEY_DIR/feed.rsa"
chmod 600 "$KEY_DIR/feed.rsa"

SDK_ARCHIVE="$WORK_DIR/sdk.tar.zst"
curl -fL --retry 3 -o "$SDK_ARCHIVE" "$SDK_URL"
tar --zstd -xf "$SDK_ARCHIVE" -C "$WORK_DIR"

SDK_DIR="$(find "$WORK_DIR" -maxdepth 1 -type d -name "$SDK_DIR_GLOB" | head -n 1)"
[[ -n "$SDK_DIR" ]] || { echo "SDK dir not found by glob: $SDK_DIR_GLOB" >&2; exit 1; }

APK_BIN="$SDK_DIR/staging_dir/host/bin/apk"
[[ -x "$APK_BIN" ]] || { echo "SDK apk tool not found: $APK_BIN" >&2; exit 1; }

for arch_dir in "$ARTIFACTS_DIR"/*; do
  [[ -d "$arch_dir" ]] || continue
  arch="$(basename "$arch_dir")"
  dest="$SITE_DIR/snapshots/packages/$arch/custom"
  mkdir -p "$dest"

  rm -f "$dest"/*.apk
  find "$arch_dir" -maxdepth 1 -type f -name '*.apk' -exec cp -f {} "$dest"/ \;

  if ! find "$dest" -maxdepth 1 -type f -name '*.apk' | grep -q .; then
    echo "No APK files for arch $arch" >&2
    continue
  fi
done

for d in "$SITE_DIR"/snapshots/packages/*/custom; do
  [[ -d "$d" ]] || continue
  cd "$d"
  ls *.apk >/dev/null 2>&1 || continue
  rm -f packages.adb
  "$APK_BIN" mkndx \
    --root /tmp \
    --keys-dir "$KEY_DIR" \
    --allow-untrusted \
    --sign "$KEY_DIR/feed.rsa" \
    --output packages.adb \
    ./*.apk
done

find "$SITE_DIR/snapshots/packages" -type f \
  \( -name '*.apk' -o -name 'packages.adb' \) \
  -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > "$SITE_DIR/checksums/sha256sum.txt"

echo "Feed content prepared at: $SITE_DIR"
find "$SITE_DIR/snapshots/packages" -maxdepth 4 -type f | LC_ALL=C sort
