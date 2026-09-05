#!/bin/bash
# Optimize performance diagnosis helpers.

set -euo pipefail

readonly MOLE_OPTIMIZE_DIAG_CPU_THRESHOLD_DEFAULT=25
readonly MOLE_OPTIMIZE_DIAG_SAMPLE_DELAY_DEFAULT=1

opt_diag_cpu_threshold() {
    local threshold="${MOLE_OPTIMIZE_DIAG_CPU_THRESHOLD:-$MOLE_OPTIMIZE_DIAG_CPU_THRESHOLD_DEFAULT}"
    if ! [[ "$threshold" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        threshold="$MOLE_OPTIMIZE_DIAG_CPU_THRESHOLD_DEFAULT"
    fi
    printf '%s\n' "$threshold"
}

opt_diag_sample_delay() {
    local delay="${MOLE_OPTIMIZE_DIAG_SAMPLE_DELAY:-$MOLE_OPTIMIZE_DIAG_SAMPLE_DELAY_DEFAULT}"
    if ! [[ "$delay" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        delay="$MOLE_OPTIMIZE_DIAG_SAMPLE_DELAY_DEFAULT"
    fi
    printf '%s\n' "$delay"
}

opt_diag_float_ge() {
    local left="${1:-0}"
    local right="${2:-0}"
    awk -v left="$left" -v right="$right" 'BEGIN { exit !((left + 0) >= (right + 0)) }'
}

opt_diag_float_gt() {
    local left="${1:-0}"
    local right="${2:-0}"
    awk -v left="$left" -v right="$right" 'BEGIN { exit !((left + 0) > (right + 0)) }'
}

opt_diag_float_avg() {
    local left="${1:-0}"
    local right="${2:-0}"
    awk -v left="$left" -v right="$right" 'BEGIN { printf "%.1f\n", ((left + 0) + (right + 0)) / 2 }'
}

opt_diag_get_ps_sample() {
    local index="$1"
    local override=""

    case "$index" in
        1) override="${MOLE_OPTIMIZE_PS_SAMPLE_1:-}" ;;
        2) override="${MOLE_OPTIMIZE_PS_SAMPLE_2:-}" ;;
    esac

    if [[ -n "$override" ]]; then
        printf '%s\n' "$override"
        return 0
    fi

    ps -Aceo pcpu=,command= 2> /dev/null || true
}

opt_diag_get_spctl_status() {
    if [[ -n "${MOLE_OPTIMIZE_SPCTL_STATUS:-}" ]]; then
        printf '%s\n' "$MOLE_OPTIMIZE_SPCTL_STATUS"
        return 0
    fi

    spctl --status 2> /dev/null || true
}

opt_diag_get_hdiutil_info() {
    if [[ -n "${MOLE_OPTIMIZE_HDIUTIL_INFO:-}" ]]; then
        printf '%s\n' "$MOLE_OPTIMIZE_HDIUTIL_INFO"
        return 0
    fi

    run_with_timeout 8 hdiutil info 2> /dev/null || true # 8s: hdiutil info, see lib/core/timeouts.sh
}

opt_diag_family_totals() {
    local raw="${1:-}"
    awk '
    function classify(cmd, lower) {
        lower = tolower(cmd)
        if (lower ~ /cloudshell/ || lower ~ /alientsafe/ || lower ~ /aliedr/) return "cloudshell"
        if (lower ~ /(^|\/)syspolicyd([[:space:]]|$)/) return "syspolicyd"
        if (lower ~ /(^|\/)windowserver([[:space:]]|$)/) return "windowserver"
        if (lower ~ /(^|\/)mds([[:space:]]|$)/ || lower ~ /mdworker/ || lower ~ /mds_stores/ || lower ~ /mdbulkimport/) return "spotlight"
        if (lower ~ /diskimagesiod/ || lower ~ /simdiskimaged/) return "coresim_disk_images"
        return ""
    }
    {
        cpu = $1 + 0
        $1 = ""
        sub(/^[[:space:]]+/, "", $0)
        family = classify($0)
        if (family != "") sums[family] += cpu
    }
    END {
        printf "cloudshell\t%.1f\n", sums["cloudshell"] + 0
        printf "syspolicyd\t%.1f\n", sums["syspolicyd"] + 0
        printf "windowserver\t%.1f\n", sums["windowserver"] + 0
        printf "spotlight\t%.1f\n", sums["spotlight"] + 0
        printf "coresim_disk_images\t%.1f\n", sums["coresim_disk_images"] + 0
    }
    ' <<< "$raw"
}

opt_diag_family_total_for() {
    local totals="${1:-}"
    local family="$2"
    awk -F '\t' -v family="$family" '$1 == family { print $2; found = 1; exit } END { if (!found) print "0.0" }' <<< "$totals"
}

opt_diag_family_label() {
    case "$1" in
        cloudshell) printf '%s\n' "CloudShell / AliEntSafe" ;;
        syspolicyd) printf '%s\n' "syspolicyd" ;;
        windowserver) printf '%s\n' "WindowServer" ;;
        spotlight) printf '%s\n' "Spotlight indexing" ;;
        coresim_disk_images) printf '%s\n' "CoreSimulator disk images" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

