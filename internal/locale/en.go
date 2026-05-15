package locale

// enMessages contains all English UI strings for the TUI components.
var enMessages = map[string]string{
	// ── Status TUI ──────────────────────────────────────────────────
	"status.title":        "Status",
	"status.health":       "Health",
	"status.loading":      "Loading...",
	"status.error":        "ERROR",

	// CPU
	"cpu.title":           "CPU",
	"cpu.total":           "Total",
	"cpu.load":            "Load",
	"cpu.core":            "Core",
	"cpu.per_core_na":     "Per-core data unavailable, using averaged load",
	"cpu.cores":           "cores",

	// Memory
	"memory.title":        "Memory",
	"memory.used":         "Used",
	"memory.free":         "Free",
	"memory.swap":         "Swap",
	"memory.total":        "Total",
	"memory.avail":        "Avail",
	"memory.cached":       "Cached",
	"memory.status":       "Status",

	// Disk
	"disk.title":          "Disk",
	"disk.read":           "Read",
	"disk.write":          "Write",
	"disk.trash":          "Trash",
	"disk.total":          "Total",
	"disk.used":           "used",
	"disk.free":           "free",
	"disk.collecting":     "Collecting...",
	"disk.no_disks":       "No disks detected",

	// Network
	"network.title":       "Network",
	"network.down":        "Down",
	"network.up":          "Up",
	"network.proxy":       "Proxy",

	// Battery / Power
	"power.title":         "Power",
	"power.level":         "Level",
	"power.health":        "Health",
	"power.input":         "Input",
	"power.no_battery":    "No battery",
	"power.unknown":       "Unknown",
	"power.ac":            "AC",
	"power.charged":       "Charged",
	"power.charging":      "Charging",
	"power.discharging":   "Discharging",
	"power.adapter":       "adapter",
	"power.max":           "max",
	"power.cycles":        "cycles",
	"power.battery":       "Battery",

	// Processes
	"process.title":       "Processes",
	"process.no_data":     "No data",

	// Health labels
	"health.excellent":    "Excellent",
	"health.good":         "Good",
	"health.fair":         "Fair",
	"health.poor":         "Poor",
	"health.critical":     "Critical",
	"health.high_cpu":     "High CPU",
	"health.high_mem":     "High Memory",
	"health.mem_pressure": "Memory Pressure",
	"health.crit_mem":     "Critical Memory",
	"health.disk_full":    "Disk Almost Full",
	"health.overheat":     "Overheating",
	"health.heavy_io":     "Heavy Disk IO",
	"health.bat_service":  "Battery Service Soon",
	"health.restart":      "Restart Recommended",

	// Battery health
	"bat.service_soon":    "Service Soon",
	"bat.fair":            "Fair",
	"bat.healthy":         "Healthy",

	// Alerts
	"alert.prefix":        "ALERT",
	"alert.more":          "+%d more",
	"alert.threshold":     "threshold",
	"alert.for":           "for",
	"alert.at":            "at",

	// ── Analyze TUI ─────────────────────────────────────────────────
	"analyze.title":       "Analyze Disk",
	"analyze.select":      "Select a location to explore:",
	"analyze.scanning":    "Scanning",
	"analyze.analyzing":   "Analyzing disk usage...",
	"analyze.deleting":    "Deleting:",
	"analyze.items":       "items",
	"analyze.removed":     "removed, please wait...",
	"analyze.files":       "files",
	"analyze.dirs":        "dirs",
	"analyze.empty_dir":   "Empty directory",
	"analyze.no_large":    "No large files found",
	"analyze.total":       "Total:",
	"analyze.pending":     "pending..",
	"analyze.free":        "free",

	// Analyze status messages
	"analyze.preparing":   "Preparing scan...",
	"analyze.checking":    "Checking system folders...",
	"analyze.ready":       "Ready",
	"analyze.refreshing":  "Refreshing...",
	"analyze.scan_failed": "Scan failed: %v",
	"analyze.del_failed":  "Failed to delete: %v",
	"analyze.deleted":     "Deleted %d items",
	"analyze.nothing":     "Nothing to delete",
	"analyze.cancelled":   "Cancelled",
	"analyze.del_items":   "Deleting %d items...",
	"analyze.del_single":  "Deleting %s...",
	"analyze.moving":      "Moving to Trash... %s items",
	"analyze.cached":      "Loaded cached data for %s, refreshing...",
	"analyze.scanned":     "Scanned %s",
	"analyze.scan_dir":    "Scanning %s..., %d left",
	"analyze.scan_dirs":   "Scanning %d directories..., %d left",
	"analyze.unable":      "Unable to measure %s: %v",
	"analyze.opening":     "Opening %s...",
	"analyze.open_items":  "Opening %d items...",
	"analyze.open_max":    "Too many items to open, max %d, selected %d",

	// Analyze delete confirmation
	"analyze.del_confirm_multi":  "Delete:",
	"analyze.del_confirm_single": "Delete:",
	"analyze.del_press":          "Press Enter to confirm  |  ESC cancel",

	// Analyze footer keybindings (kept compact)
	"analyze.keys_overview":      "↑↓←→ | Enter | R Refresh | O Open | P Preview | F File | Esc Back | Q/Ctrl+C Quit",
	"analyze.keys_overview_root": "↑↓→ | Enter | R Refresh | O Open | P Preview | F File | Esc/Q Quit",
	"analyze.keys_large":         "↑↓← | Space Select | R Refresh | O Open | P Preview | F File | ⌫ Del | Esc Back | Q/Ctrl+C Quit",
	"analyze.keys_large_sel":     "↑↓← | Space Select | R Refresh | O Open | P Preview | F File | ⌫ Del %d | Esc Back | Q/Ctrl+C Quit",
	"analyze.keys_dir":           "↑↓←→ | Space Select | Enter | R Refresh | O Open | P Preview | F File | ⌫ Del | Esc Back | Q/Ctrl+C Quit",
	"analyze.keys_dir_sel":       "↑↓←→ | Space Select | Enter | R Refresh | O Open | P Preview | F File | ⌫ Del %d | Esc Back | Q/Ctrl+C Quit",
	"analyze.keys_dir_top":       "↑↓←→ | Space Select | Enter | R Refresh | O Open | P Preview | F File | ⌫ Del | T Top %d | Esc Back | Q/Ctrl+C Quit",
	"analyze.keys_dir_sel_top":   "↑↓←→ | Space Select | Enter | R Refresh | O Open | P Preview | F File | ⌫ Del %d | T Top %d | Esc Back | Q/Ctrl+C Quit",

	// Overview names
	"overview.home":           "Home",
	"overview.user_library":   "User Library",
	"overview.applications":   "Applications",
	"overview.system_library": "System Library",

	// Uptime
	"uptime.prefix": "up",
}
