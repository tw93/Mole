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

@test "format_purge_target_path rewrites home with tilde" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
format_purge_target_path "$HOME/www/app/node_modules"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == \~/www/app/node_modules ]]
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

@test "confirm_purge_cleanup accepts Enter" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
drain_pending_input() { :; }
confirm_purge_cleanup 2 1024 0 <<< ''
EOF

	[ "$status" -eq 0 ]
}

@test "confirm_purge_cleanup shows selected paths" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
drain_pending_input() { :; }
confirm_purge_cleanup 2 1024 0 "~/www/app/node_modules" "~/www/app/dist" <<< ''
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Selected paths:"* ]]
	[[ "$output" == *"~/www/app/node_modules"* ]]
	[[ "$output" == *"~/www/app/dist"* ]]
}

@test "confirm_purge_cleanup cancels on ESC" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
drain_pending_input() { :; }
confirm_purge_cleanup 2 1024 0 <<< $'\033'
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
[[ ! -e "$HOME/find-called" ]]
[[ -f "$scan_output" ]]
[[ ! -s "$scan_output" ]]
EOF

	rm -f "$scan_output"
	[ "$status" -eq 0 ]
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
is_recently_modified "$HOME/www/uncertain-project/node_modules"
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
[[ "$_PURGE_ACTIVITY_STATE" == "uncertain" ]]
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
	[[ "$result" == *"node_modules"* ]]
	[[ "$result" == *"target"* ]]
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
	run /bin/bash -c "
        export HOME='$HOME'
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/clean/project.sh'
        clean_project_artifacts
    " </dev/null

	[[ "$status" -eq 0 ]] || [[ "$status" -eq 2 ]]
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
	[[ "$output" == *"COUNT=1"* ]]
	[[ "$output" == *"SIZE=0"* ]]
}

@test "clean_project_artifacts: skips size calculation errors instead of showing 0B (#869)" {
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
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"No artifacts found to purge"* ]]
	[[ "$output" != *"0B"* ]]
}

@test "clean_project_artifacts: dry-run does not count failed removals" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"

mkdir -p "$HOME/.cache/mole"
echo "0" > "$HOME/.cache/mole/purge_stats"

mkdir -p "$HOME/www/test-project/node_modules"
echo "test data" > "$HOME/www/test-project/node_modules/file.js"
touch "$HOME/www/test-project/package.json"
touch -t 202001010101 "$HOME/www/test-project/node_modules" "$HOME/www/test-project/package.json" "$HOME/www/test-project"

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
	[[ "$output" == *"COUNT=0"* ]]
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

# --- git worktree awareness --------------------------------------------------
#
# These fixtures build real repositories on purpose. run_with_timeout execs the
# real git binary, so a shell-function mock is invisible to it (see AGENTS.md),
# and the guards read remote-tracking refs, reflogs and per-worktree git dirs
# that only a real repo has.

_purge_wt_require_git() {
	command -v git > /dev/null 2>&1 || skip "git not available"
}

# Build "$1" as a repo with a pushed origin and "$2" as a linked worktree whose
# work is committed and pushed: clean, remote-backed, nothing unpushed.
_purge_wt_fixture() {
	local repo="$1"
	local wt="$2"
	local origin="${3:-${repo}-origin.git}"

	git init --bare -q "$origin" || return 1
	git init -q "$repo" || return 1
	git -C "$repo" config user.name "Mole Test" || return 1
	git -C "$repo" config user.email "mole@example.com" || return 1
	git -C "$repo" config commit.gpgsign false || return 1
	printf 'hello\n' > "$repo/README.md"
	git -C "$repo" add README.md || return 1
	git -C "$repo" commit -qm "init" || return 1
	git -C "$repo" remote add origin "$origin" || return 1
	git -C "$repo" push -q -u origin HEAD || return 1
	git -C "$repo" worktree add -q "$wt" -b "agent-run" || return 1
	printf 'payload\n' > "$wt/payload.txt"
	git -C "$wt" add payload.txt || return 1
	git -C "$wt" commit -qm "agent work" || return 1
	git -C "$wt" push -q origin HEAD || return 1
}

