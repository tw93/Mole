#!/usr/bin/env bats
# Orphaned simulator runtime detection: report a runtime no device uses,
# stay silent on in-use runtimes, and never delete anything.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
}

# $1 = `simctl runtime list -j` output, $2 = `simctl list devices -j` output
run_check() {
    run env PROJECT_ROOT="$PROJECT_ROOT" RT_OUT="$1" DEV_OUT="$2" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
_MOLE_SIMCTL_RESOLUTION_STATUS=ready
_MOLE_SIMCTL_DEVELOPER_DIR=/fake
note_activity() { :; }
run_with_timeout() {
    shift
    case "$*" in
        *"runtime list"*) printf '%s\n' "$RT_OUT" ;;
        *"list devices"*) printf '%s\n' "$DEV_OUT" ;;
    esac
}
check_orphaned_simulator_runtimes
EOF
}

NO_DEVICES='{
  "devices" : {
  }
}'

# Shape copied from a real `xcrun simctl runtime list -j`, trimmed to the keys
# the check reads.
RUNTIMES='{
  "70DF9A83-C8CF-458E-B463-356D557B8D2D" : {
    "build" : "22E238",
    "deletable" : true,
    "identifier" : "70DF9A83-C8CF-458E-B463-356D557B8D2D",
    "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-18-4",
    "sizeBytes" : 8800000000,
    "state" : "Ready",
    "version" : "18.4"
  },
  "78F2282D-7AC8-4DA3-B482-9E21FFBD5841" : {
    "build" : "23F77",
    "deletable" : true,
    "identifier" : "78F2282D-7AC8-4DA3-B482-9E21FFBD5841",
    "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
    "sizeBytes" : 8494282293,
    "state" : "Ready",
    "version" : "26.5"
  }
}'

# One device, under iOS 26.5 only.
DEVICES='{
  "devices" : {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-5" : [
      {
        "name" : "iPhone 17",
        "state" : "Shutdown",
        "udid" : "4231B95B-7658-493E-8BBD-C6A1995D2314"
      }
    ]
  }
}'

@test "reports a runtime no device uses and names the owner command" {
    run_check "$RUNTIMES" "$DEVICES"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Orphaned simulator runtime"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"iOS 18.4 (22E238)"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"8.80GB"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"xcrun simctl runtime delete 70DF9A83-C8CF-458E-B463-356D557B8D2D"* ]] || { echo "$output"; return 1; }
    # The in-use runtime must never appear.
    [[ "$output" != *"26.5"* ]] || { echo "$output"; return 1; }
}

@test "a point-release image whose devices exist is never called orphaned (#1505)" {
    # `runtime list` heads this image "iOS 26.4.1" while `list devices` groups
    # its simulators under "iOS 26.4". Joining on the printed name reported a
    # runtime with seven live devices as an orphan and told the user to delete
    # 8GB that Xcode was still using.
    local runtimes='{
  "7C5CBD52-233F-404D-B090-3394CC5D8FB3" : {
    "build" : "23E254a",
    "deletable" : true,
    "identifier" : "7C5CBD52-233F-404D-B090-3394CC5D8FB3",
    "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
    "sizeBytes" : 8485014416,
    "state" : "Ready",
    "version" : "26.4.1"
  }
}'
    local devices='{
  "devices" : {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-4" : [
      {
        "name" : "iPhone 17 Pro Max",
        "udid" : "5D5F2A78-A926-4096-810F-FA727BBEE150"
      }
    ]
  }
}'
    run_check "$runtimes" "$devices"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Orphaned"* ]] || { echo "$output"; return 1; }
}

@test "a runtime whose device group is empty is still an orphan" {
    local devices='{
  "devices" : {
    "com.apple.CoreSimulator.SimRuntime.iOS-18-4" : [

    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-26-5" : [
      {
        "udid" : "4231B95B-7658-493E-8BBD-C6A1995D2314"
      }
    ]
  }
}'
    run_check "$RUNTIMES" "$devices"
    [ "$status" -eq 0 ]
    [[ "$output" == *"iOS 18.4"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"26.5"* ]] || { echo "$output"; return 1; }
}

@test "silent when every runtime has devices" {
    local devices='{
  "devices" : {
    "com.apple.CoreSimulator.SimRuntime.iOS-18-4" : [
      { "udid" : "AAAA" }
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-26-5" : [
      { "udid" : "BBBB" }
    ]
  }
}'
    run_check "$RUNTIMES" "$devices"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "$output"; return 1; }
}

@test "reports every runtime when the machine has no simulators at all" {
    run_check "$RUNTIMES" "$NO_DEVICES"
    [ "$status" -eq 0 ]
    [[ "$output" == *"iOS 18.4"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"iOS 26.5"* ]] || { echo "$output"; return 1; }
}

