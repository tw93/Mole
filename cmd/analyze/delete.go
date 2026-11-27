package main

import (
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync/atomic"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/tw93/mole/internal/xdgtrash"
	"golang.org/x/sys/unix"
)

func deletePathCmd(path string, counter *int64, audit *deleteAudit) tea.Cmd {
	return func() tea.Msg {
		audit.begin()
		count, err := trashPathWithProgress(path, counter)
		audit.record(path, err)
		audit.end()
		return deleteProgressMsg{
			done:       true,
			err:        err,
			count:      count,
			path:       path,
			logWarning: audit.warning(),
		}
	}
}

// deleteMultiplePathsCmd moves paths to Trash and aggregates results.
func deleteMultiplePathsCmd(paths []string, counter *int64, audit *deleteAudit) tea.Cmd {
	return func() tea.Msg {
		var totalCount int64
		var errors []string
		var removedPaths []string
		audit.begin()

		// Process deeper paths first to avoid parent/child conflicts.
		pathsToDelete := append([]string(nil), paths...)
		sort.Slice(pathsToDelete, func(i, j int) bool {
			return strings.Count(pathsToDelete[i], string(filepath.Separator)) > strings.Count(pathsToDelete[j], string(filepath.Separator))
		})

		for _, path := range pathsToDelete {
			count, err := trashPathWithProgress(path, counter)
			audit.record(path, err)
			totalCount += count
			if err != nil {
				if os.IsNotExist(err) {
					removedPaths = append(removedPaths, path)
					continue
				}
				errors = append(errors, err.Error())
				continue
			}
			removedPaths = append(removedPaths, path)
		}

		var resultErr error
		if len(errors) > 0 {
			resultErr = &multiDeleteError{errors: errors}
		}
		audit.end()

		return deleteProgressMsg{
			done:         true,
			err:          resultErr,
			count:        totalCount,
			path:         "",
			removedPaths: removedPaths,
			logWarning:   audit.warning(),
		}
	}
}

// multiDeleteError holds multiple deletion errors.
type multiDeleteError struct {
	errors []string
}

func (e *multiDeleteError) Error() string {
	if len(e.errors) == 1 {
		return e.errors[0]
	}
	return strings.Join(e.errors[:min(3, len(e.errors))], "; ")
}

// trashPathWithProgress moves one selected path to Trash and reports completion.
func trashPathWithProgress(root string, counter *int64) (int64, error) {
	// Verify path exists (use Lstat to handle broken symlinks).
	_, err := os.Lstat(root)
	if err != nil {
		return 0, err
	}

	// Trash moves one selected path as a unit. Recursively counting every file
	// first made large directory deletes appear hung before the move began.
	const count int64 = 1

	// Move through the freedesktop.org Trash.
	if err := moveToTrash(root); err != nil {
		return 0, err
	}
	if counter != nil {
		atomic.AddInt64(counter, count)
	}

	return count, nil
}

// moveToTrash moves a file or directory to the freedesktop.org Trash through
// the shared xdgtrash sink: the home Trash for items on the home filesystem,
// the volume's $topdir/.Trash-$uid for other filesystems, and a refusal rather
// than a copy-and-delete when neither is possible.
func moveToTrash(path string) error {
	// Validate raw input before Abs resolves ".." components away.
	if err := validateTrashTarget(path); err != nil {
		return err
	}

	absPath, err := filepath.Abs(path)
	if err != nil {
		return fmt.Errorf("failed to resolve path: %w", err)
	}

	// Validate resolved path as well (defense-in-depth).
	if err := validateTrashTarget(absPath); err != nil {
		return err
	}

	if _, err := xdgtrash.Move(absPath); err != nil {
		return fmt.Errorf("failed to move to Trash: %w", err)
	}
	return nil
}

func validateTrashTarget(path string) error {
	if err := validatePath(path); err != nil {
		return err
	}
	if isProtectedAnalyzeDeletePath(path) {
		return fmt.Errorf("protected path cannot be deleted: %s", path)
	}
	if resolvedPath, err := filepath.EvalSymlinks(path); err == nil && isProtectedAnalyzeDeletePath(resolvedPath) {
		return fmt.Errorf("protected path cannot be deleted: %s", path)
	}
	return nil
}

// protectedSystemTrees are never an Analyze cleanup surface: neither the
// directory nor anything inside it. Matching is by file identity, so /lib
// and /bin resolve to /usr/lib and /usr/bin on a merged-usr system.
var protectedSystemTrees = []string{
	"/bin", "/boot", "/dev", "/etc", "/lib", "/lib64", "/proc", "/root",
	"/run", "/sbin", "/sys", "/usr", "/nix/store", "/snap",
	"/var/lib", "/var/log", // package databases, service state, live logs
}

