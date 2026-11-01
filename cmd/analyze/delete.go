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
}

// protectedSystemRoots are refused as the exact path only; ordinary
// directories below them (/var/tmp, a build under /var/lib) stay selectable.
var protectedSystemRoots = []string{"/", "/var"}

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
