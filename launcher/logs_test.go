// Author: Tim Harrison
// Created: 2026-11-01
// Updated: 2026-11-01

package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// writeCollector writes an executable fake collector into dir.
func writeCollector(t *testing.T, dir, body string) {
	t.Helper()
	path := filepath.Join(dir, "collect-logs.sh")
	if err := os.WriteFile(path, []byte(body), 0755); err != nil {
		t.Fatal(err)
	}
}

// handleLogsRequest runs the handler against a fresh recorder.
func handleLogsRequest(s *server) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	s.handleLogs(rec, httptest.NewRequest("GET", "/logs.zip", nil))
	return rec
}

func TestHandleLogsServesTheArchive(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the fake collector is a sh script")
	}
	dir := t.TempDir()
	writeCollector(t, dir, "#!/bin/sh\nprintf 'PK-not-a-real-zip' > \"$2\"\n")
	s := &server{collectorDir: dir, paths: Paths{}}

	rec := handleLogsRequest(s)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (%s)", rec.Code, rec.Body.String())
	}
	if got := rec.Header().Get("Content-Type"); got != "application/zip" {
		t.Errorf("Content-Type = %q, want application/zip", got)
	}
	disposition := rec.Header().Get("Content-Disposition")
	if !strings.Contains(disposition, "attachment") || !strings.Contains(disposition, ".zip") {
		t.Errorf("Content-Disposition = %q, want an attachment .zip", disposition)
	}
	if got := rec.Body.String(); got != "PK-not-a-real-zip" {
		t.Errorf("body = %q, want the collector's archive bytes", got)
	}
}

func TestHandleLogsMissingCollector(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the fake collector is a sh script")
	}
	s := &server{collectorDir: t.TempDir(), paths: Paths{}}

	rec := handleLogsRequest(s)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "collect-logs.sh") {
		t.Errorf("body = %q, want it to name the script", rec.Body.String())
	}
}

func TestHandleLogsCollectorFailure(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the fake collector is a sh script")
	}
	dir := t.TempDir()
	writeCollector(t, dir, "#!/bin/sh\necho boom >&2\nexit 1\n")
	s := &server{collectorDir: dir, paths: Paths{}}

	rec := handleLogsRequest(s)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "boom") {
		t.Errorf("body = %q, want the collector's output", rec.Body.String())
	}
}
