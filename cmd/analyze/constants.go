package main

import "time"

const (
	maxEntries    = 30
	maxLargeFiles = 20
	barWidth      = 24
	// Below this many columns a scanned path is too clipped to tell anything
	// apart, so it moves to its own row instead of sharing the status line.
	scanPathInlineMinWidth = 24
	largeFileWarmupMinSize = 1 << 20
	defaultViewport        = 12
	fastWalkTimeout        = 5 * time.Minute
	maxConcurrentOverview  = 8
	batchUpdateSize        = 100

	// Worker pool limits, the same budget the macOS analyzer uses: every
	// blocked directory read holds an OS thread.
	minWorkers         = 2
	maxWorkers         = 12
	cpuMultiplier      = 1
	openCommandTimeout = 10 * time.Second
	scanSendTimeout    = 100 * time.Millisecond
	uiTickInterval     = 100 * time.Millisecond
)

// overviewPath is the model path of the overview screen. Windows has no single
// filesystem root above the home folder and the drives, so the overview gets a
// value no real path can take.
const overviewPath = "::overview"

var foldDirs = map[string]bool{
	// VCS.
	".git": true,
	".svn": true,
	".hg":  true,

	// JavaScript/Node.
	"node_modules":     true,
	".npm":             true,
	"npm-cache":        true,
	"_npx":             true,
	"_cacache":         true,
	"_logs":            true,
	".yarn":            true,
	".pnpm-store":      true,
	".next":            true,
	".nuxt":            true,
	"bower_components": true,
	".vite":            true,
	".turbo":           true,
	".parcel-cache":    true,
	".nx":              true,
	".rush":            true,
	".bun":             true,
	".deno":            true,

	// Python.
	"__pycache__":   true,
	".pytest_cache": true,
	".mypy_cache":   true,
	".ruff_cache":   true,
	"venv":          true,
	".venv":         true,
	"virtualenv":    true,
	".tox":          true,
	"site-packages": true,
	".eggs":         true,
	".pyenv":        true,
	".poetry":       true,
	".pip":          true,
	".pipx":         true,

	// Ruby/Go/PHP (vendor), Java/Kotlin/Scala/Rust (target).
	"vendor":    true,
	".bundle":   true,
	"gems":      true,
	"target":    true,
	".gradle":   true,
	".m2":       true,
	".ivy2":     true,
	"out":       true,
	"pkg":       true,
	".composer": true,
	".cargo":    true,
	".nuget":    true,

	// Build outputs.
	"build":     true,
	"dist":      true,
	".output":   true,
	"coverage":  true,
	".coverage": true,

	// IDE.
	".idea":   true,
	".vscode": true,
	".vs":     true,
	".fleet":  true,

	// Cache directories.
	".cache":       true,
	"$RECYCLE.BIN": true,
	".temp":        true,
	".tmp":         true,
	"_temp":        true,
	"_tmp":         true,
	".rustup":      true,
	".sdkman":      true,
	".nvm":         true,

	// Containers.
	".docker":     true,
	".containerd": true,

	// Mobile development.
	".dart_tool": true,

	// Web frameworks.
	".angular":    true,
	".svelte-kit": true,
	".astro":      true,
	".solid":      true,

	// Other.
	".terraform": true,
	".vagrant":   true,
	"tmp":        true,
	"temp":       true,
}

// skipSystemDirs are left out when a drive root is scanned: they are system
// owned, unreadable to a normal user, and never an Analyze cleanup surface.
var skipSystemDirs = map[string]bool{
	"System Volume Information": true,
	"$Recycle.Bin":              true,
	"Recovery":                  true,
	"Config.Msi":                true,
}

var skipExtensions = map[string]bool{
	".go":     true,
	".js":     true,
	".ts":     true,
	".tsx":    true,
	".jsx":    true,
	".json":   true,
	".md":     true,
	".txt":    true,
	".yml":    true,
	".yaml":   true,
	".xml":    true,
	".html":   true,
	".css":    true,
	".scss":   true,
	".sass":   true,
	".less":   true,
	".py":     true,
	".rb":     true,
	".java":   true,
	".kt":     true,
	".rs":     true,
	".swift":  true,
	".m":      true,
	".mm":     true,
	".c":      true,
	".cpp":    true,
	".h":      true,
	".hpp":    true,
	".cs":     true,
	".sql":    true,
	".db":     true,
	".lock":   true,
	".gradle": true,
	".mjs":    true,
	".cjs":    true,
	".coffee": true,
	".dart":   true,
	".svelte": true,
	".vue":    true,
	".nim":    true,
	".hx":     true,
}

// Match the shell spinner's centered 2x2 shape used by the macOS analyzer.
var spinnerFrames = []string{"⠖", "⠲", "⠴", "⠦"}

const (
	colorPurple     = "\033[0;35m"
	colorPurpleBold = "\033[1;35m"
	colorGray       = "\033[0;38;5;244m"
	colorRed        = "\033[0;31m"
	colorYellow     = "\033[0;33m"
	colorGreen      = "\033[0;32m"
	colorBlue       = "\033[0;34m"
	colorCyan       = "\033[0;36m"
	colorReset      = "\033[0m"
	colorBold       = "\033[1m"
)
