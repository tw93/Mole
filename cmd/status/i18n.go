package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var __lang string
var __dict map[string]string

func __currentLang() string {
	l := os.Getenv("MOLE_LANG")
	if l == "" {
		l = os.Getenv("LANG")
	}
	if strings.Contains(strings.ToLower(l), "zh") || strings.ToLower(l) == "zh" {
		return "zh"
	}
	return "en"
}

func __langFile(lang string) string {
	exe, _ := os.Executable()
	base := filepath.Dir(exe)
	local := filepath.Join(base, "../config/lang", lang+".sh")
	if _, err := os.Stat(local); err == nil {
		return local
	}
	home, _ := os.UserHomeDir()
	cfg := filepath.Join(home, ".config/mole/config/lang", lang+".sh")
	if _, err := os.Stat(cfg); err == nil {
		return cfg
	}
	return local
}

func __load() {
	if __dict != nil {
		return
	}
	__dict = map[string]string{}
	lang := __currentLang()
	path := __langFile(lang)
	b, err := os.ReadFile(path)
	if err != nil {
		return
	}
	re := regexp.MustCompile(`^I18N_([A-Za-z0-9_]+)=("([^"]*)"|'([^']*)')\s*$`)
	lines := strings.Split(string(b), "\n")
	for _, ln := range lines {
		m := re.FindStringSubmatch(ln)
		if len(m) == 0 {
			continue
		}
		k := strings.ToLower(m[1])
		v := m[3]
		if v == "" {
			v = m[4]
		}
		__dict[k] = v
	}
}

func t(key string) string {
	if __lang == "" {
		__lang = __currentLang()
	}
	__load()
	if v, ok := __dict["i18n_"+key]; ok {
		return v
	}
	if v, ok := __dict[key]; ok {
		return v
	}
	return key
}

func translateStatus(s string) string {
	switch strings.ToLower(s) {
	case "warn":
		return t("mem_warn")
	case "critical":
		return t("mem_critical")
	case "normal":
		return t("status_normal")
	case "charging":
		return t("status_charging")
	case "charged":
		return t("status_charged")
	case "discharging":
		return t("status_discharging")
	case "ac":
		return t("status_ac")
	default:
		return s
	}
}
