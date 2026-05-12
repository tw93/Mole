#!/bin/bash
# Optimize performance diagnosis helpers.

set -euo pipefail

readonly ROOMY_OPTIMIZE_DIAG_CPU_THRESHOLD_DEFAULT=25
readonly ROOMY_OPTIMIZE_DIAG_SAMPLE_DELAY_DEFAULT=1

opt_diag_cpu_threshold() {
    local threshold="${ROOMY_OPTIMIZE_DIAG_CPU_THRESHOLD:-$ROOMY_OPTIMIZE_DIAG_CPU_THRESHOLD_DEFAULT}"
    if ! [[ "$threshold" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        threshold="$ROOMY_OPTIMIZE_DIAG_CPU_THRESHOLD_DEFAULT"
    fi
    printf '%s\n' "$threshold"
}

opt_diag_sample_delay() {
    local delay="${ROOMY_OPTIMIZE_DIAG_SAMPLE_DELAY:-$ROOMY_OPTIMIZE_DIAG_SAMPLE_DELAY_DEFAULT}"
    if ! [[ "$delay" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        delay="$ROOMY_OPTIMIZE_DIAG_SAMPLE_DELAY_DEFAULT"
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
        1) override="${ROOMY_OPTIMIZE_PS_SAMPLE_1:-}" ;;
        2) override="${ROOMY_OPTIMIZE_PS_SAMPLE_2:-}" ;;
    esac

    if [[ -n "$override" ]]; then
        printf '%s\n' "$override"
        return 0
    fi

    ps -Aceo pcpu=,command= 2> /dev/null || true
}

opt_diag_get_spctl_status() {
    if [[ -n "${ROOMY_OPTIMIZE_SPCTL_STATUS:-}" ]]; then
        printf '%s\n' "$ROOMY_OPTIMIZE_SPCTL_STATUS"
        return 0
    fi

    spctl --status 2> /dev/null || true
}

opt_diag_get_hdiutil_info() {
    if [[ -n "${ROOMY_OPTIMIZE_HDIUTIL_INFO:-}" ]]; then
        printf '%s\n' "$ROOMY_OPTIMIZE_HDIUTIL_INFO"
        return 0
    fi

    run_with_timeout 8 hdiutil info 2> /dev/null || true
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
            printf '%s\n' "External enterprise agent pressure detected. Roomy will not terminate enterprise security processes; restart or policy checks must happen outside Roomy."
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
        if run_with_timeout 15 hdiutil detach "$mount_path" > /dev/null 2>&1; then
            detached=$((detached + 1))
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Detached ${mount_path}"
        else
            failed=$((failed + 1))
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Failed to detach ${mount_path}"
        fi
    done <<< "$candidates"

    if [[ $detached -gt 0 ]]; then
        echo -e "  ${GRAY}${ICON_REVIEW}${NC} Detached ${detached} mounted image(s)"
    fi
    if [[ $failed -gt 0 ]]; then
        echo -e "  ${GRAY}${ICON_REVIEW}${NC} ${failed} mounted image(s) still need manual review"
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

    echo -e "  ${GRAY}${ICON_LIST}${NC} Mounted image detach candidates:"
    while IFS=$'\t' read -r image_path mount_path; do
        [[ -z "$mount_path" ]] && continue
        echo -e "    ${GRAY}${mount_path}${NC} ← ${image_path}"
    done <<< "$candidates"

    if [[ "${ROOMY_DRY_RUN:-0}" == "1" ]]; then
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
        echo -e "\n  ${GRAY}${ICON_WARNING}${NC} Mounted image detach skipped"
        return 0
    fi

    if [[ "$key" == "ENTER" ]]; then
        echo ""
        opt_diag_detach_candidates "$candidates"
    else
        echo -e "\n  ${GRAY}${ICON_WARNING}${NC} Mounted image detach skipped"
    fi
}

run_optimize_diagnostics() {
    local sample1 sample2 totals1 totals2 threshold delay
    sample1=$(opt_diag_get_ps_sample 1)
    delay=$(opt_diag_sample_delay)
    if [[ -z "${ROOMY_OPTIMIZE_PS_SAMPLE_1:-}" || -z "${ROOMY_OPTIMIZE_PS_SAMPLE_2:-}" ]]; then
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

    if [[ -z "$primary_family" ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No obvious sustained high-CPU bottleneck detected"
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

    local spctl_status hdiutil_info image_pairs detach_candidates
    spctl_status=$(opt_diag_get_spctl_status)
    hdiutil_info=$(opt_diag_get_hdiutil_info)
    image_pairs=$(opt_diag_parse_image_mount_pairs "$hdiutil_info")
    detach_candidates=$(opt_diag_collect_detach_candidates "$image_pairs")

    if [[ "$primary_family" == "syspolicyd" || "$sustained_details" == *$'syspolicyd\t'* ]]; then
        local managed_count coresim_count detach_count
        managed_count=$(opt_diag_count_matches "$image_pairs" system_managed)
        coresim_count=$(opt_diag_count_matches "$image_pairs" coresim_only)
        detach_count=$(printf '%s\n' "$detach_candidates" | awk 'NF { count++ } END { print count + 0 }')

        if [[ -n "$spctl_status" ]]; then
            echo -e "  ${GRAY}${ICON_LIST}${NC} Gatekeeper status: ${spctl_status}"
        fi
        if [[ "$managed_count" -gt 0 && "$managed_count" == "$coresim_count" && "$detach_count" -eq 0 ]]; then
            echo -e "  ${GRAY}${ICON_INFO}${NC} Only system-managed CoreSimulator images are mounted, informational only, not a detach target"
        elif [[ "$detach_count" -gt 0 ]]; then
            echo -e "  ${GRAY}${ICON_INFO}${NC} User-mounted disk images may contribute to assessment overhead"
        fi
    fi

    opt_diag_offer_detach_candidates "$detach_candidates"
}
