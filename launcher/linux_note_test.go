// Author: Tim Harrison
// Created: 2026-11-11
// Updated: 2026-11-11

package main

import (
	"net/http/httptest"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// TestRootShowsLaunchOptionNote pins the Linux launch option: every Linux player
// is told to set it, so the note never asks them to work out which Proton they run.
func TestRootShowsLaunchOptionNote(t *testing.T) {
	useStateFile(t, filepath.Join(t.TempDir(), "paths.json"))
	s := testServer(t, Paths{ConfigDir: t.TempDir(), GameWin64: t.TempDir()})

	rec := httptest.NewRecorder()
	s.handleRoot(rec, httptest.NewRequest("GET", "/", nil))
	body := rec.Body.String()

	want := `WINEDLLOVERRIDES="dwmapi=n,b" %command%`
	if runtime.GOOS == "windows" {
		if strings.Contains(body, want) {
			t.Fatal("the Proton launch option must stay off the Windows page")
		}
		return
	}
	if !strings.Contains(body, want) {
		t.Fatalf("page is missing %q from the launch-option note", want)
	}
}
