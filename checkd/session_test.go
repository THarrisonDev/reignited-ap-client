// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-11

package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestReadSession(t *testing.T) {
	dir := t.TempDir()
	cases := []struct {
		name    string
		content string // "" => don't write the file (missing-file case)
		want    session
		ok      bool
	}{
		{"valid", "slot=1\ngame=0\ntoken=abc\n", session{1, 0, "abc"}, true},
		{"whitespace", "  slot = 2 \n game=0\n", session{2, 0, ""}, true},
		{"missing game", "slot=1\n", session{}, false},
		{"slot out of range", "slot=3\ngame=0\n", session{}, false},
		{"game out of range", "slot=0\ngame=3\n", session{}, false},
		{"non-numeric", "slot=x\ngame=0\n", session{}, false},
		{"missing file", "", session{}, false},
	}
	for _, c := range cases {
		p := filepath.Join(dir, c.name+".txt")
		if c.content != "" {
			if err := os.WriteFile(p, []byte(c.content), 0644); err != nil {
				t.Fatal(err)
			}
		}
		got, ok := readSession(p)
		if ok != c.ok || got != c.want {
			t.Fatalf("%s: got %+v ok=%v, want %+v ok=%v", c.name, got, ok, c.want, c.ok)
		}
	}
}

func TestEntryIndexGameMajor(t *testing.T) {
	cases := []struct{ slot, game, want int }{{0, 0, 0}, {1, 0, 1}, {2, 0, 2}, {0, 1, 3}, {2, 2, 8}}
	for _, c := range cases {
		if got := entryIndex(c.slot, c.game); got != c.want {
			t.Fatalf("entryIndex(%d, %d) = %d, want %d", c.slot, c.game, got, c.want)
		}
	}
}

// TestSaveEntryScopesFixtures: every fixture's playthrough is entry 0, so
// scanning that entry alone matches the whole-file scan, and the other eight
// entries hold nothing to send.
func TestSaveEntryScopesFixtures(t *testing.T) {
	for _, stem := range fixtureStems[:4] {
		data := loadSave(t, stem)
		checkEntryZero(t, stem, data)
		checkOtherEntriesEmpty(t, stem, data)
	}
}

// checkEntryZero asserts scanning entry 0 matches the whole-file scan.
func checkEntryZero(t *testing.T, stem string, data []byte) {
	t.Helper()
	entry, ok := saveEntry(data, 0)
	if !ok {
		t.Fatalf("%s: no entry 0", stem)
	}
	wantDragons, _ := ScanSave(data)
	gotDragons, _ := ScanSave(entry)
	wantEggs, _ := ScanEggs(data)
	gotEggs, _ := ScanEggs(entry)
	wantGems, _ := ScanGems(data)
	gotGems, _ := ScanGems(entry)
	if !reflect.DeepEqual(gotDragons, wantDragons) || !reflect.DeepEqual(gotEggs, wantEggs) ||
		!reflect.DeepEqual(gotGems, wantGems) {
		t.Fatalf("%s: entry 0 scan differs from the whole-file scan", stem)
	}
}

// checkOtherEntriesEmpty asserts entries 1..8 hold nothing to send.
func checkOtherEntriesEmpty(t *testing.T, stem string, data []byte) {
	t.Helper()
	for idx := 1; idx < saveEntries; idx++ {
		other, ok := saveEntry(data, idx)
		if !ok {
			t.Fatalf("%s: no entry %d", stem, idx)
		}
		dragons, _ := ScanSave(other)
		eggs, _ := ScanEggs(other)
		gems, _ := ScanGems(other)
		if len(dragons) != 0 || len(eggs) != 0 || len(gems) != 0 {
			t.Fatalf("%s entry %d: want nothing, got %d dragons %d eggs %d gem regions",
				stem, idx, len(dragons), len(eggs), len(gems))
		}
	}
}

func TestSaveEntryRejectsUnknownLayout(t *testing.T) {
	data := loadSave(t, "snapshot1")
	if _, ok := saveEntry(data, saveEntries); ok {
		t.Fatal("index past the last entry must fail")
	}
	if _, ok := saveEntry(data, -1); ok {
		t.Fatal("negative index must fail")
	}
	if _, ok := saveEntry([]byte("GVAS levelObjectMap only one"), 0); ok {
		t.Fatal("a blob without nine entries must fail")
	}
}

// TestDaemonIdleWithoutSession: at the main menu (no session file) a
// progressed save sends nothing.
func TestDaemonIdleWithoutSession(t *testing.T) {
	d := testDaemon(t, true)
	d.saveDir = t.TempDir()
	if err := os.Remove(filepath.Join(d.dropDir, sessionName)); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(d.saveDir, "FalconSave.106.sav"), loadSave(t, "snapshot2"), 0644); err != nil {
		t.Fatal(err)
	}
	d.pollOnce()
	if d.drops != 0 {
		t.Fatalf("no session must drop nothing, drops=%d", d.drops)
	}
	if _, err := os.Stat(filepath.Join(d.dropDir, dropName)); !os.IsNotExist(err) {
		t.Fatalf("no session must not write checks.json, err=%v", err)
	}
}

// TestDaemonSessionSwitches: reopening the same save re-baselines (and so
// re-sends its backfill), picking an empty slot sends nothing, and closing the
// session goes idle.
func TestDaemonSessionSwitches(t *testing.T) {
	d := testDaemon(t, true)
	d.saveDir = t.TempDir()
	if err := os.WriteFile(filepath.Join(d.saveDir, "FalconSave.106.sav"), loadSave(t, "snapshot2"), 0644); err != nil {
		t.Fatal(err)
	}
	backfill := func() map[string]int {
		return map[string]int{
			"Spyro 1: Artisans: Free Nestor": 100000,
			"Spyro 1: Artisans: Free Tomas":  100002,
			"Spyro 1: Artisans: 25% Gems":    102010,
		}
	}

	d.pollOnce()
	expectDrop(t, readDrop(t, d), backfill())
	d.pollOnce()
	if d.drops != 1 {
		t.Fatalf("unchanged save must not drop again, drops=%d", d.drops)
	}

	writeSession(t, d, "slot=0\ngame=0\ntoken=t2\n")
	d.pollOnce()
	if d.drops != 2 {
		t.Fatalf("reopened save must re-baseline, drops=%d", d.drops)
	}
	expectDrop(t, readDrop(t, d), backfill())

	writeSession(t, d, "slot=1\ngame=0\ntoken=t3\n")
	d.pollOnce()
	if d.drops != 2 {
		t.Fatalf("an empty slot must drop nothing, drops=%d", d.drops)
	}

	if err := os.Remove(filepath.Join(d.dropDir, sessionName)); err != nil {
		t.Fatal(err)
	}
	d.pollOnce()
	if d.session != nil {
		t.Fatalf("closed session must go idle, session=%+v", d.session)
	}
}
