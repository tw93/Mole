package main

import (
	"sync"
	"sync/atomic"
)

// On NTFS a directory record's file ID is a file reference whose low 48 bits
// are the MFT record number: unique among live files and dense, numbered from
// zero up to the size of the MFT. One bit per record then replaces a map entry
// per file, so a scan of a volume with two million MFT records holds 256 KiB of
// identities instead of tens of MiB. The sequence number in the high 16 bits
// is dropped: a record freed and reused by a new file during the walk reads as
// a link of the old one, a miss no walk of a live disk can rule out anyway.
// Mole for Windows keeps the same layout (src/Mole.Core/DiskScan/FileIdSet.cs).
const (
	ntfsRecordMask = 1<<48 - 1
	// maxDenseRecord keeps a nonsense file reference from asking for a huge
	// page table; 2^32 records is far beyond any real MFT. Larger values go to
	// the hashed set.
	maxDenseRecord = 1 << 32
	// recordPageShift sizes one lazily created page at 2^18 records, 32 KiB,
	// so a sparse MFT costs only the pages its files touch.
	recordPageShift = 18
	recordPageWords = 1 << (recordPageShift - 6)
)

type recordPage [recordPageWords]atomic.Uint64

// recordBitmap is safe for concurrent use. Readers find an existing page
// without locking; only creating a page or growing the page table locks.
type recordBitmap struct {
	growth sync.Mutex
	pages  atomic.Pointer[[]atomic.Pointer[recordPage]]
	count  atomic.Int64
}

// add reports whether record was not set before.
func (b *recordBitmap) add(record uint64) bool {
	page := b.page(int(record >> recordPageShift))
	bit := record & (1<<recordPageShift - 1)
	mask := uint64(1) << (bit & 63)
	return page[bit>>6].Or(mask)&mask == 0
}

func (b *recordBitmap) page(index int) *recordPage {
	if pages := b.pages.Load(); pages != nil && index < len(*pages) {
		if page := (*pages)[index].Load(); page != nil {
			return page
		}
	}
	b.growth.Lock()
	defer b.growth.Unlock()
	var current []atomic.Pointer[recordPage]
	if pages := b.pages.Load(); pages != nil {
		current = *pages
	}
	if index >= len(current) {
		grown := make([]atomic.Pointer[recordPage], max(index+1, 2*len(current), 16))
		for i := range current {
			grown[i].Store(current[i].Load())
		}
		b.pages.Store(&grown)
		current = grown
	}
	if page := current[index].Load(); page != nil {
		return page
	}
	page := new(recordPage)
	current[index].Store(page)
	b.count.Add(1)
	return page
}

// footprintBytes is the memory the pages hold, for the memory test.
func (b *recordBitmap) footprintBytes() int64 {
	return b.count.Load() * recordPageWords * 8
}