opt_diag_family_note() {
    case "$1" in
        cloudshell)
            printf '%s\n' "External enterprise agent pressure detected. Mole will not terminate enterprise security processes; restart or policy checks must happen outside Mole."
            ;;
        syspolicyd)
            printf '%s\n' "Gatekeeper and code-signature assessment activity is elevated."
            ;;
        windowserver)
            printf '%s\n' "Desktop composition is busy. When another family is higher, treat this as a likely symptom rather than the root cause."
            ;;
        spotlight)
            printf '%s\n' "Metadata indexing or import work is consuming CPU."
            ;;
        coresim_disk_images)
            printf '%s\n' "Simulator runtime disk-image services are active."
            ;;
        *)
            printf '%s\n' ""
            ;;
    esac
}

opt_diag_parse_image_mount_pairs() {
    local info="${1:-}"
    awk '
    function extract_mount(line) {
        # Only /dev/disk* lines list real mount points. Other fields like
        # image-alias / icon-path / shadow-path may contain absolute paths
        # but are not mounts and previously produced phantom detach offers.
        if (line !~ /^\/dev\/disk/) {
            return ""
        }
        if (line ~ /[[:space:]]\/.*/) {
            sub(/^.*[[:space:]]\//, "/", line)
            return line
        }
        return ""
    }
    function flush_block(    i) {
        if (image == "") {
            mount_count = 0
            delete mounts
            return
        }
        for (i = 1; i <= mount_count; i++) {
            if (mounts[i] != "") {
                printf "%s\t%s\n", image, mounts[i]
            }
        }
        mount_count = 0
        delete mounts
    }
    /^=+$/ {
        flush_block()
        image = ""
        next
    }
    /^image-path[[:space:]]*:/ {
        image = $0
        sub(/^image-path[[:space:]]*:[[:space:]]*/, "", image)
        next
    }
    {
        mount = extract_mount($0)
        if (mount ~ /^\//) {
            mounts[++mount_count] = mount
        }
    }
    END {
        flush_block()
    }
    ' <<< "$info"
}

opt_diag_is_system_managed_mount() {
    local image_path="$1"
    local mount_path="$2"

    case "$image_path" in
        /System/* | /Library/Apple/* | /private/var/run/com.apple.security.cryptexd/*)
            return 0
            ;;
    esac

    case "$mount_path" in
        /Library/Developer/CoreSimulator/Volumes/* | /private/var/run/com.apple.security.cryptexd/*)
            return 0
            ;;
    esac

    return 1
}

opt_diag_is_mount_detach_candidate() {
    local image_path="$1"
    local mount_path="$2"

    if opt_diag_is_system_managed_mount "$image_path" "$mount_path"; then
        return 1
    fi

    case "$mount_path" in
        /Volumes/*) ;;
        *) return 1 ;;
    esac

    case "$image_path" in
        *.dmg | *.iso | *.img | *.cdr | *.sparseimage | *.sparsebundle) ;;
        *) return 1 ;;
    esac

    if should_protect_path "$mount_path" || is_path_whitelisted "$mount_path"; then
        return 1
    fi
    if [[ -n "$image_path" ]] && (should_protect_path "$image_path" || is_path_whitelisted "$image_path"); then
        return 1
    fi

    return 0
}

opt_diag_collect_detach_candidates() {
    local pairs="${1:-}"
    local image_path mount_path

    while IFS=$'\t' read -r image_path mount_path; do
        [[ -z "$image_path" || -z "$mount_path" ]] && continue
        if opt_diag_is_mount_detach_candidate "$image_path" "$mount_path"; then
            printf '%s\t%s\n' "$image_path" "$mount_path"
        fi
    done <<< "$pairs"
}

opt_diag_count_matches() {
    local pairs="${1:-}"
    local mode="$2"
    local image_path mount_path count=0

    while IFS=$'\t' read -r image_path mount_path; do
        [[ -z "$image_path" || -z "$mount_path" ]] && continue
        case "$mode" in
            system_managed)
                if opt_diag_is_system_managed_mount "$image_path" "$mount_path"; then
                    count=$((count + 1))
                fi
                ;;
            coresim_only)
                if [[ "$mount_path" == /Library/Developer/CoreSimulator/Volumes/* ]]; then
                    count=$((count + 1))
                fi
                ;;
        esac
    done <<< "$pairs"

    printf '%s\n' "$count"
}

opt_diag_detach_candidates() {
    local candidates="${1:-}"
    local detached=0
    local failed=0
    local image_path mount_path

    while IFS=$'\t' read -r image_path mount_path; do
        [[ -z "$mount_path" ]] && continue
        local safe_mount_path
        safe_mount_path=$(mole_terminal_safe_text "$mount_path")
        if run_with_timeout 15 hdiutil detach "$mount_path" > /dev/null 2>&1; then # 15s: hdiutil detach, see lib/core/timeouts.sh
            detached=$((detached + 1))
            printf '  %b Detached %s\n' "${GREEN}${ICON_SUCCESS}${NC}" "$safe_mount_path"
        else
            failed=$((failed + 1))
            printf '  %b Failed to detach %s\n' "${YELLOW}${ICON_WARNING}${NC}" "$safe_mount_path"
        fi
    done <<< "$candidates"

    if [[ $detached -gt 1 ]]; then
        echo -e "  ${GRAY}${ICON_REVIEW}${NC} Detached ${detached} mounted images"
    fi
    if [[ $failed -gt 1 ]]; then
        echo -e "  ${GRAY}${ICON_REVIEW}${NC} ${failed} mounted images still need manual review"
    fi
}

opt_diag_offer_detach_candidates() {
    local candidates="${1:-}"
    [[ -z "$candidates" ]] && return 0

    local count=0
    local image_path mount_path
    while IFS=$'\t' read -r image_path mount_path; do
        [[ -z "$mount_path" ]] && continue
        count=$((count + 1))
    done <<< "$candidates"

    if [[ "$count" -eq 1 ]]; then
        echo -e "  ${GRAY}${ICON_LIST}${NC} Mounted image adds assessment overhead:"
    else
        echo -e "  ${GRAY}${ICON_LIST}${NC} Mounted images add assessment overhead:"
    fi
    while IFS=$'\t' read -r image_path mount_path; do
        [[ -z "$mount_path" ]] && continue
        local safe_image_path safe_mount_path
        safe_image_path=$(mole_terminal_safe_text "${image_path##*/}")
        safe_mount_path=$(mole_terminal_safe_text "$mount_path")
        printf '    %s %b→%b %s\n' "$safe_image_path" "$GRAY" "$NC" "$safe_mount_path"
    done <<< "$candidates"

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Would offer detach for ${count} mounted image(s)"
        return 0
    fi

    if [[ ! -t 1 ]]; then
        echo -e "  ${GRAY}${ICON_REVIEW}${NC} Review these mounted images and detach any you no longer need"
        return 0
    fi

    echo -ne "  ${GRAY}${ICON_REVIEW}${NC} ${YELLOW}Detach now?${NC} ${GRAY}Enter confirm / Space cancel${NC}: "
    local key=""
    if ! key=$(read_key); then
        echo -e "\n  ${GRAY}${ICON_WARNING}${NC} Kept mounted, whitelist via ${NC}mo optimize --whitelist${GRAY}${NC}"
        return 0
    fi

    if [[ "$key" == "ENTER" ]]; then
        echo ""
        opt_diag_detach_candidates "$candidates"
    else
        echo -e "\n  ${GRAY}${ICON_WARNING}${NC} Kept mounted, whitelist via ${NC}mo optimize --whitelist${GRAY}${NC}"
    fi
}

