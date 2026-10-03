# buildvm — agent guide

You are an agent that needs to ship an iOS, tvOS, visionOS or Mac App Store build while the host
Mac runs a **beta macOS**. Do NOT `xcodebuild archive` on the host — Apple rejects beta-host binaries with
ITMS-90111 (the artifact's `BuildMachineOSBuild` carries the beta stamp). Use `buildvm`: it
archives inside a stable-macOS VM over SSH and uploads. One command per release.

## Decision rule

- Host `sw_vers -buildVersion` matches `[A-Z]5[0-9]{2,}[a-z]$` (e.g. `26A5353q`) → **beta host →
  use `buildvm`**. Otherwise plain local `xcodebuild` is fine and you don't need this.
- Uploading to TestFlight / App Store is the only thing that needs a stable host. Installing a
  Debug build on a *device* does not — that's a separate local flow.

## One-time (per machine)

```bash
buildvm status                 # if this errors about config, create ~/.config/buildvm/config.env
buildvm provision              # boots VM, copies Xcode, downloads iOS platform, installs signing
buildvm snapshot               # → buildvm-provisioned (reusable base; recover via tart clone)
```
`provision` refuses if the guest OS is itself a beta. It needs the config populated (see
`config.example.env`): ASC key, distribution p12 + password, team id.

## Ship a build

Simple app (committed .xcodeproj, public SPM deps):
```bash
buildvm build --dir <proj> --scheme <Scheme> \
  --profile <app.mobileprovision> \
  --build <N> [--marketing <V>]
```

Multi-target / xcodegen app (widget or extension, private SPM, secrets, ${VAR} in project.yml):
```bash
buildvm build --dir <proj> --scheme <Scheme> \
  --profile <app.mobileprovision> --profile <widget.mobileprovision> \  # repeat per target
  --component MetalToolchain \                                          # if it links mlx/Metal
  --deploy-key <key> \                                                 # private SPM over SSH
  --env APP_BUNDLE_ID=com.you.app --env APP_TEAM_ID=XXXXXXXXXX \       # every ${VAR} in project.yml
  --archive-flags "-skipPackagePluginValidation -skipMacroValidation -scmProvider system" \
  --build <N> [--marketing <V>]
```

macOS (Mac App Store) app:
```bash
buildvm build --dir <proj> --scheme <Scheme> --platform macos \
  --profile <app.provisionprofile> \
  --build <N> [--marketing <V>]
```
`--platform macos` archives with `generic/platform=macOS`, exports a `.pkg` signed with the
Mac Installer Distribution identity (`BUILDVM_MAC_INSTALLER_P12`, password falls back to the
dist p12 password), verifies `BuildMachineOSBuild` inside the pkg via `pkgutil --expand-full`,
and uploads with `altool -t macos`. Mac App Store apps must be sandboxed — the entitlements
come from the project's own signing config (never `--unsigned-archive`).

tvOS / visionOS app:
```bash
buildvm build --dir <proj> --scheme <Scheme> --platform tvos \
  --profile <app.mobileprovision> --build <N> [--marketing <V>]

buildvm build --dir <proj> --scheme <Scheme> --platform visionos \
  --profile <ios-app-store.mobileprovision> --build <N> [--marketing <V>]
```
Both export a plain `.ipa` like `ios` and differ only in the archive destination and the altool
platform (`appletvos` / `visionos`). Two things are not obvious:

- **visionOS has no visionOS profile.** The ASC API's `profileType` enum stops at Mac Catalyst —
  there is no `VISIONOS_*`. Sign a visionOS App Store build with the team's **`IOS_APP_STORE`**
  profile: its `Platform` array is `["iOS", "xrOS", "visionOS"]` and Xcode accepts it for
  `sdk=xros*`. tvOS does have its own `TVOS_APP_STORE` type; use it.
- **The platform support package is downloaded on demand.** A guest provisioned for iOS still
  lists tvOS/visionOS under `xcodebuild -showsdks`, then fails the archive with
  `generic/platform=tvOS … is not installed`. `buildvm` now runs `xcodebuild -downloadPlatform`
  before every archive — free once installed, but the **first** tvOS build costs ~4 GB / 2 min
  and the first visionOS build ~7.5 GB / 6 min. Budget guest disk accordingly (all four
  platforms plus Xcode need well over 40 GB).

## Faster, safer shipping (0.2)

- **`buildvm doctor`** first when anything feels off: VM, keyed ssh, guest OS stable, a *release*
  Xcode in the guest, signing identities, ASC key, guest disk, stale build lock. Non-zero exit if
  anything is wrong.
- **One run at a time.** Concurrent invocations queue behind a host lock
  (`~/.local/state/buildvm/lock`) instead of overwriting each other's archive in the guest. A dead
  owner's lock is cleared automatically.
- **Project file, one command per release.** Put a `.buildvm` in the repo and ship every platform:
  ```
  name solarbeam
  exclude marketing
  target ios --scheme solarbeam-ios --platform ios --profile app.mobileprovision --profile widget.mobileprovision
  target mac --scheme solarbeam-mac --platform macos --profile mac.provisionprofile
  ```
  `buildvm ship --build 166 --marketing 4.1.2 [--only ios,mac] [--keep-going] [--no-upload] [--down]`
  builds the targets in order under one lock and prints `ship summary: ios ✔ mac ✔`.
- **Project identity (`--name`).** The guest tree and DerivedData are keyed by the app, not the
  staging directory, so `solarbeam-4.1.2/` and `solarbeam-4.1.3/` share incremental state. Default:
  `name` in `.buildvm`, else the directory name minus a trailing version (`app-release-1.4.9` →
  `app`). DerivedData is kept per app and platform (`~/dd/<name>-<platform>`) and reused, so the
  second build of an app is incremental; `--clean` discards it.
- **Disk is managed for you.** Below `$BUILDVM_MIN_FREE_GB` (default 20) a build first prunes
  scratch (archives, exports, logs), then the least-recently-built DerivedData, then project trees
  untouched for 14 days; below `$BUILDVM_HARD_MIN_FREE_GB` (default 8) it stops with a clear
  message. Archives and exports are deleted after a successful upload (`--keep-artifacts` keeps
  them). `buildvm clean [--all] [--days N]` does it on demand.
- **Preflight fails in seconds, not after a 10-minute archive:** profile expired (warns under 14
  days) or not an App Store profile, the guest holds none of the profile's certificates, the git
  tree is behind its upstream (`--allow-stale` to override; a dirty tree only warns), the build
  number was already uploaded for this app/platform/version (`--force`), the guest's Xcode is a
  beta. `--no-preflight` skips the profile/certificate checks.
- **Failures explain themselves.** The compile/sign errors are printed and the full xcodebuild log
  is copied to `~/.local/state/buildvm/logs/<name>-<platform>-<build>-<phase>.log`.
- **altool retries** network errors, timeouts and 5xx up to `$BUILDVM_UPLOAD_ATTEMPTS` (3) times,
  never a rejected build number or a bad binary.
- **Parse the `RESULT` line.** Every build ends with one JSON line:
  `RESULT {"ok":true,"name":"solarbeam","platform":"ios","marketing":"4.1.2","build":"166","outcome":"uploaded","delivery":"<uuid>","buildMachineOSBuild":"25F71","seconds":412}`
  (`outcome` is `uploaded`, `built` with `--no-upload`, or `failed:<phase>`), followed by
  `timings:`. `buildvm history [N]` lists past runs; `buildvm status --json` is machine-readable.
- `.buildvmignore`-style excludes: `--exclude PATTERN` (repeatable) or `exclude` lines in `.buildvm`.

## Rules you must follow

1. **Pass every `${VAR}` the project.yml references as `--env`.** Miss one and xcodegen bakes an
   empty bundle id; the build fails late (App Intents "Unable to parse Info.plist") or the upload
   is wrong.
2. **Do NOT use `--unsigned-archive` for apps with entitlements** (game-center / healthkit /
   weatherkit / app-groups / applesignin). The default project-signed archive preserves them;
   `--unsigned-archive` drops them and the review submission 409s
   `BUILD_INDICATES_*_DISABLED`. Only use it for a project with no valid signing config.
3. **`--profile` once per signed target** — the app AND every embedded extension. The bundle-id
   and profile name are auto-derived from each profile's entitlements.
4. **Trust the guard, not vibes.** `buildvm` unzips the IPA and fails if `BuildMachineOSBuild`
   looks beta. If it uploaded, the artifact is stable by construction. altool's "UPLOAD
   SUCCEEDED" + Delivery UUID is authoritative; ASC surfacing lags (minutes). A failed
   upload (e.g. `ENTITY_ERROR…DUPLICATE` when the build number already exists) now hard-fails
   the run with a non-zero exit — `== done ✔` prints ONLY on a real altool success. If you
   see `altool upload FAILED`, fix the cause (usually bump `--build`) and re-run.
5. **Marketing-version trains:** altool rejects a build whose marketing version maps to a closed
   pre-release train (`Invalid Pre-Release Train … closed`). Pass `--marketing` for an open one.
6. **Debug first if unsure:** `--no-upload` builds + verifies without uploading; the artifact stays
   in the guest at `/tmp/export-<name>-<platform>/`.

## Attaching + submitting (App Store Connect API, separate from buildvm)

`buildvm` only uploads the binary. To put it in review you still: wait for the build to go
`VALID`, `PATCH /v1/appStoreVersions/{id}/relationships/build`, create a `reviewSubmission` +
`reviewSubmissionItem` (appStoreVersion), then `PATCH {submitted:true}`. Subscriptions/IAPs
already tied to the version ride along automatically.