// protectedSystemRoots are refused as the exact path only; ordinary
// directories below them (/tmp/build, /var/tmp, /var/cache) stay selectable.
var protectedSystemRoots = []string{"/", "/tmp", "/var"}

// protectedHomeTrees are refused inside every account's home, relative to it.
var protectedHomeTrees = []string{
	filepath.Join(".cache", "doc"),               // Flatpak document portal
	filepath.Join(".local", "share", "keyrings"), // GNOME keyring
	".gnupg",
	".ssh",
}

func isProtectedAnalyzeDeletePath(path string) bool {
	if path == "" {
		return false
	}

	cleanPath := filepath.Clean(path)
	if isCriticalAnalyzeDeletePath(cleanPath) {
		return true
	}
	if isSessionSocketFolderPath(cleanPath) || isTempSocketPath(cleanPath) {
		return true
	}

	for _, trashRoot := range protectedTrashRoots() {
		if cleanPath == trashRoot || strings.HasPrefix(cleanPath, trashRoot+string(filepath.Separator)) ||
			isPathWithinExistingRoot(cleanPath, trashRoot) {
			return true
		}
	}
	// A volume Trash ($topdir/.Trash-$uid) is the same kind of place.
	trashName := fmt.Sprintf(".Trash-%d", os.Getuid())
	if slices.Contains(strings.Split(cleanPath, string(filepath.Separator)), trashName) {
		return true
	}

	for _, homeRoot := range protectedAnalyzeHomeRoots() {
		if cleanPath == homeRoot || isSameExistingPath(cleanPath, homeRoot) {
			return true
		}
		if isAnalyzeHeadHomeFolder(cleanPath, homeRoot) {
			return true
		}
		for _, rel := range protectedHomeTrees {
			tree := filepath.Join(homeRoot, rel)
			if cleanPath == tree || strings.HasPrefix(cleanPath, tree+string(filepath.Separator)) ||
				isPathWithinExistingRoot(cleanPath, tree) {
				return true
			}
		}
	}
	return false
}

// isSessionSocketFolderPath reports a folder in the temp directory that holds
// a login session's sockets, or anything inside one: tmux's server socket, the
// folder a hand-started ssh-agent makes, and the X11 and ICE socket folders.
// Moved to the Trash, tmux and the agent stay unreachable until they restart,
// and the folder holds nothing to reclaim. The rest of the temp directory
// stays the user's pick. Mole CLI (macOS) refuses the same session folders.
// The parent is /tmp or the user's $TMPDIR (where ssh-agent puts its folder
// when TMPDIR is set, as pam_tmpdir does), matched by name and by identity,
// so a link to either is caught too.
func isSessionSocketFolderPath(path string) bool {
	tempRoots, tempInfos := sessionTempRoots()
	for current := filepath.Clean(path); ; current = filepath.Dir(current) {
		parent := filepath.Dir(current)
		if parent == current {
			return false
		}
		if isSessionSocketFolderName(filepath.Base(current)) && isTempDir(parent, tempRoots, tempInfos) {
			return true
		}
	}
}

// sessionTempRoots names /tmp and a sane $TMPDIR, plus the identities a
// parent reached by another spelling is compared against.
func sessionTempRoots() ([]string, []os.FileInfo) {
	tempRoots := []string{"/tmp"}
	if userTemp, ok := sessionUserTempDir(); ok {
		tempRoots = append(tempRoots, userTemp)
	}
	var tempInfos []os.FileInfo
	for _, root := range tempRoots {
		if info, err := os.Stat(root); err == nil {
			tempInfos = append(tempInfos, info)
		}
	}
	return tempRoots, tempInfos
}

// tempSocketEntryLimit bounds the listing of one temp folder.
const tempSocketEntryLimit = 4096

// isTempSocketPath reports any socket in the temp directory, and any direct
// child folder of it whose own entries include a socket: a database server's
// .s.PGSQL.5432, a hand-started agent's (zellij keeps its sockets one level
// lower, so its folder is not one). Moving one breaks the
// session or the connection and frees nothing. The type is read with lstat,
// so a link to a socket is not one, and the listing opens the folder without
// following a link, stops at the first socket or after tempSocketEntryLimit
// entries, and an unreadable folder answers false, leaving the name rule of
// isSessionSocketFolderPath. Mole CLI (macOS) refuses the same.
func isTempSocketPath(path string) bool {
	tempRoots, tempInfos := sessionTempRoots()
	cleanPath := filepath.Clean(path)
	for current := cleanPath; ; current = filepath.Dir(current) {
		parent := filepath.Dir(current)
		if parent == current {
			return false
		}
		if !isTempDir(parent, tempRoots, tempInfos) {
			continue
		}
		if info, err := os.Lstat(cleanPath); err == nil && info.Mode()&os.ModeSocket != 0 {
			return true
		}
		return current == cleanPath && directoryHoldsSocket(cleanPath)
	}
}