# Push a worktree's git activity past the age bar. Stamp the directories last:
# touching a file inside one bumps that directory's own mtime.
_purge_wt_age() {
	local wt="$1"
	local stamp="${2:-202001010101}"
	local gitdir

	gitdir=$(git -C "$wt" rev-parse --absolute-git-dir) || return 1
	# The checkout content has to age too, not just the git metadata the
	# worktree guards read: purge_target_activity_still_safe reprobes file
	# mtimes inside the tree right before deletion, so a worktree whose files
	# are fresh is skipped there no matter what git says.
	find "$wt" -exec touch -t "$stamp" {} + 2> /dev/null || true
	touch -t "$stamp" "$gitdir/HEAD" "$gitdir/index" 2> /dev/null || true
	if [[ -f "$gitdir/logs/HEAD" ]]; then
		touch -t "$stamp" "$gitdir/logs/HEAD" || return 1
	fi
	touch -t "$stamp" "$gitdir" "$wt" || return 1
}

# Inner-script preamble: real git needs headroom on a cold CI runner, and
# MO_DEBUG turns each guard's rejection into an assertable line.
_purge_wt_prelude() {
	cat << 'EOF'
set -euo pipefail
exec 2>&1
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/project.sh"
EOF
}

@test "mole_purge_worktree_is_reclaimable: accepts a clean, pushed, stale worktree" {
	_purge_wt_require_git
	_purge_wt_fixture "$HOME/www/repo" "$HOME/www/repo-wt"
	_purge_wt_age "$HOME/www/repo-wt"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		MOLE_TIMEOUT_QUICK_DETECT_SEC=15 MO_DEBUG=1 /bin/bash --noprofile --norc << EOF
$(_purge_wt_prelude)
if mole_purge_worktree_is_reclaimable "\$HOME/www/repo-wt"; then
    echo RECLAIMABLE
else
    echo KEPT
fi
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"RECLAIMABLE"* ]] || return 1
}

@test "mole_purge_worktree_is_reclaimable: keeps a worktree with uncommitted changes" {
	_purge_wt_require_git
	_purge_wt_fixture "$HOME/www/repo" "$HOME/www/repo-wt"
	printf 'scratch\n' > "$HOME/www/repo-wt/uncommitted.txt"
	_purge_wt_age "$HOME/www/repo-wt"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		MOLE_TIMEOUT_QUICK_DETECT_SEC=15 MO_DEBUG=1 /bin/bash --noprofile --norc << EOF
$(_purge_wt_prelude)
if mole_purge_worktree_is_reclaimable "\$HOME/www/repo-wt"; then
    echo RECLAIMABLE
else
    echo KEPT
fi
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"KEPT"* ]] || return 1
	[[ "$output" == *"uncommitted changes"* ]] || return 1
}

@test "mole_purge_worktree_is_reclaimable: keeps a worktree with unpushed commits" {
	_purge_wt_require_git
	_purge_wt_fixture "$HOME/www/repo" "$HOME/www/repo-wt"
	printf 'more\n' > "$HOME/www/repo-wt/extra.txt"
	git -C "$HOME/www/repo-wt" add extra.txt
	git -C "$HOME/www/repo-wt" commit -qm "local only"
	_purge_wt_age "$HOME/www/repo-wt"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		MOLE_TIMEOUT_QUICK_DETECT_SEC=15 MO_DEBUG=1 /bin/bash --noprofile --norc << EOF
$(_purge_wt_prelude)
if mole_purge_worktree_is_reclaimable "\$HOME/www/repo-wt"; then
    echo RECLAIMABLE
else
    echo KEPT
fi
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"KEPT"* ]] || return 1
	[[ "$output" == *"unpushed commit"* ]] || return 1
}

