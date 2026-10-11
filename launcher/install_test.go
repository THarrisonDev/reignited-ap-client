// Author: Tim Harrison
// Created: 2026-10-11
// Updated: 2026-10-11

package main

import (
	"archive/zip"
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

// zipBytes builds an in-memory zip from name->content entries.
func zipBytes(t *testing.T, entries map[string]string) []byte {
	t.Helper()
	var buf bytes.Buffer
	w := zip.NewWriter(&buf)
	for name, body := range entries {
		fw, err := w.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := fw.Write([]byte(body)); err != nil {
			t.Fatal(err)
		}
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// writeZip writes an in-memory zip to path.
func writeZip(t *testing.T, path string, entries map[string]string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, zipBytes(t, entries), 0644); err != nil {
		t.Fatal(err)
	}
}

func TestEnableMod(t *testing.T) {
	cases := []struct {
		name       string
		content    string // "" means the file does not exist
		want       string
		wantBackup bool
	}{
		{"missing", "", "srt_bridge : 1\n", false},
		{"disabled", "; c\nother : 1\nsrt_bridge : 0\n", "; c\nother : 1\nsrt_bridge : 1\n", true},
		{"enabled-noop", "srt_bridge : 1\n", "srt_bridge : 1\n", false},
		{"absent-appends", "other : 1\n", "other : 1\nsrt_bridge : 1\n", true},
		{"no-trailing-newline", "other : 1", "other : 1\nsrt_bridge : 1", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			p := filepath.Join(t.TempDir(), "mods.txt")
			if c.content != "" {
				if err := os.WriteFile(p, []byte(c.content), 0644); err != nil {
					t.Fatal(err)
				}
			}
			if err := enableMod(p); err != nil {
				t.Fatal(err)
			}
			got, err := os.ReadFile(p)
			if err != nil {
				t.Fatal(err)
			}
			if string(got) != c.want {
				t.Fatalf("mods.txt = %q, want %q", got, c.want)
			}
			baks, _ := filepath.Glob(p + ".bak-*")
			if c.wantBackup && len(baks) == 0 {
				t.Error("expected a backup")
			}
			if !c.wantBackup && len(baks) != 0 {
				t.Errorf("unexpected backup: %v", baks)
			}
		})
	}
}

func TestEnableModPreservesCRLFContent(t *testing.T) {
	p := filepath.Join(t.TempDir(), "mods.txt")
	if err := os.WriteFile(p, []byte("other : 1\r\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := enableMod(p); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(p)
	if string(got) != "other : 1\nsrt_bridge : 1\n" {
		t.Fatalf("mods.txt = %q", got)
	}
}

func TestExtractZipRejectsTraversal(t *testing.T) {
	zipPath := filepath.Join(t.TempDir(), "bad.zip")
	writeZip(t, zipPath, map[string]string{"../evil.txt": "x"})
	dest := filepath.Join(t.TempDir(), "dest")
	if err := os.MkdirAll(dest, 0755); err != nil {
		t.Fatal(err)
	}
	if err := extractZip(zipPath, dest, nil); err == nil {
		t.Fatal("expected traversal entry to be rejected")
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(dest), "evil.txt")); err == nil {
		t.Fatal("traversal wrote outside dest")
	}
}

func TestExtractZipKeepExisting(t *testing.T) {
	zipPath := filepath.Join(t.TempDir(), "m.zip")
	writeZip(t, zipPath, map[string]string{
		"Mods/srt_bridge/Scripts/config.txt": "debug=1\n",
		"Mods/srt_bridge/Scripts/main.lua":   "new\n",
	})
	dest := t.TempDir()
	cfg := filepath.Join(dest, "Mods", "srt_bridge", "Scripts", "config.txt")
	if err := os.MkdirAll(filepath.Dir(cfg), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cfg, []byte("debug=0\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := extractZip(zipPath, dest, keepModConfig); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(cfg); string(got) != "debug=0\n" {
		t.Fatalf("existing config clobbered: %q", got)
	}
	if got, _ := os.ReadFile(filepath.Join(dest, "Mods", "srt_bridge", "Scripts", "main.lua")); string(got) != "new\n" {
		t.Fatalf("main.lua = %q", got)
	}
}

func TestParseLibraryFolders(t *testing.T) {
	modern := `"libraryfolders"
{
	"0"
	{
		"path"		"/home/u/.local/share/Steam"
		"label"		""
		"apps"
		{
			"996580"	"41603544369"
		}
	}
	"1"
	{
		"path"		"/media/u/SteamLibrary"
	}
	"TimeNextStatsReport"	"1699999999"
}`
	got := parseLibraryFolders([]byte(modern))
	want := []string{"/home/u/.local/share/Steam", "/media/u/SteamLibrary"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}

	legacy := `"LibraryFolders"
{
	"TimeNextStatsReport"	"1"
	"1"		"/mnt/games/SteamLibrary"
}`
	got = parseLibraryFolders([]byte(legacy))
	if len(got) != 1 || got[0] != "/mnt/games/SteamLibrary" {
		t.Fatalf("legacy: got %v", got)
	}

	escaped := `"path"		"D:\\SteamLibrary"`
	got = parseLibraryFolders([]byte(escaped))
	if len(got) != 1 || got[0] != `D:\SteamLibrary` {
		t.Fatalf("escaped windows path: got %v", got)
	}
}

func TestFindGameWin64(t *testing.T) {
	root := t.TempDir()
	libA := filepath.Join(root, "A")
	libB := filepath.Join(root, "B")
	mkfile(t, filepath.Join(libB, gameRel(), "Spyro-Win64-Shipping.exe"))

	win, lib, ok := findGameWin64([]string{libA, libB})
	if !ok {
		t.Fatal("expected to find the game in library B")
	}
	if lib != libB {
		t.Fatalf("lib = %s, want %s", lib, libB)
	}
	if win != filepath.Join(libB, gameRel()) {
		t.Fatalf("win = %s", win)
	}
	if _, _, ok := findGameWin64([]string{libA}); ok {
		t.Fatal("expected no match when the game is absent")
	}
}

func TestInstallEndToEnd(t *testing.T) {
	root := t.TempDir()
	src := filepath.Join(root, "src")
	cfgDir := filepath.Join(root, "bridge")
	win64 := filepath.Join(root, "win64")

	mkfile(t, filepath.Join(src, "srtap_checkd.exe"))
	writeZip(t, filepath.Join(src, "srt_bridge.zip"), map[string]string{
		"Mods/srt_bridge/Scripts/main.lua":           "m",
		"Mods/srt_bridge/Scripts/lua-apclientpp.dll": "d",
	})
	// UE4SS already installed, so no download is attempted.
	mkfile(t, filepath.Join(win64, "dwmapi.dll"))
	mkfile(t, filepath.Join(win64, "UE4SS.dll"))
	mkfile(t, filepath.Join(win64, "Mods", "mods.txt"))

	p := Paths{ConfigDir: cfgDir, GameWin64: win64}
	for _, r := range Install(p, src, installOptions{NoDownload: true}) {
		if !r.OK {
			t.Errorf("step %q failed: %s", r.Step, r.Detail)
		}
	}
	checks := Verify(p)
	if !AllOK(checks) {
		for _, c := range checks {
			if !c.OK {
				t.Errorf("verify %q failed: %s", c.Name, c.Detail)
			}
		}
		t.Fatal("layout is not complete after install")
	}
}

func TestInstallDownloadsUE4SS(t *testing.T) {
	payload := zipBytes(t, map[string]string{"dwmapi.dll": "a", "UE4SS.dll": "b"})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/zip")
		_, _ = w.Write(payload)
	}))
	defer srv.Close()

	root := t.TempDir()
	win64 := filepath.Join(root, "win64")
	res := Install(Paths{ConfigDir: filepath.Join(root, "bridge"), GameWin64: win64},
		"", installOptions{UE4SSURL: srv.URL, HTTPClient: srv.Client()})

	var ue4ss *installResult
	for i := range res {
		if res[i].Step == "UE4SS" {
			ue4ss = &res[i]
		}
	}
	if ue4ss == nil || !ue4ss.OK {
		t.Fatalf("UE4SS step should succeed: %+v", res)
	}
	if !fileExists(filepath.Join(win64, "UE4SS.dll")) {
		t.Fatal("UE4SS.dll was not extracted")
	}
}

func TestInstallMissingSourcesReported(t *testing.T) {
	root := t.TempDir()
	win64 := filepath.Join(root, "win64")
	mkfile(t, filepath.Join(win64, "dwmapi.dll"))
	mkfile(t, filepath.Join(win64, "UE4SS.dll"))

	res := Install(Paths{ConfigDir: filepath.Join(root, "bridge"), GameWin64: win64},
		filepath.Join(root, "empty-src"), installOptions{NoDownload: true})
	byStep := map[string]installResult{}
	for _, r := range res {
		byStep[r.Step] = r
	}
	if byStep["Save scanner (srtap_checkd.exe)"].OK {
		t.Error("checkd step should fail with no source artifact")
	}
	if byStep["srt_bridge mod"].OK {
		t.Error("mod step should fail with no source artifact")
	}
}