func directoryHoldsSocket(path string) bool {
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return false
	}
	dir := os.NewFile(uintptr(fd), path)
	defer func() { _ = dir.Close() }()
	seen := 0
	for seen < tempSocketEntryLimit {
		entries, err := dir.ReadDir(256)
		for _, entry := range entries {
			if entry.Type()&os.ModeSocket != 0 {
				return true
			}
			seen++
			if seen >= tempSocketEntryLimit {
				return false
			}
		}
		if err != nil || len(entries) == 0 {
			return false
		}
	}
	return false
}

// sessionUserTempDir is $TMPDIR when it can be a temp directory: absolute, not
// / and not a home folder, so a TMPDIR pointed at $HOME does not turn the
// user's own ssh-* or tmux-* folders into refused ones.
func sessionUserTempDir() (string, bool) {
	dir := filepath.Clean(os.TempDir())
	if !filepath.IsAbs(dir) || dir == "/" {
		return "", false
	}
	for _, home := range protectedAnalyzeHomeRoots() {
		if dir == home || isSameExistingPath(dir, home) {
			return "", false
		}
	}
	return dir, true
}

func isTempDir(dir string, roots []string, infos []os.FileInfo) bool {
	if slices.Contains(roots, dir) {
		return true
	}
	if len(infos) == 0 {
		return false
	}
	dirInfo, err := os.Stat(dir)
	if err != nil {
		return false
	}
	for _, info := range infos {
		if os.SameFile(dirInfo, info) {
			return true
		}
	}
	return false
}

// isSessionSocketFolderName matches the names the owners actually create:
// tmux-<uid> and ssh- plus 10 or 12 random letters and digits (OpenSSH's
// mkdtemp template, older and current), so a tmux-3.5a source tree or an
// ssh-tutorial folder stays movable.
func isSessionSocketFolderName(name string) bool {
	switch {
	case name == ".X11-unix" || name == ".ICE-unix":
		return true
	case strings.HasPrefix(name, "tmux-"):
		return isAllDigits(name[len("tmux-"):])
	case strings.HasPrefix(name, "ssh-"):
		rest := name[len("ssh-"):]
		return (len(rest) == 10 || len(rest) == 12) && isAllAlnum(rest)
	}
	return false
}

func isAllDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func isAllAlnum(s string) bool {
	for _, r := range s {
		if (r < '0' || r > '9') && (r < 'a' || r > 'z') && (r < 'A' || r > 'Z') {
			return false
		}
	}
	return s != ""
}

func isCriticalAnalyzeDeletePath(path string) bool {
	for _, root := range protectedSystemRoots {
		if path == root || isSameExistingPath(path, root) {
			return true
		}
	}
	// A child directly under /home is another account's home root, not an
	// ordinary directory. Protect every account root while keeping its
	// descendants available to the owning user.
	if isDirectChildOfExistingRoot(path, "/home") {
		return true
	}
	if isMountPointPath(path) {
		return true
	}
	for _, root := range protectedSystemTrees {
		if path == root || strings.HasPrefix(path, root+string(filepath.Separator)) ||
			isPathWithinExistingRoot(path, root) {
			return true
		}
	}
	return false
}

// analyzeHeadHomeFolders are the XDG base directories and the folders
// xdg-user-dirs creates in a home. Moving one whole breaks every app that keeps
// state there, so analyze refuses the folder itself and keeps what is inside it
// deletable, the head-of-the-tree rule Mole CLI (macOS) follows (tw93/Mole
// d3d162a9). Localized user folders come from user-dirs.dirs.
var analyzeHeadHomeFolders = []string{
	".cache", ".config", ".local", filepath.Join(".local", "bin"), filepath.Join(".local", "share"),
	filepath.Join(".local", "state"), ".var", filepath.Join(".var", "app"),
	"Desktop", "Documents", "Downloads", "Music", "Pictures", "Public", "Templates", "Videos",
}

func isAnalyzeHeadHomeFolder(path, homeRoot string) bool {
	for _, folder := range analyzeHeadFolderPaths(homeRoot) {
		if path == folder || isSameExistingPath(path, folder) {
			return true
		}
	}
	return false
}

