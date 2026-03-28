//go:build darwin

package main

import (
	molei18n "github.com/tw93/mole/internal/i18n"
)

// tr 返回当前语言下的翻译文案。
// 入参：key string，英文原始文案。
// 返回：string，翻译后的文案。
func tr(key string) string {
	return molei18n.T(key)
}

// ftr 先翻译格式化模板，再执行格式化输出。
// 入参：format string，英文格式化模板；args ...any，格式化参数。
// 返回：string，翻译并格式化后的文案。
func ftr(format string, args ...any) string {
	return molei18n.F(format, args...)
}
