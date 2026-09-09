#!/usr/bin/env bats

setup_file() {
	PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export PROJECT_ROOT

	TEST_HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-optimize-probes.XXXXXX")"
	export TEST_HOME
}

teardown_file() {
	if [[ "$TEST_HOME" == "${BATS_TEST_DIRNAME}/tmp-optimize-probes."* ]]; then
		rm -rf "$TEST_HOME"
	fi
}

@test "system maintenance reports a failed Spotlight probe" {
	run env HOME="$TEST_HOME/system" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
unset MOLE_TEST_NO_AUTH MOLE_TEST_MODE
flush_dns_cache() { return 0; }
mkdir -p "$HOME/bin"
printf '#!/bin/bash\nexit 7\n' > "$HOME/bin/mdutil"
chmod +x "$HOME/bin/mdutil"
PATH="$HOME/bin:$PATH"

execute_optimization system_maintenance
[[ "$(optimize_outcome_count failed)" == "1" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Failed to verify Spotlight index"* ]] || return 1
}

@test "Spotlight optimization reports a failed status probe" {
	run env HOME="$TEST_HOME/spotlight" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
run_with_timeout() { return 124; }

execute_optimization spotlight_index_optimize
[[ "$(optimize_outcome_count failed)" == "1" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Failed to inspect Spotlight index (exit=124)"* ]] || return 1
}

@test "quarantine cleanup reports a failed row-count probe" {
	run env HOME="$TEST_HOME/quarantine" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
db="$HOME/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
mkdir -p "$(dirname "$db")"
touch "$db"
sqlite3() { return 0; }
should_protect_path() { return 1; }
run_with_timeout() { return 7; }

execute_optimization quarantine_cleanup
[[ "$(optimize_outcome_count failed)" == "1" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Failed to inspect quarantine database"* ]] || return 1
}

@test "login item audit reports a failed snapshot" {
	run env HOME="$TEST_HOME/login" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
unset MOLE_TEST_NO_AUTH MOLE_TEST_MODE
_login_items_snapshot() { return 7; }

execute_optimization login_items_audit
[[ "$(optimize_outcome_count failed)" == "1" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Failed to inspect login items"* ]] || return 1
}

@test "login item snapshot runs through the bounded command wrapper" {
	run env HOME="$TEST_HOME/login-snapshot-timeout" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

run_with_timeout() {
    printf 'BOUNDED:%s\n' "$2" >> "$HOME/probe.trace"
    return 124
}
osascript() {
    printf 'UNBOUNDED_OSASCRIPT\n' >> "$HOME/probe.trace"
    return 0
}

set +e
_login_items_snapshot > /dev/null
snapshot_rc=$?
set -e
printf 'RC=%s TRACE=%s\n' "$snapshot_rc" "$(tr '\n' ',' < "$HOME/probe.trace")"
[[ $snapshot_rc -eq 124 ]] || exit 1
grep -Fq 'BOUNDED:osascript' "$HOME/probe.trace" || exit 1
! grep -Fq 'UNBOUNDED_OSASCRIPT' "$HOME/probe.trace" || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"RC=124"* ]] || return 1
	[[ "$output" == *"BOUNDED:osascript"* ]] || return 1
	[[ "$output" != *"UNBOUNDED_OSASCRIPT"* ]] || return 1
}

@test "login item resolver preserves a bounded Spotlight timeout" {
	run env HOME="$TEST_HOME/login-resolver-timeout" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
mkdir -p "$HOME/bin"
printf '#!/bin/bash\nexit 0\n' > "$HOME/bin/find"
chmod +x "$HOME/bin/find"
PATH="$HOME/bin:$PATH"

run_with_timeout() {
    printf 'BOUNDED:%s\n' "$2" >> "$HOME/probe.trace"
    return 124
}
mdfind() {
    printf 'UNBOUNDED_MDFIND\n' >> "$HOME/probe.trace"
    return 1
}
sudo() { return 1; }

set +e
_login_item_app_exists "Definitely Missing" "" "$((SECONDS + 10))"
resolver_rc=$?
set -e
printf 'RC=%s TRACE=%s\n' "$resolver_rc" "$(tr '\n' ',' < "$HOME/probe.trace")"
[[ $resolver_rc -eq 124 ]] || exit 1
grep -Fq 'BOUNDED:mdfind' "$HOME/probe.trace" || exit 1
! grep -Fq 'UNBOUNDED_MDFIND' "$HOME/probe.trace" || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"RC=124"* ]] || return 1
	[[ "$output" == *"BOUNDED:mdfind"* ]] || return 1
	[[ "$output" != *"UNBOUNDED_MDFIND"* ]] || return 1
}

@test "login item resolver discards a partial filesystem inventory" {
	run env HOME="$TEST_HOME/login-find-timeout" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
mkdir -p "$HOME/Applications/Partial.app"

run_with_timeout() {
    printf 'BOUNDED:%s\n' "$2" >> "$HOME/probe.trace"
    case "$2" in
        mdfind) return 0 ;;
        find)
            printf '%s\0' "$HOME/Applications/Partial.app"
            return 124
            ;;
        *) printf 'UNEXPECTED:%s\n' "$2" >> "$HOME/probe.trace"; return 0 ;;
    esac
}

set +e
_login_item_app_exists "Definitely Missing" "" "$((SECONDS + 10))"
resolver_rc=$?
set -e
printf 'RC=%s TRACE=%s\n' "$resolver_rc" "$(tr '\n' ',' < "$HOME/probe.trace")"
[[ $resolver_rc -eq 124 ]] || exit 1
grep -Fq 'BOUNDED:find' "$HOME/probe.trace" || exit 1
! grep -Fq 'UNEXPECTED:' "$HOME/probe.trace" || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"RC=124"* ]] || return 1
	[[ "$output" == *"BOUNDED:find"* ]] || return 1
	[[ "$output" != *"UNEXPECTED:"* ]] || return 1
}

