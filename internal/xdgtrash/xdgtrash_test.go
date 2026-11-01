//go:build linux

package xdgtrash

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testEnv(t *testing.T) (*Env, string) {
	t.Helper()
	home := t.TempDir()
	return &Env{
		Home: home,
		UID:  os.Getuid(),
		Now:  func() time.Time { return time.Date(2026, 11, 1, 9, 30, 5, 0, time.Local) },
	}, home
}

func TestMoveWritesInfoThenMovesItem(t *testing.T) {
	env, home := testEnv(t)
	src := filepath.Join(home, "a b%c.txt")
	if err := os.WriteFile(src, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	res, err := env.Move(src)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(src); !os.IsNotExist(err) {
		t.Fatalf("source still present: %v", err)
	}
	if res.TrashFile != filepath.Join(home, ".local/share/Trash/files/a b%c.txt") {
		t.Fatalf("unexpected trash file %s", res.TrashFile)
	}
	info, _ := os.ReadFile(res.TrashInfo)
	want := "[Trash Info]\nPath=" + EncodePath(src) + "\nDeletionDate=2026-11-01T09:30:05\n"
	if string(info) != want {
		t.Fatalf("info = %q, want %q", info, want)
	}
	if !strings.Contains(string(info), "a%20b%25c.txt") {
		t.Fatalf("path not percent-encoded: %q", info)
	}
}

func TestMoveNeverReusesAName(t *testing.T) {
	env, home := testEnv(t)
	for i := 0; i < 3; i++ {
		p := filepath.Join(home, "same")
		if err := os.WriteFile(p, []byte{byte(i)}, 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := env.Move(p); err != nil {
			t.Fatal(err)
		}
	}
	for _, n := range []string{"same", "same.2", "same.3"} {
		if _, err := os.Stat(filepath.Join(env.HomeTrash(), "files", n)); err != nil {
			t.Fatalf("missing %s: %v", n, err)
		}
		if _, err := os.Stat(filepath.Join(env.HomeTrash(), "info", n+".trashinfo")); err != nil {
			t.Fatalf("missing info for %s: %v", n, err)
		}
	}
}

func TestMoveTrashesSymlinkNotTarget(t *testing.T) {
	env, home := testEnv(t)
	target := filepath.Join(home, "keep")
	if err := os.WriteFile(target, []byte("k"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(home, "link")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if _, err := env.Move(link); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(target); err != nil {
		t.Fatalf("symlink target was touched: %v", err)
	}
}

func TestMoveRefusesHomeRootAndTrash(t *testing.T) {
	env, home := testEnv(t)
	if err := os.MkdirAll(filepath.Join(env.HomeTrash(), "files"), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{"/", home, env.HomeTrash(), filepath.Join(home, ".local"), filepath.Join(env.HomeTrash(), "files")} {
		if _, err := env.Move(p); err == nil {
			t.Fatalf("Move(%s) succeeded", p)
		}
	}
}

func TestFailedMoveRemovesReservedInfo(t *testing.T) {
	env, home := testEnv(t)
	if _, err := env.Move(filepath.Join(home, "missing")); err == nil {
		t.Fatal("expected error")
	}
	entries, _ := os.ReadDir(filepath.Join(env.HomeTrash(), "info"))
	if len(entries) != 0 {
		t.Fatalf("left %d info files", len(entries))
	}
}

func TestRefusesForeignWritableTrash(t *testing.T) {
	env, home := testEnv(t)
	trash := env.HomeTrash()
	if err := os.MkdirAll(trash, 0o777); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(trash, 0o777); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(home, "f")
	_ = os.WriteFile(p, nil, 0o600)
	if _, err := env.Move(p); err == nil {
		t.Fatal("expected refusal of a world-writable Trash")
	}
	if _, err := os.Stat(p); err != nil {
		t.Fatal("item moved despite refusal")
	}
}

func TestEncodePath(t *testing.T) {
	cases := map[string]string{
		"/home/u/a b":  "/home/u/a%20b",
		"/home/u/中":    "/home/u/%E4%B8%AD",
		"rel/x~y_z.-q": "rel/x~y_z.-q",
		"/a%b":         "/a%25b",
	}
	for in, want := range cases {
		if got := EncodePath(in); got != want {
			t.Errorf("EncodePath(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestStrayTrashItemDoesNotBlockItsName(t *testing.T) {
	env, home := testEnv(t)
	files := filepath.Join(home, ".local/share/Trash/files")
	if err := os.MkdirAll(files, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(files, "note"), []byte("stray"), 0o600); err != nil {
		t.Fatal(err)
	}
	src := filepath.Join(home, "note")
	if err := os.WriteFile(src, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	res, err := env.Move(src)
	if err != nil {
		t.Fatal(err)
	}
	if res.TrashFile != filepath.Join(files, "note.2") {
		t.Fatalf("trash file = %s, want note.2", res.TrashFile)
	}
}
