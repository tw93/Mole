#!/usr/bin/env bats

setup_file() {
	PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export PROJECT_ROOT

	ORIGINAL_HOME="${HOME:-}"
	export ORIGINAL_HOME

	HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-purge-home.XXXXXX")"
	export HOME

	mkdir -p "$HOME"
}

teardown_file() {
	if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
		rm -rf "$HOME"
	fi
	if [[ -n "${ORIGINAL_HOME:-}" ]]; then
		export HOME="$ORIGINAL_HOME"
	fi
}

setup() {
	# Safety: refuse to operate on a real home directory.
	if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
		printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
		return 1
	fi
	mkdir -p "$HOME/www"
	mkdir -p "$HOME/dev"
	mkdir -p "$HOME/.cache/mole"

	rm -rf "${HOME:?}/www"/* "${HOME:?}/dev"/*
	rm -rf "${HOME:?}/Library/CloudStorage" "${HOME:?}/Library/Mobile Documents"
}

@test "mole_purge_is_cloud_synced_path matches only exact cloud roots and descendants" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
physical_home="$HOME/cloud-home-physical"
logical_home="$HOME/cloud-home-link"
mkdir -p "$physical_home"
ln -s "$physical_home" "$logical_home"
HOME="$logical_home"
source "$PROJECT_ROOT/lib/clean/purge_shared.sh"

mole_purge_is_cloud_synced_path "$HOME/Library/CloudStorage"
mole_purge_is_cloud_synced_path "$HOME/Library/CloudStorage/Provider/project/target"
mole_purge_is_cloud_synced_path "$HOME/Library/Mobile Documents"
mole_purge_is_cloud_synced_path "$HOME/Library/Mobile Documents/com~apple~CloudDocs/project/node_modules"
mole_purge_is_cloud_synced_path "$physical_home/Library/CloudStorage/Provider/project/target"
mole_purge_is_cloud_synced_path "$physical_home/Library/Mobile Documents/com~apple~CloudDocs/project/node_modules"

if mole_purge_is_cloud_synced_path "$HOME/Library/CloudStorageBackup/project/target"; then
	exit 1
fi
if mole_purge_is_cloud_synced_path "$HOME/Library/Mobile Documents-old/project/target"; then
	exit 1
fi
if mole_purge_is_cloud_synced_path "$physical_home/Library/CloudStorageBackup/project/target"; then
	exit 1
fi
if mole_purge_is_cloud_synced_path "$physical_home/Library/Mobile Documents-old/project/target"; then
	exit 1
fi
EOF

	[ "$status" -eq 0 ] || return 1
}

@test "is_safe_project_artifact: rejects shallow paths (protection against accidents)" {
	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        if is_safe_project_artifact '$HOME/www/node_modules' '$HOME/www'; then
            echo 'UNSAFE'
        else
            echo 'SAFE'
        fi
    ")
	[[ "$result" == "SAFE" ]]
}

@test "is_safe_project_artifact: allows proper project artifacts" {
	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        if is_safe_project_artifact '$HOME/www/myproject/node_modules' '$HOME/www'; then
            echo 'ALLOWED'
        else
            echo 'BLOCKED'
        fi
    ")
	[[ "$result" == "ALLOWED" ]]
}

@test "is_safe_project_artifact: rejects non-absolute paths" {
	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        if is_safe_project_artifact 'relative/path/node_modules' '$HOME/www'; then
            echo 'UNSAFE'
        else
            echo 'SAFE'
        fi
    ")
	[[ "$result" == "SAFE" ]]
}

@test "is_safe_project_artifact: validates depth calculation" {
	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        if is_safe_project_artifact '$HOME/www/project/subdir/node_modules' '$HOME/www'; then
            echo 'ALLOWED'
        else
            echo 'BLOCKED'
        fi
    ")
	[[ "$result" == "ALLOWED" ]]
}

@test "is_safe_project_artifact: allows direct child when search path is project root" {
	mkdir -p "$HOME/single-project/node_modules"
	touch "$HOME/single-project/package.json"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        if is_safe_project_artifact '$HOME/single-project/node_modules' '$HOME/single-project'; then
            echo 'ALLOWED'
        else
            echo 'BLOCKED'
        fi
    ")

	[[ "$result" == "ALLOWED" ]]
}

@test "is_safe_project_artifact: accepts physical path under symlinked search root" {
	mkdir -p "$HOME/www/real/proj/node_modules"
	touch "$HOME/www/real/proj/package.json"
	ln -s "$HOME/www/real" "$HOME/www/link"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        if is_safe_project_artifact '$HOME/www/real/proj/node_modules' '$HOME/www/link/proj'; then
            echo 'ALLOWED'
        else
            echo 'BLOCKED'
        fi
    ")

	[[ "$result" == "ALLOWED" ]]
}

@test "is_safe_configured_purge_artifact rejects paths outside configured roots" {
	mkdir -p "$HOME/www/project/node_modules" "$HOME/dev/other/node_modules"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        PURGE_SEARCH_PATHS=('$HOME/www')
        if is_safe_configured_purge_artifact '$HOME/dev/other/node_modules'; then
            echo 'UNSAFE'
        else
            echo 'BLOCKED'
        fi
    ")

	[[ "$result" == "BLOCKED" ]]
}

@test "is_safe_configured_purge_artifact checks a lexical owner before unrelated roots" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
PURGE_SEARCH_PATHS=("$HOME/unrelated" "$HOME/projects")
is_safe_project_artifact() {
	printf '%s\n' "$2" >> "$HOME/safety-roots"
	[[ "$2" == "$HOME/projects" ]]
}
is_safe_configured_purge_artifact "$HOME/projects/app/node_modules"
printf 'CALLS=%s ROOT=%s\n' \
	"$(wc -l < "$HOME/safety-roots" | tr -d ' ')" \
	"$(cat "$HOME/safety-roots")"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == "CALLS=1 ROOT=$HOME/projects" ]] || return 1
}

@test "is_safe_configured_purge_artifact preserves physical alias fallback" {
	mkdir -p "$HOME/www/real/proj/node_modules"
	touch "$HOME/www/real/proj/package.json"
	ln -s "$HOME/www/real" "$HOME/www/link"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        PURGE_SEARCH_PATHS=('$HOME/www/link/proj')
        if is_safe_configured_purge_artifact '$HOME/www/real/proj/node_modules'; then
            echo 'ALLOWED'
        else
            echo 'BLOCKED'
        fi
    ")

	[[ "$result" == "ALLOWED" ]]
}

@test "compact_purge_scan_path keeps the tail of long purge paths visible" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_SKIP_MAIN=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/purge.sh"
compact_purge_scan_path "$HOME/projects/team/service/very/deep/component/node_modules" 32
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == ".../deep/component/node_modules" ]]
}

@test "compact_purge_menu_path keeps the project tail visible" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
compact_purge_menu_path "$HOME/projects/team/service/very/deep/component/node_modules" 32
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == ".../deep/component/node_modules" ]]
}

@test "compact_purge_menu_path respects display width for a long CJK segment" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
result=$(compact_purge_menu_path '/项目项目项目项目项目项目项目项目项目项目项目项目' 10)
printf '%s\n' "$result"
[[ $(get_display_width "$result") -le 10 ]]
EOF

	[ "$status" -eq 0 ] || return 1
}

@test "format_purge_display preserves the cloud marker while compacting paths" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
result=$(format_purge_display '[cloud] ~/Library/CloudStorage/Provider/company/team/very/deep/project' node_modules 1GB 48)
printf '%s\n' "$result"
[[ "$result" == "[cloud] "* ]]
[[ $(get_display_width "$result") -le 48 ]]
EOF

	[ "$status" -eq 0 ] || return 1
}

@test "format_purge_target_path rewrites home with tilde" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
format_purge_target_path "$HOME/www/app/node_modules"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == \~/www/app/node_modules ]]
}

@test "find_purge_project_root_for_artifact prefers the owning monorepo" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"

artifact="$HOME/www/obelisk/apps/web/node_modules"
mkdir -p "$artifact"
touch "$HOME/www/obelisk/pnpm-workspace.yaml"
touch "$HOME/www/obelisk/apps/web/package.json"

find_purge_project_root_for_artifact "$artifact"
EOF

	[ "$status" -eq 0 ] || return 1
	[ "$output" = "$HOME/www/obelisk" ] || return 1
}

@test "find_purge_project_root_for_artifact prefers a worktree over its nested package" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"

artifact="$HOME/.codex/worktrees/obelisk/apps/web/node_modules"
mkdir -p "$artifact"
touch "$HOME/.codex/worktrees/obelisk/.git"
touch "$HOME/.codex/worktrees/obelisk/apps/web/package.json"

find_purge_project_root_for_artifact "$artifact"
EOF

	[ "$status" -eq 0 ] || return 1
	[ "$output" = "$HOME/.codex/worktrees/obelisk" ] || return 1
}

@test "filter_nested_artifacts: removes nested node_modules" {
	mkdir -p "$HOME/www/project/node_modules/package/node_modules"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        printf '%s\n' '$HOME/www/project/node_modules' '$HOME/www/project/node_modules/package/node_modules' | \
        filter_nested_artifacts | wc -l | tr -d ' '
    ")

	[[ "$result" == "1" ]]
}

@test "filter_nested_artifacts: keeps independent artifacts" {
	mkdir -p "$HOME/www/project1/node_modules"
	mkdir -p "$HOME/www/project2/target"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        printf '%s\n' '$HOME/www/project1/node_modules' '$HOME/www/project2/target' | \
        filter_nested_artifacts | wc -l | tr -d ' '
    ")

	[[ "$result" == "2" ]]
}

@test "filter_nested_artifacts: removes Xcode build subdirectories (Mac projects)" {
	# Simulate Mac Xcode project with nested .build directories:
	# ~/www/testapp/build
	# ~/www/testapp/build/Framework.build
	# ~/www/testapp/build/Package.build
	mkdir -p "$HOME/www/testapp/build/Framework.build"
	mkdir -p "$HOME/www/testapp/build/Package.build"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        printf '%s\n' \
            '$HOME/www/testapp/build' \
            '$HOME/www/testapp/build/Framework.build' \
            '$HOME/www/testapp/build/Package.build' | \
        filter_nested_artifacts | wc -l | tr -d ' '
    ")

	# Should only keep the top-level 'build' directory, filtering out nested .build dirs
	[[ "$result" == "1" ]]
}

# Vendor protection unit tests
@test "is_rails_project_root: detects valid Rails project" {
	mkdir -p "$HOME/www/test-rails/config"
	mkdir -p "$HOME/www/test-rails/bin"
	touch "$HOME/www/test-rails/config/application.rb"
	touch "$HOME/www/test-rails/Gemfile"
	touch "$HOME/www/test-rails/bin/rails"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        if is_rails_project_root '$HOME/www/test-rails'; then
            echo 'YES'
        else
            echo 'NO'
        fi
    ")

	[[ "$result" == "YES" ]]
}

@test "is_rails_project_root: rejects non-Rails directory" {
	mkdir -p "$HOME/www/not-rails"
	touch "$HOME/www/not-rails/package.json"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        if is_rails_project_root '$HOME/www/not-rails'; then
            echo 'YES'
        else
            echo 'NO'
        fi
    ")

	[[ "$result" == "NO" ]]
}

@test "is_go_project_root: detects valid Go project" {
	mkdir -p "$HOME/www/test-go"
	touch "$HOME/www/test-go/go.mod"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        if is_go_project_root '$HOME/www/test-go'; then
            echo 'YES'
        else
            echo 'NO'
        fi
    ")

	[[ "$result" == "YES" ]]
}

@test "is_php_project_root: detects valid PHP Composer project" {
	mkdir -p "$HOME/www/test-php"
	touch "$HOME/www/test-php/composer.json"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        if is_php_project_root '$HOME/www/test-php'; then
            echo 'YES'
        else
            echo 'NO'
        fi
    ")

	[[ "$result" == "YES" ]]
}

@test "is_protected_vendor_dir: protects Rails vendor" {
	mkdir -p "$HOME/www/rails-app/vendor"
	mkdir -p "$HOME/www/rails-app/config"
	touch "$HOME/www/rails-app/config/application.rb"
	touch "$HOME/www/rails-app/Gemfile"
	touch "$HOME/www/rails-app/config/environment.rb"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        if is_protected_vendor_dir '$HOME/www/rails-app/vendor'; then
            echo 'PROTECTED'
        else
            echo 'NOT_PROTECTED'
        fi
    ")

	[[ "$result" == "PROTECTED" ]]
}

@test "is_protected_vendor_dir: does not protect PHP vendor" {
	mkdir -p "$HOME/www/php-app/vendor"
	touch "$HOME/www/php-app/composer.json"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        if is_protected_vendor_dir '$HOME/www/php-app/vendor'; then
            echo 'PROTECTED'
        else
            echo 'NOT_PROTECTED'
        fi
    ")

	[[ "$result" == "NOT_PROTECTED" ]]
}

@test "is_project_container detects project indicators" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
mkdir -p "$HOME/Workspace2/project"
touch "$HOME/Workspace2/project/package.json"
if is_project_container "$HOME/Workspace2" 2; then
    echo "yes"
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"yes"* ]]
}

@test "is_project_container rejects purge targets so artifacts are never scanned into (#1459)" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"

# Every npm package ships package.json, the first project indicator, so a
# stray ~/node_modules matches the container probe unless targets are rejected.
mkdir -p "$HOME/node_modules/markdown-it/dist"
printf '{"name":"markdown-it"}' > "$HOME/node_modules/markdown-it/package.json"
mkdir -p "$HOME/vendor/acme/lib"
printf '{"name":"acme/lib"}' > "$HOME/vendor/acme/composer.json"
mkdir -p "$HOME/Pods/SomePod"
printf 'x' > "$HOME/Pods/SomePod/Package.swift"

for artifact in node_modules vendor Pods; do
    if is_project_container "$HOME/$artifact" 2; then
        echo "FAIL: $artifact classified as container"
        exit 1
    fi
done

# A directory that is not a purge target still works.
mkdir -p "$HOME/Sources/app"
touch "$HOME/Sources/app/package.json"
is_project_container "$HOME/Sources" 2 || exit 1
echo ok
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" == *"ok"* ]]
}

@test "purge emits no candidates inside a stray home-level node_modules (#1459)" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"

mkdir -p "$HOME/node_modules/markdown-it/dist" "$HOME/node_modules/khroma/build"
printf '{"name":"markdown-it"}' > "$HOME/node_modules/markdown-it/package.json"
printf '{"name":"khroma"}' > "$HOME/node_modules/khroma/package.json"

# Deleting node_modules/<pkg>/dist leaves the package half-installed and needs
# a network restore, so the container must never be discovered as a scan root.
if discover_project_dirs | grep -q "^$HOME/node_modules$"; then
    echo "FAIL: stray node_modules discovered as a purge search path"
    exit 1
fi
echo ok
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" == *"ok"* ]]
}

@test "discover_project_dirs includes detected containers" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
mkdir -p "$HOME/CustomProjects/app"
touch "$HOME/CustomProjects/app/go.mod"
discover_project_dirs | grep -q "$HOME/CustomProjects"
EOF

	[ "$status" -eq 0 ]
}

@test "discover_project_dirs includes agent worktree containers" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
mkdir -p "$HOME/.codex/worktrees/checkout/node_modules"
discover_project_dirs | grep -q "^$HOME/.codex/worktrees$"
EOF

	[ "$status" -eq 0 ]
}

@test "discover_project_dirs still ignores unlisted dot directories" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
mkdir -p "$HOME/.local/share/app"
touch "$HOME/.local/share/app/package.json"
if discover_project_dirs | grep -q "$HOME/.local"; then
	echo "leaked"
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" != *"leaked"* ]] || return 1
}

@test "agent worktree container does not allow direct-child artifact removal" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
mkdir -p "$HOME/.codex/worktrees/node_modules"
mkdir -p "$HOME/.codex/worktrees/checkout/node_modules"
if is_safe_project_artifact "$HOME/.codex/worktrees/node_modules" "$HOME/.codex/worktrees"; then
	echo "direct-child-allowed"
fi
if is_safe_project_artifact "$HOME/.codex/worktrees/checkout/node_modules" "$HOME/.codex/worktrees"; then
	echo "nested-allowed"
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"nested-allowed"* ]] || return 1
	[[ "$output" != *"direct-child-allowed"* ]] || return 1
}

@test "save_discovered_paths writes config with tilde" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
save_discovered_paths "$HOME/Projects"
grep -q "^~/" "$HOME/.config/mole/purge_paths"
EOF

	[ "$status" -eq 0 ]
}

@test "purge terminal preserves focus across resize and supports project navigation" {
	command -v python3 >/dev/null 2>&1 || skip "python3 not available"
	run python3 "$PROJECT_ROOT/tests/purge_menu_pty.py"
	[ "$status" -eq 0 ]
}

@test "select_purge_categories returns failure on empty input" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
if select_purge_categories; then
    exit 1
fi
EOF

	[ "$status" -eq 0 ]
}

@test "select_purge_categories restores caller EXIT/INT/TERM traps" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
trap 'echo parent-exit' EXIT
trap 'echo parent-int' INT
trap 'echo parent-term' TERM

before_exit=$(trap -p EXIT)
before_int=$(trap -p INT)
before_term=$(trap -p TERM)

PURGE_CATEGORY_SIZES="1"
PURGE_RECENT_CATEGORIES="false"
select_purge_categories "demo" <<< $'\n' > /dev/null 2>&1 || true

after_exit=$(trap -p EXIT)
after_int=$(trap -p INT)
after_term=$(trap -p TERM)

if [[ "$before_exit" == "$after_exit" && "$before_int" == "$after_int" && "$before_term" == "$after_term" ]]; then
    echo "PASS"
else
    echo "FAIL"
    echo "before_exit=$before_exit"
    echo "after_exit=$after_exit"
    echo "before_int=$before_int"
    echo "after_int=$after_int"
    echo "before_term=$before_term"
    echo "after_term=$after_term"
    exit 1
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
}

@test "select_purge_categories names the destructive choice and keeps project skip visible when narrow" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"

tput() {
	[[ "${1:-}" == "cols" ]] && printf '32\n'
}
PURGE_CATEGORY_SIZES="1"
PURGE_RECENT_CATEGORIES="false"
if select_purge_categories "~/work/obelisk 4KB | node_modules" <<< $'q\n'; then
	exit 1
fi
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"Select Artifacts to Purge"* ]] || return 1
	[[ "$output" == *"X Skip"* ]] || return 1
	[[ "$output" != *"Select Categories to Clean"* ]] || return 1
}

@test "select_purge_categories shows exact project boundaries and selection feedback" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"

tput() {
	case "${1:-}" in
		cols) printf '100\n' ;;
		lines) printf '24\n' ;;
	esac
}
PURGE_CATEGORY_SIZES="100,50,25"
PURGE_CATEGORY_PROJECT_IDS_ARRAY=("project-a" "project-a" "project-b")
PURGE_CATEGORY_PROJECT_PATHS_ARRAY=("~/work/obelisk" "~/work/obelisk" "~/work/atlas")
PURGE_CATEGORY_SIZE_UNKNOWN_FLAGS_ARRAY=("false" "false" "false")
select_purge_categories "A node_modules" "A dist" "B target" <<< $'x\n'
printf 'RESULT=%s\n' "$PURGE_SELECTION_RESULT"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"┌ ~/work/obelisk"* ]] || return 1
	[[ "$output" == *"└ ~/work/obelisk"* ]] || return 1
	[[ "$output" == *"─ ~/work/atlas"* ]] || return 1
	[[ "$output" == *"~/work/obelisk · 154KB · 2/2 selected"* ]] || return 1
	[[ "$output" == *"~/work/atlas · 26KB · 1/1 selected"* ]] || return 1
	[[ "$output" == *"RESULT=2"* ]] || return 1
}

@test "select_purge_categories skips every artifact with the current project ID" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"

PURGE_CATEGORY_SIZES="1,2,3"
PURGE_CATEGORY_PROJECT_IDS_ARRAY=("project-a" "project-a" "project-b")
select_purge_categories "A node_modules" "A dist" "B target" <<< $'x\n' > /dev/null
printf 'RESULT=%s\n' "$PURGE_SELECTION_RESULT"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"RESULT=2"* ]] || return 1
}

@test "select_purge_categories skips only the current row without a project ID" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"

PURGE_CATEGORY_SIZES="1,2"
PURGE_CATEGORY_PROJECT_IDS_ARRAY=("" "project-a")
select_purge_categories "Unknown node_modules" "A dist" <<< $'x\n' > /dev/null
printf 'RESULT=%s\n' "$PURGE_SELECTION_RESULT"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"RESULT=1"* ]] || return 1
}

@test "select_purge_categories does not group same-named projects" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"

PURGE_CATEGORY_SIZES="1,2"
PURGE_CATEGORY_PROJECT_IDS_ARRAY=("inode:1:10" "inode:1:20")
select_purge_categories "~/client-a/obelisk node_modules" "~/client-b/obelisk dist" <<< $'x\n' > /dev/null
printf 'RESULT=%s\n' "$PURGE_SELECTION_RESULT"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"RESULT=1"* ]] || return 1
}

@test "purge search jumps by exact project path without changing other selections" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
PURGE_CATEGORY_SIZES="1,2,3"
PURGE_CATEGORY_PROJECT_IDS_ARRAY=("a" "b" "c")
PURGE_CATEGORY_PROJECT_PATHS_ARRAY=("~/client-a/obelisk" "~/client-b/obelisk" "~/client-c/atlas")
# Search is case-insensitive and accepts vim navigation letters as query text.
select_purge_categories "node_modules" "dist" "target" <<< $'/CLIENT-B\n \n' >/dev/null
[[ "$PURGE_SELECTION_RESULT" == "0,2" ]]
# Searching must restore the caller's shell matching mode.
if shopt -q nocasematch; then exit 1; fi
PURGE_CATEGORY_PROJECT_PATHS_ARRAY[1]="~/client-b/项目"
LC_ALL=C select_purge_categories "node_modules" "dist" "target" <<< $'/项目\n \n' >/dev/null
[[ "$PURGE_SELECTION_RESULT" == "0,2" ]]
EOF
	[ "$status" -eq 0 ]
}

@test "purge selection and final confirmation cancel when input closes" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
PURGE_CATEGORY_SIZES="1"
PURGE_RECENT_CATEGORIES="false"
if select_purge_categories "node_modules" </dev/null; then exit 91; fi
if confirm_purge_cleanup 1 1 0 0 </dev/null; then exit 92; fi
EOF
	[ "$status" -eq 0 ]
}

@test "confirm_purge_cleanup accepts Enter" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
drain_pending_input() { :; }
confirm_purge_cleanup 2 1024 0 0 <<< ''
EOF

	[ "$status" -eq 0 ]
}

@test "confirm_purge_cleanup shows selected paths" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
drain_pending_input() { :; }
confirm_purge_cleanup 2 1024 0 0 "~/www/app/node_modules" "~/www/app/dist" <<< ''
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Selected paths:"* ]] || return 1
	[[ "$output" == *"~/www/app/node_modules"* ]] || return 1
	[[ "$output" == *"~/www/app/dist"* ]]
}

@test "confirm_purge_cleanup warns once before confirming cloud-synced artifacts" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
drain_pending_input() { :; }
confirm_purge_cleanup 2 1024 0 1 "[cloud] ~/Library/CloudStorage/Provider/app/target" "~/www/app/dist" <<< ''
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"Cloud-synced artifacts may also be removed from other devices."* ]] || return 1
	[[ "$output" == *"mo purge --paths"* ]] || return 1
	local warning_count
	warning_count=$(printf '%s\n' "$output" | grep -cF "Cloud-synced artifacts may also be removed from other devices.")
	[ "$warning_count" -eq 1 ] || return 1
	local warning_line prompt_line
	warning_line=$(printf '%s\n' "$output" | grep -nF "Cloud-synced artifacts may also be removed from other devices." | cut -d: -f1)
	prompt_line=$(printf '%s\n' "$output" | grep -nF "Remove 2 artifacts" | cut -d: -f1)
	[ "$warning_line" -lt "$prompt_line" ] || return 1
}

@test "confirm_purge_cleanup cancels on ESC" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
drain_pending_input() { :; }
confirm_purge_cleanup 2 1024 0 0 <<< $'\033'
EOF

    [ "$status" -eq 1 ]
}

@test "is_protected_vendor_dir: protects Go vendor" {
	mkdir -p "$HOME/www/go-app/vendor"
	touch "$HOME/www/go-app/go.mod"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        if is_protected_vendor_dir '$HOME/www/go-app/vendor'; then
            echo 'PROTECTED'
        else
            echo 'NOT_PROTECTED'
        fi
    ")

	[[ "$result" == "PROTECTED" ]]
}

@test "is_protected_vendor_dir: protects unknown vendor (conservative)" {
	mkdir -p "$HOME/www/unknown-app/vendor"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        if is_protected_vendor_dir '$HOME/www/unknown-app/vendor'; then
            echo 'PROTECTED'
        else
            echo 'NOT_PROTECTED'
        fi
    ")

	[[ "$result" == "PROTECTED" ]]
}

@test "is_protected_purge_artifact: handles vendor directories correctly" {
	mkdir -p "$HOME/www/php-app/vendor"
	touch "$HOME/www/php-app/composer.json"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        if is_protected_purge_artifact '$HOME/www/php-app/vendor'; then
            echo 'PROTECTED'
        else
            echo 'NOT_PROTECTED'
        fi
    ")

	# PHP vendor should not be protected
	[[ "$result" == "NOT_PROTECTED" ]]
}

@test "is_protected_purge_artifact: returns false for non-vendor artifacts" {
	mkdir -p "$HOME/www/app/node_modules"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        if is_protected_purge_artifact '$HOME/www/app/node_modules'; then
            echo 'PROTECTED'
        else
            echo 'NOT_PROTECTED'
        fi
    ")

	# node_modules is not in the protected list
	[[ "$result" == "NOT_PROTECTED" ]]
}

@test "is_protected_purge_artifact avoids basename and dirname subprocesses" {
	mkdir -p "$HOME/dotnet-app/bin/Debug"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
basename() { return 99; }
dirname() { return 99; }
is_protected_purge_artifact "$HOME/dotnet-app/bin"
EOF

	[ "$status" -eq 0 ]
}

# Integration tests
@test "scan_purge_targets: skips Rails vendor directory" {
	mkdir -p "$HOME/www/rails-app/vendor/javascript"
	mkdir -p "$HOME/www/rails-app/config"
	touch "$HOME/www/rails-app/config/application.rb"
	touch "$HOME/www/rails-app/Gemfile"
	mkdir -p "$HOME/www/rails-app/bin"
	touch "$HOME/www/rails-app/bin/rails"

	local scan_output
	scan_output="$(mktemp)"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        scan_purge_targets '$HOME/www' '$scan_output'
        if grep -q '$HOME/www/rails-app/vendor' '$scan_output'; then
            echo 'FOUND'
        else
            echo 'SKIPPED'
        fi
    ")

	rm -f "$scan_output"

	[[ "$result" == "SKIPPED" ]]
}

@test "scan_purge_targets: cleans PHP Composer vendor directory" {
	mkdir -p "$HOME/www/php-app/vendor"
	touch "$HOME/www/php-app/composer.json"

	local scan_output
	scan_output="$(mktemp)"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        scan_purge_targets '$HOME/www' '$scan_output'
        if grep -q '$HOME/www/php-app/vendor' '$scan_output'; then
            echo 'FOUND'
        else
            echo 'MISSING'
        fi
    ")

	rm -f "$scan_output"

	[[ "$result" == "FOUND" ]]
}

@test "scan_purge_targets: skips Go vendor directory" {
	mkdir -p "$HOME/www/go-app/vendor"
	touch "$HOME/www/go-app/go.mod"
	touch "$HOME/www/go-app/go.sum"

	local scan_output
	scan_output="$(mktemp)"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        scan_purge_targets '$HOME/www' '$scan_output'
        if grep -q '$HOME/www/go-app/vendor' '$scan_output'; then
            echo 'FOUND'
        else
            echo 'SKIPPED'
        fi
    ")

	rm -f "$scan_output"

	[[ "$result" == "SKIPPED" ]]
}

@test "scan_purge_targets: skips unknown vendor directory" {
	# Create a vendor directory without any project file
	mkdir -p "$HOME/www/unknown-app/vendor"

	local scan_output
	scan_output="$(mktemp)"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        scan_purge_targets '$HOME/www' '$scan_output'
        if grep -q '$HOME/www/unknown-app/vendor' '$scan_output'; then
            echo 'FOUND'
        else
            echo 'SKIPPED'
        fi
    ")

	rm -f "$scan_output"

	# Unknown vendor should be protected (conservative approach)
	[[ "$result" == "SKIPPED" ]]
}

@test "scan_purge_targets: finds direct-child artifacts in project root with find mode" {
	mkdir -p "$HOME/single-project/node_modules"
	touch "$HOME/single-project/package.json"

	local scan_output
	scan_output="$(mktemp)"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        MO_USE_FIND=1 scan_purge_targets '$HOME/single-project' '$scan_output'
        if grep -q '$HOME/single-project/node_modules' '$scan_output'; then
            echo 'FOUND'
        else
            echo 'MISSING'
        fi
    ")

	rm -f "$scan_output"

	[[ "$result" == "FOUND" ]]
}

@test "scan_purge_targets: includes Terragrunt cache in project root with find mode" {
	mkdir -p "$HOME/terragrunt-project/.terragrunt-cache"
	touch "$HOME/terragrunt-project/terragrunt.hcl"

	local scan_output
	scan_output="$(mktemp)"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        MO_USE_FIND=1 scan_purge_targets '$HOME/terragrunt-project' '$scan_output'
        if grep -q '$HOME/terragrunt-project/.terragrunt-cache' '$scan_output'; then
            echo 'FOUND'
        else
            echo 'MISSING'
        fi
    ")

	rm -f "$scan_output"

	[[ "$result" == "FOUND" ]]
}

@test "scan_purge_targets: supports trailing slash search path in find mode" {
	mkdir -p "$HOME/single-project/node_modules"
	touch "$HOME/single-project/package.json"

	local scan_output
	scan_output="$(mktemp)"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        MO_USE_FIND=1 scan_purge_targets '$HOME/single-project/' '$scan_output'
        if grep -q '$HOME/single-project/node_modules' '$scan_output'; then
            echo 'FOUND'
        else
            echo 'MISSING'
        fi
    ")

	rm -f "$scan_output"

	[[ "$result" == "FOUND" ]]
}

@test "scan_purge_targets: includes valid CACHEDIR.TAG directories in find mode" {
	mkdir -p "$HOME/www/python-app/.custom-cache"
	touch "$HOME/www/python-app/pyproject.toml"
	printf 'Signature: 8a477f597d28d172789f06886806bc55\n' > "$HOME/www/python-app/.custom-cache/CACHEDIR.TAG"

	scan_output=$(mktemp)
	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        MO_USE_FIND=1 scan_purge_targets '$HOME/www' '$scan_output'
        if grep -q '$HOME/www/python-app/.custom-cache' '$scan_output'; then
            echo 'FOUND'
        else
            echo 'NOT_FOUND'
        fi
    ")
	rm -f "$scan_output"

	[[ "$result" == "FOUND" ]]
}

@test "scan_purge_targets: ignores invalid CACHEDIR.TAG signatures" {
	mkdir -p "$HOME/www/python-app/.custom-cache"
	touch "$HOME/www/python-app/pyproject.toml"
	printf 'Signature: invalid\n' > "$HOME/www/python-app/.custom-cache/CACHEDIR.TAG"

	scan_output=$(mktemp)
	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        MO_USE_FIND=1 scan_purge_targets '$HOME/www' '$scan_output'
        if grep -q '$HOME/www/python-app/.custom-cache' '$scan_output'; then
            echo 'FOUND'
        else
            echo 'NOT_FOUND'
        fi
    ")
	rm -f "$scan_output"

	[[ "$result" == "NOT_FOUND" ]]
}

@test "scan_purge_targets: keeps CACHEDIR.TAG under Library out of purge scans" {
	mkdir -p "$HOME/www/python-app/Library/fontconfig-cache"
	touch "$HOME/www/python-app/pyproject.toml"
	printf 'Signature: 8a477f597d28d172789f06886806bc55\n' > "$HOME/www/python-app/Library/fontconfig-cache/CACHEDIR.TAG"

	scan_output=$(mktemp)
	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        MO_USE_FIND=1 scan_purge_targets '$HOME/www' '$scan_output'
        if grep -q '$HOME/www/python-app/Library/fontconfig-cache' '$scan_output'; then
            echo 'FOUND'
        else
            echo 'NOT_FOUND'
        fi
    ")
	rm -f "$scan_output"

	[[ "$result" == "NOT_FOUND" ]]
}

@test "scan_purge_targets: trusts empty fd result without falling back to find" {
	mkdir -p "$HOME/.config/mole" "$HOME/www/empty-project"
	printf '%s\n' "$HOME/www" > "$HOME/.config/mole/purge_paths"

	local mock_bin="$HOME/mock-bin"
	mkdir -p "$mock_bin"
	cat > "$mock_bin/fd" <<'EOF'
#!/bin/bash
exit 0
EOF
	chmod +x "$mock_bin/fd"
	cat > "$mock_bin/find" <<'EOF'
#!/bin/bash
echo find-called >> "$HOME/find-called"
exit 0
EOF
	chmod +x "$mock_bin/find"

	local scan_output
	scan_output="$(mktemp)"

	run env HOME="$HOME" PATH="$mock_bin:$PATH" /bin/bash --noprofile --norc <<EOF
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
scan_purge_targets "$HOME/www" "$scan_output"
MO_DEBUG=1 scan_purge_targets "$HOME/www" "$scan_output"
[[ ! -e "$HOME/find-called" ]] || exit 1
[[ -f "$scan_output" ]] || exit 1
[[ ! -s "$scan_output" ]] || exit 1
EOF

	rm -f "$scan_output"
	[ "$status" -eq 0 ]
}

@test "scan_purge_targets: prunes matched artifacts from target and tag scans" {
	mkdir -p "$HOME/.config/mole" "$HOME/www/test-project/node_modules"
	printf '%s\n' "$HOME/www" > "$HOME/.config/mole/purge_paths"

	local mock_bin="$HOME/mock-pruned-fd"
	mkdir -p "$mock_bin"
	cat > "$mock_bin/fd" <<'EOF'
#!/bin/bash
args=" $* "
case "$args" in
    *" --type d "*)
        [[ "$args" == *" --prune "* ]] || exit 9
        printf '%s\n' "$HOME/www/test-project/node_modules"
        ;;
    *" --type f "*)
        [[ "$args" == *" --exclude node_modules "* ]] || exit 10
        ;;
    *) exit 11 ;;
esac
EOF
	chmod +x "$mock_bin/fd"
	cat > "$mock_bin/find" <<'EOF'
#!/bin/bash
printf 'find-called\n' >> "$HOME/find-called"
exit 12
EOF
	chmod +x "$mock_bin/find"

	local scan_output
	scan_output="$(mktemp)"

	run env HOME="$HOME" PATH="$mock_bin:$PATH" PROJECT_ROOT="$PROJECT_ROOT" SCAN_OUTPUT="$scan_output" \
		/bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
scan_purge_targets "$HOME/www" "$SCAN_OUTPUT"
[[ ! -e "$HOME/find-called" ]] || exit 1
grep -Fx "$HOME/www/test-project/node_modules" "$SCAN_OUTPUT"
EOF

	rm -f "$scan_output"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == "$HOME/www/test-project/node_modules" ]] || return 1
}

@test "scan_purge_targets: removes nested candidates before physical safety checks" {
	mkdir -p "$HOME/.config/mole" "$HOME/www/test-project/node_modules/nested/dist"
	printf '%s\n' "$HOME/www" > "$HOME/.config/mole/purge_paths"

	local mock_bin="$HOME/mock-nested-fd"
	mkdir -p "$mock_bin"
	cat > "$mock_bin/fd" <<'EOF'
#!/bin/bash
args=" $* "
if [[ "$args" == *" --type d "* ]]; then
    printf '%s\n' \
        "$HOME/www/test-project/node_modules" \
        "$HOME/www/test-project/node_modules/nested/dist"
fi
EOF
	chmod +x "$mock_bin/fd"

	local scan_output
	scan_output="$(mktemp)"

	run env HOME="$HOME" PATH="$mock_bin:$PATH" PROJECT_ROOT="$PROJECT_ROOT" SCAN_OUTPUT="$scan_output" \
		/bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
is_safe_project_artifact() {
    printf '%s\n' "$1" >> "$HOME/safety-calls"
    return 0
}
scan_purge_targets "$HOME/www" "$SCAN_OUTPUT"
grep -Fx "$HOME/www/test-project/node_modules" "$SCAN_OUTPUT"
[[ "$(wc -l < "$HOME/safety-calls" | tr -d ' ')" -eq 1 ]]
EOF

	rm -f "$scan_output"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == "$HOME/www/test-project/node_modules" ]] || return 1
}

@test "scan_purge_targets: discards a failed find target scan prefix" {
	mkdir -p "$HOME/.config/mole" "$HOME/www/test-project/node_modules"
	printf '%s\n' "$HOME/www" > "$HOME/.config/mole/purge_paths"

	local mock_bin="$HOME/mock-find-target-failure"
	mkdir -p "$mock_bin"
	cat > "$mock_bin/find" <<'EOF'
#!/bin/bash
printf '%s\n' "$HOME/www/test-project/node_modules"
exit 7
EOF
	chmod +x "$mock_bin/find"

	local scan_output
	scan_output="$(mktemp)"

	run env HOME="$HOME" PATH="$mock_bin:$PATH" PROJECT_ROOT="$PROJECT_ROOT" SCAN_OUTPUT="$scan_output" \
		/bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"

scan_status=0
MO_USE_FIND=1 scan_purge_targets "$HOME/www" "$SCAN_OUTPUT" || scan_status=$?
printf 'STATUS=%s\n' "$scan_status"
[[ ! -s "$SCAN_OUTPUT" ]] || exit 1
EOF

	rm -f "$scan_output"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"STATUS=7"* ]] || return 1
}

@test "scan_purge_targets: discards target results when the tag scan fails" {
	mkdir -p "$HOME/.config/mole" "$HOME/www/test-project/node_modules"
	printf '%s\n' "$HOME/www" > "$HOME/.config/mole/purge_paths"

	local mock_bin="$HOME/mock-find-tag-failure"
	mkdir -p "$mock_bin"
	cat > "$mock_bin/find" <<'EOF'
#!/bin/bash
args=" $* "
if [[ "$args" != *" -type f "* ]]; then
	printf '%s\n' "$HOME/www/test-project/node_modules"
	exit 0
fi

printf '%s\n' "$HOME/www/test-project/.cache/CACHEDIR.TAG"
exit 9
EOF
	chmod +x "$mock_bin/find"

	local scan_output
	scan_output="$(mktemp)"

	run env HOME="$HOME" PATH="$mock_bin:$PATH" PROJECT_ROOT="$PROJECT_ROOT" SCAN_OUTPUT="$scan_output" \
		/bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"

scan_status=0
MO_USE_FIND=1 scan_purge_targets "$HOME/www" "$SCAN_OUTPUT" || scan_status=$?
printf 'STATUS=%s\n' "$scan_status"
[[ ! -s "$SCAN_OUTPUT" ]] || exit 1
EOF

	rm -f "$scan_output"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"STATUS=9"* ]] || return 1
}

@test "scan_purge_targets: shares one deadline across fd stages and fallback" {
	mkdir -p "$HOME/.config/mole" "$HOME/www/test-project/node_modules"
	printf '%s\n' "$HOME/www" > "$HOME/.config/mole/purge_paths"

	local mock_bin="$HOME/mock-shared-scan-deadline"
	mkdir -p "$mock_bin"
	cat > "$mock_bin/fd" <<'EOF'
#!/bin/bash
printf '%s\n' "$HOME/www/test-project/node_modules"
EOF
	chmod +x "$mock_bin/fd"
	cat > "$mock_bin/find" <<'EOF'
#!/bin/bash
printf 'find-called\n' >> "$HOME/find-called"
exit 0
EOF
	chmod +x "$mock_bin/find"

	local scan_output
	scan_output="$(mktemp)"

	run env HOME="$HOME" PATH="$mock_bin:$PATH" PROJECT_ROOT="$PROJECT_ROOT" SCAN_OUTPUT="$scan_output" \
		/bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"

_mole_timeout_with_deadline() {
	local calls=0
	[[ -f "$HOME/deadline-calls" ]] && calls="$(cat "$HOME/deadline-calls")"
	calls=$((calls + 1))
	printf '%s\n' "$calls" > "$HOME/deadline-calls"
	if [[ $calls -gt 1 ]]; then
		return 124
	fi
	printf '5\n'
}

scan_status=0
scan_purge_targets "$HOME/www" "$SCAN_OUTPUT" || scan_status=$?
printf 'STATUS=%s CALLS=%s\n' "$scan_status" "$(cat "$HOME/deadline-calls")"
[[ "$scan_status" -eq 124 ]] || exit 1
[[ ! -s "$SCAN_OUTPUT" ]] || exit 1
[[ ! -e "$HOME/find-called" ]] || exit 1
EOF

	rm -f "$scan_output"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == "STATUS=124 CALLS=3" ]] || return 1
}

@test "scan_purge_targets: bounds nested filtering within the shared deadline" {
	mkdir -p "$HOME/.config/mole" "$HOME/www/test-project/node_modules"
	printf '%s\n' "$HOME/www" > "$HOME/.config/mole/purge_paths"

	local mock_bin="$HOME/mock-slow-nested-filter"
	mkdir -p "$mock_bin"
	cat > "$mock_bin/find" <<'EOF'
#!/bin/bash
args=" $* "
if [[ "$args" != *" -type f "* ]]; then
	printf '%s\n' "$HOME/www/test-project/node_modules"
fi
EOF
	chmod +x "$mock_bin/find"
	cat > "$mock_bin/sort" <<'EOF'
#!/bin/bash
sleep 4
/usr/bin/sort "$@"
EOF
	chmod +x "$mock_bin/sort"

	local scan_output
	scan_output="$(mktemp)"

	run env HOME="$HOME" PATH="$mock_bin:$PATH" PROJECT_ROOT="$PROJECT_ROOT" SCAN_OUTPUT="$scan_output" \
		MO_USE_FIND=1 MO_PURGE_SCAN_TIMEOUT_SEC=2 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
SECONDS=0
scan_status=0
scan_purge_targets "$HOME/www" "$SCAN_OUTPUT" || scan_status=$?
printf 'STATUS=%s ELAPSED=%s BYTES=%s\n' \
	"$scan_status" "$SECONDS" "$(wc -c < "$SCAN_OUTPUT" | tr -d ' ')"
EOF

	rm -f "$scan_output"
	[ "$status" -eq 0 ] || return 1
	local elapsed
	elapsed=$(printf '%s\n' "$output" | sed -n 's/.*ELAPSED=\([0-9][0-9]*\).*/\1/p')
	[[ "$output" == STATUS=124*" BYTES=0" ]] || return 1
	[[ "$elapsed" =~ ^[0-9]+$ ]] || return 1
	((elapsed < 4))
}

