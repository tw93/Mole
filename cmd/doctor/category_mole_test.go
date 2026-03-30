//go:build darwin

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCountWhitelistErrors(t *testing.T) {
	tests := []struct {
		name    string
		content string
		want    int
	}{
		{
			name:    "valid paths only",
			content: "/usr/local/bin\n/opt/homebrew/bin\n/Applications\n",
			want:    0,
		},
		{
			name:    "with comments",
			content: "/usr/local/bin\n# comment line\n/opt/homebrew/bin\n",
			want:    0,
		},
		{
			name:    "with empty lines",
			content: "/usr/local/bin\n\n/opt/homebrew/bin\n\n",
			want:    0,
		},
		{
			name:    "leading double dots error",
			content: "/usr/local/bin\n../escape\n/opt/homebrew/bin\n",
			want:    1,
		},
		{
			name:    "slash double dots error",
			content: "/usr/local/bin\n/foo/../bar\n/opt/homebrew/bin\n",
			want:    1,
		},
		{
			name:    "multiple errors",
			content: "/usr/local/bin\n../escape\n/foo/../bar\n..hidden\n/opt/homebrew/bin\n",
			want:    3,
		},
		{
			name:    "empty content",
			content: "",
			want:    0,
		},
		{
			name:    "only comments",
			content: "# comment 1\n# comment 2\n",
			want:    0,
		},
		{
			name:    "whitespace handling",
			content: "  /usr/local/bin  \n  ../bad  \n  /opt/homebrew/bin  \n",
			want:    1,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := countWhitelistErrors(tt.content)
			if got != tt.want {
				t.Errorf("countWhitelistErrors(%q) = %d, want %d", tt.content, got, tt.want)
			}
		})
	}
}

func TestCheckMoleConfig_ValidWhitelist(t *testing.T) {
	tmpDir := t.TempDir()
	configDir := filepath.Join(tmpDir, ".config", "mole")
	if err := os.MkdirAll(configDir, 0755); err != nil {
		t.Fatal(err)
	}

	whitelistPath := filepath.Join(configDir, "whitelist")
	content := "/usr/local/bin\n/opt/homebrew/bin\n# comment\n"
	if err := os.WriteFile(whitelistPath, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}

	data, err := os.ReadFile(whitelistPath)
	if err != nil {
		t.Fatal(err)
	}

	errorCount := countWhitelistErrors(string(data))
	if errorCount != 0 {
		t.Errorf("valid whitelist had %d errors, want 0", errorCount)
	}
}

func TestCheckMoleConfig_InvalidWhitelist(t *testing.T) {
	tmpDir := t.TempDir()
	configDir := filepath.Join(tmpDir, ".config", "mole")
	if err := os.MkdirAll(configDir, 0755); err != nil {
		t.Fatal(err)
	}

	whitelistPath := filepath.Join(configDir, "whitelist")
	content := "/usr/local/bin\n../escape\n/foo/../bar\n# comment\n..hidden\n"
	if err := os.WriteFile(whitelistPath, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}

	data, err := os.ReadFile(whitelistPath)
	if err != nil {
		t.Fatal(err)
	}

	errorCount := countWhitelistErrors(string(data))
	if errorCount != 3 {
		t.Errorf("invalid whitelist had %d errors, want 3", errorCount)
	}
}

func TestCheckMoleConfig_MixedValidAndInvalid(t *testing.T) {
	tmpDir := t.TempDir()
	configDir := filepath.Join(tmpDir, ".config", "mole")
	if err := os.MkdirAll(configDir, 0755); err != nil {
		t.Fatal(err)
	}

	whitelistPath := filepath.Join(configDir, "whitelist")
	content := "/usr/local/bin\n/usr/bin\n/foo/../bar\n/Applications\n"
	if err := os.WriteFile(whitelistPath, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}

	data, err := os.ReadFile(whitelistPath)
	if err != nil {
		t.Fatal(err)
	}

	errorCount := countWhitelistErrors(string(data))
	if errorCount != 1 {
		t.Errorf("mixed valid/invalid whitelist had %d errors, want 1", errorCount)
	}
}
