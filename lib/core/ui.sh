#!/bin/bash
# Mole - UI Components
# Terminal UI utilities: cursor control, keyboard input, spinners, menus

set -euo pipefail

if [[ -n "${MOLE_UI_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_UI_LOADED=1

_MOLE_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "${MOLE_BASE_LOADED:-}" ]] && source "$_MOLE_CORE_DIR/base.sh"

# Timeout for the second key of a multi-key sequence (e.g. gg -> jump to top).
# Bash 4.0+ accepts fractional `read -t` values; macOS default Bash 3.2 rejects
# them ("invalid timeout specification") and the read fails instantly, which
# silently disabled the gg shortcut. Use a snappy sub-second wait where it is
# supported and fall back to a 1s integer timeout on Bash 3.2.
if [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]]; then
    readonly MOLE_KEY_SEQ_TIMEOUT="0.3"
else
    readonly MOLE_KEY_SEQ_TIMEOUT="1"
fi

# Cursor control
clear_screen() { printf '\033[2J\033[H'; }
hide_cursor() { [[ -t 1 ]] && printf '\033[?25l' >&2 || true; }
show_cursor() { [[ -t 1 ]] && printf '\033[?25h' >&2 || true; }

# OSC 7501 program status. Callers supply protocol constants only. A report
# replaces the previous record, so include the program name on every write.
mole_report_program_status() {
    [[ -t 2 ]] || return 0
    local kind="${2:-}"
    printf '\033]7501;state=%s:app=mole%s\033\134' "$1" "${kind:+:kind=$kind}" >&2 || true
}

