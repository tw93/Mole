#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-api-home.XXXXXX")"
    export HOME
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    rm -rf "${HOME:?}"/*
    mkdir -p "$HOME/.config/roomy" "$HOME/bin"
}

@test "roomy api status delegates to status JSON binary" {
    cat > "$HOME/bin/status-go" <<'SCRIPT'
#!/usr/bin/env bash
[[ "$1" == "--json" ]] || exit 2
printf '{"host":"api-test","health_score":91,"cpu":{"usage":4,"logical_cpu":8},"memory":{"used":1,"total":2,"used_percent":50},"disks":[]}\n'
SCRIPT
    chmod +x "$HOME/bin/status-go"

    run env HOME="$HOME" ROOMY_TEST_STATUS_BIN="$HOME/bin/status-go" "$PROJECT_ROOT/roomy" api status

    [ "$status" -eq 0 ]
    echo "$output" | python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["host"]=="api-test"; assert data["health_score"]==91'
}

@test "roomy api storage scan delegates path to analyze JSON binary" {
    cat > "$HOME/bin/analyze-go" <<'SCRIPT'
#!/usr/bin/env bash
[[ "$1" == "--json" ]] || exit 2
printf '{"path":"%s","overview":false,"entries":[],"large_files":[],"total_size":0,"total_files":0}\n' "$2"
SCRIPT
    chmod +x "$HOME/bin/analyze-go"

    run env HOME="$HOME" ROOMY_TEST_ANALYZE_BIN="$HOME/bin/analyze-go" "$PROJECT_ROOT/roomy" api storage scan --path "$HOME"

    [ "$status" -eq 0 ]
    echo "$output" | python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["path"]'
}

@test "roomy api storage execute streams dry-run Trash events for scanned files" {
    scan_root="$HOME/Downloads"
    target="$scan_root/Large.bin"
    mkdir -p "$scan_root"
    printf 'large-file' > "$target"
    plan="$HOME/storage-plan.json"
    printf '{"confirmed": true, "dry_run": true, "operation": "trash", "scan_path": "%s", "targets": ["%s"]}\n' "$scan_root" "$target" > "$plan"

    run env HOME="$HOME" "$PROJECT_ROOT/roomy" api storage execute --plan "$plan"

    [ "$status" -eq 0 ]
    [ -f "$target" ]
    echo "$output" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
assert events[0]["event"] == "started"
assert events[0]["domain"] == "storage"
assert any(event.get("message") == "Would move item to Trash" for event in events)
assert events[-1]["event"] == "completed"
'
}

@test "roomy api storage execute refuses targets outside scan root" {
    scan_root="$HOME/Downloads"
    outside="$HOME/Desktop/Outside.bin"
    mkdir -p "$scan_root" "$HOME/Desktop"
    printf 'outside' > "$outside"
    plan="$HOME/storage-refuse-plan.json"
    printf '{"confirmed": true, "dry_run": true, "operation": "trash", "scan_path": "%s", "targets": ["%s"]}\n' "$scan_root" "$outside" > "$plan"

    run env HOME="$HOME" "$PROJECT_ROOT/roomy" api storage execute --plan "$plan"

    [ "$status" -ne 0 ]
    [ -f "$outside" ]
    echo "$output" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
assert events[-1]["event"] == "failed"
assert any(event.get("event") == "skipped" for event in events)
'
}

@test "roomy api storage execute refuses symlinked directories outside scan root" {
    scan_root="$HOME/Downloads"
    outside_dir="$HOME/Desktop/OutsideDir"
    linked_dir="$scan_root/OutsideLink"
    mkdir -p "$scan_root" "$outside_dir"
    printf 'outside' > "$outside_dir/keep.bin"
    ln -s "$outside_dir" "$linked_dir"
    plan="$HOME/storage-symlink-refuse-plan.json"
    printf '{"confirmed": true, "dry_run": true, "operation": "trash", "scan_path": "%s", "targets": ["%s"]}\n' "$scan_root" "$linked_dir" > "$plan"

    run env HOME="$HOME" "$PROJECT_ROOT/roomy" api storage execute --plan "$plan"

    [ "$status" -ne 0 ]
    [ -L "$linked_dir" ]
    [ -f "$outside_dir/keep.bin" ]
    echo "$output" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
assert events[-1]["event"] == "failed"
skipped = next(event for event in events if event.get("event") == "skipped")
assert skipped["message"] == "Path is outside the scanned folder"
assert skipped["scan_path"].endswith("/Downloads")
assert skipped["path"].endswith("/Desktop/OutsideDir")
'
}

@test "roomy api storage execute can trash broken symlink targets inside scan root" {
    scan_root="$HOME/storage-root"
    mkdir -p "$scan_root" "$HOME/.Trash"
    target="$scan_root/broken-link"
    ln -s "$scan_root/missing-target" "$target"
    plan="$HOME/storage-broken-link-plan.json"
    printf '{"confirmed": true, "operation": "trash", "scan_path": "%s", "targets": ["%s"]}\n' "$scan_root" "$target" > "$plan"

    run env HOME="$HOME" ROOMY_TEST_TRASH_DIR="$HOME/.Trash" "$PROJECT_ROOT/roomy" api storage execute --plan "$plan"

    [ "$status" -eq 0 ]
    echo "$output" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
assert events[-1]["event"] == "completed", events
assert events[-1]["domain"] == "storage", events
assert events[-1]["item_count"] == 1, events
'
    [[ ! -e "$target" && ! -L "$target" ]]
    find "$HOME/.Trash" -type l -name 'broken-link*' -print -quit | grep -q .
}

@test "roomy api clean preview returns structured cleanup JSON" {
    mkdir -p "$HOME/Library/Caches/TestApp"
    printf 'cache' > "$HOME/Library/Caches/TestApp/file.tmp"

    run env HOME="$HOME" ROOMY_TEST_MODE=1 "$PROJECT_ROOT/roomy" api clean preview --json

    [ "$status" -eq 0 ]
    echo "$output" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["command"] == "clean.preview"
assert data["dry_run"] is True
assert "categories" in data
assert "estimated_bytes" in data
'
}

@test "roomy api clean preview supports external volume cleanup" {
    root="$HOME/Volumes"
    volume="$root/TestVolume"
    mkdir -p "$volume/.Trashes" "$volume/Folder"
    printf 'trash' > "$volume/.Trashes/item"
    printf 'metadata' > "$volume/Folder/._file"

    run env HOME="$HOME" ROOMY_EXTERNAL_VOLUMES_ROOT="$root" "$PROJECT_ROOT/roomy" api clean preview --json --external "$volume"

    [ "$status" -eq 0 ]
    echo "$output" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["command"] == "clean.preview"
assert data["category_count"] >= 1
assert any(category["section"] == "External volume" for category in data["categories"])
'
}

@test "roomy api optimize preview returns health JSON" {
    run env HOME="$HOME" "$PROJECT_ROOT/roomy" api optimize preview

    [ "$status" -eq 0 ]
    echo "$output" | python3 -c 'import json,sys; data=json.load(sys.stdin); assert "optimizations" in data; assert len(data["optimizations"]) > 0'
}

@test "roomy api installer preview returns selectable installer files" {
    target="$HOME/Downloads/Test.DMG"
    mkdir -p "$HOME/Downloads"
    printf 'dmg' > "$target"

    run env HOME="$HOME" "$PROJECT_ROOT/roomy" api installer preview --json

    [ "$status" -eq 0 ]
    echo "$output" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["command"] == "installer.preview"
assert data["item_count"] == 1
assert data["items"][0]["path"].endswith("Test.DMG")
'
}

@test "roomy api purge preview returns revalidatable project artifacts" {
    artifact="$HOME/Projects/App/node_modules"
    mkdir -p "$artifact"
    printf 'module' > "$artifact/package.txt"
    printf '{}\n' > "$HOME/Projects/App/package.json"

    run env HOME="$HOME" "$PROJECT_ROOT/roomy" api purge preview --json

    [ "$status" -eq 0 ]
    echo "$output" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["command"] == "purge.preview"
assert data["item_count"] >= 1
assert any(item["path"].endswith("node_modules") for item in data["items"])
'
}

@test "roomy api purge execute validates targets before dry-run progress" {
    project="$HOME/Projects/App"
    artifact="$project/node_modules"
    mkdir -p "$project"
    printf '{}\n' > "$project/package.json"
    ln -s /etc "$artifact"
    plan="$HOME/purge-execute-plan.json"
    printf '{"confirmed": true, "dry_run": true, "targets": ["%s"]}\n' "$artifact" > "$plan"

    run env HOME="$HOME" "$PROJECT_ROOT/roomy" api purge execute --plan "$plan"

    [ "$status" -ne 0 ]
    [ -L "$artifact" ]
    echo "$output" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
assert events[0]["event"] == "started"
assert events[-1]["event"] == "failed"
skipped = next(event for event in events if event.get("event") == "skipped")
assert skipped["message"] == "Path failed deletion validation"
assert not any(event.get("message") == "Would remove project artifact" for event in events)
'
}

@test "roomy api execute refuses unconfirmed plans with NDJSON failure event" {
    plan="$HOME/plan.json"
    printf '{"confirmed": false, "dry_run": true}\n' > "$plan"

    run env HOME="$HOME" "$PROJECT_ROOT/roomy" api clean execute --plan "$plan"

    [ "$status" -ne 0 ]
    echo "$output" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
assert events[0]["event"] == "started"
assert events[-1]["event"] == "failed"
'
}

@test "roomy api execute validates plan schema before action dispatch" {
    plan="$HOME/bad-installer-plan.json"
    printf '{"confirmed": true, "dry_run": true, "targets": "%s"}\n' "$HOME/Downloads/Test.dmg" > "$plan"

    run env HOME="$HOME" "$PROJECT_ROOT/roomy" api installer execute --plan "$plan"

    [ "$status" -ne 0 ]
    echo "$output" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
assert events[0]["event"] == "started"
assert events[-1]["event"] == "failed"
assert "targets" in events[-1]["message"]
assert "array" in events[-1]["message"]
'
}

@test "roomy api storage execute rejects invalid operations during plan validation" {
    scan_root="$HOME/Downloads"
    target="$scan_root/Test.bin"
    mkdir -p "$scan_root"
    printf 'data' > "$target"
    plan="$HOME/storage-invalid-operation-plan.json"
    printf '{"confirmed": true, "dry_run": true, "operation": "delete", "scan_path": "%s", "targets": ["%s"]}\n' "$scan_root" "$target" > "$plan"

    run env HOME="$HOME" "$PROJECT_ROOT/roomy" api storage execute --plan "$plan"

    [ "$status" -ne 0 ]
    echo "$output" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
assert events[0]["event"] == "started"
assert events[-1]["event"] == "failed"
assert "operation" in events[-1]["message"]
assert "reveal, open, or trash" in events[-1]["message"]
'
}

@test "roomy api completion status returns shell integration JSON" {
    run env HOME="$HOME" SHELL=/bin/zsh "$PROJECT_ROOT/roomy" api completion status

    [ "$status" -eq 0 ]
    echo "$output" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["shell"] == "zsh"
assert "config_file" in data
assert "installed" in data
'
}

@test "roomy api launchers status returns Raycast and Alfred setup JSON" {
    run env HOME="$HOME" "$PROJECT_ROOT/roomy" api launchers status

    [ "$status" -eq 0 ]
    echo "$output" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["schema_version"] == 1
assert data["command_count"] == 5
assert any(command["command"] == "clean" for command in data["commands"])
assert "raycast_dir" in data
assert "alfred_dir" in data
'
}

@test "roomy api update status returns Roomy maintenance JSON" {
    run env HOME="$HOME" "$PROJECT_ROOT/roomy" api update status

    [ "$status" -eq 0 ]
    echo "$output" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["schema_version"] == 1
assert data["version"]
assert data["channel"] in ("stable", "nightly", "dev")
assert data["cli_path"].endswith("/roomy")
'
}

@test "roomy api purge paths update writes scan roots through a plan" {
    plan="$HOME/purge-paths-plan.json"
    mkdir -p "$HOME/Work"
    printf '{"confirmed": true, "paths": ["%s"]}\n' "$HOME/Work" > "$plan"

    run env HOME="$HOME" "$PROJECT_ROOT/roomy" api purge paths update --plan "$plan"

    [ "$status" -eq 0 ]
    expected_config_path="${HOME/#$HOME/~}/Work"
    grep -q "$expected_config_path" "$HOME/.config/roomy/purge_paths"
    echo "$output" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
assert events[-1]["event"] == "completed"
assert events[-1]["domain"] == "purge_paths"
'

    run env HOME="$HOME" "$PROJECT_ROOT/roomy" api purge paths --json

    [ "$status" -eq 0 ]
    echo "$output" | HOME="$HOME" python3 -c '
import json, os, sys
data = json.load(sys.stdin)
assert os.path.join(os.environ["HOME"], "Work") in data["paths"]
'
}

@test "roomy api whitelist update allows clearing all patterns" {
    plan="$HOME/whitelist-clear-plan.json"
    printf '{"confirmed": true, "patterns": []}\n' > "$plan"

    run env HOME="$HOME" "$PROJECT_ROOT/roomy" api whitelist update --mode clean --plan "$plan"

    [ "$status" -eq 0 ]
    echo "$output" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
assert events[-1]["event"] == "completed"
assert events[-1]["domain"] == "whitelist"
assert events[-1]["pattern_count"] == 0
'
    [ -f "$HOME/.config/roomy/whitelist" ]
    [ -z "$(grep -Ev '^[[:space:]]*(#|$)' "$HOME/.config/roomy/whitelist" || true)" ]
}

@test "roomy api whitelist update reports config write failures as NDJSON" {
    plan="$HOME/whitelist-write-failure-plan.json"
    printf '{"confirmed": true, "patterns": ["%s"]}\n' "$HOME/KeepMe" > "$plan"
    chmod 500 "$HOME/.config/roomy"

    run env HOME="$HOME" "$PROJECT_ROOT/roomy" api whitelist update --mode clean --plan "$plan"
    chmod 700 "$HOME/.config/roomy"

    [ "$status" -ne 0 ]
    echo "$output" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
assert events[0]["event"] == "started"
assert events[-1]["event"] == "failed"
assert events[-1]["domain"] == "whitelist"
assert "Could not write whitelist" in events[-1]["message"]
'
}

@test "roomy api purge paths update allows clearing all scan roots" {
    plan="$HOME/purge-paths-clear-plan.json"
    printf '{"confirmed": true, "paths": []}\n' > "$plan"

    run env HOME="$HOME" "$PROJECT_ROOT/roomy" api purge paths update --plan "$plan"

    [ "$status" -eq 0 ]
    echo "$output" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
assert events[-1]["event"] == "completed"
assert events[-1]["domain"] == "purge_paths"
assert events[-1]["path_count"] == 0
'
    [ -f "$HOME/.config/roomy/purge_paths" ]
    [ -z "$(grep -Ev '^[[:space:]]*(#|$)' "$HOME/.config/roomy/purge_paths" || true)" ]
}

@test "roomy api purge paths update reports config write failures as NDJSON" {
    plan="$HOME/purge-paths-write-failure-plan.json"
    mkdir -p "$HOME/Work"
    printf '{"confirmed": true, "paths": ["%s"]}\n' "$HOME/Work" > "$plan"
    chmod 500 "$HOME/.config/roomy"

    run env HOME="$HOME" "$PROJECT_ROOT/roomy" api purge paths update --plan "$plan"
    chmod 700 "$HOME/.config/roomy"

    [ "$status" -ne 0 ]
    echo "$output" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
assert events[0]["event"] == "started"
assert events[-1]["event"] == "failed"
assert events[-1]["domain"] == "purge_paths"
assert "Could not write project scan paths" in events[-1]["message"]
'
}

@test "roomy api purge paths update rejects unsafe scan roots" {
    plan="$HOME/purge-paths-plan.json"
    mkdir -p "$HOME/Work"
    printf '%s\n' "$HOME/Work" > "$HOME/.config/roomy/purge_paths"
    printf '{"confirmed": true, "paths": ["/", "%s", "relative/project"]}\n' "$HOME" > "$plan"

    run env HOME="$HOME" "$PROJECT_ROOT/roomy" api purge paths update --plan "$plan"

    [ "$status" -ne 0 ]
    echo "$output" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
assert events[-1]["event"] == "failed"
assert events[-1]["domain"] == "purge_paths"
assert "Unsafe project scan path" in events[-1]["message"]
'
    grep -qx "$HOME/Work" "$HOME/.config/roomy/purge_paths"
    [ ! -e "$HOME/pwned" ]
}

@test "roomy api purge paths update rejects control-character paths before writing config" {
    plan="$HOME/purge-paths-control-plan.json"
    mkdir -p "$HOME/Work"
    printf '%s\n' "$HOME/Work" > "$HOME/.config/roomy/purge_paths"
    printf '{"confirmed": true, "paths": ["%s"]}\n' "$HOME/Bad\\nPath" > "$plan"

    run env HOME="$HOME" "$PROJECT_ROOT/roomy" api purge paths update --plan "$plan"

    [ "$status" -ne 0 ]
    echo "$output" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
assert events[-1]["event"] == "failed"
assert events[-1]["domain"] == "purge_paths"
assert "control characters" in events[-1]["message"]
'
    grep -qx "$HOME/Work" "$HOME/.config/roomy/purge_paths"
}

@test "roomy api launchers execute streams dry-run events" {
    plan="$HOME/launchers-plan.json"
    printf '{"confirmed": true, "dry_run": true}\n' > "$plan"

    run env HOME="$HOME" "$PROJECT_ROOT/roomy" api launchers execute --plan "$plan"

    [ "$status" -eq 0 ]
    echo "$output" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
assert events[0]["event"] == "started"
assert any(event.get("domain") == "launchers" for event in events)
assert events[-1]["event"] == "completed"
'
}

@test "roomy api touchid execute streams dry-run events" {
    plan="$HOME/touchid-plan.json"
    printf '{"confirmed": true, "dry_run": true}\n' > "$plan"

    run env HOME="$HOME" "$PROJECT_ROOT/roomy" api touchid execute --action enable --plan "$plan"

    [ "$status" -eq 0 ]
    echo "$output" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
assert events[0]["event"] == "started"
assert any(event["event"] == "progress" for event in events)
assert events[-1]["event"] == "completed"
'
}

@test "roomy api completion execute streams dry-run events" {
    plan="$HOME/completion-plan.json"
    printf '{"confirmed": true, "dry_run": true}\n' > "$plan"

    run env HOME="$HOME" SHELL=/bin/zsh PATH="$PROJECT_ROOT:$PATH" "$PROJECT_ROOT/roomy" api completion execute --plan "$plan"

    [ "$status" -eq 0 ]
    echo "$output" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
assert events[0]["event"] == "started"
assert events[-1]["event"] == "completed"
'
}

@test "roomy api update execute streams dry-run events" {
    plan="$HOME/update-plan.json"
    printf '{"confirmed": true, "dry_run": true, "force": true}\n' > "$plan"

    run env HOME="$HOME" "$PROJECT_ROOT/roomy" api update execute --plan "$plan"

    [ "$status" -eq 0 ]
    echo "$output" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
assert events[0]["event"] == "started"
assert any(event.get("domain") == "update" for event in events)
assert events[-1]["event"] == "completed"
'
}

@test "roomy api remove execute streams dry-run events" {
    mkdir -p "$HOME/.local/bin" "$HOME/.config/roomy"
    printf '#!/usr/bin/env bash\n' > "$HOME/.local/bin/roomy"
    chmod +x "$HOME/.local/bin/roomy"
    plan="$HOME/remove-plan.json"
    printf '{"confirmed": true, "dry_run": true}\n' > "$plan"

    run env HOME="$HOME" ROOMY_TEST_MODE=1 "$PROJECT_ROOT/roomy" api remove execute --plan "$plan"

    [ "$status" -eq 0 ]
    [ -f "$HOME/.local/bin/roomy" ]
    echo "$output" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
assert events[0]["event"] == "started"
assert any(event.get("domain") == "remove" for event in events)
assert events[-1]["event"] == "completed"
'
}

@test "roomy api installer execute streams dry-run events" {
    target="$HOME/Downloads/Test.PKG"
    mkdir -p "$HOME/Downloads"
    printf 'pkg' > "$target"
    plan="$HOME/installer-plan.json"
    printf '{"confirmed": true, "dry_run": true, "targets": ["%s"]}\n' "$target" > "$plan"

    run env HOME="$HOME" "$PROJECT_ROOT/roomy" api installer execute --plan "$plan"

    [ "$status" -eq 0 ]
    [ -f "$target" ]
    echo "$output" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
assert events[0]["event"] == "started"
assert any(event["event"] == "progress" for event in events)
assert events[-1]["event"] == "completed"
'
}

@test "roomy api installer execute removes broken installer symlinks" {
    target="$HOME/Downloads/Old.dmg"
    mkdir -p "$HOME/Downloads"
    ln -s "$HOME/Downloads/Missing.dmg" "$target"
    plan="$HOME/installer-broken-link-plan.json"
    printf '{"confirmed": true, "targets": ["%s"]}\n' "$target" > "$plan"

    run env HOME="$HOME" "$PROJECT_ROOT/roomy" api installer execute --plan "$plan"

    [ "$status" -eq 0 ]
    [ ! -L "$target" ]
    echo "$output" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
assert events[0]["event"] == "started"
assert any(event.get("message") == "Removed installer" for event in events)
assert events[-1]["event"] == "completed"
assert events[-1]["removed_count"] == 1
'
}

@test "roomy api installer execute refuses non-installer zip targets" {
    target="$HOME/Downloads/Archive.ZIP"
    mkdir -p "$HOME/Downloads"
    printf 'not a zip with installer payload' > "$target"
    plan="$HOME/installer-zip-plan.json"
    printf '{"confirmed": true, "targets": ["%s"]}\n' "$target" > "$plan"

    run env HOME="$HOME" "$PROJECT_ROOT/roomy" api installer execute --plan "$plan"

    [ "$status" -ne 0 ]
    [ -f "$target" ]
    echo "$output" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
assert events[0]["event"] == "started"
skipped = next(event for event in events if event.get("event") == "skipped")
assert skipped["message"] == "ZIP does not contain installer payload"
assert events[-1]["event"] == "failed"
'
}

@test "roomy api clean execute streams external dry-run events" {
    root="$HOME/Volumes"
    volume="$root/TestVolume"
    mkdir -p "$volume/.Trashes"
    printf 'trash' > "$volume/.Trashes/item"
    plan="$HOME/external-clean-plan.json"
    printf '{"confirmed": true, "dry_run": true, "external_path": "%s"}\n' "$volume" > "$plan"

    run env HOME="$HOME" ROOMY_EXTERNAL_VOLUMES_ROOT="$root" "$PROJECT_ROOT/roomy" api clean execute --plan "$plan"

    [ "$status" -eq 0 ]
    [ -f "$volume/.Trashes/item" ]
    echo "$output" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
assert events[0]["event"] == "started"
assert any(event["event"] == "progress" for event in events)
assert events[-1]["event"] == "completed"
'
}