@test "is_recently_modified: detects recent projects" {
	mkdir -p "$HOME/www/project/node_modules"
	touch "$HOME/www/project/package.json"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/clean/project.sh'
        if is_recently_modified '$HOME/www/project/node_modules'; then
            echo 'RECENT'
        else
            echo 'OLD'
        fi
    ")
	[[ "$result" == "RECENT" ]]
}

@test "is_recently_modified: detects recent contained files under an old artifact directory" {
	mkdir -p "$HOME/www/active-project/node_modules"
	touch "$HOME/www/active-project/node_modules/active.js"
	touch -t 202001010000 "$HOME/www/active-project/node_modules"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"
is_recently_modified "$HOME/www/active-project/node_modules"
EOF

	[ "$status" -eq 0 ]
}

@test "is_recently_modified: marks old projects correctly" {
	mkdir -p "$HOME/www/old-project/node_modules"
	touch "$HOME/www/old-project/node_modules/old.js"
	touch -t 202001010000 \
		"$HOME/www/old-project/node_modules/old.js" \
		"$HOME/www/old-project/node_modules"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"
if is_recently_modified "$HOME/www/old-project/node_modules"; then
	exit 99
fi
EOF

	[ "$status" -eq 0 ]
}

@test "is_recently_modified: treats activity probe timeout as uncertain and protected" {
	mkdir -p "$HOME/www/uncertain-project/node_modules"
	touch -t 202001010000 "$HOME/www/uncertain-project/node_modules"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"
run_with_timeout() { return 124; }
result=0
is_recently_modified "$HOME/www/uncertain-project/node_modules" || result=$?
[[ "$result" -eq 124 && "$_PURGE_ACTIVITY_STATE" == uncertain ]]
EOF

	[ "$status" -eq 0 ]
}

