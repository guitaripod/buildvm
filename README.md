# buildvm

Ship iOS App Store builds from a **stable-macOS VM**, headless over SSH, while your Mac runs a
**beta macOS** — one command, zero CI minutes. Agent-native: every step is non-interactive,
self-verifying, and fails closed.

## The problem it solves

When the build host runs a beta macOS, every App Store binary archived on it carries a beta
`BuildMachineOSBuild` in `Info.plist`, and Apple rejects it after upload with **ITMS-90111**
("must use the latest Xcode and SDK Release Candidates"). The message is misleading — your
Xcode and SDK can be fully release and it still bounces. The real trigger is the host-OS build
number.

The usual workaround is a stable-macOS GitHub Actions runner, but macOS runners bill minutes at
a **10× multiplier**, so a busy release month burns the free tier fast.

`buildvm` runs the archive inside a stable-macOS [Tart](https://tart.run) guest on your own
machine. The artifact is stamped with the guest's stable build number, so ITMS-90111 is
**structurally impossible** — and it costs nothing but local CPU. It verifies this on the actual
IPA (`BuildMachineOSBuild` guard) before it will upload.

> **Scope, honestly:** this exists *because of* the beta-macOS window. When your Mac's macOS
> reaches GM, plain local `xcodebuild` is legal again and you only need this next beta season.
> It's a sharp seasonal tool, not a CI platform.

## Requirements

- Apple Silicon Mac, [Tart](https://tart.run) installed (`tart` on PATH).
- Host Xcode (copied into the guest during `provision`).
- A distribution certificate (`.p12`), the App Store provisioning profile(s) for your app, and an
  App Store Connect API key. Point `buildvm` at them via `~/.config/buildvm/config.env`
  (see `config.example.env`). **No secrets live in this repo.**

## Quickstart

```bash
git clone https://github.com/guitaripod/buildvm && cd buildvm
ln -s "$PWD/bin/buildvm" ~/.local/bin/buildvm     # or add bin/ to PATH
cp config.example.env ~/.config/buildvm/config.env && $EDITOR ~/.config/buildvm/config.env

tart clone ghcr.io/cirruslabs/macos-tahoe-base:latest buildvm
tart set buildvm --cpu 8 --memory 24576 --disk-size 120
buildvm provision        # Xcode + iOS platform + signing identity, all over SSH
buildvm snapshot         # reusable base

buildvm build --dir ~/code/MyApp --scheme MyApp \
  --profile MyApp_AppStore.mobileprovision --build 42 --marketing 1.2.0
```

## Commands

| command | what it does |
|---|---|
| `buildvm status` | VM state, guest OS build, Xcode version, valid-identity count |
| `buildvm provision` | one-time: SSH key, copy Xcode, download iOS platform + xcodegen, import signing + Apple WWDR chain + ASC key |
| `buildvm snapshot [name]` | stop + clone the provisioned VM as a reusable base |
| `buildvm build …` | rsync project → archive → export → verify stable → upload |
| `buildvm up / down / ip / ssh [cmd]` | VM lifecycle / shell into the guest |

See **[AGENTS.md](AGENTS.md)** for the agent-facing playbook and **[docs/build-vm.md](docs/build-vm.md)**
for the full runbook, multi-target apps, and the non-obvious gotchas.

## How it works

1. Boots a stable-macOS Tart guest; refuses if the guest OS is itself beta.
2. rsyncs the project in; optionally installs a private-SPM deploy key, runs a prebuild hook,
   ensures Xcode components (e.g. Metal), and exports `--env` vars for xcodegen substitution.
3. Archives with the **project's own per-target signing** (preserves entitlements; no leak onto
   SPM package targets), then `-exportArchive` produces the signed IPA.
4. Unzips the IPA and **fails hard if `BuildMachineOSBuild` looks beta** — the whole point.
5. `xcrun altool --upload-app`.

Public source, no license — use at your own risk. PRs welcome; it improves as it meets more app
shapes.
