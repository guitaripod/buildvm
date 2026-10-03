#!/bin/bash
### Hermetic tests for the parts of buildvm that do not need the VM: everything is exercised
### by sourcing bin/buildvm. Needs only macOS tools (plutil, git, openssl). Run: test/run.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

export BUILDVM_CONFIG=/dev/null
export BUILDVM_STATE_DIR=$SANDBOX/state
export BUILDVM_TART=/usr/bin/true
export HOME=$SANDBOX/home
mkdir -p "$HOME"
# shellcheck disable=SC1091
source "$ROOT/bin/buildvm"
set +e

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && echo "      $2"; }

eq() { # label expected actual
  if [ "$2" = "$3" ]; then ok; else bad "$1" "expected [$2] got [$3]"; fi
}
yes() { # label cmd...
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then ok; else bad "$label" "expected success: $*"; fi
}
no() { # label cmd...
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then bad "$label" "expected failure: $*"; else ok; fi
}
dies() { # label expected-substring cmd...   (runs in a subshell: die exits it)
  local label=$1 want=$2 out; shift 2
  out=$( ( "$@" ) 2>&1 ); local rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q -- "$want"; then ok; else bad "$label" "rc=$rc out=[$out] wanted [$want]"; fi
}

# ---- build number classification ------------------------------------------------
yes "26A5353q is a beta OS build" is_beta_build 26A5353q
no  "25F71 is stable" is_beta_build 25F71
yes "27A266a is a beta Xcode" is_beta_xcode 27A266a
no  "17F113 is a release Xcode" is_beta_xcode 17F113

# ---- platform table ---------------------------------------------------------------
eq "ios traits" $'generic/platform=iOS\tipa\tmobileprovision\tios\tiOS' "$(platform_traits ios)"
eq "tvos traits" $'generic/platform=tvOS\tipa\tmobileprovision\tappletvos\ttvOS' "$(platform_traits tvos)"
eq "visionos traits" $'generic/platform=visionOS\tipa\tmobileprovision\tvisionos\tvisionOS' "$(platform_traits visionos)"
eq "macos traits" $'generic/platform=macOS\tpkg\tprovisionprofile\tmacos\t' "$(platform_traits macos)"
no  "unknown platform" platform_traits watchos

# ---- project identity -----------------------------------------------------------------
eq "plain name" solarbeam "$(derive_name /tmp/solarbeam)"
eq "version suffix" solarbeam "$(derive_name /tmp/solarbeam-4.1.2)"
eq "release suffix" app-of-the-dead "$(derive_name /x/app-of-the-dead-release-1.4.9)"
eq "bare release suffix" tailscode-mac "$(derive_name /x/tailscode-mac-release)"
eq "v-prefixed version" pixiepocket "$(derive_name /x/pixiepocket-v1.6.1)"
eq "digits without a separator are part of the name" Helia2 "$(derive_name /x/Helia2)"
eq "inner digits stay" game-2-pro "$(derive_name /x/game-2-pro)"

# ---- json -------------------------------------------------------------------------
eq "json escapes quotes and backslashes" 'a\"b\\c' "$(json_str 'a"b\c')"

# ---- .buildvm ----------------------------------------------------------------------
proj=$SANDBOX/proj; mkdir -p "$proj"
cat > "$proj/.buildvm" <<'EOF'
# comment line
name  solarbeam   # trailing comment
exclude marketing
exclude screenshots
target ios --scheme solarbeam-ios --platform ios --profile app.mobileprovision --profile "widget one.mobileprovision"
target mac --scheme solarbeam-mac --platform macos --profile mac.provisionprofile
EOF
load_project_file "$proj"
eq "project name" solarbeam "$PROJECT_NAME"
eq "excludes" "marketing screenshots" "${PROJECT_EXCLUDES[*]}"
eq "target names" "ios mac" "${TARGET_NAMES[*]}"
eq "target args" "--scheme solarbeam-mac --platform macos --profile mac.provisionprofile" "${TARGET_ARGS[1]#"${TARGET_ARGS[1]%%[![:space:]]*}"}"
eval "parsed=(${TARGET_ARGS[0]})"
eq "quoted args survive" "widget one.mobileprovision" "${parsed[${#parsed[@]}-1]}"
load_project_file "$SANDBOX/nowhere"
eq "missing file is fine" "" "$PROJECT_NAME"
printf 'frobnicate yes\n' > "$proj/.buildvm"
dies "unknown directive" "unknown directive" load_project_file "$proj"
printf 'target ios\n' > "$proj/.buildvm"
dies "target needs arguments" "needs a name and arguments" load_project_file "$proj"

