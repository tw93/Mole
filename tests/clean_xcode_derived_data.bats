#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-xcode-dd.XXXXXX")"
    export HOME

    mkdir -p "$HOME"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

@test "clean_xcode_derived_data reports project count and size" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
is_path_whitelisted() { return 1; }
cleanup_result_color_kb() { echo "\033[0;32m"; }
bytes_to_human() { echo "36 KB"; }
DRY_RUN=false
files_cleaned=0
total_size_cleaned=0
total_items=0

pgrep() { return 1; }
export -f pgrep

dd_dir="$HOME/Library/Developer/Xcode/DerivedData"
mkdir -p "$dd_dir/ProjectAlpha-abcdef123"
mkdir -p "$dd_dir/ProjectBeta-ghijkl456"
mkdir -p "$dd_dir/ProjectGamma-mnopqr789"
echo "build output" > "$dd_dir/ProjectAlpha-abcdef123/build.o"
echo "build output" > "$dd_dir/ProjectBeta-ghijkl456/build.o"
echo "build output" > "$dd_dir/ProjectGamma-mnopqr789/build.o"

clean_xcode_derived_data
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"3 projects"* ]]
    [[ "$output" == *"Xcode DerivedData"* ]]
}

@test "clean_xcode_derived_data skips when Xcode is running" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
is_path_whitelisted() { return 1; }
DRY_RUN=false

pgrep() { return 0; }
export -f pgrep

dd_dir="$HOME/Library/Developer/Xcode/DerivedData"
mkdir -p "$dd_dir/SomeProject-abc123"
echo "data" > "$dd_dir/SomeProject-abc123/build.o"

clean_xcode_derived_data
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Xcode is running"* ]]
}

@test "clean_xcode_derived_data handles empty DerivedData" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
is_path_whitelisted() { return 1; }
DRY_RUN=false
pgrep() { return 1; }
export -f pgrep

mkdir -p "$HOME/Library/Developer/Xcode/DerivedData"

clean_xcode_derived_data
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"projects"* ]]
}

@test "clean_xcode_derived_data handles missing DerivedData dir" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
is_path_whitelisted() { return 1; }
DRY_RUN=false
pgrep() { return 1; }
export -f pgrep

clean_xcode_derived_data
EOF

    [ "$status" -eq 0 ]
}

@test "clean_xcode_derived_data dry run shows would-clean message" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
is_path_whitelisted() { return 1; }
DRY_RUN=true
pgrep() { return 1; }
export -f pgrep

dd_dir="$HOME/Library/Developer/Xcode/DerivedData"
mkdir -p "$dd_dir/MyApp-abc123"
echo "data" > "$dd_dir/MyApp-abc123/build.o"

clean_xcode_derived_data
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"1 project"* ]]
}
