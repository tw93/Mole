//go:build windows

package main

// Directory enumeration with file identity. os.ReadDir already asks the file
// system for FILE_ID_BOTH_DIR_INFO and then discards the file ID in Sys()
// (src/os/dir_windows.go, src/os/types_windows.go). This file repeats the same
// call and keeps the ID and the allocation size, so hardlink deduplication
// costs no extra round trip per file.

import (
	"errors"
	"fmt"
	"io/fs"
	"sync"
	"syscall"

	"golang.org/x/sys/windows"
)

const (
	// dirEnumBufferSize stays at 64 KiB: Windows 8.1 and earlier accept no
	// larger buffer for this information class, and one name alone can hold
	// 512 bytes.
	dirEnumBufferSize = 64 * 1024
	// Volume flags that must be set before the record carries a file ID.
	fileSupportsObjectIDs    = 0x00010000
	fileSupportsOpenByFileID = 0x01000000
)

// errIdentitiesUnavailable reports a volume that cannot supply file IDs.
// Callers keep the os.ReadDir numbers and skip deduplication for that root.
var errIdentitiesUnavailable = errors.New("file IDs are not available on this volume")

// The Windows name decoder copies nothing beyond the string itself.
func init() {
	decodeDirName = syscall.UTF16ToString
}

var dirEnumBufferPool = sync.Pool{New: func() any {
	buffer := make([]byte, dirEnumBufferSize, dirEnumBufferSize+idBothDirRecordSlack)
	return &buffer
}}

// readDirIdentityRecords opens path once and decodes every record the file
// system returns. The handle lives only for this call, the same lifetime
// os.ReadDir gives its own handle.
func readDirIdentityRecords(path string) ([]idBothDirEntry, error) {
	handle, err := openDirEnumHandle(path)
	if err != nil {
		return nil, err
	}
	defer func() {
		// Closing only releases the enumeration handle. The entries are
		// already copied out, so a close error changes nothing.
		_ = windows.CloseHandle(handle)
	}()

	volumeSerial, fileReference, err := requireIdentitySupport(handle, path)
	if err != nil {
		return nil, err
	}

	bufferPointer := dirEnumBufferPool.Get().(*[]byte)
	defer dirEnumBufferPool.Put(bufferPointer)
	buffer := *bufferPointer

	var entries []idBothDirEntry
	class := uint32(windows.FileIdBothDirectoryRestartInfo)
	for {
		callErr := windows.GetFileInformationByHandleEx(handle, class, &buffer[0], uint32(len(buffer)))
		if callErr != nil {
			if errors.Is(callErr, windows.ERROR_NO_MORE_FILES) {
				return entries, nil
			}
			// A restart read of an empty root reports "no such file"; MS-FSA
			// 2.1.5.6.3 defines that as an empty directory, not a failure.
			if errors.Is(callErr, syscall.ERROR_FILE_NOT_FOUND) && class == windows.FileIdBothDirectoryRestartInfo {
				return entries, nil
			}
			return nil, &fs.PathError{Op: "GetFileInformationByHandleEx", Path: path, Err: callErr}
		}
		class = windows.FileIdBothDirectoryInfo
		decodeErr := walkIDBothDirBuffer(buffer, func(entry idBothDirEntry) error {
			entry.VolumeSerial = volumeSerial
			entry.FileReference = fileReference
			entries = append(entries, entry)
			return nil
		})
		if decodeErr != nil {
			return nil, &fs.PathError{Op: "readdir", Path: path, Err: decodeErr}
		}
	}
}

// openDirEnumHandle opens path for listing only. It does not set
// FILE_FLAG_OPEN_REPARSE_POINT, because os.ReadDir follows the path it is
// given; the caller decides whether a linked directory is ever listed.
func openDirEnumHandle(path string) (windows.Handle, error) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return 0, &fs.PathError{Op: "readdir", Path: path, Err: err}
	}
	handle, err := windows.CreateFile(name,
		windows.FILE_LIST_DIRECTORY,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE,
		nil,
		windows.OPEN_EXISTING,
		windows.FILE_FLAG_BACKUP_SEMANTICS,
		0)
	if err != nil {
		return 0, &fs.PathError{Op: "readdir", Path: path, Err: err}
	}
	return handle, nil
}

// requireIdentitySupport asks the volume whether this directory can report file
// IDs. os.ReadDir runs the same probe for every directory handle.
// The file system name tells whether file IDs are NTFS file references.
func requireIdentitySupport(handle windows.Handle, path string) (uint32, bool, error) {
	var volumeSerial uint32
	var flags uint32
	var fileSystem [windows.MAX_PATH + 1]uint16
	if err := windows.GetVolumeInformationByHandle(handle, nil, 0, &volumeSerial, nil, &flags, &fileSystem[0], uint32(len(fileSystem))); err != nil {
		return 0, false, fmt.Errorf("%w: %s: %v", errIdentitiesUnavailable, path, err)
	}
	if volumeSerial == 0 || flags&fileSupportsObjectIDs == 0 || flags&fileSupportsOpenByFileID == 0 {
		return 0, false, fmt.Errorf("%w: %s", errIdentitiesUnavailable, path)
	}
	return volumeSerial, windows.UTF16ToString(fileSystem[:]) == "NTFS", nil
}