# ---- ledger ----------------------------------------------------------------------
RUN_START=$SECONDS; RUN_NAME=solarbeam; RUN_PLATFORM=ios; RUN_MARKETING=4.1.2; RUN_BUILD=166; RUN_SHA=abc123; RUN_DELIVERY=uuid-1
no  "empty ledger has no upload" ledger_has_upload solarbeam ios 4.1.2 166
ledger_add uploaded
RUN_BUILD=167; ledger_add failed:archive
RUN_BUILD=168; RUN_DELIVERY=""; ledger_add built
yes "uploaded build is found" ledger_has_upload solarbeam ios 4.1.2 166
no  "failed build is not an upload" ledger_has_upload solarbeam ios 4.1.2 167
no  "built-only is not an upload" ledger_has_upload solarbeam ios 4.1.2 168
no  "other marketing version" ledger_has_upload solarbeam ios 4.1.3 166
no  "other platform" ledger_has_upload solarbeam macos 4.1.2 166
eq "max uploaded build" 166 "$(ledger_max_build solarbeam ios 4.1.2)"
eq "no max for another app" "" "$(ledger_max_build other ios 4.1.2)"
eq "history has a header and the rows" 4 "$(cmd_history 10 | wc -l | tr -d ' ')"

# ---- locking ---------------------------------------------------------------------------
LOCK_OWNER=0
acquire_lock "test"
eq "lock taken" 1 "$LOCK_OWNER"
yes "lock directory exists" test -d "$LOCK_DIR"
eq "lock records the pid" "$$" "$(cat "$LOCK_DIR/pid")"
( LOCK_OWNER=0; LOCK_WAIT=0; acquire_lock other ) >/dev/null 2>&1
no  "a held lock blocks a second run" test $? -eq 0
release_lock
no  "lock released" test -d "$LOCK_DIR"
mkdir -p "$LOCK_DIR"; echo 999999 > "$LOCK_DIR/pid"
( LOCK_OWNER=0; acquire_lock stale-clearing ) >/dev/null 2>&1
yes "a dead owner's lock is cleared" test $? -eq 0
rm -rf "$LOCK_DIR"; LOCK_OWNER=0

# ---- profiles -------------------------------------------------------------------------------
future=$(date -u -v+400d +%Y-%m-%dT%H:%M:%SZ); soon=$(date -u -v+5d +%Y-%m-%dT%H:%M:%SZ); past=$(date -u -v-2d +%Y-%m-%dT%H:%M:%SZ)
profile_plist() { # expiry platform [devices]
  local devices=""; [ -n "${3:-}" ] && devices="<key>ProvisionedDevices</key><array><string>X</string></array>"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Name</key><string>Test Profile</string>
<key>ExpirationDate</key><date>$1</date>
<key>Platform</key><array><string>$2</string></array>
$devices
</dict></plist>
EOF
}
yes "valid profile passes" check_profile_plist "$(profile_plist "$future" iOS)" ios
dies "expired profile" "expired" check_profile_plist "$(profile_plist "$past" iOS)" ios
eq "profile near expiry warns" 1 "$(check_profile_plist "$(profile_plist "$soon" iOS)" ios 2>&1 | grep -c 'expires in')"
dies "development profile" "development/ad-hoc" check_profile_plist "$(profile_plist "$future" iOS devices)" ios
eq "platform mismatch warns" 1 "$(check_profile_plist "$(profile_plist "$future" iOS)" tvos 2>&1 | grep -c 'does not list a tvos platform')"
eq "visionOS accepts an iOS profile" 0 "$(check_profile_plist "$(profile_plist "$future" iOS)" visionos 2>&1 | grep -c warning)"
eq "mac profile platform" 0 "$(check_profile_plist "$(profile_plist "$future" OSX)" macos 2>&1 | grep -c warning)"

# certificate matching: a throwaway self-signed cert stands in for the profile's developer cert
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$SANDBOX/k.pem" -out "$SANDBOX/c.pem" -days 2 -subj "/CN=buildvm-test" >/dev/null 2>&1
openssl x509 -in "$SANDBOX/c.pem" -outform der -out "$SANDBOX/c.der"
cert_b64=$(base64 < "$SANDBOX/c.der" | tr -d '\n')
cert_sha=$(shasum -a 1 "$SANDBOX/c.der" | cut -d' ' -f1 | tr 'a-f' 'A-F')
cert_plist=$(profile_plist "$future" iOS | sed "s#</dict></plist>#<key>DeveloperCertificates</key><array><data>$cert_b64</data></array></dict></plist>#")
eq "profile cert fingerprint" "$cert_sha" "$(profile_cert_hashes "$cert_plist")"
yes "guest holding the cert passes" check_profile_cert_plist "$cert_plist" "$cert_sha"$'\n'"0000000000000000000000000000000000000000"
dies "guest without the cert" "does not hold" check_profile_cert_plist "$cert_plist" "1111111111111111111111111111111111111111"

