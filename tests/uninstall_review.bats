#!/usr/bin/env bats

load helpers/common

setup_file() { mole_test_setup_home uninstall-review; }
teardown_file() { mole_test_teardown_home; }

run_review_fixture() {
    run env HOME="$HOME/$1" PROJECT_ROOT="$PROJECT_ROOT" REVIEW_CHOICE="$1" /bin/bash --noprofile --norc <<'SH'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_paginated.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
cache="$HOME/Library/Caches/com.example.app"
data="$HOME/Library/Application Support/Example"
app="$HOME/Applications/Example.app"
mkdir -p "$cache" "$data" "$app"
encoded=$(printf '%s\n' "$cache" "$data" | base64 | tr -d '\n')
app_details=("Example|$app|com.example.app|12|$encoded||true|false|false|||||none||||")
running_apps=() sudo_apps=() brew_cask_apps=() leftover_notes=()
total_estimated_size=12
get_path_size_kb() { printf '10\n'; }
calculate_total_size() { if [[ -n "$1" ]]; then printf '1\n'; else printf '0\n'; fi; }
drain_pending_input() { :; }
paginated_multi_select() {
    [[ "$*" == *"Application Support/Example"* ]] || return 9
    [[ "${MOLE_PRESELECTED_INDICES:-}" == "" ]] || return 9
    MOLE_SELECTION_RESULT=""
    [[ "$REVIEW_CHOICE" != selected ]] || MOLE_SELECTION_RESULT=0
    return 0
}
if [[ "$REVIEW_CHOICE" == default ]]; then input=$'\n'; else input=$'d\n'; fi
MOLE_DRY_RUN=1 MOLE_TEST_MODE=1 _batch_preview_and_confirm <<< "$input"
IFS='|' read -r _ _ _ _ result _ <<< "${app_details[0]}"
files=$(decode_file_list "$result" Example)
[[ "$files" == *"$cache"* ]] || exit 1
if [[ "$REVIEW_CHOICE" == selected ]]; then
    [[ "$files" == *"$data"* ]] || exit 1
else
    [[ "$files" != *"$data"* ]] || exit 1
fi
[[ -d "$cache" && -d "$data" && -d "$app" ]] || exit 1
SH
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "uninstall preview keeps personal data by default without losing cache targets" { run_review_fixture default; }
@test "uninstall preview includes only explicitly selected personal data" { run_review_fixture selected; }
@test "uninstall personal-data selection can remain empty" { run_review_fixture empty; }

@test "configuration hints match removed paths and expose no configuration contents" {
    run env HOME="$HOME/config-references" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'SH'
set -euo pipefail
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
mkdir -p "$HOME/.cursor" "$HOME/.config/paseo" "$HOME/.config/fish"
app="$HOME/Applications/Example.app"
removed="$HOME/.config/removed-tool"
# shellcheck disable=SC2016  # Literal forms stored by third-party installers.
printf '%s\n' 'alias example=Example' 'TOKEN=private-value' \
    "TOKEN=private-value command=\"$app/Contents/MacOS/example\"" \
    "command=\"${app}Helper/run\"" \
    'hook="$HOME/.config/removed-tool/run"' \
    'hook="${HOME}/.config/removed-tool/run"' \
    'hook="~/.config/removed-tool/run"' > "$HOME/.zshrc"
printf '{"command":"%s/Contents/MacOS/example"}\n' "$app" > "$HOME/.cursor/mcp.json"
printf '%s\n' "set -gx EXAMPLE_BIN \"$app/Contents/MacOS/example\"" > "$HOME/.config/fish/config.fish"
cp "$HOME/.zshrc" "$HOME/config-before"
uninstall_configuration_references "$app" "$removed" "$HOME/.config/paseo"
cmp "$HOME/.zshrc" "$HOME/config-before" || exit 1
SH
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"~/.zshrc:3"* && "$output" == *"~/.zshrc:5"* && "$output" == *"~/.zshrc:6"* && "$output" == *"~/.zshrc:7"* ]] || return 1
    [[ "$output" == *"~/.cursor/mcp.json:1"* ]] || return 1
    [[ "$output" == *"~/.config/fish/config.fish:1"* ]] || return 1
    [[ "$output" != *"private-value"* && "$output" != *"~/.zshrc:4"* && "$output" != *"~/.zshrc:1"* ]] || return 1
}

