#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/build_sdk_packages.sh \
    --sdk-url <url> \
    --sdk-dir-glob <glob> \
    --repo-dir <repo_dir> \
    --whitelist <file> \
    --output-dir <dir>

Description:
  Build whitelist packages with an OpenWrt snapshots SDK and collect .apk outputs.
EOF
}

SDK_URL=""
SDK_DIR_GLOB=""
REPO_DIR=""
WHITELIST=""
OUTPUT_DIR=""
COOLSNOWWOLF_LUCI_URL="${COOLSNOWWOLF_LUCI_URL:-https://github.com/coolsnowwolf/luci.git}"
COOLSNOWWOLF_PACKAGES_URL="${COOLSNOWWOLF_PACKAGES_URL:-https://github.com/coolsnowwolf/packages.git}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sdk-url) SDK_URL="${2:-}"; shift 2 ;;
    --sdk-dir-glob) SDK_DIR_GLOB="${2:-}"; shift 2 ;;
    --repo-dir) REPO_DIR="${2:-}"; shift 2 ;;
    --whitelist) WHITELIST="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$SDK_URL" ]] || { echo "Missing --sdk-url" >&2; exit 1; }
[[ -n "$SDK_DIR_GLOB" ]] || { echo "Missing --sdk-dir-glob" >&2; exit 1; }
[[ -n "$REPO_DIR" ]] || { echo "Missing --repo-dir" >&2; exit 1; }
[[ -n "$WHITELIST" ]] || { echo "Missing --whitelist" >&2; exit 1; }
[[ -n "$OUTPUT_DIR" ]] || { echo "Missing --output-dir" >&2; exit 1; }
[[ -f "$WHITELIST" ]] || { echo "Whitelist not found: $WHITELIST" >&2; exit 1; }

for cmd in curl tar sed awk make grep xargs; do
  command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 1; }
done

REPO_DIR="$(cd "$REPO_DIR" && pwd)"
OUTPUT_DIR="$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

mapfile -t PACKAGES < <(sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' "$WHITELIST" | xargs -n1)
[[ ${#PACKAGES[@]} -gt 0 ]] || { echo "Whitelist is empty: $WHITELIST" >&2; exit 1; }

SDK_ARCHIVE="$WORKDIR/sdk.tar.zst"
curl -fL --retry 3 -o "$SDK_ARCHIVE" "$SDK_URL"
tar --zstd -xf "$SDK_ARCHIVE" -C "$WORKDIR"

SDK_DIR="$(find "$WORKDIR" -maxdepth 1 -type d -name "$SDK_DIR_GLOB" | head -n 1)"
[[ -n "$SDK_DIR" ]] || { echo "SDK dir not found by glob: $SDK_DIR_GLOB" >&2; exit 1; }

pushd "$SDK_DIR" >/dev/null

# Prefer GitHub mirrors for better availability in CI.
cp -f feeds.conf.default feeds.conf
sed -i.bak 's#https://git.openwrt.org/feed/packages.git#https://github.com/openwrt/packages.git#g' feeds.conf
sed -i.bak 's#https://git.openwrt.org/project/luci.git#https://github.com/openwrt/luci.git#g' feeds.conf
sed -i.bak 's#https://git.openwrt.org/feed/routing.git#https://github.com/openwrt/routing.git#g' feeds.conf
sed -i.bak 's#https://git.openwrt.org/feed/telephony.git#https://github.com/openwrt/telephony.git#g' feeds.conf
rm -f feeds.conf.bak
echo "src-git coolsnowwolf_packages $COOLSNOWWOLF_PACKAGES_URL" >> feeds.conf
echo "src-git coolsnowwolf_luci $COOLSNOWWOLF_LUCI_URL" >> feeds.conf
echo "src-link local $REPO_DIR" >> feeds.conf

./scripts/feeds update -a
touch .config

install_feed_package() {
  local pkg="$1"
  local feed=""

  for feed in local coolsnowwolf_luci coolsnowwolf_packages; do
    if ./scripts/feeds list -r "$feed" | awk '{print $1}' | grep -Fxq "$pkg"; then
      ./scripts/feeds install -p "$feed" -f "$pkg"
      return 0
    fi
  done

  ./scripts/feeds install -f "$pkg"
}

for pkg in "${PACKAGES[@]}"; do
  echo "Installing package metadata for: $pkg"
  install_feed_package "$pkg"
  if ! grep -q "^CONFIG_PACKAGE_${pkg}=m$" .config; then
    echo "CONFIG_PACKAGE_${pkg}=m" >> .config
  fi
done

make defconfig

for pkg in "${PACKAGES[@]}"; do
  echo "Compiling package: $pkg"
  compile_target=""
  feed_pkg_dir="$(find package/feeds \( -type d -o -type l \) -name "$pkg" | head -n 1 || true)"

  if [[ -n "$feed_pkg_dir" ]]; then
    compile_target="${feed_pkg_dir}/compile"
  else
    compile_target="package/${pkg}/compile"
  fi

  make "$compile_target" -j"$(nproc)" V=s
done

for pkg in "${PACKAGES[@]}"; do
  find bin/packages -type f -name "${pkg}-*.apk" -exec cp -f {} "$OUTPUT_DIR"/ \;
done

popd >/dev/null

if ! find "$OUTPUT_DIR" -type f -name '*.apk' | grep -q .; then
  echo "No APK artifacts were generated." >&2
  exit 1
fi

ls -lh "$OUTPUT_DIR"
