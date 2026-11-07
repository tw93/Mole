//go:build windows

package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"runtime"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

// lastAccessTracked answers once per run whether NTFS records file openings; a
// missing or unreadable value is unknown, which claims nothing.
var lastAccessTracked = sync.OnceValue(func() bool {
	key, err := registry.OpenKey(registry.LOCAL_MACHINE, `SYSTEM\CurrentControlSet\Control\FileSystem`, registry.QUERY_VALUE)
	if err != nil {
		return false
	}
	defer func() { _ = key.Close() }()
	value, _, err := key.GetIntegerValue("NtfsDisableLastAccessUpdate")
	return err == nil && accessTrackedFrom(value)
})

// isLinkEntry reports a junction or symbolic link. Go reports these name
// surrogate reparse points without the directory bit, so a walk that only
// descends into IsDir entries never follows them; this check lets the listing
// label them. Cloud placeholders (OneDrive) are not name surrogates and stay
// ordinary files and folders.
func isLinkEntry(entry fs.DirEntry) bool {
	if entry.Type()&fs.ModeSymlink != 0 {
		return true
	}
	if entry.IsDir() || entry.Type()&fs.ModeIrregular == 0 {
		return false
	}
	info, err := entry.Info()
	if err != nil {
		return false
	}
	data, ok := info.Sys().(*syscall.Win32FileAttributeData)
	return ok && data.FileAttributes&syscall.FILE_ATTRIBUTE_DIRECTORY != 0 &&
		data.FileAttributes&syscall.FILE_ATTRIBUTE_REPARSE_POINT != 0
}

func lastAccessTime(info fs.FileInfo) time.Time {
	data, ok := info.Sys().(*syscall.Win32FileAttributeData)
	if !ok {
		return time.Time{}
	}
	ns := data.LastAccessTime.Nanoseconds()
	if ns <= 0 {
		return time.Time{}
	}
	return time.Unix(0, ns)
}

func diskSpace(path string) (available, total, free uint64, err error) {
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return 0, 0, 0, err
	}
	err = windows.GetDiskFreeSpaceEx(p, &available, &total, &free)
	return available, total, free, err
}

// volumeUsedBytes is the used space of the volume rooted at root.
func volumeUsedBytes(root string) (int64, error) {
	_, total, free, err := diskSpace(root)
	if err != nil {
		return 0, err
	}
	return int64(total - free), nil
}

// volumeFreeBytes is the free space available to the current user on the
// volume holding path, or 0 when it cannot be read.
func volumeFreeBytes(path string) int64 {
	available, _, _, err := diskSpace(path)
	if err != nil {
		return 0
	}
	return int64(available)
}

