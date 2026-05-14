#!/usr/bin/env bats

setup_file() {
	PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export PROJECT_ROOT

	ORIGINAL_HOME="${HOME:-}"
	export ORIGINAL_HOME

	HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-dev-extended.XXXXXX")"
	export HOME

	mkdir -p "$HOME"
}

teardown_file() {
	rm -rf "$HOME"
	if [[ -n "${ORIGINAL_HOME:-}" ]]; then
		export HOME="$ORIGINAL_HOME"
	fi
}

@test "clean_dev_elixir cleans hex cache" {
	mkdir -p "$HOME/.mix" "$HOME/.hex"
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2"; }
clean_dev_elixir
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Hex cache"* ]]
}

@test "clean_dev_elixir does not clean mix archives" {
	mkdir -p "$HOME/.mix/archives"
	touch "$HOME/.mix/archives/test_tool.ez"

	# Source and run the function
	source "$PROJECT_ROOT/lib/core/common.sh"
	source "$PROJECT_ROOT/lib/clean/dev.sh"
	# shellcheck disable=SC2329
	safe_clean() { :; }
	clean_dev_elixir >/dev/null 2>&1 || true

	# Verify the file still exists
	[ -f "$HOME/.mix/archives/test_tool.ez" ]
}

@test "clean_dev_haskell cleans cabal install cache" {
	mkdir -p "$HOME/.cabal" "$HOME/.stack"
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2"; }
clean_dev_haskell
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Cabal install cache"* ]]
}

@test "clean_dev_haskell does not clean stack programs" {
	mkdir -p "$HOME/.stack/programs/x86_64-osx"
	touch "$HOME/.stack/programs/x86_64-osx/ghc-9.2.8.tar.xz"

	# Source and run the function
	source "$PROJECT_ROOT/lib/core/common.sh"
	source "$PROJECT_ROOT/lib/clean/dev.sh"
	# shellcheck disable=SC2329
	safe_clean() { :; }
	clean_dev_haskell >/dev/null 2>&1 || true

	# Verify the file still exists
	[ -f "$HOME/.stack/programs/x86_64-osx/ghc-9.2.8.tar.xz" ]
}

@test "clean_dev_ocaml cleans opam cache" {
	mkdir -p "$HOME/.opam"
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2"; }
clean_dev_ocaml
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Opam cache"* ]]
}

@test "clean_dev_editors cleans VS Code and Zed caches" {
	mkdir -p "$HOME/Library/Caches/com.microsoft.VSCode" "$HOME/Library/Application Support/Code" "$HOME/Library/Caches/Zed"
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2"; }
clean_service_worker_cache() { :; }
clean_dev_editors
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"VS Code cached data"* ]]
	[[ "$output" == *"Zed cache"* ]]
}

@test "clean_dev_editors does not clean VS Code workspace storage" {
	mkdir -p "$HOME/Library/Application Support/Code/User/workspaceStorage/abc123"
	touch "$HOME/Library/Application Support/Code/User/workspaceStorage/abc123/workspace.json"

	# Source and run the function
	source "$PROJECT_ROOT/lib/core/common.sh"
	source "$PROJECT_ROOT/lib/clean/dev.sh"
	# shellcheck disable=SC2329
	safe_clean() { :; }
	clean_dev_editors >/dev/null 2>&1 || true

	# Verify the file still exists
	[ -f "$HOME/Library/Application Support/Code/User/workspaceStorage/abc123/workspace.json" ]
}

@test "check_android_ndk reports multiple NDK versions" {
	run bash -c 'HOME=$(mktemp -d) && mkdir -p "$HOME/Library/Android/sdk/ndk"/{21.0.1,22.0.0,20.0.0} && source "$0" && note_activity() { :; } && NC="" && GREEN="" && GRAY="" && YELLOW="" && ICON_SUCCESS="✓" && check_android_ndk' "$PROJECT_ROOT/lib/clean/dev.sh"

	[ "$status" -eq 0 ]
	[[ "$output" == *"Android NDK versions: 3 found"* ]]
}

@test "check_android_ndk silent when only one NDK" {
	run bash -c 'HOME=$(mktemp -d) && mkdir -p "$HOME/Library/Android/sdk/ndk/22.0.0" && source "$0" && note_activity() { :; } && NC="" && GREEN="" && GRAY="" && YELLOW="" && ICON_SUCCESS="✓" && check_android_ndk' "$PROJECT_ROOT/lib/clean/dev.sh"

	[ "$status" -eq 0 ]
	[[ "$output" != *"NDK versions"* ]]
}