@test "mole_purge_worktree_is_reclaimable: keeps a worktree whose repo has no remote" {
	_purge_wt_require_git
	_purge_wt_fixture "$HOME/www/repo" "$HOME/www/repo-wt"
	git -C "$HOME/www/repo" remote remove origin
	_purge_wt_age "$HOME/www/repo-wt"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		MOLE_TIMEOUT_QUICK_DETECT_SEC=15 MO_DEBUG=1 /bin/bash --noprofile --norc << EOF
$(_purge_wt_prelude)
if mole_purge_worktree_is_reclaimable "\$HOME/www/repo-wt"; then
    echo RECLAIMABLE
else
    echo KEPT
fi
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"KEPT"* ]] || return 1
	[[ "$output" == *"no remote"* ]] || return 1
}

@test "mole_purge_worktree_is_reclaimable: keeps a worktree with recent git activity" {
	_purge_wt_require_git
	_purge_wt_fixture "$HOME/www/repo" "$HOME/www/repo-wt"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		MOLE_TIMEOUT_QUICK_DETECT_SEC=15 MO_DEBUG=1 /bin/bash --noprofile --norc << EOF
$(_purge_wt_prelude)
if mole_purge_worktree_is_reclaimable "\$HOME/www/repo-wt"; then
    echo RECLAIMABLE
else
    echo KEPT
fi
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"KEPT"* ]] || return 1
	[[ "$output" == *"git activity"* ]] || return 1
}

@test "mole_purge_worktree_is_reclaimable: keeps a worktree holding an unrecognized ignored entry" {
	_purge_wt_require_git
	_purge_wt_fixture "$HOME/www/repo" "$HOME/www/repo-wt"
	# .env is gitignored, so status reports the tree clean while the only copy
	# of a secret sits inside it. node_modules is ignored too and IS a known
	# purge target, so the guard has to reject on .env specifically.
	printf 'node_modules/\n.env\n' > "$HOME/www/repo-wt/.gitignore"
	git -C "$HOME/www/repo-wt" add .gitignore
	git -C "$HOME/www/repo-wt" commit -qm "ignore deps and env"
	git -C "$HOME/www/repo-wt" push -q origin HEAD
	mkdir -p "$HOME/www/repo-wt/node_modules"
	printf 'dep\n' > "$HOME/www/repo-wt/node_modules/index.js"
	printf 'TOKEN=secret\n' > "$HOME/www/repo-wt/.env"
	_purge_wt_age "$HOME/www/repo-wt"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		MOLE_TIMEOUT_QUICK_DETECT_SEC=15 MO_DEBUG=1 /bin/bash --noprofile --norc << EOF
$(_purge_wt_prelude)
if mole_purge_worktree_is_reclaimable "\$HOME/www/repo-wt"; then
    echo RECLAIMABLE
else
    echo KEPT
fi
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"KEPT"* ]] || return 1
	[[ "$output" == *"ignored entry outside the purge whitelist (.env)"* ]] || return 1
	[[ -f "$HOME/www/repo-wt/.env" ]] || return 1
}

@test "mole_purge_worktree_is_reclaimable: allows a worktree whose ignored entries are all purge targets" {
	_purge_wt_require_git
	_purge_wt_fixture "$HOME/www/repo" "$HOME/www/repo-wt"
	printf 'node_modules/\ndist/\n' > "$HOME/www/repo-wt/.gitignore"
	git -C "$HOME/www/repo-wt" add .gitignore
	git -C "$HOME/www/repo-wt" commit -qm "ignore deps"
	git -C "$HOME/www/repo-wt" push -q origin HEAD
	mkdir -p "$HOME/www/repo-wt/node_modules" "$HOME/www/repo-wt/dist"
	printf 'dep\n' > "$HOME/www/repo-wt/node_modules/index.js"
	printf 'out\n' > "$HOME/www/repo-wt/dist/bundle.js"
	_purge_wt_age "$HOME/www/repo-wt"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		MOLE_TIMEOUT_QUICK_DETECT_SEC=15 MO_DEBUG=1 /bin/bash --noprofile --norc << EOF
$(_purge_wt_prelude)
if mole_purge_worktree_is_reclaimable "\$HOME/www/repo-wt"; then
    echo RECLAIMABLE
else
    echo KEPT
fi
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"RECLAIMABLE"* ]] || return 1
}