func systemDriveRoot() string {
	if drive := os.Getenv("SystemDrive"); drive != "" {
		return drive + `\`
	}
	return `C:\`
}

type driveInfo struct {
	name string
	root string
}

// fixedDrives lists local fixed volumes with drive letters, named the way
// Explorer names them, such as "Local Disk (C:)".
func fixedDrives() []driveInfo {
	mask, err := windows.GetLogicalDrives()
	if err != nil {
		return nil
	}
	var drives []driveInfo
	for i := 0; i < 26; i++ {
		if mask&(1<<uint(i)) == 0 {
			continue
		}
		letter := string(rune('A' + i))
		root := letter + `:\`
		rootPtr, err := windows.UTF16PtrFromString(root)
		if err != nil || windows.GetDriveType(rootPtr) != windows.DRIVE_FIXED {
			continue
		}
		label := "Local Disk"
		var labelBuf [windows.MAX_PATH + 1]uint16
		if err := windows.GetVolumeInformation(rootPtr, &labelBuf[0], uint32(len(labelBuf)), nil, nil, nil, nil, 0); err == nil {
			if name := windows.UTF16ToString(labelBuf[:]); name != "" {
				label = name
			}
		}
		drives = append(drives, driveInfo{name: fmt.Sprintf("%s (%s:)", label, letter), root: root})
	}
	return drives
}

// resolveFinalPath resolves every junction and symbolic link in path. Go's
// filepath.EvalSymlinks leaves junctions alone, so it cannot answer where a
// path really leads.
func resolveFinalPath(path string) (string, error) {
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return "", err
	}
	h, err := windows.CreateFile(p, 0, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE,
		nil, windows.OPEN_EXISTING, windows.FILE_FLAG_BACKUP_SEMANTICS, 0)
	if err != nil {
		return "", err
	}
	defer func() { _ = windows.CloseHandle(h) }()
	buf := make([]uint16, windows.MAX_PATH)
	for {
		n, err := windows.GetFinalPathNameByHandle(h, &buf[0], uint32(len(buf)), 0)
		if err != nil {
			return "", err
		}
		if int(n) < len(buf) {
			return windows.UTF16ToString(buf[:n]), nil
		}
		buf = make([]uint16, n+1)
	}
}

// withCOM runs fn on a locked thread with COM initialized, which the shell
// APIs used for opening files and recycling expect. A zero timeout waits for
// fn to finish.
func withCOM(timeout time.Duration, fn func() error) error {
	done := make(chan error, 1)
	go func() {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		if err := windows.CoInitializeEx(0, windows.COINIT_APARTMENTTHREADED|windows.COINIT_DISABLE_OLE1DDE); err == nil {
			defer windows.CoUninitialize()
		}
		done <- fn()
	}()
	if timeout <= 0 {
		return <-done
	}
	select {
	case err := <-done:
		return err
	case <-time.After(timeout):
		return errors.New("timed out")
	}
}

func shellOpen(path string) error {
	verb, err := windows.UTF16PtrFromString("open")
	if err != nil {
		return err
	}
	file, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	return withCOM(openCommandTimeout, func() error {
		return windows.ShellExecute(0, verb, file, nil, nil, windows.SW_SHOWNORMAL)
	})
}

// safeOpen opens path with its default handler, or selects it in Explorer
// when reveal is set.
func safeOpen(path string, reveal bool) error {
	if err := validatePath(path); err != nil {
		return err
	}
	if !reveal {
		return shellOpen(path)
	}
	// Explorer parses /select, itself and does not accept the argument quoted
	// as a whole, so the command line is written out rather than escaped.
	cmd := exec.Command("explorer.exe")
	cmd.SysProcAttr = &syscall.SysProcAttr{CmdLine: `explorer.exe /select,"` + path + `"`}
	return cmd.Run()
}

// safePreview opens the file with its default Windows application.
func safePreview(path string) error {
	if err := validatePath(path); err != nil {
		return err
	}
	return shellOpen(path)
}

const (
	foDelete           = 0x0003
	fofSilent          = 0x0004
	fofNoConfirmation  = 0x0010
	fofAllowUndo       = 0x0040
	fofNoErrorUI       = 0x0400
	fofWantNukeWarning = 0x4000
)

// shFileOpStructW mirrors SHFILEOPSTRUCTW with the natural alignment it has
// on 64-bit Windows; the 32-bit header packs it to one byte.
type shFileOpStructW struct {
	hwnd                  uintptr
	wFunc                 uint32
	pFrom                 *uint16
	pTo                   *uint16
	fFlags                uint16
	fAnyOperationsAborted int32
	hNameMappings         uintptr
	lpszProgressTitle     *uint16
}

var (
	kernel32                   = windows.NewLazySystemDLL("kernel32.dll")
	procGetCompressedFileSizeW = kernel32.NewProc("GetCompressedFileSizeW")
	shell32                    = windows.NewLazySystemDLL("shell32.dll")
	procSHFileOperationW       = shell32.NewProc("SHFileOperationW")
	procSHQueryRecycleBinW     = shell32.NewProc("SHQueryRecycleBinW")
)

// shQueryRBInfo mirrors SHQUERYRBINFO with its 64-bit natural alignment.
type shQueryRBInfo struct {
	cbSize      uint32
	i64Size     int64
	i64NumItems int64
}

// recycleBinItemCount reads how many items the Recycle Bin holds for one
// volume root, so a delete can tell whether it went there.
func recycleBinItemCount(volume *uint16) (int64, bool) {
	info := shQueryRBInfo{cbSize: uint32(unsafe.Sizeof(shQueryRBInfo{}))}
	ret, _, _ := procSHQueryRecycleBinW.Call(uintptr(unsafe.Pointer(volume)), uintptr(unsafe.Pointer(&info)))
	if ret != 0 {
		return 0, false
	}
	return info.i64NumItems, true
}

// moveToRecycleBinNative sends one absolute path to the Recycle Bin through
// the shell. Only fixed local drives have a Recycle Bin; elsewhere the shell
// would delete permanently, so those paths are refused. FOF_WANTNUKEWARNING
// makes the shell ask before it ever deletes instead of recycling, such as for
// an item larger than the Recycle Bin. If the user accepts that prompt the
// item is gone without reaching the bin; comparing the bin's item count before
// and after is how the outcome tells that apart.
func moveToRecycleBinNative(absPath string) (recycleOutcome, error) {
	if unsafe.Sizeof(uintptr(0)) != 8 {
		return recycledVerified, errors.New("moving to the Recycle Bin is supported only on 64-bit Windows")
	}
	volume, err := requireRecycleBinVolume(absPath)
	if err != nil {
		return recycledVerified, err
	}

	from, err := windows.UTF16FromString(absPath)
	if err != nil {
		return recycledVerified, err
	}
	from = append(from, 0) // pFrom is a double-null-terminated list.

	op := shFileOpStructW{
		wFunc:  foDelete,
		pFrom:  &from[0],
		fFlags: fofAllowUndo | fofNoConfirmation | fofSilent | fofNoErrorUI | fofWantNukeWarning,
	}
	before, beforeKnown := recycleBinItemCount(&volume[0])
	// Recycling a large folder can take a while; reporting a timeout while the
	// shell keeps moving it would misstate the outcome, so this waits.
	err = withCOM(0, func() error {
		ret, _, _ := procSHFileOperationW.Call(uintptr(unsafe.Pointer(&op)))
		runtime.KeepAlive(from)
		if ret != 0 {
			return fmt.Errorf("failed to move to Recycle Bin: shell error 0x%x", ret)
		}
		if op.fAnyOperationsAborted != 0 {
			return errors.New("move to Recycle Bin was cancelled")
		}
		return nil
	})
	if err != nil {
		return recycledVerified, err
	}
	if _, statErr := os.Lstat(absPath); statErr == nil {
		return recycledVerified, fmt.Errorf("failed to move to Recycle Bin: %s is still in place", absPath)
	}
	after, afterKnown := recycleBinItemCount(&volume[0])
	switch {
	case !beforeKnown || !afterKnown:
		return recycledUnverified, nil
	case after > before:
		return recycledVerified, nil
	default:
		return deletedPermanently, nil
	}
}

// requireRecycleBinVolume returns the volume root of absPath, which must be a
// fixed local drive: only those have a Recycle Bin.
func requireRecycleBinVolume(absPath string) ([]uint16, error) {
	pathPtr, err := windows.UTF16PtrFromString(absPath)
	if err != nil {
		return nil, err
	}
	volume := make([]uint16, windows.MAX_PATH+1)
	if err := windows.GetVolumePathName(pathPtr, &volume[0], uint32(len(volume))); err != nil {
		return nil, fmt.Errorf("cannot resolve the volume of %s: %w", absPath, err)
	}
	if windows.GetDriveType(&volume[0]) != windows.DRIVE_FIXED {
		return nil, fmt.Errorf("the Recycle Bin is not available for %s", absPath)
	}
	return volume, nil
}

// diskSize reads the attributes FindNextFile already returned; only a
// placeholder, sparse or compressed file costs one extra metadata query.
func diskSize(path string, info fs.FileInfo) int64 {
	data, ok := info.Sys().(*syscall.Win32FileAttributeData)
	if !ok {
		return info.Size()
	}
	return onDiskSize(path, info.Size(), data.FileAttributes, compressedFileSize)
}

// compressedFileSize asks for the allocated bytes of a sparse, compressed or
// partly downloaded file. It reads metadata only and recalls no file data.
func compressedFileSize(path string) (int64, error) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return 0, err
	}
	var high uint32
	low, _, callErr := procGetCompressedFileSizeW.Call(uintptr(unsafe.Pointer(name)), uintptr(unsafe.Pointer(&high)))
	if uint32(low) == 0xFFFFFFFF && callErr != windows.ERROR_SUCCESS {
		return 0, callErr
	}
	return int64(high)<<32 | int64(uint32(low)), nil
}
