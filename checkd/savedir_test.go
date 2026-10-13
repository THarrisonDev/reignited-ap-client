// Author: Tim Harrison
// Created: 2026-10-12
// Updated: 2026-10-12

package main

import (
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

// TestDefaultSaveDirUsesLocalAppData: a set %LOCALAPPDATA% wins, so a native
// Windows install looks under the player's own profile, not the Proton
// prefix's steamuser home.
func TestDefaultSaveDirUsesLocalAppData(t *testing.T) {
	local := `C:\Users\Flurry\AppData\Local`
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
	if got := defaultSaveDir(); got != protonSaveDir {
		t.Fatalf("defaultSaveDir() = %q, want %q", got, protonSaveDir)
	}
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
