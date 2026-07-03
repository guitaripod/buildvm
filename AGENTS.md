# buildvm — agent guide

You are an agent that needs to ship an iOS App Store build while the host Mac runs a **beta
macOS**. Do NOT `xcodebuild archive` on the host — Apple rejects beta-host binaries with
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
   SUCCEEDED" + Delivery UUID is authoritative; ASC surfacing lags (minutes).
5. **Marketing-version trains:** altool rejects a build whose marketing version maps to a closed
   pre-release train (`Invalid Pre-Release Train … closed`). Pass `--marketing` for an open one.
6. **Debug first if unsure:** `--no-upload` builds + verifies without uploading; the IPA stays in
   the guest at `/tmp/export-<name>/`.

## Attaching + submitting (App Store Connect API, separate from buildvm)

`buildvm` only uploads the binary. To put it in review you still: wait for the build to go
`VALID`, `PATCH /v1/appStoreVersions/{id}/relationships/build`, create a `reviewSubmission` +
`reviewSubmissionItem` (appStoreVersion), then `PATCH {submitted:true}`. Subscriptions/IAPs
already tied to the version ride along automatically.
