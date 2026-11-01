//go:build linux

// Package xdgtrash moves files into the freedesktop.org Trash. It is the only
// place Mole CLI (Linux) moves user files away: clean, uninstall and analyze
// all end here, so the rules live once.
//
// Rules (Trash spec 1.0, plus Mole's own fail-closed choices):
//   - The .trashinfo file is created with O_EXCL before the move, so the name
//     is reserved and two writers never share it.
//   - Path= is percent-encoded; home Trash stores absolute paths, a volume
//     Trash stores paths relative to its top directory.
//   - Items on the home filesystem go to $XDG_DATA_HOME/Trash. Items on
//     another filesystem go to that filesystem's $topdir/.Trash-$uid. Nothing
//     is ever copied across devices and then deleted: a cross-device rename
//     fails and the item stays where it is.
//   - A failed move removes the reserved .trashinfo again.
package xdgtrash

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// Result describes one completed move.
type Result struct {
	Source    string // absolute path the item had
	TrashFile string // where it now lives (…/Trash/files/<name>)
	TrashInfo string // its .trashinfo
}

// Env lets tests point the home Trash elsewhere and fix the clock.
type Env struct {
	Home        string
	DataHome    string // $XDG_DATA_HOME; empty means Home/.local/share
	UID         int
	Now         func() time.Time
	noReplaceOK bool // set after the first EINVAL to skip renameat2
}

// DefaultEnv reads HOME, XDG_DATA_HOME and the real uid.
func DefaultEnv() (*Env, error) {
	home, err := os.UserHomeDir()
	if err != nil || !filepath.IsAbs(home) {
		return nil, fmt.Errorf("home directory is unknown")
	}
	data := os.Getenv("XDG_DATA_HOME")
	if !filepath.IsAbs(data) {
		data = ""
	}
	return &Env{Home: filepath.Clean(home), DataHome: data, UID: os.Getuid(), Now: time.Now}, nil
}

// Move trashes one path with the default environment.
func Move(path string) (Result, error) {
	env, err := DefaultEnv()
	if err != nil {
		return Result{}, err
	}
	return env.Move(path)
}

// HomeTrash returns the home Trash directory ($XDG_DATA_HOME/Trash).
func (e *Env) HomeTrash() string {
	data := e.DataHome
	if data == "" {
		data = filepath.Join(e.Home, ".local", "share")
	}
	return filepath.Join(data, "Trash")
}

// Move trashes path. The item itself is moved, never what a symlink points to.
func (e *Env) Move(path string) (Result, error) {
	if path == "" {
		return Result{}, errors.New("empty path")
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return Result{}, err
	}
	abs = filepath.Clean(abs)
	if abs == "/" || abs == e.Home {
		return Result{}, fmt.Errorf("refusing to trash %s", abs)
	}

	var st unix.Stat_t
	if err := unix.Lstat(abs, &st); err != nil {
		return Result{}, err
	}

	home := e.HomeTrash()
	if abs == home || strings.HasPrefix(abs+"/", home+"/") || strings.HasPrefix(home+"/", abs+"/") {
		return Result{}, fmt.Errorf("refusing to trash the Trash itself or a folder holding it: %s", abs)
	}

	trashDir, topdir, err := e.trashFor(abs, st.Dev)
	if err != nil {
		return Result{}, err
	}
	if strings.HasPrefix(trashDir+"/", abs+"/") {
		return Result{}, fmt.Errorf("refusing to trash a folder holding a Trash: %s", abs)
	}

	filesDir := filepath.Join(trashDir, "files")
	infoDir := filepath.Join(trashDir, "info")
	for _, d := range []string{trashDir, filesDir, infoDir} {
		if err := e.ensureOwnedDir(d); err != nil {
			return Result{}, err
		}
	}

	stored := abs
	if topdir != "" {
		rel, err := filepath.Rel(topdir, abs)
		if err != nil || rel == "." || strings.HasPrefix(rel, "..") {
			return Result{}, fmt.Errorf("item is outside its volume: %s", abs)
		}
		stored = rel
	}

	now := time.Now
	if e.Now != nil {
		now = e.Now
	}
	body := "[Trash Info]\nPath=" + EncodePath(stored) + "\nDeletionDate=" + now().Format("2006-01-02T15:04:05") + "\n"

	name, infoPath, err := reserveInfo(infoDir, filesDir, filepath.Base(abs), body)
	if err != nil {
		return Result{}, err
	}
	dest := filepath.Join(filesDir, name)
	if err := e.rename(abs, dest); err != nil {
		_ = os.Remove(infoPath)
		if errors.Is(err, unix.EXDEV) {
			return Result{}, fmt.Errorf("%s is on another filesystem than its Trash; left in place", abs)
		}
		return Result{}, err
	}
	return Result{Source: abs, TrashFile: dest, TrashInfo: infoPath}, nil
}

