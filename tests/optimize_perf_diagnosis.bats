#!/usr/bin/env bats

load helpers/common

# Memory pressure, idle-VM, and runaway-process diagnosis.
# All three are read-only and must stay silent on a healthy machine.

setup_file() {
    mole_test_setup_project_root
}

# ---------- memory pressure ----------

@test "memory pressure stays silent when swap is healthy" {
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        sysctl() { echo 'total = 8192.00M  used = 100.00M  free = 8092.00M'; }
        SYSCTL_CMD=sysctl
        memory_pressure() { echo 'System-wide memory free percentage: 80%'; }
        out=\$(opt_diag_memory_pressure)
        [ -z \"\$out\" ] && echo SILENT || echo \"LEAKED: \$out\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"SILENT"* ]] || { echo "$output"; return 1; }
}

@test "memory pressure fires on exhausted swap and names the holders" {
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        sysctl() { echo 'total = 16384.00M  used = 15500.00M  free = 884.00M'; }
        SYSCTL_CMD=sysctl
        memory_pressure() { echo 'System-wide memory free percentage: 8%'; }
        ps() { printf '%s\n' '   RSS COMM' '8600000 com.apple.Virtualization.VirtualMachine' '2000000 /usr/local/bin/codex' '500 tiny'; }
        opt_diag_memory_pressure
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"Memory pressure"* ]] || return 1
    [[ "$output" == *"94%"* ]] || { echo "$output"; return 1; }
    # The largest process must appear — a header-vs-sort bug once dropped it.
    [[ "$output" == *"VirtualMachine"* ]] || { echo "$output"; return 1; }
    # Decimal GB from bytes_to_human, the formatter the rest of Mole uses.
    [[ "$output" == *"8.81GB"* ]] || { echo "$output"; return 1; }
    # Basename only, and sub-1GB noise excluded.
    [[ "$output" != *"/usr/local/bin/codex"* ]] || return 1
    [[ "$output" != *"tiny"* ]] || return 1
    # The ps header must never render as a process.
    [[ "$output" != *"COMM"* ]] || { echo "$output"; return 1; }
}

# ---------- idle VM ----------

@test "idle VM reports reclaimable memory when no containers run" {
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        ps() { printf '%s\n' '   RSS COMMAND' '8600000 /System/Library/Frameworks/Virtualization.framework/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine'; }
        docker() { :; }
        mole_docker_endpoint_is_local() { return 0; }
        run_with_timeout() { shift; printf ''; }
        opt_diag_idle_vm
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"8.81GB"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"no running containers"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"likely Docker Desktop"* ]] || { echo "$output"; return 1; }
}

@test "idle VM does NOT claim reclaimable when containers are running" {
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        ps() { printf '%s\n' '   RSS COMMAND' '8600000 Virtualization.framework/x/com.apple.Virtualization.VirtualMachine'; }
        docker() { :; }
        mole_docker_endpoint_is_local() { return 0; }
        run_with_timeout() { shift; printf '%s\n' abc123 def456; }
        opt_diag_idle_vm
    "
    [ "$status" -eq 0 ]
    [[ "$output" != *"no running containers"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"2 containers running"* ]] || { echo "$output"; return 1; }
}

@test "idle VM keeps Docker timeout neutral" {
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        ps() { printf '%s\n' '   RSS COMMAND' '8600000 Virtualization.framework/x/com.apple.Virtualization.VirtualMachine'; }
        docker() { :; }
        mole_docker_endpoint_is_local() { return 0; }
        run_with_timeout() { return 124; }
        opt_diag_idle_vm
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"Virtual machine using 8.81GB"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"no running containers"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"likely Docker Desktop"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"quitting it reclaims"* ]] || { echo "$output"; return 1; }
}

@test "idle VM ignores partial output from a failed Docker probe" {
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        ps() { printf '%s\n' '   RSS COMMAND' '8600000 Virtualization.framework/x/com.apple.Virtualization.VirtualMachine'; }
        docker() { :; }
        mole_docker_endpoint_is_local() { return 0; }
        run_with_timeout() { printf '%s\n' partial-id; return 1; }
        opt_diag_idle_vm
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"Virtual machine using 8.81GB"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"containers running"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"no running containers"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"quitting it reclaims"* ]] || { echo "$output"; return 1; }
}

@test "idle VM never asks a remote Docker engine about containers (#1922)" {
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        ps() { printf '%s\n' '   RSS COMMAND' '8600000 Virtualization.framework/x/com.apple.Virtualization.VirtualMachine'; }
        docker() { :; }
        run_with_timeout() {
            shift
            if [[ \"\$1 \$2\" == 'docker context' ]]; then echo 'tcp://10.0.0.5:2376'; return 0; fi
            echo 'abc123'
            return 0
        }
        opt_diag_idle_vm
    "
    [ "$status" -eq 0 ]
    [[ "$output" != *"containers running"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"Virtual machine using 8.81GB"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"no running containers"* ]] || { echo "$output"; return 1; }
}

@test "idle VM silent when no VM is present" {
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        ps() { printf '%s\n' '   RSS COMMAND' '100 Finder'; }
        out=\$(opt_diag_idle_vm)
        [ -z \"\$out\" ] && echo SILENT || echo \"LEAKED: \$out\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"SILENT"* ]] || { echo "$output"; return 1; }
}

# ---------- runaway process ----------

@test "runaway fires on a long-lived process pinning a core" {
    # ControlCenter's real shape: 138h CPU across 16 days of uptime.
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        ps() { printf '%s\n' 'PID TIME ELAPSED COMM' '785 138:00:00 16-08:00:00 /System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter'; }
        opt_diag_runaway_process
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"ControlCenter"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"138h"* ]] || return 1
    [[ "$output" == *"kill -TERM 785"* ]] || return 1
}

@test "runaway ignores a brief spike and short-lived processes" {
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        # 100% of a core but only 5 minutes old -> below the 12h floor.
        ps() { printf '%s\n' 'PID TIME ELAPSED COMM' '999 05:00 05:00 somebuild'; }
        opt_diag_runaway_process || echo NO_FINDING
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"NO_FINDING"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"somebuild"* ]] || return 1
}