@test "mole_purge_worktree_is_reclaimable: keeps a main worktree even when stale" {
	_purge_wt_require_git
	_purge_wt_fixture "$HOME/www/repo" "$HOME/www/repo-wt"
	touch -t 202001010101 "$HOME/www/repo"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		MOLE_TIMEOUT_QUICK_DETECT_SEC=15 MO_DEBUG=1 /bin/bash --noprofile --norc << EOF
$(_purge_wt_prelude)
if mole_purge_worktree_is_reclaimable "\$HOME/www/repo"; then
    echo RECLAIMABLE
else
    echo KEPT
fi
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"KEPT"* ]] || return 1
}

@test "mole_purge_worktree_registrations: skips the main worktree and prunable entries" {
	_purge_wt_require_git
	_purge_wt_fixture "$HOME/www/repo" "$HOME/www/repo-wt"
	git -C "$HOME/www/repo" worktree add -q "$HOME/www/repo-dead" -b "dead-run"
	rm -rf "$HOME/www/repo-dead"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		MOLE_TIMEOUT_QUICK_DETECT_SEC=15 /bin/bash --noprofile --norc << EOF
$(_purge_wt_prelude)
mole_purge_worktree_registrations "\$HOME/www/repo"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"$HOME/www/repo-wt"* ]] || return 1
	[[ "$output" != *"repo-dead"* ]] || return 1
	# The main worktree must never be offered.
	[[ "$(printf '%s\n' "$output" | grep -cx "$HOME/www/repo")" == "0" ]] || return 1
}

@test "scan_purge_worktrees: finds a worktree registered outside the search root" {
	_purge_wt_require_git
	local outside="$BATS_TEST_TMPDIR/agent-checkout"
	_purge_wt_fixture "$HOME/www/repo" "$outside"
	_purge_wt_age "$outside"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" OUTSIDE="$outside" \
		BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR" \
		MOLE_TIMEOUT_QUICK_DETECT_SEC=15 /bin/bash --noprofile --norc << EOF
$(_purge_wt_prelude)
out=\$(mktemp)
scan_purge_worktrees "\$HOME/www" "\$out"
cat "\$out"
rm -f "\$out"
EOF

	[ "$status" -eq 0 ] || return 1
	# "<worktree>\t<parent repo>\t<activity epoch>"
	[[ "$output" == *"$outside	$HOME/www/repo	"* ]] || return 1
}

@test "is_safe_purge_worktree: rejects a worktree whose repo is outside the configured roots" {
	_purge_wt_require_git
	_purge_wt_fixture "$HOME/www/repo" "$HOME/www/repo-wt"
	_purge_wt_age "$HOME/www/repo-wt"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		MOLE_TIMEOUT_QUICK_DETECT_SEC=15 /bin/bash --noprofile --norc << EOF
$(_purge_wt_prelude)
PURGE_SEARCH_PATHS=("\$HOME/dev")
if is_safe_purge_worktree "\$HOME/www/repo-wt"; then
    echo UNSAFE
else
    echo BLOCKED
fi
PURGE_SEARCH_PATHS=("\$HOME/www")
if is_safe_purge_worktree "\$HOME/www/repo-wt"; then
    echo ALLOWED
else
    echo BLOCKED_IN_ROOT
fi
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"BLOCKED"* ]] || return 1
	[[ "$output" != *"UNSAFE"* ]] || return 1
	[[ "$output" == *"ALLOWED"* ]] || return 1
}

