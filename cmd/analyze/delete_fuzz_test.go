package main

import (
	"path/filepath"
	"strings"
	"testing"
)

// FuzzValidatePath asserts the invariant: anything validatePath accepts
// (returns nil) must be absolute, free of null bytes, and free of ".."
// path components. The fuzzer also catches panics on adversarial input.
func FuzzValidatePath(f *testing.F) {
	seeds := []string{
		"/Users/alice",
		"/",
		"",
		"../etc/passwd",
		"/../etc/passwd",
		"/Users/../etc",
		"relative/path",
		"/path\x00with/null",
		"/with spaces/file",
		"/中文路径/测试",
		"/very/deeply/nested/path/that/is/quite/long",
		"/.",
		"/..",
		"/.../legitimate",
		"/name..files/ok",
		"//double/slash",
		"/trailing/slash/",
		"\x00",
		string(make([]byte, 4096)),
	}
	for _, s := range seeds {
		f.Add(s)
	}

	f.Fuzz(func(t *testing.T, path string) {
		err := validatePath(path)
		if err != nil {
			return
		}

		if path == "" {
			t.Errorf("accepted empty path")
		}
		if !filepath.IsAbs(path) {
			t.Errorf("accepted non-absolute path: %q", path)
		}
		if strings.Contains(path, "\x00") {
			t.Errorf("accepted path with null bytes: %q", path)
		}
		for p := range strings.SplitSeq(path, string(filepath.Separator)) {
			if p == ".." {
				t.Errorf("accepted path with .. component: %q", path)
			}
		}
	})
}
