# Fix Python Bytecode Output Spam Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the 3000+ line output spam when `mo clean` encounters many `__pycache__` directories, reducing output to grouped summary lines.

**Architecture:** Two surgical fixes in `lib/clean/caches.sh`: (1) filter empty `__pycache__` dirs at scan time so they never enter the pipeline, (2) suppress output lines where total cleaned size is 0 B. Both changes are backward-compatible and follow tw93's precedent of hiding zero-size entries (PR #664).

**Tech Stack:** Bash, bats (testing)

**Resolves:** [tw93/Mole#633](https://github.com/tw93/Mole/issues/633)

---

### Task 1: Filter empty `__pycache__` dirs at scan time

**Files:**
- Modify: `lib/clean/caches.sh:214-222` (inside `scan_project_cache_root`, the while-read loop)
- Test: `tests/clean_system_caches.bats`

- [ ] **Step 1: Write failing test — empty `__pycache__` dirs are excluded from scan**

Add this test to `tests/clean_system_caches.bats` after the existing `"clean_project_caches groups pycache directories by project root"` test (after line 197):

```bash
@test "clean_project_caches skips empty pycache directories" {
    mkdir -p "$HOME/Projects/python-app/pkg/__pycache__"
    mkdir -p "$HOME/Projects/python-app/empty/__pycache__"
    touch "$HOME/Projects/python-app/pyproject.toml"
    touch "$HOME/Projects/python-app/pkg/__pycache__/module.pyc"
    # empty/__pycache__ has no .pyc files

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
DRY_RUN=true
clean_project_caches
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"Python bytecode cache"* ]]
    [[ "$output" == *"1 dirs"* ]]

    rm -rf "$HOME/Projects"
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/clean_system_caches.bats --filter "skips empty pycache"`
Expected: FAIL — output will show `2 dirs` instead of `1 dirs` because the empty `__pycache__` is still included.

- [ ] **Step 3: Implement the filter in `scan_project_cache_root`**

In `lib/clean/caches.sh`, inside the `scan_project_cache_root` function, modify the while-read loop (lines 215-221) to skip `__pycache__` dirs that contain no `.pyc` or `.pyo` files:

Replace:
```bash
    if [[ -s "$tmp_file" ]]; then
        while IFS= read -r match_path; do
            [[ -z "$match_path" ]] && continue
            local project_root=""
            project_root=$(project_cache_group_root "$root" "$match_path")
            [[ -z "$project_root" ]] && project_root="$root"
            printf '%s\t%s\n' "$project_root" "$match_path" >> "$output_file"
        done < "$tmp_file"
    fi
```

With:
```bash
    if [[ -s "$tmp_file" ]]; then
        while IFS= read -r match_path; do
            [[ -z "$match_path" ]] && continue
            # Skip __pycache__ dirs with no .pyc/.pyo files (empty or already cleaned)
            if [[ "${match_path##*/}" == "__pycache__" ]]; then
                local has_bytecode
                has_bytecode=$(find "$match_path" -maxdepth 1 -name '*.pyc' -o -name '*.pyo' 2>/dev/null | head -1)
                [[ -z "$has_bytecode" ]] && continue
            fi
            local project_root=""
            project_root=$(project_cache_group_root "$root" "$match_path")
            [[ -z "$project_root" ]] && project_root="$root"
            printf '%s\t%s\n' "$project_root" "$match_path" >> "$output_file"
        done < "$tmp_file"
    fi
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/clean_system_caches.bats --filter "skips empty pycache"`
Expected: PASS

- [ ] **Step 5: Run all existing pycache-related tests to verify no regressions**

Run: `bats tests/clean_system_caches.bats --filter "pycache|project_caches"`
Expected: All pass (including the grouping and dry-run export tests).

- [ ] **Step 6: Commit**

```bash
git add lib/clean/caches.sh tests/clean_system_caches.bats
git commit -m "fix(clean): skip empty __pycache__ dirs during project cache scan

Filter out __pycache__ directories that contain no .pyc/.pyo files
at scan time. These empty dirs produce 0 B output lines that spam
the terminal when running mo clean.

Closes tw93/Mole#633"
```

---

### Task 2: Suppress 0 B output lines in `clean_python_bytecode_cache_group`

**Files:**
- Modify: `lib/clean/caches.sh:384-386` (inside `clean_python_bytecode_cache_group`, the early return check)
- Test: `tests/clean_system_caches.bats`

- [ ] **Step 1: Write failing test — 0 B groups produce no output**

Add this test to `tests/clean_system_caches.bats`:

```bash
@test "clean_python_bytecode_cache_group suppresses 0 B output" {
    mkdir -p "$HOME/Projects/python-app/pkg/__pycache__"
    touch "$HOME/Projects/python-app/pyproject.toml"
    # Create a .pyc file with zero size (passes the scan filter but has 0 B)
    touch "$HOME/Projects/python-app/pkg/__pycache__/module.pyc"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
DRY_RUN=true
# Override get_path_size_kb to always return 0
get_path_size_kb() { echo "0"; }
clean_project_caches
EOF
    [ "$status" -eq 0 ]
    [[ "$output" != *"Python bytecode cache"* ]]

    rm -rf "$HOME/Projects"
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/clean_system_caches.bats --filter "suppresses 0 B"`
Expected: FAIL — the line still prints "Python bytecode cache · python-app, 1 dirs, 0 B dry"

- [ ] **Step 3: Add the 0 B suppression check**

In `lib/clean/caches.sh`, in the `clean_python_bytecode_cache_group` function, after the loop that processes cache dirs (after line 382), modify the early return to also suppress 0 B groups:

Replace:
```bash
    if [[ $removed_count -eq 0 ]]; then
        return 0
    fi
```

With:
```bash
    if [[ $removed_count -eq 0 || $total_size_kb -eq 0 ]]; then
        # Still count removals for global stats, but suppress output for 0 B groups
        if [[ $removed_count -gt 0 ]]; then
            files_cleaned=$((${files_cleaned:-0} + removed_count))
        fi
        return 0
    fi
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/clean_system_caches.bats --filter "suppresses 0 B"`
Expected: PASS

- [ ] **Step 5: Run ALL pycache and project cache tests**

Run: `bats tests/clean_system_caches.bats --filter "pycache|project_caches|suppresses"`
Expected: All pass.

- [ ] **Step 6: Commit**

```bash
git add lib/clean/caches.sh tests/clean_system_caches.bats
git commit -m "fix(clean): suppress 0 B Python bytecode output lines

Hide output lines where the total cleaned size is 0 B, consistent
with the zero-size suppression pattern used in mo analyze (PR #664).
The removal still happens, but users don't see useless noise."
```

---

### Task 3: Add scan performance guard for conda/miniconda/anaconda

**Files:**
- Modify: `lib/clean/caches.sh:200-203` (the `find` prune list in `scan_project_cache_root`)
- Test: `tests/clean_system_caches.bats`

- [ ] **Step 1: Write failing test — conda dirs are pruned from scan**

```bash
@test "scan_project_cache_root prunes conda environments" {
    mkdir -p "$HOME/Projects/miniconda3/lib/python3.11/site-packages/pkg1/__pycache__"
    mkdir -p "$HOME/Projects/miniconda3/lib/python3.11/site-packages/pkg2/__pycache__"
    mkdir -p "$HOME/Projects/app/__pycache__"
    touch "$HOME/Projects/miniconda3/lib/python3.11/site-packages/pkg1/__pycache__/mod.pyc"
    touch "$HOME/Projects/miniconda3/lib/python3.11/site-packages/pkg2/__pycache__/mod.pyc"
    touch "$HOME/Projects/app/pyproject.toml"
    touch "$HOME/Projects/app/__pycache__/mod.pyc"

    local output_file
    output_file=$(mktemp)

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<EOF
set -euo pipefail
source "\$PROJECT_ROOT/lib/core/common.sh"
source "\$PROJECT_ROOT/lib/clean/caches.sh"
scan_project_cache_root "$HOME/Projects" "$output_file"
cat "$output_file"
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"app/__pycache__"* ]]
    [[ "$output" != *"miniconda3"* ]]

    rm -rf "$HOME/Projects" "$output_file"
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/clean_system_caches.bats --filter "prunes conda"`
Expected: FAIL — miniconda3 paths appear in output.

- [ ] **Step 3: Add conda dirs to the find prune list**

In `lib/clean/caches.sh`, in the `scan_project_cache_root` function, add conda-related directories to the prune list (line 202):

Replace:
```bash
        "(" -name "Library" -o -name ".Trash" -o -name "node_modules" -o -name ".git" -o -name ".svn" -o -name ".hg" -o -name ".venv" -o -name "venv" -o -name ".pnpm-store" -o -name ".fvm" -o -name "DerivedData" -o -name "Pods" ")"
```

With:
```bash
        "(" -name "Library" -o -name ".Trash" -o -name "node_modules" -o -name ".git" -o -name ".svn" -o -name ".hg" -o -name ".venv" -o -name "venv" -o -name ".pnpm-store" -o -name ".fvm" -o -name "DerivedData" -o -name "Pods" -o -name "miniconda3" -o -name "anaconda3" -o -name "miniforge3" -o -name "mambaforge" -o -name "site-packages" ")"
```

Note: adding `site-packages` is the most surgical fix — it prunes ALL Python package install dirs, regardless of which conda/virtualenv tool created them. This is safe because `site-packages` `__pycache__` dirs are regenerated automatically by Python and should not be cleaned by a system tool (they are part of installed packages).

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/clean_system_caches.bats --filter "prunes conda"`
Expected: PASS

- [ ] **Step 5: Run full test suite for regressions**

Run: `bats tests/clean_system_caches.bats`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/clean/caches.sh tests/clean_system_caches.bats
git commit -m "fix(clean): prune conda and site-packages from project cache scan

Add miniconda3, anaconda3, miniforge3, mambaforge, and site-packages
to the find prune list in scan_project_cache_root. These directories
contain thousands of __pycache__ dirs from installed packages that
should not be cleaned, and traversing them causes 10-15 minute scans."
```

---

### Task 4: Final validation

**Files:** None (test-only)

- [ ] **Step 1: Run the full clean_system_caches test suite**

Run: `bats tests/clean_system_caches.bats`
Expected: All tests pass, including all pre-existing tests.

- [ ] **Step 2: Run all project tests for regression check**

Run: `bats tests/`
Expected: All test files pass. Watch for any test that depends on empty `__pycache__` dirs being processed.

- [ ] **Step 3: Manual smoke test with `mo clean --dry-run`**

Run: `./mole clean --dry-run 2>&1 | grep -c "Python bytecode"`
Expected: Should show a small number of grouped lines (not hundreds). Each line should show a meaningful size.

- [ ] **Step 4: Create feature branch and push**

```bash
git checkout -b fix/python-bytecode-spam
git push -u origin fix/python-bytecode-spam
```

- [ ] **Step 5: Create PR against tw93/Mole**

Create PR with title: `fix(clean): reduce Python bytecode output spam`

Body should reference issue #633 and describe the three changes:
1. Skip empty `__pycache__` dirs at scan time
2. Suppress 0 B output lines
3. Prune conda/site-packages from scan tree