@test "clean_xcode_device_support handles empty directories under nounset" {
	local ds_dir="$HOME/EmptyDeviceSupport"
	mkdir -p "$ds_dir"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
safe_clean() { :; }
clean_xcode_device_support "$HOME/EmptyDeviceSupport" "iOS DeviceSupport"
echo "survived"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"survived"* ]]
}

@test "clean_xcode_documentation_cache keeps newest DeveloperDocumentation index" {
	local doc_root="$HOME/DocumentationCache"
	mkdir -p "$doc_root"
	touch "$doc_root/DeveloperDocumentation.index"
	touch "$doc_root/DeveloperDocumentation-16.0.index"
	touch -t 202402010000 "$doc_root/DeveloperDocumentation.index"
	touch -t 202401010000 "$doc_root/DeveloperDocumentation-16.0.index"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_DOCUMENTATION_CACHE_DIR="$doc_root" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
has_sudo_session() { return 0; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
safe_sudo_remove() {
    local target="$1"
    echo "CLEAN:$target:Xcode documentation cache (old indexes)"
}
clean_xcode_documentation_cache
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"CLEAN:$doc_root/DeveloperDocumentation-16.0.index:Xcode documentation cache (old indexes)"* ]]
	[[ "$output" != *"CLEAN:$doc_root/DeveloperDocumentation.index:Xcode documentation cache (old indexes)"* ]]
}

@test "clean_xcode_documentation_cache skips when Xcode is running" {
	local doc_root="$HOME/DocumentationCache"
	mkdir -p "$doc_root"
	touch "$doc_root/DeveloperDocumentation.index"
	touch "$doc_root/DeveloperDocumentation-16.0.index"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_DOCUMENTATION_CACHE_DIR="$doc_root" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
pgrep() { return 0; }
safe_sudo_remove() { echo "UNEXPECTED_SAFE_SUDO_REMOVE"; }
clean_xcode_documentation_cache
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"skipping documentation cache cleanup"* ]]
	[[ "$output" != *"UNEXPECTED_SAFE_SUDO_REMOVE"* ]]
}

@test "check_rust_toolchains reports multiple toolchains" {
	run bash -c 'HOME=$(mktemp -d) && mkdir -p "$HOME/.rustup/toolchains"/{stable,nightly,1.75.0}-aarch64-apple-darwin && source "$0" && note_activity() { :; } && NC="" && GREEN="" && GRAY="" && YELLOW="" && ICON_SUCCESS="✓" && rustup() { :; } && export -f rustup && check_rust_toolchains' "$PROJECT_ROOT/lib/clean/dev.sh"

	[ "$status" -eq 0 ]
	[[ "$output" == *"Rust toolchains: 3 found"* ]]
}

@test "check_rust_toolchains silent when only one toolchain" {
	run bash -c 'HOME=$(mktemp -d) && mkdir -p "$HOME/.rustup/toolchains/stable-aarch64-apple-darwin" && source "$0" && note_activity() { :; } && NC="" && GREEN="" && GRAY="" && YELLOW="" && ICON_SUCCESS="✓" && rustup() { :; } && export -f rustup && check_rust_toolchains' "$PROJECT_ROOT/lib/clean/dev.sh"

	[ "$status" -eq 0 ]
	[[ "$output" != *"Rust toolchains"* ]]
}

@test "clean_dev_jetbrains_toolbox cleans old versions and bypasses toolbox whitelist" {
	local toolbox_channel="$HOME/Library/Application Support/JetBrains/Toolbox/apps/IDEA/ch-0"
	mkdir -p "$toolbox_channel/241.1" "$toolbox_channel/241.2" "$toolbox_channel/241.3"
	ln -s "241.3" "$toolbox_channel/current"
	touch -t 202401010000 "$toolbox_channel/241.1"
	touch -t 202402010000 "$toolbox_channel/241.2"
	touch -t 202403010000 "$toolbox_channel/241.3"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
toolbox_root="$HOME/Library/Application Support/JetBrains/Toolbox/apps"
WHITELIST_PATTERNS=("$toolbox_root"* "$HOME/Library/Application Support/JetBrains*")
note_activity() { :; }
safe_clean() {
    local target="$1"
    for pattern in "${WHITELIST_PATTERNS[@]+${WHITELIST_PATTERNS[@]}}"; do
        if [[ "$pattern" == "$toolbox_root"* ]]; then
            echo "WHITELIST_NOT_REMOVED"
            exit 1
        fi
    done
    echo "$target"
}
MOLE_JETBRAINS_TOOLBOX_KEEP=1
clean_dev_jetbrains_toolbox
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"/241.1"* ]]
	[[ "$output" != *"/241.2"* ]]
}

