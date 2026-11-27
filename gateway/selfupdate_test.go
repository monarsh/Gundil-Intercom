package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestUpdateDir(t *testing.T) {
	exe := filepath.Join(t.TempDir(), "prog")
	d, err := updateDir(exe, "gundil-test")
	if err != nil || filepath.Dir(d) == filepath.Dir(exe) {
		t.Fatalf("with a usable temp folder it is used: %s %v", d, err)
	}
	os.RemoveAll(d)
	t.Setenv("TMPDIR", filepath.Join(t.TempDir(), "missing"))
	d, err = updateDir(exe, "gundil-test")
	if err != nil || filepath.Dir(d) != filepath.Dir(exe) || !strings.HasPrefix(filepath.Base(d), ".gundil-test-") {
		t.Fatalf("without it, next to the program: %s %v", d, err)
	}
}
