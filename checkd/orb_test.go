package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// mixed_s1_s2.sav is a synthetic save (gen_fixtures.py) holding a Spyro 1
// playthrough and a Spyro 2 one in save slot 1 (entry 4 = game 1, slot 1)
// with two Glimmer orbs.
const mixedSave = "testdata/mixed_s1_s2.sav"

func loadMixedSave(t *testing.T) []byte {
	t.Helper()
	b, err := os.ReadFile(mixedSave)
	if err != nil {
		t.Fatalf("read %s: %v", mixedSave, err)
	}
	return b
}

func TestScanOrbsMixedSave(t *testing.T) {
	data := loadMixedSave(t)
	entry, ok := saveEntry(data, entryIndex(1, 1))
	if !ok {
		t.Fatal("no Spyro 2 save entry")
	}
	orbs, stats := ScanOrbs(entry)
	want := map[string]bool{"Lizard hunt": true, "Gem Lamp Flight outdoors": true}
	if len(orbs) != len(want) {
		t.Fatalf("got orbs %+v (stats %+v), want %v", orbs, stats, want)
	}
	for _, o := range orbs {
		if o.Region != "Glimmer" || !want[o.Name] || !o.Collected {
			t.Fatalf("unexpected orb record %+v", o)
		}
	}
	if s1, _ := ScanOrbs(mustEntry(t, data, entryIndex(0, 0))); len(s1) != 0 {
		t.Fatalf("Spyro 1 entry must hold no orbs, got %+v", s1)
	}
	if dragons, _ := ScanSave(entry); len(dragons) != 0 {
		t.Fatalf("Spyro 2 entry must hold no Spyro 1 dragons, got %+v", dragons)
	}
}

func TestScanTalismansMixedSave(t *testing.T) {
	data := loadMixedSave(t)
	tals, stats := ScanTalismans(mustEntry(t, data, entryIndex(1, 1)))
	if len(tals) != 1 || tals[0] != (Dragon{Region: "Glimmer", Name: "Magic Pick", Collected: true}) {
		t.Fatalf("got talismans %+v (stats %+v), want Glimmer Magic Pick collected", tals, stats)
	}
	if s1, _ := ScanTalismans(mustEntry(t, data, entryIndex(0, 0))); len(s1) != 0 {
		t.Fatalf("Spyro 1 entry must hold no talismans, got %+v", s1)
	}
}

// Glimmer holds 21 red, 39 green, 21 purple, 2 yellow gems: 21 + 78 + 105 + 20.
func TestScanSpyro2GemsMixedSave(t *testing.T) {
	gems, stats := ScanSpyro2Gems(mustEntry(t, loadMixedSave(t), entryIndex(1, 1)))
	if len(gems) != 1 || gems["Glimmer"] != 224 {
		t.Fatalf("got gem totals %v (stats %+v), want Glimmer 224", gems, stats)
	}
}

func mustEntry(t *testing.T, data []byte, idx int) []byte {
	t.Helper()
	e, ok := saveEntry(data, idx)
	if !ok {
		t.Fatalf("no save entry %d", idx)
	}
	return e
}

func mixedDaemon(t *testing.T, session string) *daemon {
	t.Helper()
	d := testDaemon(t, true)
	d.saveDir = t.TempDir()
	if err := os.WriteFile(filepath.Join(d.saveDir, "FalconSave.0.sav"), loadMixedSave(t), 0644); err != nil {
		t.Fatal(err)
	}
	writeSession(t, d, session)
	return d
}

// 224 of Glimmer's 400 gems crosses the 100 and 200 thresholds, not 300/400.
func TestDaemonSpyro2Drop(t *testing.T) {
	d := mixedDaemon(t, "slot=1\ngame=1\ntoken=s2\n")
	d.pollOnce()
	expectDrop(t, readDrop(t, d), map[string]int{
		"Spyro 2: Glimmer: Lizard hunt":              201000,
		"Spyro 2: Glimmer: Gem lamp flight outdoors": 201001,
		"Spyro 2: Glimmer: Magic Pick":               201003,
		"Spyro 2: Glimmer: 25% Gems":                 201004,
		"Spyro 2: Glimmer: 50% Gems":                 201005,
	})
	d.lastPath = ""
	d.pollOnce()
	if d.drops != 1 {
		t.Fatalf("already-sent Spyro 2 checks must not drop again, drops=%d", d.drops)
	}
}

func TestDaemonSpyro1SessionIgnoresOrbs(t *testing.T) {
	d := mixedDaemon(t, "slot=0\ngame=0\ntoken=s1\n")
	d.pollOnce()
	if d.drops == 0 {
		t.Fatal("Spyro 1 playthrough in slot 0 must drop its checks")
	}
	for _, n := range readDrop(t, d).Names {
		if !strings.HasPrefix(n, "Spyro 1: ") {
			t.Fatalf("Spyro 1 session dropped non-Spyro 1 check %q", n)
		}
	}
	for k := range d.known {
		if k.kind == "orb" {
			t.Fatalf("Spyro 1 session must not scan orbs, known %+v", k)
		}
	}
}