# Terminal columns a string takes, the width charmbracelet/x/ansi StringWidth
# gives in the Go TUIs, so shell and Go menus line up: the zero and wide
# ranges below are generated from StringWidth one code point at a time, then
# a ZWJ sequence, skin tone, flag pair or VS16 emoji counts as one 2-column
# cluster. Scripts whose clusters join several letters (Devanagari conjuncts)
# can still differ. Bash 3.2's printf "'c" yields only the first byte, so
# UTF-8 is decoded by hand in the C locale; no forks. Locked by
# "get_display_width matches the Go width table" in core_common.bats.
get_display_width() {
    local str="$1"
    local had_lc=${LC_ALL+x} old_lc="${LC_ALL:-}"

    export LC_ALL=en_US.UTF-8
    local char_count=${#str}
    export LC_ALL=C
    local byte_count=${#str}

    local width=$char_count
    if ((byte_count != char_count)); then
        width=0
        local i=0 b c n k cp w prev_w=0 after_zwj=0 flag_open=0
        while ((i < byte_count)); do
            printf -v b '%d' "'${str:i:1}"
            if ((b < 0)); then b=$((b + 256)); fi
            i=$((i + 1))
            if ((b < 128)); then
                width=$((width + 1))
                prev_w=1 after_zwj=0 flag_open=0
                continue
            fi
            if ((b >= 240)); then
                n=3 cp=$((b & 7))
            elif ((b >= 224)); then
                n=2 cp=$((b & 15))
            elif ((b >= 192)); then
                n=1 cp=$((b & 31))
            else
                n=0 cp=-1
            fi
            for ((k = 0; k < n; k++)); do
                printf -v c '%d' "'${str:i:1}"
                if ((c < 0)); then c=$((c + 256)); fi
                if ((c < 128 || c >= 192)); then
                    cp=-1
                    break
                fi
                cp=$(((cp << 6) | (c & 63)))
                i=$((i + 1))
            done

            if ((cp == 0x200D)); then
                after_zwj=1
                continue
            fi
            if ((cp == 0xFE0F)); then
                # VS16 asks for emoji presentation: a narrow base becomes wide.
                if ((prev_w == 1)); then
                    width=$((width + 1))
                    prev_w=2
                fi
                continue
            fi
            if ((cp < 0)); then
                w=1
            elif ((cp < 0x300)); then
                w=1
                if ((cp == 0xAD)); then w=0; fi
            elif (((cp >= 0x4E00 && cp <= 0x9FFF) || (cp >= 0xAC00 && cp <= 0xD7A3))); then
                w=2
            elif ((cp >= 0x1F3FB && cp <= 0x1F3FF)); then
                # A skin tone joins whatever comes before it; alone it is wide.
                w=2
                if ((prev_w > 0)); then w=0; fi
            elif ((cp >= 0x1F1E6 && cp <= 0x1F1FF)); then
                # Regional indicators pair into one flag.
                if ((flag_open)); then
                    w=0 flag_open=0
                else
                    w=2 flag_open=1
                fi
            elif ((cp < 0x2000)) && (((cp >= 0x300 && cp <= 0x36F) || (cp >= 0x483 && cp <= 0x489) || (\
            cp >= 0x591 && cp <= 0x5BD) || cp == 0x5BF || (cp >= 0x5C1 && cp <= 0x5C2) || (\
            cp >= 0x5C4 && cp <= 0x5C5) || cp == 0x5C7 || (cp >= 0x600 && cp <= 0x605) || (\
            cp >= 0x610 && cp <= 0x61A) || cp == 0x61C || (cp >= 0x64B && cp <= 0x65F) || cp == 0x670 || (\
            cp >= 0x6D6 && cp <= 0x6DD) || (cp >= 0x6DF && cp <= 0x6E4) || (\
            cp >= 0x6E7 && cp <= 0x6E8) || (cp >= 0x6EA && cp <= 0x6ED) || cp == 0x70F || cp == 0x711 || (\
            cp >= 0x730 && cp <= 0x74A) || (cp >= 0x7A6 && cp <= 0x7B0) || (\
            cp >= 0x7EB && cp <= 0x7F3) || cp == 0x7FD || (cp >= 0x816 && cp <= 0x819) || (\
            cp >= 0x81B && cp <= 0x823) || (cp >= 0x825 && cp <= 0x827) || (\
            cp >= 0x829 && cp <= 0x82D) || (cp >= 0x859 && cp <= 0x85B) || (\
            cp >= 0x890 && cp <= 0x891) || (cp >= 0x898 && cp <= 0x89F) || (\
            cp >= 0x8CA && cp <= 0x902) || cp == 0x93A || cp == 0x93C || (cp >= 0x941 && cp <= 0x948) || \
            cp == 0x94D || (cp >= 0x951 && cp <= 0x957) || (cp >= 0x962 && cp <= 0x963) || cp == 0x981 || \
            cp == 0x9BC || (cp >= 0x9C1 && cp <= 0x9C4) || cp == 0x9CD || (cp >= 0x9E2 && cp <= 0x9E3) || \
            cp == 0x9FE || (cp >= 0xA01 && cp <= 0xA02) || cp == 0xA3C || (cp >= 0xA41 && cp <= 0xA42) || (\
            cp >= 0xA47 && cp <= 0xA48) || (cp >= 0xA4B && cp <= 0xA4D) || cp == 0xA51 || (\
            cp >= 0xA70 && cp <= 0xA71) || cp == 0xA75 || (cp >= 0xA81 && cp <= 0xA82) || cp == 0xABC || (\
            cp >= 0xAC1 && cp <= 0xAC5) || (cp >= 0xAC7 && cp <= 0xAC8) || cp == 0xACD || (\
            cp >= 0xAE2 && cp <= 0xAE3) || (cp >= 0xAFA && cp <= 0xAFF) || cp == 0xB01 || cp == 0xB3C || \
            cp == 0xB3F || (cp >= 0xB41 && cp <= 0xB44) || cp == 0xB4D || (cp >= 0xB55 && cp <= 0xB56) || (\
            cp >= 0xB62 && cp <= 0xB63) || cp == 0xB82 || cp == 0xBC0 || cp == 0xBCD || cp == 0xC00 || \
            cp == 0xC04 || cp == 0xC3C || (cp >= 0xC3E && cp <= 0xC40) || (cp >= 0xC46 && cp <= 0xC48) || (\
            cp >= 0xC4A && cp <= 0xC4D) || (cp >= 0xC55 && cp <= 0xC56) || (\
            cp >= 0xC62 && cp <= 0xC63) || cp == 0xC81 || cp == 0xCBC || cp == 0xCBF || cp == 0xCC6 || (\
            cp >= 0xCCC && cp <= 0xCCD) || (cp >= 0xCE2 && cp <= 0xCE3) || (\
            cp >= 0xD00 && cp <= 0xD01) || (cp >= 0xD3B && cp <= 0xD3C) || (\
            cp >= 0xD41 && cp <= 0xD44) || cp == 0xD4D || (cp >= 0xD62 && cp <= 0xD63) || cp == 0xD81 || \
            cp == 0xDCA || (cp >= 0xDD2 && cp <= 0xDD4) || cp == 0xDD6 || cp == 0xE31 || (\
            cp >= 0xE34 && cp <= 0xE3A) || (cp >= 0xE47 && cp <= 0xE4E) || cp == 0xEB1 || (\
            cp >= 0xEB4 && cp <= 0xEBC) || (cp >= 0xEC8 && cp <= 0xECE) || (\
            cp >= 0xF18 && cp <= 0xF19) || cp == 0xF35 || cp == 0xF37 || cp == 0xF39 || (\
            cp >= 0xF71 && cp <= 0xF7E) || (cp >= 0xF80 && cp <= 0xF84) || (\
            cp >= 0xF86 && cp <= 0xF87) || (cp >= 0xF8D && cp <= 0xF97) || (\
            cp >= 0xF99 && cp <= 0xFBC) || cp == 0xFC6 || (cp >= 0x102D && cp <= 0x1030) || (\
            cp >= 0x1032 && cp <= 0x1037) || (cp >= 0x1039 && cp <= 0x103A) || (\
            cp >= 0x103D && cp <= 0x103E) || (cp >= 0x1058 && cp <= 0x1059) || (\
            cp >= 0x105E && cp <= 0x1060) || (cp >= 0x1071 && cp <= 0x1074) || cp == 0x1082 || (\
            cp >= 0x1085 && cp <= 0x1086) || cp == 0x108D || cp == 0x109D || (\
            cp >= 0x1160 && cp <= 0x11FF) || (cp >= 0x135D && cp <= 0x135F) || (\
            cp >= 0x1712 && cp <= 0x1714) || (cp >= 0x1732 && cp <= 0x1733) || (\
            cp >= 0x1752 && cp <= 0x1753) || (cp >= 0x1772 && cp <= 0x1773) || (\
            cp >= 0x17B4 && cp <= 0x17B5) || (cp >= 0x17B7 && cp <= 0x17BD) || cp == 0x17C6 || (\
            cp >= 0x17C9 && cp <= 0x17D3) || cp == 0x17DD || (cp >= 0x180B && cp <= 0x180F) || (\
            cp >= 0x1885 && cp <= 0x1886) || cp == 0x18A9 || (cp >= 0x1920 && cp <= 0x1922) || (\
            cp >= 0x1927 && cp <= 0x1928) || cp == 0x1932 || (cp >= 0x1939 && cp <= 0x193B) || (\
            cp >= 0x1A17 && cp <= 0x1A18) || cp == 0x1A1B || cp == 0x1A56 || (\
            cp >= 0x1A58 && cp <= 0x1A5E) || cp == 0x1A60 || cp == 0x1A62 || (\
            cp >= 0x1A65 && cp <= 0x1A6C) || (cp >= 0x1A73 && cp <= 0x1A7C) || cp == 0x1A7F || (\
            cp >= 0x1AB0 && cp <= 0x1ACE) || (cp >= 0x1B00 && cp <= 0x1B03) || cp == 0x1B34 || (\
            cp >= 0x1B36 && cp <= 0x1B3A) || cp == 0x1B3C || cp == 0x1B42 || (\
            cp >= 0x1B6B && cp <= 0x1B73) || (cp >= 0x1B80 && cp <= 0x1B81) || (\
            cp >= 0x1BA2 && cp <= 0x1BA5) || (cp >= 0x1BA8 && cp <= 0x1BA9) || (\
            cp >= 0x1BAB && cp <= 0x1BAD) || cp == 0x1BE6 || (cp >= 0x1BE8 && cp <= 0x1BE9) || \
            cp == 0x1BED || (cp >= 0x1BEF && cp <= 0x1BF1) || (cp >= 0x1C2C && cp <= 0x1C33) || (\
            cp >= 0x1C36 && cp <= 0x1C37) || (cp >= 0x1CD0 && cp <= 0x1CD2) || (\
            cp >= 0x1CD4 && cp <= 0x1CE0) || (cp >= 0x1CE2 && cp <= 0x1CE8) || cp == 0x1CED || \
            cp == 0x1CF4 || (cp >= 0x1CF8 && cp <= 0x1CF9) || (cp >= 0x1DC0 && cp <= 0x1DFF))); then
                w=0
            elif ((cp >= 0x2000)) && (((cp >= 0x200B && cp <= 0x200C) || (cp >= 0x200E && cp <= 0x200F) || (\
            cp >= 0x2028 && cp <= 0x202E) || (cp >= 0x2060 && cp <= 0x2064) || (\
            cp >= 0x2066 && cp <= 0x206F) || (cp >= 0x20D0 && cp <= 0x20F0) || (\
            cp >= 0x2CEF && cp <= 0x2CF1) || cp == 0x2D7F || (cp >= 0x2DE0 && cp <= 0x2DFF) || (\
            cp >= 0x302A && cp <= 0x302D) || (cp >= 0x3099 && cp <= 0x309A) || (\
            cp >= 0xA66F && cp <= 0xA672) || (cp >= 0xA674 && cp <= 0xA67D) || (\
            cp >= 0xA69E && cp <= 0xA69F) || (cp >= 0xA6F0 && cp <= 0xA6F1) || cp == 0xA802 || \
            cp == 0xA806 || cp == 0xA80B || (cp >= 0xA825 && cp <= 0xA826) || cp == 0xA82C || (\
            cp >= 0xA8C4 && cp <= 0xA8C5) || (cp >= 0xA8E0 && cp <= 0xA8F1) || cp == 0xA8FF || (\
            cp >= 0xA926 && cp <= 0xA92D) || (cp >= 0xA947 && cp <= 0xA951) || (\
            cp >= 0xA980 && cp <= 0xA982) || cp == 0xA9B3 || (cp >= 0xA9B6 && cp <= 0xA9B9) || (\
            cp >= 0xA9BC && cp <= 0xA9BD) || cp == 0xA9E5 || (cp >= 0xAA29 && cp <= 0xAA2E) || (\
            cp >= 0xAA31 && cp <= 0xAA32) || (cp >= 0xAA35 && cp <= 0xAA36) || cp == 0xAA43 || \
            cp == 0xAA4C || cp == 0xAA7C || cp == 0xAAB0 || (cp >= 0xAAB2 && cp <= 0xAAB4) || (\
            cp >= 0xAAB7 && cp <= 0xAAB8) || (cp >= 0xAABE && cp <= 0xAABF) || cp == 0xAAC1 || (\
            cp >= 0xAAEC && cp <= 0xAAED) || cp == 0xAAF6 || cp == 0xABE5 || cp == 0xABE8 || \
            cp == 0xABED || cp == 0xFB1E || (cp >= 0xFE00 && cp <= 0xFE0E) || (\
            cp >= 0xFE20 && cp <= 0xFE2F) || cp == 0xFEFF || (cp >= 0xFF9E && cp <= 0xFF9F) || (\
            cp >= 0xFFF9 && cp <= 0xFFFB) || cp == 0xE0001 || (cp >= 0xE0020 && cp <= 0xE007F) || (\
            cp >= 0xE0100 && cp <= 0xE01EF))); then
                w=0
            elif (((cp >= 0x1100 && cp <= 0x115F) || (cp >= 0x231A && cp <= 0x231B) || (\
                cp >= 0x2329 && cp <= 0x232A) || (cp >= 0x23E9 && cp <= 0x23EC) || cp == 0x23F0 || \
                cp == 0x23F3 || (cp >= 0x25FD && cp <= 0x25FE) || (cp >= 0x2614 && cp <= 0x2615) || (\
                cp >= 0x2630 && cp <= 0x2637) || (cp >= 0x2648 && cp <= 0x2653) || cp == 0x267F || (\
                cp >= 0x268A && cp <= 0x268F) || cp == 0x2693 || cp == 0x26A1 || (\
                cp >= 0x26AA && cp <= 0x26AB) || (cp >= 0x26BD && cp <= 0x26BE) || (\
                cp >= 0x26C4 && cp <= 0x26C5) || cp == 0x26CE || cp == 0x26D4 || cp == 0x26EA || (\
                cp >= 0x26F2 && cp <= 0x26F3) || cp == 0x26F5 || cp == 0x26FA || cp == 0x26FD || \
                cp == 0x2705 || (cp >= 0x270A && cp <= 0x270B) || cp == 0x2728 || cp == 0x274C || \
                cp == 0x274E || (cp >= 0x2753 && cp <= 0x2755) || cp == 0x2757 || (\
                cp >= 0x2795 && cp <= 0x2797) || cp == 0x27B0 || cp == 0x27BF || (\
                cp >= 0x2B1B && cp <= 0x2B1C) || cp == 0x2B50 || cp == 0x2B55 || (\
                cp >= 0x2E80 && cp <= 0x2E99) || (cp >= 0x2E9B && cp <= 0x2EF3) || (\
                cp >= 0x2F00 && cp <= 0x2FD5) || (cp >= 0x2FF0 && cp <= 0x3029) || (\
                cp >= 0x302E && cp <= 0x303E) || (cp >= 0x3041 && cp <= 0x3096) || (\
                cp >= 0x309B && cp <= 0x30FF) || (cp >= 0x3105 && cp <= 0x312F) || (\
                cp >= 0x3131 && cp <= 0x318E) || (cp >= 0x3190 && cp <= 0x31E5) || (\
                cp >= 0x31EF && cp <= 0x321E) || (cp >= 0x3220 && cp <= 0x3247) || (\
                cp >= 0x3250 && cp <= 0x4DBF) || (cp >= 0x4E00 && cp <= 0xA4CF) || (\
                cp >= 0xA960 && cp <= 0xA97C) || (cp >= 0xAC00 && cp <= 0xD7A3) || (\
                cp >= 0xFE10 && cp <= 0xFE19) || (cp >= 0xFE30 && cp <= 0xFE52) || (\
                cp >= 0xFE54 && cp <= 0xFE66) || (cp >= 0xFE68 && cp <= 0xFE6B) || (\
                cp >= 0xFF01 && cp <= 0xFF60) || (cp >= 0xFFE0 && cp <= 0xFFE6) || (\
                cp >= 0x16FE0 && cp <= 0x16FE4) || (cp >= 0x17000 && cp <= 0x18AFF) || (\
                cp >= 0x1B000 && cp <= 0x1B2FF) || cp == 0x1F004 || cp == 0x1F0CF || cp == 0x1F18E || (\
                cp >= 0x1F191 && cp <= 0x1F19A) || (cp >= 0x1F200 && cp <= 0x1F202) || (\
                cp >= 0x1F210 && cp <= 0x1F23B) || (cp >= 0x1F240 && cp <= 0x1F248) || (\
                cp >= 0x1F250 && cp <= 0x1F251) || (cp >= 0x1F260 && cp <= 0x1F265) || (\
                cp >= 0x1F300 && cp <= 0x1F320) || (cp >= 0x1F32D && cp <= 0x1F335) || (\
                cp >= 0x1F337 && cp <= 0x1F37C) || (cp >= 0x1F37E && cp <= 0x1F393) || (\
                cp >= 0x1F3A0 && cp <= 0x1F3CA) || (cp >= 0x1F3CF && cp <= 0x1F3D3) || (\
                cp >= 0x1F3E0 && cp <= 0x1F3F0) || cp == 0x1F3F4 || (cp >= 0x1F3F8 && cp <= 0x1F3FA) || (\
                cp >= 0x1F400 && cp <= 0x1F43E) || cp == 0x1F440 || (cp >= 0x1F442 && cp <= 0x1F4FC) || (\
                cp >= 0x1F4FF && cp <= 0x1F53D) || (cp >= 0x1F54B && cp <= 0x1F54E) || (\
                cp >= 0x1F550 && cp <= 0x1F567) || cp == 0x1F57A || (cp >= 0x1F595 && cp <= 0x1F596) || \
                cp == 0x1F5A4 || (cp >= 0x1F5FB && cp <= 0x1F64F) || (cp >= 0x1F680 && cp <= 0x1F6C5) || \
                cp == 0x1F6CC || (cp >= 0x1F6D0 && cp <= 0x1F6D2) || (cp >= 0x1F6D5 && cp <= 0x1F6D7) || (\
                cp >= 0x1F6DC && cp <= 0x1F6DF) || (cp >= 0x1F6EB && cp <= 0x1F6EC) || (\
                cp >= 0x1F6F4 && cp <= 0x1F6FC) || (cp >= 0x1F7E0 && cp <= 0x1F7EB) || cp == 0x1F7F0 || (\
                cp >= 0x1F90C && cp <= 0x1F93A) || (cp >= 0x1F93C && cp <= 0x1F945) || (\
                cp >= 0x1F947 && cp <= 0x1F9FF) || (cp >= 0x1FA70 && cp <= 0x1FA7C) || (\
                cp >= 0x1FA80 && cp <= 0x1FA89) || (cp >= 0x1FA8F && cp <= 0x1FAC6) || (\
                cp >= 0x1FACE && cp <= 0x1FADC) || (cp >= 0x1FADF && cp <= 0x1FAE9) || (\
                cp >= 0x1FAF0 && cp <= 0x1FAF8) || (cp >= 0x20000 && cp <= 0x3FFFD))); then
                w=2
            else
                w=1
            fi
            if ((cp < 0x1F1E6 || cp > 0x1F1FF)); then flag_open=0; fi
            # An emoji after a ZWJ joins the cluster before it.
            if ((after_zwj && prev_w == 2 && w > 0 && (cp >= 0x1F000 || (cp >= 0x2190 && cp <= 0x2BFF)))); then
                w=0
            fi
            after_zwj=0
            width=$((width + w))
            if ((w > 0)); then prev_w=$w; fi
        done
    fi

    if [[ -n "$had_lc" ]]; then
        export LC_ALL="$old_lc"
    else
        unset LC_ALL
    fi
    echo "$width"
}

# Truncate string by display width (handles CJK)
truncate_by_display_width() {
    local str="$1"
    local max_width="$2"
    local current_width
    current_width=$(get_display_width "$str")

    if [[ $current_width -le $max_width ]]; then
        # printf, not echo: a string such as "-n" or "-e" is an echo option.
        printf '%s\n' "$str"
        return
    fi

    # Fallback: Use pure bash character iteration
    # Since we need to know the width of *each* character to truncate at the right spot,
    # we cannot just use the total width formula on the whole string.
    # However, iterating char-by-char and calling the optimized get_display_width function
    # is now much faster because it doesn't fork 'wc'.

    # CRITICAL: Switch to UTF-8 for correct character iteration
    local old_lc="${LC_ALL:-}"
    export LC_ALL=en_US.UTF-8

    local truncated=""
    local width=0
    local i=0
    local char char_width
    local strlen=${#str} # Re-calculate in UTF-8

    # Optimization: If total width <= max_width, return original string (checked above)

    while [[ $i -lt $strlen ]]; do
        char="${str:$i:1}"

        # Inlined width calculation for minimal overhead to avoid recursion overhead
        # We are already in UTF-8, so ${#char} is char length (1).
        # We need byte length for the heuristic.
        # But switching locale inside loop is disastrous for perf.
        # Logic: If char is ASCII (1 byte), width 1.
        # If char is wide (3 bytes), width 2.
        # How to detect byte size without switching locale?
        # printf %s "$char" | wc -c ? Slow.
        # Check against ASCII range?
        # Bash's own pattern matcher knows [:ascii:]; a regex hands it to
        # regcomp, where glibc rejects it (#1918) and macOS never matches.
        if [[ "$char" == [[:ascii:]] ]]; then
            char_width=1
        else
            # Assume wide for non-ascii in this context (simplified)
            # Or use LC_ALL=C inside? No.
            # Most non-ASCII in filenames are either CJK (width 2) or heavy symbols.
            # Let's assume 2 for simplicity in this fast loop as we know we are usually dealing with CJK.
            char_width=2
        fi

        if ((width + char_width + 3 > max_width)); then
            break
        fi

        truncated+="$char"
        width=$((width + char_width))
        i=$((i + 1))
    done

    # Restore locale
    if [[ -n "$old_lc" ]]; then
        export LC_ALL="$old_lc"
    else
        unset LC_ALL
    fi

    printf '%s...\n' "$truncated"
}

# Shorten to max_width columns by cutting the middle and joining the ends with
# "…" (one column). A third of the room goes to the head and the rest to the
# tail, because bundle ids and process names differ at the end
# (com.microsoft.VSCode vs com.microsoft.VSCode.ShipIt), which an end cut hides.
# Uses the same ASCII-1 / other-2 column guess as truncate_by_display_width.
truncate_middle_by_display_width() {
    local str="$1"
    local max_width="$2"
    if (($(get_display_width "$str") <= max_width)); then
        printf '%s\n' "$str"
        return
    fi
    local LC_ALL=en_US.UTF-8
    local keep=$((max_width - 1))
    ((keep > 1)) || keep=1
    local head_room=$((keep / 3)) tail_room
    tail_room=$((keep - head_room))
    local head="" tail="" char cw width=0 i=0 n=${#str}
    while ((i < n)); do
        char="${str:i:1}"
        if [[ "$char" == [[:ascii:]] ]]; then cw=1; else cw=2; fi
        ((width + cw <= head_room)) || break
        head+="$char"
        width=$((width + cw))
        i=$((i + 1))
    done
    width=0
    local j=$((n - 1))
    while ((j >= i)); do
        char="${str:j:1}"
        if [[ "$char" == [[:ascii:]] ]]; then cw=1; else cw=2; fi
        ((width + cw <= tail_room)) || break
        tail="$char$tail"
        width=$((width + cw))
        j=$((j - 1))
    done
    printf '%s…%s\n' "$head" "$tail"
}

# Read single keyboard input
read_key() {
    local key rest read_status
    if [[ "${1:-}" == "1" ]]; then
        # Bash 3.2 returns 1 for both EOF and timeout; elapsed shell time
        # distinguishes an idle tick from immediate EOF. ESC reads stay below.
        local read_started=$SECONDS
        if IFS= read -r -s -n 1 -t 1 key; then read_status=0; else read_status=$?; fi
        if [[ "$read_status" -ne 0 ]] && ((SECONDS > read_started)); then return 1; fi
    else
        if IFS= read -r -s -n 1 key; then read_status=0; else read_status=$?; fi
    fi
    [[ $read_status -ne 0 ]] && {
        echo "QUIT"
        return 0
    }

    # Decode terminal sequences once, in both navigation and text-input modes.
    # Keep the established one-second ESC reads for Bash 3.2.
    if [[ "$key" == $'\x1b' ]]; then
        local sequence="" terminator=""
        if ! IFS= read -r -s -n 1 -t 1 rest 2> /dev/null; then
            echo "QUIT"
        elif [[ "$rest" == "[" || "$rest" == "O" ]]; then
            if ! IFS= read -r -s -n 1 -t 1 sequence 2> /dev/null; then
                [[ "$rest" == "[" ]] && echo "QUIT" || echo "OTHER"
            else
                case "$sequence" in
                    A) echo "UP" ;;
                    B) echo "DOWN" ;;
                    C) echo "RIGHT" ;;
                    D) echo "LEFT" ;;
                    H) echo "TOP" ;;
                    F) echo "BOTTOM" ;;
                    1 | 3 | 4 | 5 | 6 | 7 | 8)
                        if [[ "$rest" == "[" ]] && IFS= read -r -s -n 1 -t 1 terminator 2> /dev/null && [[ "$terminator" == "~" ]]; then
                            case "$sequence" in
                                1 | 7) echo "TOP" ;;
                                4 | 8) echo "BOTTOM" ;;
                                5) echo "LEFT" ;;
                                6) echo "RIGHT" ;;
                                3) echo "DELETE" ;;
                            esac
                        else
                            echo "OTHER"
                        fi
                        ;;
                    *) echo "OTHER" ;;
                esac
            fi
        elif [[ "${MOLE_READ_KEY_FORCE_CHAR:-}" == "1" ]]; then
            echo "QUIT"
        else
            echo "OTHER"
        fi
        return 0
    fi

    if [[ "${MOLE_READ_KEY_FORCE_CHAR:-}" == "1" ]]; then
        [[ -z "$key" ]] && {
            echo "ENTER"
            return 0
        }
        case "$key" in
            $'\n' | $'\r') echo "ENTER" ;;
            $'\x7f' | $'\x08') echo "DELETE" ;;
            $'\x15') echo "CLEAR_LINE" ;; # Ctrl+U (often mapped from Cmd+Delete in terminals)
            ' ') echo "SPACE" ;;          # Search input or selection, decided by the menu
            $'\x03') echo "QUIT" ;;
            [[:print:]]) echo "CHAR:$key" ;;
            *) echo "OTHER" ;;
        esac
        return 0
    fi

    [[ -z "$key" ]] && {
        echo "ENTER"
        return 0
    }
    case "$key" in
        $'\n' | $'\r') echo "ENTER" ;;
        ' ') echo "SPACE" ;;
        'q' | 'Q') echo "QUIT" ;;
        'R') echo "RETRY" ;;
        'm' | 'M') echo "MORE" ;;
        'v' | 'V') echo "VERSION" ;;
        'u' | 'U') echo "UPDATE" ;;
        't' | 'T') echo "TOUCHID" ;;
        'j' | 'J') echo "DOWN" ;;
        'k' | 'K') echo "UP" ;;
        'h' | 'H') echo "LEFT" ;;
        'l' | 'L') echo "RIGHT" ;;
        'G') echo "BOTTOM" ;;
        'g')
            if IFS= read -r -s -n 1 -t "$MOLE_KEY_SEQ_TIMEOUT" rest 2> /dev/null; then
                if [[ "$rest" == "g" ]]; then
                    echo "TOP"
                else
                    echo "OTHER"
                fi
            else
                echo "OTHER"
            fi
            ;;
        $'\x03') echo "QUIT" ;;
        $'\x7f' | $'\x08') echo "DELETE" ;;
        $'\x15') echo "CLEAR_LINE" ;; # Ctrl+U
        [[:print:]]) echo "CHAR:$key" ;;
        *) echo "OTHER" ;;
    esac
}

