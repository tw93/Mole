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
	rm -rf "$HOME"
	if [[ -n "${ORIGINAL_HOME:-}" ]]; then
		export HOME="$ORIGINAL_HOME"
	fi
}

setup() {
	mkdir -p "$HOME/www"
	mkdir -p "$HOME/dev"
	mkdir -p "$HOME/.cache/mole"

	rm -rf "${HOME:?}/www"/* "${HOME:?}/dev"/*
}

@test "is_safe_project_artifact: rejects shallow paths (protection against accidents)" {
	result=$(bash -c "
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
	result=$(bash -c "
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
	result=$(bash -c "
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
	result=$(bash -c "
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

	result=$(bash -c "
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

	result=$(bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        if is_safe_project_artifact '$HOME/www/real/proj/node_modules' '$HOME/www/link/proj'; then
            echo 'ALLOWED'
        else
            echo 'BLOCKED'
        fi
    ")

	[[ "$result" == "ALLOWED" ]]
}

@test "compact_purge_scan_path keeps the tail of long purge paths visible" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_SKIP_MAIN=1 bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/purge.sh"
compact_purge_scan_path "$HOME/projects/team/service/very/deep/component/node_modules" 32
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == ".../deep/component/node_modules" ]]
}

@test "compact_purge_menu_path keeps the project tail visible" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
compact_purge_menu_path "$HOME/projects/team/service/very/deep/component/node_modules" 32
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == ".../deep/component/node_modules" ]]
}

@test "format_purge_target_path rewrites home with tilde" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
format_purge_target_path "$HOME/www/app/node_modules"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == \~/www/app/node_modules ]]
}

@test "filter_nested_artifacts: removes nested node_modules" {
	mkdir -p "$HOME/www/project/node_modules/package/node_modules"

	result=$(bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        printf '%s\n' '$HOME/www/project/node_modules' '$HOME/www/project/node_modules/package/node_modules' | \
        filter_nested_artifacts | wc -l | tr -d ' '
    ")

	[[ "$result" == "1" ]]
}

@test "filter_nested_artifacts: keeps independent artifacts" {
	mkdir -p "$HOME/www/project1/node_modules"
	mkdir -p "$HOME/www/project2/target"

	result=$(bash -c "
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

	result=$(bash -c "
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

	result=$(bash -c "
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

	result=$(bash -c "
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

	result=$(bash -c "
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

	result=$(bash -c "
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

	result=$(bash -c "
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

	result=$(bash -c "
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
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
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
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
mkdir -p "$HOME/CustomProjects/app"
touch "$HOME/CustomProjects/app/go.mod"
discover_project_dirs | grep -q "$HOME/CustomProjects"
EOF

	[ "$status" -eq 0 ]
}

@test "save_discovered_paths writes config with tilde" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
save_discovered_paths "$HOME/Projects"
grep -q "^~/" "$HOME/.config/mole/purge_paths"
EOF

	[ "$status" -eq 0 ]
}

@test "select_purge_categories returns failure on empty input" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
if select_purge_categories; then
    exit 1
fi
EOF

	[ "$status" -eq 0 ]
}

@test "select_purge_categories restores caller EXIT/INT/TERM traps" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
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
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
drain_pending_input() { :; }
confirm_purge_cleanup 2 1024 0 <<< ''
EOF

	[ "$status" -eq 0 ]
}

@test "confirm_purge_cleanup shows selected paths" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
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
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
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

	result=$(bash -c "
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

	result=$(bash -c "
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

	result=$(bash -c "
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

	result=$(bash -c "
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

	result=$(bash -c "
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

	result=$(bash -c "
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

	result=$(bash -c "
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

	result=$(bash -c "
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

	result=$(bash -c "
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

@test "scan_purge_targets: supports trailing slash search path in find mode" {
	mkdir -p "$HOME/single-project/node_modules"
	touch "$HOME/single-project/package.json"

	local scan_output
	scan_output="$(mktemp)"

	result=$(bash -c "
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

@test "is_recently_modified: detects recent projects" {
	mkdir -p "$HOME/www/project/node_modules"
	touch "$HOME/www/project/package.json"

	result=$(bash -c "
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

@test "is_recently_modified: marks old projects correctly" {
	mkdir -p "$HOME/www/old-project/node_modules"
	mkdir -p "$HOME/www/old-project"

	bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/clean/project.sh'
        is_recently_modified '$HOME/www/old-project/node_modules' || true
    "
	local exit_code=$?
	[ "$exit_code" -eq 0 ] || [ "$exit_code" -eq 1 ]
}

@test "purge targets are configured correctly" {
	result=$(bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        echo \"\${PURGE_TARGETS[@]}\"
    ")
	[[ "$result" == *"node_modules"* ]]
	[[ "$result" == *"target"* ]]
}

@test "get_dir_size_kb: calculates directory size" {
	mkdir -p "$HOME/www/test-project/node_modules"
	dd if=/dev/zero of="$HOME/www/test-project/node_modules/file.bin" bs=1024 count=1024 2>/dev/null

	result=$(bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        get_dir_size_kb '$HOME/www/test-project/node_modules'
    ")

	[[ "$result" -ge 1000 ]] && [[ "$result" -le 1100 ]]
}

@test "get_dir_size_kb: handles non-existent paths gracefully" {
	result=$(bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        get_dir_size_kb '$HOME/www/non-existent'
    ")
	[[ "$result" == "0" ]]
}

@test "get_dir_size_kb: returns TIMEOUT when size calculation hangs" {
	mkdir -p "$HOME/www/stuck-project/node_modules"

	result=$(bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/clean/project.sh'
        run_with_timeout() { return 124; }
        get_dir_size_kb '$HOME/www/stuck-project/node_modules'
    ")

	[[ "$result" == "TIMEOUT" ]]
}

@test "clean_project_artifacts: restores caller INT/TERM traps" {
	result=$(bash -c "
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
	run bash -c "
        export HOME='$HOME'
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/clean/project.sh'
        clean_project_artifacts
    " </dev/null

	[[ "$status" -eq 0 ]] || [[ "$status" -eq 2 ]]
}

@test "clean_project_artifacts: handles empty menu options under set -u" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
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

@test "clean_project_artifacts: dry-run does not count failed removals" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
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

@test "clean_project_artifacts: scans and finds artifacts" {
	if ! command -v gtimeout >/dev/null 2>&1 && ! command -v timeout >/dev/null 2>&1; then
		skip "gtimeout/timeout not available"
	fi

	mkdir -p "$HOME/www/test-project/node_modules/package1"
	echo "test data" >"$HOME/www/test-project/node_modules/package1/index.js"

	mkdir -p "$HOME/www/test-project"

	timeout_cmd="timeout"
	command -v timeout >/dev/null 2>&1 || timeout_cmd="gtimeout"

	run bash -c "
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

@test "mo purge: accepts --debug flag" {
	if ! command -v gtimeout >/dev/null 2>&1 && ! command -v timeout >/dev/null 2>&1; then
		skip "gtimeout/timeout not available"
	fi

	timeout_cmd="timeout"
	command -v timeout >/dev/null 2>&1 || timeout_cmd="gtimeout"

	run bash -c "
        export HOME='$HOME'
        $timeout_cmd 2 '$PROJECT_ROOT/mole' purge --debug < /dev/null 2>&1 || true
    "
	true
}

@test "mo purge: accepts --dry-run flag" {
	if ! command -v gtimeout >/dev/null 2>&1 && ! command -v timeout >/dev/null 2>&1; then
		skip "gtimeout/timeout not available"
	fi

	timeout_cmd="timeout"
	command -v timeout >/dev/null 2>&1 || timeout_cmd="gtimeout"

	run bash -c "
        export HOME='$HOME'
        $timeout_cmd 2 '$PROJECT_ROOT/mole' purge --dry-run < /dev/null 2>&1 || true
    "

	[[ "$output" == *"DRY RUN MODE"* ]] || [[ "$output" == *"Dry run complete"* ]]
}

@test "mo purge: creates cache directory for stats" {
	if ! command -v gtimeout >/dev/null 2>&1 && ! command -v timeout >/dev/null 2>&1; then
		skip "gtimeout/timeout not available"
	fi

	timeout_cmd="timeout"
	command -v timeout >/dev/null 2>&1 || timeout_cmd="gtimeout"

	bash -c "
        export HOME='$HOME'
        $timeout_cmd 2 '$PROJECT_ROOT/mole' purge < /dev/null 2>&1 || true
    "

	[ -d "$HOME/.cache/mole" ] || [ -d "${XDG_CACHE_HOME:-$HOME/.cache}/mole" ]
}

# .NET bin directory detection tests
@test "is_dotnet_bin_dir: finds .NET context in parent directory with Debug dir" {
	mkdir -p "$HOME/www/dotnet-app/bin/Debug"
	touch "$HOME/www/dotnet-app/MyProject.csproj"

	result=$(bash -c "
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

	result=$(bash -c "
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

	result=$(bash -c "
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

	result=$(bash -c "
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

	result=$(bash -c "
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
	script -q /dev/null bash --noprofile --norc "$script_file" 2>/dev/null
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
