package main

import (
	"os"
	"path/filepath"
	"strings"
)

// detectRestartReason names why a restart is advisable, or returns "". Uptime
// alone is never a reason on Linux; only concrete evidence counts:
//
//   - Debian and Ubuntu write /run/reboot-required when an update needs one.
//   - Arch and friends delete the running kernel's /usr/lib/modules/<release>
//     directory when the kernel package is upgraded.
//
// Containers share the host kernel and see neither signal truthfully, so they
// are never told to restart.
func detectRestartReason(root string) string {
	if pathExists(filepath.Join(root, ".dockerenv")) || pathExists(filepath.Join(root, "run/.containerenv")) {
		return ""
	}
	for _, rel := range []string{"run/reboot-required", "var/run/reboot-required"} {
		if pathExists(filepath.Join(root, rel)) {
			return "reboot required by pending updates"
		}
	}

	release := readTrimmed(filepath.Join(root, "proc/sys/kernel/osrelease"))
	modules := filepath.Join(root, "usr/lib/modules")
	if release == "" || strings.ContainsRune(release, '/') {
		return ""
	}
	entries, err := os.ReadDir(modules)
	if err != nil || len(entries) == 0 {
		return ""
	}
	if !pathExists(filepath.Join(modules, release)) {
		return "running kernel was replaced by an update"
	}
	return ""
}
