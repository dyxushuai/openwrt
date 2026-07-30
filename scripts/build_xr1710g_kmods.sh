#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/build_xr1710g_kmods.sh \
    --release-file <file> \
    --release <release> \
    --whitelist <file> \
    --work-dir <dir> \
    --output-dir <dir>

Description:
  Reproduce an XR1710G release kernel ABI from its published build metadata,
  enable only the whitelisted missing kernel modules, and package them against
  the original release's kernel dependency. No firmware image is published.
EOF
}

RELEASE_FILE=""
RELEASE=""
WHITELIST=""
WORK_DIR=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-file) RELEASE_FILE="${2:-}"; shift 2 ;;
    --release) RELEASE="${2:-}"; shift 2 ;;
    --whitelist) WHITELIST="${2:-}"; shift 2 ;;
    --work-dir) WORK_DIR="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

target_release="$RELEASE"
unset RELEASE VERSION

[[ -f "$RELEASE_FILE" ]] || { echo "Release file not found: $RELEASE_FILE" >&2; exit 1; }
[[ -n "$target_release" ]] || { echo "Missing --release" >&2; exit 1; }
[[ -f "$WHITELIST" ]] || { echo "Whitelist not found: $WHITELIST" >&2; exit 1; }
[[ -n "$WORK_DIR" ]] || { echo "Missing --work-dir" >&2; exit 1; }
[[ -n "$OUTPUT_DIR" ]] || { echo "Missing --output-dir" >&2; exit 1; }

for cmd in curl find git grep jq make sed sha256sum xargs; do
  command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 1; }
done

RELEASE_FILE="$(cd "$(dirname "$RELEASE_FILE")" && pwd -P)/$(basename "$RELEASE_FILE")"
WHITELIST="$(cd "$(dirname "$WHITELIST")" && pwd -P)/$(basename "$WHITELIST")"
mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
WORK_DIR="$(cd "$WORK_DIR" && pwd -P)"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"

if find "$WORK_DIR" -mindepth 1 -maxdepth 1 | grep -q .; then
  echo "Work directory must be empty: $WORK_DIR" >&2
  exit 1
fi
if find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 | grep -q .; then
  echo "Output directory must be empty: $OUTPUT_DIR" >&2
  exit 1
fi

release_json="$(
  jq -ce --arg release "$target_release" \
    '.releases[] | select(.release == $release)' \
    "$RELEASE_FILE"
)"
[[ -n "$release_json" ]] || {
  echo "Release is not configured: $target_release" >&2
  exit 1
}

json_value() {
  jq -er "$1" <<<"$release_json"
}

target_id="$(json_value '.id')"
source_url="$(json_value '.source_url')"
source_ref="$(json_value '.source_ref')"
kernel_release="$(json_value '.kernel_release')"
kernel_package_release="$(json_value '.kernel_package_release')"
kernel_vermagic="$(json_value '.kernel_vermagic')"
config_seed_sha256="$(json_value '.config_seed_sha256')"
arch="$(json_value '.arch')"
config_url="$(json_value '.config_url')"
config_sha256="$(json_value '.config_sha256')"
feeds_url="$(json_value '.feeds_url')"
feeds_sha256="$(json_value '.feeds_sha256')"

