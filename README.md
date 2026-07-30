# OpenWrt and ImmortalWrt Snapshots APK Feed Pipeline

This repository builds and publishes custom OpenWrt and ImmortalWrt snapshots
APK feeds with GitHub Actions.

## What this pipeline does

- Builds whitelist packages with distribution-specific SDKs for:
  - `aarch64_cortex-a53` (`mediatek/filogic`)
  - `x86_64` (`x86/64`)
  - `aarch64_cortex-a53` (`ImmortalWrt airoha/an7581`)
- Uses package sources from:
  - a pinned pre-removal `coolsnowwolf/luci` revision for `luci-app-mwan3helper`
  - this repository (optional local feed via `src-link`)
- Normalizes the legacy helper release from `1-3` to APK-compatible `1-r3`.
- Publishes signed feed content to the same repository `gh-pages` branch.
- Verifies each SDK archive against the SHA-256 digest recorded in
  `.ci/targets.json`.

## Package release scope

Edit `.ci/package-whitelist.txt` to control what gets compiled and published.

Current default:

- `luci-app-mwan3helper`
- `luci-i18n-mwan3helper-zh-cn`
- `pdnsd-alt`

`.ci/package-whitelist.txt` controls source packages to compile.
`.ci/artifact-whitelist.txt` controls the APK outputs that must be present
before a build can be published. The Simplified Chinese translation is
generated while compiling `luci-app-mwan3helper`.

## Required GitHub Secrets

Set both secrets in repository settings:

- `APK_SIGN_PRIVATE_KEY_B64`
- `APK_SIGN_PUBLIC_KEY`

Generate a signing keypair locally:

```bash
openssl ecparam -name prime256v1 -genkey -noout -out custom-feed.rsa
openssl ec -in custom-feed.rsa -pubout -out custom-feed.pub
```

Create secret values:

```bash
# Linux
base64 -w0 custom-feed.rsa

# macOS
base64 < custom-feed.rsa | tr -d '\n'
```

- Put the base64 output into `APK_SIGN_PRIVATE_KEY_B64`.
- Put the full file content of `custom-feed.pub` into `APK_SIGN_PUBLIC_KEY`.

## Trigger

- Automatic: push to `main`
- Manual: `workflow_dispatch`, with either one target or all targets selected

Workflow file: `.github/workflows/feed.yml`

## Build host requirements

- OpenWrt SDK packages in `.ci/targets.json` are Linux x86_64 SDKs.
- Local SDK builds must run on Linux x86_64.
- On macOS, use GitHub Actions instead of local SDK execution.

## Published feed layout

After a successful run, `gh-pages` contains:

- `snapshots/packages/aarch64_cortex-a53/custom/*.apk`
- `snapshots/packages/aarch64_cortex-a53/custom/packages.adb`
- `snapshots/packages/x86_64/custom/*.apk`
- `snapshots/packages/x86_64/custom/packages.adb`
- `snapshots/immortalwrt/targets/airoha/an7581/packages/aarch64_cortex-a53/custom/*.apk`
- `snapshots/immortalwrt/targets/airoha/an7581/packages/aarch64_cortex-a53/custom/packages.adb`
- `keys/custom-feed.pub`
- `checksums/sha256sum.txt`

## Router-side usage (example: Filogic / Cortex-A53)

```bash
wget -O /etc/apk/keys/custom-feed.pub \
  https://<owner>.github.io/<repo>/keys/custom-feed.pub

cat >/etc/apk/repositories.d/customfeeds.list <<'EOF'
https://<owner>.github.io/<repo>/snapshots/packages/aarch64_cortex-a53/custom/packages.adb
EOF

apk update
apk add luci-app-mwan3helper luci-i18n-mwan3helper-zh-cn pdnsd-alt
```

For x86_64 routers, replace `aarch64_cortex-a53` with `x86_64`.

## Router-side usage (ImmortalWrt Airoha AN7581)

```bash
wget -O /etc/apk/keys/custom-feed.pub \
  https://<owner>.github.io/<repo>/keys/custom-feed.pub

cat >/etc/apk/repositories.d/customfeeds.list <<'EOF'
https://<owner>.github.io/<repo>/snapshots/immortalwrt/targets/airoha/an7581/packages/aarch64_cortex-a53/custom/packages.adb
EOF

apk update
apk add luci-app-mwan3helper luci-i18n-mwan3helper-zh-cn pdnsd-alt
```

The Airoha feed is separate from the OpenWrt feeds so packages built with
different SDK families never overwrite each other.

## XR1710G release-specific kernel packages

The XR1710G kernel-module pipeline builds only the missing kernel packages for
an exact firmware release. It does not build or publish a replacement firmware
image, and it does not include router runtime configuration.

Current release scope:

- Firmware release: `20260719-5747ad3`
- Source commit: `5747ad32a4b3ef2484d0b01a5af91ea140b29630`
- Kernel release: `6.18.38`
- Installed kernel package:
  `kernel-6.18.38~84454825e3136c38c92f481b32e76c13-r1`
- Packages:
  - `kmod-ip6tables`
  - `kmod-ipt-conntrack-extra`
  - `kmod-ipt-ipopt`
  - `kmod-ipt-ipset`
  - `kmod-nft-compat`

The build first reproduces the original release kernel ABI from the published
`config.buildinfo` and pinned `feeds.buildinfo`. It then enables the five
modules and validates that every APK depends on the original release's exact
kernel package. A mismatch fails the build.

Pull requests run the build and validation only. Publishing is a separate
manual action and requires `publish=true`.

Published path:

```text
snapshots/immortalwrt/targets/airoha/an7581/packages/aarch64_cortex-a53/xr1710g/20260719-5747ad3
```

Do not add this repository to a router running another release. Before
installation, compare the router's installed `kernel` package with
`expected_kernel_dependency` in the workflow artifact's `build-report.txt`.
Each future firmware release needs its own release entry and feed directory.
