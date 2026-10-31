// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-23

package main

import (
	"bytes"
	"path/filepath"
	"testing"
)

func TestScanS2BossesMatchesGolden(t *testing.T) {
	for _, stem := range allFixtureStems {
		got, stats := ScanS2Bosses(loadSave(t, stem))
		expectNamedGolden(t, stem, "boss", got, stats, namedGolden(t, stem, ".bosses.golden.json", "bosses"))
	}
}

// TestScanS2Bosses100pct is the fixture-level unit test: the 100% Spyro 2
// entry holds exactly three collected boss records, one per boss level, each
// named by the region-fixed event name and resolving through the init-built
// spyro2Locations table to its locations.json id.
func TestScanS2Bosses100pct(t *testing.T) {
	data := loadSave(t, "100pct_ref")
	entry := mustEntry(t, data, entryIndex(0, 1))
	bosses, stats := ScanS2Bosses(entry)
	want := []Dragon{
		{Region: "Crush's Dungeon", Name: "Crush Defeated", Collected: true},
		{Region: "Gulp's Overlook", Name: "Gulp Defeated", Collected: true},
		{Region: "Ripto's Arena", Name: "Ripto Defeated", Collected: true},
	}
	if len(bosses) != len(want) {
		t.Fatalf("ScanS2Bosses found %d records (stats %+v), want %d", len(bosses), stats, len(want))
	}
	nameToID := nameToIDForTest(t)
	for i, w := range want {
		if bosses[i] != w {
			t.Fatalf("boss %d = %+v, want %+v", i, bosses[i], w)
		}
		loc, ok := spyro2Locations[checkKey{"boss", w.Region, w.Name}]
		if !ok {
			t.Fatalf("boss %v missing from the init-built table", w)
		}
		id, ok := nameToID[loc]
		if !ok {
			t.Fatalf("location %q not in nameToID", loc)
		}
		wantID := map[string]int{
			"Spyro 2: Crush's Dungeon: Crush Defeated": 207000,
			"Spyro 2: Gulp's Overlook: Gulp Defeated":  218000,
			"Spyro 2: Ripto's Arena: Ripto Defeated":   226000,
		}[loc]
		if id != wantID {
			t.Fatalf("location %q id = %d, want %d", loc, id, wantID)
		}
	}
	// the Spyro 1 entry holds no boss records (the types are game-scoped)
	s1 := mustEntry(t, data, entryIndex(0, 0))
	if s1b, _ := ScanS2Bosses(s1); len(s1b) != 0 {
		t.Fatalf("Spyro 1 entry holds boss records: %+v", s1b)
	}
	t.Log("100pct_ref: 3 collected boss records in the boss regions, ids 207000/218000/226000: OK")
}

// TestSpyro3BossKeys pins the init-built spyro3Locations shape for the four
// Spyro 3 boss rows: a Spyro 3 boss kill saves as the boss dungeon's named egg
// record (ScanS3Eggs emits the egg param as an "egg" check), so the row
// registers the event-name "boss" key AND the egg-param "egg" alias; both
// resolve to the boss location and its locations.json id.
func TestSpyro3BossKeys(t *testing.T) {
	nameToID := nameToIDForTest(t)
	for _, w := range []struct {
		region, saveKey, name string
		id                    int
	}{
		{"Buzz's Dungeon", "Grayson", "Buzz Defeated", 307000},
		{"Spike's Arena", "Monique", "Spike Defeated", 316000},
		{"Scorch's Pit", "James", "Scorch Defeated", 325000},
		{"Sorceress Lair", "George", "Sorceress Defeated", 334000},
	} {
		for _, k := range []checkKey{{"boss", w.region, w.name}, {"egg", w.region, w.saveKey}} {
			loc, ok := spyro3Locations[k]
			if !ok {
				t.Fatalf("key %+v missing from the init-built table", k)
			}
			if loc != "Spyro 3: "+w.region+": "+w.name {
				t.Fatalf("key %+v resolved to %q, want %q", k, loc, "Spyro 3: "+w.region+": "+w.name)
			}
			if id, ok := nameToID[loc]; !ok || id != w.id {
				t.Fatalf("location %q id = %d (present %t), want %d", loc, id, ok, w.id)
			}
		}
	}
	t.Log("4 S3 boss rows registered under both keys, all resolving to 307000/316000/325000/334000: OK")
}