run_optimize_diagnostics() {
    local sample1 sample2 totals1 totals2 threshold delay
    sample1=$(opt_diag_get_ps_sample 1)
    delay=$(opt_diag_sample_delay)
    if [[ -z "${MOLE_OPTIMIZE_PS_SAMPLE_1:-}" || -z "${MOLE_OPTIMIZE_PS_SAMPLE_2:-}" ]]; then
        sleep "$delay"
    fi
    sample2=$(opt_diag_get_ps_sample 2)
    totals1=$(opt_diag_family_totals "$sample1")
    totals2=$(opt_diag_family_totals "$sample2")
    threshold=$(opt_diag_cpu_threshold)

    echo ""
    echo -e "${BLUE}PERFORMANCE DIAGNOSIS${NC}"

    local families="cloudshell syspolicyd windowserver spotlight coresim_disk_images"
    local sustained_count=0
    local primary_family=""
    local primary_avg="0.0"
    local sustained_details=""
    local family cpu1 cpu2 avg label

    for family in $families; do
        cpu1=$(opt_diag_family_total_for "$totals1" "$family")
        cpu2=$(opt_diag_family_total_for "$totals2" "$family")
        if opt_diag_float_ge "$cpu1" "$threshold" && opt_diag_float_ge "$cpu2" "$threshold"; then
            avg=$(opt_diag_float_avg "$cpu1" "$cpu2")
            label=$(opt_diag_family_label "$family")
            sustained_count=$((sustained_count + 1))
            sustained_details+="${family}"$'\t'"${avg}"$'\t'"${label}"$'\n'
            if [[ -z "$primary_family" ]] || opt_diag_float_gt "$avg" "$primary_avg"; then
                primary_family="$family"
                primary_avg="$avg"
            fi
        fi
    done

    # Memory and stuck-process checks run alongside the family CPU scan. They
    # cover the two shapes the family list cannot see, and each stays silent
    # when healthy, so a clean machine still prints one reassuring line below.
    local extra_findings=0
    local mem_out runaway_out vm_out
    mem_out=$(opt_diag_memory_pressure) || true
    vm_out=$(opt_diag_idle_vm) || true
    runaway_out=$(opt_diag_runaway_process) || true
    [[ -n "$mem_out" || -n "$vm_out" || -n "$runaway_out" ]] && extra_findings=1

    if [[ -z "$primary_family" && "$extra_findings" -eq 0 ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No sustained high-CPU bottleneck detected"
    elif [[ -z "$primary_family" ]]; then
        : # extra findings print below; no CPU-family bottleneck to headline
    else
        label=$(opt_diag_family_label "$primary_family")
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Likely bottleneck: ${label} (~${primary_avg}% CPU sustained)"
        echo -e "  ${GRAY}${ICON_REVIEW}${NC} $(opt_diag_family_note "$primary_family")"

        if [[ $sustained_count -gt 1 ]]; then
            echo -e "  ${GRAY}${ICON_LIST}${NC} Additional sustained pressure:"
            while IFS=$'\t' read -r family avg label; do
                [[ -z "$family" || "$family" == "$primary_family" ]] && continue
                echo -e "    ${GRAY}${label}${NC} ~${avg}%"
            done <<< "$sustained_details"
        fi
    fi

    [[ -n "$runaway_out" ]] && printf '%s\n' "$runaway_out"
    [[ -n "$mem_out" ]] && printf '%s\n' "$mem_out"
    [[ -n "$vm_out" ]] && printf '%s\n' "$vm_out"

    # Mounted-image checks are scoped to sustained syspolicyd pressure: a
    # mounted DMG on an otherwise healthy system is not a diagnosis finding,
    # so healthy runs end at the summary line without probing spctl/hdiutil.
    if [[ "$primary_family" == "syspolicyd" || "$sustained_details" == *$'syspolicyd\t'* ]]; then
        local spctl_status hdiutil_info image_pairs detach_candidates
        local managed_count coresim_count detach_count
        spctl_status=$(opt_diag_get_spctl_status)
        hdiutil_info=$(opt_diag_get_hdiutil_info)
        image_pairs=$(opt_diag_parse_image_mount_pairs "$hdiutil_info")
        detach_candidates=$(opt_diag_collect_detach_candidates "$image_pairs")
        managed_count=$(opt_diag_count_matches "$image_pairs" system_managed)
        coresim_count=$(opt_diag_count_matches "$image_pairs" coresim_only)
        detach_count=$(printf '%s\n' "$detach_candidates" | awk 'NF { count++ } END { print count + 0 }')

        if [[ -n "$spctl_status" ]]; then
            echo -e "  ${GRAY}${ICON_LIST}${NC} Gatekeeper status: ${spctl_status}"
        fi
        if [[ "$managed_count" -gt 0 && "$managed_count" == "$coresim_count" && "$detach_count" -eq 0 ]]; then
            echo -e "  ${GRAY}${ICON_INFO}${NC} Only system-managed CoreSimulator images are mounted, informational only, not a detach target"
        fi

        opt_diag_offer_detach_candidates "$detach_candidates"
    fi
}

# ============================================================================
# Memory and runaway-process diagnosis
#
# The family-based CPU checks above only look at five known process families,
# so they miss the two failure shapes that actually make a Mac feel slow:
#   1. memory exhaustion (swap thrash), where load is high but nothing is busy
#   2. a single process stuck in a run loop that is not in the family list
# Both are read-only diagnosis. Nothing here kills or changes anything.
# ============================================================================

readonly MOLE_OPTIMIZE_SWAP_PCT_DEFAULT=50
readonly MOLE_OPTIMIZE_FREE_PCT_DEFAULT=15
readonly MOLE_OPTIMIZE_IDLE_VM_GB_DEFAULT=2
readonly MOLE_OPTIMIZE_RUNAWAY_PCT_DEFAULT=25
readonly MOLE_OPTIMIZE_RUNAWAY_MIN_HOURS_DEFAULT=12

# Injection seams so diagnosis is deterministic under test, matching the
# existing MOLE_OPTIMIZE_PS_SAMPLE_* convention above. Without these, the
# memory and runaway checks read live system state and any assertion about a
# "quiet" run depends on whatever the test host happens to be doing.
opt_diag_get_swapusage() {
    if [[ -n "${MOLE_OPTIMIZE_SWAPUSAGE:-}" ]]; then
        printf '%s\n' "$MOLE_OPTIMIZE_SWAPUSAGE"
        return 0
    fi
    sysctl -n vm.swapusage 2> /dev/null || true
}

opt_diag_get_mem_free_pct() {
    if [[ -n "${MOLE_OPTIMIZE_MEM_FREE_PCT:-}" ]]; then
        printf '%s\n' "$MOLE_OPTIMIZE_MEM_FREE_PCT"
        return 0
    fi
    memory_pressure 2> /dev/null | awk -F': ' '/free percentage/ {gsub(/%/,"",$2); print int($2)}' | tail -1
}

# shellcheck disable=SC2009  # pgrep cannot report RSS; the column is the point.
opt_diag_get_rss_sample() {
    if [[ -n "${MOLE_OPTIMIZE_RSS_SAMPLE:-}" ]]; then
        printf '%s\n' "$MOLE_OPTIMIZE_RSS_SAMPLE"
        return 0
    fi
    ps -Ao rss,comm 2> /dev/null | tail -n +2 | grep -v CoreSimulator || true
}

# shellcheck disable=SC2009  # pgrep cannot report TIME/ELAPSED; both are required.
opt_diag_get_proctime_sample() {
    if [[ -n "${MOLE_OPTIMIZE_PROCTIME_SAMPLE:-}" ]]; then
        printf '%s\n' "$MOLE_OPTIMIZE_PROCTIME_SAMPLE"
        return 0
    fi
    ps -Ao pid,time,etime,comm 2> /dev/null | tail -n +2 | grep -v CoreSimulator || true
}

# shellcheck disable=SC2009  # needs full COMMAND path to match the VM binary.
opt_diag_get_vm_sample() {
    if [[ -n "${MOLE_OPTIMIZE_VM_SAMPLE:-}" ]]; then
        printf '%s\n' "$MOLE_OPTIMIZE_VM_SAMPLE"
        return 0
    fi
    ps -Ao rss,command 2> /dev/null | tail -n +2 | grep -v CoreSimulator || true
}

opt_diag_int_env() {
    local value="${1:-}" fallback="${2:-0}"
    [[ "$value" =~ ^[0-9]+$ ]] || value="$fallback"
    printf '%s\n' "$value"
}

# Convert ps time/etime ([[dd-]hh:]mm:ss) to seconds. Returns 0 on garbage so a
# malformed row can never inflate a ratio into a false runaway report. Shared
# as awk source rather than a shell function because the runaway scan reads
# two of these per row across hundreds of rows, and paying a fork for each one
# cost five seconds of every optimize run.
readonly MOLE_OPT_DIAG_TIME_AWK='
function opt_secs(t,   n, a, p, d, first, h, m, s) {
    d = 0
    n = split(t, a, ":")
    if (n < 2 || n > 3) return 0
    first = a[1]
    if (first ~ /-/) { split(first, p, "-"); d = p[1]; first = p[2] }
    if (n == 3) { h = first; m = a[2]; s = a[3] }
    else        { h = 0;     m = first; s = a[2] }
    if (d !~ /^[0-9]+$/ || h !~ /^[0-9]+$/ || m !~ /^[0-9]+$/ || s !~ /^[0-9.]+$/) return 0
    return d * 86400 + h * 3600 + m * 60 + s
}
'

opt_diag_time_to_seconds() {
    printf '%s\n' "${1:-}" | awk "$MOLE_OPT_DIAG_TIME_AWK"'{ printf "%d\n", opt_secs($0) }'
}

# Swap pressure, and the processes actually responsible for it. Silent when
# memory is healthy.
opt_diag_memory_pressure() {
    local swap_line swap_total swap_used swap_pct free_pct warn_swap warn_free
    warn_swap=$(opt_diag_int_env "${MOLE_OPTIMIZE_SWAP_PCT:-}" "$MOLE_OPTIMIZE_SWAP_PCT_DEFAULT")
    warn_free=$(opt_diag_int_env "${MOLE_OPTIMIZE_FREE_PCT:-}" "$MOLE_OPTIMIZE_FREE_PCT_DEFAULT")

    swap_line=$(opt_diag_get_swapusage)
    [[ -n "$swap_line" ]] || return 0
    swap_total=$(printf '%s\n' "$swap_line" | awk '{gsub(/M/,"",$3); print int($3)}')
    swap_used=$(printf '%s\n' "$swap_line" | awk '{gsub(/M/,"",$6); print int($6)}')
    [[ "$swap_total" =~ ^[0-9]+$ && "$swap_used" =~ ^[0-9]+$ ]] || return 0

    swap_pct=0
    [[ "$swap_total" -gt 0 ]] && swap_pct=$((swap_used * 100 / swap_total))
    free_pct=$(opt_diag_get_mem_free_pct)
    [[ "$free_pct" =~ ^[0-9]+$ ]] || free_pct=100

    if [[ "$swap_pct" -lt "$warn_swap" && "$free_pct" -ge "$warn_free" ]]; then
        return 0
    fi

    # bytes_to_human, not integer GB: sysctl reports megabytes, so "used / 1024"
    # printed "swap 0GB of 1GB used (88%)" on a machine with a small swap file.
    echo -e "  ${YELLOW}${ICON_WARNING}${NC} Memory pressure: swap $(bytes_to_human_kb "$((swap_used * 1024))") of $(bytes_to_human_kb "$((swap_total * 1024))") used (${swap_pct}%), ${free_pct}% free"
    echo -e "  ${GRAY}${ICON_REVIEW}${NC} High load with little CPU activity is usually this, not compute"

    # Name the actual holders. Simulator runtimes ship duplicate daemons whose
    # rows would otherwise crowd out the real offenders.
    local shown=0 holder_kb holder_name
    while IFS=$'\t' read -r holder_kb holder_name; do
        [[ -n "$holder_name" ]] || continue
        echo -e "    ${GRAY}${holder_name}$(bytes_to_human_kb "$holder_kb")${NC}"
        shown=$((shown + 1))
        # The ps header is stripped inside opt_diag_get_rss_sample, BEFORE the
        # sort here. Filtering it afterwards with NR>1 would discard the
        # LARGEST process instead, since the non-numeric header sorts last.
        #
        # 256MB floor rather than 1GB: when pressure is spread across several
        # mid-size processes there is no single 1GB offender, and a 1GB cutoff
        # then prints nothing actionable at exactly the moment the user most
        # needs a name. Observed live at 97% swap with no 1GB process.
    done < <(opt_diag_get_rss_sample |
        sort -rn |
        awk '$1 > 262144 {
                kb = $1
                # comm can contain spaces ("Claude Helper (Renderer)"), so take
                # every remaining field. Reading $2 alone printed fragments like
                # "(2.1.223)" - a version string, not a process name.
                name = ""
                for (i = 2; i <= NF; i++) name = name (i > 2 ? " " : "") $i
                sub(/^.*\//, "", name)
                # Truncate from the LEFT. These are often reverse-DNS names
                # where the tail identifies the process
                # ("com.apple.Virtualization.VirtualMachine"); keeping the head
                # would hide which service it actually is.
                prefix = ""
                if (length(name) > 26) {
                    name = substr(name, length(name) - 24)
                    prefix = "\xe2\x80\xa6"
                }
                # Pad here, on the ASCII name, and add the ellipsis after.
                # printf "%-28s" counts bytes, so padding a string that already
                # carried the three-byte ellipsis pulled the size column two
                # places left on exactly the rows that were truncated.
                pad = 28 - length(name) - (prefix == "" ? 0 : 1)
                if (pad < 1) pad = 1
                printf "%s\t%s%s%*s\n", kb, prefix, name, pad, ""
             }' |
        head -4)
    [[ "$shown" -gt 0 ]] || echo -e "    ${GRAY}pressure is spread across many small processes${NC}"
    return 0
}

# A virtual machine holding gigabytes while doing no work. Docker Desktop is
# the common case: its Linux VM claims its full memory reservation even with
# zero containers running, which is invisible to disk-oriented checks.
opt_diag_idle_vm() {
    local min_gb vm_kb vm_gb
    min_gb=$(opt_diag_int_env "${MOLE_OPTIMIZE_IDLE_VM_GB:-}" "$MOLE_OPTIMIZE_IDLE_VM_GB_DEFAULT")

    vm_kb=$(opt_diag_get_vm_sample |
        awk '/Virtualization.framework.*VirtualMachine/ {s += $1} END {print s + 0}')
    [[ "$vm_kb" =~ ^[0-9]+$ ]] || return 0
    [[ "$vm_kb" -gt $((min_gb * 1048576)) ]] || return 0
    vm_gb=$(bytes_to_human_kb "$vm_kb")

    # Only claim it is idle if the owner agrees. A probe that cannot answer
    # must not produce a "safe to quit" recommendation.
    local running="" docker_output="" container_id
    if command -v docker > /dev/null 2>&1; then
        if docker_output=$(run_with_timeout "$MOLE_TIMEOUT_SHORT_QUERY_SEC" docker ps -q 2> /dev/null); then
            running=0
            while IFS= read -r container_id; do
                [[ -n "$container_id" ]] || continue
                running=$((running + 1))
            done <<< "$docker_output"
        fi
    fi

    if [[ "$running" == "0" ]]; then
        if command -v docker > /dev/null 2>&1; then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Virtual machine holding ${vm_gb} with no running containers (likely Docker Desktop)"
            echo -e "  ${GRAY}${ICON_REVIEW}${NC} If this is Docker Desktop, quitting it reclaims all of it; it reserves memory even when idle"
        else
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Virtual machine holding ${vm_gb}"
            echo -e "  ${GRAY}${ICON_REVIEW}${NC} Check Docker Desktop, UTM, or other virtualization tools for reclaimable memory"
        fi
    else
        echo -e "  ${GRAY}${ICON_LIST}${NC} Virtual machine using ${vm_gb}${running:+ (${running} containers running)}"
    fi
    return 0
}

# A process stuck in a run loop: high CPU averaged over its entire lifetime,
# which is what `ps` TIME/ELAPSED actually measures. A momentary spike cannot
# trip this, and neither can a short-lived process.
opt_diag_runaway_process() {
    local pct_floor min_hours
    pct_floor=$(opt_diag_int_env "${MOLE_OPTIMIZE_RUNAWAY_PCT:-}" "$MOLE_OPTIMIZE_RUNAWAY_PCT_DEFAULT")
    min_hours=$(opt_diag_int_env "${MOLE_OPTIMIZE_RUNAWAY_MIN_HOURS:-}" "$MOLE_OPTIMIZE_RUNAWAY_MIN_HOURS_DEFAULT")

    # The whole scan is one awk pass. Splitting fields and converting two
    # timestamps per row in the shell cost six forks for each of 400 rows,
    # which measured 5.1s on a 1000-process machine even when it found
    # nothing, and every optimize run paid it.
    local found=1 pid comm cpu_hours run_hours pct
    while IFS=$'\t' read -r pid comm cpu_hours run_hours pct; do
        [[ -n "$pid" ]] || continue
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} ${comm} has burned ${cpu_hours}h CPU over ${run_hours}h of runtime (~${pct}% sustained)"
        echo -e "  ${GRAY}${ICON_REVIEW}${NC} A stuck run loop. Restarting it usually clears it: ${NC}kill -TERM ${pid}${GRAY} (launchd respawns system daemons)${NC}"
        found=0
    done < <(opt_diag_get_proctime_sample | head -400 |
        awk -v floor="$pct_floor" -v minh="$min_hours" "$MOLE_OPT_DIAG_TIME_AWK"'
        NF >= 4 {
            name = ""
            for (i = 4; i <= NF; i++) name = name (i > 4 ? " " : "") $i
            sub(/^.*\//, "", name)
            # kernel_task is expected to accumulate CPU; it is thermal
            # management, not a stuck process, and reporting it would be noise
            # every run. WindowServer and the other scanned families are
            # already headlined by the family CPU check above, so repeating
            # them here would double-report one problem under two names.
            if (name == "kernel_task" || name == "WindowServer" || name == "mds" ||
                name == "mds_stores" || name == "syspolicyd" || name ~ /^mdworker/) next
            el = opt_secs($3)
            if (el <= minh * 3600) next
            cpu = opt_secs($2)
            if (cpu <= 0) next
            pct = int(cpu * 100 / el)
            if (pct < floor) next
            printf "%s\t%s\t%d\t%d\t%d\n", $1, name, cpu / 3600, el / 3600, pct
        }')

    return "$found"
}
