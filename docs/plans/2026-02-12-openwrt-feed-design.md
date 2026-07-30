# OpenWrt Feed Pipeline Design (Snapshots/APK)

Date: 2026-02-12  
Status: Approved; extended for ImmortalWrt/Airoha on 2026-07-30

## 1. Goals

- Build and publish custom OpenWrt and ImmortalWrt feed packages via GitHub Actions.
- Support snapshot APK feeds.
- Support these SDK targets:
  - `aarch64_cortex-a53`
  - `x86_64`
  - `airoha/an7581` using the ImmortalWrt `aarch64_cortex-a53` SDK
- Publish to the same repository `gh-pages` branch.
- Keep a single source of truth for publish scope with a package whitelist.
- Produce both:
  - GitHub Action artifacts (per build)
  - Online feed repository content (for direct router consumption)

## 2. Non-Goals

- No 24.10.x / IPK dual track in phase 1.
- No full firmware image build in CI; package-only pipeline.

## 3. Architecture

### Source and Release Model

- `main` branch:
  - feed source code
  - CI configs/scripts
  - package whitelist
- `gh-pages` branch:
  - published APK feed repository data only

### CI Job Topology

1. `changes` job
   - path filter gate to avoid unnecessary runs
2. `build` matrix job
   - per distribution target
   - download the matching OpenWrt or ImmortalWrt snapshots SDK
   - inject local feed (`src-link`)
   - compile whitelist packages
   - upload per-target artifacts
3. `publish` job
   - depends on successful build matrix
   - download artifacts
   - generate feed index and signatures
   - publish to `gh-pages`

## 4. Release Scope Control

- `.ci/package-whitelist.txt` is the only release scope authority.
- CI compiles and publishes whitelist packages only.
- Dependencies may be built transitively by SDK but are not published unless explicitly listed.

## 5. Signing and Trust

- Use formal signing in CI.
- Private key is stored in GitHub Secrets.
- Public key is published under `gh-pages/keys/`.
- Publish step signs repository index files.
- Secrets are never echoed in logs.

## 6. Repository Layout (Phase 1)

- `.ci/package-whitelist.txt`
- `.ci/targets.json`
- `scripts/build_sdk_packages.sh`
- `scripts/publish_feed.sh`
- `.github/workflows/feed.yml`

## 7. Feed Output Layout

Published under `gh-pages`:

- `snapshots/packages/aarch64_cortex-a53/custom/*.apk`
- `snapshots/packages/x86_64/custom/*.apk`
- `snapshots/packages/<arch>/custom/packages.adb`
- `snapshots/immortalwrt/targets/airoha/an7581/packages/<arch>/custom/*.apk`
- `snapshots/immortalwrt/targets/airoha/an7581/packages/<arch>/custom/packages.adb`
- `keys/<public-key-file>`
- `checksums/sha256sum.txt`

## 8. Failure Policy and Rollback

- If any matrix build fails, publish must not run.
- Publish uses a staging directory and pushes atomically.
- Rollback strategy:
  1. revert `gh-pages` to previous known-good commit
  2. re-run publish using retained artifacts if needed

## 9. Operational Rules

- Trigger: `push` to `main` (automatic).
- Optional manual trigger: `workflow_dispatch`.
- Keep logs and artifacts for a short retention window.
- Add scheduled rebuild later to detect upstream SDK/source drift.

## 10. Security Notes

- No untrusted install path in official docs (no default `--allow-untrusted`).
- Snapshot SDK archives must match the SHA-256 digest pinned in `.ci/targets.json`.
- Package source hashes must be fixed and validated during build.
- Any hash mismatch must fail the pipeline.

## 11. Future Extensions

- Add more architectures from `.ci/targets.json`.
- Split source and releases into dedicated repositories if scale requires.
- Add integration smoke tests against containerized OpenWrt rootfs.