@test "login item metadata inventory preserves its batch timeout" {
	run env HOME="$TEST_HOME/login-plist-timeout" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
app="$HOME/Applications/Example.app"
mkdir -p "$app/Contents"
printf '<plist><dict></dict></plist>\n' > "$app/Contents/Info.plist"
printf '%s\0' "$app" > "$HOME/apps.list"

run_with_timeout() {
    printf 'BOUNDED:%s\n' "$*" >> "$HOME/probe.trace"
    return 124
}

set +e
_login_item_build_metadata_inventory \
    "$HOME/apps.list" "$HOME/metadata.list" "$((SECONDS + 10))"
metadata_rc=$?
set -e
printf 'RC=%s TRACE=%s\n' "$metadata_rc" "$(tr '\n' ',' < "$HOME/probe.trace")"
[[ $metadata_rc -eq 124 ]] || exit 1
grep -Fq 'BOUNDED:' "$HOME/probe.trace" || exit 1
grep -Fq '/bin/bash' "$HOME/probe.trace" || exit 1
grep -Fq '/usr/bin/plutil' "$HOME/probe.trace" || exit 1
[[ ! -s "$HOME/metadata.list" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"RC=124"* ]] || return 1
	[[ "$output" == *"/usr/bin/plutil"* ]] || return 1
}

@test "login item resolver rejects a disappeared shared-inventory app" {
	run env HOME="$TEST_HOME/login-stale-inventory" PROJECT_ROOT="$PROJECT_ROOT" \
		MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
mkdir -p "$HOME"
printf '%s\0%s\0%s\0%s\0%s\0' \
    "$HOME/Ghost.app" ready '' '' '' > "$HOME/apps.inventory"
run_with_timeout() { return 0; }

set +e
_login_item_app_exists Ghost '' "$((SECONDS + 10))" "$HOME/apps.inventory"
resolver_rc=$?
set -e
printf 'RC=%s\n' "$resolver_rc"
[[ $resolver_rc -eq 2 ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"RC=2"* ]] || return 1
}

@test "login item resolver keeps case-insensitive filesystem matching" {
	run env HOME="$TEST_HOME/login-case-inventory" PROJECT_ROOT="$PROJECT_ROOT" \
		MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
mkdir -p "$HOME/example.app"
printf '%s\0%s\0%s\0%s\0%s\0' \
    "$HOME/example.app" ready '' '' '' > "$HOME/apps.inventory"
run_with_timeout() { return 0; }

_login_item_app_exists Example '' "$((SECONDS + 10))" "$HOME/apps.inventory"
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "login item audit does not publish partial broken-item conclusions" {
	run env HOME="$TEST_HOME/login-partial" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
unset MOLE_TEST_NO_AUTH MOLE_TEST_MODE

_login_items_snapshot() {
    printf 'Confirmed Missing\t\nUnknown Item\t\n'
}
_login_item_app_exists() {
    case "$1" in
        "Confirmed Missing") return 1 ;;
        *) return 124 ;;
    esac
}

execute_optimization login_items_audit
printf 'FAILED=%s ATTENTION=%s\n' \
    "$(optimize_outcome_count failed)" "$(optimize_outcome_count attention)"
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Login items audit incomplete"* ]] || return 1
	[[ "$output" == *"FAILED=1 ATTENTION=0"* ]] || return 1
	[[ "$output" != *"Broken login item"* ]] || return 1
}