@test "clean_dev_jetbrains_toolbox keeps current directory and removes older versions" {
	local toolbox_channel="$HOME/Library/Application Support/JetBrains/Toolbox/apps/IDEA/ch-0"
	mkdir -p "$toolbox_channel/241.1" "$toolbox_channel/241.2" "$toolbox_channel/current"
	touch -t 202401010000 "$toolbox_channel/241.1"
	touch -t 202402010000 "$toolbox_channel/241.2"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
safe_clean() { echo "$1"; }
MOLE_JETBRAINS_TOOLBOX_KEEP=1
clean_dev_jetbrains_toolbox
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"/241.1"* ]]
	[[ "$output" != *"/241.2"* ]]
}

@test "clean_dev_ai_agents keeps newest version and removes older ones by mtime" {
	local claude_root="$HOME/.local/share/claude/versions"
	local cursor_root="$HOME/.local/share/cursor-agent/versions"
	local copilot_root="$HOME/.copilot/pkg/universal"
	mkdir -p "$claude_root" "$cursor_root" "$copilot_root"
	touch -t 202604170829 "$claude_root/2.1.112"
	touch -t 202604180902 "$claude_root/2.1.113"
	touch -t 202604181002 "$claude_root/2.1.114"
	mkdir -p "$cursor_root/2026.04.08-old" "$cursor_root/2026.04.15-new"
	touch -t 202604080000 "$cursor_root/2026.04.08-old"
	touch -t 202604150000 "$cursor_root/2026.04.15-new"
	mkdir -p "$copilot_root/1.0.5" "$copilot_root/1.0.32" "$copilot_root/1.0.34"
	touch -t 202604010000 "$copilot_root/1.0.5"
	touch -t 202604200000 "$copilot_root/1.0.32"
	touch -t 202604250000 "$copilot_root/1.0.34"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
safe_clean() { echo "$1|$2"; }
clean_dev_ai_agents
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"/2.1.112|Claude Code old version"* ]]
	[[ "$output" == *"/2.1.113|Claude Code old version"* ]]
	[[ "$output" != *"/2.1.114|"* ]]
	[[ "$output" == *"/2026.04.08-old|Cursor Agent old version"* ]]
	[[ "$output" != *"/2026.04.15-new|"* ]]
	[[ "$output" == *"/1.0.5|GitHub Copilot CLI old version"* ]]
	[[ "$output" == *"/1.0.32|GitHub Copilot CLI old version"* ]]
	[[ "$output" != *"/1.0.34|"* ]]
}

@test "clean_dev_ai_agents protects the active version pointed at by ~/.local/bin/<agent>" {
	local claude_root="$HOME/.local/share/claude/versions"
	local cursor_root="$HOME/.local/share/cursor-agent/versions"
	local bin_dir="$HOME/.local/bin"
	rm -rf "$claude_root" "$cursor_root" "$bin_dir"
	mkdir -p "$claude_root" "$cursor_root" "$bin_dir"

	mkdir -p "$claude_root/2.1.112" "$claude_root/2.1.113" "$claude_root/2.1.114"
	touch -t 202604170000 "$claude_root/2.1.112"
	touch -t 202604180000 "$claude_root/2.1.113"
	touch -t 202604200000 "$claude_root/2.1.114"
	ln -s "$claude_root/2.1.113" "$bin_dir/claude"

	mkdir -p "$cursor_root/2026.04.01-old" "$cursor_root/2026.04.10-active" "$cursor_root/2026.04.20-newest"
	touch -t 202604010000 "$cursor_root/2026.04.01-old"
	touch -t 202604100000 "$cursor_root/2026.04.10-active"
	touch -t 202604200000 "$cursor_root/2026.04.20-newest"
	: >"$cursor_root/2026.04.10-active/cursor-agent"
	ln -s "$cursor_root/2026.04.10-active/cursor-agent" "$bin_dir/cursor-agent"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
safe_clean() { echo "$1|$2"; }
clean_dev_ai_agents
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"/2.1.112|Claude Code old version"* ]]
	[[ "$output" != *"/2.1.113|"* ]]
	[[ "$output" != *"/2.1.114|"* ]]
	[[ "$output" == *"/2026.04.01-old|Cursor Agent old version"* ]]
	[[ "$output" != *"/2026.04.10-active|"* ]]
	[[ "$output" != *"/2026.04.20-newest|"* ]]
}

