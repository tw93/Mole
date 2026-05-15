// Package locale provides lightweight i18n for Mole's TUI components.
//
// Language detection order:
//  1. MO_LANG environment variable (e.g. "zh", "zh_CN", "en")
//  2. LC_ALL / LANG system locale
//  3. Fallback to English
package locale

import (
	"fmt"
	"os"
	"strings"
	"sync"
)

var (
	current  = "en"
	messages map[string]string
	once     sync.Once
)

// Init detects the user's locale and loads the appropriate message table.
// Safe to call multiple times; only the first call has effect.
func Init() {
	once.Do(func() {
		lang := os.Getenv("MO_LANG")
		if lang == "" {
			lang = detectFromEnv()
		}
		lang = normalize(lang)

		if lang == "zh" || strings.HasPrefix(lang, "zh_CN") || strings.HasPrefix(lang, "zh_Hans") {
			current = "zh"
			messages = zhMessages
		} else {
			current = "en"
			messages = enMessages
		}
	})
}

// T returns the translated string for the given key.
// Falls back to the key itself if no translation is found.
func T(key string) string {
	if messages == nil {
		Init()
	}
	if msg, ok := messages[key]; ok {
		return msg
	}
	return key
}

// Tf returns the translated string with printf-style formatting.
func Tf(key string, args ...interface{}) string {
	return fmt.Sprintf(T(key), args...)
}

// Current returns the active locale identifier ("en" or "zh").
func Current() string {
	if messages == nil {
		Init()
	}
	return current
}

func detectFromEnv() string {
	if v := os.Getenv("LC_ALL"); v != "" {
		return v
	}
	if v := os.Getenv("LANG"); v != "" {
		return v
	}
	return "en"
}

func normalize(lang string) string {
	// Strip encoding: "zh_CN.UTF-8" → "zh_CN"
	if i := strings.IndexByte(lang, '.'); i >= 0 {
		lang = lang[:i]
	}
	// Strip modifier: "sr_RS@latin" → "sr_RS"
	if i := strings.IndexByte(lang, '@'); i >= 0 {
		lang = lang[:i]
	}
	return lang
}
