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
- Publishes signed feed content to the same repository `gh-pages` branch.
- Verifies each SDK archive against the SHA-256 digest recorded in
  `.ci/targets.json`.

## Package release scope

Edit `.ci/package-whitelist.txt` to control what gets compiled and published.

Current default:

- `luci-app-mwan3helper`
- `pdnsd-alt`

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
apk add luci-app-mwan3helper pdnsd-alt
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
apk add luci-app-mwan3helper pdnsd-alt
```

The Airoha feed is separate from the OpenWrt feeds so packages built with
different SDK families never overwrite each other.
