//go:build darwin

package main

import (
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"

	"golang.org/x/sys/unix"
)

// Ordinary du operands preserve the final symlink. Old Downloads and the
// split Home scan list their operand and therefore follow the final symlink.
func overviewCoveragePath(row jsonOverviewMeasurement) string {
	if !filepath.IsAbs(row.Path) {
		return ""
	}
	path := filepath.Clean(row.Path)
	if overviewFollowsLeaf(row) {
		if resolved, err := filepath.EvalSymlinks(path); err == nil {
			return resolved
		}
	} else if dir, err := filepath.EvalSymlinks(filepath.Dir(path)); err == nil {
		return filepath.Join(dir, filepath.Base(path))
	}
	return path
}

func overviewFollowsLeaf(row jsonOverviewMeasurement) bool {
	return row.ageFiltered || row.excludedPath != ""
}

type overviewCoverage uint8

const (
	overviewOutside overviewCoverage = iota
	overviewOverlap
	overviewCovered
	overviewPermissionSkipped
)

// overviewRowCovers reports potential coverage for the overview cache key.
// Scan state and permission skips belong to the accounting of the measurement.
func overviewRowCovers(parent, child jsonOverviewMeasurement) bool {
	if parent.ageFiltered {
		return false
	}
	if parent.coveragePath == "" {
		parent.coveragePath = overviewCoveragePath(parent)
	}
	if child.coveragePath == "" {
		child.coveragePath = overviewCoveragePath(child)
	}
	return overviewCoverageBetween(parent, child, false) != overviewOutside
}

func overviewTotalSize(rows []jsonOverviewMeasurement) int64 {
	rows = slices.Clone(rows)
	for i := range rows {
		if rows[i].coveragePath == "" {
			rows[i].coveragePath = overviewCoveragePath(rows[i])
		}
	}
	// Place enclosing roots first. At the same root a broader, complete
	// measurement takes precedence over a narrower or incomplete one.
	sort.SliceStable(rows, func(i, j int) bool {
		a, b := rows[i], rows[j]
		if len(a.coveragePath) != len(b.coveragePath) {
			return len(a.coveragePath) < len(b.coveragePath)
		}
		if a.coveragePath != b.coveragePath {
			return a.coveragePath < b.coveragePath
		}
		if a.ageFiltered != b.ageFiltered {
			return !a.ageFiltered
		}
		if (a.excludedPath == "") != (b.excludedPath == "") {
			return a.excludedPath == ""
		}
		return a.State == scanComplete && b.State != scanComplete
	})

	type branchSizes struct {
		covered int64
		overlap int64
		skipped int64
	}
	children := make([]branchSizes, len(rows))
	var total int64
	for i, row := range slices.Backward(rows) {
		size := row.Size
		if row.ageFiltered {
			size = row.allocatedSize
		}
		size = max(size, 0)
		if row.State != scanComplete {
			size = max(size, children[i].covered)
		}
		size = max(size, children[i].overlap) + children[i].skipped
		if size == 0 {
			continue
		}

		parentIndex, coverage := findOverviewParent(rows, i)
		switch coverage {
		case overviewOutside:
			total += size
		case overviewCovered:
			children[parentIndex].covered = max(children[parentIndex].covered, size)
		case overviewOverlap:
			children[parentIndex].overlap = max(children[parentIndex].overlap, size)
		case overviewPermissionSkipped:
			// Independent scans of skipped paths can still share inodes.
			children[parentIndex].skipped = max(children[parentIndex].skipped, size)
		}
	}
	return total
}

func findOverviewParent(rows []jsonOverviewMeasurement, childIndex int) (int, overviewCoverage) {
	found := -1
	for i := childIndex - 1; i >= 0; i-- {
		parent := rows[i]
		switch coverage := overviewCoverageBetween(parent, rows[childIndex], parent.State != scanComplete); coverage {
		case overviewPermissionSkipped:
			// Keep a known skipped branch with the outermost parent that
			// skipped it, so an intermediate subtotal cannot hide it.
			found = i
		case overviewCovered, overviewOverlap:
			if found < 0 || (coverage == overviewCovered && parent.State == scanComplete) {
				return i, coverage
			}
		}
	}
	if found < 0 {
		return -1, overviewOutside
	}
	return found, overviewPermissionSkipped
}

func overviewCoverageBetween(parent, child jsonOverviewMeasurement, checkReadAccess bool) overviewCoverage {
	if parent.coveragePath == "" || child.coveragePath == "" {
		return overviewOutside
	}
	rel, err := filepath.Rel(parent.coveragePath, child.coveragePath)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return overviewOutside
	}
	coverage := overviewCovered
	if parent.ageFiltered {
		// Age and visibility filtering can leave only part of a child root.
		coverage = overviewOverlap
	}
	if excluded := overviewRelativeExclusion(parent); excluded != "" {
		if rel == excluded || strings.HasPrefix(rel, excluded+string(filepath.Separator)) {
			return overviewOutside
		}
		if rel == "." && excluded != overviewRelativeExclusion(child) {
			return overviewOverlap
		}
	}
	if rel == "." {
		return coverage
	}

	// Use the same operand spelling as the scan for device checks. The
	// relative components come from the resolved traversal roots.
	path := filepath.Clean(parent.Path)
	var info fs.FileInfo
	if overviewFollowsLeaf(parent) {
		info, err = os.Stat(path)
	} else {
		info, err = os.Lstat(path)
	}
	if err != nil {
		return overviewOverlap
	}
	if !info.IsDir() {
		return overviewOutside
	}
	dev, ok := fileDevice(path, info)
	device := scanDevice{dev: dev, ok: ok}
	if !ok {
		coverage = overviewOverlap
	}
	parts := strings.Split(rel, string(filepath.Separator))
	for i, part := range parts {
		if checkReadAccess && coverage != overviewPermissionSkipped &&
			isPermissionFailure(unix.Faccessat(unix.AT_FDCWD, path, unix.R_OK, unix.AT_EACCESS)) {
			// A walker needs read permission to list this strict ancestor.
			// An independently named child may still be reachable by search.
			coverage = overviewPermissionSkipped
		}
		if !parent.ageFiltered && overviewDuIgnoreNames[part] {
			// The directory name is ignored throughout the walk only when
			// the scanner finds a directory with that name at the root.
			info, err := os.Lstat(filepath.Join(parent.Path, part))
			if err == nil && info.IsDir() {
				return overviewOutside
			}
		}
		path = filepath.Join(path, part)
		info, err = os.Lstat(path)
		if err != nil {
			return overviewOverlap
		}
		if device.isOtherDevice(path, info) || (i < len(parts)-1 && !info.IsDir()) {
			return overviewOutside
		}
	}
	return coverage
}

// The scanner excludes this immediate entry, preserving a symlink at its leaf.
func overviewRelativeExclusion(row jsonOverviewMeasurement) string {
	if row.excludedPath == "" {
		return ""
	}
	rel, err := filepath.Rel(row.Path, row.excludedPath)
	if err != nil || rel == "." || rel == ".." || strings.ContainsRune(rel, filepath.Separator) {
		return ""
	}
	return rel
}
