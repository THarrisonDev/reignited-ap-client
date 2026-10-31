// Author: Tim Harrison
// Created: 2026-10-11
// Updated: 2026-10-31

package main

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
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
		t.Run(c.name, func(t *testing.T) { checkEnableMod(t, c.content, c.want, c.wantBackup) })
	}
}

// checkEnableMod runs one enableMod case and asserts the rewritten file and
// whether a backup was taken.
func checkEnableMod(t *testing.T, content, want string, wantBackup bool) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "mods.txt")
	if content != "" {
		if err := os.WriteFile(p, []byte(content), 0644); err != nil {
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
	if string(got) != want {
		t.Fatalf("mods.txt = %q, want %q", got, want)
	}
	baks, _ := filepath.Glob(p + ".bak-*")
	if wantBackup && len(baks) == 0 {
		t.Error("expected a backup")
	}
	if !wantBackup && len(baks) != 0 {
		t.Errorf("unexpected backup: %v", baks)
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
	if err := extractZip(zipPath, dest); err == nil {
		t.Fatal("expected traversal entry to be rejected")
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(dest), "evil.txt")); err == nil {
		t.Fatal("traversal wrote outside dest")
	}
}

func TestExtractZipOverwritesExisting(t *testing.T) {
	zipPath := filepath.Join(t.TempDir(), "m.zip")
	writeZip(t, zipPath, map[string]string{
		"Mods/srt_bridge/Scripts/main.lua": "new\n",
	})
	dest := t.TempDir()
	main := filepath.Join(dest, "Mods", "srt_bridge", "Scripts", "main.lua")
	if err := os.MkdirAll(filepath.Dir(main), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(main, []byte("old\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := extractZip(zipPath, dest); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(main); string(got) != "new\n" {
		t.Fatalf("re-extraction must overwrite: %q", got)
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
	if !slices.Equal(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}

	legacy := `"LibraryFolders"
{
	"TimeNextStatsReport"	"1"
	"1"		"/mnt/games/SteamLibrary"
}`
	got = parseLibraryFolders([]byte(legacy))
	if !slices.Equal(got, []string{"/mnt/games/SteamLibrary"}) {
		t.Fatalf("legacy: got %v", got)
	}

	escaped := `"path"		"D:\\SteamLibrary"`
	got = parseLibraryFolders([]byte(escaped))
	if !slices.Equal(got, []string{`D:\SteamLibrary`}) {
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
	sum := sha256.Sum256(payload)
	srv := servePayload(t, payload)
	win64, res := installFrom(t, srv, installOptions{UE4SSSHA256: hex.EncodeToString(sum[:])})

	if step := stepOf(res, "UE4SS"); step == nil || !step.OK {
		t.Fatalf("UE4SS step should succeed: %+v", res)
	}
	if !fileExists(filepath.Join(win64, "UE4SS.dll")) {
		t.Fatal("UE4SS.dll was not extracted")
	}
}

// TestInstallRejectsBadUE4SSHash: the archive drops a DLL the game loads, so a
// body that does not match the pin must never reach extraction.
func TestInstallRejectsBadUE4SSHash(t *testing.T) {
	srv := servePayload(t, zipBytes(t, map[string]string{"dwmapi.dll": "a"}))
	win64, res := installFrom(t, srv, installOptions{UE4SSSHA256: strings.Repeat("00", 32)})

	if step := stepOf(res, "UE4SS"); step == nil || step.OK {
		t.Fatalf("UE4SS must fail on a hash mismatch: %+v", res)
	}
	if fileExists(filepath.Join(win64, "dwmapi.dll")) {
		t.Fatal("a bad-hash archive must not be extracted")
	}
}

// TestInstallRejectsOversizeUE4SS: the download is size-capped before hashing.
func TestInstallRejectsOversizeUE4SS(t *testing.T) {
	payload := zipBytes(t, map[string]string{"dwmapi.dll": strings.Repeat("a", 128)})
	sum := sha256.Sum256(payload)
	srv := servePayload(t, payload)
	_, res := installFrom(t, srv, installOptions{
		UE4SSSHA256: hex.EncodeToString(sum[:]), UE4SSMaxBytes: 16})

	if step := stepOf(res, "UE4SS"); step == nil || step.OK {
		t.Fatalf("UE4SS must fail on an oversize download: %+v", res)
	}
}

// servePayload serves payload over a test HTTP server for the installer.
func servePayload(t *testing.T, payload []byte) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/zip")
		_, _ = w.Write(payload)
	}))
	t.Cleanup(srv.Close)
	return srv
}

// installFrom downloads UE4SS from srv into a fresh Win64 folder, returning
// that folder and the install steps.
func installFrom(t *testing.T, srv *httptest.Server, opts installOptions) (string, []installResult) {
	t.Helper()
	root := t.TempDir()
	win64 := filepath.Join(root, "win64")
	if err := os.MkdirAll(win64, 0755); err != nil {
		t.Fatal(err)
	}
	opts.UE4SSURL, opts.HTTPClient = srv.URL, srv.Client()
	return win64, Install(Paths{ConfigDir: filepath.Join(root, "bridge"), GameWin64: win64}, "", opts)
}

// stepOf returns the named install step, or nil.
func stepOf(res []installResult, name string) *installResult {
	for i := range res {
		if res[i].Step == name {
			return &res[i]
		}
	}
	return nil
}

// TestInstallEmptyPathsRefused: unresolved folders must be refused before any
// path is created (otherwise a relative default would land in the cwd).
func TestInstallEmptyPathsRefused(t *testing.T) {
	res := Install(Paths{}, "", installOptions{NoDownload: true})
	if len(res) != 1 || res[0].OK {
		t.Fatalf("empty paths must be a single failed step: %+v", res)
	}
}

// TestInstallMissingGameFolder: a Game folder that does not exist must fail
// loudly and stay uncreated, so a typo'd override cannot look like a clean
// install.
func TestInstallMissingGameFolder(t *testing.T) {
	root := t.TempDir()
	win64 := filepath.Join(root, "no-such-win64")

	res := Install(Paths{ConfigDir: filepath.Join(root, "bridge"), GameWin64: win64},
		"", installOptions{NoDownload: true})
	step := stepOf(res, "Game folder")
	if step == nil || step.OK {
		t.Fatalf("missing game folder must be a failed step: %+v", res)
	}
	if dirExists(win64) {
		t.Fatal("install must not create the missing game folder")
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