# Absolute path on purpose: a version-manager shim earlier on PATH can fail or
# start slowly, and this runs after every menu key.
_mole_drain_with_perl() {
    [[ -x /usr/bin/perl ]] || return 127
    /usr/bin/perl -MPOSIX=tcflush,TCIFLUSH -e '
        my $timeout = shift;
        if (-t STDIN) {
            select undef, undef, undef, $timeout;
            exit(defined(tcflush(fileno(STDIN), TCIFLUSH)) ? 0 : 1);
        }
        my $input = "";
        vec($input, fileno(STDIN), 1) = 1;
        for (1..101) {
            my $ready = $input;
            last unless select($ready, undef, undef, $timeout) > 0;
            last unless sysread(STDIN, my $byte, 1);
            $timeout = 0.01;
        }
    ' "$1" 2> /dev/null
}

drain_pending_input() {
    local idle_timeout="${1:-0.01}"
    local between_timeout="0.01"
    # Bash 3.2 rejects fractional read timeouts, and read -t 0 never consumes
    # input. Use macOS's Perl for the short idle wait without changing TTY modes.
    if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
        if _mole_drain_with_perl "$idle_timeout"; then
            return 0
        fi
        # An integer read would block a terminal for a full second per call,
        # so a terminal without Perl keeps its queue rather than stalling keys.
        [[ -t 0 ]] && return 0
        # Pipes have no keystrokes to delay; integer reads still drain them.
        idle_timeout="1"
        between_timeout="1"
    fi
    local drained=0
    while IFS= read -r -s -n 1 -t "$idle_timeout" _ 2> /dev/null; do
        drained=$((drained + 1))
        [[ $drained -gt 100 ]] && break
        idle_timeout="$between_timeout"
    done
    return 0
}