@test "is_recently_modified: treats activity probe failure as uncertain and protected" {
	mkdir -p "$HOME/www/unreadable-project/node_modules"
	touch -t 202001010000 "$HOME/www/unreadable-project/node_modules"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"
run_with_timeout() { return 2; }
is_recently_modified "$HOME/www/unreadable-project/node_modules"
EOF

	[ "$status" -eq 0 ]
}

@test "is_recently_modified: treats exhausted total activity budget as uncertain and protected" {
	mkdir -p "$HOME/www/budget-project/node_modules"
	touch -t 202001010000 "$HOME/www/budget-project/node_modules"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"
_PURGE_ACTIVITY_DEADLINE_EPOCH=1
is_recently_modified "$HOME/www/budget-project/node_modules"
[[ "$_PURGE_ACTIVITY_STATE" == "uncertain" ]] || exit 1
EOF

    [ "$status" -eq 0 ]
}

@test "purge_target_activity_still_safe catches activity after menu review" {
    mkdir -p "$HOME/www/changed-project/node_modules"
    touch "$HOME/www/changed-project/node_modules/active.js"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"
if purge_target_activity_still_safe "$HOME/www/changed-project/node_modules" false; then
    exit 90
fi
EOF

    [ "$status" -eq 0 ]
}

@test "purge_target_activity_still_safe honors an explicit recent selection" {
    mkdir -p "$HOME/www/recent-project/node_modules"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"
purge_target_activity_still_safe "$HOME/www/recent-project/node_modules" true
EOF

    [ "$status" -eq 0 ]
}

