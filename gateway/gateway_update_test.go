//go:build !updateserver

package main

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"os"
	"path/filepath"
	"testing"
)

func TestExtractTheProgramFromAReleaseFile(t *testing.T) {
	dir := t.TempDir()
	tgz := filepath.Join(dir, "gundil-gateway-1.9.1-linux-arm64.tar.gz")
	f, _ := os.Create(tgz)
	gz := gzip.NewWriter(f)
	tw := tar.NewWriter(gz)
	for _, e := range []struct{ name, body string }{
		{"gundil-gateway-1.9.1-linux-arm64/install.sh", "#!/bin/sh"},
		{"gundil-gateway-1.9.1-linux-arm64/gundil-gateway", "NEW PROGRAM"},
	} {
		tw.WriteHeader(&tar.Header{Name: e.name, Mode: 0o755, Size: int64(len(e.body)), Typeflag: tar.TypeReg})
		tw.Write([]byte(e.body))
	}
	tw.Close()
	gz.Close()
	f.Close()
	out := filepath.Join(dir, "out")
	if err := extractOne(tgz, "gundil-gateway", out); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(out); string(b) != "NEW PROGRAM" {
		t.Fatalf("got %q", b)
	}

	zp := filepath.Join(dir, "gundil-gateway-1.9.1-windows-x86_64.zip")
	zf, _ := os.Create(zp)
	zw := zip.NewWriter(zf)
	w, _ := zw.Create("gundil-gateway-1.9.1-windows-x86_64/gundil-gateway.exe")
	w.Write([]byte("EXE"))
	zw.Close()
	zf.Close()
	if err := extractOne(zp, "gundil-gateway.exe", out); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(out); string(b) != "EXE" {
		t.Fatalf("got %q", b)
	}
	if err := extractOne(zp, "missing", out); err == nil {
		t.Fatal("missing program not reported")
	}
	if p, v := packageOf("app-gundil-gateway-1.9.1-linux-arm64.tar.gz"); p != "gateway-linux-arm64" || v != "1.9.1" {
		t.Fatal(p, v)
	}
}
