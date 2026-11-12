// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-11

package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
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

// findCheck returns the named check, or nil.
func findCheck(checks []Check, name string) *Check {
	for i := range checks {
		if checks[i].Name == name {
			return &checks[i]
		}
	}
	return nil
}

// TestVerifyBridgeFixDefersWithoutPrefix pins the deferred-install wording: on
// Linux with no Proton prefix the fix is to launch the game once, not to create
// the folder by hand.
func TestVerifyBridgeFixDefersWithoutPrefix(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Proton prefix wording")
	}
	root := t.TempDir()
	checks := Verify(Paths{
		ConfigDir: filepath.Join(root, "missing-bridge"),
		GameWin64: filepath.Join(root, "missing-win64"),
	})
	check := findCheck(checks, "Bridge folder")
	if check == nil || check.OK {
		t.Fatalf("missing bridge folder must fail: %+v", check)
	}
	if !strings.Contains(check.Fix, "Launch the game once through Steam") {
		t.Fatalf("fix should defer to the prefix: %s", check.Fix)
	}
}

// removeFiles deletes each path, failing the test on error.
func removeFiles(t *testing.T, paths ...string) {
	t.Helper()
	for _, p := range paths {
		if err := os.Remove(p); err != nil {
			t.Fatal(err)
		}
	}
}

// bridgeMatchCheck returns the bridge-matching check for p, failing the test
// when the check is absent.
func bridgeMatchCheck(t *testing.T, p Paths) Check {
	t.Helper()
	check := findCheck(Verify(p), "Bridge folder matches the game")
	if check == nil {
		t.Fatalf("the bridge-matching check is missing for %+v", p)
	}
	return *check
}

// TestVerifyBridgeMatchesGameFires: a temp prefix with a newer bridge.log than
// the selected folder must be reported, naming the folder to switch to.
func TestVerifyBridgeMatchesGameFires(t *testing.T) {
	home, root := steamTree(t)
	libA := filepath.Join(home, "LibraryA")
	libB := filepath.Join(home, "LibraryB")
	listLibraries(t, root, libA, libB)

	bridgeA := bridgeIn(t, prefixTree(t, libA))
	mkfile(t, filepath.Join(bridgeA, "config.txt"))
	logA := filepath.Join(bridgeA, "bridge.log")
	mkfile(t, logA)
	setMtime(t, logA, 1000)

	bridgeB := bridgeIn(t, prefixTree(t, libB))
	mkfile(t, filepath.Join(bridgeB, "config.txt"))
	logB := filepath.Join(bridgeB, "bridge.log")
	mkfile(t, logB)
	setMtime(t, logB, 5000)

	p := Paths{ConfigDir: bridgeA, GameWin64: filepath.Join(libA, gameRel()), PrefixReady: true}
	check := bridgeMatchCheck(t, p)
	if check.OK {
		t.Fatalf("a newer bridge.log elsewhere must fail the check: %+v", check)
	}
	if !strings.Contains(check.Detail, bridgeB) {
		t.Fatalf("detail should name %s: %s", bridgeB, check.Detail)
	}
	if !strings.Contains(check.Fix, "Set the Bridge folder to "+bridgeB) {
		t.Fatalf("fix should name the folder to select: %s", check.Fix)
	}

	p.ConfigDir = bridgeB
	if check := bridgeMatchCheck(t, p); !check.OK {
		t.Fatalf("the newest bridge folder must pass: %+v", check)
	}

	removeFiles(t, logA, logB)
	if check := bridgeMatchCheck(t, p); !check.OK {
		t.Fatalf("no bridge log anywhere must pass: %+v", check)
	}
}

// TestVerifyBridgeMismatchSkippedOutsidePrefix: an unrelated temp layout must
// never trigger Steam discovery, even with PrefixReady set.
func TestVerifyBridgeMismatchSkippedOutsidePrefix(t *testing.T) {
	p := fullLayout(t)
	p.PrefixReady = true
	if check := findCheck(Verify(p), "Bridge folder matches the game"); check != nil {
		t.Fatalf("the check must not run outside a Proton prefix: %+v", check)
	}
}

// TestVerifyGameFolderWritable pins the new permission check on the game folder.
func TestVerifyGameFolderWritable(t *testing.T) {
	p := fullLayout(t)
	if check := findCheck(Verify(p), "Game folder writable"); check == nil || !check.OK {
		t.Fatalf("a writable game folder must pass: %+v", check)
	}

	readOnly := filepath.Join(t.TempDir(), "win64")
	if err := os.MkdirAll(readOnly, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(readOnly, 0555); err != nil {
		t.Skipf("cannot make the folder read-only: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(readOnly, 0755) })
	if probeWritable(readOnly) == nil {
		t.Skip("the folder is still writable (running as root)")
	}
	p.GameWin64 = readOnly
	check := findCheck(Verify(p), "Game folder writable")
	if check == nil || check.OK {
		t.Fatalf("an unwritable game folder must fail: %+v", check)
	}
	if !strings.Contains(check.Fix, "administrator") {
		t.Fatalf("fix should name the likely cause: %s", check.Fix)
	}
}
