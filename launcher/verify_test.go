// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-11

package main

import (
	"os"
	"path/filepath"
	"testing"
)

// mkfile creates a file (and parents) with placeholder content.
func mkfile(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("x"), 0644); err != nil {
		t.Fatal(err)
	}
}

// fullLayout builds a temp dir tree that passes every check and returns Paths.
func fullLayout(t *testing.T) Paths {
	t.Helper()
	root := t.TempDir()
	cfg := filepath.Join(root, "srtap_bridge")
	win64 := filepath.Join(root, "game", "Falcon", "Binaries", "Win64")
	mkfile(t, filepath.Join(cfg, "srtap_checkd.exe"))
	mkfile(t, filepath.Join(win64, "dwmapi.dll"))
	mkfile(t, filepath.Join(win64, "UE4SS.dll"))
	mkfile(t, filepath.Join(win64, "Mods", "srt_bridge", "Scripts", "main.lua"))
	mkfile(t, filepath.Join(win64, "Mods", "srt_bridge", "Scripts", "lua-apclientpp.dll"))
	if err := os.WriteFile(filepath.Join(win64, "Mods", "mods.txt"),
		[]byte("; comment\nsrt_bridge : 1\nother_mod : 0\n"), 0644); err != nil {
		t.Fatal(err)
	}
	return Paths{ConfigDir: cfg, GameWin64: win64}
}

func TestVerifyFullLayoutAllOK(t *testing.T) {
	checks := Verify(fullLayout(t))
	if !AllOK(checks) {
		for _, c := range checks {
			if !c.OK {
				t.Errorf("check %q failed: detail=%s", c.Name, c.Detail)
			}
		}
		t.Fatal("expected all checks OK for a full layout")
	}
}

func TestVerifyEmptyLayoutAllFail(t *testing.T) {
	root := t.TempDir()
	checks := Verify(Paths{
		ConfigDir: filepath.Join(root, "nope-cfg"),
		GameWin64: filepath.Join(root, "nope-win64"),
	})
	if AllOK(checks) {
		t.Fatal("expected failures for an empty layout")
	}
	// every check should carry actionable Fix text
	for _, c := range checks {
		if !c.OK && c.Fix == "" {
			t.Errorf("failing check %q has no Fix guidance", c.Name)
		}
	}
}

func TestModEnabled(t *testing.T) {
	dir := t.TempDir()
	write := func(content string) string {
		p := filepath.Join(dir, "mods.txt")
		if err := os.WriteFile(p, []byte(content), 0644); err != nil {
			t.Fatal(err)
		}
		return p
	}
	cases := []struct {
		name          string
		content       string
		enabled, seen bool
	}{
		{"enabled", "srt_bridge : 1\n", true, true},
		{"disabled", "srt_bridge : 0\n", false, true},
		{"commented", "; srt_bridge : 1\n", false, false},
		{"absent", "other : 1\n", false, false},
		{"spacing", "  srt_bridge   :   1  \n", true, true},
	}
	for _, c := range cases {
		enabled, seen := modEnabled(write(c.content))
		if enabled != c.enabled || seen != c.seen {
			t.Errorf("%s: got (enabled=%v seen=%v), want (%v %v)", c.name, enabled, seen, c.enabled, c.seen)
		}
	}
	if _, seen := modEnabled(filepath.Join(dir, "missing.txt")); seen {
		t.Error("missing mods.txt must report not-found")
	}
}