@test "runaway ignores kernel_task, which legitimately accumulates CPU" {
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        ps() { printf '%s\n' 'PID TIME ELAPSED COMM' '0 200:00:00 16-08:00:00 kernel_task'; }
        opt_diag_runaway_process || echo NO_FINDING
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"NO_FINDING"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"kernel_task"* ]] || return 1
}

@test "runaway ignores a long-lived but mostly idle process" {
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        # 1h CPU over 16 days = ~0%, the shape of a healthy daemon.
        ps() { printf '%s\n' 'PID TIME ELAPSED COMM' '500 01:00:00 16-08:00:00 quietd'; }
        opt_diag_runaway_process || echo NO_FINDING
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"NO_FINDING"* ]] || { echo "$output"; return 1; }
}

@test "removed tuning environment variables are not read again" {
    # These overrides were undocumented and untested, so their defaults are
    # now fixed in code (weekly audit 2026-10-16). Match the expansion form,
    # skip comment lines, and prove the matcher fires on a known positive.
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
names='MOLE_SKIP_TRASH_CLEANUP|MOLE_SUPPORT_CACHE_AGE_DAYS|MOLE_CLAUDE_VM_ORPHAN_AGE_DAYS|MOLE_MENU_SORT_DEFAULT'
names+='|MOLE_OPTIMIZE_(SWAP_PCT|FREE_PCT|IDLE_VM_GB|RUNAWAY_PCT|RUNAWAY_MIN_HOURS|DIAG_CPU_THRESHOLD|DIAG_SAMPLE_DELAY)'
# Weekly audit 2026-10-22: seven more overrides nothing documented or tested.
names+='|MOLE_APP_SUPPORT_ITEM_SIZE_TIMEOUT_SEC|MOLE_EXTERNAL_VOLUME_SCAN_TIMEOUT|MOLE_LARGE_CANDIDATE_SIZE_TIMEOUT'
names+='|MOLE_HOMEBREW_UPDATE_TIMEOUT|MOLE_HOMEBREW_UPGRADE_TIMEOUT|MOLE_PKG_RECEIPT_CACHE_TTL|MOLE_OPERATIONS_LOG'
pattern="[$][{]?($names)([^A-Za-z0-9_]|$)"
probe='    local x="${MOLE_SUPPORT_CACHE_AGE_DAYS:-30}"'
printf '%s\n' "$probe" | grep -qE "$pattern" || { echo "matcher missed a known positive"; exit 1; }
matched=$(grep -rnE "$pattern" "$PROJECT_ROOT/lib" "$PROJECT_ROOT/bin" "$PROJECT_ROOT/mole" |
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
if [[ -n "$matched" ]]; then
    echo "a removed tuning variable is read again: $matched"
    exit 1
fi
EOF

    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "the size column stays aligned when a long name is truncated" {
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        sysctl() { echo 'total = 16384.00M  used = 15500.00M  free = 884.00M'; }
        SYSCTL_CMD=sysctl
        memory_pressure() { echo 'System-wide memory free percentage: 8%'; }
        ps() { printf '%s\n' '   RSS COMM' '8600000 com.apple.Virtualization.VirtualMachine' '2000000 codex'; }
        opt_diag_memory_pressure | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^    [^ ]' |
            while IFS= read -r row; do
                LC_ALL=C printf '%s' \"\${row%%GB*}\" | LC_ALL=C wc -c
            done
    "
    [ "$status" -eq 0 ]
    # Everything before the size is ASCII except the ellipsis on the truncated
    # row, which is three bytes wide and one column wide. Padding that string
    # with printf "%-28s" counted the bytes and pulled its size field two
    # columns left of every other row.
    local truncated_bytes="${lines[0]// /}"
    local plain_bytes="${lines[1]// /}"
    [ "$truncated_bytes" -eq $((plain_bytes + 2)) ] || {
        echo "truncated=$truncated_bytes plain=$plain_bytes"
        return 1
    }
}

@test "a small swap file reports real sizes, not 0GB" {
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        sysctl() { echo 'total = 1024.00M  used = 900.00M  free = 124.00M'; }
        SYSCTL_CMD=sysctl
        memory_pressure() { echo 'System-wide memory free percentage: 8%'; }
        ps() { printf '%s\n' '   RSS COMM' '100 tiny'; }
        opt_diag_memory_pressure
    "
    [ "$status" -eq 0 ]
    [[ "$output" != *"0GB of"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"943.7MB of 1.07GB"* ]] || { echo "$output"; return 1; }
}

@test "the runaway scan does not fork per process row" {
    # It read two timestamps and four fields per row through the shell, six
    # forks for each of 400 rows, and every optimize run paid ~5s for it even
    # when nothing was wrong.
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        ps() {
            local i=0
            echo 'PID TIME ELAPSED COMM'
            while [ \$i -lt 400 ]; do
                echo \"\$i 00:10 16-08:00:00 quietd\$i\"
                i=\$((i + 1))
            done
        }
        start=\$(date +%s)
        opt_diag_runaway_process || true
        echo \"ELAPSED=\$((\$(date +%s) - start))\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"ELAPSED=0"* || "$output" == *"ELAPSED=1"* ]] || { echo "$output"; return 1; }
}