@test "never recommends deleting a runtime simctl cannot delete" {
    local runtimes='{
  "70DF9A83-C8CF-458E-B463-356D557B8D2D" : {
    "build" : "22E238",
    "deletable" : false,
    "identifier" : "70DF9A83-C8CF-458E-B463-356D557B8D2D",
    "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-18-4",
    "sizeBytes" : 8800000000,
    "state" : "Ready",
    "version" : "18.4"
  }
}'
    run_check "$runtimes" "$NO_DEVICES"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "$output"; return 1; }
}

@test "never recommends a runtime that is not Ready" {
    local runtimes='{
  "70DF9A83-C8CF-458E-B463-356D557B8D2D" : {
    "build" : "22E238",
    "deletable" : true,
    "identifier" : "70DF9A83-C8CF-458E-B463-356D557B8D2D",
    "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-18-4",
    "sizeBytes" : 8800000000,
    "state" : "Unusable",
    "version" : "18.4"
  }
}'
    run_check "$runtimes" "$NO_DEVICES"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "$output"; return 1; }
}

@test "two images sharing one runtime identifier are both left alone" {
    # The device list keys on the identifier, so it cannot say which of the
    # two images the devices are bound to. Ambiguity is not evidence.
    local runtimes='{
  "AAAAAAAA-0000-0000-0000-000000000001" : {
    "build" : "22E238",
    "deletable" : true,
    "identifier" : "AAAAAAAA-0000-0000-0000-000000000001",
    "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-18-4",
    "sizeBytes" : 8800000000,
    "state" : "Ready",
    "version" : "18.4"
  },
  "AAAAAAAA-0000-0000-0000-000000000002" : {
    "build" : "22E239",
    "deletable" : true,
    "identifier" : "AAAAAAAA-0000-0000-0000-000000000002",
    "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-18-4",
    "sizeBytes" : 8800000000,
    "state" : "Ready",
    "version" : "18.4.1"
  }
}'
    run_check "$runtimes" "$NO_DEVICES"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "$output"; return 1; }
}

@test "an unrecognized device payload reports nothing rather than guessing" {
    run_check "$RUNTIMES" 'simctl: command not found'
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "$output"; return 1; }
}

# $1 = exit status every simctl probe returns
run_check_with_probe_status() {
    run env PROJECT_ROOT="$PROJECT_ROOT" PROBE_STATUS="$1" /bin/bash --noprofile --norc <<'EOF'
set -uo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
_MOLE_SIMCTL_RESOLUTION_STATUS=ready
_MOLE_SIMCTL_DEVELOPER_DIR=/fake
note_activity() { :; }
debug_log() { echo "DEBUG:$*"; }
run_with_timeout() { return "$PROBE_STATUS"; }
check_orphaned_simulator_runtimes
EOF
}

@test "a probe timeout skips the review instead of cancelling the run" {
    # The review only prints a hint. A cold CoreSimulatorService that
    # outlives the probe budget must not end `mo clean` with exit 124 and
    # skip every later section.
    run_check_with_probe_status 124
    [ "$status" -eq 0 ] || { echo "status=$status $output"; return 1; }
    [[ "$output" == *"DEBUG:Orphaned runtime review skipped"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"Orphaned simulator runtime"* ]] || { echo "$output"; return 1; }
}

@test "an interrupted probe still propagates the signal status" {
    run_check_with_probe_status 130
    [ "$status" -eq 130 ] || { echo "status=$status $output"; return 1; }
    [ -z "$output" ] || { echo "$output"; return 1; }
}

@test "no-op when simctl was never resolved" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
_MOLE_SIMCTL_RESOLUTION_STATUS=unresolved
note_activity() { :; }
run_with_timeout() { echo "UNEXPECTED_PROBE"; }
check_orphaned_simulator_runtimes
EOF
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "$output"; return 1; }
}

@test "the check never deletes anything" {
    run env PROJECT_ROOT="$PROJECT_ROOT" RT_OUT="$RUNTIMES" DEV_OUT="$NO_DEVICES" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
_MOLE_SIMCTL_RESOLUTION_STATUS=ready
_MOLE_SIMCTL_DEVELOPER_DIR=/fake
note_activity() { :; }
run_with_timeout() {
    shift
    case "$*" in
        *"runtime list"*) printf '%s\n' "$RT_OUT" ;;
        *"list devices"*) printf '%s\n' "$DEV_OUT" ;;
    esac
}
safe_clean() { echo "UNEXPECTED_DELETE $*"; }
mole_delete() { echo "UNEXPECTED_DELETE $*"; }
safe_remove() { echo "UNEXPECTED_DELETE $*"; }
check_orphaned_simulator_runtimes
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"Orphaned"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"UNEXPECTED_DELETE"* ]] || { echo "$output"; return 1; }
}
