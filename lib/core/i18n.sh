#!/bin/bash
# Mole - Internationalization (i18n) Module
# Provides locale detection and message lookup for all user-facing strings.
#
# Usage:
#   msg "KEY"               -> returns translated string
#   msgf "KEY" arg1 arg2    -> returns translated string with printf formatting
#
# Language detection order:
#   1. $MO_LANG (explicit override, e.g. MO_LANG=zh)
#   2. $LC_ALL / $LANG (system locale)
#   3. Fallback to English
#
# Supported locales: en (default), zh_CN
#
# Implementation note:
#   Uses flat shell variables (MOLE_MSG_<KEY>) and indirect expansion via
#   "${!varname}" instead of associative arrays. This keeps the module
#   compatible with macOS stock /bin/bash 3.2 (Apple does not ship bash 4
#   due to GPLv3), which is a hard requirement for the rest of Mole.

# Prevent multiple sourcing
if [[ -n "${MOLE_I18N_LOADED:-}" ]]; then
    return 0
fi
MOLE_I18N_LOADED=1

_MOLE_I18N_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../i18n" && pwd)"

# Current locale identifier (e.g. "en", "zh_CN")
MOLE_LOCALE=""

_mole_detect_locale() {
    local lang=""

    if [[ -n "${MO_LANG:-}" ]]; then
        lang="$MO_LANG"
    elif [[ -n "${LC_ALL:-}" ]]; then
        lang="$LC_ALL"
    elif [[ -n "${LANG:-}" ]]; then
        lang="$LANG"
    fi

    lang="${lang%%.*}"
    lang="${lang%%@*}"

    case "$lang" in
        zh_CN | zh_Hans | zh)
            echo "zh_CN"
            ;;
        zh_TW | zh_HK | zh_Hant)
            echo "en"
            ;;
        *)
            echo "en"
            ;;
    esac
}

# Always source English first as the fallback layer, then overlay the
# target locale. Missing keys in non-English locales silently fall back
# to English instead of leaking raw keys to users.
_mole_load_locale() {
    local locale="$1"
    local en_file="$_MOLE_I18N_DIR/en.sh"
    local target_file="$_MOLE_I18N_DIR/${locale}.sh"

    if [[ -f "$en_file" ]]; then
        # shellcheck source=/dev/null
        source "$en_file"
    fi

    if [[ "$locale" != "en" && -f "$target_file" ]]; then
        # shellcheck source=/dev/null
        source "$target_file"
    fi
}

msg() {
    local key="MOLE_MSG_$1"
    if [[ -n "${!key+x}" ]]; then
        printf '%s' "${!key}"
    else
        printf '%s' "$1"
    fi
}

msgf() {
    local key="MOLE_MSG_$1"
    local raw_key="$1"
    shift
    local fmt
    if [[ -n "${!key+x}" ]]; then
        fmt="${!key}"
    else
        fmt="$raw_key"
    fi
    # shellcheck disable=SC2059
    printf "$fmt" "$@"
}

MOLE_LOCALE=$(_mole_detect_locale)
_mole_load_locale "$MOLE_LOCALE"
