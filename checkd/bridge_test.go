// Author: Tim Harrison
// Created: 2026-11-09

package main

import (
	"os"
	"path/filepath"
	"testing"
)

// TestDefaultDropDirUsesLocalAppData: with %LOCALAPPDATA% set and no bridge
// files anywhere yet, the modern folder is selected.
func TestDefaultDropDirUsesLocalAppData(t *testing.T) {
	local := t.TempDir()
	t.Setenv("LOCALAPPDATA", local)
	want := filepath.Join(local, "srtap_bridge")

	if got := defaultDropDir(); got != want {
		t.Fatalf("defaultDropDir() = %q, want %q", got, want)
	}
}

// TestDefaultDropDirWithoutLocalAppData: without %LOCALAPPDATA% there is no
// modern candidate, so the legacy folder is selected.
func TestDefaultDropDirWithoutLocalAppData(t *testing.T) {
	t.Setenv("LOCALAPPDATA", "")

	if got := defaultDropDir(); got != legacyBridgeDir {
		t.Fatalf("defaultDropDir() = %q, want %q", got, legacyBridgeDir)
	}
}

// TestDefaultDropDirKeepsNewWithBridgeFiles: a modern folder that already holds
// a bridge file is selected.
func TestDefaultDropDirKeepsNewWithBridgeFiles(t *testing.T) {
	local := t.TempDir()
	t.Setenv("LOCALAPPDATA", local)
	bridge := filepath.Join(local, "srtap_bridge")
	writeBridgeFile(t, bridge, "config.txt")

	if got := defaultDropDir(); got != bridge {
		t.Fatalf("defaultDropDir() = %q, want %q", got, bridge)
	}
}

// TestSelectBridgePrefersLegacyBinary: an existing legacy install is kept when
// the modern folder has no bridge file. The legacy path is a fixed constant, so
// the rule is exercised directly.
func TestSelectBridgePrefersLegacyBinary(t *testing.T) {
	root := t.TempDir()
	newDir := filepath.Join(root, "new")
	legacyDir := filepath.Join(root, "legacy")
	writeBridgeFile(t, legacyDir, "srtap_checkd.exe")

	if got := selectBridge(newDir, legacyDir); got != legacyDir {
		t.Fatalf("selectBridge() = %q, want %q", got, legacyDir)
	}
}

// TestSelectBridgePrefersNewWhenBothHaveFiles: once both folders hold a bridge
// file, the modern folder wins.
func TestSelectBridgePrefersNewWhenBothHaveFiles(t *testing.T) {
	root := t.TempDir()
	newDir := filepath.Join(root, "new")
	legacyDir := filepath.Join(root, "legacy")
	writeBridgeFile(t, newDir, "config.txt")
	writeBridgeFile(t, legacyDir, "config.txt")

	if got := selectBridge(newDir, legacyDir); got != newDir {
		t.Fatalf("selectBridge() = %q, want %q", got, newDir)
	}
}

// TestSelectBridgePrefersNewWhenNeitherHasFiles: a fresh install selects the
// modern folder.
func TestSelectBridgePrefersNewWhenNeitherHasFiles(t *testing.T) {
	root := t.TempDir()

	if got := selectBridge(filepath.Join(root, "new"), filepath.Join(root, "legacy")); got != filepath.Join(root, "new") {
		t.Fatalf("selectBridge() = %q, want %q", got, filepath.Join(root, "new"))
	}
}

// TestDefaultLogPathFollowsSelectedBridge: the log lives beside the bridge
// folder the selection rule picked.
func TestDefaultLogPathFollowsSelectedBridge(t *testing.T) {
	local := t.TempDir()
	t.Setenv("LOCALAPPDATA", local)
	bridge := filepath.Join(local, "srtap_bridge")
	want := filepath.Join(bridge, "checkd.log")

	if got := defaultLogPath(); got != want {
		t.Fatalf("defaultLogPath() = %q, want %q", got, want)
	}

	t.Setenv("LOCALAPPDATA", "")
	want = filepath.Join(legacyBridgeDir, "checkd.log")
	if got := defaultLogPath(); got != want {
		t.Fatalf("defaultLogPath() without LOCALAPPDATA = %q, want %q", got, want)
	}
}

// writeBridgeFile creates dir and an empty file named name inside it.
func writeBridgeFile(t *testing.T, dir, name string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatalf("mkdir %s: %v", dir, err)
	}
	if err := os.WriteFile(filepath.Join(dir, name), nil, 0644); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
}
