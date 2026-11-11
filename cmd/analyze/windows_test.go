//go:build windows

package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestIsProtectedPathAcrossVolumeSpellings(t *testing.T) {
	protected := []string{
		`C:\`,
		`D:\`,
		`\\localhost\c$\`,
		`C:\Windows`,
		`C:\Program Files`,
		`C:\Program Files\App`,
		`C:\Program Files (x86)\Steam`,
		`C:\ProgramData`,
		`D:\Program Files`,
		`D:\ProgramData\Vendor`,
		`C:\Users`,
		`C:\Users\someone`,
		`C:\Users\Default\AppData`,
		`C:\Users\Public\Documents`,
		`\\localhost\c$\Program Files`,
		`\\localhost\c$\Program Files (x86)\Steam`,
		`\\localhost\c$\Windows\System32`,
		`\\?\C:\Program Files`,
		`\\?\UNC\localhost\c$\ProgramData`,
		`\\.\UNC\localhost\c$\Windows\System32`,
		`\\.\C:\Program Files (x86)`,
		`\\?\Volume{12345678-1234-1234-1234-123456789abc}\Windows`,
		`\\?\Volume{12345678-1234-1234-1234-123456789abc}\Program Files\App`,
		`\\?\HarddiskVolume3\ProgramData`,
		`\\?\GLOBALROOT\Device\HarddiskVolume3\Users\me\Downloads`,
		`E:\$Recycle.Bin`,
		`E:\$Recycle.Bin\S-1-5-21\file`,
		`E:\System Volume Information`,
		`C:\PerfLogs`,
		`C:\PerfLogs\System\Diagnostics`,
		`E:\Boot\BCD`,
		`C:\$WinREAgent\Scratch`,
		`C:\pagefile.sys`,
		`E:\pagefile.sys`,
		`E:\swapfile.sys`,
		`D:\HIBERFIL.SYS`,
		`C:\Projects`,
		`\\?\C:\Projects`,
		`\\?\Volume{12345678-1234-1234-1234-123456789abc}\Projects`,
		``,
	}
	for _, path := range protected {
		if !isProtectedPath(path) {
			t.Errorf("isProtectedPath(%q) = false, expected true", path)
		}
	}

	allowed := []string{
		`C:\Projects\Windows`,
		`D:\data\Program Files`,
		`E:\Projects`,
		`E:\pagefile.sys.bak`,
		`\\localhost\share\pagefile.txt`,
		`\\localhost\share\work`,
		`\\?\Volume{12345678-1234-1234-1234-123456789abc}\data\work`,
		`C:\Users\me\Downloads\node_modules`,
		`C:\Users\me\Downloads`,
		`C:\Users\me\AppData\Local\Temp\x`,
	}
	for _, path := range allowed {
		if isProtectedPath(path) {
			t.Errorf("isProtectedPath(%q) = true, expected false", path)
		}
	}
}

func TestIsProtectedPathFollowsEnvironmentFolders(t *testing.T) {
	root := t.TempDir()
	profile := filepath.Join(root, "Profiles", "me")
	sysRoot := filepath.Join(root, "WinDir")
	programs := filepath.Join(root, "Apps")
	local := filepath.Join(profile, "AppData", "Local")
	t.Setenv("USERPROFILE", profile)
	t.Setenv("SystemRoot", sysRoot)
	t.Setenv("WINDIR", sysRoot)
	t.Setenv("ProgramFiles", programs)
	t.Setenv("LOCALAPPDATA", local)
	t.Setenv("OneDrive", filepath.Join(root, "Cloud", "OneDrive"))
	t.Setenv("OneDriveConsumer", "")
	t.Setenv("OneDriveCommercial", "")

	for _, path := range []string{
		profile,
		strings.ToUpper(profile) + `\`,
		sysRoot,
		filepath.Join(sysRoot, "System32"),
		filepath.Join(programs, "Vendor", "app.exe"),
		filepath.Join(local, "Docker", "wsl", "disk.vhdx"),
		// The head of the user's own tree: the folders Windows creates in the profile,
		// AppData's three stores, a OneDrive root and the Mole app's own folders.
		filepath.Join(profile, "Downloads"),
		filepath.Join(profile, "Documents"),
		filepath.Join(profile, "desktop"),
		filepath.Join(profile, "Pictures"),
		filepath.Join(profile, "Videos"),
		filepath.Join(profile, "Music"),
		filepath.Join(profile, "AppData"),
		local,
		filepath.Join(profile, "AppData", "Roaming"),
		filepath.Join(profile, "AppData", "LocalLow"),
		filepath.Join(profile, "OneDrive"),
		filepath.Join(profile, "OneDrive - Contoso"),
		filepath.Join(root, "Cloud", "OneDrive"),
		filepath.Join(local, "Mole"),
		filepath.Join(local, "Mole", "logs", "crash.log"),
		filepath.Join(local, "Tw93.Mole", "current"),
	} {
		if !isProtectedPath(path) {
			t.Errorf("isProtectedPath(%q) = false, expected true", path)
		}
	}
	for _, path := range []string{
		// What a user keeps inside those folders can still be deleted.
		filepath.Join(profile, "Downloads", "old.iso"),
		filepath.Join(profile, "Documents", "Taxes"),
		filepath.Join(profile, "OneDrive", "Old photos"),
		filepath.Join(root, "Cloud", "OneDrive", "Old photos"),
		filepath.Join(profile, "OneDriveBackup"),
		filepath.Join(profile, "source"),
		filepath.Join(local, "Vendor"),
		filepath.Join(local, "MoleTools"),
		filepath.Join(root, "Data", "Documents"),
		filepath.Join(local, "Temp"),
		filepath.Join(root, "Apps2"),
	} {
		if isProtectedPath(path) {
			t.Errorf("isProtectedPath(%q) = true, expected false", path)
		}
	}
}

func withRecorder(t *testing.T) *[]string {
	t.Helper()
	var calls []string
	previous := recycleItem
	recycleItem = func(path string) (recycleOutcome, error) {
		calls = append(calls, path)
		return recycledVerified, nil
	}
	t.Cleanup(func() { recycleItem = previous })
	return &calls
}

func TestMoveToRecycleBinRefusesProtectedAndTraversal(t *testing.T) {
	calls := withRecorder(t)
	for _, path := range []string{
		`C:\`,
		`C:\Windows\Temp`,
		`C:\Program Files\App`,
		os.Getenv("USERPROFILE"),
		`C:\Users\me\..\..\Windows`,
		`relative\path`,
	} {
		if _, err := moveToRecycleBin(path); err == nil {
			t.Errorf("moveToRecycleBin(%q) succeeded, expected a refusal", path)
		}
	}
	if len(*calls) != 0 {
		t.Fatalf("the Recycle Bin was called for refused paths: %v", *calls)
	}
}

func TestMoveToRecycleBinPassesAbsolutePath(t *testing.T) {
	calls := withRecorder(t)
	dir := t.TempDir()
	target := filepath.Join(dir, "old.log")
	if err := os.WriteFile(target, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := recyclePathWithProgress(target, "1 B", nil); err != nil {
		t.Fatalf("recyclePathWithProgress: %v", err)
	}
	if len(*calls) != 1 || !strings.EqualFold((*calls)[0], target) {
		t.Fatalf("recycle calls = %v, want [%s]", *calls, target)
	}
}

// A junction whose parent path leads into a protected tree through another
// junction is refused, even though its spelling looks harmless.
func TestMoveToRecycleBinRefusesProtectedTreeReachedThroughJunction(t *testing.T) {
	calls := withRecorder(t)
	programData := os.Getenv("ProgramData")
	if programData == "" {
		t.Skip("ProgramData is not set")
	}
	link := filepath.Join(t.TempDir(), "pd")
	makeJunction(t, link, programData)

	if _, err := moveToRecycleBin(filepath.Join(link, "Microsoft")); err == nil {
		t.Fatal("expected a refusal for a protected folder reached through a junction")
	}
	if len(*calls) != 0 {
		t.Fatalf("the Recycle Bin was called: %v", *calls)
	}
}

func makeJunction(t *testing.T, link, target string) {
	t.Helper()
	out, err := exec.Command("cmd", "/c", "mklink", "/J", link, target).CombinedOutput()
	if err != nil {
		t.Skipf("cannot create a junction: %v %s", err, out)
	}
}

func TestJunctionsAreListedButNeverFollowed(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "big.bin"), make([]byte, 4096), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "own.txt"), []byte("12345"), 0o644); err != nil {
		t.Fatal(err)
	}
	makeJunction(t, filepath.Join(root, "link"), outside)

	size, err := calculateDirSizeFast(context.Background(), root, nil, nil, nil, nil, nil)
	if err != nil || size != 5 {
		t.Fatalf("calculateDirSizeFast = %d, %v; want 5 with the junction target uncounted", size, err)
	}

	result, err := scanPathConcurrent(context.Background(), root, nil, new(int64), new(int64), new(int64), nil)
	if err != nil {
		t.Fatal(err)
	}
	if result.TotalSize != 5 {
		t.Fatalf("scan total = %d, want 5", result.TotalSize)
	}
	for _, entry := range result.Entries {
		if strings.HasPrefix(entry.Name, "link") && entry.IsDir {
			t.Fatalf("junction listed as an enterable folder: %+v", entry)
		}
	}

	initial, targets, err := readLiveScanInitialEntries(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(targets) != 0 {
		t.Fatalf("live scan would walk %+v; a junction is not a scan target", targets)
	}
	if initial.TotalSize != 5 {
		t.Fatalf("live initial total = %d, want 5", initial.TotalSize)
	}
}

func TestOverviewEntriesUseProfileFoldersAndFixedDrives(t *testing.T) {
	home := t.TempDir()
	for _, dir := range []string{"AppData", "Downloads"} {
		if err := os.MkdirAll(filepath.Join(home, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("USERPROFILE", home)
	t.Setenv("LOCALAPPDATA", filepath.Join(home, "AppData", "Local"))

	names := map[string]string{}
	for _, entry := range createOverviewEntries() {
		names[entry.Name] = entry.Path
		if entry.Size != -1 || !entry.IsDir {
			t.Errorf("overview row %q should start pending: %+v", entry.Name, entry)
		}
	}
	if names["Home"] != home || names["User AppData"] != filepath.Join(home, "AppData") {
		t.Fatalf("Home/AppData rows = %q / %q", names["Home"], names["User AppData"])
	}
	if names["Old Downloads (90d+)"] != filepath.Join(home, "Downloads") {
		t.Fatalf("Old Downloads row = %q", names["Old Downloads (90d+)"])
	}
	foundDrive := false
	for name, path := range names {
		if isVolumeRoot(path) && strings.HasSuffix(name, ":)") {
			foundDrive = true
		}
	}
	if !foundDrive {
		t.Fatalf("no fixed drive row in %v", names)
	}
}

func TestMeasureOverviewSizeExcludesAppDataFromHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("USERPROFILE", home)
	if err := os.MkdirAll(filepath.Join(home, "AppData", "Local"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, "AppData", "Local", "cache.bin"), make([]byte, 1000), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, "doc.txt"), make([]byte, 10), 0o644); err != nil {
		t.Fatal(err)
	}
	size, err := measureOverviewSize(context.Background(), home)
	if err != nil || size != 10 {
		t.Fatalf("Home size = %d, %v; want 10 without AppData", size, err)
	}
	size, err = measureOverviewSize(context.Background(), filepath.Join(home, "AppData"))
	if err != nil || size != 1000 {
		t.Fatalf("AppData size = %d, %v; want 1000", size, err)
	}
}

// TestRecycleBinIntegration moves a real fixture to the Recycle Bin. It only
// runs when MOLE_ANALYZE_RECYCLE_FIXTURE names a scratch folder to use.
func TestRecycleBinIntegration(t *testing.T) {
	fixture := os.Getenv("MOLE_ANALYZE_RECYCLE_FIXTURE")
	if fixture == "" {
		t.Skip("set MOLE_ANALYZE_RECYCLE_FIXTURE to a scratch folder to run")
	}
	if err := os.MkdirAll(fixture, 0o755); err != nil {
		t.Fatal(err)
	}

	file := filepath.Join(fixture, "recycle-me.txt")
	if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	outcome, err := moveToRecycleBin(file)
	if err != nil {
		t.Fatalf("recycle file: %v", err)
	}
	// A one-byte file fits any Recycle Bin, so the bin has to have grown.
	if outcome == deletedPermanently {
		t.Fatalf("a recycled file was reported as permanently deleted")
	}
	if _, err := os.Lstat(file); !os.IsNotExist(err) {
		t.Fatalf("file still present after recycling: %v", err)
	}

	// A junction is recycled as a link: its target and contents stay.
	target := filepath.Join(fixture, "junction-target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatal(err)
	}
	kept := filepath.Join(target, "keep.txt")
	if err := os.WriteFile(kept, []byte("keep"), 0o644); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(fixture, "junction-link")
	makeJunction(t, link, target)
	if _, err := moveToRecycleBin(link); err != nil {
		t.Fatalf("recycle junction: %v", err)
	}
	if _, err := os.Lstat(link); !os.IsNotExist(err) {
		t.Fatalf("junction still present: %v", err)
	}
	if data, err := os.ReadFile(kept); err != nil || string(data) != "keep" {
		t.Fatalf("junction target content changed: %q, %v", data, err)
	}

	// A folder holding a junction is recycled without touching the target.
	parent := filepath.Join(fixture, "parent")
	if err := os.MkdirAll(parent, 0o755); err != nil {
		t.Fatal(err)
	}
	makeJunction(t, filepath.Join(parent, "inner-link"), target)
	if _, err := moveToRecycleBin(parent); err != nil {
		t.Fatalf("recycle folder with junction: %v", err)
	}
	if data, err := os.ReadFile(kept); err != nil || string(data) != "keep" {
		t.Fatalf("junction target content changed after recycling its parent: %q, %v", data, err)
	}
}

func TestRecycleRefusesProtectedDescendant(t *testing.T) {
	calls := withRecorder(t)
	local := filepath.Join(t.TempDir(), "Local")
	t.Setenv("LOCALAPPDATA", local)
	if err := os.MkdirAll(filepath.Join(local, "Docker", "wsl"), 0755); err != nil {
		t.Fatal(err)
	}
	if _, err := moveToRecycleBin(local); err == nil {
		t.Fatal("recycled parent of protected Docker data")
	}
	if len(*calls) != 0 {
		t.Fatalf("recycle called: %v", *calls)
	}
	sibling := filepath.Join(filepath.Dir(local), "ordinary")
	if err := os.Mkdir(sibling, 0755); err != nil {
		t.Fatal(err)
	}
	if _, err := moveToRecycleBin(sibling); err != nil {
		t.Fatal(err)
	}
	if len(*calls) != 1 {
		t.Fatalf("eligible sibling not recycled: %v", *calls)
	}
}

func TestRecycleReviewRejectsReplacedRoot(t *testing.T) {
	root := filepath.Join(t.TempDir(), "reviewed")
	if err := os.Mkdir(root, 0755); err != nil {
		t.Fatal(err)
	}
	guard, err := prepareRecycleTarget(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(root, root+"-original"); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(root, 0755); err != nil {
		t.Fatal(err)
	}
	if err := guard(); err == nil {
		t.Fatal("replacement accepted")
	}
}

func TestRecycleReviewRechecksNewProtectedChild(t *testing.T) {
	root := filepath.Join(t.TempDir(), "Local")
	t.Setenv("LOCALAPPDATA", root)
	if err := os.Mkdir(root, 0755); err != nil {
		t.Fatal(err)
	}
	guard, err := prepareRecycleTarget(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(root, "Docker"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := guard(); err == nil {
		t.Fatal("new protected child accepted")
	}
}
