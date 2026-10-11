// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-11

package main

import (
	"runtime"
	"strings"
	"testing"
)

// TestDefaultPathsResolves is a smoke test for the current host OS: every field
// must be non-empty and land in a plausible place. Cross-OS resolution is
// exercised by reading the branches, not by faking runtime.GOOS.
func TestDefaultPathsResolves(t *testing.T) {
	p := defaultPaths()
	if p.ConfigDir == "" || p.GameWin64 == "" {
		t.Fatalf("empty path field: %+v", p)
	}
	if !strings.Contains(p.GameWin64, "Win64") {
		t.Errorf("GameWin64 should contain Win64: %s", p.GameWin64)
	}
	switch runtime.GOOS {
	case "windows":
		if !strings.Contains(p.ConfigDir, "srtap_bridge") {
			t.Errorf("windows ConfigDir: %s", p.ConfigDir)
		}
	default:
		if !strings.Contains(p.ConfigDir, "compatdata") || !strings.Contains(p.ConfigDir, appID) {
			t.Errorf("linux ConfigDir should be in the Proton prefix: %s", p.ConfigDir)
		}
	}
}
