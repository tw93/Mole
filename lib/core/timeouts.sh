#!/bin/bash
# Mole - Centralized timeout constants for run_with_timeout calls.
#
# Goal: when someone needs to tune "all quick command-availability probes"
# or "all package-manager cleanup ceilings", they edit ONE place instead
# of grepping 100+ call sites.
#
# Naming: MOLE_TIMEOUT_<CATEGORY>_SEC. All values are seconds (integer or
# fractional). All are overridable via the same-named env var so operators
# can lengthen them for slow disks / cold Spotlight / etc.
#
# Categories (with rationale, not "what they happen to be tuned to"):
#
#   QUICK_DETECT      command -v + version-check style probes. Should fail
#                     fast when the tool is missing or wedged. ~2s.
#   SHORT_QUERY       Lightweight subprocess query (df, tmutil status). ~3s.
#   MEDIUM_PROBE      Heavier probe that occasionally talks to the network
#                     or scans a directory tree. ~5s.
#   PKG_LIST          Package manager listing (brew list, simctl list). ~10s.
#   PKG_CLEANUP       Cache cleanup commands that walk disks. ~20s.
#   DISK_VERIFY       Filesystem-level verify/repair operations. ~30s.
#   HINT_SCAN         Non-destructive scan that walks an unbounded user
#                     directory tree (project-artifact discovery, preference
#                     plist lint). Per-listing finds are already capped; this is
#                     the cumulative wall-clock ceiling for the whole walk so it
#                     can never appear hung. ~15s.
#
# Migration: new code should use these constants. Existing call sites can
# be migrated incrementally; the script `grep 'run_with_timeout [0-9]'` lists
# remaining literal-timeout calls.
#
# Intentionally NOT in this table (values that appear hardcoded in lib/):
#
#   1s    Volume/filesystem type probes that should be near-instant on a
#         healthy disk: `df -T`, `diskutil info`, `find -maxdepth 1`. A
#         wedge here usually means the volume itself is sick; failing fast
#         is the right behavior.
#   8s    External tool calls that are too slow for MEDIUM_PROBE (5s) but
#         shouldn't pay the PKG_LIST (10s) ceiling: `hdiutil info`,
#         `brew outdated`, `simctl list` warm-up retry. Also the deep
#         `find /private/var/folders -maxdepth 8` GPU-cache scan in
#         lib/clean/system.sh - same "occasionally slow disk probe" shape.
#   15s   Long-running maintenance ops on user-selected targets:
#         `hdiutil detach`, `lsregister -r -f`, Time Machine backupdb
#         `find`. Different shape from PKG_CLEANUP (20s, brew/conda) -
#         keep them apart so tuning one doesn't move the other.
#   0.2s  Per-app inline mdls probe in the uninstall scan tight loop. Tens
#         to hundreds of invocations per scan; bucket constants would
#         imply this is reusable elsewhere, which it isn't.
#
# If you find yourself adding a new use of one of these literals, consider
# whether a bucket actually exists for it before copying the magic number.

set -euo pipefail

if [[ -n "${MOLE_TIMEOUTS_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_TIMEOUTS_LOADED=1

readonly MOLE_TIMEOUT_QUICK_DETECT_SEC="${MOLE_TIMEOUT_QUICK_DETECT_SEC:-2}"
readonly MOLE_TIMEOUT_SHORT_QUERY_SEC="${MOLE_TIMEOUT_SHORT_QUERY_SEC:-3}"
readonly MOLE_TIMEOUT_MEDIUM_PROBE_SEC="${MOLE_TIMEOUT_MEDIUM_PROBE_SEC:-5}"
readonly MOLE_TIMEOUT_PKG_LIST_SEC="${MOLE_TIMEOUT_PKG_LIST_SEC:-10}"
readonly MOLE_TIMEOUT_PKG_CLEANUP_SEC="${MOLE_TIMEOUT_PKG_CLEANUP_SEC:-20}"
readonly MOLE_TIMEOUT_DISK_VERIFY_SEC="${MOLE_TIMEOUT_DISK_VERIFY_SEC:-30}"
readonly MOLE_TIMEOUT_HINT_SCAN_SEC="${MOLE_TIMEOUT_HINT_SCAN_SEC:-15}"
readonly MOLE_TIMEOUT_TERRAFORM_SCAN_SEC="${MOLE_TIMEOUT_TERRAFORM_SCAN_SEC:-15}"
