#!/bin/bash
# Mole - 国际化核心能力。
# 负责语言解析、语言配置读写、翻译目录加载与公共翻译函数。

set -euo pipefail

if [[ -n "${MOLE_I18N_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_I18N_LOADED=1

_MOLE_I18N_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "${MOLE_BASE_LOADED:-}" ]] && source "$_MOLE_I18N_CORE_DIR/base.sh"

readonly MOLE_LANG_ZH_CN="zh-CN"
readonly MOLE_LANG_EN_US="en-US"

# 返回 Mole 用户配置目录。
# 入参：无。
# 返回：string，配置目录绝对路径。
mole_get_config_dir() {
    printf '%s\n' "${MOLE_CONFIG_DIR:-$HOME/.config/mole}"
}

# 返回语言配置文件路径。
# 入参：无。
# 返回：string，语言配置文件绝对路径。
mole_get_language_config_file() {
    printf '%s/language\n' "$(mole_get_config_dir)"
}

# 规范化语言编码，避免出现大小写或别名差异。
# 入参：$1 string，原始语言值。
# 返回：string，规范化后的语言编码。
mole_normalize_language() {
    local raw="${1:-}"
    case "$raw" in
        zh | zh-* | zh_* | cn | CN) printf '%s\n' "$MOLE_LANG_ZH_CN" ;;
        en | en-* | en_* | us | US) printf '%s\n' "$MOLE_LANG_EN_US" ;;
        "$MOLE_LANG_ZH_CN" | "$MOLE_LANG_EN_US") printf '%s\n' "$raw" ;;
        *) printf '%s\n' "" ;;
    esac
}

# 根据系统语言推断推荐语言。
# 入参：无。
# 返回：string，推荐语言编码。
mole_detect_system_language() {
    local env_lang="${LANG:-${LC_ALL:-}}"
    local normalized
    normalized=$(mole_normalize_language "$env_lang")
    if [[ -n "$normalized" ]]; then
        printf '%s\n' "$normalized"
        return 0
    fi

    local apple_lang=""
    apple_lang=$(defaults read -g AppleLanguages 2> /dev/null | grep -o 'zh-Hans\|zh-Hant\|zh\|en-US\|en' | head -1 || true)
    normalized=$(mole_normalize_language "$apple_lang")
    if [[ -n "$normalized" ]]; then
        printf '%s\n' "$normalized"
        return 0
    fi

    printf '%s\n' "$MOLE_LANG_EN_US"
}

# 读取已经保存的语言设置。
# 入参：无。
# 返回：string，若未配置则返回空字符串。
mole_read_saved_language() {
    local config_file
    config_file=$(mole_get_language_config_file)
    [[ -f "$config_file" ]] || {
        printf '%s\n' ""
        return 0
    }

    local raw=""
    raw=$(sed -n 's/^LANG=//p' "$config_file" | head -1)
    mole_normalize_language "$raw"
}

# 持久化保存语言设置。
# 入参：$1 string，语言编码。
# 返回：0 表示成功，非 0 表示失败。
mole_set_language() {
    local normalized
    normalized=$(mole_normalize_language "${1:-}")
    [[ -n "$normalized" ]] || return 1

    local config_dir config_file tmp_file
    config_dir=$(mole_get_config_dir)
    config_file=$(mole_get_language_config_file)

    ensure_user_dir "$config_dir"
    tmp_file=$(mktemp "${config_dir}/language.XXXXXX") || return 1
    printf 'LANG=%s\n' "$normalized" > "$tmp_file"
    mv -f "$tmp_file" "$config_file"

    export MOLE_LANG="$normalized"
    MOLE_LANG_CATALOG_LOADED=""
    MOLE_LANG_CATALOG_NAME=""
    return 0
}

# 判断是否存在已保存语言。
# 入参：无。
# 返回：0 表示存在，1 表示不存在。
mole_has_saved_language() {
    [[ -n "$(mole_read_saved_language)" ]]
}

# 解析当前会话语言。
# 入参：无。
# 返回：string，当前应使用的语言编码。
mole_resolve_language() {
    local normalized=""

    normalized=$(mole_normalize_language "${MOLE_LANG:-}")
    if [[ -n "$normalized" ]]; then
        printf '%s\n' "$normalized"
        return 0
    fi

    normalized=$(mole_read_saved_language)
    if [[ -n "$normalized" ]]; then
        printf '%s\n' "$normalized"
        return 0
    fi

    printf '%s\n' "$MOLE_LANG_EN_US"
}

# 按当前语言加载对应翻译目录。
# 入参：无。
# 返回：0。
mole_load_language_catalog() {
    local lang
    lang=$(mole_resolve_language)
    export MOLE_LANG="$lang"

    if [[ "${MOLE_LANG_CATALOG_LOADED:-}" == "$lang" ]]; then
        return 0
    fi

    case "$lang" in
        "$MOLE_LANG_ZH_CN")
            source "$_MOLE_I18N_CORE_DIR/../i18n/zh_cn.sh"
            MOLE_LANG_CATALOG_NAME="zh_cn"
            ;;
        *)
            source "$_MOLE_I18N_CORE_DIR/../i18n/en_us.sh"
            MOLE_LANG_CATALOG_NAME="en_us"
            ;;
    esac

    MOLE_LANG_CATALOG_LOADED="$lang"
    return 0
}

# 初始化当前会话语言环境。
# 入参：无。
# 返回：0。
mole_init_language() {
    export MOLE_LANG="$(mole_resolve_language)"
    mole_load_language_catalog
}

# 返回当前语言是否为中文。
# 入参：无。
# 返回：0 表示中文，1 表示非中文。
mole_is_chinese_language() {
    [[ "$(mole_resolve_language)" == "$MOLE_LANG_ZH_CN" ]]
}

# 翻译普通文案或格式化模板。
# 入参：$1 string，英文键值或格式化模板。
# 返回：string，翻译后的文案或原文。
mole_t() {
    mole_load_language_catalog
    local key="${1:-}"
    case "${MOLE_LANG_CATALOG_NAME:-en_us}" in
        zh_cn) mole_translate_zh_cn "$key" ;;
        *) mole_translate_en_us "$key" ;;
    esac
}

# 返回语言的展示名称。
# 入参：$1 string，语言编码。
# 返回：string，对用户展示的语言名称。
mole_language_name() {
    local normalized
    normalized=$(mole_normalize_language "${1:-}")
    case "$normalized" in
        "$MOLE_LANG_ZH_CN") printf '%s\n' '简体中文' ;;
        "$MOLE_LANG_EN_US") printf '%s\n' 'English' ;;
        *) printf '%s\n' "${1:-}" ;;
    esac
}

# 统一输出翻译后的单行文案。
# 入参：$1 string，英文键值。
# 返回：0。
mole_println_t() {
    printf '%s\n' "$(mole_t "$1")"
}

mole_init_language