@test "is_safe_purge_worktree: rejects a directory that only looks like a worktree" {
	_purge_wt_require_git
	mkdir -p "$HOME/www/not-a-worktree"
	printf 'gitdir: /nonexistent/.git/worktrees/fake\n' > "$HOME/www/not-a-worktree/.git"
	touch -t 202001010101 "$HOME/www/not-a-worktree"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		MOLE_TIMEOUT_QUICK_DETECT_SEC=15 /bin/bash --noprofile --norc << EOF
$(_purge_wt_prelude)
PURGE_SEARCH_PATHS=("\$HOME/www")
if is_safe_purge_worktree "\$HOME/www/not-a-worktree"; then
    echo UNSAFE
else
    echo BLOCKED
fi
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"BLOCKED"* ]] || return 1
	[[ -d "$HOME/www/not-a-worktree" ]] || return 1
}

@test "mole_purge_remove_worktree: trashes the checkout and prunes the registration" {
	_purge_wt_require_git
	_purge_wt_fixture "$HOME/www/repo" "$HOME/www/repo-wt"
	_purge_wt_age "$HOME/www/repo-wt"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		MOLE_TEST_TRASH_DIR="$BATS_TEST_TMPDIR/Trash" \
		MOLE_DELETE_LOG="$BATS_TEST_TMPDIR/deletions.log" \
		MOLE_TEST_NO_AUTH=1 MOLE_TIMEOUT_QUICK_DETECT_SEC=15 /bin/bash --noprofile --norc << EOF
$(_purge_wt_prelude)
mole_purge_remove_worktree "\$HOME/www/repo-wt" "\$HOME/www/repo"
echo "REGISTRATIONS:\$(git -C "\$HOME/www/repo" worktree list --porcelain | grep -c '^worktree ')"
EOF

	[ "$status" -eq 0 ] || return 1
	# Recoverable: the checkout went to the Trash, not to rm -rf.
	[[ ! -d "$HOME/www/repo-wt" ]] || return 1
	[[ -n "$(ls -A "$BATS_TEST_TMPDIR/Trash" 2> /dev/null || true)" ]] || return 1
	[[ "$(cat "$BATS_TEST_TMPDIR/Trash"/repo-wt.*/payload.txt 2> /dev/null)" == "payload" ]] || return 1
	# Only the main worktree registration is left behind.
	[[ "$output" == *"REGISTRATIONS:1"* ]] || return 1
	[[ "$(grep -c 'trash' "$BATS_TEST_TMPDIR/deletions.log")" -ge 1 ]] || return 1
}

@test "mole_purge_worktree_prune: keeps a registration whose worktree still exists" {
	_purge_wt_require_git
	_purge_wt_fixture "$HOME/www/repo" "$HOME/www/repo-wt"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		MOLE_TIMEOUT_QUICK_DETECT_SEC=15 /bin/bash --noprofile --norc << EOF
$(_purge_wt_prelude)
mole_purge_worktree_prune "\$HOME/www/repo-wt" "\$HOME/www/repo"
echo "REGISTRATIONS:\$(git -C "\$HOME/www/repo" worktree list --porcelain | grep -c '^worktree ')"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"REGISTRATIONS:2"* ]] || return 1
	[[ -d "$HOME/www/repo-wt" ]] || return 1
}

