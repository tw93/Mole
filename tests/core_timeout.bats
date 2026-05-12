#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
    export ROOMY_DEBUG=0
}

@test "run_with_timeout: command completes before timeout" {
    result=$(bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 echo 'success'
    ")
    [[ "$result" == "success" ]]
}

@test "run_with_timeout: zero timeout runs command normally" {
    result=$(bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 0 echo 'no_timeout'
    ")
    [[ "$result" == "no_timeout" ]]
}

@test "run_with_timeout: invalid timeout runs command normally" {
    result=$(bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout invalid echo 'no_timeout'
    ")
    [[ "$result" == "no_timeout" ]]
}

@test "run_with_timeout: negative timeout runs command normally" {
    result=$(bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout -5 echo 'no_timeout'
    ")
    [[ "$result" == "no_timeout" ]]
}

@test "run_with_timeout: preserves command exit code on success" {
    bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 true
    "
    exit_code=$?
    [[ $exit_code -eq 0 ]]
}

@test "run_with_timeout: preserves command exit code on failure" {
    set +e
    bash -c "
        set +e
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 false
        exit \$?
    "
    exit_code=$?
    set -e
    [[ $exit_code -eq 1 ]]
}

@test "run_with_timeout: returns 124 on timeout (if using gtimeout)" {
    if ! command -v gtimeout >/dev/null 2>&1 && ! command -v timeout >/dev/null 2>&1; then
        skip "gtimeout/timeout not available"
    fi

    set +e
    bash -c "
        set +e
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 1 sleep 3
        exit \$?
    "
    exit_code=$?
    set -e
    [[ $exit_code -eq 124 ]]
}

@test "run_with_timeout: kills long-running command" {
    start_time=$(date +%s)
    set +e
    bash -c "
        set +e
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 2 sleep 5
    " >/dev/null 2>&1
    set -e
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    [[ $duration -lt 10 ]]
}

@test "run_with_timeout: handles fast-completing commands" {
    start_time=$(date +%s)
    bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 10 echo 'fast'
    " >/dev/null 2>&1
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    [[ $duration -lt 3 ]]
}

@test "run_with_timeout: works in pipefail mode" {
    result=$(bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 echo 'pipefail_test'
    ")
    [[ "$result" == "pipefail_test" ]]
}

@test "run_with_timeout: doesn't cause unintended exits" {
    result=$(bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 true || true
        echo 'survived'
    ")
    [[ "$result" == "survived" ]]
}

@test "run_with_timeout: handles commands with arguments" {
    result=$(bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 echo 'arg1' 'arg2' 'arg3'
    ")
    [[ "$result" == "arg1 arg2 arg3" ]]
}

@test "run_with_timeout: handles commands with spaces in arguments" {
    result=$(bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 echo 'hello world'
    ")
    [[ "$result" == "hello world" ]]
}

@test "run_with_timeout: debug logging when ROOMY_DEBUG=1" {
    output=$(bash -c "
        set -euo pipefail
        export ROOMY_DEBUG=1
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 echo 'test' 2>&1
    ")
    [[ "$output" =~ TIMEOUT ]]
}

@test "run_with_timeout: no debug logging when ROOMY_DEBUG=0" {
    output=$(bash -c "
        set -euo pipefail
        export ROOMY_DEBUG=0
        unset ROOMY_TIMEOUT_INITIALIZED
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 echo 'test'
    " 2>/dev/null)
    [[ "$output" == "test" ]]
}

@test "timeout.sh: prevents multiple sourcing" {
    result=$(bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        echo 'loaded'
    ")
    [[ "$result" == "loaded" ]]
}

@test "timeout.sh: sets ROOMY_TIMEOUT_LOADED flag" {
    result=$(bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        echo \"\$ROOMY_TIMEOUT_LOADED\"
    ")
    [[ "$result" == "1" ]]
}

@test "run_with_timeout: shell fallback preserves caller INT trap" {
    result=$(bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        ROOMY_TIMEOUT_BIN=''
        ROOMY_TIMEOUT_PERL_BIN=''
        trap 'echo caller-trap' INT
        run_with_timeout 2 true
        trap -p INT
    ")
    [[ "$result" == *"caller-trap"* ]]
}