@test "purge targets are configured correctly" {
	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        echo \"\${PURGE_TARGETS[@]}\"
    ")
	[[ "$result" == *"node_modules"* ]] || return 1
	[[ "$result" == *"target"* ]] || return 1
	[[ "$result" == *".terragrunt-cache"* ]]
}

@test "get_dir_size_kb: calculates directory size" {
	mkdir -p "$HOME/www/test-project/node_modules"
	dd if=/dev/zero of="$HOME/www/test-project/node_modules/file.bin" bs=1024 count=1024 2>/dev/null

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        get_dir_size_kb '$HOME/www/test-project/node_modules'
    ")

	[[ "$result" -ge 1000 ]] && [[ "$result" -le 1100 ]]
}

@test "get_dir_size_kb: handles non-existent paths gracefully" {
	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        get_dir_size_kb '$HOME/www/non-existent'
    ")
	[[ "$result" == "0" ]]
}

@test "get_dir_size_kb: returns TIMEOUT when size calculation hangs" {
	mkdir -p "$HOME/www/stuck-project/node_modules"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/clean/project.sh'
        run_with_timeout() { return 124; }
        get_dir_size_kb '$HOME/www/stuck-project/node_modules'
    ")

	[[ "$result" == "TIMEOUT" ]]
}

@test "get_dir_size_kb: returns ERROR when du fails without timing out" {
	mkdir -p "$HOME/www/error-project/node_modules"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/clean/project.sh'
        run_with_timeout() { return 2; }
        get_dir_size_kb '$HOME/www/error-project/node_modules'
    ")

	[[ "$result" == "ERROR" ]]
}

@test "get_dir_size_kb: returns TIMEOUT when the shared size budget is exhausted" {
	mkdir -p "$HOME/www/budget-project/node_modules"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"
_mole_timeout_with_deadline() { return 124; }
run_with_timeout() {
	printf 'unexpected du call\n' >&2
	return 99
}
get_dir_size_kb "$HOME/www/budget-project/node_modules" "$((SECONDS + 30))"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == "TIMEOUT" ]] || return 1
}

@test "purge preserves fd cancellation and rejects its partial filesystem-error output" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
mkdir -p "$HOME/probe/project/node_modules" "$HOME/.cache/mole"
touch "$HOME/probe/project/package.json"
fd() { :; }
export MO_USE_FIND=0
run_with_timeout() {
    shift
    case "$1" in
        fd)
            if [[ "$probe_mode" == cancelled ]]; then return 130; fi
            printf '%s\n' "$HOME/probe/project/node_modules"
            printf 'Permission denied\n' >&2
            ;;
        find)
            echo find >> "$HOME/find-trace"
            printf '%s\n' "$HOME/probe/project/node_modules"
            return 1
            ;;
    esac
}
probe_mode=cancelled
result=0
scan_purge_targets "$HOME/probe" "$HOME/scan-result" || result=$?
[[ $result -eq 130 && ! -e "$HOME/find-trace" && ! -s "$HOME/scan-result" ]]
probe_mode=unreadable
result=0
scan_purge_targets "$HOME/probe" "$HOME/scan-result" || result=$?
[[ $result -eq 1 && -e "$HOME/find-trace" && ! -s "$HOME/scan-result" ]]
EOF
	[ "$status" -eq 0 ]
}

@test "purge_target_activity_still_safe rechecks an uncertain selection" {
	mkdir -p "$HOME/www/uncertain-project/node_modules"
	touch -t 202001010000 "$HOME/www/uncertain-project/node_modules"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"
run_with_timeout() { return 124; }
result=0
purge_target_activity_still_safe "$HOME/www/uncertain-project/node_modules" uncertain || result=$?
[[ "$result" -eq 124 ]]
EOF

	[ "$status" -eq 0 ]
}

@test "purge size pass preserves a fractional timeout override" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"
printf 'BUDGET=%s\n' "$(_mole_purge_size_budget_seconds 2.5)"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == "BUDGET=3" ]] || return 1
}

@test "purge size pass kills active workers when its parent receives TERM" {
	local purge_home="$HOME/terminated-purge-sizes"
	local artifact="$purge_home/www/app/node_modules"
	mkdir -p "$artifact" "$purge_home/.cache/mole"
	touch "$purge_home/www/app/package.json"
	local driver="$purge_home/driver.sh"

	cat > "$driver" <<'EOF'
#!/bin/bash
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"
artifact="$HOME/www/app/node_modules"
PURGE_SEARCH_PATHS=("$HOME/www")
get_optimal_parallel_jobs() { printf '1\n'; }
scan_purge_targets() { printf '%s\n' "$artifact" > "$2"; }
is_recently_modified() {
	_PURGE_ACTIVITY_STATE=old
	return 1
}
get_dir_size_kb() {
	/bin/sh -c 'printf "%s\n" "$PPID" > "$1"' _ "$HOME/size-worker-pid"
	trap 'touch "$HOME/size-worker-terminated"; exit 143' TERM
	while [[ ! -e "$HOME/release-size-worker" ]]; do
		sleep 0.05
	done
	printf '1\n'
}
safe_remove() { return 0; }
MOLE_DRY_RUN=1 clean_project_artifacts </dev/null
EOF
	chmod +x "$driver"

	run env HOME="$purge_home" PROJECT_ROOT="$PROJECT_ROOT" DRIVER="$driver" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
/bin/bash "$DRIVER" &
parent_pid=$!
for _ in {1..100}; do
	[[ -s "$HOME/size-worker-pid" ]] && break
	sleep 0.05
done
[[ -s "$HOME/size-worker-pid" ]] || exit 1
worker_pid=$(< "$HOME/size-worker-pid")
/usr/bin/perl -e '
	my ($done, $fired, $parent, $worker) = @ARGV;
	for (1 .. 10) {
		exit 0 if -e $done;
		sleep 1;
	}
	open my $marker, ">", $fired or exit 2;
	close $marker;
	kill 9, $parent, $worker;
' "$HOME/size-parent-finished" "$HOME/size-watchdog-fired" \
	"$parent_pid" "$worker_pid" &
watchdog_pid=$!
kill -TERM "$parent_pid"
parent_rc=0
wait "$parent_pid" || parent_rc=$?
touch "$HOME/size-parent-finished"
wait "$watchdog_pid" 2> /dev/null || true
worker_alive=no
if kill -0 "$worker_pid" 2> /dev/null; then
	worker_alive=yes
	touch "$HOME/release-size-worker"
	kill -TERM "$worker_pid" 2> /dev/null || true
fi
printf 'PARENT_RC=%s WORKER_ALIVE=%s WORKER_TERMINATED=%s WATCHDOG=%s\n' \
	"$parent_rc" "$worker_alive" \
	"$([[ -e "$HOME/size-worker-terminated" ]] && printf yes || printf no)" \
	"$([[ -e "$HOME/size-watchdog-fired" ]] && printf yes || printf no)"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == "PARENT_RC=143 WORKER_ALIVE=no WORKER_TERMINATED=yes WATCHDOG=no" ]] || {
		echo "$output"
		return 1
	}
}

