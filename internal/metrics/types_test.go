package metrics

import (
	"slices"
	"testing"
)

func TestNewRingBuffer(t *testing.T) {
	tests := []struct {
		name     string
		capacity int
	}{
		{"small buffer", 5},
		{"standard buffer", 120},
		{"single element", 1},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rb := NewRingBuffer(tt.capacity)
			if rb == nil {
				t.Fatal("NewRingBuffer returned nil")
			}
			if rb.cap != tt.capacity {
				t.Errorf("NewRingBuffer(%d).cap = %d, want %d", tt.capacity, rb.cap, tt.capacity)
			}
			if rb.size != 0 {
				t.Errorf("NewRingBuffer(%d).size = %d, want 0", tt.capacity, rb.size)
			}
			if rb.index != 0 {
				t.Errorf("NewRingBuffer(%d).index = %d, want 0", tt.capacity, rb.index)
			}
			if len(rb.data) != tt.capacity {
				t.Errorf("len(NewRingBuffer(%d).data) = %d, want %d", tt.capacity, len(rb.data), tt.capacity)
			}
		})
	}
}

func TestRingBuffer_EmptyBuffer(t *testing.T) {
	rb := NewRingBuffer(5)
	got := rb.Slice()

	if got != nil {
		t.Errorf("Slice() on empty buffer = %v, want nil", got)
	}
}

func TestRingBuffer_AddWithinCapacity(t *testing.T) {
	rb := NewRingBuffer(5)

	// Add 3 elements (less than capacity)
	rb.Add(1.0)
	rb.Add(2.0)
	rb.Add(3.0)

	if rb.size != 3 {
		t.Errorf("size after 3 adds = %d, want 3", rb.size)
	}

	got := rb.Slice()
	want := []float64{1.0, 2.0, 3.0}

	if !slices.Equal(got, want) {
		t.Errorf("Slice() = %v, want %v", got, want)
	}
}

func TestRingBuffer_ExactCapacity(t *testing.T) {
	rb := NewRingBuffer(5)

	// Fill exactly to capacity
	for i := 1; i <= 5; i++ {
		rb.Add(float64(i))
	}

	if rb.size != 5 {
		t.Errorf("size after filling to capacity = %d, want 5", rb.size)
	}

	got := rb.Slice()
	want := []float64{1.0, 2.0, 3.0, 4.0, 5.0}

	if !slices.Equal(got, want) {
		t.Errorf("Slice() = %v, want %v", got, want)
	}
}

func TestRingBuffer_WrapAround(t *testing.T) {
	rb := NewRingBuffer(5)

	// Add 7 elements to trigger wrap-around (2 past capacity)
	// Internal state after: data=[6, 7, 3, 4, 5], index=2, size=5
	// Oldest element is at index 2 (value 3)
	for i := 1; i <= 7; i++ {
		rb.Add(float64(i))
	}

	if rb.size != 5 {
		t.Errorf("size after wrap-around = %d, want 5", rb.size)
	}

	// Verify index points to oldest element position
	if rb.index != 2 {
		t.Errorf("index after adding 7 elements to cap-5 buffer = %d, want 2", rb.index)
	}

	got := rb.Slice()
	// Should return chronological order: oldest (3) to newest (7)
	want := []float64{3.0, 4.0, 5.0, 6.0, 7.0}

	if !slices.Equal(got, want) {
		t.Errorf("Slice() = %v, want %v", got, want)
	}
}

func TestRingBuffer_MultipleWrapArounds(t *testing.T) {
	rb := NewRingBuffer(3)

	// Add 10 elements (wraps multiple times)
	for i := 1; i <= 10; i++ {
		rb.Add(float64(i))
	}

	got := rb.Slice()
	// Should have the last 3 values: 8, 9, 10
	want := []float64{8.0, 9.0, 10.0}

	if !slices.Equal(got, want) {
		t.Errorf("Slice() after 10 adds to cap-3 buffer = %v, want %v", got, want)
	}
}

func TestRingBuffer_SingleElementBuffer(t *testing.T) {
	rb := NewRingBuffer(1)

	rb.Add(5.0)
	if got := rb.Slice(); !slices.Equal(got, []float64{5.0}) {
		t.Errorf("Slice() = %v, want [5.0]", got)
	}

	// Overwrite the single element
	rb.Add(10.0)
	if got := rb.Slice(); !slices.Equal(got, []float64{10.0}) {
		t.Errorf("Slice() after overwrite = %v, want [10.0]", got)
	}
}

func TestRingBuffer_SliceReturnsNewSlice(t *testing.T) {
	rb := NewRingBuffer(3)
	rb.Add(1.0)
	rb.Add(2.0)

	slice1 := rb.Slice()
	slice2 := rb.Slice()

	// Modify slice1 and verify slice2 is unaffected
	// This ensures Slice() returns a copy, not a reference to internal data
	slice1[0] = 999.0

	if slice2[0] == 999.0 {
		t.Error("Slice() should return a new copy, not a reference to internal data")
	}
}

func TestRingBuffer_NegativeAndZeroValues(t *testing.T) {
	rb := NewRingBuffer(4)

	// Test that negative and zero values are handled correctly
	rb.Add(-5.0)
	rb.Add(0.0)
	rb.Add(0.0)
	rb.Add(3.5)

	got := rb.Slice()
	want := []float64{-5.0, 0.0, 0.0, 3.5}

	if !slices.Equal(got, want) {
		t.Errorf("Slice() with negative/zero values = %v, want %v", got, want)
	}
}
