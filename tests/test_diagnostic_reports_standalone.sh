#!/usr/bin/env bash
# Standalone test for get_diagnostic_report_paths_for_app (Issue #441). Run: bash tests/test_diagnostic_reports_standalone.sh

set +e
set +u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ ! -f "$PROJECT_ROOT/lib/core/app_protection.sh" ]]; then
    PROJECT_ROOT="$(pwd)"
    SCRIPT_DIR="$PROJECT_ROOT/tests"
fi
cd "$PROJECT_ROOT" || exit 1

source_crlf_safe() {
    local f="$1"
    if [[ -f "$f" ]]; then
        # shellcheck source=/dev/null
        source /dev/stdin <<< "$(sed 's/\r$//' < "$f")"
    fi
}

source_crlf_safe "$PROJECT_ROOT/lib/core/base.sh"
source_crlf_safe "$PROJECT_ROOT/lib/core/app_protection.sh"
set +e
set +u

FAILED=0
PASSED=0

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local name="${3:-assert}"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  OK $name"
        ((PASSED++))
        return 0
    fi
    echo "  FAIL $name (expected to find: $needle)"
    ((FAILED++))
    return 1
}

assert_empty() {
    local val="$1"
    local name="${2:-assert}"
    if [[ -z "$val" ]]; then
        echo "  OK $name (empty as expected)"
        ((PASSED++))
        return 0
    fi
    echo "  FAIL $name (expected empty, got: $val)"
    ((FAILED++))
    return 1
}

echo "Testing get_diagnostic_report_paths_for_app (DiagnosticReports uninstall)"
echo ""

out=$(get_diagnostic_report_paths_for_app "/Applications/Foo.app" "Foo" "/nonexistent/dir" 2> /dev/null || true)
assert_empty "$out" "missing directory returns empty"

TMP_EMPTY=$(mktemp -d 2> /dev/null || mktemp -d -t mole-test 2> /dev/null || echo "")
[[ -z "$TMP_EMPTY" ]] && TMP_EMPTY="/tmp/mole-test-$$" && mkdir -p "$TMP_EMPTY"
out=$(get_diagnostic_report_paths_for_app "" "Ab" "$TMP_EMPTY" 2> /dev/null || true)
assert_empty "$out" "empty app_path returns empty"
rm -rf "$TMP_EMPTY" 2> /dev/null || true

TMP_DIAG=$(mktemp -d 2> /dev/null || mktemp -d -t mole-diag 2> /dev/null || echo "/tmp/mole-diag-$$")
TMP_APP=$(mktemp -d 2> /dev/null || mktemp -d -t mole-app 2> /dev/null || echo "/tmp/mole-app-$$")
mkdir -p "$TMP_DIAG" "$TMP_APP"
mkdir -p "$TMP_APP/Contents"
printf '%s' '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>MyApp</string></dict></plist>' > "$TMP_APP/Contents/Info.plist"

touch "$TMP_DIAG/MyApp_2025-02-10-120000_host.ips"
touch "$TMP_DIAG/MyApp.crash"
touch "$TMP_DIAG/MyApp_2025-02-10-120001_host.spin"
touch "$TMP_DIAG/OtherApp_2025-02-10.ips"
touch "$TMP_DIAG/MyApp_log.txt"

out=$(get_diagnostic_report_paths_for_app "$TMP_APP" "My App" "$TMP_DIAG" 2> /dev/null || true)

assert_contains "$out" "MyApp_2025-02-10-120000" "returns .ips file"
assert_contains "$out" "MyApp.crash" "returns .crash file"
assert_contains "$out" "MyApp_2025-02-10-120001" "returns .spin file"
assert_contains "$out" ".ips" "output contains .ips path"
if [[ "$out" == *"OtherApp"* ]]; then
    echo "  FAIL should not return OtherApp"
    ((FAILED++))
else
    echo "  OK does not return OtherApp"
    ((PASSED++))
fi
if [[ "$out" == *"MyApp_log.txt"* ]]; then
    echo "  FAIL should not return non-diagnostic extension"
    ((FAILED++))
else
    echo "  OK does not return .txt file"
    ((PASSED++))
fi

rm -rf "$TMP_DIAG" "$TMP_APP" 2> /dev/null || true

TMP_DIAG2=$(mktemp -d 2> /dev/null || mktemp -d -t mole-diag2 2> /dev/null || echo "/tmp/mole-diag2-$$")
TMP_APP2=$(mktemp -d 2> /dev/null || mktemp -d -t mole-app2 2> /dev/null || echo "/tmp/mole-app2-$$")
mkdir -p "$TMP_DIAG2" "$TMP_APP2"
mkdir -p "$TMP_APP2/Contents"
touch "$TMP_DIAG2/TestApp_2025-02-10.ips"

out=$(get_diagnostic_report_paths_for_app "$TMP_APP2" "Test App" "$TMP_DIAG2" 2> /dev/null || true)
assert_contains "$out" "TestApp_" "fallback to nospace app name matches file"

rm -rf "$TMP_DIAG2" "$TMP_APP2" 2> /dev/null || true

echo ""
echo "Result: $PASSED passed, $FAILED failed"
if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
echo "All DiagnosticReports tests passed."
exit 0