# Format menu option display
show_menu_option() {
    local number="$1"
    local text="$2"
    local selected="$3"

    if [[ "$selected" == "true" ]]; then
        echo -e "${CYAN}${ICON_ARROW} $number. $text${NC}"
    else
        echo "  $number. $text"
    fi
}

# Background spinner implementation
INLINE_SPINNER_PID=""
INLINE_SPINNER_STOP_FILE=""
INLINE_SPINNER_MSG_FILE=""
INLINE_SPINNER_CONTROL_DIR=""

create_inline_spinner_control_dir() {
    ensure_mole_temp_root || return 1
    local control_root="$MOLE_RESOLVED_TMPDIR"

    [[ -d "$control_root" && ! -L "$control_root" ]] || return 1
    INLINE_SPINNER_CONTROL_DIR=$(umask 077 && mktemp -d "$control_root/.mole-spinner.XXXXXX") || return 1
    [[ -d "$INLINE_SPINNER_CONTROL_DIR" && ! -L "$INLINE_SPINNER_CONTROL_DIR" && -O "$INLINE_SPINNER_CONTROL_DIR" ]] || return 1
    MOLE_TEMP_DIRS+=("$INLINE_SPINNER_CONTROL_DIR")
}

# Keep spinner message on one line and avoid wrapping/noisy output on narrow terminals.
format_spinner_message() {
    local message="$1"
    message="${message//$'\r'/ }"
    message="${message//$'\n'/ }"

    local cols=80
    if command -v tput > /dev/null 2>&1; then
        cols=$(tput cols 2> /dev/null || echo "80")
    fi
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80

    # Reserve space for prefix + spinner char + spacing.
    local available=$((cols - 8))
    if [[ $available -lt 20 ]]; then
        available=20
    fi

    # An app or file name can make the message non-ASCII. ${#message} then
    # counts bytes under LC_ALL=C or characters otherwise, neither of which is
    # the width a CJK name takes, and a byte slice splits a character.
    if [[ "$message" == *[![:ascii:]]* ]]; then
        if (($(get_display_width "$message") > available)); then
            message=$(truncate_by_display_width "$message" "$available")
        fi
    elif [[ ${#message} -gt $available ]]; then
        message="${message:0:$((available - 3))}..."
    fi

    printf "%s" "$message"
}

start_inline_spinner() {
    stop_inline_spinner 2> /dev/null || true
    local message="$1"
    local display_message
    display_message=$(format_spinner_message "$message")

    if [[ -t 1 ]]; then
        if ! create_inline_spinner_control_dir; then
            echo -n "  ${BLUE}|${NC} $display_message" >&2 || true
            return 0
        fi

        INLINE_SPINNER_STOP_FILE="$INLINE_SPINNER_CONTROL_DIR/stop"
        # Message file lets callers swap the text in place; a stop/start cycle
        # blanks the line for a frame and reads as flicker.
        INLINE_SPINNER_MSG_FILE="$INLINE_SPINNER_CONTROL_DIR/message"
        if ! (umask 077 && set -C && printf '%s\n' "$display_message" > "$INLINE_SPINNER_MSG_FILE") 2> /dev/null; then
            rmdir "$INLINE_SPINNER_CONTROL_DIR" 2> /dev/null || true
            INLINE_SPINNER_CONTROL_DIR=""
            INLINE_SPINNER_STOP_FILE=""
            INLINE_SPINNER_MSG_FILE=""
            echo -n "  ${BLUE}|${NC} $display_message" >&2 || true
            return 0
        fi

        (
            local stop_file="$INLINE_SPINNER_STOP_FILE"
            local msg_file="$INLINE_SPINNER_MSG_FILE"
            mo_load_spinner_frames
            local i=0
            local current_message="$display_message"
            local next_message=""

            # Clear line on first output to prevent text remnants from previous messages
            printf "\r\033[2K" >&2 || true

            # Cooperative exit: check for stop file instead of relying on signals
            while [[ ! -f "$stop_file" ]]; do
                local c="${MO_SPINNER_FRAMES[$((i % ${#MO_SPINNER_FRAMES[@]}))]}"
                # Re-read the message each frame; erase the line only when the
                # text changed (a shorter message would leave remnants), and
                # keep erase + redraw in one write so no blank frame shows.
                local frame_lead="\r"
                if [[ -f "$msg_file" && ! -L "$msg_file" && -r "$msg_file" ]]; then
                    IFS= read -r next_message < "$msg_file" 2> /dev/null || next_message=""
                    if [[ -n "$next_message" && "$next_message" != "$current_message" ]]; then
                        current_message="$next_message"
                        frame_lead="\r\033[2K"
                    fi
                fi
                # Output to stderr to avoid interfering with stdout
                printf "${frame_lead}${MOLE_SPINNER_PREFIX:-}${BLUE}%s${NC} %s" "$c" "$current_message" >&2 || break
                i=$((i + 1))
                /bin/sleep 0.08
            done

            # Clean up stop file before exiting
            rm -f "$stop_file" 2> /dev/null || true
            exit 0
        ) &
        INLINE_SPINNER_PID=$!
        disown "$INLINE_SPINNER_PID" 2> /dev/null || true
    else
        echo -n "  ${BLUE}|${NC} $display_message" >&2 || true
    fi
}

stop_inline_spinner() {
    if [[ -n "$INLINE_SPINNER_PID" ]]; then
        # Cooperative stop: create stop file to signal spinner to exit
        if [[ -n "$INLINE_SPINNER_STOP_FILE" ]]; then
            touch "$INLINE_SPINNER_STOP_FILE" 2> /dev/null || true
        fi

        # Wait briefly for cooperative exit
        local wait_count=0
        while kill -0 "$INLINE_SPINNER_PID" 2> /dev/null && [[ $wait_count -lt 5 ]]; do
            /bin/sleep 0.05 2> /dev/null || true
            wait_count=$((wait_count + 1))
        done

        # Only use SIGKILL as last resort if process is stuck
        if kill -0 "$INLINE_SPINNER_PID" 2> /dev/null; then
            kill -KILL "$INLINE_SPINNER_PID" 2> /dev/null || true
        fi

        wait "$INLINE_SPINNER_PID" 2> /dev/null || true

        # Cleanup
        rm -f "$INLINE_SPINNER_STOP_FILE" 2> /dev/null || true
        rm -f "$INLINE_SPINNER_MSG_FILE" 2> /dev/null || true
        if [[ -n "$INLINE_SPINNER_CONTROL_DIR" ]]; then
            rmdir "$INLINE_SPINNER_CONTROL_DIR" 2> /dev/null || true
        fi
        INLINE_SPINNER_PID=""
        INLINE_SPINNER_STOP_FILE=""
        INLINE_SPINNER_MSG_FILE=""
        INLINE_SPINNER_CONTROL_DIR=""

        # Clear the line - use \033[2K to clear entire line, not just to end
        [[ -t 2 ]] && printf "\r\033[2K" >&2 || true
    fi
}

# Swap the text of a running inline spinner without restarting it.
# Returns 1 when no spinner is active so callers can fall back to starting one.
update_inline_spinner_message() {
    local message="$1"
    [[ -n "$INLINE_SPINNER_PID" && -n "$INLINE_SPINNER_MSG_FILE" && -n "$INLINE_SPINNER_CONTROL_DIR" ]] || return 1
    kill -0 "$INLINE_SPINNER_PID" 2> /dev/null || return 1
    [[ -f "$INLINE_SPINNER_MSG_FILE" && ! -L "$INLINE_SPINNER_MSG_FILE" && -O "$INLINE_SPINNER_MSG_FILE" ]] || return 1

    local display_message
    display_message=$(format_spinner_message "$message")

    # Write-then-rename so the spinner never reads a half-truncated file.
    local tmp_file
    tmp_file=$(umask 077 && mktemp "$INLINE_SPINNER_CONTROL_DIR/message.XXXXXX") || return 1
    if ! printf '%s\n' "$display_message" > "$tmp_file" 2> /dev/null; then
        rm -f "$tmp_file" 2> /dev/null || true
        return 1
    fi
    if ! mv -f "$tmp_file" "$INLINE_SPINNER_MSG_FILE" 2> /dev/null; then
        rm -f "$tmp_file" 2> /dev/null || true
        return 1
    fi
    return 0
}

# Keep the spinner in the middle two braille rows for a centered 2x2 shape.
mo_spinner_chars() {
    printf "%s\n" "⠖" "⠲" "⠴" "⠦"
}

# Fill MO_SPINNER_FRAMES, one frame per element, for every spinner loop.
# LC_ALL=C makes ${var:i:1} slice bytes, so multibyte frames must never be
# indexed out of a single string.
mo_load_spinner_frames() {
    MO_SPINNER_FRAMES=()
    local frame=""
    while IFS= read -r frame; do
        [[ -n "$frame" ]] && MO_SPINNER_FRAMES[${#MO_SPINNER_FRAMES[@]}]="$frame"
    done < <(mo_spinner_chars)
    [[ ${#MO_SPINNER_FRAMES[@]} -gt 0 ]] || MO_SPINNER_FRAMES=("|" "/" "-" "\\")
}

# Format relative time for compact display (e.g., 3d ago)
format_last_used_summary() {
    local value="$1"

    case "$value" in
        "" | "Unknown")
            echo "Unknown"
            return 0
            ;;
        "Never" | "Recent" | "Today" | "Yesterday" | "This year" | "Old")
            echo "$value"
            return 0
            ;;
    esac

    if [[ $value =~ ^([0-9]+)[[:space:]]+days?\ ago$ ]]; then
        echo "${BASH_REMATCH[1]}d ago"
        return 0
    fi
    if [[ $value =~ ^([0-9]+)[[:space:]]+weeks?\ ago$ ]]; then
        echo "${BASH_REMATCH[1]}w ago"
        return 0
    fi
    if [[ $value =~ ^([0-9]+)[[:space:]]+months?\ ago$ ]]; then
        echo "${BASH_REMATCH[1]}m ago"
        return 0
    fi
    if [[ $value =~ ^([0-9]+)[[:space:]]+month\(s\)\ ago$ ]]; then
        echo "${BASH_REMATCH[1]}m ago"
        return 0
    fi
    if [[ $value =~ ^([0-9]+)[[:space:]]+years?\ ago$ ]]; then
        echo "${BASH_REMATCH[1]}y ago"
        return 0
    fi
    echo "$value"
}

# Check if terminal has Full Disk Access
# Returns 0 if FDA is granted, 1 if denied, 2 if unknown
has_full_disk_access() {
    # Cache the result to avoid repeated checks
    if [[ -n "${MOLE_HAS_FDA:-}" ]]; then
        if [[ "$MOLE_HAS_FDA" == "1" ]]; then
            return 0
        elif [[ "$MOLE_HAS_FDA" == "unknown" ]]; then
            return 2
        else
            return 1
        fi
    fi

    # Test access to protected directories that require FDA
    # Strategy: Try to access directories that are commonly protected
    # If ANY of them are accessible, we likely have FDA
    # If ALL fail, we definitely don't have FDA
    local -a protected_dirs=(
        "$HOME/Library/Safari/LocalStorage"
        "$HOME/Library/Mail/V10"
        "$HOME/Library/Messages/chat.db"
    )

    local accessible_count=0
    local tested_count=0

    for test_path in "${protected_dirs[@]}"; do
        # Only test when the protected path exists
        if [[ -e "$test_path" ]]; then
            tested_count=$((tested_count + 1))
            # stat succeeds without FDA; only reading the contents proves access
            if [[ -d "$test_path" ]]; then
                if /bin/ls "$test_path" > /dev/null 2>&1; then
                    accessible_count=$((accessible_count + 1))
                fi
            elif { : < "$test_path"; } 2> /dev/null; then
                accessible_count=$((accessible_count + 1))
            fi
        fi
    done

    # Three possible outcomes:
    # 1. tested_count = 0: Can't determine (test paths don't exist) → unknown
    # 2. tested_count > 0 && accessible_count > 0: Has FDA → yes
    # 3. tested_count > 0 && accessible_count = 0: No FDA → no
    if [[ $tested_count -eq 0 ]]; then
        # Can't determine - test paths don't exist, treat as unknown
        export MOLE_HAS_FDA="unknown"
        return 2
    elif [[ $accessible_count -gt 0 ]]; then
        # At least one path is accessible → has FDA
        export MOLE_HAS_FDA=1
        return 0
    else
        # Tested paths exist but not accessible → no FDA
        export MOLE_HAS_FDA=0
        return 1
    fi
}
