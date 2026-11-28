//go:build darwin

package main

import (
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/unix"
)

func TestJSONOverviewCoverageThroughAncestorSymlinks(t *testing.T) {
	root := t.TempDir()
	home := filepath.Join(root, "home")
	outside := filepath.Join(root, "outside")
	for _, tc := range []struct {
		name   string
		target string
		total  int64
	}{
		{name: "covered", target: filepath.Join(home, "DevData"), total: 10},
		{name: "separate", target: outside, total: 16},
	} {
		t.Run(tc.name, func(t *testing.T) {
			leaf := filepath.Join(tc.target, "DerivedData")
			if err := os.MkdirAll(leaf, 0o755); err != nil {
				t.Fatal(err)
			}
			alias := filepath.Join(home, tc.name)
			if err := os.Symlink(tc.target, alias); err != nil {
				t.Fatal(err)
			}
			parent := testJSONOverviewRow(home, 10)
			child := testJSONOverviewRow(filepath.Join(alias, "DerivedData"), 6)
			resolved, err := filepath.EvalSymlinks(leaf)
			if err != nil {
				t.Fatal(err)
			}
			if got := overviewCoveragePath(child); got != resolved {
				t.Fatalf("coverage path = %q, want %q", got, resolved)
			}
			if got := overviewTotalSize([]jsonOverviewMeasurement{child, parent}); got != tc.total {
				t.Errorf("total = %d, want %d", got, tc.total)
			}
		})
	}
}

func TestJSONOverviewCoverageOfOldDownloadsSymlink(t *testing.T) {
	root := t.TempDir()
	home := filepath.Join(root, "home")
	for _, tc := range []struct {
		name      string
		target    string
		allocated int64
		total     int64
	}{
		{name: "covered", target: filepath.Join(home, "aged"), allocated: 6, total: 10},
		{name: "separate", target: filepath.Join(root, "external"), allocated: 6, total: 16},
		{name: "sparse", target: filepath.Join(root, "sparse"), allocated: 0, total: 10},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if err := os.MkdirAll(home, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(tc.target, 0o755); err != nil {
				t.Fatal(err)
			}
			link := filepath.Join(home, tc.name)
			if err := os.Symlink(tc.target, link); err != nil {
				t.Fatal(err)
			}
			parent := testJSONOverviewRow(home, 10)
			child := testJSONOverviewRow(link, 60)
			if !overviewRowCovers(parent, child) {
				t.Fatal("ordinary du should count the link itself within Home")
			}
			child.ageFiltered = true
			child.allocatedSize = tc.allocated
			if got := overviewTotalSize([]jsonOverviewMeasurement{parent, child}); got != tc.total {
				t.Errorf("total = %d, want %d", got, tc.total)
			}
		})
	}
}

func TestJSONOverviewAgeFilteredRowCannotCoverFullChild(t *testing.T) {
	root := t.TempDir()
	childPath := filepath.Join(root, "child")
	if err := os.Mkdir(childPath, 0o755); err != nil {
		t.Fatal(err)
	}
	parent := testJSONOverviewRow(root, 20)
	parent.ageFiltered = true
	parent.allocatedSize = 2
	child := testJSONOverviewRow(childPath, 9)
	if overviewRowCovers(parent, child) {
		t.Fatal("the age-filtered parent does not cover a full child scan")
	}
	if got := overviewTotalSize([]jsonOverviewMeasurement{parent, child}); got != child.Size {
		t.Errorf("total = %d, want %d", got, child.Size)
	}
}

