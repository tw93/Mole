#!/usr/bin/env bats
# Tests for JSON output functionality

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-json-home.XXXXXX")"
    export HOME

    mkdir -p "$HOME"
    mkdir -p "$HOME/.config/mole"
    mkdir -p "$HOME/.cache/mole"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    rm -rf "$HOME/.config/mole"/*
    rm -rf "$HOME/.cache/mole"/*
    mkdir -p "$HOME/.config/mole"
    mkdir -p "$HOME/.cache/mole"
    mkdir -p "$HOME/Library/Caches"
}

# ============================================================================
# JSON Module Unit Tests
# ============================================================================

@test "json_escape_string escapes special characters" {
    source "$PROJECT_ROOT/lib/core/json_output.sh"

    result=$(json_escape_string 'hello "world"')
    [[ "$result" == 'hello \"world\"' ]]

    result=$(json_escape_string 'path/with\backslash')
    [[ "$result" == 'path/with\\backslash' ]]

    result=$(json_escape_string $'line1\nline2')
    [[ "$result" == 'line1\nline2' ]]
}

@test "json_generate_id creates stable identifiers" {
    source "$PROJECT_ROOT/lib/core/json_output.sh"

    id1=$(json_generate_id "Safari cache")
    id2=$(json_generate_id "Safari cache")
    [[ "$id1" == "$id2" ]]

    id3=$(json_generate_id "Chrome cache")
    [[ "$id1" != "$id3" ]]

    # IDs should be lowercase with underscores
    [[ "$id1" =~ ^[a-z0-9_-]+$ ]]
}

@test "json_classify_risk returns correct risk levels" {
    source "$PROJECT_ROOT/lib/core/json_output.sh"

    # Low risk: caches
    risk=$(json_classify_risk "Safari cache" "/Users/test/Library/Caches")
    [[ "$risk" == "low" ]]

    # Low risk: logs
    risk=$(json_classify_risk "Application logs" "/Users/test/Library/Logs")
    [[ "$risk" == "low" ]]

    # Medium risk: orphaned data
    risk=$(json_classify_risk "Orphaned app data" "/Users/test/Library/Application Support")
    [[ "$risk" == "medium" ]]

    # High risk: system paths
    risk=$(json_classify_risk "System cache" "/Library/Caches")
    [[ "$risk" == "high" ]]

    # High risk: preferences
    risk=$(json_classify_risk "App preferences" "/Users/test/Library/Preferences")
    [[ "$risk" == "high" ]]
}

@test "json_extract_tags identifies technology tags" {
    source "$PROJECT_ROOT/lib/core/json_output.sh"

    tags=$(json_extract_tags "Xcode DerivedData" "Developer tools")
    [[ "$tags" == *"ios"* ]]
    [[ "$tags" == *"xcode"* ]]

    tags=$(json_extract_tags "npm cache" "Developer tools")
    [[ "$tags" == *"nodejs"* ]]

    tags=$(json_extract_tags "pip cache" "Developer tools")
    [[ "$tags" == *"python"* ]]

    tags=$(json_extract_tags "Docker cache" "Developer tools")
    [[ "$tags" == *"docker"* ]]
}

@test "json_add_item adds item to buffer" {
    source "$PROJECT_ROOT/lib/core/json_output.sh"

    export MOLE_JSON_OUTPUT="true"
    json_reset

    json_set_category "Test Category"
    json_add_item "Test item" "1024" "/path/to/test" "false"

    [[ ${#MOLE_JSON_ITEMS[@]} -eq 1 ]]
    [[ "${MOLE_JSON_ITEMS[0]}" == *"Test item"* ]]
    [[ "${MOLE_JSON_ITEMS[0]}" == *"Test Category"* ]]
}

@test "json_output_clean produces valid JSON structure" {
    source "$PROJECT_ROOT/lib/core/json_output.sh"

    export MOLE_JSON_OUTPUT="true"
    json_reset

    json_set_category "Browsers"
    json_add_item "Safari cache" "5120" "/Users/test/Library/Caches/Safari" "false"

    json_set_category "Developer tools"
    json_add_item "npm cache" "10240" "/Users/test/.npm" "false"

    output=$(json_output_clean "clean" "true")

    # Check JSON structure
    [[ "$output" == *'"command": "clean"'* ]]
    [[ "$output" == *'"dryRun": true'* ]]
    [[ "$output" == *'"items":'* ]]
    [[ "$output" == *'"totalEstimatedBytes":'* ]]
    [[ "$output" == *'"requiresSudo":'* ]]
    [[ "$output" == *'"warnings":'* ]]

    # Check items
    [[ "$output" == *'"title": "Safari cache"'* ]]
    [[ "$output" == *'"title": "npm cache"'* ]]
    [[ "$output" == *'"category": "Browsers"'* ]]
    [[ "$output" == *'"category": "Developer tools"'* ]]
}

@test "json_reset clears all buffers" {
    source "$PROJECT_ROOT/lib/core/json_output.sh"

    export MOLE_JSON_OUTPUT="true"

    json_set_category "Test"
    json_add_item "item1" "100" "/path1" "false"
    json_add_item "item2" "200" "/path2" "false"
    json_add_warning "test warning"

    json_reset

    [[ ${#MOLE_JSON_ITEMS[@]} -eq 0 ]]
    [[ ${#MOLE_JSON_WARNINGS[@]} -eq 0 ]]
    [[ "$MOLE_JSON_TOTAL_BYTES" -eq 0 ]]
}

# ============================================================================
# CLI Integration Tests
# ============================================================================

@test "mo clean --format json outputs valid JSON" {
    # Create some test cache files
    mkdir -p "$HOME/Library/Caches/com.test.app"
    echo "test data" > "$HOME/Library/Caches/com.test.app/cache.dat"

    run env HOME="$HOME" TERM="dumb" "$PROJECT_ROOT/mole" clean --format json
    [ "$status" -eq 0 ]

    # Should be valid JSON (starts with { and ends with })
    [[ "${output:0:1}" == "{" ]]
    [[ "${output: -1}" == "}" ]] || [[ "${output: -2:1}" == "}" ]]

    # Check required fields
    [[ "$output" == *'"command": "clean"'* ]]
    [[ "$output" == *'"dryRun": true'* ]]
    [[ "$output" == *'"items":'* ]]
}

@test "mo clean --json is alias for --format json" {
    run env HOME="$HOME" TERM="dumb" "$PROJECT_ROOT/mole" clean --json
    [ "$status" -eq 0 ]

    [[ "${output:0:1}" == "{" ]]
    [[ "$output" == *'"command": "clean"'* ]]
}

@test "mo clean --format=json works with equals syntax" {
    run env HOME="$HOME" TERM="dumb" "$PROJECT_ROOT/mole" clean --format=json
    [ "$status" -eq 0 ]

    [[ "${output:0:1}" == "{" ]]
    [[ "$output" == *'"command": "clean"'* ]]
}

@test "mo clean --format json includes item fields" {
    # Create test cache
    mkdir -p "$HOME/Library/Caches/com.apple.Safari"
    dd if=/dev/zero of="$HOME/Library/Caches/com.apple.Safari/test.cache" bs=1024 count=10 2>/dev/null

    run env HOME="$HOME" TERM="dumb" "$PROJECT_ROOT/mole" clean --format json
    [ "$status" -eq 0 ]

    # Check that items have required fields
    [[ "$output" == *'"id":'* ]]
    [[ "$output" == *'"title":'* ]]
    [[ "$output" == *'"category":'* ]]
    [[ "$output" == *'"paths":'* ]]
    [[ "$output" == *'"estimatedBytes":'* ]]
    [[ "$output" == *'"risk":'* ]]
    [[ "$output" == *'"requiresSudo":'* ]]
    [[ "$output" == *'"reason":'* ]]
    [[ "$output" == *'"personaTags":'* ]]
}

@test "mo purge --format json outputs valid JSON" {
    # Create test project structure
    mkdir -p "$HOME/Projects/test-app/node_modules"
    echo "test" > "$HOME/Projects/test-app/node_modules/test.js"
    touch -t 202301010000 "$HOME/Projects/test-app/node_modules"

    run env HOME="$HOME" TERM="dumb" "$PROJECT_ROOT/mole" purge --format json
    [ "$status" -eq 0 ]

    [[ "${output:0:1}" == "{" ]]
    [[ "$output" == *'"command": "purge"'* ]]
    [[ "$output" == *'"dryRun": true'* ]]
}

@test "mo purge --json is alias for --format json" {
    run env HOME="$HOME" TERM="dumb" "$PROJECT_ROOT/mole" purge --json
    [ "$status" -eq 0 ]

    [[ "${output:0:1}" == "{" ]]
    [[ "$output" == *'"command": "purge"'* ]]
}

@test "JSON output includes totalEstimatedBytes" {
    mkdir -p "$HOME/Library/Caches/com.test.large"
    dd if=/dev/zero of="$HOME/Library/Caches/com.test.large/big.cache" bs=1024 count=100 2>/dev/null

    run env HOME="$HOME" TERM="dumb" "$PROJECT_ROOT/mole" clean --format json
    [ "$status" -eq 0 ]

    [[ "$output" == *'"totalEstimatedBytes":'* ]]
    # Total should be > 0 if we found items
    if [[ "$output" == *'"items": ['* ]] && [[ "$output" != *'"items": []'* ]]; then
        # Extract totalEstimatedBytes value
        total=$(echo "$output" | grep -o '"totalEstimatedBytes": [0-9]*' | grep -o '[0-9]*')
        [[ "$total" -gt 0 ]]
    fi
}

@test "JSON output has stable IDs across runs" {
    mkdir -p "$HOME/Library/Caches/com.stable.test"
    echo "data" > "$HOME/Library/Caches/com.stable.test/cache"

    run env HOME="$HOME" TERM="dumb" "$PROJECT_ROOT/mole" clean --format json
    [ "$status" -eq 0 ]
    output1="$output"

    run env HOME="$HOME" TERM="dumb" "$PROJECT_ROOT/mole" clean --format json
    [ "$status" -eq 0 ]
    output2="$output"

    # Extract IDs and compare (IDs should be identical for same items)
    id1=$(echo "$output1" | grep -o '"id": "[^"]*"' | head -1)
    id2=$(echo "$output2" | grep -o '"id": "[^"]*"' | head -1)

    [[ "$id1" == "$id2" ]]
}

@test "JSON mode does not output terminal formatting" {
    run env HOME="$HOME" TERM="dumb" "$PROJECT_ROOT/mole" clean --format json
    [ "$status" -eq 0 ]

    # Should not contain ANSI escape codes
    [[ "$output" != *$'\033'* ]]
    [[ "$output" != *$'\e['* ]]

    # Should not contain the normal CLI headers
    [[ "$output" != *"Clean Your Mac"* ]]
    [[ "$output" != *"━━━"* ]]
}

@test "help text mentions --format json" {
    run env HOME="$HOME" "$PROJECT_ROOT/mole" --help
    [ "$status" -eq 0 ]

    [[ "$output" == *"--format json"* ]] || [[ "$output" == *"--json"* ]]
}