@test "clean_project_artifacts: a non-interactive purge never auto-selects a worktree" {
	_purge_wt_require_git
	_purge_wt_fixture "$HOME/www/repo" "$HOME/www/repo-wt"
	_purge_wt_age "$HOME/www/repo-wt"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		MOLE_TIMEOUT_QUICK_DETECT_SEC=15 MO_DEBUG=1 /bin/bash --noprofile --norc << EOF
$(_purge_wt_prelude)
mkdir -p "\$HOME/.cache/mole"
PURGE_SEARCH_PATHS=("\$HOME/www")
scan_purge_targets() { : > "\$2"; }
get_dir_size_kb() { echo 4096; }
mole_purge_remove_worktree() {
    echo "WORKTREE_REMOVE:\$1"
    return 0
}
safe_remove() {
    echo "REMOVE:\$1"
    return 0
}
clean_project_artifacts < /dev/null
EOF

	[ "$status" -eq 0 ] || return 1
	# The worktree really did reach the selection step (guards against a
	# vacuous pass where discovery found nothing at all)...
	[[ "$output" == *"Not auto-selecting worktree in non-interactive purge"* ]] || return 1
	# ...and was then left alone.
	[[ "$output" == *"No items selected"* ]] || return 1
	[[ "$output" != *"WORKTREE_REMOVE:"* ]] || return 1
	[[ -d "$HOME/www/repo-wt" ]] || return 1
}

@test "clean_project_artifacts: a listed worktree absorbs the artifacts inside it" {
	_purge_wt_require_git
	_purge_wt_fixture "$HOME/www/repo" "$HOME/www/repo-wt"
	# Gitignored, so `git status --porcelain` still reports the worktree clean:
	# the same blind spot that makes Trash the right delete mode here.
	printf 'node_modules/\n' > "$HOME/www/repo-wt/.gitignore"
	git -C "$HOME/www/repo-wt" add .gitignore
	git -C "$HOME/www/repo-wt" commit -qm "ignore deps"
	git -C "$HOME/www/repo-wt" push -q origin HEAD
	mkdir -p "$HOME/www/repo-wt/node_modules"
	printf 'dep\n' > "$HOME/www/repo-wt/node_modules/index.js"
	_purge_wt_age "$HOME/www/repo-wt"

	local capture_file script_file
	capture_file=$(mktemp "$HOME/wt_capture.XXXXXX")
	script_file=$(mktemp "$HOME/wt_script.XXXXXX.sh")

	cat > "$script_file" << SCRIPT
set -euo pipefail
# Timeout constants are readonly once the libs load, so widen before sourcing.
export MOLE_TIMEOUT_QUICK_DETECT_SEC=15
export XDG_CACHE_HOME="$HOME/.cache"
export TERM="dumb"
mkdir -p "$HOME/.cache/mole"
source "$PROJECT_ROOT/lib/clean/project.sh"
PURGE_SEARCH_PATHS=("$HOME/www")
scan_purge_targets() { printf '%s\n' "$HOME/www/repo-wt/node_modules" > "\$2"; }
get_dir_size_kb() { echo 4096; }

select_purge_categories() {
	printf '%s\n' "\${PURGE_CATEGORY_FULL_PATHS_ARRAY[@]}" > "$capture_file"
	PURGE_SELECTION_RESULT=""
	return 1
}

clean_project_artifacts 2>/dev/null || true
SCRIPT

	local pty_log="$HOME/wt_absorb.log"
	_run_in_pty "$script_file" > "$pty_log" 2>&1 || printf 'PTY_RC=%s\n' "$?" >> "$pty_log"
	rm -f "$script_file"

	if [[ ! -s "$capture_file" ]]; then
		printf 'select_purge_categories was never called; pty output:\n%s\n' "$(cat "$pty_log" 2> /dev/null)" >&2
		return 1
	fi

	local listed
	listed=$(cat "$capture_file")
	rm -f "$capture_file"

	# The worktree is offered as one entry; the node_modules inside it is not a
	# second entry, so the same bytes are never listed (or counted) twice.
	if [[ "$listed" != *"/www/repo-wt"* ]]; then
		printf 'worktree row missing; listed:\n%s\n' "$listed" >&2
		return 1
	fi
	[[ "$listed" != *"node_modules"* ]] || return 1
}