// TestDaemonSpyro3Drop drives the real pollOnce path on the 100% save: a
// Spyro 3 session (game 2) baselines the 150 named eggs + 29 gem regions and,
// with backfill, drops all of them resolved through spyro3Locations. The save
// also holds completed S1/S2 playthroughs (entries 0/3); scanning only the
// game-2 entry and resolving only through spyro3Locations must keep their
// checks out of the drop.
func TestDaemonSpyro3Drop(t *testing.T) {
	d := testDaemon(t, true)
	d.saveDir = t.TempDir()
	if err := os.WriteFile(filepath.Join(d.saveDir, "FalconSave.106.sav"), loadSave(t, ref100Save), 0644); err != nil {
		t.Fatal(err)
	}
	writeSession(t, d, "slot=0\ngame=2\ntoken=s3full\n")
	d.pollOnce()
	if d.drops != 1 {
		t.Fatalf("baseline must drop once, drops=%d", d.drops)
	}
	drop := readDrop(t, d)
	sent := map[string]bool{}
	for _, n := range drop.Names {
		sent[n] = true
		if !strings.HasPrefix(n, "Spyro 3: ") {
			t.Fatalf("Spyro 3 session dropped non-Spyro 3 check %q", n)
		}
	}
	// 150 collected named eggs + every gem-bearing level at 100% (4 thresholds)
	// + the 20 earned skill points + the 3 obtained Sparx powers
	if len(drop.Checks) != 150+29*4+20+3 {
		t.Fatalf("backfill sent %d checks, want %d", len(drop.Checks), 150+29*4+20+3)
	}
	for _, n := range []string{
		"Spyro 3: Sunny Villa: Sanders",
		"Spyro 3: Midnight Mountain: Al",
		"Spyro 3: Super Bonus Round: YinYang",
		"Spyro 3: Sorceress Lair: Sorceress Defeated",
		"Spyro 3: Buzz's Dungeon: Buzz Defeated",
		"Spyro 3: Spike's Arena: Spike Defeated",
		"Spyro 3: Scorch's Pit: Scorch Defeated",
		"Spyro 3: Crawdad Farm: Sparx Gem Collect Range (Power)",
		"Spyro 3: Starfish Reef: Sparx Extra Hit Point (Power)",
		"Spyro 3: Bugbot Factory: Sparx Chest Breaking (Power)",
	} {
		if !sent[n] {
			t.Fatalf("egg location %q missing from the baseline drop %v", n, drop.Names)
		}
	}
	for _, region := range []string{"Sunrise Spring", "Dino Mines", "Super Bonus Round"} {
		for _, label := range []string{"25% Gems", "50% Gems", "75% Gems", "All Gems"} {
			n := "Spyro 3: " + region + ": " + label
			if !sent[n] {
				t.Fatalf("gem location %q missing from the baseline drop %v", n, drop.Names)
			}
		}
	}
	// the 300000+1000*regionIndex+n ID scheme, pinned on the spot-checked regions
	wantID := map[string]int{
		"Spyro 3: Sunrise Spring: 25% Gems":    300000,
		"Spyro 3: Sunrise Spring: 50% Gems":    300001,
		"Spyro 3: Sunrise Spring: 75% Gems":    300002,
		"Spyro 3: Sunrise Spring: All Gems":    300003,
		"Spyro 3: Dino Mines: 25% Gems":        331000,
		"Spyro 3: Dino Mines: 50% Gems":        331001,
		"Spyro 3: Dino Mines: 75% Gems":        331002,
		"Spyro 3: Dino Mines: All Gems":        331003,
		"Spyro 3: Super Bonus Round: 25% Gems": 336000,
		"Spyro 3: Super Bonus Round: 50% Gems": 336001,
		"Spyro 3: Super Bonus Round: 75% Gems": 336002,
		"Spyro 3: Super Bonus Round: All Gems": 336003,
	}
	for i, n := range drop.Names {
		if want, ok := wantID[n]; ok && drop.Checks[i] != want {
			t.Fatalf("check %q: got id %d, want %d", n, drop.Checks[i], want)
		}
	}
	// the save also holds a completed S2 playthrough: its Glimmer checks must
	// not leak into an S3 session's drops
	if sent["Spyro 2: Glimmer: 25% Gems"] || sent["Spyro 2: Glimmer: All Gems"] {
		t.Fatal("Spyro 2 gem checks leaked into the Spyro 3 session's drop")
	}
	t.Logf("100pct_ref Spyro 3 baseline: %d checks (150 eggs + 116 gem checks across 29 gem levels + 20 SPs + 3 sparx powers): OK",
		len(drop.Checks))
}

// TestDaemonSpyro3TransientSkip: a save with no Spyro 3 playthrough (the
// mixed fixture's game-2 entries are empty) takes the transient-skip path
// and sends nothing.
func TestDaemonSpyro3TransientSkip(t *testing.T) {
	d := mixedDaemon(t, "slot=1\ngame=2\ntoken=s3empty\n")
	d.pollOnce()
	if d.drops != 0 {
		t.Fatalf("empty Spyro 3 entry must drop nothing, drops=%d", d.drops)
	}
	if d.baselineOn {
		t.Fatal("empty Spyro 3 entry must not baseline")
	}
}

// Spyro 1's 10-gem type is EIT_YellowGem (the game has no EIT_GoldGem): the
// mixed save's fully collected Town Square reaches its 200 total only when
// yellow gems count 10; counted as 0 it stalled at 160 and "All Gems" never fired.
func TestScanGemsSpyro1YellowGems(t *testing.T) {
	gems, stats := ScanGems(mustEntry(t, loadMixedSave(t), entryIndex(0, 0)))
	if gems["Town Square"] != 200 {
		t.Fatalf("got Town Square %d (all %v, stats %+v), want 200", gems["Town Square"], gems, stats)
	}
}