func TestJSONOverviewScopeOfSplitHomeSymlink(t *testing.T) {
	root := t.TempDir()
	physicalHome := filepath.Join(root, "physical")
	home := filepath.Join(root, "home")
	library := filepath.Join(physicalHome, "Library")
	project := filepath.Join(physicalHome, "project", "Library")
	for _, path := range []string{library, project} {
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(physicalHome, home); err != nil {
		t.Fatal(err)
	}
	parent := testJSONOverviewRow(home, 20)
	parent.excludedPath = filepath.Join(home, "Library")
	libraryRow := testJSONOverviewRow(library, 8)
	projectRow := testJSONOverviewRow(project, 6)
	if overviewRowCovers(parent, libraryRow) || !overviewRowCovers(parent, projectRow) {
		t.Fatal("split Home should exclude its own Library and cover the project's Library")
	}
	rows := []jsonOverviewMeasurement{projectRow, libraryRow, parent}
	if got := overviewTotalSize(rows); got != 28 {
		t.Errorf("total = %d, want 28", got)
	}
}

func TestJSONOverviewCloudExclusionKeepsKnownSeparateScope(t *testing.T) {
	root := t.TempDir()
	library := filepath.Join(root, "Library")
	cloud := filepath.Join(library, "CloudStorage", "provider")
	if err := os.MkdirAll(cloud, 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "Downloads")
	if err := os.Symlink(cloud, link); err != nil {
		t.Fatal(err)
	}
	parent := testJSONOverviewRow(library, 10)
	child := testJSONOverviewRow(link, 60)
	child.ageFiltered = true
	child.allocatedSize = 6
	if overviewRowCovers(parent, child) {
		t.Fatal("the Library scan skips the CloudStorage directory")
	}
	if got := overviewTotalSize([]jsonOverviewMeasurement{parent, child}); got != 16 {
		t.Errorf("total = %d, want 16", got)
	}
}

func TestJSONOverviewPartialBranchesDoNotSumHardlinks(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("permission fixture requires an unprivileged user")
	}
	for _, tc := range []struct {
		name    string
		mode    os.FileMode
		skipped bool
		nested  bool
	}{
		{name: "overlapping siblings", mode: 0o755},
		{name: "siblings in a skipped branch", mode: 0o111, skipped: true},
		{name: "skipped branch of nested partial parents", mode: 0o111, skipped: true, nested: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			parentPath := root
			if tc.nested {
				parentPath = filepath.Join(root, "intermediate")
				writeFileWithSize(t, filepath.Join(root, "outer-local"), 4<<20)
			}
			branch := filepath.Join(parentPath, "branch")
			first := filepath.Join(branch, "first")
			second := filepath.Join(branch, "second")
			file := filepath.Join(first, "payload")
			writeFileWithSize(t, file, 2<<20)
			writeFileWithSize(t, filepath.Join(parentPath, "local"), 1<<20)
			if err := os.Mkdir(second, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.Link(file, filepath.Join(second, "payload")); err != nil {
				t.Fatal(err)
			}
			unrelated := filepath.Join(parentPath, "unreadable")
			if err := os.Mkdir(unrelated, 0o000); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = os.Chmod(unrelated, 0o755) })
			if err := os.Chmod(branch, tc.mode); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = os.Chmod(branch, 0o755) })
			if tc.skipped {
				if err := unix.Faccessat(unix.AT_FDCWD, branch, unix.R_OK, unix.AT_EACCESS); !isPermissionFailure(err) {
					t.Skipf("effective read access probe did not confirm the denial: %v", err)
				}
			}

			parent := measureJSONOverviewRowForTest(t, parentPath)
			child1 := measureJSONOverviewRowForTest(t, first)
			child2 := measureJSONOverviewRowForTest(t, second)
			if parent.State != scanPartial || child1.State != scanComplete || child2.State != scanComplete ||
				child1.Size != 2<<20 || child2.Size != child1.Size {
				t.Fatalf("expected one partial parent and two complete hardlink rows: %+v %+v %+v", parent, child1, child2)
			}
			rows := []jsonOverviewMeasurement{child1, parent, child2}
			want := parent.Size
			if tc.nested {
				outer := measureJSONOverviewRowForTest(t, root)
				if outer.State != scanPartial || outer.Size <= parent.Size+child1.Size {
					t.Fatalf("expected a larger partial outer measurement, got %+v", outer)
				}
				rows = append(rows, outer)
				want = outer.Size
			}
			if tc.skipped {
				want += child1.Size
			}
			if got := overviewTotalSize(rows); got != want {
				t.Errorf("total = %d, want %d (parent = %d, each child = %d)", got, want, parent.Size, child1.Size)
			}
		})
	}
}

func testJSONOverviewRow(path string, size int64) jsonOverviewMeasurement {
	return jsonOverviewMeasurement{dirEntry: dirEntry{Path: path, Size: size, IsDir: true}}
}

func measureJSONOverviewRowForTest(t *testing.T, path string) jsonOverviewMeasurement {
	t.Helper()
	size, err := getDirectorySizeFromDu(t.Context(), path)
	row := testJSONOverviewRow(path, size)
	row.State = measurementState(size, err)
	return row
}