@test "clean_project_artifacts: restores caller INT/TERM traps" {
	result=$(/bin/bash -c "
        set -euo pipefail
        export HOME='$HOME'
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/clean/project.sh'
        mkdir -p '$HOME/www'
        PURGE_SEARCH_PATHS=('$HOME/www')
        trap 'echo parent-int' INT
        trap 'echo parent-term' TERM
        before_int=\$(trap -p INT)
        before_term=\$(trap -p TERM)
        clean_project_artifacts > /dev/null 2>&1 || true
        after_int=\$(trap -p INT)
        after_term=\$(trap -p TERM)
        if [[ \"\$before_int\" == \"\$after_int\" && \"\$before_term\" == \"\$after_term\" ]]; then
            echo 'PASS'
        else
            echo 'FAIL'
            echo \"before_int=\$before_int\"
            echo \"after_int=\$after_int\"
            echo \"before_term=\$before_term\"
            echo \"after_term=\$after_term\"
            exit 1
        fi
    ")

	[[ "$result" == *"PASS"* ]]
}

@test "clean_project_artifacts: handles empty directory gracefully" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"
clean_project_artifacts </dev/null
printf 'PURGE_OUTCOME=%s\n' "$PURGE_RUN_OUTCOME"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"PURGE_OUTCOME=no_candidates"* ]] || return 1
}

@test "clean_project_artifacts: keeps completed roots and reports failed roots" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"

good_root="$HOME/www"
failed_root="$HOME/dev"
good_artifact="$good_root/good-project/node_modules"
failed_artifact="$failed_root/failed-project/node_modules"
mkdir -p "$good_artifact" "$failed_artifact" "$HOME/.cache/mole"
touch "$good_root/good-project/package.json" "$failed_root/failed-project/package.json"

PURGE_SEARCH_PATHS=("$good_root" "$failed_root")
get_optimal_parallel_jobs() { echo 1; }
scan_purge_targets() {
	if [[ "$1" == "$good_root" ]]; then
		printf '%s\n' "$good_artifact" > "$2"
		return 0
	fi
	printf '%s\n' "$failed_artifact" > "$2"
	return 7
}
get_dir_size_kb() { echo 4; }
is_recently_modified() {
	_PURGE_ACTIVITY_STATE=old
	return 1
}
purge_target_activity_still_safe() { return 0; }
safe_remove() {
	printf 'REMOVE:%s\n' "$1"
	return 0
}

export MOLE_DRY_RUN=1
clean_project_artifacts </dev/null
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"Skipped 1 project scan root because scanning did not complete"* ]] || return 1
	[[ "$output" == *"~/dev"* ]] || return 1
	[[ "$output" == *"(status 7)"* ]] || return 1
	[[ "$output" == *"REMOVE:$HOME/www/good-project/node_modules"* ]] || return 1
	[[ "$output" != *"REMOVE:$HOME/dev/failed-project/node_modules"* ]] || return 1
}

@test "purge refills free scan slots and keeps failure status on the correct root" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
for name in slow failed fast; do
    mkdir -p "$HOME/$name/project/node_modules"
    touch "$HOME/$name/project/package.json"
done
PURGE_SEARCH_PATHS=("$HOME/slow" "$HOME/failed" "$HOME/fast")
get_optimal_parallel_jobs() { echo 2; }
scan_purge_targets() {
    printf '%s/project/node_modules\n' "$1" > "$2"
    case "$1" in
        */slow)
            deadline=$((SECONDS + 3))
            until [[ -e "$HOME/fast-started" ]]; do
                [[ $SECONDS -lt $deadline ]] || return 8
                sleep 0.05
            done ;;
        */failed) return 7 ;;
        */fast) touch "$HOME/fast-started" ;;
    esac
}
get_dir_size_kb() { echo 4; }
is_recently_modified() { return 1; }
purge_target_activity_still_safe() { return 0; }
safe_remove() { printf 'REVIEW:%s\n' "$1"; }
MOLE_DRY_RUN=1 clean_project_artifacts </dev/null
EOF
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"REVIEW:$HOME/slow/project/node_modules"* ]] || return 1
	[[ "$output" == *"REVIEW:$HOME/fast/project/node_modules"* ]] || return 1
	[[ "$output" != *"REVIEW:$HOME/failed/project/node_modules"* ]] || return 1
	[[ "$output" == *"~/failed"* && "$output" == *"(status 7)"* ]] || return 1
}

@test "clean_project_artifacts stops launching roots after an interrupted scan" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"

first_root="$HOME/root-1"
second_root="$HOME/root-2"
third_root="$HOME/root-3"
mkdir -p "$first_root" "$second_root" "$third_root" "$HOME/.cache/mole"
PURGE_SEARCH_PATHS=("$first_root" "$second_root" "$third_root")
get_optimal_parallel_jobs() { printf '1\n'; }
scan_purge_targets() {
	: > "$2"
	printf '%s\n' "${1##*/}" >> "$HOME/scanned-roots"
	[[ "$1" == "$first_root" ]] && return 130
	return 0
}

clean_rc=0
clean_project_artifacts </dev/null || clean_rc=$?
printf 'RC=%s SCANNED=%s\n' "$clean_rc" "$(paste -sd, "$HOME/scanned-roots")"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == "RC=130 SCANNED=root-1" ]] || return 1
}

@test "clean_project_artifacts preserves nested candidates merged from overlapping roots" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"

outer_root="$HOME/projects"
inner_root="$outer_root/app"
parent_artifact="$inner_root/node_modules"
nested_artifact="$parent_artifact/package/.cache"
mkdir -p "$nested_artifact" "$HOME/.cache/mole"
touch "$inner_root/package.json"
PURGE_SEARCH_PATHS=("$outer_root" "$inner_root")
get_optimal_parallel_jobs() { echo 1; }
scan_purge_targets() {
	if [[ "$1" == "$outer_root" ]]; then
		printf '%s\n' "$parent_artifact" > "$2"
	else
		printf '%s\n' "$nested_artifact" > "$2"
	fi
}
get_dir_size_kb() { echo 4; }
is_recently_modified() {
	_PURGE_ACTIVITY_STATE=old
	return 1
}
purge_target_activity_still_safe() { return 0; }
safe_remove() { printf 'REMOVE:%s\n' "$1"; }

export MOLE_DRY_RUN=1
clean_project_artifacts </dev/null
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"REMOVE:$HOME/projects/app/node_modules"* ]] || return 1
	[[ "$output" == *"REMOVE:$HOME/projects/app/node_modules/package/.cache"* ]] || return 1
}

@test "clean_project_artifacts binds candidates without probing unrelated roots" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"

unrelated_root="$HOME/unrelated"
owner_root="$HOME/projects"
artifact="$owner_root/app/node_modules"
mkdir -p "$unrelated_root" "$artifact" "$HOME/.cache/mole"
touch "$owner_root/app/package.json"
PURGE_SEARCH_PATHS=("$unrelated_root" "$owner_root")
get_optimal_parallel_jobs() { echo 1; }
scan_purge_targets() {
	: > "$2"
	if [[ "$1" == "$owner_root" ]]; then
		printf '%s\n' "$artifact" > "$2"
	fi
	return 0
}
is_safe_project_artifact_under_root() {
	printf '%s\n' "$2" >> "$HOME/safety-roots"
	[[ "$2" == "$owner_root" ]]
}
get_dir_size_kb() { echo 4; }
is_recently_modified() {
	_PURGE_ACTIVITY_STATE=old
	return 1
}
purge_target_activity_still_safe() { return 0; }
safe_remove() { return 0; }

export MOLE_DRY_RUN=1
clean_project_artifacts </dev/null
if grep -Fx "$unrelated_root" "$HOME/safety-roots"; then
	printf 'UNRELATED_PROBED\n'
	exit 1
fi
owner_calls=$(grep -Fxc "$owner_root" "$HOME/safety-roots")
printf 'OWNER_CALLS=%s\n' "$owner_calls"
[[ "$owner_calls" -ge 1 && "$owner_calls" -le 4 ]]
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"OWNER_CALLS="* ]] || return 1
	[[ "$output" != *"UNRELATED_PROBED"* ]] || return 1
}

@test "clean_project_artifacts: bounds concurrent root scans" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"

first_root="$HOME/www"
second_root="$HOME/dev"
first_artifact="$first_root/first-project/node_modules"
second_artifact="$second_root/second-project/node_modules"
scan_lock="$HOME/scan-active"
mkdir -p "$first_artifact" "$second_artifact" "$HOME/.cache/mole"
touch "$first_root/first-project/package.json" "$second_root/second-project/package.json"

PURGE_SEARCH_PATHS=("$first_root" "$second_root")
get_optimal_parallel_jobs() { echo 1; }
scan_purge_targets() {
	if ! mkdir "$scan_lock" 2>/dev/null; then
		printf 'OVERLAPPING_SCAN\n'
		return 7
	fi
	if [[ "$1" == "$first_root" ]]; then
		printf '%s\n' "$first_artifact" > "$2"
	else
		printf '%s\n' "$second_artifact" > "$2"
	fi
	sleep 0.05
	rmdir "$scan_lock"
}
get_dir_size_kb() { echo 4; }
is_recently_modified() {
	_PURGE_ACTIVITY_STATE=old
	return 1
}
purge_target_activity_still_safe() { return 0; }
safe_remove() { return 0; }

export MOLE_DRY_RUN=1
clean_project_artifacts </dev/null
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" != *"OVERLAPPING_SCAN"* ]] || return 1
	[[ "$output" != *"Skipped 1 project scan root"* ]] || return 1
}

@test "clean_project_artifacts: refuses when every configured root scan fails" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"

failed_root="$HOME/www"
failed_artifact="$failed_root/failed-project/node_modules"
mkdir -p "$failed_artifact" "$HOME/.cache/mole"
touch "$failed_root/failed-project/package.json"

PURGE_SEARCH_PATHS=("$failed_root")
get_optimal_parallel_jobs() { echo 1; }
scan_purge_targets() {
	printf '%s\n' "$failed_artifact" > "$2"
	return 7
}
safe_remove() {
	printf 'UNEXPECTED_REMOVE:%s\n' "$1"
	return 1
}

clean_project_artifacts </dev/null
printf 'PURGE_OUTCOME=%s\n' "$PURGE_RUN_OUTCOME"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"Skipped 1 project scan root because scanning did not complete"* ]] || return 1
	[[ "$output" == *"~/www"* ]] || return 1
	[[ "$output" == *"(status 7)"* ]] || return 1
	[[ "$output" == *"PURGE_OUTCOME=scan_failed"* ]] || return 1
	[[ "$output" != *"Great! No old project artifacts to clean"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_REMOVE:"* ]] || return 1
}

@test "perform_purge: suppresses completion summary for non-completed outcomes" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_SKIP_MAIN=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/purge.sh"

clean_project_artifacts() {
	PURGE_RUN_OUTCOME="cancelled"
	return 0
}
print_summary_block() {
	printf 'UNEXPECTED_SUMMARY\n'
}

perform_purge </dev/null
printf 'PERFORM_RETURNED\n'
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"PERFORM_RETURNED"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_SUMMARY"* ]] || return 1
}

@test "perform_purge: preserves errexit for unexpected cleanup failures" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_SKIP_MAIN=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/purge.sh"

clean_project_artifacts() { return 7; }

perform_purge </dev/null
printf 'UNEXPECTED_CONTINUATION\n'
EOF

	[ "$status" -eq 7 ] || return 1
	[[ "$output" != *"UNEXPECTED_CONTINUATION"* ]] || return 1
}

@test "perform_purge: incomplete cleanup is a failed command, not an empty inventory" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_SKIP_MAIN=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/purge.sh"
clean_project_artifacts() {
    PURGE_RUN_OUTCOME=incomplete
    printf '0\n' > "$HOME/.cache/mole/purge_stats"
    printf '0\n' > "$HOME/.cache/mole/purge_count"
}
perform_purge </dev/null
EOF
	[ "$status" -eq 1 ] || return 1
	[[ "$output" == *"Purge incomplete"* ]] || return 1
	[[ "$output" == *"Some artifacts were skipped or could not be processed"* ]] || return 1
	[[ "$output" != *"No old project artifacts"* ]] || return 1
}

@test "perform_purge: unknown-size successes remain visible in the summary" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_SKIP_MAIN=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/purge.sh"
clean_project_artifacts() {
    PURGE_RUN_OUTCOME=completed
    PURGE_UNKNOWN_SIZE_COUNT=1
    printf '0\n' > "$HOME/.cache/mole/purge_stats"
    printf '1\n' > "$HOME/.cache/mole/purge_count"
}
perform_purge </dev/null
EOF
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"1 unmeasured"* ]] || return 1
	[[ "$output" == *"Items: 1"* ]] || return 1
	[[ "$output" != *"No artifacts were removed"* ]] || return 1
}

@test "clean_project_artifacts: handles empty menu options under set -u" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"

mkdir -p "$HOME/www/test-project/node_modules"
touch "$HOME/www/test-project/package.json"

PURGE_SEARCH_PATHS=("$HOME/www")
get_dir_size_kb() { echo 0; }

clean_project_artifacts </dev/null
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"No artifacts found to purge"* ]]
}

@test "clean_project_artifacts: include-empty exposes zero-size artifacts (#869)" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"

mkdir -p "$HOME/.cache/mole"
echo "0" > "$HOME/.cache/mole/purge_stats"

mkdir -p "$HOME/www/test-project/node_modules"
touch "$HOME/www/test-project/package.json"
touch -t 202001010101 "$HOME/www/test-project/node_modules" "$HOME/www/test-project/package.json" "$HOME/www/test-project"

PURGE_SEARCH_PATHS=("$HOME/www")
get_dir_size_kb() { echo 0; }

