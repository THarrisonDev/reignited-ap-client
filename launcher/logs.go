// Author: Tim Harrison
// Created: 2026-11-01
// Updated: 2026-11-01

package main

import (
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
)

// handleLogs runs the standalone collector and serves the archive it wrote.
func (s *server) handleLogs(w http.ResponseWriter, r *http.Request) {
	name := "collect-logs.sh"
	if runtime.GOOS == "windows" {
		name = "collect-logs.bat"
	}
	script := filepath.Join(s.collectorDir, name)
	if _, err := os.Stat(script); err != nil {
		http.Error(w, "collect-logs.sh not found next to the launcher ("+s.collectorDir+")", http.StatusInternalServerError)
		return
	}
	tmp, err := os.MkdirTemp("", "srtap-logs-")
	if err != nil {
		http.Error(w, "collecting logs failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	defer func() { _ = os.RemoveAll(tmp) }()

	out := filepath.Join(tmp, "srtap-logs.zip")
	var cmd *exec.Cmd
	if runtime.GOOS == "windows" {
		cmd = exec.Command("cmd", "/c", script, "--out", out)
	} else {
		cmd = exec.Command("sh", script, "--out", out)
	}
	cmd.Dir = tmp
	combined, err := cmd.CombinedOutput()
	if err != nil {
		http.Error(w, "collecting logs failed: "+err.Error()+"\n"+string(combined), http.StatusInternalServerError)
		return
	}

	// The collector falls back to a .tar.gz when zip is not installed.
	final := out
	if _, err := os.Stat(final); err != nil {
		final = out + ".tar.gz"
	}
	f, err := os.Open(final)
	if err != nil {
		http.Error(w, "collecting logs failed: "+err.Error()+"\n"+string(combined), http.StatusInternalServerError)
		return
	}
	defer func() { _ = f.Close() }()
	info, err := f.Stat()
	if err != nil {
		http.Error(w, "collecting logs failed: "+err.Error(), http.StatusInternalServerError)
		return
	}

	kind := "application/zip"
	if filepath.Ext(final) != ".zip" {
		kind = "application/gzip"
	}
	w.Header().Set("Content-Type", kind)
	w.Header().Set("Content-Disposition", `attachment; filename="`+filepath.Base(final)+`"`)
	w.Header().Set("Content-Length", strconv.FormatInt(info.Size(), 10))
	_, _ = io.Copy(w, f)
}