@test "configuration hints keep live owners and skip links binary and oversized files" {
    run env HOME="$HOME/config-protection" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'SH'
set -euo pipefail
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
mkdir -p "$HOME/Applications/Live.app" "$HOME/outside" "$HOME/.cursor"
app="$HOME/Applications/Gone.app"
printf '%s\n' "$app/run" > "$HOME/outside/settings"
ln -s "$HOME/outside/settings" "$HOME/.zshrc"
printf '%s\0' "$app/run" > "$HOME/.bashrc"
/usr/bin/perl -e 'print "x" x 1048577' > "$HOME/.profile"
printf '%s\n' "$app/run" >> "$HOME/.profile"
printf '%s\n' "$HOME/Applications/Live.app/run" > "$HOME/.cursor/mcp.json"
uninstall_configuration_references "$app" "$HOME/Applications/Live.app"
SH
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"Configuration references"* ]] || return 1
}

@test "configuration hint failures discard partial output and signals propagate" {
    run env HOME="$HOME/config-timeout" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'SH'
set -euo pipefail
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
run_with_timeout() { cat > /dev/null; printf 'PARTIAL_SECRET\n'; return 124; }
uninstall_configuration_references /Applications/Gone.app
run_with_timeout() { cat > /dev/null; return 130; }
rc=0
uninstall_configuration_references /Applications/Gone.app || rc=$?
[[ $rc -eq 130 ]] || exit 1
SH
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"PARTIAL_SECRET"* ]] || return 1
}