// TestScanS2BossesFlip mutates 100pct_ref's first boss record (Crush's
// Dungeon, the earliest marker in the file) collected 1->0 and asserts the
// scan result follows: exactly the two other boss checks remain.
func TestScanS2BossesFlip(t *testing.T) {
	data := loadSave(t, "100pct_ref")
	bosses, stats := ScanS2Bosses(data)
	if len(bosses) != 3 {
		t.Fatalf("fixture precondition: %d boss records, want 3 (stats %+v)", len(bosses), stats)
	}
	m := bytes.Index(data, []byte(s2BossMarker))
	if m < 0 {
		t.Fatal("no boss marker in 100pct_ref")
	}
	valOff := mustCollectedOff(t, data, m)
	if data[valOff] != 1 {
		t.Fatalf("fixture precondition: boss value byte at %d must be 1", valOff)
	}
	mutated := append([]byte(nil), data...)
	mutated[valOff] = 0
	got, _ := ScanS2Bosses(mutated)
	if len(got) != 3 {
		t.Fatalf("flip changed record count: %d records, want 3", len(got))
	}
	for _, d := range got {
		want := d.Name != "Crush Defeated"
		if d.Collected != want {
			t.Fatalf("after the flip %v collected=%t, want %t", d, d.Collected, want)
		}
	}
	t.Log("Crush collected flip 1->0: record uncollected, Gulp/Ripto untouched: OK")
}

// TestDaemonBossFlipDrop drives the real pollOnce path: the 100% Spyro 2 save
// baselines everything (backfill), then a save with Ripto's collected byte
// flipped to 0 must send nothing new (a de-kill fires nothing), while
// flipping it back must re-send exactly the Ripto boss check.
func TestDaemonBossFlipDrop(t *testing.T) {
	d := testDaemon(t, true)
	d.saveDir = t.TempDir()

	data := loadSave(t, "100pct_ref")
	valOff := lastBossValueOff(t, data)
	if data[valOff] != 1 {
		t.Fatalf("fixture precondition: Ripto value byte at %d must be 1", valOff)
	}

	// de-kill: Ripto uncollected at first sight
	killed := append([]byte(nil), data...)
	killed[valOff] = 0
	writeSaveBytes(t, d, "FalconSave.106.sav", killed)
	writeSession(t, d, "slot=0\ngame=1\ntoken=s2boss\n")
	d.pollOnce()
	if d.drops != 1 {
		t.Fatalf("baseline must drop once, drops=%d", d.drops)
	}
	sent := nameSet(readDrop(t, d).Names)
	if sent["Spyro 2: Ripto's Arena: Ripto Defeated"] {
		t.Fatal("uncollected Ripto must not be in the baseline drop")
	}
	expectSent(t, sent, "Spyro 2: Crush's Dungeon: Crush Defeated", "Spyro 2: Gulp's Overlook: Gulp Defeated")
	baseDrops := d.drops

	// kill: re-collect Ripto, exactly one new check drops
	stampSave(t, filepath.Join(d.saveDir, "FalconSave.105.sav"), data)
	d.pollOnce()
	got := readDrop(t, d)
	if d.drops != baseDrops+1 {
		t.Fatalf("the kill must drop once, drops=%d (base %d)", d.drops, baseDrops)
	}
	expectDrop(t, got, map[string]int{"Spyro 2: Ripto's Arena: Ripto Defeated": 226000})

	// unchanged save: no re-drop
	d.lastPath = ""
	d.pollOnce()
	if d.drops != baseDrops+1 {
		t.Fatalf("already-sent boss check must not drop again, drops=%d", d.drops)
	}
}

// lastBossValueOff is the collected byte of the save's last Spyro 2 boss record
// (Ripto's Arena).
func lastBossValueOff(t *testing.T, data []byte) int {
	t.Helper()
	m := bytes.LastIndex(data, []byte(s2BossMarker))
	if m < 0 {
		t.Fatal("no boss marker in the save")
	}
	return mustCollectedOff(t, data, m)
}
