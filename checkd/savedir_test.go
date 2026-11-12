// Author: Tim Harrison
// Created: 2026-10-12
// Updated: 2026-10-12

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestDefaultSaveDirUsesLocalAppData: a set %LOCALAPPDATA% wins, so a native
// Windows install looks under the player's own profile, not the Proton
// prefix's steamuser home.
func TestDefaultSaveDirUsesLocalAppData(t *testing.T) {
	local := `C:\Users\Player\AppData\Local`
	t.Setenv("LOCALAPPDATA", local)
	want := filepath.Join(local, "Falcon", "Saved", "SaveGames")
	if got := defaultSaveDir(); got != want {
		t.Fatalf("defaultSaveDir() = %q, want %q", got, want)
	}
}

// TestDefaultSaveDirFallsBackToProton: with no %LOCALAPPDATA% the legacy
// Proton prefix path is kept.
func TestDefaultSaveDirFallsBackToProton(t *testing.T) {
	t.Setenv("LOCALAPPDATA", "")
	if got := defaultSaveDir(); got != filepath.FromSlash(protonSaveDir) {
		t.Fatalf("defaultSaveDir() = %q, want %q", got, protonSaveDir)
	}
}

// TestSaveDirUnderPrefersNewestProfile: the Wine profile whose saves are newest
// is chosen over the others under the same drive.
func TestSaveDirUnderPrefersNewestProfile(t *testing.T) {
	base := t.TempDir()
	now := time.Now()
	seedWineProfile(t, base, "steamuser", now.Add(-time.Hour))
	want := seedWineProfile(t, base, "player", now)

	if got := saveDirUnder(base); got != want {
		t.Fatalf("saveDirUnder() = %q, want %q", got, want)
	}
}

// TestSaveDirUnderFallsBackWithoutSaves: a drive with no FalconSave file keeps
// the legacy steamuser path.
func TestSaveDirUnderFallsBackWithoutSaves(t *testing.T) {
	base := t.TempDir()
	empty := filepath.Join(base, "users", "steamuser", "AppData", "Local", "Falcon", "Saved", "SaveGames")
	if err := os.MkdirAll(empty, 0755); err != nil {
		t.Fatalf("mkdir %s: %v", empty, err)
	}

	if got := saveDirUnder(base); got != filepath.FromSlash(protonSaveDir) {
		t.Fatalf("saveDirUnder() = %q, want %q", got, protonSaveDir)
	}
}

// seedWineProfile creates a Wine user profile under base holding one save file
// with the given modification time, and returns its save folder.
func seedWineProfile(t *testing.T, base, user string, mod time.Time) string {
	t.Helper()
	dir := filepath.Join(base, "users", user, "AppData", "Local", "Falcon", "Saved", "SaveGames")
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatalf("mkdir %s: %v", dir, err)
	}
	path := filepath.Join(dir, "FalconSave.0.sav")
	if err := os.WriteFile(path, []byte("save"), 0644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
	if err := os.Chtimes(path, mod, mod); err != nil {
		t.Fatalf("chtimes %s: %v", path, err)
	}
	return dir
}

// TestDaemonWarnsWhenSaveMissing: with a session open but no FalconSave.*.sav
// in the save dir, the daemon must say so (once per session) instead of
// failing silently, and re-arm the warning when a new session opens.
func TestDaemonWarnsWhenSaveMissing(t *testing.T) {
	var logs []string
	d := testDaemon(t, false)
	d.logf = func(f string, a ...any) { logs = append(logs, fmt.Sprintf(f, a...)) }
	d.saveDir = t.TempDir()

	d.pollOnce()
	d.pollOnce()
	warns := 0
	for _, l := range logs {
		if strings.Contains(l, "no FalconSave.*.sav found") {
			warns++
			if !strings.Contains(l, d.saveDir) {
				t.Fatalf("warning must name the save dir %q: %q", d.saveDir, l)
			}
		}
	}
	if warns != 1 {
		t.Fatalf("missing save must warn once, got %d: %v", warns, logs)
	}

	// a new session resets the dedup, so the warning fires again
	logs = nil
	writeSession(t, d, "slot=0\ngame=0\ntoken=t2\n")
	d.pollOnce()
	warns = 0
	for _, l := range logs {
		if strings.Contains(l, "no FalconSave.*.sav found") {
			warns++
		}
	}
	if warns != 1 {
		t.Fatalf("new session must re-arm the warning, got %d: %v", warns, logs)
	}
}
