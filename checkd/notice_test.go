// Author: Tim Harrison
// Created: 2026-10-15

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func noticePath(d *daemon) string {
	return filepath.Join(d.dropDir, noticeName)
}

func readNotice(t *testing.T, d *daemon) string {
	t.Helper()
	b, err := os.ReadFile(noticePath(d))
	if err != nil {
		t.Fatalf("read notice: %v", err)
	}
	var p noticePayload
	if err := json.Unmarshal(b, &p); err != nil {
		t.Fatalf("notice is not valid JSON: %v", err)
	}
	return p.Text
}

// TestSetNoticeWritesOnChangeOnly pins the notice as a state: nothing is
// written until there is a notice, the same text is never rewritten, and
// clearing writes an empty text.
func TestSetNoticeWritesOnChangeOnly(t *testing.T) {
	d := testDaemon(t, true)
	d.saveDir = t.TempDir()

	if _, err := os.Stat(noticePath(d)); !os.IsNotExist(err) {
		t.Fatalf("notice exists before any notice, err=%v", err)
	}
	d.setNotice(noticeSaveScanFailed)
	if got := readNotice(t, d); got != noticeSaveScanFailed {
		t.Fatalf("notice = %q, want %q", got, noticeSaveScanFailed)
	}

	old := time.Unix(1000000, 0)
	if err := os.Chtimes(noticePath(d), old, old); err != nil {
		t.Fatal(err)
	}
	d.setNotice(noticeSaveScanFailed) // unchanged text: must not rewrite
	fi, err := os.Stat(noticePath(d))
	if err != nil {
		t.Fatal(err)
	}
	if !fi.ModTime().Equal(old) {
		t.Fatal("an unchanged notice was rewritten")
	}

	d.setNotice("")
	if got := readNotice(t, d); got != "" {
		t.Fatalf("notice = %q, want it cleared", got)
	}
}

// TestDaemonNoticesBrokenSaveLayout: a save whose levelObjectMap count is not 9
// never yields an entry, so checkd sends nothing at all. After noticeLayoutErrs
// rewrites the player is told; a readable save clears the notice again.
func TestDaemonNoticesBrokenSaveLayout(t *testing.T) {
	d := testDaemon(t, true)
	d.saveDir = t.TempDir()
	path := filepath.Join(d.saveDir, "FalconSave.1.sav")

	for i := 0; i < noticeLayoutErrs; i++ {
		stampSave(t, path, []byte("GVAS levelObjectMap only one"))
		d.pollOnce()
	}
	if got := readNotice(t, d); got != noticeSaveScanFailed {
		t.Fatalf("notice = %q, want %q", got, noticeSaveScanFailed)
	}

	stampSave(t, path, loadSave(t, "snapshot1"))
	d.pollOnce()
	if got := readNotice(t, d); got != "" {
		t.Fatalf("notice = %q after a readable save, want it cleared", got)
	}
}
