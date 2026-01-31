package main

import (
	"container/heap"
	"testing"
)

func TestEntryHeap(t *testing.T) {
	t.Run("basic heap operations", func(t *testing.T) {
		h := &entryHeap{}
		heap.Init(h)

		// Push entries with varying sizes.
		heap.Push(h, dirEntry{Name: "medium", Size: 500})
		heap.Push(h, dirEntry{Name: "small", Size: 100})
		heap.Push(h, dirEntry{Name: "large", Size: 1000})

		if h.Len() != 3 {
			t.Errorf("Len() = %d, want 3", h.Len())
		}

		// Min-heap: smallest should come out first.
		first := heap.Pop(h).(dirEntry)
		if first.Name != "small" || first.Size != 100 {
			t.Errorf("first Pop() = %v, want {small, 100}", first)
		}

		second := heap.Pop(h).(dirEntry)
		if second.Name != "medium" || second.Size != 500 {
			t.Errorf("second Pop() = %v, want {medium, 500}", second)
		}

		third := heap.Pop(h).(dirEntry)
		if third.Name != "large" || third.Size != 1000 {
			t.Errorf("third Pop() = %v, want {large, 1000}", third)
		}

		if h.Len() != 0 {
			t.Errorf("Len() after all pops = %d, want 0", h.Len())
		}
	})

	t.Run("empty heap", func(t *testing.T) {
		h := &entryHeap{}
		heap.Init(h)

		if h.Len() != 0 {
			t.Errorf("empty heap Len() = %d, want 0", h.Len())
		}
	})

	t.Run("single element", func(t *testing.T) {
		h := &entryHeap{}
		heap.Init(h)

		heap.Push(h, dirEntry{Name: "only", Size: 42})
		popped := heap.Pop(h).(dirEntry)

		if popped.Name != "only" || popped.Size != 42 {
			t.Errorf("Pop() = %v, want {only, 42}", popped)
		}
	})

	t.Run("equal sizes maintain stability", func(t *testing.T) {
		h := &entryHeap{}
		heap.Init(h)

		heap.Push(h, dirEntry{Name: "a", Size: 100})
		heap.Push(h, dirEntry{Name: "b", Size: 100})
		heap.Push(h, dirEntry{Name: "c", Size: 100})

		// All have same size, heap property still holds.
		for i := 0; i < 3; i++ {
			popped := heap.Pop(h).(dirEntry)
			if popped.Size != 100 {
				t.Errorf("Pop() size = %d, want 100", popped.Size)
			}
		}
	})
}

func TestLargeFileHeap(t *testing.T) {
	t.Run("basic heap operations", func(t *testing.T) {
		h := &largeFileHeap{}
		heap.Init(h)

		// Push entries with varying sizes.
		heap.Push(h, fileEntry{Name: "medium.bin", Size: 500})
		heap.Push(h, fileEntry{Name: "small.txt", Size: 100})
		heap.Push(h, fileEntry{Name: "large.iso", Size: 1000})

		if h.Len() != 3 {
			t.Errorf("Len() = %d, want 3", h.Len())
		}

		// Min-heap: smallest should come out first.
		first := heap.Pop(h).(fileEntry)
		if first.Name != "small.txt" || first.Size != 100 {
			t.Errorf("first Pop() = %v, want {small.txt, 100}", first)
		}

		second := heap.Pop(h).(fileEntry)
		if second.Name != "medium.bin" || second.Size != 500 {
			t.Errorf("second Pop() = %v, want {medium.bin, 500}", second)
		}

		third := heap.Pop(h).(fileEntry)
		if third.Name != "large.iso" || third.Size != 1000 {
			t.Errorf("third Pop() = %v, want {large.iso, 1000}", third)
		}
	})

	t.Run("top N largest pattern", func(t *testing.T) {
		// This is how the heap is used in practice: keep top N largest.
		h := &largeFileHeap{}
		heap.Init(h)
		maxSize := 3

		files := []fileEntry{
			{Name: "a", Size: 50},
			{Name: "b", Size: 200},
			{Name: "c", Size: 30},
			{Name: "d", Size: 150},
			{Name: "e", Size: 300},
		}

		for _, f := range files {
			heap.Push(h, f)
			if h.Len() > maxSize {
				heap.Pop(h) // Remove smallest to keep only top N.
			}
		}

		if h.Len() != maxSize {
			t.Errorf("Len() = %d, want %d", h.Len(), maxSize)
		}

		// Extract remaining (should be 3 largest: 150, 200, 300).
		var sizes []int64
		for h.Len() > 0 {
			sizes = append(sizes, heap.Pop(h).(fileEntry).Size)
		}

		// Min-heap pops in ascending order.
		want := []int64{150, 200, 300}
		for i, s := range sizes {
			if s != want[i] {
				t.Errorf("sizes[%d] = %d, want %d", i, s, want[i])
			}
		}
	})
}