func analyzeHeadFolderPaths(homeRoot string) []string {
	folders := make([]string, 0, len(analyzeHeadHomeFolders)+12)
	for _, rel := range analyzeHeadHomeFolders {
		folders = append(folders, filepath.Join(homeRoot, rel))
	}
	configHome := filepath.Join(homeRoot, ".config")
	for _, name := range []string{"XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME"} {
		if dir := os.Getenv(name); filepath.IsAbs(dir) {
			folders = append(folders, filepath.Clean(dir))
			if name == "XDG_CONFIG_HOME" {
				configHome = filepath.Clean(dir)
			}
		}
	}
	if data, err := os.ReadFile(filepath.Join(configHome, "user-dirs.dirs")); err == nil {
		folders = append(folders, parseXDGUserDirs(string(data), homeRoot)...)
	}
	return folders
}

// parseXDGUserDirs reads the XDG_*_DIR="$HOME/Name" or "/abs/path" lines
// xdg-user-dirs-update writes. A folder set to the home itself (how a user
// disables one) is skipped, since the home has its own refusal.
func parseXDGUserDirs(data, homeRoot string) []string {
	var dirs []string
	for _, line := range strings.Split(data, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "#") || !strings.HasPrefix(line, "XDG_") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok || !strings.HasSuffix(key, "_DIR") {
			continue
		}
		value = strings.Trim(value, "\"")
		switch {
		case value == "$HOME" || value == "$HOME/":
			continue
		case strings.HasPrefix(value, "$HOME/"):
			value = filepath.Join(homeRoot, strings.TrimPrefix(value, "$HOME/"))
		case filepath.IsAbs(value):
			value = filepath.Clean(value)
		default:
			continue
		}
		if value != homeRoot {
			dirs = append(dirs, value)
		}
	}
	return dirs
}

func isDirectChildOfExistingRoot(path, protectedRoot string) bool {
	cleanPath := filepath.Clean(path)
	return cleanPath != filepath.Clean(protectedRoot) &&
		filepath.Dir(cleanPath) != cleanPath &&
		isSameExistingPath(filepath.Dir(cleanPath), protectedRoot)
}

// isMountPointPath reports whether path is exactly a mount point in the live
// mount table. Moving one to the Trash would fail at best and hide a whole
// filesystem at worst.
func isMountPointPath(path string) bool {
	data, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		return false
	}
	return mountTableHasMountPoint(string(data), path)
}

func mountTableHasMountPoint(mountinfo, path string) bool {
	for _, mount := range parseMountInfo(mountinfo) {
		if mount.Mountpoint == path {
			return true
		}
	}
	return false
}

// protectedTrashRoots lists the home Trash directory, as XDG_DATA_HOME or the
// default location names it.
func protectedTrashRoots() []string {
	env, err := xdgtrash.DefaultEnv()
	if err != nil {
		return nil
	}
	return []string{env.HomeTrash()}
}

func protectedAnalyzeHomeRoots() []string {
	var homeRoots []string
	seenHomeRoots := make(map[string]bool)
	addHomeRoot := func(home string) {
		if home == "" {
			return
		}
		cleanHome := filepath.Clean(home)
		if !seenHomeRoots[cleanHome] {
			homeRoots = append(homeRoots, cleanHome)
			seenHomeRoots[cleanHome] = true
		}
		if resolvedHome, err := filepath.EvalSymlinks(cleanHome); err == nil && !seenHomeRoots[resolvedHome] {
			homeRoots = append(homeRoots, resolvedHome)
			seenHomeRoots[resolvedHome] = true
		}
	}

	addHomeRoot(os.Getenv("HOME"))
	if currentUser, err := user.Current(); err == nil {
		addHomeRoot(currentUser.HomeDir)
	}
	return homeRoots
}

func isPathWithinExistingRoot(path, protectedRoot string) bool {
	protectedInfo, err := os.Stat(protectedRoot)
	if err != nil {
		return false
	}

	for current := filepath.Clean(path); ; current = filepath.Dir(current) {
		if currentInfo, err := os.Stat(current); err == nil && os.SameFile(currentInfo, protectedInfo) {
			return true
		}
		parent := filepath.Dir(current)
		if parent == current {
			return false
		}
	}
}

func isSameExistingPath(path, protectedPath string) bool {
	pathInfo, pathErr := os.Stat(path)
	protectedInfo, protectedErr := os.Stat(protectedPath)
	return pathErr == nil && protectedErr == nil && os.SameFile(pathInfo, protectedInfo)
}

// validatePath checks path safety for external commands.
// Returns error if path is empty, relative, contains null bytes, or has traversal.
func validatePath(path string) error {
	if path == "" {
		return fmt.Errorf("path is empty")
	}
	if !filepath.IsAbs(path) {
		return fmt.Errorf("path must be absolute: %s", path)
	}
	if strings.Contains(path, "\x00") {
		return fmt.Errorf("path contains null bytes")
	}
	// Check for path traversal attempts (.. components).
	if slices.Contains(strings.Split(path, string(filepath.Separator)), "..") {
		return fmt.Errorf("path contains traversal components: %s", path)
	}
	return nil
}