@test "clean_dev_ai_agents skips cleanup entirely when the active symlink is broken" {
	local claude_root="$HOME/.local/share/claude/versions"
	local bin_dir="$HOME/.local/bin"
	rm -rf "$claude_root" "$bin_dir"
	mkdir -p "$claude_root" "$bin_dir"

	mkdir -p "$claude_root/2.1.112" "$claude_root/2.1.113" "$claude_root/2.1.114"
	touch -t 202604170000 "$claude_root/2.1.112"
	touch -t 202604180000 "$claude_root/2.1.113"
	touch -t 202604200000 "$claude_root/2.1.114"
	ln -s "$claude_root/2.1.999-missing" "$bin_dir/claude"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
safe_clean() { echo "$1|$2"; }
clean_dev_ai_agents
EOF

	[ "$status" -eq 0 ]
	[[ "$output" != *"|Claude Code old version"* ]]
	[[ "$output" == *"Claude Code old version active symlink is broken"* ]]

	rm -f "$bin_dir/claude"
}

@test "clean_dev_ai_agents respects MOLE_AI_AGENTS_KEEP and skips missing roots" {
	local claude_root="$HOME/.local/share/claude/versions"
	mkdir -p "$claude_root"
	touch -t 202604170000 "$claude_root/2.1.100"
	touch -t 202604180000 "$claude_root/2.1.101"
	touch -t 202604190000 "$claude_root/2.1.102"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
safe_clean() { echo "$1"; }
MOLE_AI_AGENTS_KEEP=2 clean_dev_ai_agents
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"/2.1.100"* ]]
	[[ "$output" != *"/2.1.101"* ]]
	[[ "$output" != *"/2.1.102"* ]]
}

@test "clean_dev_jetbrains_logs only targets JetBrains logs" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { printf '%s|%s\n' "$1" "$2"; }
clean_dev_jetbrains_logs
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"$HOME/Library/Logs/JetBrains/*|JetBrains IDE logs"* ]]
	[[ "$output" != *"Library/Caches/JetBrains"* ]]
}

@test "clean_developer_tools includes JetBrains logs but not JetBrains cache sweep" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
stop_section_spinner() { :; }
note_activity() { :; }
safe_clean() { printf '%s|%s\n' "$1" "$2"; }
clean_tool_cache() { :; }
check_rust_toolchains() { :; }
clean_dev_npm() { :; }
clean_dev_python() { :; }
clean_dev_go() { :; }
clean_dev_mise() { :; }
clean_dev_rust() { :; }
clean_dev_docker() { :; }
clean_dev_cloud() { :; }
clean_dev_nix() { :; }
clean_dev_shell() { :; }
clean_dev_frontend() { :; }
clean_project_caches() { :; }
clean_dev_mobile() { :; }
clean_dev_jvm() { :; }
clean_dev_jetbrains_toolbox() { :; }
clean_dev_ai_agents() { :; }
clean_dev_other_langs() { :; }
clean_dev_cicd() { :; }
clean_dev_database() { :; }
clean_dev_api_tools() { :; }
clean_dev_network() { :; }
clean_dev_misc() { :; }
clean_dev_elixir() { :; }
clean_dev_haskell() { :; }
clean_dev_ocaml() { :; }
clean_xcode_tools() { :; }
clean_code_editors() { :; }
clean_homebrew() { :; }
clean_developer_tools
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"$HOME/Library/Logs/JetBrains/*|JetBrains IDE logs"* ]]
	[[ "$output" != *"Library/Caches/JetBrains"* ]]
}

@test "clean_dev_misc does not touch Claude Code state" {
	mkdir -p "$HOME/.claude/projects/project-a/memory"
	mkdir -p "$HOME/.claude/plugins/cache/plugin-a"
	mkdir -p "$HOME/.claude/plugins/marketplaces"
	mkdir -p "$HOME/.claude/paste-cache"
	mkdir -p "$HOME/.claude/tmp"
	mkdir -p "$HOME/.claude/session-env"
	mkdir -p "$HOME/.claude/shell-snapshots"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { printf 'SAFE:%s|%s\n' "$1" "$2"; }
safe_find_delete() { printf 'FIND:%s|%s|%s|%s\n' "$1" "$2" "$3" "$4"; }
clean_service_worker_cache() { :; }
clean_dev_misc
EOF

	[ "$status" -eq 0 ]
	[[ "$output" != *"$HOME/.claude/projects"* ]]
	[[ "$output" != *"$HOME/.claude/plugins/cache"* ]]
	[[ "$output" != *"$HOME/.claude/plugins/marketplaces"* ]]
	[[ "$output" != *"$HOME/.claude/paste-cache"* ]]
	[[ "$output" != *"$HOME/.claude/tmp"* ]]
	[[ "$output" != *"$HOME/.claude/session-env"* ]]
	[[ "$output" != *"$HOME/.claude/shell-snapshots"* ]]
}