@test "login item audit still reports conclusively absent items" {
	run env HOME="$TEST_HOME/login-absent" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
unset MOLE_TEST_NO_AUTH MOLE_TEST_MODE

_login_items_snapshot() { printf 'Confirmed Missing\t\n'; }
_login_item_app_exists() { return 1; }

execute_optimization login_items_audit
printf 'FAILED=%s ATTENTION=%s\n' \
    "$(optimize_outcome_count failed)" "$(optimize_outcome_count attention)"
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Broken login item: Confirmed Missing"* ]] || return 1
	[[ "$output" == *"FAILED=0 ATTENTION=1"* ]] || return 1
}

@test "login item audit reuses one fallback app inventory" {
	run env HOME="$TEST_HOME/login-shared-inventory" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
unset MOLE_TEST_NO_AUTH MOLE_TEST_MODE

_login_items_snapshot() {
    printf 'Missing One\t\nMissing Two\t\nMissing Three\t\n'
}
_login_item_build_app_inventory() {
    printf 'BUILD\n' >> "$HOME/build.trace"
    : > "$1"
    return 0
}
run_with_timeout() {
    case "$2" in
        mdfind) return 0 ;;
        sudo) return 1 ;;
        *) printf 'UNEXPECTED:%s\n' "$2" >> "$HOME/build.trace"; return 1 ;;
    esac
}

execute_optimization login_items_audit
printf 'BUILDS=%s FAILED=%s ATTENTION=%s\n' \
    "$(grep -c '^BUILD$' "$HOME/build.trace")" \
    "$(optimize_outcome_count failed)" "$(optimize_outcome_count attention)"
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"BUILDS=1 FAILED=0 ATTENTION=1"* ]] || return 1
	[[ "$output" == *"3 broken login item(s)"* ]] || return 1
	[[ "$output" != *"UNEXPECTED:"* ]] || return 1
}

