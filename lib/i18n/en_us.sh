#!/bin/bash
# Mole - 英文翻译目录。
# 英文为默认原文，未命中时直接返回键值本身。

mole_translate_en_us() {
    printf '%s\n' "${1:-}"
}
