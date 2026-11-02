package main

import (
	"bufio"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// AppInfo is one row of the process card: every process of one desktop app
// summed (Kind "app"), or a single process that belongs to no app cgroup (Kind
// "process"), so the list never hides a process behind a missing group.
type AppInfo struct {
	Name           string  `json:"name"`
	ID             string  `json:"id,omitempty"` // application id from the cgroup, e.g. org.mozilla.firefox
	Kind           string  `json:"kind"`         // "app" or "process"
	PID            int     `json:"pid,omitempty"`
	Processes      int     `json:"processes"`
	CPU            float64 `json:"cpu"`    // percent of one core, summed
	Memory         float64 `json:"memory"` // percent of physical memory, summed
	MemoryBytes    uint64  `json:"memory_bytes,omitempty"`
	GPUMemoryBytes uint64  `json:"gpu_memory_bytes,omitempty"`
}

const (
	appKindApp     = "app"
	appKindProcess = "process"
	topAppRows     = 5
)

// parseAppCgroup returns the application id and the launcher from the content
// of /proc/<pid>/cgroup, or "" when no path component is an app unit.
//
// systemd's XDG cgroup convention (the one uwsm, Hyprland's exec, systemd-run
// launchers and Flatpak follow) names units
//
//	app[-<launcher>]-<ApplicationID>[@<RANDOM>].service
//	app[-<launcher>]-<ApplicationID>-<RANDOM>.scope
//
// with "-" inside an id written as \x2d. Flatpak uses
// app-flatpak-<appid>-<pid>.scope. The first matching component wins, so a
// scope nested under an app service still belongs to the app.
func parseAppCgroup(raw string) (id, launcher string) {
	for line := range strings.Lines(raw) {
		// Cgroup v2 is "0::/path"; v1 lines are "N:controllers:/path". Only the
		// unified or the systemd hierarchy carries unit names.
		parts := strings.SplitN(strings.TrimSpace(line), ":", 3)
		if len(parts) != 3 {
			continue
		}
		for _, comp := range strings.Split(parts[2], "/") {
			if id, launcher, ok := parseAppUnit(comp); ok {
				return id, launcher
			}
		}
	}
	return "", ""
}

func parseAppUnit(unit string) (id, launcher string, ok bool) {
	var body string
	scope := false
	switch {
	case strings.HasSuffix(unit, ".scope"):
		body, scope = strings.TrimSuffix(unit, ".scope"), true
	case strings.HasSuffix(unit, ".service"):
		body = strings.TrimSuffix(unit, ".service")
	default:
		return "", "", false
	}
	body, found := strings.CutPrefix(body, "app-")
	if !found || body == "" {
		return "", "", false
	}
	if at := strings.IndexByte(body, '@'); at >= 0 {
		body = body[:at]
	} else if scope {
		if dash := strings.LastIndexByte(body, '-'); dash > 0 {
			body = body[:dash] // drop the random suffix
		}
	}
	if body == "" {
		return "", "", false
	}
	// First unescaped "-" separates launcher from id; ids carry \x2d instead.
	if dash := strings.IndexByte(body, '-'); dash > 0 && dash < len(body)-1 {
		launcher, body = body[:dash], body[dash+1:]
	}
	id = unescapeUnitName(body)
	if id == "" {
		return "", "", false
	}
	return id, unescapeUnitName(launcher), true
}

// unescapeUnitName decodes systemd's \xNN escapes.
func unescapeUnitName(s string) string {
	if !strings.Contains(s, `\x`) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+3 < len(s) && s[i+1] == 'x' {
			if v, err := strconv.ParseUint(s[i+2:i+4], 16, 8); err == nil {
				b.WriteByte(byte(v))
				i += 3
				continue
			}
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

// readAppID reads one process's app id; "" when it has none or the file is
// unreadable (another user's process, a process that just exited).
func readAppID(procDir string) string {
	data, err := os.ReadFile(filepath.Join(procDir, "cgroup"))
	if err != nil {
		return ""
	}
	id, _ := parseAppCgroup(string(data))
	return id
}

// desktopNames caches Name= by application id for the life of the process:
// launchers rarely change, and only the few ids on screen are ever looked up.
var desktopNames = struct {
	sync.Mutex
	m map[string]string
}{m: map[string]string{}}

// appDesktopDirs lists the applications directories a launcher id can live in.
func appDesktopDirs() []string {
	var dirs []string
	home := os.Getenv("XDG_DATA_HOME")
	if home == "" {
		if h, err := os.UserHomeDir(); err == nil {
			home = filepath.Join(h, ".local/share")
		}
	}
	if home != "" {
		dirs = append(dirs, filepath.Join(home, "applications"), filepath.Join(home, "flatpak/exports/share/applications"))
	}
	data := os.Getenv("XDG_DATA_DIRS")
	if data == "" {
		data = "/usr/local/share:/usr/share"
	}
	for _, d := range strings.Split(data, ":") {
		if d != "" {
			dirs = append(dirs, filepath.Join(d, "applications"))
		}
	}
	return append(dirs, "/var/lib/flatpak/exports/share/applications")
}

// desktopName returns the Name= of <id>.desktop from the first directory that
// has one, or "" so the caller shows the id. Only the [Desktop Entry] group is
// read and the unlocalized Name wins, so the label does not depend on locale.
func desktopName(id string, dirs []string) string {
	if id == "" || strings.ContainsAny(id, "/\x00") {
		return ""
	}
	desktopNames.Lock()
	cacheKey := id + "\x00" + strings.Join(dirs, ":")
	if name, ok := desktopNames.m[cacheKey]; ok {
		desktopNames.Unlock()
		return name
	}
	desktopNames.Unlock()

	name := ""
	for _, dir := range dirs {
		if n, ok := readDesktopName(filepath.Join(dir, id+".desktop")); ok {
			name = n
			break
		}
	}
	desktopNames.Lock()
	desktopNames.m[cacheKey] = name
	desktopNames.Unlock()
	return name
}

func readDesktopName(path string) (string, bool) {
	f, err := os.Open(path)
	if err != nil {
		return "", false
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	inEntry := false
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if strings.HasPrefix(line, "[") {
			inEntry = line == "[Desktop Entry]"
			continue
		}
		if !inEntry {
			continue
		}
		if v, ok := strings.CutPrefix(line, "Name="); ok {
			v = strings.TrimSpace(v)
			return v, v != ""
		}
	}
	return "", false
}

// groupProcesses folds the process table into rows: one per app id, one per
// ungrouped process. CPU and memory are plain sums, so a browser's shared
// pages count once per process (the same convention as RSS in the per-process
// list), and the rows rank by CPU then memory like the process list did.
func groupProcesses(procs []ProcessInfo) []AppInfo {
	byApp := make(map[string]*AppInfo)
	var rows []AppInfo
	for _, p := range procs {
		if p.AppID == "" {
			rows = append(rows, AppInfo{
				Name: p.Name, Kind: appKindProcess, PID: p.PID, Processes: 1,
				CPU: p.CPU, Memory: p.Memory, MemoryBytes: p.MemoryBytes,
				GPUMemoryBytes: p.GPUMemoryBytes,
			})
			continue
		}
		a := byApp[p.AppID]
		if a == nil {
			a = &AppInfo{Name: p.AppID, ID: p.AppID, Kind: appKindApp}
			byApp[p.AppID] = a
		}
		a.Processes++
		a.CPU += p.CPU
		a.Memory += p.Memory
		a.MemoryBytes += p.MemoryBytes
		a.GPUMemoryBytes += p.GPUMemoryBytes
	}
	for _, a := range byApp {
		rows = append(rows, *a)
	}
	sort.Slice(rows, func(i, j int) bool {
		a, b := rows[i], rows[j]
		if a.CPU != b.CPU {
			return a.CPU > b.CPU
		}
		if a.Memory != b.Memory {
			return a.Memory > b.Memory
		}
		if a.Name != b.Name {
			return a.Name < b.Name
		}
		return a.PID < b.PID
	})
	return rows
}

// topApps returns the busiest limit rows with display names resolved. The
// .desktop lookup runs for those rows only, never for the whole table.
func topApps(procs []ProcessInfo, limit int, dirs []string) []AppInfo {
	rows := groupProcesses(procs)
	if limit > 0 && len(rows) > limit {
		rows = rows[:limit]
	}
	for i := range rows {
		if rows[i].Kind == appKindApp {
			if n := desktopName(rows[i].ID, dirs); n != "" {
				rows[i].Name = n
			}
		}
	}
	return rows
}

// buildTopApps is the one call the collector makes per process sample: group,
// measure GPU memory for the rows on screen, then name them.
func buildTopApps(root string, procs []ProcessInfo, now time.Time) []AppInfo {
	if root != "" {
		rows := groupProcesses(procs)
		if len(rows) > topAppRows {
			rows = rows[:topAppRows]
		}
		attachGPUMemory(root, procs, rows, now)
	}
	return topApps(procs, topAppRows, appDesktopDirs())
}