export MOLE_PURGE_INCLUDE_EMPTY=1
export MOLE_DRY_RUN=1
clean_project_artifacts </dev/null

stats_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mole"
echo "COUNT=$(cat "$stats_dir/purge_count" 2> /dev/null || echo missing)"
echo "SIZE=$(cat "$stats_dir/purge_stats" 2> /dev/null || echo missing)"
[[ -d "$HOME/www/test-project/node_modules" ]]
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"COUNT=1"* ]] || return 1
	[[ "$output" == *"SIZE=0"* ]]
}

@test "clean_project_artifacts: reports size errors as incomplete instead of an empty inventory" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"

mkdir -p "$HOME/www/test-project/node_modules"
touch "$HOME/www/test-project/package.json"
touch -t 202001010101 "$HOME/www/test-project/node_modules" "$HOME/www/test-project/package.json" "$HOME/www/test-project"

PURGE_SEARCH_PATHS=("$HOME/www")
get_dir_size_kb() { echo ERROR; }

clean_project_artifacts </dev/null
printf 'OUTCOME=%s\n' "$PURGE_RUN_OUTCOME"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Could not measure ~/www/test-project/node_modules; skipped"* ]] || return 1
	[[ "$output" == *"OUTCOME=incomplete"* ]] || return 1
	[[ "$output" != *"No artifacts found to purge"* ]] || return 1
}

@test "clean_project_artifacts: preparation does not exhaust the activity evidence budget" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
artifact="$HOME/www/old-project/node_modules"
mkdir -p "$artifact"
printf 'payload\n' > "$artifact/file"
touch "$HOME/www/old-project/package.json"
touch -t 202001010101 "$artifact" "$artifact/file"
PURGE_SEARCH_PATHS=("$HOME/www")
fake_now=$(date +%s)
get_epoch_seconds() { printf '%s\n' "$fake_now"; }
eval "$(declare -f _mole_path_matches_identity | sed '1s/_mole_path_matches_identity/_original_path_matches_identity/')"
_mole_path_matches_identity() {
    fake_now=$((fake_now + 100))
    _original_path_matches_identity "$@"
}
safe_remove() { printf 'DEFAULT_SELECTED:%s\n' "$1"; }
MOLE_DRY_RUN=1 clean_project_artifacts </dev/null
EOF
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"DEFAULT_SELECTED:$HOME/www/old-project/node_modules"* ]] || return 1
}

@test "clean_project_artifacts: removal cancellation stops the next eligible artifact" {
	for cancellation_status in 124 130; do
		run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" CANCELLATION_STATUS="$cancellation_status" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
for project in first second; do
    artifact="$HOME/www/$project/node_modules"
    mkdir -p "$artifact"
    printf 'payload\n' > "$artifact/file"
    touch "$HOME/www/$project/package.json"
    touch -t 202001010101 "$artifact" "$artifact/file"
done
PURGE_SEARCH_PATHS=("$HOME/www")
export MOLE_DRY_RUN=1
safe_remove() {
    printf 'REMOVE:%s\n' "$1"
    case "$1" in
        */first/node_modules) return "$CANCELLATION_STATUS" ;;
        *) printf 'UNEXPECTED_SECOND_REMOVAL\n'; return 0 ;;
    esac
}
set +e
clean_project_artifacts </dev/null
result=$?
printf 'OUTCOME=%s\n' "$PURGE_RUN_OUTCOME"
exit "$result"
EOF
		[ "$status" -eq "$cancellation_status" ] || return 1
		[[ "$output" == *"REMOVE:$HOME/www/first/node_modules"* ]] || return 1
		[[ "$output" == *"OUTCOME=cancelled"* ]] || return 1
		[[ "$output" != *"UNEXPECTED_SECOND_REMOVAL"* ]] || return 1
	done
}

@test "clean_project_artifacts: final activity cancellation stops before any removal" {
	for cancellation_status in 124 130; do
		run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" CANCELLATION_STATUS="$cancellation_status" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
for project in first second; do
    artifact="$HOME/www/$project/node_modules"
    mkdir -p "$artifact"
    printf 'payload\n' > "$artifact/file"
    touch "$HOME/www/$project/package.json"
    touch -t 202001010101 "$artifact" "$artifact/file"
done
PURGE_SEARCH_PATHS=("$HOME/www")
export MOLE_DRY_RUN=1
purge_target_activity_still_safe() { return "$CANCELLATION_STATUS"; }
safe_remove() {
    printf 'REMOVE:%s\n' "$1"
    case "$1" in
        */first/node_modules) return "$CANCELLATION_STATUS" ;;
        *) printf 'UNEXPECTED_SECOND_REMOVAL\n'; return 0 ;;
    esac
}
set +e
clean_project_artifacts </dev/null
result=$?
printf 'OUTCOME=%s\n' "$PURGE_RUN_OUTCOME"
exit "$result"
EOF
		[ "$status" -eq "$cancellation_status" ] || return 1
		[[ "$output" != *"REMOVE:"* ]] || return 1
		[[ "$output" == *"OUTCOME=cancelled"* ]] || return 1
		[[ "$output" != *"UNEXPECTED_SECOND_REMOVAL"* ]] || return 1
	done
}

@test "clean_project_artifacts: manually selected uncertain activity never reaches removal" {
	local script_file
	script_file=$(mktemp "$HOME/uncertain_selection.XXXXXX.sh")

	cat > "$script_file" <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
artifact="$HOME/www/uncertain-project/node_modules"
mkdir -p "$artifact" "$HOME/.cache/mole"
printf 'payload\n' > "$artifact/file"
touch "$HOME/www/uncertain-project/package.json"
touch -t 202001010101 "$artifact" "$artifact/file"
PURGE_SEARCH_PATHS=("$HOME/www")
get_dir_size_kb() { echo 1; }
is_recently_modified() {
    _PURGE_ACTIVITY_STATE=uncertain
    return 124
}
select_purge_categories() {
    PURGE_SELECTION_RESULT=0
    return 0
}
confirm_purge_cleanup() { return 0; }
safe_remove() {
    printf 'UNEXPECTED_REMOVE:%s\n' "$1"
    return 0
}
set +e
clean_project_artifacts
result=$?
set -e
printf 'RESULT=%s OUTCOME=%s\n' "$result" "$PURGE_RUN_OUTCOME"
SCRIPT

	run _run_in_pty "$script_file"
	rm -f "$script_file"

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"RESULT=124 OUTCOME=cancelled"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_REMOVE:"* ]]
}

@test "clean_project_artifacts: dry-run does not count failed removals" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"

mkdir -p "$HOME/.cache/mole"
echo "0" > "$HOME/.cache/mole/purge_stats"
# purge_count must be seeded too: without it this reads a previous test's file
# through the shared HOME, or reports "missing" when run alone.
echo "0" > "$HOME/.cache/mole/purge_count"

mkdir -p "$HOME/www/test-project/node_modules"
echo "test data" > "$HOME/www/test-project/node_modules/file.js"
touch "$HOME/www/test-project/package.json"
# The contained file has to be aged as well. Recency is judged from the newest
# entry inside the artifact, so a fresh file.js marks the whole node_modules as
# recent, the non-interactive branch skips it, and the failed-removal path this
# test exists for is never reached.
touch -t 202001010101 "$HOME/www/test-project/node_modules/file.js" \
    "$HOME/www/test-project/node_modules" "$HOME/www/test-project/package.json" "$HOME/www/test-project"

PURGE_SEARCH_PATHS=("$HOME/www")
safe_remove() { return 1; }

export MOLE_DRY_RUN=1
clean_project_artifacts

stats_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mole"
echo "COUNT=$(cat "$stats_dir/purge_count" 2> /dev/null || echo missing)"
echo "SIZE=$(cat "$stats_dir/purge_stats" 2> /dev/null || echo missing)"
[[ -d "$HOME/www/test-project/node_modules" ]]
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Skipped ~/www/test-project/node_modules (final removal check failed; re-run mo purge to review it again)"* ]] || return 1
	[[ "$output" == *"COUNT=0"* ]] || return 1
	[[ "$output" == *"SIZE=0"* ]]
}

@test "clean_project_artifacts accepts configured artifacts outside HOME (#1205)" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"

external_root="$BATS_TEST_TMPDIR/var-www"
artifact="$external_root/site/node_modules"
mkdir -p "$artifact" "$HOME/.cache/mole"
touch "$external_root/site/package.json"

PURGE_SEARCH_PATHS=("$external_root")
scan_purge_targets() { printf '%s\n' "$artifact" > "$2"; }
get_dir_size_kb() { echo 1; }
is_recently_modified() { return 1; }
safe_remove() {
    printf 'REMOVE:%s\n' "$1"
    return 0
}

export MOLE_DRY_RUN=1
clean_project_artifacts </dev/null
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"REMOVE:$BATS_TEST_TMPDIR/var-www/site/node_modules"* ]]
}

@test "clean_project_artifacts refuses a candidate reached through a replaced configured root" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"

configured_root="$HOME/www"
original_root="$HOME/www-original"
redirected_root="$HOME/redirected"
artifact="$configured_root/project/node_modules"
redirected_artifact="$redirected_root/project/node_modules"
mkdir -p "$artifact" "$redirected_artifact" "$HOME/.cache/mole"
touch "$configured_root/project/package.json" "$redirected_root/project/package.json"

PURGE_SEARCH_PATHS=("$configured_root")
scan_purge_targets() { printf '%s\n' "$artifact" > "$2"; }
get_dir_size_kb() { echo 1; }
is_recently_modified() {
	_PURGE_ACTIVITY_STATE=old
	return 1
}
purge_target_activity_still_safe() {
	mv "$configured_root" "$original_root"
	ln -s "$redirected_root" "$configured_root"
	return 0
}

clean_project_artifacts </dev/null

original_preserved=false
redirected_preserved=false
[[ -d "$original_root/project/node_modules" ]] && original_preserved=true
[[ -d "$redirected_artifact" ]] && redirected_preserved=true
rm "$configured_root"
mv "$original_root" "$configured_root"
rm -rf "$redirected_root"
[[ "$original_preserved" == "true" ]] || exit 1
[[ "$redirected_preserved" == "true" ]] || exit 1
EOF

	[ "$status" -eq 0 ] || return 1
}

@test "clean_project_artifacts rejects results when a symlink root target is replaced" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"

configured_root="$HOME/www"
physical_root="$HOME/www-target"
original_root="$HOME/www-original"
artifact="$configured_root/project/node_modules"
mkdir -p "$physical_root/project/node_modules" "$HOME/.cache/mole"
touch "$physical_root/project/package.json"
/bin/rmdir "$configured_root"
ln -s "$physical_root" "$configured_root"

PURGE_SEARCH_PATHS=("$configured_root")
scan_purge_targets() {
	printf '%s\n' "$artifact" > "$2"
	mv "$physical_root" "$original_root"
	mkdir -p "$physical_root/project/node_modules"
	touch "$physical_root/project/package.json"
}
safe_remove() {
	printf 'UNEXPECTED_REMOVE:%s\n' "$1"
	return 1
}

clean_project_artifacts </dev/null

[[ -L "$configured_root" ]] || exit 1
[[ -d "$original_root/project/node_modules" ]] || exit 1
[[ -d "$physical_root/project/node_modules" ]] || exit 1
/bin/rm "$configured_root"
mv "$physical_root" "$configured_root"
/bin/rm -rf "$original_root"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"Skipped 1 project scan root because scanning did not complete"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_REMOVE:"* ]] || return 1
}

@test "clean_project_artifacts refuses a replacement at the selected artifact leaf" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"

configured_root="$HOME/www"
artifact="$configured_root/project/node_modules"
original_artifact="$configured_root/project/node_modules-original"
replacement="$HOME/replacement-node-modules"
mkdir -p "$artifact" "$replacement" "$HOME/.cache/mole"
touch "$configured_root/project/package.json"

PURGE_SEARCH_PATHS=("$configured_root")
scan_purge_targets() { printf '%s\n' "$artifact" > "$2"; }
get_dir_size_kb() { echo 1; }
is_recently_modified() {
	_PURGE_ACTIVITY_STATE=old
	return 1
}
purge_target_activity_still_safe() {
	mv "$artifact" "$original_artifact"
	mv "$replacement" "$artifact"
	return 0
}

clean_project_artifacts </dev/null

[[ -d "$original_artifact" ]] || exit 1
[[ -d "$artifact" ]] || exit 1
EOF

	[ "$status" -eq 0 ] || return 1
}

@test "clean_project_artifacts rechecks identity after the final activity probe" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"

configured_root="$HOME/www"
artifact="$configured_root/project/node_modules"
original_artifact="$configured_root/project/node_modules-original"
replacement="$HOME/replacement-node-modules"
mkdir -p "$artifact" "$replacement" "$HOME/.cache/mole"
touch "$configured_root/project/package.json"

PURGE_SEARCH_PATHS=("$configured_root")
scan_purge_targets() { printf '%s\n' "$artifact" > "$2"; }
get_dir_size_kb() { echo 1; }
is_recently_modified() {
	_PURGE_ACTIVITY_STATE=old
	return 1
}
activity_calls=0
rm_trace="$HOME/target-rm-reached"
purge_target_activity_still_safe() {
	activity_calls=$((activity_calls + 1))
	if [[ $activity_calls -eq 2 ]]; then
		mv "$artifact" "$original_artifact"
		mv "$replacement" "$artifact"
	fi
	return 0
}
rm() {
	if [[ "$*" == *"$artifact"* ]]; then
		printf 'TARGET_RM_REACHED:%s\n' "$*" > "$rm_trace"
		return 0
	fi
	command /bin/rm "$@"
}

