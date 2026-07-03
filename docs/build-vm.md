# Stable-macOS build VM (`buildvm`)

Free, local, agent-native replacement for the GitHub Actions macOS release runners.

## Why

When this Mac runs a **beta macOS**, any App Store binary archived on it carries a beta
`BuildMachineOSBuild` in its `Info.plist`, and Apple rejects it post-upload with the
misleading **ITMS-90111** ("must use the latest Xcode and SDK Release Candidates") — the
Xcode/SDK can be fully release and it still bounces. Until now the workaround was a
GitHub Actions `macos-latest` runner, but macOS runners bill GitHub-minutes at a **10×
multiplier**, so a ~15-minute archive burns ~150 quota-minutes and a busy release month
exhausts the free tier.

`buildvm` runs the archive inside a **stable-macOS** [Tart](https://tart.run) guest on
this machine, entirely over SSH. The artifact is stamped with the guest's stable host-OS
build number, so ITMS-90111 is impossible by construction. Cost: local CPU + disk only.

This is the **standard release method for the duration of any major macOS beta.** Once
this Mac's macOS goes GM, plain local `xcodebuild` is legal again and the VM is only
needed during the next beta season.

## One-time setup (already done 2026-07-03)

```bash
# Tart (installed from GitHub release, not brew — brew refuses on the Xcode/OS mismatch)
curl -L .../tart.tar.gz | tar xz -C /Applications && ln -s /Applications/tart.app/Contents/MacOS/tart ~/.local/bin/tart

tart clone ghcr.io/cirruslabs/macos-tahoe-base:latest buildvm   # stable macOS 26.5 (25F71)
tart set buildvm --cpu 8 --memory 24576 --disk-size 120
buildvm provision        # SSH key, copy host Xcode.app, download iOS platform, import signing
buildvm snapshot         # → buildvm-provisioned  (reusable CoW base)
```

`buildvm provision` does, over SSH:
1. Installs the host `~/.ssh/id_ed25519.pub` into the guest (`admin`/`admin`, passwordless sudo).
2. Refuses if the guest OS build looks like a beta.
3. rsyncs `/Applications/Xcode.app` into the guest, `xcode-select` + license + `-runFirstLaunch`.
4. **`xcodebuild -downloadPlatform iOS`** — the copied Xcode.app carries the device SDK
   but NOT the platform-component registration Xcode 16+ needs, so `generic/platform=iOS`
   is otherwise "not installed". This ~8.5 GB download registers the destination. (This
   is the one non-obvious gotcha; without it archives fail with "Found no destinations".)
5. Imports `midgar_distribution.p12` + the **Apple WWDR G3/G6 + Apple Root** intermediates
   (a fresh VM lacks them, so `find-identity` reports 0 *valid* identities until they're
   added), `set-key-partition-list`, and copies the ASC API `.p8`.

## Daily use

```bash
buildvm status                          # OS build, Xcode version, valid-identity count
buildvm build \
  --dir  ~/Dev/ios/solarbeam \
  --scheme solarbeam-ios \
  --profile solarbeam-ios-appstore-2026.mobileprovision \   # name in <signing-dir>/ or a path
  --bundle-id com.marcusziade.solarbeam \
  --build 141 [--marketing 3.0.1] \
  [--prebuild ./ci-secrets.sh] [--deploy-key <your-private-spm-deploy-key>] \
  [--no-upload]
```

The `build` flow:
1. Boots the VM if needed, refuses if the guest OS is beta.
2. (`--deploy-key`) installs a read-only SPM deploy key + `~/.ssh/config` for private
   package clones (e.g. AICredits).
3. rsyncs the project into the guest.
4. (`--prebuild`) runs a script in the project dir first — for `Secrets.swift` generation,
   `xcodegen`, etc. (xcodegen also runs automatically if `project.yml` is present).
5. **Two-phase signing** (the important part): archives with `CODE_SIGNING_ALLOWED=NO`,
   then `-exportArchive` re-signs **only the .app** via a generated `ExportOptions.plist`
   (manual, `Apple Distribution`, the profile mapped to the bundle id). This avoids the
   `<Package> does not support provisioning profiles` failure you get when global
   `PROVISIONING_PROFILE_SPECIFIER` leaks onto SPM package targets (MidgarKit,
   RevenueCat, Lottie).
6. Unzips the IPA and **fails hard if `BuildMachineOSBuild` looks like a beta** — the
   whole point, verified on the actual artifact, not the host.
7. `xcrun altool --upload-app` (unless `--no-upload`).

## Multi-target / xcodegen apps (Helia, PayDay, psybeam, …)

Apps with a widget/extension, private SPM deps, secret injection, or `${VAR}` substitution
in `project.yml` need extra flags. Real invocation that shipped Helia 1.0 build 7:

```bash
buildvm build \
  --dir ~/Dev/ios/Helia --scheme Helia \
  --profile <app>.mobileprovision \
  --profile <widget>.mobileprovision \   # repeat --profile per target; bundle-id + name auto-derived
  --component MetalToolchain \                              # mlx-swift compiles Metal shaders
  --deploy-key <your-private-spm-deploy-key> \  # private SPM (AICredits) over SSH
  --env APP_BUNDLE_ID=com.you.app \             # xcodegen ${VAR} substitution — MUST match the app
  --env APP_TEAM_ID=XXXXXXXXXX \
  --archive-flags "-skipPackagePluginValidation -skipMacroValidation -scmProvider system" \
  --marketing 1.0 --build 7
```

Three failures hit on the first Helia run, each now handled by the tooling:
1. **`xcodegen: command not found`** — installed into the guest (provision does this now; PATH
   prepends `/usr/local/bin` for the archive step since the non-login SSH PATH omits it).
2. **`AppIntentsSSUTraining … Unable to parse Info.plist` + empty `--bundle-id`** — `project.yml`
   uses `PRODUCT_BUNDLE_IDENTIFIER: ${APP_BUNDLE_ID}`; without `--env APP_BUNDLE_ID=…` xcodegen
   substitutes empty, the app ships a blank bundle id, and the App Intents processor chokes. Always
   pass every `${VAR}` the project.yml references as `--env`.
3. **`BUILD_INDICATES_GAME_CENTER_DISABLED` at submit** — the app was archived with
   `CODE_SIGNING_ALLOWED=NO`, which SKIPS entitlement processing, so exportArchive re-signed with
   **no entitlements** (game-center/healthkit/weatherkit/app-groups all dropped) and the review
   submission 409'd. **Fix: DEFAULT is now a project-signed archive** — the archive is signed by the
   project's own per-target Release config (Manual + Apple Distribution + the App Store profiles),
   which preserves entitlements and, being per-target, does NOT leak onto SPM packages. Only pass
   `--unsigned-archive` for a project that lacks valid signing config (e.g. a committed .xcodeproj
   with automatic-only signing); then the profile is the sole entitlement source.

Verify entitlements survived before uploading:
`codesign -d --entitlements - --xml Payload/App.app | plutil -convert xml1 -o - -`.

## Notes / gotchas

- **Marketing-version trains.** altool rejects a build whose marketing version maps to a
  closed pre-release train (`Invalid Pre-Release Train … closed`) — this is a project
  version-number matter, not a build failure. Pass `--marketing` to target an open train.
  For xcodegen apps the marketing version's source of truth is `project.yml`
  `info.properties.CFBundleShortVersionString` (see OPERATIONS.md).
- **Snapshot to recover fast.** `buildvm-provisioned` is a CoW clone of the fully-set-up
  guest; if `buildvm` gets into a bad state, `tart delete buildvm && tart clone
  buildvm-provisioned buildvm`. Re-snapshot from a cleanly *stopped* VM for a pristine base.
- **Guest = macOS 26.5 (25F71), Xcode 26.6.** The guest OS need not match the host; only
  its stability matters. Xcode version doesn't trigger ITMS-90111 — only the host-OS build.
- Vault paths: signing in `<signing-dir>/`, ASC key id/issuer in
  `~/.config/buildvm/config.env` (`ASC_KEY_ID`, `ASC_ISSUER_ID`).
