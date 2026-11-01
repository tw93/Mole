package main

// entryHeap is a min-heap of dirEntry used to keep Top N largest entries.
type entryHeap []dirEntry

// sizePathBefore is the ordering shared by selection and rendering.
func sizePathBefore(size int64, path string, otherSize int64, otherPath string) bool {
	if size != otherSize {
		return size > otherSize
	}
	return path < otherPath
}

func (h entryHeap) Len() int { return len(h) }

// The heap evicts its smallest item first. Equal sizes fall back to the path
// (the later path goes first), so the surviving rows and their pop order do
// not depend on which worker finished first.
func (h entryHeap) Less(i, j int) bool {
	return sizePathBefore(h[j].Size, h[j].Path, h[i].Size, h[i].Path)
}
func (h entryHeap) Swap(i, j int) { h[i], h[j] = h[j], h[i] }

func (h *entryHeap) Push(x any) {
	*h = append(*h, x.(dirEntry))
}

func (h *entryHeap) Pop() any {
	old := *h
	n := len(old)
	x := old[n-1]
	*h = old[0 : n-1]
	return x
}

// largeFileHeap is a min-heap for fileEntry.
type largeFileHeap []fileEntry

func (h largeFileHeap) Len() int { return len(h) }
func (h largeFileHeap) Less(i, j int) bool {
	return sizePathBefore(h[j].Size, h[j].Path, h[i].Size, h[i].Path)
}
func (h largeFileHeap) Swap(i, j int) { h[i], h[j] = h[j], h[i] }

func (h *largeFileHeap) Push(x any) {
	*h = append(*h, x.(fileEntry))
}

func (h *largeFileHeap) Pop() any {
	old := *h
	n := len(old)
	x := old[n-1]
	*h = old[0 : n-1]
	return x
}
