#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/publish_feed.sh \
    --artifacts-dir <dir> \
    --site-dir <dir> \
    --targets-file <file> \
    --key-name <name.pub> \
    [--apk-bin <path>]

Environment:
  APK_SIGN_PRIVATE_KEY_B64  Base64-encoded private key for index signing
  APK_SIGN_PUBLIC_KEY       Public key content to publish under keys/<key-name>

Description:
  Assemble per-target APK artifacts into configured feed paths, generate
  signed packages.adb indexes, and produce checksums. When --apk-bin is
  omitted, each target must provide SDK download metadata.
EOF
}

ARTIFACTS_DIR=""
SITE_DIR=""
TARGETS_FILE=""
KEY_NAME=""
APK_BIN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifacts-dir) ARTIFACTS_DIR="${2:-}"; shift 2 ;;
    --site-dir) SITE_DIR="${2:-}"; shift 2 ;;
    --targets-file) TARGETS_FILE="${2:-}"; shift 2 ;;
    --key-name) KEY_NAME="${2:-}"; shift 2 ;;
    --apk-bin) APK_BIN="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$ARTIFACTS_DIR" ]] || { echo "Missing --artifacts-dir" >&2; exit 1; }
[[ -n "$SITE_DIR" ]] || { echo "Missing --site-dir" >&2; exit 1; }
[[ -n "$TARGETS_FILE" ]] || { echo "Missing --targets-file" >&2; exit 1; }
[[ -n "$KEY_NAME" ]] || { echo "Missing --key-name" >&2; exit 1; }
[[ -d "$ARTIFACTS_DIR" ]] || { echo "Artifacts dir not found: $ARTIFACTS_DIR" >&2; exit 1; }
[[ -f "$TARGETS_FILE" ]] || { echo "Targets file not found: $TARGETS_FILE" >&2; exit 1; }
if [[ -n "$APK_BIN" ]]; then
  [[ -x "$APK_BIN" ]] || { echo "APK tool is not executable: $APK_BIN" >&2; exit 1; }
  APK_BIN="$(cd "$(dirname "$APK_BIN")" && pwd -P)/$(basename "$APK_BIN")"
fi
[[ -n "${APK_SIGN_PRIVATE_KEY_B64:-}" ]] || { echo "Missing APK_SIGN_PRIVATE_KEY_B64" >&2; exit 1; }
[[ -n "${APK_SIGN_PUBLIC_KEY:-}" ]] || { echo "Missing APK_SIGN_PUBLIC_KEY" >&2; exit 1; }
for cmd in curl tar find jq sha256sum; do
  command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 1; }
done

ARTIFACTS_DIR="$(cd "$ARTIFACTS_DIR" && pwd -P)"
TARGETS_FILE="$(cd "$(dirname "$TARGETS_FILE")" && pwd -P)/$(basename "$TARGETS_FILE")"
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

target_count=0

while IFS=$'\t' read -r target_id feed_path sdk_url sdk_sha256 sdk_dir_glob; do
  [[ "$target_id" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "Invalid target id: $target_id" >&2
    exit 1
  }
  [[ -n "$feed_path" && "$feed_path" != /* && "$feed_path" != *".."* ]] || {
    echo "Invalid feed path for target $target_id: $feed_path" >&2
    exit 1
  }
  if [[ -z "$APK_BIN" ]]; then
    [[ -n "$sdk_url" ]] || { echo "Missing SDK URL for target $target_id" >&2; exit 1; }
    [[ "$sdk_sha256" =~ ^[0-9a-f]{64}$ ]] || {
      echo "Invalid SDK SHA-256 for target $target_id" >&2
      exit 1
    }
    [[ -n "$sdk_dir_glob" ]] || {
      echo "Missing SDK directory glob for target $target_id" >&2
      exit 1
    }
  fi

  target_dir="$ARTIFACTS_DIR/$target_id"
  [[ -d "$target_dir" ]] || {
    echo "Artifact directory not found for target $target_id: $target_dir" >&2
    exit 1
  }

  dest="$SITE_DIR/$feed_path"
  mkdir -p "$dest"

  rm -f "$dest"/*.apk
  find "$target_dir" -maxdepth 1 -type f -name '*.apk' -exec cp -f {} "$dest"/ \;

  if ! find "$dest" -maxdepth 1 -type f -name '*.apk' | grep -q .; then
    echo "No APK files for target $target_id" >&2
    exit 1
  fi

  apk_bin="$APK_BIN"
  if [[ -z "$apk_bin" ]]; then
    target_work_dir="$WORK_DIR/$target_id"
    mkdir -p "$target_work_dir"
    sdk_archive="$target_work_dir/sdk.tar.zst"
    curl -fL --retry 3 -o "$sdk_archive" "$sdk_url"
    printf '%s  %s\n' "$sdk_sha256" "$sdk_archive" | sha256sum -c -
    tar --zstd -xf "$sdk_archive" -C "$target_work_dir"

    sdk_dir="$(find "$target_work_dir" -maxdepth 1 -type d -name "$sdk_dir_glob" | head -n 1)"
    [[ -n "$sdk_dir" ]] || {
      echo "SDK directory not found for target $target_id by glob: $sdk_dir_glob" >&2
      exit 1
    }
    apk_bin="$sdk_dir/staging_dir/host/bin/apk"
  fi
  [[ -x "$apk_bin" ]] || { echo "SDK apk tool not found for target $target_id: $apk_bin" >&2; exit 1; }

  pushd "$dest" >/dev/null
  rm -f packages.adb
  "$apk_bin" mkndx \
    --root /tmp \
    --keys-dir "$KEY_DIR" \
    --allow-untrusted \
    --sign "$KEY_DIR/feed.rsa" \
    --output packages.adb \
    ./*.apk
  popd >/dev/null

  ((target_count += 1))
done < <(
  jq -r \
    '.targets[] | [.id, .feed_path, (.sdk_url // ""), (.sdk_sha256 // ""), (.sdk_dir_glob // "")] | @tsv' \
    "$TARGETS_FILE"
)

[[ "$target_count" -gt 0 ]] || { echo "No feed targets configured." >&2; exit 1; }

(
  cd "$SITE_DIR"
  find snapshots -type f \
    \( -name '*.apk' -o -name 'packages.adb' \) \
    -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > checksums/sha256sum.txt
)

echo "Feed content prepared at: $SITE_DIR"
find "$SITE_DIR/snapshots" -type f | LC_ALL=C sort