@test "notification cleanup reports a failed size probe" {
	run env HOME="$TEST_HOME/notification" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
getconf() { echo "$HOME/runtime"; }
db="$HOME/runtime/com.apple.notificationcenter/db2/db"
mkdir -p "$(dirname "$db")"
touch "$db"
opt_existing_file_size_kb_strict() { return 124; }

execute_optimization notification_cleanup
[[ "$(optimize_outcome_count failed)" == "1" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Failed to inspect Notification Center database size"* ]] || return 1
}

@test "CoreDuet cleanup reports a failed size probe" {
	run env HOME="$TEST_HOME/coreduet-size" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
db="$HOME/Library/Application Support/Knowledge/knowledgeC.db"
mkdir -p "$(dirname "$db")"
touch "$db"
run_with_timeout() { return 124; }

execute_optimization coreduet_cleanup
[[ "$(optimize_outcome_count failed)" == "1" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Failed to inspect Knowledge database size"* ]] || return 1
}

@test "sudo-dependent maintenance is skipped when admin access is denied" {
	run env HOME="$TEST_HOME/admin" PROJECT_ROOT="$PROJECT_ROOT" MOLE_OPTIMIZE_SUDO_AVAILABLE=false /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
mdutil() { echo "UNEXPECTED_MDUTIL"; return 0; }

execute_optimization system_maintenance
execute_optimization network_optimization
[[ "$(optimize_outcome_count skipped)" == "2" ]] || exit 1
[[ "$(optimize_outcome_count failed)" == "0" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"admin access required"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_MDUTIL"* ]] || return 1
}

@test "Spotlight optimization reports failed speed probes" {
	run env HOME="$TEST_HOME/spotlight-speed" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
run_with_timeout() {
    if [[ "$2" == "mdutil" ]]; then
        echo "Indexing enabled."
        return 0
    fi
    return 7
}
is_ac_power() { return 0; }
time_file="$HOME/probe-time"
echo 0 > "$time_file"
get_epoch_seconds() {
    local call
    call=$(cat "$time_file")
    call=$((call + 1))
    echo "$call" > "$time_file"
    if ((call % 2 == 1)); then
        echo 100
    else
        echo 110
    fi
}
sleep() { return 0; }

execute_optimization spotlight_index_optimize
[[ "$(optimize_outcome_count failed)" == "1" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Spotlight speed check failed (2 probe(s))"* ]] || return 1
}

@test "saved state cleanup reports a failed discovery scan" {
	run env HOME="$TEST_HOME/saved-scan" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
mkdir -p "$HOME/Library/Saved Application State" "$HOME/bin"
printf '#!/bin/bash\nexit 7\n' > "$HOME/bin/find"
chmod +x "$HOME/bin/find"
PATH="$HOME/bin:$PATH"

execute_optimization saved_state_cleanup
[[ "$(optimize_outcome_count failed)" == "1" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Failed to scan old saved states"* ]] || return 1
	[[ "$output" != *"App saved states optimized"* ]] || return 1
	[[ "$output" != *"Failed to remove"* ]] || return 1
}

@test "shared file list repair reports a failed discovery scan" {
	run env HOME="$TEST_HOME/shared-scan" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
mkdir -p "$HOME/Library/Application Support/com.apple.sharedfilelist" "$HOME/bin"
printf '#!/bin/bash\nexit 7\n' > "$HOME/bin/find"
chmod +x "$HOME/bin/find"
PATH="$HOME/bin:$PATH"

execute_optimization shared_file_list_repair
[[ "$(optimize_outcome_count failed)" == "1" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Failed to scan shared file lists"* ]] || return 1
	[[ "$output" != *"Failed to repair"* ]] || return 1
}

@test "optimize external probes use bounded execution" {
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
tasks_file="$PROJECT_ROOT/lib/optimize/tasks.sh"

system_body=$(sed -n '/^opt_system_maintenance() {/,/^}/p' "$tasks_file")
saved_body=$(sed -n '/^opt_saved_state_cleanup() {/,/^}/p' "$tasks_file")
network_body=$(sed -n '/^opt_network_stack_optimize() {/,/^}/p' "$tasks_file")
vpn_body=$(sed -n '/^has_active_vpn_interface() {/,/^}/p' "$tasks_file")
shared_body=$(sed -n '/^opt_shared_file_list_repair() {/,/^}/p' "$tasks_file")
login_snapshot_body=$(sed -n '/^_login_items_snapshot() {/,/^}/p' "$tasks_file")
login_resolver_body=$(sed -n '/^_login_item_app_exists() {/,/^}/p' "$tasks_file")
login_metadata_body=$(sed -n '/^_login_item_build_metadata_inventory() {/,/^}/p' "$tasks_file")
login_inventory_body=$(sed -n '/^_login_item_build_app_inventory() {/,/^}/p' "$tasks_file")

[[ "$system_body" == *'run_with_timeout "$MOLE_TIMEOUT_SHORT_QUERY_SEC" mdutil -s /'* ]] || exit 1
[[ "$saved_body" == *'run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" find'* ]] || exit 1
[[ "$network_body" == *'run_with_timeout "$MOLE_TIMEOUT_SHORT_QUERY_SEC" route -n get default'* ]] || exit 1
[[ "$network_body" == *'run_with_timeout "$MOLE_TIMEOUT_SHORT_QUERY_SEC" dscacheutil -q host'* ]] || exit 1
[[ "$vpn_body" == *'run_with_timeout "$MOLE_TIMEOUT_SHORT_QUERY_SEC" scutil --nc list'* ]] || exit 1
[[ "$vpn_body" == *'run_with_timeout "$MOLE_TIMEOUT_SHORT_QUERY_SEC" route -n get default'* ]] || exit 1
[[ "$shared_body" == *'run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" find'* ]] || exit 1
[[ "$login_snapshot_body" == *'run_with_timeout'*"osascript"* ]] || exit 1
[[ "$login_resolver_body" == *'run_with_timeout'*"mdfind"* ]] || exit 1
[[ "$login_resolver_body" == *'run_with_timeout'*"sfltool"* ]] || exit 1
[[ "$login_metadata_body" == *'run_with_timeout'*"/usr/bin/plutil"* ]] || exit 1
[[ "$login_inventory_body" == *'run_with_timeout'*"find"* ]] || exit 1
[[ "$login_inventory_body" == *'_login_item_build_metadata_inventory'* ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "network probe timeout never authorizes maintenance" {
	run env HOME="$TEST_HOME/network-timeout" PROJECT_ROOT="$PROJECT_ROOT" MOLE_ASSUME_VPN_ACTIVE=0 MOLE_DRY_RUN=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

run_with_timeout() { return 124; }
sudo() { echo "UNEXPECTED_SUDO"; return 0; }

execute_optimization network_stack_optimize
[[ "$(optimize_outcome_count failed)" == "1" ]] || exit 1
[[ "$(optimize_outcome_count applied)" == "0" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Network health check timed out"* ]] || return 1
	[[ "$output" != *"Network routing table refreshed"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_SUDO"* ]] || return 1
}

@test "network probes preserve the caller errexit mode" {
	run env HOME="$TEST_HOME/vpn-errexit" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

run_with_timeout() { return 124; }
sudo() { echo "UNEXPECTED_SUDO"; return 0; }
set +e
execute_optimization network_stack_optimize
false
echo "survived:$(optimize_outcome_count failed)"
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Failed to inspect active VPN state"* ]] || return 1
	[[ "$output" == *"survived:1"* ]] || return 1
	[[ "$output" != *"Network routing table refreshed"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_SUDO"* ]] || return 1
}

@test "optimize tasks never toggle the caller errexit option" {
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
tasks_file="$PROJECT_ROOT/lib/optimize/tasks.sh"
if grep -nE '^[[:space:]]*set [+-]e([[:space:]]|$)' "$tasks_file"; then
    exit 1
fi
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}
