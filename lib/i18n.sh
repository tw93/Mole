#!/bin/bash
# Mole - Internationalization Library

# Global translation map (using variables for Bash 3.2 compatibility)
# Keys will be stored as I18N_key

# Current language
MOLE_CURRENT_LANG="en"

# Initialize i18n
i18n_init() {
    # Detect language
    if [[ "${MOLE_LANG:-}" == "zh" ]] || [[ "${LANG:-}" == *"zh_"* ]]; then
        MOLE_CURRENT_LANG="zh"
    else
        MOLE_CURRENT_LANG="en"
    fi

    # Always load translation file
    local lang_file="$SCRIPT_DIR/../config/lang/${MOLE_CURRENT_LANG}.sh"
    
    # Prefer local config/lang relative to this file (dev environment)
    if [[ ! -f "$lang_file" ]]; then
        local lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        lang_file="$lib_dir/../config/lang/${MOLE_CURRENT_LANG}.sh"
    fi

    # Then check user config dir (installed environment)
    if [[ ! -f "$lang_file" ]]; then
        local config_dir="${CONFIG_DIR:-$HOME/.config/mole}"
        lang_file="$config_dir/config/lang/${MOLE_CURRENT_LANG}.sh"
    fi

    if [[ -f "$lang_file" ]]; then
        source "$lang_file"
    else
        # Fallback: try to load English if current language file not found
        if [[ "$MOLE_CURRENT_LANG" != "en" ]]; then
            local en_file="${lang_file/$MOLE_CURRENT_LANG/en}"
            [[ -f "$en_file" ]] && source "$en_file"
        fi
    fi
}

# Translation function
# Usage: t "key"
# Note: No default parameter needed, all translations are in files
t() {
    local key="$1"
    local var_name="I18N_${key}"
    local translation=""
    eval "translation=\"\${$var_name:-}\""
    
    if [[ -n "$translation" ]]; then
        echo "$translation"
    else
        # Return the key itself if translation not found (for debugging)
        echo "[${key}]"
    fi
}

# Initialize immediately
i18n_init