clean_project_artifacts </dev/null

printf 'ACTIVITY_CALLS=%s\n' "$activity_calls"
[[ -d "$original_artifact" ]] || exit 1
[[ -d "$artifact" ]] || exit 1
[[ ! -e "$rm_trace" ]] || exit 1
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"ACTIVITY_CALLS=2"* ]] || return 1
}

@test "clean_project_artifacts: non-interactive dry-run shows cloud marker and preserves artifact" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"

cloud_root="$HOME/Library/CloudStorage"
cloud_artifact="$cloud_root/TestProvider/SampleProject/target"
mkdir -p "$cloud_artifact" "$HOME/.cache/mole"
touch "$cloud_root/TestProvider/SampleProject/Cargo.toml"

PURGE_SEARCH_PATHS=("$cloud_root")
scan_purge_targets() { printf '%s\n' "$cloud_artifact" > "$2"; }
get_dir_size_kb() { echo 4; }
is_recently_modified() {
	_PURGE_ACTIVITY_STATE=old
	return 1
}
purge_target_activity_still_safe() { return 0; }
safe_remove() {
	printf 'REMOVE:%s\n' "$1"
	return 0
}

export MOLE_DRY_RUN=1
clean_project_artifacts </dev/null

[[ -d "$cloud_artifact" ]] || exit 1
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"REMOVE:$HOME/Library/CloudStorage/TestProvider/SampleProject/target"* ]] || return 1
	[[ "$output" == *"[cloud] ~/Library/CloudStorage/TestProvider/SampleProject/target"* ]] || return 1
	[[ "$output" == *"4KB"* ]] || return 1
}

@test "clean_project_artifacts: non-interactive real run skips cloud and keeps local selection aligned after sorting" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"

cloud_root="$HOME/Library/CloudStorage"
cloud_artifact="$cloud_root/TestProvider/CloudProject/target"
local_root="$HOME/www"
local_artifact="$local_root/LocalProject/node_modules"
mkdir -p "$cloud_artifact" "$local_artifact" "$HOME/.cache/mole"
touch "$cloud_root/TestProvider/CloudProject/Cargo.toml"
touch "$local_root/LocalProject/package.json"

PURGE_SEARCH_PATHS=("$cloud_root" "$local_root")
scan_purge_targets() {
	case "$1" in
		"$cloud_root") printf '%s\n' "$cloud_artifact" > "$2" ;;
		"$local_root") printf '%s\n' "$local_artifact" > "$2" ;;
	esac
}
get_dir_size_kb() {
	case "$1" in
		"$cloud_artifact") echo 4 ;;
		"$local_artifact") echo 8 ;;
	esac
}
is_recently_modified() {
	_PURGE_ACTIVITY_STATE=old
	return 1
}
purge_target_activity_still_safe() { return 0; }
safe_remove() {
	printf 'REMOVE:%s\n' "$1"
	return 0
}

unset MOLE_DRY_RUN
clean_project_artifacts </dev/null
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"Skipped 1 cloud-synced artifact in non-interactive mode"* ]] || return 1
	[[ "$output" == *"REMOVE:$HOME/www/LocalProject/node_modules"* ]] || return 1
	[[ "$output" != *"REMOVE:$HOME/Library/CloudStorage/TestProvider/CloudProject/target"* ]] || return 1
}

@test "clean_project_artifacts: scans and finds artifacts" {
	if ! command -v gtimeout >/dev/null 2>&1 && ! command -v timeout >/dev/null 2>&1; then
		skip "gtimeout/timeout not available"
	fi

	mkdir -p "$HOME/www/test-project/node_modules/package1"
	echo "test data" >"$HOME/www/test-project/node_modules/package1/index.js"

	mkdir -p "$HOME/www/test-project"

	timeout_cmd="timeout"
	command -v timeout >/dev/null 2>&1 || timeout_cmd="gtimeout"

	run /bin/bash -c "
        export HOME='$HOME'
        exec $timeout_cmd 5 '$PROJECT_ROOT/bin/purge.sh' 2>&1 < /dev/null
    "

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"Purge Project Artifacts"* ]] || return 1
	[[ "$output" == *"No items selected"* ]] ||
		[[ "$output" == *"Purge complete"* ]] ||
		[[ "$output" == *"No old"* ]] ||
		[[ "$output" == *"Great"* ]] || return 1
}

@test "mo purge: command exists and is executable" {
	[ -x "$PROJECT_ROOT/mole" ]
	[ -f "$PROJECT_ROOT/bin/purge.sh" ]
}

@test "mo purge: shows in help text" {
	run env HOME="$HOME" "$PROJECT_ROOT/mole" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"mo purge"* ]]
}

@test "mo purge --help includes include-empty option" {
	run env HOME="$HOME" "$PROJECT_ROOT/mole" purge --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"--include-empty"* ]] || return 1
	[[ "$output" == *"Show zero-size project artifact directories"* ]]
}

@test "mo purge: accepts --debug flag" {
	if ! command -v gtimeout >/dev/null 2>&1 && ! command -v timeout >/dev/null 2>&1; then
		skip "gtimeout/timeout not available"
	fi

	timeout_cmd="timeout"
	command -v timeout >/dev/null 2>&1 || timeout_cmd="gtimeout"

	run /bin/bash -c "
        export HOME='$HOME'
        $timeout_cmd 10 '$PROJECT_ROOT/mole' purge --debug < /dev/null 2>&1 || true
    "
	true
}

@test "mo purge: accepts --dry-run flag" {
	if ! command -v gtimeout >/dev/null 2>&1 && ! command -v timeout >/dev/null 2>&1; then
		skip "gtimeout/timeout not available"
	fi

	timeout_cmd="timeout"
	command -v timeout >/dev/null 2>&1 || timeout_cmd="gtimeout"

	run /bin/bash -c "
        export HOME='$HOME'
        $timeout_cmd 10 '$PROJECT_ROOT/mole' purge --dry-run < /dev/null 2>&1 || true
    "

	[[ "$output" == *"DRY RUN MODE"* ]] || [[ "$output" == *"Dry run complete"* ]]
}

@test "mo purge: accepts --include-empty flag" {
	if ! command -v gtimeout >/dev/null 2>&1 && ! command -v timeout >/dev/null 2>&1; then
		skip "gtimeout/timeout not available"
	fi

	timeout_cmd="timeout"
	command -v timeout >/dev/null 2>&1 || timeout_cmd="gtimeout"

	run /bin/bash -c "
        export HOME='$HOME'
        $timeout_cmd 10 '$PROJECT_ROOT/mole' purge --include-empty --dry-run < /dev/null 2>&1
    "

	[ "$status" -eq 0 ] || [ "$status" -eq 2 ]
	[[ "$output" != *"Unknown option"* ]]
}

@test "mo purge: creates cache directory for stats" {
	if ! command -v gtimeout >/dev/null 2>&1 && ! command -v timeout >/dev/null 2>&1; then
		skip "gtimeout/timeout not available"
	fi

	timeout_cmd="timeout"
	command -v timeout >/dev/null 2>&1 || timeout_cmd="gtimeout"

	/bin/bash -c "
        export HOME='$HOME'
        $timeout_cmd 10 '$PROJECT_ROOT/mole' purge < /dev/null 2>&1 || true
    "

	[ -d "$HOME/.cache/mole" ] || [ -d "${XDG_CACHE_HOME:-$HOME/.cache}/mole" ]
}

@test "mo purge skips whitelisted project artifacts (#1427)" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail

protected="$HOME/www/protected/node_modules"
unprotected="$HOME/www/unprotected/node_modules"
mkdir -p "$protected" "$unprotected" "$HOME/.config/mole" "$HOME/.cache/mole"
printf 'keep\n' > "$protected/keep.js"
printf 'remove\n' > "$unprotected/remove.js"
touch "$HOME/www/protected/package.json" "$HOME/www/unprotected/package.json"
touch -t 202001010101 \
    "$protected/keep.js" "$protected" "$HOME/www/protected/package.json" "$HOME/www/protected" \
    "$unprotected/remove.js" "$unprotected" "$HOME/www/unprotected/package.json" "$HOME/www/unprotected"
printf '%s\n' "$protected" > "$HOME/.config/mole/whitelist"

export MOLE_SKIP_MAIN=1
export MOLE_TEST_NO_AUTH=1
source "$PROJECT_ROOT/bin/purge.sh"
PURGE_SEARCH_PATHS=("$HOME/www")
scan_purge_targets() {
    printf '%s\n' "$protected" "$unprotected" > "$2"
}
get_dir_size_kb() {
    [[ "$1" == "$protected" ]] && touch "$HOME/unexpected-protected-size"
    echo 1
}
get_file_mtime() { echo 1577836800; }
is_recently_modified() { return 1; }
purge_target_activity_still_safe() { return 0; }

start_purge
clean_project_artifacts </dev/null

protected_loaded=false
for pattern in "${WHITELIST_PATTERNS[@]}"; do
    if [[ "$pattern" == "$protected" ]]; then
        protected_loaded=true
        break
    fi
done
[[ "$protected_loaded" == "true" ]] || exit 1
[[ ! -e "$HOME/unexpected-protected-size" ]] || exit 1
[[ -d "$protected" ]] || exit 1
[[ ! -e "$unprotected" ]] || exit 1
EOF

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# .NET bin directory detection tests
@test "is_dotnet_bin_dir: finds .NET context in parent directory with Debug dir" {
	mkdir -p "$HOME/www/dotnet-app/bin/Debug"
	touch "$HOME/www/dotnet-app/MyProject.csproj"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        if is_dotnet_bin_dir '$HOME/www/dotnet-app/bin'; then
            echo 'FOUND'
        else
            echo 'NOT_FOUND'
        fi
    ")

	[[ "$result" == "FOUND" ]]
}

@test "is_dotnet_bin_dir: requires .csproj AND Debug/Release" {
	mkdir -p "$HOME/www/dotnet-app/bin"
	touch "$HOME/www/dotnet-app/MyProject.csproj"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        if is_dotnet_bin_dir '$HOME/www/dotnet-app/bin'; then
            echo 'FOUND'
        else
            echo 'NOT_FOUND'
        fi
    ")

	# Should not find it because Debug/Release directories don't exist
	[[ "$result" == "NOT_FOUND" ]]
}

@test "is_dotnet_bin_dir: rejects non-bin directories" {
	mkdir -p "$HOME/www/dotnet-app/obj"
	touch "$HOME/www/dotnet-app/MyProject.csproj"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        if is_dotnet_bin_dir '$HOME/www/dotnet-app/obj'; then
            echo 'FOUND'
        else
            echo 'NOT_FOUND'
        fi
    ")
	[[ "$result" == "NOT_FOUND" ]]
}

# Integration test for bin scanning
@test "scan_purge_targets: includes .NET bin directories with Debug/Release" {
	mkdir -p "$HOME/www/dotnet-app/bin/Debug"
	touch "$HOME/www/dotnet-app/MyProject.csproj"

	local scan_output
	scan_output="$(mktemp)"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        scan_purge_targets '$HOME/www' '$scan_output'
        if grep -q '$HOME/www/dotnet-app/bin' '$scan_output'; then
            echo 'FOUND'
        else
            echo 'MISSING'
        fi
    ")

	rm -f "$scan_output"

	[[ "$result" == "FOUND" ]]
}

