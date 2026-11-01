package main

import "testing"

func TestDetectRestartReason(t *testing.T) {
	tests := []struct {
		name  string
		files map[string]string
		want  bool
	}{
		{"nothing pending", map[string]string{
			"proc/sys/kernel/osrelease":                  "6.12.1-arch1-1\n",
			"usr/lib/modules/6.12.1-arch1-1/modules.dep": "x",
		}, false},
		{"debian reboot-required", map[string]string{"run/reboot-required": "*** System restart required ***\n"}, true},
		{"arch kernel replaced", map[string]string{
			"proc/sys/kernel/osrelease":                  "6.12.1-arch1-1\n",
			"usr/lib/modules/6.12.2-arch1-1/modules.dep": "x",
		}, true},
		{"container ignores both signals", map[string]string{
			".dockerenv":                         "",
			"run/reboot-required":                "x",
			"proc/sys/kernel/osrelease":          "6.12.1\n",
			"usr/lib/modules/6.13.0/modules.dep": "x",
		}, false},
		{"no modules directory", map[string]string{"proc/sys/kernel/osrelease": "6.12.1\n"}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := detectRestartReason(writeTree(t, tt.files))
			if (got != "") != tt.want {
				t.Fatalf("detectRestartReason() = %q, want pending=%v", got, tt.want)
			}
		})
	}
}