# ---- git preflight --------------------------------------------------------------------------
origin=$SANDBOX/origin.git; work=$SANDBOX/work; other=$SANDBOX/other
git init -q --bare "$origin"
git clone -q "$origin" "$work" 2>/dev/null
( cd "$work" && git config user.email t@t && git config user.name t && echo 1 > f && git add f && git commit -qm one && git push -q origin HEAD 2>/dev/null )
git clone -q "$origin" "$other" 2>/dev/null
( cd "$other" && git config user.email t@t && git config user.name t && echo 2 > f && git commit -qam two && git push -q origin HEAD 2>/dev/null )
dies "a tree behind its upstream is refused" "behind its upstream" git_preflight "$work" 0
yes "--allow-stale lets it through" git_preflight "$work" 1
( cd "$work" && git pull -q 2>/dev/null )
yes "an up-to-date tree passes" git_preflight "$work" 0
echo dirt > "$work/untracked"
eq "a dirty tree warns" 1 "$(git_preflight "$work" 0 2>&1 | grep -c 'uncommitted')"
git_preflight "$work" 0 2>/dev/null; case $RUN_SHA in *+dirty) ok;; *) bad "dirty tree marks the recorded sha" "$RUN_SHA";; esac
yes "a non-git directory is skipped" git_preflight "$SANDBOX" 0
eq "no sha for a non-git directory" "" "$(git_preflight "$SANDBOX" 0; echo "$RUN_SHA")"

# ---- upload retry classification ---------------------------------------------------------------
yes "timeouts retry" upload_error_is_transient "Error: The operation timed out"
yes "network drops retry" upload_error_is_transient "The network connection was lost"
yes "a 503 retries" upload_error_is_transient "HTTP status 503 from the service"
no  "a rejected build number does not retry" upload_error_is_transient "The bundle version must be higher than the previously uploaded version: '5012'."
no  "a bad binary does not retry" upload_error_is_transient "Invalid Pre-Release Train. The train version '4.1.1' is closed"

# ---- VM state ----------------------------------------------------------------------------------
cat > "$SANDBOX/tart" <<'STUB'
#!/bin/bash
case $1 in
  list) printf 'Source Name Disk Size Accessed State\nlocal  buildvm  120  93  7 seconds ago %s\nlocal  buildvm-provisioned  120  59  2 months ago  stopped\n' "$TART_STATE";;
  ip) echo 192.168.64.9;;
esac
STUB
chmod +x "$SANDBOX/tart"; TART=$SANDBOX/tart; VM=buildvm
export TART_STATE=stopped
eq "a stopped vm is stopped" stopped "$(vm_state)"
no  "a stopped vm is not running" vm_running
no  "a stopped vm has no ip even though tart still reports a lease" vm_ip
export TART_STATE=running
yes "a running vm is running" vm_running
eq "a running vm has its ip" 192.168.64.9 "$(vm_ip)"
VM=buildvm-provisioned; export TART_STATE=running
no  "another vm's state is not ours" vm_running
VM=buildvm

# ---- upload: retries and the delivery id ------------------------------------------------------
sleep() { :; }
UPLOAD_ATTEMPTS=3; ASC_KEY_ID=K; ASC_ISSUER_ID=I
UPLOAD_SCRIPT=()
### Stands in for the guest: replays UPLOAD_SCRIPT one reply per call. The call count lives in a
### file because upload_artifact runs gssh inside a command substitution (a subshell).
gssh() {
  local n reply; n=$(cat "$SANDBOX/calls" 2>/dev/null || echo 0)
  reply=${UPLOAD_SCRIPT[$n]:-}
  echo $((n + 1)) > "$SANDBOX/calls"
  case $reply in
    ok:*) printf '%s\n' "${reply#ok:}"; return 0;;
    *) printf '%s\n' "${reply#fail:}"; return 1;;
  esac
}
run_upload() { rm -f "$SANDBOX/calls" "$SANDBOX/delivery"; ( RUN_DELIVERY=""; upload_artifact "/tmp/x/*.ipa" ios 166; echo "$RUN_DELIVERY" > "$SANDBOX/delivery" ) >/dev/null 2>&1; echo $?; }
calls() { cat "$SANDBOX/calls" 2>/dev/null || echo 0; }

UPLOAD_SCRIPT=("fail:The network connection was lost" "fail:Error: The operation timed out" "ok:Delivery UUID: aaaa-bbbb")
eq "a transient failure is retried until it works" 0 "$(run_upload)"
eq "…after three calls" 3 "$(calls)"
eq "the delivery uuid is captured" "aaaa-bbbb" "$(cat "$SANDBOX/delivery")"
UPLOAD_SCRIPT=("fail:The bundle version must be higher than the previously uploaded version" "ok:Delivery UUID: never")
eq "a rejected build fails" 1 "$(run_upload)"
eq "…after a single attempt" 1 "$(calls)"
UPLOAD_SCRIPT=("fail:network down" "fail:network down" "fail:network down" "ok:Delivery UUID: late")
eq "retries are bounded" 1 "$(run_upload)"
eq "…at the configured attempts" 3 "$(calls)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