[[ "$source_ref" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid source ref: $source_ref" >&2; exit 1; }
[[ "$kernel_vermagic" =~ ^[0-9a-f]{32}$ ]] || {
  echo "Invalid release kernel ABI hash: $kernel_vermagic" >&2
  exit 1
}
[[ "$config_seed_sha256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "Invalid config.seed SHA-256: $config_seed_sha256" >&2
  exit 1
}
[[ "$config_sha256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "Invalid config SHA-256: $config_sha256" >&2
  exit 1
}
[[ "$feeds_sha256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "Invalid feeds SHA-256: $feeds_sha256" >&2
  exit 1
}

mapfile -t packages < <(
  sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' "$WHITELIST" | xargs -n1
)
[[ ${#packages[@]} -gt 0 ]] || { echo "Whitelist is empty: $WHITELIST" >&2; exit 1; }
for package in "${packages[@]}"; do
  [[ "$package" =~ ^kmod-[a-z0-9][a-z0-9+._-]*$ ]] || {
    echo "Invalid kernel package name: $package" >&2
    exit 1
  }
done

source_dir="$WORK_DIR/source"
metadata_dir="$OUTPUT_DIR/metadata"
mkdir -p "$metadata_dir"

git clone --filter=blob:none --no-checkout "$source_url" "$source_dir"
git -C "$source_dir" fetch --depth=1 origin "$source_ref"
git -C "$source_dir" checkout --detach "$source_ref"
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$source_ref" ]] || {
  echo "Source checkout does not match configured ref." >&2
  exit 1
}
printf '%s  %s\n' "$config_seed_sha256" "$source_dir/config.seed" | sha256sum -c -

curl -fL --retry 3 -o "$WORK_DIR/config.buildinfo" "$config_url"
printf '%s  %s\n' "$config_sha256" "$WORK_DIR/config.buildinfo" | sha256sum -c -
curl -fL --retry 3 -o "$WORK_DIR/feeds.buildinfo" "$feeds_url"
printf '%s  %s\n' "$feeds_sha256" "$WORK_DIR/feeds.buildinfo" | sha256sum -c -

cp -f "$source_dir/config.seed" "$source_dir/.config"
cp -f "$WORK_DIR/feeds.buildinfo" "$source_dir/feeds.conf"

pushd "$source_dir" >/dev/null

./scripts/feeds update -a
./scripts/feeds install -a
make defconfig

for package in "${packages[@]}"; do
  if grep -q "^CONFIG_PACKAGE_${package}=[ym]$" .config; then
    echo "Release already enables whitelisted package: $package" >&2
    exit 1
  fi
done

jobs="${JOBS:-2}"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid JOBS value: $jobs" >&2; exit 1; }
make -j"$jobs" download
if ! make -j"$jobs" tools/install; then
  echo "Parallel host-tools build failed; retrying serially with verbose output." >&2
  make -j1 V=s tools/install
fi
make -j"$jobs" toolchain/install
make -j"$jobs" target/linux/compile

mapfile -t baseline_vermagic_files < <(
  find build_dir -type f -path '*/linux-*/.vermagic'
)
[[ ${#baseline_vermagic_files[@]} -eq 1 ]] || {
  echo "Expected exactly one baseline .vermagic, found ${#baseline_vermagic_files[@]}." >&2
  printf '%s\n' "${baseline_vermagic_files[@]}" >&2
  exit 1
}
baseline_vermagic="$(<"${baseline_vermagic_files[0]}")"
[[ "$baseline_vermagic" =~ ^[0-9a-f]{32}$ ]] || {
  echo "Invalid baseline kernel ABI hash: $baseline_vermagic" >&2
  exit 1
}
[[ "$baseline_vermagic" == "$kernel_vermagic" ]] || {
  echo "Reproduced kernel ABI does not match the configured release." >&2
  echo "Expected: $kernel_vermagic" >&2
  echo "Actual:   $baseline_vermagic" >&2
  exit 1
}

for package in "${packages[@]}"; do
  sed -i "/^CONFIG_PACKAGE_${package}=[ym]$/d" .config
  sed -i "/^# CONFIG_PACKAGE_${package} is not set$/d" .config
  printf 'CONFIG_PACKAGE_%s=m\n' "$package" >> .config
done
make defconfig

for package in "${packages[@]}"; do
  grep -qx "CONFIG_PACKAGE_${package}=m" .config || {
    echo "Package selection did not survive defconfig: $package" >&2
    exit 1
  }
done

make -j"$jobs" LINUX_VERMAGIC="$baseline_vermagic" target/linux/compile
make -j"$jobs" LINUX_VERMAGIC="$baseline_vermagic" package/kernel/linux/compile

mapfile -t module_vermagic_files < <(
  find build_dir -type f -path '*/linux-*/.vermagic'
)
[[ ${#module_vermagic_files[@]} -eq 1 ]] || {
  echo "Expected exactly one module .vermagic, found ${#module_vermagic_files[@]}." >&2
  exit 1
}
module_vermagic="$(<"${module_vermagic_files[0]}")"
[[ "$module_vermagic" =~ ^[0-9a-f]{32}$ ]] || {
  echo "Invalid module build hash: $module_vermagic" >&2
  exit 1
}
[[ "$module_vermagic" != "$baseline_vermagic" ]] || {
  echo "Module selections did not change the generated kernel ABI hash." >&2
  exit 1
}

apk_bin="$source_dir/staging_dir/host/bin/apk"
[[ -x "$apk_bin" ]] || { echo "Host APK tool not found: $apk_bin" >&2; exit 1; }
expected_kernel_dependency="kernel=${kernel_release}~${baseline_vermagic}-r${kernel_package_release}"

for package in "${packages[@]}"; do
  mapfile -t artifacts < <(
    find "bin/targets/airoha/an7581/packages" -maxdepth 1 -type f \
      -name "${package}-${kernel_release}-r${kernel_package_release}.apk"
  )
  [[ ${#artifacts[@]} -eq 1 ]] || {
    echo "Expected one APK for $package, found ${#artifacts[@]}." >&2
    printf '%s\n' "${artifacts[@]}" >&2
    exit 1
  }

  metadata_file="$metadata_dir/${package}.json"
  "$apk_bin" adbdump --format json "${artifacts[0]}" > "$metadata_file"
  jq -e --arg package "$package" \
    '(.info // .).name == $package' "$metadata_file" >/dev/null || {
    echo "APK name validation failed: $package" >&2
    exit 1
  }
  jq -e --arg arch "$arch" \
    '((.info // .).arch // (.info // .).architecture) == $arch' \
    "$metadata_file" >/dev/null || {
    echo "APK architecture validation failed: $package" >&2
    exit 1
  }
  jq -e --arg dependency "$expected_kernel_dependency" \
    '[.. | strings] | any(. == $dependency)' \
    "$metadata_file" >/dev/null || {
      echo "APK kernel dependency validation failed: $package" >&2
      echo "Expected dependency: $expected_kernel_dependency" >&2
      exit 1
    }

  cp -f "${artifacts[0]}" "$OUTPUT_DIR/"
done

{
  printf 'target_id=%s\n' "$target_id"
  printf 'release=%s\n' "$target_release"
  printf 'source_ref=%s\n' "$source_ref"
  printf 'kernel_release=%s\n' "$kernel_release"
  printf 'kernel_package_release=%s\n' "$kernel_package_release"
  printf 'verified_release_vermagic=%s\n' "$kernel_vermagic"
  printf 'baseline_vermagic=%s\n' "$baseline_vermagic"
  printf 'module_config_vermagic=%s\n' "$module_vermagic"
  printf 'expected_kernel_dependency=%s\n' "$expected_kernel_dependency"
  printf 'packages=%s\n' "$(IFS=,; echo "${packages[*]}")"
  printf '\n'
  (
    cd "$OUTPUT_DIR"
    sha256sum ./*.apk
  )
} > "$OUTPUT_DIR/build-report.txt"

popd >/dev/null

echo "Validated XR1710G kernel packages:"
find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.apk' -print | LC_ALL=C sort
echo "Build report: $OUTPUT_DIR/build-report.txt"