@test "clean_xcode_simulator_runtime_volumes shows scan progress and skips sizing in-use volumes" {
	local volumes_root="$HOME/sim-volumes"
	local cryptex_root="$HOME/sim-cryptex"
	mkdir -p "$volumes_root/in-use-runtime" "$volumes_root/unused-runtime"
	mkdir -p "$cryptex_root"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_SIM_RUNTIME_VOLUMES_ROOT="$volumes_root" MOLE_XCODE_SIM_RUNTIME_CRYPTEX_ROOT="$cryptex_root" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"

size_log="$HOME/size-calls.log"
: > "$size_log"
DRY_RUN=false

note_activity() { :; }
has_sudo_session() { return 0; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
_sim_runtime_mount_points() {
    printf '%s\n' "$MOLE_XCODE_SIM_RUNTIME_VOLUMES_ROOT/in-use-runtime"
}
_sim_runtime_size_kb() {
    local target_path="$1"
    echo "$target_path" >> "$size_log"
    echo "1"
}
safe_sudo_remove() {
    local target_path="$1"
    echo "REMOVE:$target_path"
    return 0
}

clean_xcode_simulator_runtime_volumes
echo "SIZE_LOG_START"
cat "$size_log"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Xcode runtime volumes · scanning 2 entries"* ]]
	[[ "$output" == *"Xcode runtime volumes · cleaning 1 unused"* ]]
	[[ "$output" == *"REMOVE:$volumes_root/unused-runtime"* ]]
	[[ "$output" == *"$volumes_root/unused-runtime"* ]]
	[[ "$output" != *"$volumes_root/in-use-runtime"* ]]
}

@test "clean_dev_mobile continues cleanup when simctl is unavailable" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"

check_android_ndk() { :; }
clean_xcode_documentation_cache() { :; }
clean_xcode_simulator_runtime_volumes() { :; }
clean_xcode_device_support() { echo "DEVICE_SUPPORT:$2"; }
safe_clean() { echo "SAFE_CLEAN:$2"; }
note_activity() { :; }
debug_log() { :; }
xcrun() { return 1; }

clean_dev_mobile
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"simctl not available"* ]]
	[[ "$output" == *"DEVICE_SUPPORT:iOS DeviceSupport"* ]]
	[[ "$output" == *"SAFE_CLEAN:Android SDK cache"* ]]
}

@test "clean_dev_mobile retries simctl probe on cold-boot timeout (#890)" {
	# Exercises the timeout-retry branch (the only path the #890 fix touches).
	# Strategy:
	#   - put a real `xcrun` shim on PATH so `command -v xcrun` succeeds AND
	#     `declare -F xcrun` returns false → function falls into the else branch.
	#   - stub `run_with_timeout` so the first probe returns 124 (timeout) and
	#     the second returns 0, mirroring a cold-boot CoreSimulatorService
	#     warmup.
	#   - the shim itself returns empty for the post-probe
	#     `xcrun simctl list devices unavailable` call so we take the
	#     "already clean" branch and don't try to delete anything.
	local tmp_bin
	tmp_bin="$(mktemp -d)"
	cat > "$tmp_bin/xcrun" <<'XEOF'
#!/bin/bash
exit 0
XEOF
	chmod +x "$tmp_bin/xcrun"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TMP_XCRUN_BIN="$tmp_bin" DRY_RUN=false bash --noprofile --norc <<'EOF'
set -euo pipefail
PATH="$TMP_XCRUN_BIN:$PATH"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"

check_android_ndk() { :; }
clean_xcode_documentation_cache() { :; }
clean_xcode_simulator_runtime_volumes() { :; }
clean_xcode_device_support() { :; }
safe_clean() { :; }
note_activity() { :; }
debug_log() { echo "debug: $*"; }
sleep() { :; }  # skip the 1s pause between probes for fast tests

# First call (5s timeout) simulates cold-boot warmup → return 124.
# Second call (8s timeout) succeeds.
__rwt_count=0
run_with_timeout() {
    __rwt_count=$((__rwt_count + 1))
    if [[ $__rwt_count -eq 1 ]]; then
        return 124
    fi
    return 0
}

clean_dev_mobile
EOF

	rm -rf "$tmp_bin"

	[ "$status" -eq 0 ]
	[[ "$output" == *"simctl probe succeeded on retry"* ]] || return 1
	[[ "$output" != *"simctl not available"* ]] || return 1
}
