package main

// File attribute bits whose length overstates what the file occupies on disk.
const (
	attrSparse             = 0x00000200
	attrCompressed         = 0x00000800
	attrOffline            = 0x00001000
	attrRecallOnOpen       = 0x00040000
	attrRecallOnDataAccess = 0x00400000
)

// onDiskSize returns the bytes a file occupies given its length and
// attributes. An online-only cloud placeholder (OneDrive marks it
// RECALL_ON_DATA_ACCESS with OFFLINE, or RECALL_ON_OPEN) occupies nothing, so
// it counts as 0 without any call. Partly downloaded placeholders, sparse and
// NTFS-compressed files ask the file system for their allocation, a metadata
// read that never recalls data; every other file keeps the length the
// directory listing already returned. An unanswered query keeps the length,
// except for a placeholder, which is never counted as local data.
func onDiskSize(path string, length int64, attrs uint32, allocated func(string) (int64, error)) int64 {
	if attrs&attrRecallOnOpen != 0 || (attrs&attrRecallOnDataAccess != 0 && attrs&attrOffline != 0) {
		return 0
	}
	if attrs&(attrRecallOnDataAccess|attrSparse|attrCompressed) == 0 || allocated == nil {
		return length
	}
	size, err := allocated(path)
	if err != nil || size < 0 {
		if attrs&attrRecallOnDataAccess != 0 {
			return 0
		}
		return length
	}
	if size > length {
		return length
	}
	return size
}
