package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestParseAppUnit(t *testing.T) {
	for _, tc := range []struct {
		unit, id, launcher string
		ok                 bool
	}{
		{"app-flatpak-org.mozilla.firefox-4242.scope", "org.mozilla.firefox", "flatpak", true},
		{"app-Hyprland-firefox-98765.scope", "firefox", "Hyprland", true},
		{"app-Hyprland-foot@a1b2c3.service", "foot", "Hyprland", true},
		{"app-org.gnome.Nautilus@1234.service", "org.gnome.Nautilus", "", true},
		{"app-gnome-org.gnome.Calculator-5555.scope", "org.gnome.Calculator", "gnome", true},
		{`app-uwsm-my\x2dapp-777.scope`, "my-app", "uwsm", true},
		{"app-firefox-1234.scope", "firefox", "", true},
		{"app-vlc.scope", "vlc", "", true},
		// Seen on the Omarchy VM: uwsm-style scope with a hex suffix and escaped dashes.
		{`app-Hyprland-xdg\x2dterminal\x2dexec-c3d4d733.scope`, "xdg-terminal-exec", "Hyprland", true},
		{"app-graphical.slice", "", "", false},
		{"app.slice", "", "", false},
		{"session-3.scope", "", "", false},
		{"user@1000.service", "", "", false},
		{"app-.scope", "", "", false},
		{"dbus.service", "", "", false},
	} {
		id, launcher, ok := parseAppUnit(tc.unit)
		if id != tc.id || launcher != tc.launcher || ok != tc.ok {
			t.Errorf("parseAppUnit(%q) = %q, %q, %v; want %q, %q, %v", tc.unit, id, launcher, ok, tc.id, tc.launcher, tc.ok)
		}
	}
}

func TestParseAppCgroupReadsNestedAndV1Lines(t *testing.T) {
	v2 := "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-Hyprland-kitty-31337.scope\n"
	if id, _ := parseAppCgroup(v2); id != "kitty" {
		t.Fatalf("v2 id = %q", id)
	}
	// A scope under an app service still belongs to the app; the first app unit wins.
	nested := "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-org.mozilla.firefox@9.service/sub-1.scope\n"
	if id, _ := parseAppCgroup(nested); id != "org.mozilla.firefox" {
		t.Fatalf("nested id = %q", id)
	}
	v1 := "12:cpu:/\n1:name=systemd:/user.slice/user-1000.slice/user@1000.service/app.slice/app-vlc-12.scope\n"
	if id, _ := parseAppCgroup(v1); id != "vlc" {
		t.Fatalf("v1 id = %q", id)
	}
	for _, none := range []string{"", "0::/\n", "0::/system.slice/sshd.service\n", "0::/user.slice/user-1000.slice/session-2.scope\n"} {
		if id, _ := parseAppCgroup(none); id != "" {
			t.Fatalf("parseAppCgroup(%q) = %q, want none", none, id)
		}
	}
}

func TestProcSamplerReadsAppIDOncePerPid(t *testing.T) {
	root := procFixture(t, "100.00", map[int]string{
		10: statLine(10, "firefox", "S", 1, 100, 0, 1000, 100),
		11: statLine(11, "Web Content", "S", 10, 100, 0, 1000, 100),
		12: statLine(12, "sshd", "S", 1, 100, 0, 1000, 100),
	})
	scope := "0::/user.slice/user@1000.service/app.slice/app-flatpak-org.mozilla.firefox-10.scope\n"
	addTree(t, root, map[string]string{"proc/10/cgroup": scope, "proc/11/cgroup": scope, "proc/12/cgroup": "0::/system.slice/sshd.service\n"})

	s := &procSampler{}
	sample, err := s.sample(root, time.Unix(1000, 0))
	if err != nil {
		t.Fatal(err)
	}
	byPID := map[int]ProcessInfo{}
	for _, p := range sample.processes {
		byPID[p.PID] = p
	}
	if byPID[10].AppID != "org.mozilla.firefox" || byPID[11].AppID != "org.mozilla.firefox" || byPID[12].AppID != "" {
		t.Fatalf("app ids = %q %q %q", byPID[10].AppID, byPID[11].AppID, byPID[12].AppID)
	}
	if sample.root != root {
		t.Fatalf("sample.root = %q", sample.root)
	}
	// The second sample reuses the cached id: removing the file must not change it.
	if err := os.Remove(filepath.Join(root, "proc/10/cgroup")); err != nil {
		t.Fatal(err)
	}
	sample, _ = s.sample(root, time.Unix(1001, 0))
	for _, p := range sample.processes {
		if p.PID == 10 && p.AppID != "org.mozilla.firefox" {
			t.Fatalf("cached app id lost: %q", p.AppID)
		}
	}
}

