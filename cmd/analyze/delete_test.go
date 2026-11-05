//go:build darwin

package main

import (
	"os"
	"os/user"
	"path/filepath"
	"strings"
	"testing"
)

func TestTrashPathWithProgress(t *testing.T) {
	skipIfFinderUnavailable(t)

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
	skipIfFinderUnavailable(t)

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

func TestValidateTrashTargetRejectsOrbStackLiveData(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	tests := []string{
		filepath.Join(home, "Library", "Group Containers", "HUAQ24HBR6.dev.orbstack"),
		filepath.Join(home, "Library", "Group Containers", "HUAQ24HBR6.dev.orbstack", "data"),
		filepath.Join(home, "Library", "Group Containers", "HUAQ24HBR6.dev.orbstack", "data", "data.img.raw"),
		filepath.Join(home, ".orbstack"),
		filepath.Join(home, ".orbstack", "state.db"),
	}

	for _, path := range tests {
		t.Run(path, func(t *testing.T) {
			if err := validateTrashTarget(path); err == nil || !strings.Contains(err.Error(), "protected path") {
				t.Fatalf("validateTrashTarget(%q) error = %v, want protected path error", path, err)
			}
		})
	}
}

func TestValidateTrashTargetRejectsDockerDesktopLiveData(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	tests := []string{
		filepath.Join(home, "Library", "Containers", "com.docker.docker"),
		filepath.Join(home, "Library", "Containers", "com.docker.docker", "Data"),
		filepath.Join(home, "Library", "Containers", "com.docker.docker", "Data", "vms", "0", "data", "Docker.raw"),
	}

	for _, path := range tests {
		t.Run(path, func(t *testing.T) {
			if err := validateTrashTarget(path); err == nil || !strings.Contains(err.Error(), "protected path") {
				t.Fatalf("validateTrashTarget(%q) error = %v, want protected path error", path, err)
			}
		})
	}
}

func TestValidateTrashTargetRejectsParentsOfProtectedRuntimeState(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	containers := filepath.Join(home, "Library", "Containers")
	if err := os.MkdirAll(containers, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := validateTrashTarget(containers); err != nil {
		t.Fatalf("empty container directory was protected: %v", err)
	}
	for _, relative := range []string{
		"Library/Containers/com.docker.docker/Data",
		"Library/Group Containers/HUAQ24HBR6.dev.orbstack/data",
	} {
		if err := os.MkdirAll(filepath.Join(home, relative), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	for _, relative := range []string{"Library", "Library/Containers", "Library/Group Containers"} {
		path := filepath.Join(home, relative)
		if err := validateTrashTarget(path); err == nil {
			t.Errorf("parent of protected runtime state accepted: %s", path)
		}
		alias := filepath.Join(t.TempDir(), "parent-alias")
		if err := os.Symlink(path, alias); err != nil {
			t.Fatal(err)
		}
		if err := validateTrashTarget(alias); err == nil {
			t.Errorf("alias of protected runtime parent accepted: %s", alias)
		}
	}
	for _, relative := range []string{"Library/Caches/rebuildable", "Library/Containers/com.example.app", "Library/Group Containers/example.dev.orbstack-backup"} {
		if err := validateTrashTarget(filepath.Join(home, relative)); err != nil {
			t.Errorf("unrelated sibling refused: %s: %v", relative, err)
		}
	}
}

func TestValidateTrashTargetRejectsPhysicalParentOfLinkedRuntimeState(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	external := t.TempDir()
	state := filepath.Join(external, "runtime")
	if err := os.Mkdir(state, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(state, filepath.Join(home, ".orbstack")); err != nil {
		t.Fatal(err)
	}
	if err := validateTrashTarget(external); err == nil {
		t.Fatal("physical parent of linked runtime state was accepted")
	}
	if err := validateTrashTarget(filepath.Join(external, "ordinary-sibling")); err != nil {
		t.Fatalf("ordinary sibling was protected: %v", err)
	}
}

func TestValidateTrashTargetRejectsDockerDesktopSymlinkAlias(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	dockerData := filepath.Join(home, "Library", "Containers", "com.docker.docker", "Data")
	if err := os.MkdirAll(dockerData, 0o755); err != nil {
		t.Fatalf("create Docker data fixture: %v", err)
	}
	alias := filepath.Join(home, "docker-data")
	if err := os.Symlink(filepath.Dir(dockerData), alias); err != nil {
		t.Fatalf("create Docker data symlink: %v", err)
	}

	path := filepath.Join(alias, "Data")
	if err := validateTrashTarget(path); err == nil || !strings.Contains(err.Error(), "protected path") {
		t.Fatalf("validateTrashTarget(%q) error = %v, want protected path error", path, err)
	}
}

func TestValidateTrashTargetRejectsDockerDesktopCaseVariant(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	dockerData := filepath.Join(home, "Library", "Containers", "com.docker.docker", "Data")
	if err := os.MkdirAll(dockerData, 0o755); err != nil {
		t.Fatalf("create Docker data fixture: %v", err)
	}

	caseVariant := filepath.Join(home, "library", "containers", "COM.DOCKER.DOCKER", "Data")
	if _, err := os.Stat(caseVariant); err != nil {
		t.Skip("filesystem is case-sensitive")
	}
	if err := validateTrashTarget(caseVariant); err == nil || !strings.Contains(err.Error(), "protected path") {
		t.Fatalf("validateTrashTarget(%q) error = %v, want protected path error", caseVariant, err)
	}
}

func TestValidateTrashTargetRejectsDockerDesktopLiveDataWithoutHOME(t *testing.T) {
	currentUser, err := user.Current()
	if err != nil || currentUser.HomeDir == "" {
		t.Skipf("current user home unavailable: %v", err)
	}
	t.Setenv("HOME", "")

	path := filepath.Join(currentUser.HomeDir, "Library", "Containers", "com.docker.docker", "Data")
	if err := validateTrashTarget(path); err == nil || !strings.Contains(err.Error(), "protected path") {
		t.Fatalf("validateTrashTarget(%q) with empty HOME error = %v, want protected path error", path, err)
	}
}

func TestValidateTrashTargetRejectsOrbStackGroupContainerAliases(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	groupRoot := filepath.Join(home, "Library", "Group Containers", "HUAQ24HBR6.dev.orbstack")
	groupData := filepath.Join(groupRoot, "data")
	if err := os.MkdirAll(groupData, 0o755); err != nil {
		t.Fatalf("create OrbStack group fixture: %v", err)
	}

	alias := filepath.Join(home, "orbstack-group")
	if err := os.Symlink(groupRoot, alias); err != nil {
		t.Fatalf("create OrbStack group symlink: %v", err)
	}
	if err := validateTrashTarget(filepath.Join(alias, "data")); err == nil || !strings.Contains(err.Error(), "protected path") {
		t.Fatalf("OrbStack group symlink error = %v, want protected path error", err)
	}

	caseVariant := filepath.Join(home, "library", "group containers", "huaq24hbr6.DEV.ORBSTACK", "data")
	if _, err := os.Stat(caseVariant); err == nil {
		if err := validateTrashTarget(caseVariant); err == nil || !strings.Contains(err.Error(), "protected path") {
			t.Fatalf("OrbStack group case variant error = %v, want protected path error", err)
		}
	}
}

func TestValidateTrashTargetRejectsOrbStackGroupContainerWithoutHOME(t *testing.T) {
	currentUser, err := user.Current()
	if err != nil || currentUser.HomeDir == "" {
		t.Skipf("current user home unavailable: %v", err)
	}
	t.Setenv("HOME", "")

	path := filepath.Join(currentUser.HomeDir, "Library", "Group Containers", "HUAQ24HBR6.dev.orbstack", "data")
	if err := validateTrashTarget(path); err == nil || !strings.Contains(err.Error(), "protected path") {
		t.Fatalf("validateTrashTarget(%q) with empty HOME error = %v, want protected path error", path, err)
	}
}

func TestValidateTrashTargetRejectsCriticalRoots(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	tests := []string{
		"/",
		"/Applications",
		"/Library",
		"/System",
		"/Users",
		"/Volumes",
		"/dev",
		"/etc",
		"/tmp",
		"/var",
		"/private",
		"/private/etc",
		"/private/tmp",
		"/private/var",
		"/private/var/audit",
		"/private/var/db",
		"/private/var/root",
		"/private/var/tmp",
		"/private/var/folders",
		"/Library/Apple",
		"/Library/Extensions",
		"/Library/Keychains",
		"/Applications/Finder.app",
		"/Applications/Safari.app",
		"/usr",
		"/opt",
		"/opt/homebrew",
		"/Users/another-account",
		home,
	}

	for _, path := range tests {
		t.Run(path, func(t *testing.T) {
			if err := validateTrashTarget(path); err == nil || !strings.Contains(err.Error(), "protected path") {
				t.Fatalf("validateTrashTarget(%q) error = %v, want protected path error", path, err)
			}
		})
	}
}

func TestValidateTrashTargetRejectsCriticalRootCaseAliases(t *testing.T) {
	tests := []struct {
		alias     string
		canonical string
	}{
		{"/SYSTEM", "/System"},
		{"/DEV", "/dev"},
		{"/PRIVATE/TMP", "/private/tmp"},
		{"/PRIVATE/VAR/FOLDERS", "/private/var/folders"},
		{"/USERS", "/Users"},
	}

	for _, tt := range tests {
		t.Run(tt.alias, func(t *testing.T) {
			if !isSameExistingPath(tt.alias, tt.canonical) {
				t.Skip("filesystem does not expose this case-insensitive alias")
			}
			if err := validateTrashTarget(tt.alias); err == nil || !strings.Contains(err.Error(), "protected path") {
				t.Fatalf("validateTrashTarget(%q) error = %v, want protected path error", tt.alias, err)
			}
		})
	}
}

func TestEndpointSecurityCachePathIsCaseInsensitive(t *testing.T) {
	path := "/PRIVATE/VAR/FOLDERS/9D/ABC/C/COM.CROWDSTRIKE.FALCON.APP/cache"
	if !isEndpointSecurityCachePath(path) {
		t.Fatalf("isEndpointSecurityCachePath(%q) = false, want true", path)
	}
}

func TestValidateTrashTargetRejectsOrbStackCaseVariant(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	path := filepath.Join(home, "LIBRARY", "GROUP CONTAINERS", "HUAQ24HBR6.DEV.ORBSTACK", "DATA")
	if err := validateTrashTarget(path); err == nil || !strings.Contains(err.Error(), "protected path") {
		t.Fatalf("validateTrashTarget(%q) error = %v, want protected path error", path, err)
	}
}

func TestValidateTrashTargetAllowsChildrenOfOtherUserHomes(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	path := "/Users/another-account/Library/Caches/old-cache"
	if err := validateTrashTarget(path); err != nil {
		t.Fatalf("validateTrashTarget(%q) error = %v, want nil", path, err)
	}
}

func TestValidateTrashTargetRejectsSymlinkToCriticalRoot(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	parent := t.TempDir()
	alias := filepath.Join(parent, "home-alias")
	if err := os.Symlink(home, alias); err != nil {
		t.Fatalf("create critical-root symlink: %v", err)
	}

	if err := validateTrashTarget(alias); err == nil || !strings.Contains(err.Error(), "protected path") {
		t.Fatalf("validateTrashTarget(%q) error = %v, want protected path error", alias, err)
	}
}

func TestValidateTrashTargetAllowsChildrenOfCriticalRoots(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	tests := []string{
		filepath.Join(home, "Downloads", "old.zip"),
		"/Applications/Example.app",
		"/Library/Caches/com.example.app",
		"/Volumes/External/old-artifact",
		"/private/tmp/mole-user-artifact",
		"/private/var/tmp/mole-user-artifact",
	}

	for _, path := range tests {
		t.Run(path, func(t *testing.T) {
			if err := validateTrashTarget(path); err != nil {
				t.Fatalf("validateTrashTarget(%q) error = %v, want nil", path, err)
			}
		})
	}
}

func TestValidateTrashTargetRejectsEndpointSecurityCaches(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	tests := []string{
		"/private/var/folders/zz",
		"/private/var/folders/zz/aa",
		"/private/var/folders/zz/aa/C",
		"/var/folders/zz/aa/T",
		"/var/folders/zz/aa/X",
		"/private/var/folders/zz/aa/C/com.crowdstrike.falcon.App/com.apple.metalfe",
		"/private/var/folders/zz/aa/X/com.sentinelone.agent.code_sign_clone",
		"/var/folders/zz/aa/C/com.jamf.management/cache",
	}

	for _, path := range tests {
		t.Run(path, func(t *testing.T) {
			if err := validateTrashTarget(path); err == nil || !strings.Contains(err.Error(), "protected path") {
				t.Fatalf("validateTrashTarget(%q) error = %v, want protected path error", path, err)
			}
		})
	}
}

func TestValidateTrashTargetAllowsNonEDRDarwinCache(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	// A normal app's rebuildable GPU cache under var/folders stays deletable.
	path := "/private/var/folders/zz/aa/C/com.example.App/com.apple.metalfe"
	if err := validateTrashTarget(path); err != nil {
		t.Fatalf("validateTrashTarget(%q) error = %v, want nil", path, err)
	}
}

func TestValidateTrashTargetRejectsEndpointSecurityCachesWithoutHOME(t *testing.T) {
	// The EDR check must not depend on HOME (e.g. `env -u HOME mo analyze`).
	t.Setenv("HOME", "")
	path := "/private/var/folders/zz/aa/C/com.crowdstrike.falcon.App/com.apple.metalfe"
	if err := validateTrashTarget(path); err == nil || !strings.Contains(err.Error(), "protected path") {
		t.Fatalf("validateTrashTarget(%q) with empty HOME error = %v, want protected path error", path, err)
	}
}

func TestEndpointSecurityBundlePrefixesMirrorShellData(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "lib", "core", "app_protection_data.sh"))
	if err != nil {
		t.Fatalf("read app_protection_data.sh: %v", err)
	}

	shellPrefixes := endpointSecurityPrefixesFromShellData(t, string(data))
	if len(shellPrefixes) != len(endpointSecurityBundlePrefixes) {
		t.Fatalf("endpointSecurityBundlePrefixes length = %d, shell ENDPOINT_SECURITY_BUNDLE_PREFIXES length = %d",
			len(endpointSecurityBundlePrefixes), len(shellPrefixes))
	}
	for i, prefix := range endpointSecurityBundlePrefixes {
		if prefix != shellPrefixes[i] {
			t.Fatalf("endpointSecurityBundlePrefixes[%d] = %q, shell ENDPOINT_SECURITY_BUNDLE_PREFIXES[%d] = %q",
				i, prefix, i, shellPrefixes[i])
		}
	}
}

func TestEndpointSecurityBundlePrefixesAllProtectDarwinCaches(t *testing.T) {
	for _, prefix := range endpointSecurityBundlePrefixes {
		t.Run(prefix, func(t *testing.T) {
			path := "/private/var/folders/zz/aa/C/" + prefix + "agent/cache"
			if !isEndpointSecurityCachePath(path) {
				t.Fatalf("isEndpointSecurityCachePath(%q) = false, want true", path)
			}
		})
	}
}

func endpointSecurityPrefixesFromShellData(t *testing.T, data string) []string {
	t.Helper()

	const marker = "readonly ENDPOINT_SECURITY_BUNDLE_PREFIXES=("
	_, body, ok := strings.Cut(data, marker)
	if !ok {
		t.Fatalf("ENDPOINT_SECURITY_BUNDLE_PREFIXES array not found")
	}

	body, _, ok = strings.Cut(body, "\n)")
	if !ok {
		t.Fatalf("ENDPOINT_SECURITY_BUNDLE_PREFIXES array terminator not found")
	}

	var prefixes []string
	for line := range strings.SplitSeq(body, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		prefixes = append(prefixes, strings.Trim(line, "\""))
	}
	return prefixes
}

func TestValidateTrashTargetAllowsRegularUserPaths(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	tests := []string{
		filepath.Join(home, "Downloads", "old.zip"),
		filepath.Join(home, "Library", "Caches", "example.cache"),
		filepath.Join(home, "Library", "Containers", "com.docker.docker-helper", "Data"),
		filepath.Join(home, "Library", "Group Containers", "group.com.example.tool", "Library", "Caches", "item"),
	}

	for _, path := range tests {
		t.Run(path, func(t *testing.T) {
			if err := validateTrashTarget(path); err != nil {
				t.Fatalf("validateTrashTarget(%q) error = %v, want nil", path, err)
			}
		})
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

// Regression for discussion #474: deleting from analyze over SSH appeared to do
// nothing. The only Trash path was Finder AppleScript, which raises a dialog on
// the physical machine that a remote user cannot answer, so every delete sat for
// trashTimeout and then failed. trash(8) needs no Finder, so it must be tried
// first and must actually move the file.
func TestMoveToTrashViaBinaryMovesFile(t *testing.T) {
	if _, err := os.Stat(trashBinary); err != nil {
		t.Skipf("%s not present on this macOS version", trashBinary)
	}

	dir := t.TempDir()
	probe, err := os.CreateTemp(dir, "mole-trash-binary-probe-*.txt")
	if err != nil {
		t.Fatalf("failed to create unique target: %v", err)
	}
	target := probe.Name()
	if _, err := probe.WriteString("probe"); err != nil {
		_ = probe.Close()
		t.Fatalf("failed to seed target: %v", err)
	}
	if err := probe.Close(); err != nil {
		t.Fatalf("failed to close target: %v", err)
	}

	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatalf("failed to resolve user home: %v", err)
	}
	trashCopy := filepath.Join(home, ".Trash", filepath.Base(target))
	if _, err := os.Lstat(trashCopy); !os.IsNotExist(err) {
		t.Fatalf("refusing Trash probe basename collision at %s", trashCopy)
	}
	t.Cleanup(func() {
		_ = os.Remove(trashCopy)
	})

	if err := moveToTrashViaBinary(target); err != nil {
		t.Fatalf("moveToTrashViaBinary failed: %v", err)
	}

	if _, err := os.Lstat(target); !os.IsNotExist(err) {
		t.Fatalf("expected %s to be gone, Lstat returned %v", target, err)
	}
}

func TestMoveToTrashViaFilesystemMovesWithoutOverwritingCollision(t *testing.T) {
	root := t.TempDir()
	home := filepath.Join(root, "home")
	trashDir := filepath.Join(home, ".Trash")
	sourceDir := filepath.Join(root, "source")
	if err := os.MkdirAll(trashDir, 0o700); err != nil {
		t.Fatalf("create fake Trash: %v", err)
	}
	if err := os.MkdirAll(sourceDir, 0o755); err != nil {
		t.Fatalf("create source directory: %v", err)
	}
	t.Setenv("HOME", home)

	target := filepath.Join(sourceDir, "report.txt")
	if err := os.WriteFile(target, []byte("new"), 0o644); err != nil {
		t.Fatalf("write target: %v", err)
	}
	existing := filepath.Join(trashDir, filepath.Base(target))
	if err := os.WriteFile(existing, []byte("keep"), 0o644); err != nil {
		t.Fatalf("write collision: %v", err)
	}

	if err := moveToTrashViaFilesystem(target); err != nil {
		t.Fatalf("filesystem Trash move failed: %v", err)
	}
	if _, err := os.Lstat(target); !os.IsNotExist(err) {
		t.Fatalf("expected source to be gone, Lstat returned %v", err)
	}
	if got, err := os.ReadFile(existing); err != nil || string(got) != "keep" {
		t.Fatalf("existing Trash item was changed: data=%q err=%v", got, err)
	}
	matches, err := filepath.Glob(filepath.Join(trashDir, "report.txt.*"))
	if err != nil || len(matches) != 1 {
		t.Fatalf("expected one collision-safe Trash item, matches=%v err=%v", matches, err)
	}
	if got, err := os.ReadFile(matches[0]); err != nil || string(got) != "new" {
		t.Fatalf("moved Trash item mismatch: data=%q err=%v", got, err)
	}
}

func TestMoveToTrashViaFilesystemRejectsSymlinkedTrash(t *testing.T) {
	root := t.TempDir()
	home := filepath.Join(root, "home")
	realTrash := filepath.Join(root, "real-trash")
	sourceDir := filepath.Join(root, "source")
	if err := os.MkdirAll(home, 0o755); err != nil {
		t.Fatalf("create fake home: %v", err)
	}
	if err := os.MkdirAll(realTrash, 0o700); err != nil {
		t.Fatalf("create real Trash: %v", err)
	}
	if err := os.MkdirAll(sourceDir, 0o755); err != nil {
		t.Fatalf("create source directory: %v", err)
	}
	if err := os.Symlink(realTrash, filepath.Join(home, ".Trash")); err != nil {
		t.Fatalf("create Trash symlink: %v", err)
	}
	t.Setenv("HOME", home)

	target := filepath.Join(sourceDir, "report.txt")
	if err := os.WriteFile(target, []byte("keep"), 0o644); err != nil {
		t.Fatalf("write target: %v", err)
	}

	if err := moveToTrashViaFilesystem(target); err == nil {
		t.Fatal("expected symlinked Trash to be rejected")
	}
	if _, err := os.Lstat(target); err != nil {
		t.Fatalf("target changed after rejected Trash move: %v", err)
	}
}

// trash(8) takes no "--" separator. Passing one makes it report a missing file
// named "--" and exit non-zero while still trashing the real target, which would
// make moveToTrash fall through to Finder and delete a second time. Absolute
// paths cannot be mistaken for options, so no separator is used.
func TestMoveToTrashViaBinaryUsesAbsolutePathWithoutSeparator(t *testing.T) {
	data, err := os.ReadFile("delete.go")
	if err != nil {
		t.Fatalf("failed to read delete.go: %v", err)
	}
	if strings.Contains(string(data), `trashBinary, "--"`) {
		t.Error(`moveToTrashViaBinary must not pass "--" to trash(8); it trashes the target but exits non-zero`)
	}
}

func TestAnalyzeDeleteRefusesICloudStructuralFoldersButNotTheirContents(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	mobile := filepath.Join(home, "Library", "Mobile Documents")
	for _, refused := range []string{
		mobile,
		filepath.Join(mobile, "com~apple~CloudDocs"),
		filepath.Join(mobile, "com~apple~Keynote"),
		filepath.Join(mobile, "com~apple~Keynote", "Documents"),
		filepath.Join(home, "library", "mobile documents", "COM~APPLE~PAGES", "documents"),
	} {
		if !isProtectedAnalyzeDeletePath(refused) {
			t.Errorf("iCloud structural folder not refused: %s", refused)
		}
	}
	for _, allowed := range []string{
		filepath.Join(mobile, "com~apple~CloudDocs", "Downloads"),
		filepath.Join(mobile, "com~apple~CloudDocs", "big.mov"),
		filepath.Join(mobile, "com~apple~Keynote", "Documents", "Deck.key"),
		filepath.Join(mobile, "com~apple~Keynote", "Documents", "Old", "a.key"),
		filepath.Join(home, "Library", "Mobile Documents Backup"),
	} {
		if isProtectedAnalyzeDeletePath(allowed) {
			t.Errorf("iCloud content refused: %s", allowed)
		}
	}
}

func TestAnalyzeDeleteRefusesICloudStructuralFoldersReachedThroughAnotherPath(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	container := filepath.Join(home, "Library", "Mobile Documents", "com~apple~Keynote", "Documents")
	if err := os.MkdirAll(container, 0o755); err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(t.TempDir(), "icloud")
	if err := os.Symlink(filepath.Join(home, "Library", "Mobile Documents"), alias); err != nil {
		t.Fatal(err)
	}
	for _, refused := range []string{
		alias,
		filepath.Join(alias, "com~apple~Keynote"),
		filepath.Join(alias, "com~apple~Keynote", "Documents"),
	} {
		if !isICloudStructuralPath(refused, home) {
			t.Errorf("iCloud structural folder reached through an alias not refused: %s", refused)
		}
	}
	if isICloudStructuralPath(filepath.Join(alias, "com~apple~Keynote", "Documents", "Deck.key"), home) {
		t.Errorf("file inside an app's iCloud Documents refused through an alias")
	}
}

func TestAnalyzeDeleteAllowsICloudFilesAtStructuralDepths(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	mobile := filepath.Join(home, "Library", "Mobile Documents")
	cloud := filepath.Join(mobile, "com~apple~CloudDocs")
	if err := os.MkdirAll(cloud, 0o700); err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(t.TempDir(), "icloud")
	if err := os.Symlink(mobile, alias); err != nil {
		t.Fatal(err)
	}
	for _, relative := range []string{"report.txt", "com~apple~CloudDocs/Documents"} {
		path := filepath.Join(mobile, relative)
		if err := os.WriteFile(path, []byte("keep user control"), 0o600); err != nil {
			t.Fatal(err)
		}
		for _, candidate := range []string{path, filepath.Join(alias, relative)} {
			if err := validateTrashTarget(candidate); err != nil {
				t.Errorf("ordinary iCloud file refused: %s: %v", candidate, err)
			}
		}
	}
	if err := validateTrashTarget(cloud); err == nil {
		t.Fatal("real iCloud container directory was accepted")
	}
}

func TestAnalyzeDeleteRefusesParentsOfExistingICloudState(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	library := filepath.Join(home, "Library")
	if err := os.MkdirAll(library, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := validateTrashTarget(library); err != nil {
		t.Fatalf("Library without protected state was refused: %v", err)
	}
	mobile := filepath.Join(library, "Mobile Documents")
	if err := os.MkdirAll(filepath.Join(mobile, "com~apple~Keynote", "Documents"), 0o700); err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(t.TempDir(), "library")
	if err := os.Symlink(library, alias); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{library, alias} {
		if err := validateTrashTarget(path); err == nil {
			t.Errorf("ancestor of iCloud state accepted: %s", path)
		}
	}
	for _, path := range []string{filepath.Join(library, "Caches"), filepath.Join(mobile, "com~apple~Keynote", "Documents", "Deck.key")} {
		if err := validateTrashTarget(path); err != nil {
			t.Errorf("unrelated directory or user content refused: %s: %v", path, err)
		}
	}
}
