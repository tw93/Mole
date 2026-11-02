//go:build !windows

package main

import (
	"errors"
	"io/fs"
	"path/filepath"
	"time"
)

// The analyzer only runs on Windows. These stand-ins keep the platform-neutral
// code and its tests building elsewhere; every destructive path fails closed.

var errUnsupported = errors.New("analyze is only supported on Windows")

func isLinkEntry(entry fs.DirEntry) bool { return entry.Type()&fs.ModeSymlink != 0 }

func lastAccessTime(fs.FileInfo) time.Time { return time.Time{} }

func diskSize(_ string, info fs.FileInfo) int64 { return info.Size() }

func volumeUsedBytes(string) (int64, error) { return 0, errUnsupported }

func volumeFreeBytes(string) int64 { return 0 }

func systemDriveRoot() string { return "/" }

type driveInfo struct {
	name string
	root string
}

func fixedDrives() []driveInfo { return nil }

func safeOpen(string, bool) error { return errUnsupported }

func safePreview(string) error { return errUnsupported }

func moveToRecycleBinNative(string) (recycleOutcome, error) {
	return recycledVerified, errUnsupported
}

func isProtectedPath(string) bool { return true }

func resolveFinalPath(path string) (string, error) { return filepath.EvalSymlinks(path) }

func prepareRecycleTarget(string) (func() error, error) { return nil, errUnsupported }