func TestGroupProcessesSumsAppsAndKeepsUngroupedRows(t *testing.T) {
	procs := []ProcessInfo{
		{PID: 1, Name: "firefox", AppID: "org.mozilla.firefox", CPU: 10, Memory: 2, MemoryBytes: 200},
		{PID: 2, Name: "Web Content", AppID: "org.mozilla.firefox", CPU: 15, Memory: 3, MemoryBytes: 300, GPUMemoryBytes: 50},
		{PID: 3, Name: "Web Content", AppID: "org.mozilla.firefox", CPU: 5, Memory: 1, MemoryBytes: 100},
		{PID: 4, Name: "go", CPU: 40, Memory: 1, MemoryBytes: 90},
		{PID: 5, Name: "kitty", AppID: "kitty", CPU: 1, MemoryBytes: 10},
	}
	rows := groupProcesses(procs)
	if len(rows) != 3 {
		t.Fatalf("rows = %#v", rows)
	}
	// go (40) ranks above the firefox total (30): ungrouped rows compete on the same CPU scale.
	if rows[0].Name != "go" || rows[0].Kind != appKindProcess || rows[0].PID != 4 {
		t.Fatalf("rows[0] = %#v", rows[0])
	}
	ff := rows[1]
	if ff.ID != "org.mozilla.firefox" || ff.Kind != appKindApp || ff.Processes != 3 || ff.CPU != 30 ||
		ff.MemoryBytes != 600 || ff.Memory != 6 || ff.GPUMemoryBytes != 50 {
		t.Fatalf("firefox row = %#v", ff)
	}
}

func TestDesktopNameReadsUnlocalizedNameFromTheFirstDirectory(t *testing.T) {
	first, second := t.TempDir(), t.TempDir()
	addTree(t, first, map[string]string{"org.mozilla.firefox.desktop": "[Desktop Entry]\nName[zh_CN]=火狐\nName=Firefox Web Browser\n[Desktop Action new-window]\nName=New Window\n"})
	addTree(t, second, map[string]string{
		"org.mozilla.firefox.desktop": "[Desktop Entry]\nName=Shadowed\n",
		"vlc.desktop":                 "[Desktop Action x]\nName=Wrong group\n[Desktop Entry]\nName=VLC media player\n",
	})
	dirs := []string{first, second}
	if got := desktopName("org.mozilla.firefox", dirs); got != "Firefox Web Browser" {
		t.Fatalf("firefox = %q", got)
	}
	if got := desktopName("vlc", dirs); got != "VLC media player" {
		t.Fatalf("vlc = %q", got)
	}
	for _, id := range []string{"missing", "", "../etc/passwd"} {
		if got := desktopName(id, dirs); got != "" {
			t.Fatalf("desktopName(%q) = %q, want empty", id, got)
		}
	}
}

func TestTopAppsNamesOnlyTheRowsItReturns(t *testing.T) {
	dir := t.TempDir()
	addTree(t, dir, map[string]string{"big.desktop": "[Desktop Entry]\nName=Big App\n", "small.desktop": "[Desktop Entry]\nName=Small App\n"})
	procs := []ProcessInfo{
		{PID: 1, Name: "big", AppID: "big", CPU: 50},
		{PID: 2, Name: "small", AppID: "small", CPU: 1},
	}
	rows := topApps(procs, 1, []string{dir})
	if len(rows) != 1 || rows[0].Name != "Big App" {
		t.Fatalf("rows = %#v", rows)
	}
	desktopNames.Lock()
	_, looked := desktopNames.m["small\x00"+dir]
	desktopNames.Unlock()
	if looked {
		t.Fatal("a row outside the limit had its .desktop file read")
	}
	if rows := topApps([]ProcessInfo{{PID: 3, Name: "x", AppID: "unknown.app", CPU: 1}}, 5, []string{dir}); rows[0].Name != "unknown.app" {
		t.Fatalf("fallback name = %q", rows[0].Name)
	}
}

func TestProcessRowsGroupsAndFallsBack(t *testing.T) {
	m := MetricsSnapshot{
		TopProcesses: []ProcessInfo{{PID: 9, Name: "plain", CPU: 1}},
		TopApps: []AppInfo{
			{Name: "Firefox", Kind: appKindApp, Processes: 14, CPU: 30, MemoryBytes: 1 << 30, GPUMemoryBytes: 1 << 28},
			{Name: "go", Kind: appKindProcess, PID: 4, Processes: 1, CPU: 5},
			{Name: "kitty", Kind: appKindApp, Processes: 1},
		},
	}
	rows := processRows(m)
	if rows[0].Name != "Firefox ×14" || rows[1].Name != "go" || rows[2].Name != "kitty" || rows[0].GPUMemoryBytes != 1<<28 {
		t.Fatalf("rows = %#v", rows)
	}
	m.TopApps = nil
	if rows := processRows(m); len(rows) != 1 || rows[0].Name != "plain" {
		t.Fatalf("fallback rows = %#v", rows)
	}
}

func TestProcessCardShowsGPUMemoryOnlyWhenMeasured(t *testing.T) {
	with := renderProcessCard([]ProcessInfo{{Name: "Firefox ×14", CPU: 30, MemoryBytes: 1 << 30, GPUMemoryBytes: 1 << 28}}, 80)
	narrow := renderProcessCard([]ProcessInfo{{Name: "Firefox ×14", CPU: 30, MemoryBytes: 1 << 30, GPUMemoryBytes: 1 << 28}}, 58)
	if strings.Contains(narrow.lines[0], "GPU") || !strings.Contains(narrow.lines[0], "Firefox") {
		t.Fatalf("narrow line = %q", narrow.lines[0])
	}
	without := renderProcessCard([]ProcessInfo{{Name: "Firefox ×14", CPU: 30, MemoryBytes: 1 << 30}}, 80)
	if !strings.Contains(with.lines[0], "GPU 256") || !strings.Contains(with.lines[0], "Firefox ×14") {
		t.Fatalf("line = %q", with.lines[0])
	}
	if strings.Contains(without.lines[0], "GPU") {
		t.Fatalf("line without GPU data = %q", without.lines[0])
	}
}