// trashFor picks the home Trash when abs shares its device, else the volume's
// $topdir/.Trash-$uid. topdir is empty for the home Trash.
func (e *Env) trashFor(abs string, dev uint64) (trashDir, topdir string, err error) {
	home := e.HomeTrash()
	if hdev, ok := deviceOf(nearestExisting(home)); ok && hdev == dev {
		return home, "", nil
	}
	top := topDirectory(abs, dev)
	if top == "" || top == "/" {
		return "", "", fmt.Errorf("no Trash on the filesystem holding %s", abs)
	}
	return filepath.Join(top, fmt.Sprintf(".Trash-%d", e.UID)), top, nil
}

// topDirectory walks up from abs while the parent stays on the same device and
// returns the highest such directory: the mount point (or btrfs subvolume root).
func topDirectory(abs string, dev uint64) string {
	cur := filepath.Dir(abs)
	if d, ok := deviceOf(cur); !ok || d != dev {
		return ""
	}
	for i := 0; i < 4096; i++ {
		parent := filepath.Dir(cur)
		if parent == cur {
			return cur
		}
		d, ok := deviceOf(parent)
		if !ok || d != dev {
			return cur
		}
		cur = parent
	}
	return ""
}

func deviceOf(path string) (uint64, bool) {
	var st unix.Stat_t
	if err := unix.Stat(path, &st); err != nil {
		return 0, false
	}
	return st.Dev, true
}

func nearestExisting(path string) string {
	for i := 0; i < 4096; i++ {
		if _, err := os.Lstat(path); err == nil {
			return path
		}
		parent := filepath.Dir(path)
		if parent == path {
			return path
		}
		path = parent
	}
	return path
}

// ensureOwnedDir creates dir with 0700 when missing and refuses one that is a
// symlink, not a directory, owned by someone else or writable by others.
func (e *Env) ensureOwnedDir(dir string) error {
	info, err := os.Lstat(dir)
	if os.IsNotExist(err) {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return fmt.Errorf("cannot create Trash directory %s: %w", dir, err)
		}
		info, err = os.Lstat(dir)
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return fmt.Errorf("Trash path is not a normal directory: %s", dir)
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(st.Uid) != e.UID {
		return fmt.Errorf("Trash directory is not owned by you: %s", dir)
	}
	if info.Mode().Perm()&0o022 != 0 {
		return fmt.Errorf("Trash directory is writable by others: %s", dir)
	}
	return nil
}

// reserveInfo creates <name>.trashinfo with O_EXCL, trying name, name.2, …
// reserveInfo claims the first free name: no info file and no item in files/
// (a stray item left without its info file would otherwise block the name).
func reserveInfo(infoDir, filesDir, base, body string) (string, string, error) {
	if base == "" || base == "." || base == "/" || base == ".." {
		return "", "", fmt.Errorf("invalid item name %q", base)
	}
	for i := 1; i <= 1000; i++ {
		name := base
		if i > 1 {
			name = fmt.Sprintf("%s.%d", base, i)
		}
		if _, err := os.Lstat(filepath.Join(filesDir, name)); err == nil {
			continue
		}
		infoPath := filepath.Join(infoDir, name+".trashinfo")
		f, err := os.OpenFile(infoPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if errors.Is(err, os.ErrExist) {
			continue
		}
		if err != nil {
			return "", "", fmt.Errorf("cannot write Trash info: %w", err)
		}
		_, werr := f.WriteString(body)
		serr := f.Sync()
		cerr := f.Close()
		if werr != nil || serr != nil || cerr != nil {
			_ = os.Remove(infoPath)
			return "", "", fmt.Errorf("cannot write Trash info for %s", base)
		}
		return name, infoPath, nil
	}
	return "", "", fmt.Errorf("no free Trash name for %s", base)
}

// rename never replaces an existing destination: renameat2(RENAME_NOREPLACE)
// where the filesystem supports it, else a checked plain rename.
func (e *Env) rename(src, dst string) error {
	if !e.noReplaceOK {
		err := unix.Renameat2(unix.AT_FDCWD, src, unix.AT_FDCWD, dst, unix.RENAME_NOREPLACE)
		if err == nil {
			return nil
		}
		if !errors.Is(err, unix.EINVAL) && !errors.Is(err, unix.ENOSYS) {
			return err
		}
		e.noReplaceOK = true
	}
	if _, err := os.Lstat(dst); err == nil {
		return fmt.Errorf("Trash destination already exists: %s", dst)
	}
	return os.Rename(src, dst)
}

// EncodePath percent-encodes a path for Path= (RFC 3986 unreserved and '/' stay).
func EncodePath(p string) string {
	const hex = "0123456789ABCDEF"
	var b strings.Builder
	for i := 0; i < len(p); i++ {
		c := p[i]
		switch {
		case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z', c >= '0' && c <= '9',
			c == '-', c == '.', c == '_', c == '~', c == '/':
			b.WriteByte(c)
		default:
			b.WriteByte('%')
			b.WriteByte(hex[c>>4])
			b.WriteByte(hex[c&15])
		}
	}
	return b.String()
}