@test "uninstall keeps unselected preferences at every post-removal side effect" {
    run env HOME="$HOME/keep-preferences" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'SH'
set -euo pipefail
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
app="$HOME/Applications/Example.app"
preferences="$HOME/Library/Preferences/com.example.app.plist"
byhost="$HOME/Library/Preferences/ByHost/com.example.app.fixture.plist"
mkdir -p "$app" "$(dirname "$byhost")"
printf 'settings\n' > "$preferences"
printf 'settings\n' > "$byhost"
brew() { return 1; }
get_brew_cask_name() { return 1; }
pgrep() { return 1; }
pkill() { return 0; }
remove_apps_from_dock() { :; }
refresh_launch_services_after_uninstall() { :; }
defaults() { printf 'DEFAULTS:%s\n' "$*" >> "$HOME/forbidden"; return 0; }
mole_delete() {
    if [[ "$1" == "$app" ]]; then
        mv "$app" "$HOME/removed-app"
    else
        printf '%s\n' "$1" >> "$HOME/forbidden"
    fi
}
selected_apps=("0|$app|Example|com.example.app|0|Never")
files_cleaned=0 total_items=0 total_size_cleaned=0
MOLE_TEST_MODE=1 batch_uninstall_applications <<< ''
[[ ! -e "$app" && -f "$preferences" && -f "$byhost" ]] || exit 1
[[ ! -e "$HOME/forbidden" ]] || { cat "$HOME/forbidden"; exit 1; }
SH
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "personal-data menu keeps empty Enter while app selection keeps its existing default" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'SH'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_paginated.sh"
enter_alt_screen() { :; }
leave_alt_screen() { :; }
stty() { :; }
tput() { :; }
clear() { :; }
printf_at() { :; }
export MOLE_MANAGED_ALT_SCREEN=1
read_key() { printf 'ENTER\n'; }
MOLE_PRESELECTED_INDICES=""
_MOLE_MENU_KEEP_EMPTY=true
paginated_multi_select "Data" alpha beta <<< '' > /dev/null || exit $?
[[ -z "$MOLE_SELECTION_RESULT" ]] || exit 1
unset _MOLE_MENU_KEEP_EMPTY
paginated_multi_select "Apps" alpha beta <<< '' > /dev/null || exit $?
[[ "$MOLE_SELECTION_RESULT" == 0 ]] || exit 1
SH
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "personal-data menu toggles every visible row with A while the app selector ignores it" {
    run env PROJECT_ROOT="$PROJECT_ROOT" KEYS="$BATS_TEST_TMPDIR/keys" /bin/bash --noprofile --norc <<'SH'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_paginated.sh"
enter_alt_screen() { :; }
leave_alt_screen() { :; }
stty() { :; }
tput() { :; }
clear() { :; }
printf_at() { :; }
export MOLE_MANAGED_ALT_SCREEN=1 COLUMNS=100
read_key() {
    local first
    first=$(head -n 1 "$KEYS")
    tail -n +2 "$KEYS" > "$KEYS.rest" && mv "$KEYS.rest" "$KEYS"
    printf '%s\n' "$first"
}
pick() {
    local title="$1"
    shift
    printf '%s\n' "$@" > "$KEYS"
    MOLE_SELECTION_RESULT=""
    paginated_multi_select "$title" alpha beta gamma <<< '' 2> "$KEYS.screen" > /dev/null || exit $?
}
MOLE_PRESELECTED_INDICES=""
_MOLE_MENU_KEEP_EMPTY=true
_MOLE_MENU_SELECT_ALL=true
pick Data CHAR:a ENTER
[[ "$MOLE_SELECTION_RESULT" == 0,1,2 ]] || exit 1
grep -q 'A All' "$KEYS.screen" || exit 1
pick Data CHAR:A CHAR:a ENTER
[[ -z "$MOLE_SELECTION_RESULT" ]] || exit 1
MOLE_PRESELECTED_INDICES=1
pick Data CHAR:a ENTER
[[ "$MOLE_SELECTION_RESULT" == 0,1,2 ]] || exit 1
MOLE_PRESELECTED_INDICES=""
# With a search applied, A covers only the rows the search shows.
pick Data CHAR:/ CHAR:m CHAR:m ENTER CHAR:a CLEAR_LINE ENTER
[[ "$MOLE_SELECTION_RESULT" == 2 ]] || exit 1
unset _MOLE_MENU_KEEP_EMPTY _MOLE_MENU_SELECT_ALL
pick Apps CHAR:a ENTER
[[ "$MOLE_SELECTION_RESULT" == 0 ]] || exit 1
if grep -q 'A All' "$KEYS.screen"; then exit 1; fi
SH
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "configuration hints only inspect absent paths from successful non-dry removals" {
    run env HOME="$HOME/config-batch" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'SH'
set -euo pipefail
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
mkdir -p "$HOME/kept" "$HOME/returned.app"
success_items=("$HOME/gone.app" "$HOME/returned.app")
encoded=$(printf '%s\n' "$HOME/kept" "$HOME/gone-data" | base64 | tr -d '\n')
failed=$(printf '%s' "$HOME/failed-data" | base64 | tr -d '\n')
app_details=("Gone|$HOME/gone.app|com.example.gone|0|$encoded|" "Failed|$HOME/failed.app|com.example.failed|0|$failed|")
uninstall_configuration_references() { printf '%s\n' "$@"; }
output=$(_batch_report_configuration_references)
[[ "$output" == *"$HOME/gone-data"* && "$output" != *"$HOME/failed"* && "$output" != *"$HOME/kept"* ]] || exit 1
output=$(MOLE_DRY_RUN=1 _batch_report_configuration_references)
[[ -z "$output" ]] || exit 1
SH
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "uninstall data review handles real terminal selection empty save and cancel" {
    run python3 "$PROJECT_ROOT/tests/uninstall_review_pty.py"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "default uninstall review never sizes kept data or remeasures its app bundle" {
    run env HOME="$HOME/single-measure" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'SH'
set -euo pipefail
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
app="$HOME/Applications/Example.app"
cache="$HOME/Library/Caches/com.example.app"
data="$HOME/Library/Application Support/Example"
mkdir -p "$app" "$cache" "$data"
_batch_refresh_selected_app_bundle_id() { printf 'com.example.app\n'; }
official_uninstaller_vendor() { return 1; }
uninstall_live_bundle_has_other_install() {
    _MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT=""
    _MOLE_UNINSTALL_LIVE_SIBLING_PATHS=()
    return 1
}
pgrep() { return 1; }
get_brew_cask_name() { return 1; }
get_file_owner() { whoami; }
find_app_files() { printf '%s\n' "$cache" "$data"; }
get_diagnostic_report_paths_for_app() { :; }
find_app_system_files() { :; }
discover_login_item_helper_bundle_ids() { :; }
has_sensitive_data() { return 1; }
get_path_size_kb() { printf '%s\n' "$1" >> "$HOME/measured"; printf '10\n'; }
drain_pending_input() { :; }
selected_apps=("0|$app|Example|com.example.app|0|Never")
running_apps=() sudo_apps=() brew_cask_apps=() blocked_apps=() manual_removal_apps=() app_details=() leftover_notes=()
total_estimated_size=0
_batch_scan_app_details
MOLE_DRY_RUN=1 MOLE_TEST_MODE=1 _batch_preview_and_confirm <<< '' > "$HOME/default.out"
grep -Fq 'Personal data kept:' "$HOME/default.out" || exit 1
if grep -Fq 'Personal data to remove:' "$HOME/default.out"; then exit 1; fi
if grep -Fq 'including personal data' "$HOME/default.out"; then exit 1; fi
[[ $(grep -Fxc "$app" "$HOME/measured") -eq 1 ]] || exit 1
if grep -Fxq "$data" "$HOME/measured"; then exit 1; fi
grep -Fxq "$cache" "$HOME/measured" || exit 1
[[ $total_estimated_size -eq 20 ]] || exit 1
# A new invocation measures again, and selected personal data joins its total.
: > "$HOME/measured"
app_details=()
total_estimated_size=0
_batch_scan_app_details
paginated_multi_select() { MOLE_SELECTION_RESULT=0; }
MOLE_DRY_RUN=1 MOLE_TEST_MODE=1 _batch_preview_and_confirm <<< $'d\n'
[[ $(grep -Fxc "$app" "$HOME/measured") -eq 1 ]] || exit 1
grep -Fxq "$data" "$HOME/measured" || exit 1
[[ $total_estimated_size -eq 30 ]] || exit 1
SH
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "selected personal data has its own preview heading and names itself in the prompt" {
    run env HOME="$HOME/heading" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'SH'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_paginated.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
cache="$HOME/Library/Caches/com.example.app"
data="$HOME/Library/Application Support/Example"
app="$HOME/Applications/Example.app"
mkdir -p "$cache" "$data" "$app"
encoded=$(printf '%s\n' "$cache" "$data" | base64 | tr -d '\n')
app_details=("Example|$app|com.example.app|12|$encoded||true|false|false|||||none||||")
running_apps=() sudo_apps=() brew_cask_apps=() leftover_notes=()
total_estimated_size=12
get_path_size_kb() { printf '10\n'; }
calculate_total_size() { if [[ -n "$1" ]]; then printf '1\n'; else printf '0\n'; fi; }
drain_pending_input() { :; }
paginated_multi_select() { MOLE_SELECTION_RESULT=0; }
MOLE_DRY_RUN=1 MOLE_TEST_MODE=1 _batch_preview_and_confirm <<< $'d\n'
SH
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    local confirmed="${output##*Files to be removed:}"
    local apps_part="${confirmed%%Personal data to remove:*}"
    local data_part="${confirmed#*Personal data to remove:}"
    # The cache stays beside the app; the chosen data moves under its heading.
    [[ "$confirmed" == *"Personal data to remove:"* ]] || { echo "$output"; return 1; }
    [[ "$apps_part" == *"Caches/com.example.app"* ]] || { echo "$output"; return 1; }
    [[ "$apps_part" != *"Application Support/Example"* ]] || { echo "$output"; return 1; }
    [[ "$data_part" == *"Application Support/Example"* ]] || { echo "$output"; return 1; }
    [[ "$confirmed" != *"Personal data kept:"* ]] || { echo "$output"; return 1; }
    [[ "$confirmed" == *"Remove 1 app, "*", including personal data"* ]] || { echo "$output"; return 1; }
}

@test "--with-data preselects every app's personal data but holds back browser profiles and App Groups" {
    run env HOME="$HOME/with-data-review" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'SH'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_paginated.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
one_data="$HOME/Library/Application Support/One"
one_group="$HOME/Library/Group Containers/group.com.example.one"
two_data="$HOME/Library/Preferences/com.example.two.plist"
# Upper case on purpose: APFS folds case, so the holdback must too.
two_profile="$HOME/Library/Application Support/GOOGLE/Chrome"
one_app="$HOME/Applications/One.app"
two_app="$HOME/Applications/Two.app"
mkdir -p "$one_data" "$one_group" "$two_profile" "$one_app" "$two_app" "$HOME/Library/Preferences"
touch "$two_data"
one=$(printf '%s\n' "$one_data" "$one_group" | base64 | tr -d '\n')
two=$(printf '%s\n' "$two_data" "$two_profile" | base64 | tr -d '\n')
app_details=(
    "One|$one_app|com.example.one|12|$one||true|false|false|||||none||||"
    "Two|$two_app|com.example.two|12|$two||true|false|false|||||none||||"
)
running_apps=() sudo_apps=() brew_cask_apps=() leftover_notes=()
total_estimated_size=24
get_path_size_kb() { printf '10\n'; }
calculate_total_size() { if [[ -n "$1" ]]; then printf '1\n'; else printf '0\n'; fi; }
drain_pending_input() { :; }
paginated_multi_select() { return 9; }
MOLE_UNINSTALL_WITH_DATA=1 MOLE_DRY_RUN=1 MOLE_TEST_MODE=1 _batch_preview_and_confirm <<< ''
IFS='|' read -r _ _ _ _ result _ <<< "${app_details[0]}"
files=$(decode_file_list "$result" One)
[[ "$files" == *"$one_data"* ]] || exit 1
[[ "$files" != *"$one_group"* ]] || exit 1
IFS='|' read -r _ _ _ _ result _ <<< "${app_details[1]}"
files=$(decode_file_list "$result" Two)
[[ "$files" == *"$two_data"* ]] || exit 1
[[ "$files" != *"$two_profile"* ]] || exit 1
[[ -d "$one_data" && -f "$two_data" && -d "$two_profile" ]] || exit 1
SH
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    local kept="${output##*Personal data kept:}"
    [[ "$kept" == *"group.com.example.one"* && "$kept" == *"GOOGLE/Chrome"* ]] || { echo "$output"; return 1; }
    [[ "$kept" != *"Application Support/One"* && "$kept" != *"com.example.two.plist"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *", including personal data"* ]] || { echo "$output"; return 1; }
}

@test "--with-data holds back CrossOver, Whisky and OpenEmu game libraries" {
    run env HOME="$HOME/with-data-games" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'SH'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_paginated.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
bottles="$HOME/Library/Application Support/CrossOver"
whisky="$HOME/Library/Containers/com.isaacmarovitz.Whisky"
roms="$HOME/Library/Application Support/OpenEmu"
prefs="$HOME/Library/Preferences/com.codeweavers.CrossOver.plist"
app="$HOME/Applications/CrossOver.app"
mkdir -p "$bottles/Bottles/Steam" "$whisky/Bottles" "$roms/Game Library" "$app" "$HOME/Library/Preferences"
touch "$prefs"
encoded=$(printf '%s\n' "$bottles" "$whisky" "$roms" "$prefs" | base64 | tr -d '\n')
app_details=("CrossOver|$app|com.codeweavers.CrossOver|12|$encoded||true|false|false|||||none||||")
running_apps=() sudo_apps=() brew_cask_apps=() leftover_notes=()
total_estimated_size=12
get_path_size_kb() { printf '10\n'; }
calculate_total_size() { if [[ -n "$1" ]]; then printf '1\n'; else printf '0\n'; fi; }
drain_pending_input() { :; }
paginated_multi_select() { return 9; }
MOLE_UNINSTALL_WITH_DATA=1 MOLE_DRY_RUN=1 MOLE_TEST_MODE=1 _batch_preview_and_confirm <<< ''
IFS='|' read -r _ _ _ _ result _ <<< "${app_details[0]}"
files=$(decode_file_list "$result" CrossOver)
[[ "$files" == *"$prefs"* ]] || exit 1
[[ "$files" != *"$bottles"* ]] || exit 1
[[ "$files" != *"$whisky"* ]] || exit 1
[[ "$files" != *"$roms"* ]] || exit 1
SH
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    local kept="${output##*Personal data kept:}"
    [[ "$kept" == *"CrossOver"* && "$kept" == *"Whisky"* && "$kept" == *"OpenEmu"* ]] || { echo "$output"; return 1; }
}

run_non_tty_confirmation() {
    local input_mode="$1" dry_run="${2:-0}" expected_rc=3 expected_text='interactive terminal'
    if [[ "$dry_run" == 1 ]]; then
        expected_rc=4
        expected_text='Dry run complete'
    fi
    local out="$HOME/no-tty-$input_mode-$dry_run.out"
    # No sudo or Homebrew apps are selected, so the real-mode confirmation
    # path cannot reach a password prompt even when the gate is broken.
    if ! env -u MOLE_TEST_NO_AUTH -u MOLE_TEST_MODE HOME="$HOME/no-tty-$input_mode-$dry_run" \
        PROJECT_ROOT="$PROJECT_ROOT" INPUT_MODE="$input_mode" MOLE_DRY_RUN="$dry_run" EXPECTED_RC="$expected_rc" \
        /bin/bash --noprofile --norc > "$out" 2>&1 <<'SH'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_paginated.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
app="$HOME/Applications/Example.app"
mkdir -p "$app"
app_details=("Example|$app|com.example.app|12|||false|false|false|||||none||||")
running_apps=() sudo_apps=() brew_cask_apps=() leftover_notes=()
total_estimated_size=12
get_path_size_kb() { printf '0\n'; }
calculate_total_size() { printf '0\n'; }
drain_pending_input() { :; }
rc=0
if [[ "$INPUT_MODE" == null ]]; then
    _batch_preview_and_confirm < /dev/null || rc=$?
else
    printf 'n\n' | _batch_preview_and_confirm || rc=$?
fi
printf 'RC=%s\n' "$rc"
[[ $rc -eq $EXPECTED_RC ]] || exit 1
[[ -d "$app" ]] || exit 1
SH
    then
        cat "$out"
        return 1
    fi
    grep -Fq "$expected_text" "$out" || { cat "$out"; return 1; }
}

@test "real uninstall preview refuses /dev/null without a terminal" {
    run_non_tty_confirmation null
}

@test "real uninstall preview refuses a piped n without a terminal" {
    run_non_tty_confirmation piped
}

@test "dry-run uninstall preview without a terminal ends cleanly after the plan" {
    run_non_tty_confirmation null 1
    run_non_tty_confirmation piped 1
}

@test "with-data emulator holdbacks stay selectable and ordinary data stays selected" {
    run env HOME="$HOME/emulator-holdbacks" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'SH'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
for name in Dolphin PCSX2 RetroArch PrismLauncher Minecraft Citra Cemu Ryujinx PPSSPP RPCS3 MultiMC ATLauncher; do
    path="$HOME/Library/Application Support/$name"
    mkdir -p "$path"
    found=$(find_app_files "org.example.$name" "$name")
    grep -Fx "$path" <<< "$found" || exit 1
    _uninstall_data_preselect_holdback "$path" || exit 1
    _uninstall_data_preselect_holdback "$path/saves" || exit 1
    if _uninstall_data_preselect_holdback "$path-backup"; then exit 1; fi
done
if _uninstall_data_preselect_holdback "$HOME/Library/Application Support/ExampleChat"; then exit 1; fi
files=$(printf '%s\n' "$HOME/Library/Application Support/PCSX2" "$HOME/Library/Application Support/ExampleChat")
encoded=$(printf '%s' "$files" | base64 | tr -d '\n')
_review_original_details=("PCSX2|$HOME/Applications/PCSX2.app|net.pcsx2.PCSX2|1|$encoded|")
_review_personal_paths=() _review_selected_paths=() _review_auto_files=() _review_personal_files=() _review_app_sizes=()
calculate_total_size() { printf '1\n'; }
MOLE_UNINSTALL_WITH_DATA=1 _uninstall_prepare_data_review
[[ "${_review_personal_paths[*]}" == *PCSX2* ]] || exit 1
[[ "${_review_selected_paths[*]}" != *PCSX2* ]] || exit 1
[[ "${_review_selected_paths[*]}" == *ExampleChat* ]] || exit 1
_review_selected_paths+=("$HOME/Library/Application Support/PCSX2")
_uninstall_apply_data_selection
[[ "$(decode_file_list "$(cut -d '|' -f 5 <<< "${app_details[0]}")" PCSX2)" == *PCSX2* ]] || exit 1
SH
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "without Full Disk Access, other apps' container rows are listed unmeasured" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
stub="$HOME/du-stub"; log="$HOME/du.log"
rm -rf "$stub" "$log"; mkdir -p "$stub"
cat > "$stub/du" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$log"
printf '8\t%s\n' "\${@: -1}"
STUB
chmod +x "$stub/du"
PATH="$stub:$PATH"
container="$HOME/Library/Containers/com.example.review"
group="$HOME/Library/Group Containers/group.example.review"
support="$HOME/Library/Application Support/ExampleReview"
mkdir -p "$container/Data" "$group/Data" "$support"
files=$(printf '%s\n%s\n%s' "$container" "$group" "$support")

MOLE_HAS_FDA=0
[[ "$(format_uninstall_preview_path "$container")" != *", "* ]] || exit 1
[[ "$(format_uninstall_preview_path "$group")" != *", "* ]] || exit 2
[[ "$(calculate_total_size "$files")" == 8 ]] || exit 3
[[ "$(format_uninstall_preview_path "$support")" == *", "* ]] || exit 4
if grep -F -e "Containers" "$log"; then exit 5; fi

: > "$log"; MOLE_HAS_FDA=unknown
[[ "$(calculate_total_size "$files")" == 8 ]] || exit 6
if grep -F -e "Containers" "$log"; then exit 7; fi

# Through the real sink: the row still goes, its log size reads unknown, and
# only an uninstall skips the probe.
export MOLE_DELETE_LOG="$HOME/deletions.log"
: > "$log"; : > "$MOLE_DELETE_LOG"; MOLE_HAS_FDA=0
MOLE_UNINSTALL_MODE=1 MOLE_DELETE_MODE=permanent mole_delete "$container" false || exit 8
[[ ! -e "$container" ]] || exit 9
if grep -F -e "Containers" "$log"; then exit 10; fi
grep -F "$container" "$MOLE_DELETE_LOG" | grep -qF unknown || exit 15
MOLE_DELETE_MODE=permanent mole_delete "$group" false || exit 11
[[ ! -e "$group" ]] || exit 16
grep -qF "Group Containers" "$log" || exit 12
mkdir -p "$container/Data" "$group/Data"

: > "$log"; MOLE_HAS_FDA=1
[[ "$(calculate_total_size "$files")" == 24 ]] || exit 13
[[ "$(grep -c "Containers" "$log")" == 2 ]] || exit 14
echo ok
SCRIPT
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"ok"* ]]
}