@test "scan_purge_targets: skips generic bin directories (non-.NET)" {
	mkdir -p "$HOME/www/ruby-app/bin"
	touch "$HOME/www/ruby-app/Gemfile"

	local scan_output
	scan_output="$(mktemp)"

	result=$(/bin/bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        scan_purge_targets '$HOME/www' '$scan_output'
        if grep -q '$HOME/www/ruby-app/bin' '$scan_output'; then
            echo 'FOUND'
        else
            echo 'SKIPPED'
        fi
    ")

	rm -f "$scan_output"
	[[ "$result" == "SKIPPED" ]]
}

# ---------------------------------------------------------------------------
# Regression tests: sort-order consistency in clean_project_artifacts
#
# Bug: after sorting artifacts by size (descending), item_display_paths was
# not included in the reorder, so PURGE_CATEGORY_FULL_PATHS_ARRAY ended up
# in the original discovery order (alphabetical) while every other parallel
# array (menu_options, item_paths, item_sizes, …) was in size order.
# Effect: the "Full path" footer showed the wrong project for the highlighted
# item, and the confirmation dialog listed paths that did not match the
# selection. See https://github.com/tw93/Mole/issues/647
#
# These tests run clean_project_artifacts under a pseudo-terminal (so the
# interactive code path is taken and select_purge_categories is called).
# The function is overridden to capture PURGE_CATEGORY_FULL_PATHS_ARRAY and
# PURGE_CATEGORY_SIZES without performing any actual deletion.
# ---------------------------------------------------------------------------

# Run a bash script file under a pseudo-terminal so that [[ -t 0 ]] is true
# inside the script. Required to exercise the interactive branch of
# clean_project_artifacts, which only calls select_purge_categories when
# stdin is a tty.
_run_in_pty() {
	local script_file="$1"
	# A socket-backed runner stdin makes macOS script(1) fail before the child starts.
	script -q /dev/null /bin/bash --noprofile --norc "$script_file" < /dev/null 2>/dev/null
}

@test "sort: PURGE_CATEGORY_FULL_PATHS_ARRAY[0] is the largest artifact after size-descending sort" {
	# alpha = small (~5 KB), beta = large (~200 KB).
	# Alphabetical discovery order puts alpha first; size order puts beta first.
	# After the sort, PURGE_CATEGORY_FULL_PATHS_ARRAY[0] must be beta's path.
	mkdir -p "$HOME/www/alpha/node_modules"
	mkdir -p "$HOME/www/beta/node_modules"
	echo '{}' > "$HOME/www/alpha/package.json"
	echo '{}' > "$HOME/www/beta/package.json"
	dd if=/dev/zero of="$HOME/www/alpha/node_modules/data" bs=1024 count=5   2>/dev/null
	dd if=/dev/zero of="$HOME/www/beta/node_modules/data"  bs=1024 count=200 2>/dev/null

	local capture_file script_file
	capture_file=$(mktemp "$HOME/sort_capture.XXXXXX")
	script_file=$(mktemp  "$HOME/sort_script.XXXXXX.sh")

	cat > "$script_file" << SCRIPT
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
mkdir -p "$HOME/.cache/mole"
export XDG_CACHE_HOME="$HOME/.cache"
export TERM="dumb"
PURGE_SEARCH_PATHS=("$HOME/www")

# Override the interactive selector: dump the full-path array to the capture
# file then cancel (return 1) so nothing is deleted.
select_purge_categories() {
	printf '%s\n' "\${PURGE_CATEGORY_FULL_PATHS_ARRAY[@]}" > "$capture_file"
	PURGE_SELECTION_RESULT=""
	return 1
}

clean_project_artifacts 2>/dev/null || true
SCRIPT

	_run_in_pty "$script_file"
	rm -f "$script_file"

	if [[ ! -s "$capture_file" ]]; then
		rm -f "$capture_file"
		fail "capture file is empty – select_purge_categories was never called (stdin was not a tty?)"
	fi

	local first_path
	first_path=$(head -1 "$capture_file")
	rm -f "$capture_file"

	# With the bug item_display_paths is not sorted, so alpha (alphabetically
	# first) appears at index 0 → [[ ... == *beta* ]] fails.
	# After the fix beta (largest) is at index 0 → test passes.
	[[ "$first_path" == *"beta"* ]]
}

@test "sort: PURGE_CATEGORY_FULL_PATHS_ARRAY and PURGE_CATEGORY_SIZES indices are consistent" {
	mkdir -p "$HOME/www/alpha/node_modules"
	mkdir -p "$HOME/www/beta/node_modules"
	echo '{}' > "$HOME/www/alpha/package.json"
	echo '{}' > "$HOME/www/beta/package.json"
	dd if=/dev/zero of="$HOME/www/alpha/node_modules/data" bs=1024 count=5   2>/dev/null
	dd if=/dev/zero of="$HOME/www/beta/node_modules/data"  bs=1024 count=200 2>/dev/null

	local capture_file script_file
	capture_file=$(mktemp "$HOME/sort_capture.XXXXXX")
	script_file=$(mktemp  "$HOME/sort_script.XXXXXX.sh")

	cat > "$script_file" << SCRIPT
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
mkdir -p "$HOME/.cache/mole"
export XDG_CACHE_HOME="$HOME/.cache"
export TERM="dumb"
PURGE_SEARCH_PATHS=("$HOME/www")

select_purge_categories() {
	echo "SIZES=\${PURGE_CATEGORY_SIZES:-}" > "$capture_file"
	local i=0
	for p in "\${PURGE_CATEGORY_FULL_PATHS_ARRAY[@]}"; do
		echo "PATH[\$i]=\$p" >> "$capture_file"
		i=\$((i + 1))
	done
	i=0
	for project_id in "\${PURGE_CATEGORY_PROJECT_IDS_ARRAY[@]}"; do
		echo "PROJECT_ID[\$i]=\$project_id" >> "$capture_file"
		i=\$((i + 1))
	done
	i=0
	for project_path in "\${PURGE_CATEGORY_PROJECT_PATHS_ARRAY[@]}"; do
		echo "PROJECT_PATH[\$i]=\$project_path" >> "$capture_file"
		i=\$((i + 1))
	done
	PURGE_SELECTION_RESULT=""
	return 1
}

clean_project_artifacts 2>/dev/null || true
SCRIPT

	_run_in_pty "$script_file"
	rm -f "$script_file"

	if [[ ! -s "$capture_file" ]]; then
		rm -f "$capture_file"
		fail "capture file is empty – select_purge_categories was never called (stdin was not a tty?)"
	fi

	local sizes_csv
	sizes_csv=$(grep '^SIZES=' "$capture_file" | cut -d= -f2-)
	IFS=',' read -r -a sizes <<< "$sizes_csv"

	local path0 path1 project_id0 project_path0 expected_project_id0
	path0=$(grep '^PATH\[0\]=' "$capture_file" | head -1 | cut -d= -f2-)
	path1=$(grep '^PATH\[1\]=' "$capture_file" | head -1 | cut -d= -f2-)
	project_id0=$(grep '^PROJECT_ID\[0\]=' "$capture_file" | head -1 | cut -d= -f2-)
	project_path0=$(grep '^PROJECT_PATH\[0\]=' "$capture_file" | head -1 | cut -d= -f2-)
	rm -f "$capture_file"
	expected_project_id0=$(/bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; mole_path_identity '$HOME/www/beta'")

	# PURGE_CATEGORY_SIZES must be sorted descending (largest first).
	[ "${sizes[0]}" -gt "${sizes[1]}" ]

	# Index 0 → largest artifact → beta's path.
	# With the bug path0 = alpha (discovery order) → [[ ... == *beta* ]] fails.
	[[ "$path0" == *"beta"* ]] || return 1
	[ "$project_id0" = "$expected_project_id0" ] || return 1
	[[ "$project_path0" == *"beta"* ]] || return 1

	# Index 1 → smaller artifact → alpha's path.
	[[ "$path1" == *"alpha"* ]]
}

@test "sort: project groups use aggregate size before artifact size" {
	mkdir -p "$HOME/www/alpha/node_modules" "$HOME/www/alpha/.venv"
	mkdir -p "$HOME/www/beta/node_modules"
	echo '{}' > "$HOME/www/alpha/package.json"
	echo '{}' > "$HOME/www/beta/package.json"
	dd if=/dev/zero of="$HOME/www/alpha/node_modules/data" bs=1024 count=130 2>/dev/null
	dd if=/dev/zero of="$HOME/www/alpha/.venv/data" bs=1024 count=110 2>/dev/null
	dd if=/dev/zero of="$HOME/www/beta/node_modules/data" bs=1024 count=200 2>/dev/null

	local capture_file script_file
	capture_file=$(mktemp "$HOME/group_sort_capture.XXXXXX")
	script_file=$(mktemp "$HOME/group_sort_script.XXXXXX.sh")

	cat > "$script_file" << SCRIPT
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
mkdir -p "$HOME/.cache/mole"
export XDG_CACHE_HOME="$HOME/.cache"
export TERM="dumb"
PURGE_SEARCH_PATHS=("$HOME/www")

select_purge_categories() {
	local i=0
	for path in "\${PURGE_CATEGORY_FULL_PATHS_ARRAY[@]}"; do
		echo "PATH[\$i]=\$path" >> "$capture_file"
		i=\$((i + 1))
	done
	PURGE_SELECTION_RESULT=""
	return 1
}

clean_project_artifacts 2>/dev/null
SCRIPT

	_run_in_pty "$script_file"
	rm -f "$script_file"

	[ "$(grep -c '^PATH\[' "$capture_file")" -eq 3 ] || return 1
	local path0 path1 path2
	path0=$(grep '^PATH\[0\]=' "$capture_file" | cut -d= -f2-)
	path1=$(grep '^PATH\[1\]=' "$capture_file" | cut -d= -f2-)
	path2=$(grep '^PATH\[2\]=' "$capture_file" | cut -d= -f2-)
	rm -f "$capture_file"

	[[ "$path0" == *"alpha/node_modules"* ]] || return 1
	[[ "$path1" == *"alpha/.venv"* ]] || return 1
	[[ "$path2" == *"beta/node_modules"* ]] || return 1
}

@test "grouping: indicator-less sibling artifacts share their exact parent" {
	mkdir -p "$HOME/www/unmarked/node_modules" "$HOME/www/unmarked/dist"
	dd if=/dev/zero of="$HOME/www/unmarked/node_modules/data" bs=1024 count=5 2>/dev/null
	dd if=/dev/zero of="$HOME/www/unmarked/dist/data" bs=1024 count=4 2>/dev/null

	local capture_file script_file
	capture_file=$(mktemp "$HOME/fallback_group_capture.XXXXXX")
	script_file=$(mktemp "$HOME/fallback_group_script.XXXXXX.sh")

	cat > "$script_file" << SCRIPT
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
mkdir -p "$HOME/.cache/mole"
export XDG_CACHE_HOME="$HOME/.cache"
export TERM="dumb"
PURGE_SEARCH_PATHS=("$HOME/www")

select_purge_categories() {
	local i=0
	for project_id in "\${PURGE_CATEGORY_PROJECT_IDS_ARRAY[@]}"; do
		echo "PROJECT_ID[\$i]=\$project_id" >> "$capture_file"
		i=\$((i + 1))
	done
	i=0
	for project_path in "\${PURGE_CATEGORY_PROJECT_PATHS_ARRAY[@]}"; do
		echo "PROJECT_PATH[\$i]=\$project_path" >> "$capture_file"
		i=\$((i + 1))
	done
	PURGE_SELECTION_RESULT=""
	return 1
}

clean_project_artifacts 2>/dev/null
SCRIPT

	_run_in_pty "$script_file"
	rm -f "$script_file"

	[ "$(grep -c '^PROJECT_ID\[' "$capture_file")" -eq 2 ] || return 1
	local project_id0 project_id1 project_path0 project_path1 expected_project_id expected_project_path
	project_id0=$(grep '^PROJECT_ID\[0\]=' "$capture_file" | cut -d= -f2-)
	project_id1=$(grep '^PROJECT_ID\[1\]=' "$capture_file" | cut -d= -f2-)
	project_path0=$(grep '^PROJECT_PATH\[0\]=' "$capture_file" | cut -d= -f2-)
	project_path1=$(grep '^PROJECT_PATH\[1\]=' "$capture_file" | cut -d= -f2-)
	rm -f "$capture_file"
	expected_project_id=$(/bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; mole_path_identity '$HOME/www/unmarked'")
	printf -v expected_project_path '~%s' '/www/unmarked'

	[ "$project_id0" = "$expected_project_id" ] || return 1
	[ "$project_id1" = "$expected_project_id" ] || return 1
	[ "$project_path0" = "$expected_project_path" ] || return 1
	[ "$project_path1" = "$expected_project_path" ] || return 1
}

@test "sort: cloud marker stays aligned across menu and full-path arrays" {
	mkdir -p "$HOME/www/local-project/node_modules"
	mkdir -p "$HOME/Library/CloudStorage/TestProvider/cloud-project/node_modules"
	echo '{}' > "$HOME/www/local-project/package.json"
	echo '{}' > "$HOME/Library/CloudStorage/TestProvider/cloud-project/package.json"
	dd if=/dev/zero of="$HOME/www/local-project/node_modules/data" bs=1024 count=200 2>/dev/null
	dd if=/dev/zero of="$HOME/Library/CloudStorage/TestProvider/cloud-project/node_modules/data" bs=1024 count=5 2>/dev/null

	local capture_file script_file
	capture_file=$(mktemp "$HOME/sort_cloud_capture.XXXXXX")
	script_file=$(mktemp "$HOME/sort_cloud_script.XXXXXX.sh")

	cat > "$script_file" << SCRIPT
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
mkdir -p "$HOME/.cache/mole"
export XDG_CACHE_HOME="$HOME/.cache"
export TERM="dumb"
PURGE_SEARCH_PATHS=("$HOME/www" "$HOME/Library/CloudStorage")

select_purge_categories() {
	local i=0
	for option in "\${PURGE_CATEGORY_PROJECT_PATHS_ARRAY[@]}"; do
		echo "MENU[\$i]=\$option" >> "$capture_file"
		i=\$((i + 1))
	done
	i=0
	for path in "\${PURGE_CATEGORY_FULL_PATHS_ARRAY[@]}"; do
		echo "PATH[\$i]=\$path" >> "$capture_file"
		i=\$((i + 1))
	done
	PURGE_SELECTION_RESULT=""
	return 1
}

clean_project_artifacts 2>/dev/null || true
SCRIPT

	_run_in_pty "$script_file"
	rm -f "$script_file"

	if [[ ! -s "$capture_file" ]]; then
		rm -f "$capture_file"
		fail "capture file is empty; select_purge_categories was never called"
	fi

	local menu0 menu1 path0 path1
	menu0=$(grep '^MENU\[0\]=' "$capture_file" | cut -d= -f2-)
	menu1=$(grep '^MENU\[1\]=' "$capture_file" | cut -d= -f2-)
	path0=$(grep '^PATH\[0\]=' "$capture_file" | cut -d= -f2-)
	path1=$(grep '^PATH\[1\]=' "$capture_file" | cut -d= -f2-)
	rm -f "$capture_file"

	[[ "$menu0" != *"[cloud]"* ]] || return 1
	[[ "$path0" != *"[cloud]"* ]] || return 1
	[[ "$menu0" == *"local-project"* ]] || return 1
	[[ "$path0" == *"local-project"* ]] || return 1
	[[ "$menu1" == *"[cloud]"* ]] || return 1
	[[ "$path1" == *"[cloud]"* ]] || return 1
	[[ "$menu1" == *"cloud-project"* ]] || return 1
	[[ "$path1" == *"cloud-project"* ]] || return 1
}