@test "clean_project_artifacts: an interactively selected worktree is trashed and pruned" {
	_purge_wt_require_git
	_purge_wt_fixture "$HOME/www/repo" "$HOME/www/repo-wt"
	_purge_wt_age "$HOME/www/repo-wt"

	local script_file trash_dir
	trash_dir="$BATS_TEST_TMPDIR/Trash"
	script_file=$(mktemp "$HOME/wt_remove.XXXXXX.sh")

	cat > "$script_file" << SCRIPT
set -euo pipefail
# Timeout constants are readonly once the libs load, so widen before sourcing.
export MOLE_TIMEOUT_QUICK_DETECT_SEC=15
export XDG_CACHE_HOME="$HOME/.cache"
export TERM="dumb"
export MOLE_TEST_TRASH_DIR="$trash_dir"
export MOLE_DELETE_LOG="$BATS_TEST_TMPDIR/deletions.log"
export MOLE_TEST_NO_AUTH=1
mkdir -p "$HOME/.cache/mole"
source "$PROJECT_ROOT/lib/clean/project.sh"
PURGE_SEARCH_PATHS=("$HOME/www")
scan_purge_targets() { : > "\$2"; }

# Select every listed entry, then accept the confirmation, so the real
# revalidation gate and the real delete path both run.
select_purge_categories() {
	local total=\$#
	local i=0
	PURGE_SELECTION_RESULT=""
	while [[ \$i -lt \$total ]]; do
		[[ -n "\$PURGE_SELECTION_RESULT" ]] && PURGE_SELECTION_RESULT+=","
		PURGE_SELECTION_RESULT+="\$i"
		i=\$((i + 1))
	done
	return 0
}
confirm_purge_cleanup() { return 0; }

clean_project_artifacts
SCRIPT

	local pty_log="$HOME/wt_remove.log"
	_run_in_pty "$script_file" > "$pty_log" 2>&1 || true
	rm -f "$script_file"

	# Recoverable delete, not purge's usual permanent rm -rf.
	if [[ -d "$HOME/www/repo-wt" ]]; then
		printf 'worktree still present; pty output:\n%s\n' "$(cat "$pty_log" 2> /dev/null)" >&2
		return 1
	fi
	[[ "$(cat "$trash_dir"/repo-wt.*/payload.txt 2> /dev/null)" == "payload" ]] || return 1
	# The dangling registration is reaped, so `git worktree list` stays clean.
	[[ "$(git -C "$HOME/www/repo" worktree list --porcelain | grep -c '^worktree ')" == "1" ]] || return 1
	# The main worktree is untouched.
	[[ -d "$HOME/www/repo" ]] || return 1
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
        $timeout_cmd 5 '$PROJECT_ROOT/bin/purge.sh' 2>&1 < /dev/null || true
    "

	[[ "$output" =~ "Scanning" ]] ||
		[[ "$output" =~ "Purge complete" ]] ||
		[[ "$output" =~ "No old" ]] ||
		[[ "$output" =~ "Great" ]]
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
	[[ "$output" == *"--include-empty"* ]]
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
	# stdin must come from /dev/null (or any pipe), not from whatever the test
	# runner inherited: macOS script(1) only tolerates a non-tty stdin when
	# ioctl fails with ENOTTY, and dies with "tcgetattr/ioctl: Operation not
	# supported on socket" otherwise. The child still gets the allocated pty,
	# so [[ -t 0 ]] inside the script stays true either way.
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

	local path0 path1
	path0=$(grep '^PATH\[0\]=' "$capture_file" | head -1 | cut -d= -f2-)
	path1=$(grep '^PATH\[1\]=' "$capture_file" | head -1 | cut -d= -f2-)
	rm -f "$capture_file"

	# PURGE_CATEGORY_SIZES must be sorted descending (largest first).
	[ "${sizes[0]}" -gt "${sizes[1]}" ]

	# Index 0 → largest artifact → beta's path.
	# With the bug path0 = alpha (discovery order) → [[ ... == *beta* ]] fails.
	[[ "$path0" == *"beta"* ]]

	# Index 1 → smaller artifact → alpha's path.
	[[ "$path1" == *"alpha"* ]]
}
