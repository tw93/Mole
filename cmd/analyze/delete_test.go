package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// isolateTrash points HOME and XDG_DATA_HOME at a temp directory so a test's
// Trash move never touches the real Trash.
func isolateTrash(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_DATA_HOME", filepath.Join(home, ".local", "share"))
	return home
}

func TestTrashPathWithProgress(t *testing.T) {
	isolateTrash(t)

	parent := t.TempDir()
	target := filepath.Join(parent, "target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}

	files := []string{
		filepath.Join(target, "one.txt"),
		filepath.Join(target, "two.txt"),
	}
	for _, f := range files {
		if err := os.WriteFile(f, []byte("content"), 0o644); err != nil {
			t.Fatalf("write %s: %v", f, err)
		}
	}

	var counter int64
	count, err := trashPathWithProgress(target, &counter)
	if err != nil {
		t.Fatalf("trashPathWithProgress returned error: %v", err)
	}
	if count != 1 {
		t.Fatalf("expected one path-level Trash operation, got %d", count)
	}
	if counter != 1 {
		t.Fatalf("expected one completed Trash operation, got %d", counter)
	}
	if _, err := os.Stat(target); !os.IsNotExist(err) {
		t.Fatalf("expected target to be moved to Trash, stat err=%v", err)
	}
}

func TestDeleteMultiplePathsCmdHandlesParentChild(t *testing.T) {
	isolateTrash(t)

	base := t.TempDir()
	parent := filepath.Join(base, "parent")
	child := filepath.Join(parent, "child")

	// Structure: parent/fileA, parent/child/fileC.
	if err := os.MkdirAll(child, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(parent, "fileA"), []byte("a"), 0o644); err != nil {
		t.Fatalf("write fileA: %v", err)
	}
	if err := os.WriteFile(filepath.Join(child, "fileC"), []byte("c"), 0o644); err != nil {
		t.Fatalf("write fileC: %v", err)
	}

	var counter int64
	msg := deleteMultiplePathsCmd([]string{parent, child}, &counter, nil)()
	progress, ok := msg.(deleteProgressMsg)
	if !ok {
		t.Fatalf("expected deleteProgressMsg, got %T", msg)
	}
	if progress.err != nil {
		t.Fatalf("unexpected error: %v", progress.err)
	}
	if progress.count != 2 {
		t.Fatalf("expected 2 paths trashed, got %d", progress.count)
	}
	if counter != 2 {
		t.Fatalf("expected two completed Trash operations, got %d", counter)
	}
	if _, err := os.Stat(parent); !os.IsNotExist(err) {
		t.Fatalf("expected parent to be moved to Trash, err=%v", err)
	}
}

func TestMoveToTrashNonExistent(t *testing.T) {
	err := moveToTrash("/nonexistent/path/that/does/not/exist")
	if err == nil {
		t.Fatal("expected error for non-existent path")
	}
}

func TestMoveToTrashRejectsTraversal(t *testing.T) {
	// Verify the full production path rejects ".." before filepath.Abs resolves it.
	err := moveToTrash("/tmp/fakedir/../../../etc/passwd")
	if err == nil {
		t.Fatal("expected error for path with traversal components")
	}
	if !strings.Contains(err.Error(), "traversal") {
		t.Fatalf("expected traversal error, got: %v", err)
	}
}

func TestMoveToTrashWritesTrashInfoInXDGTrash(t *testing.T) {
	home := isolateTrash(t)
	target := filepath.Join(t.TempDir(), "item.txt")
	if err := os.WriteFile(target, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := moveToTrash(target); err != nil {
		t.Fatalf("moveToTrash: %v", err)
	}
	trash := filepath.Join(home, ".local", "share", "Trash")
	if _, err := os.Stat(filepath.Join(trash, "files", "item.txt")); err != nil {
		t.Fatalf("item missing from Trash/files: %v", err)
	}
	info, err := os.ReadFile(filepath.Join(trash, "info", "item.txt.trashinfo"))
	if err != nil {
		t.Fatalf("trashinfo missing: %v", err)
	}
	if !strings.Contains(string(info), "[Trash Info]") || !strings.Contains(string(info), "Path=") {
		t.Fatalf("unexpected trashinfo: %q", info)
	}
}

func TestValidateTrashTargetRejectsLinuxSystemPaths(t *testing.T) {
	isolateTrash(t)
	rejected := []string{
		"/", "/bin", "/boot", "/dev", "/etc", "/lib", "/lib64", "/proc", "/root",
		"/run", "/sbin", "/sys", "/usr", "/var", "/nix/store", "/snap",
		"/usr/bin/env", "/etc/passwd", "/boot/vmlinuz", "/proc/self",
	}
	for _, path := range rejected {
		// Paths absent on this machine cannot be matched by identity, so only
		// assert the ones that exist or are protected by name.
		if err := validateTrashTarget(path); err == nil {
			t.Errorf("validateTrashTarget(%q) = nil, want protected path error", path)
		}
	}
}

func TestValidateTrashTargetAllowsChildrenOfVar(t *testing.T) {
	isolateTrash(t)
	for _, path := range []string{"/var/tmp/build-output", "/var/cache/example/item", "/opt/example", "/tmp/example"} {
		if err := validateTrashTarget(path); err != nil {
			t.Errorf("validateTrashTarget(%q) error = %v, want nil", path, err)
		}
	}
}

func TestValidateTrashTargetRejectsHomeAndSensitiveHomeTrees(t *testing.T) {
	home := isolateTrash(t)
	rejected := []string{
		home,
		filepath.Join(home, ".local", "share", "Trash"),
		filepath.Join(home, ".local", "share", "Trash", "files", "old.txt"),
		filepath.Join(home, ".cache", "doc"),
		filepath.Join(home, ".cache", "doc", "abc", "file.txt"),
		filepath.Join(home, ".local", "share", "keyrings"),
		filepath.Join(home, ".local", "share", "keyrings", "login.keyring"),
		filepath.Join(home, ".gnupg"),
		filepath.Join(home, ".gnupg", "private-keys-v1.d", "key.key"),
		filepath.Join(home, ".ssh"),
		filepath.Join(home, ".ssh", "id_ed25519"),
	}
	for _, path := range rejected {
		if err := validateTrashTarget(path); err == nil {
			t.Errorf("validateTrashTarget(%q) = nil, want protected path error", path)
		}
	}
}

func TestValidateTrashTargetHonorsXDGDataHomeTrash(t *testing.T) {
	home := t.TempDir()
	data := filepath.Join(t.TempDir(), "data")
	t.Setenv("HOME", home)
	t.Setenv("XDG_DATA_HOME", data)
	if err := validateTrashTarget(filepath.Join(data, "Trash", "files", "x")); err == nil {
		t.Fatal("custom XDG Trash must be protected")
	}
}

func TestValidateTrashTargetRejectsVolumeTrash(t *testing.T) {
	isolateTrash(t)
	path := filepath.Join("/mnt/disk", ".Trash-"+strconv.Itoa(os.Getuid()), "files", "x")
	if err := validateTrashTarget(path); err == nil {
		t.Fatalf("validateTrashTarget(%q) = nil, want protected", path)
	}
}

func TestValidateTrashTargetAllowsRegularUserPaths(t *testing.T) {
	home := isolateTrash(t)
	for _, path := range []string{
		filepath.Join(home, "Downloads", "old.zip"),
		filepath.Join(home, ".cache", "pip", "wheels"),
		filepath.Join(home, ".cache", "mole", "x"),
		filepath.Join(home, ".local", "share", "mise", "installs"),
		filepath.Join(home, "project", "node_modules"),
		filepath.Join(home, ".config", "ssh-notes"),
	} {
		if err := validateTrashTarget(path); err != nil {
			t.Errorf("validateTrashTarget(%q) error = %v, want nil", path, err)
		}
	}
}

func TestValidateTrashTargetRejectsSymlinkToProtectedRoot(t *testing.T) {
	home := isolateTrash(t)
	link := filepath.Join(home, "etc-link")
	if err := os.Symlink("/etc", link); err != nil {
		t.Skipf("symlink: %v", err)
	}
	if err := validateTrashTarget(link); err == nil {
		t.Fatal("symlink to /etc must be protected")
	}
}

func TestValidateTrashTargetRejectsOtherAccountHomeRoot(t *testing.T) {
	isolateTrash(t)
	entries, err := os.ReadDir("/home")
	if err != nil || len(entries) == 0 {
		t.Skip("no /home entries")
	}
	for _, e := range entries {
		if e.IsDir() {
			path := filepath.Join("/home", e.Name())
			if err := validateTrashTarget(path); err == nil {
				t.Errorf("validateTrashTarget(%q) = nil, want account root protected", path)
			}
		}
	}
}

func TestMountTableMountPointsAreExact(t *testing.T) {
	table := "36 1 8:2 / / rw - ext4 /dev/sda2 rw\n" +
		"37 36 8:3 / /mnt/data\\040disk rw - ext4 /dev/sda3 rw\n"
	if !mountTableHasMountPoint(table, "/mnt/data disk") {
		t.Fatal("escaped mount point not recognised")
	}
	if mountTableHasMountPoint(table, "/mnt/data disk/sub") || mountTableHasMountPoint(table, "/mnt") {
		t.Fatal("only exact mount points are protected")
	}
}

func TestValidatePath(t *testing.T) {
	tests := []struct {
		name    string
		path    string
		wantErr bool
	}{
		// 基本合法路径
		{"absolute path", "/Users/test/file.txt", false},
		{"path with spaces", "/Users/test/My Documents/file.txt", false},
		{"root", "/", false},

		// 中文路径
		{"chinese path", "/Users/test/中文文件夹/文件.txt", false},
		{"chinese mixed", "/Users/test/Downloads/报告2024.pdf", false},

		// Emoji 路径
		{"emoji path", "/Users/test/📁文件夹/📝笔记.txt", false},
		{"emoji only", "/Users/test/🎉/🎊.txt", false},

		// 特殊字符路径 (之前被错误拒绝的)
		{"dollar sign", "/Users/test/$HOME/workspace", false},
		{"semicolon", "/Users/test/project;v2", false},
		{"colon", "/Users/test/project:2024", false},
		{"ampersand", "/Users/test/R&D/project", false},
		{"at sign", "/Users/test/user@domain", false},
		{"hash", "/Users/test/project#123", false},
		{"percent", "/Users/test/100% complete", false},
		{"exclamation", "/Users/test/important!.txt", false},
		{"single quote", "/Users/test/user's files", false},
		{"equals", "/Users/test/key=value", false},
		{"plus", "/Users/test/file+v2", false},
		{"brackets", "/Users/test/[2024] report", false},
		{"parentheses", "/Users/test/project (copy)", false},
		{"comma", "/Users/test/file, backup", false},

		// 非法路径
		{"empty", "", true},
		{"relative", "relative/path", true},
		{"relative dot", "./file.txt", true},
		{"null byte", "/Users/test\x00/file", true},
		{"path traversal", "/Users/test/../../../etc", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validatePath(tt.path)
			if (err != nil) != tt.wantErr {
				t.Errorf("validatePath(%q) error = %v, wantErr %v", tt.path, err, tt.wantErr)
			}
		})
	}
}

func TestValidatePathWithChineseAndSpecialChars(t *testing.T) {
	// 专门测试之前会导致兼容性回退的路径
	parent := t.TempDir()
	testCases := []struct {
		name string
		path string
	}{
		{"chinese", "中文文件夹"},
		{"emoji", "📁 文档"},
		{"mixed", "报告-2024_v2 (终稿) [已审核]"},
		{"special", "Project$2024; Q1: R&D"},
		{"complex", "用户@公司 100% 完成!"},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			fullPath := filepath.Join(parent, tc.path)
			if err := os.MkdirAll(fullPath, 0o755); err != nil {
				t.Fatalf("mkdir %q: %v", tc.path, err)
			}

			if err := validatePath(fullPath); err != nil {
				t.Errorf("validatePath rejected valid path %q: %v", tc.path, err)
			}
		})
	}
}
