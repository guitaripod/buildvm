# Changelog

## 0.2.0

- `buildvm ship` and a per-project `.buildvm` file: every platform of an app in one command.
- Persistent per-app, per-platform DerivedData (incremental second builds) keyed by a stable
  project name instead of the staging directory's name; `--name`, `--clean`.
- Guest disk management: automatic pruning below a free-space floor, artifacts removed after a
  successful upload, `buildvm clean`.
- Host-side build lock so concurrent runs queue instead of corrupting one another.
- Preflight: expired / non-App-Store profiles, certificates the guest does not hold, git trees
  behind their upstream, already-uploaded build numbers, a beta Xcode in the guest.
- Failures print the compile/sign errors and keep the full log under `~/.local/state/buildvm/logs`.
- altool retries transient failures; the Delivery UUID is captured.
- `buildvm doctor`, `status --json`, `history`, `--version`; a build ledger; a final
  machine-readable `RESULT {json}` line and per-phase timings.
- SSH keepalives for long archives; `--exclude`; `--down`.
- Fixed: `status` always reported one valid identity.
- Fixed: after `buildvm down` the next command never booted the VM and timed out (`tart ip` keeps
  answering with the last lease, so "has an IP" was mistaken for "is running").
- `test/run.sh`: hermetic tests for the logic that does not need the VM.

## 0.1.0

Initial release: iOS, tvOS, visionOS and macOS App Store builds from a stable-macOS Tart guest.
