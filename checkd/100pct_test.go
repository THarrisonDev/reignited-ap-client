package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// 100pct_ref.sav is a synthetic 100% playthrough (gen_fixtures.py): Spyro 1
// in entry 0 (game 0, slot 0), Spyro 2 in entry 3 (game 1, slot 0), Spyro 3
// in entry 6.
const ref100Save = "100pct_ref"

// Test100pctRefDragons: the full S1 playthrough rescues all 80 dragons (74
// unique + 6 rescued in two levels each), every one resolving through the
// embedded locations.json regions.
func Test100pctRefDragons(t *testing.T) {
	data := loadSave(t, ref100Save)
	dragons, stats := ScanSave(data)
	if len(dragons) != 80 {
		t.Fatalf("ScanSave found %d dragons (stats %+v), want 80", len(dragons), stats)
	}
	collected := 0
	names := make(map[string]bool)
	for _, d := range dragons {
		if d.Collected {
			collected++
		}
		names[d.Name] = true
		loc := locationPrefix + d.Region + ": Free " + d.Name
		if _, ok := nameToIDForTest(t)[loc]; !ok {
			t.Fatalf("dragon %v does not resolve to a location (%q)", d, loc)
		}
	}
	if collected != 80 {
		t.Fatalf("collected %d dragons, want 80", collected)
	}
	if len(names) != 74 {
		t.Fatalf("%d unique dragon names, want 74 (6 dragons rescued in two levels)", len(names))
	}
	t.Logf("100pct_ref: 80 collected dragons (%d unique names) all resolve: OK", len(names))
}

// Test100pctRefS1Gems: every non-flight S1 level hits its locations.json
// levelGems total; the five flight levels scan 0 gems (their "gems" are
// summary-screen challenge rewards, never in gemCollectionMap).
func Test100pctRefS1Gems(t *testing.T) {
	data := loadSave(t, ref100Save)
	entry := mustEntry(t, data, entryIndex(0, 0))
	gems, stats := ScanGems(entry)
	if len(gems) == 0 {
		t.Fatalf("ScanGems found nothing (stats %+v)", stats)
	}
	flights := map[string]bool{
		"Sunny Flight": true, "Night Flight": true, "Crystal Flight": true,
		"Wild Flight": true, "Icy Flight": true,
	}
	for region, total := range levelGemsForTest(t) {
		if flights[region] {
			if gems[region] != 0 {
				t.Fatalf("flight level %s scanned gem value %d, want 0", region, gems[region])
			}
			continue
		}
		if gems[region] != total {
			t.Fatalf("%s: scanned %d, levelGems total %d", region, gems[region], total)
		}
	}
	t.Logf("100pct_ref S1: %d gem regions all match levelGems (flights 0): OK", len(gems))
}

// Test100pctRefSpyro2Gems: all 21 gem-bearing levels read exactly 400; the 4
// speedways, 3 boss dungeons and Dragon Shores read 0/absent.
func Test100pctRefSpyro2Gems(t *testing.T) {
	data := loadSave(t, ref100Save)
	gems, stats := ScanSpyro2Gems(mustEntry(t, data, entryIndex(0, 1)))
	gemLevels := map[string]bool{
		"Summer Forest": true, "Glimmer": true, "Idol Springs": true, "Colossus": true,
		"Hurricos": true, "Sunny Beach": true, "Aquaria Towers": true, "Autumn Plains": true,
		"Crystal Glacier": true, "Skelos Badlands": true, "Zephyr": true, "Breeze Harbor": true,
		"Scorch": true, "Fracture Hills": true, "Magma Cone": true, "Shady Oasis": true,
		"Winter Tundra": true, "Mystic Marsh": true, "Cloud Temples": true,
		"Metropolis": true, "Robotica Farms": true,
	}
	noGems := []string{"Ocean Speedway", "Icy Speedway", "Metro Speedway", "Canyon Speedway",
		"Crush's Dungeon", "Gulp's Overlook", "Ripto's Arena", "Dragon Shores"}
	for region := range gemLevels {
		if gems[region] != 400 {
			t.Fatalf("%s: scanned %d, want 400", region, gems[region])
		}
	}
	if len(gems) != len(gemLevels) {
		t.Fatalf("scanned %d gem regions, want %d (stats %+v)", len(gems), len(gemLevels), stats)
	}
	for _, region := range noGems {
		if gems[region] != 0 {
			t.Fatalf("%s: scanned %d, want 0", region, gems[region])
		}
	}
	t.Logf("100pct_ref Spyro 2: %d gem levels at 400, speedways/bosses/Dragon Shores 0: OK", len(gems))
}

// Test100pctRefSpyro3Gems: the game-2 entry's 29 gem-bearing levels hit
// their locations.json gemTotal exactly — including the two odd totals, Dino
// Mines 702 (the wiki-documented gem-shrub) and Super Bonus Round 5000 —
// while the speedways, boss/challenge dungeons and Sorceress Lair read 0
// (summary-screen rewards, never in gemCollectionMap).
func Test100pctRefSpyro3Gems(t *testing.T) {
	data := loadSave(t, ref100Save)
	entry := mustEntry(t, data, entryIndex(0, 2))
	gems, stats := ScanSpyro3Gems(entry)
	if len(gems) == 0 {
		t.Fatalf("ScanSpyro3Gems found nothing (stats %+v)", stats)
	}
	for region, total := range spyro3LevelGemsForTest(t) {
		if gems[region] != total {
			t.Fatalf("%s: scanned %d, locations.json gemTotal %d", region, gems[region], total)
		}
	}
	if gems["Dino Mines"] != 702 {
		t.Fatalf("Dino Mines: scanned %d, want 702", gems["Dino Mines"])
	}
	if gems["Super Bonus Round"] != 5000 {
		t.Fatalf("Super Bonus Round: scanned %d, want 5000", gems["Super Bonus Round"])
	}
	// The MoneybagGems pseudo-key's 8000-value stash must attribute to no
	// region: it backward-walks to Harbor Speedway (the nearest preceding
	// level key) whenever the pseudo-key is not found. Regression pin: the
	// isLevelKeyAt call must pass the NUL's offset, not one past it.
	if gems["Harbor Speedway"] != 0 {
		t.Fatalf("Harbor Speedway: scanned %d, want 0 (MoneybagGems stash leaked in)", gems["Harbor Speedway"])
	}
	for region := range gems {
		if region == "MoneybagGems" {
			t.Fatalf("MoneybagGems must not resolve to a gem region")
		}
	}
	t.Logf("100pct_ref Spyro 3: %d gem regions all match locations.json (Dino Mines 702, Super Bonus Round 5000): OK",
		len(gems))
}

// Test100pctRefAbilities: the S2 100% entry's global inventory owns all three
// Money Bags abilities (Superflame excluded), each resolving through the
// init-built ability table to a location present in nameToID.
func Test100pctRefAbilities(t *testing.T) {
	data := loadSave(t, ref100Save)
	abilities, stats := ScanAbilities(data)
	if len(abilities) != 3 {
		t.Fatalf("ScanAbilities found %d records (stats %+v), want 3", len(abilities), stats)
	}
	want := map[string]string{
		"Swim":     "Spyro 2: Summer Forest: Swim Ability",
		"Climb":    "Spyro 2: Autumn Plains: Climb Ability",
		"Headbash": "Spyro 2: Winter Tundra: Headbash Ability",
	}
	wantID := map[string]int{
		"Spyro 2: Summer Forest: Swim Ability":     200004,
		"Spyro 2: Autumn Plains: Climb Ability":    209002,
		"Spyro 2: Winter Tundra: Headbash Ability": 221003,
	}
	nameToID := nameToIDForTest(t)
	for _, a := range abilities {
		if !a.Collected {
			t.Fatalf("ability %q not collected", a.Name)
		}
		if a.Region != "" {
			t.Fatalf("ability %q must carry no region, got %q", a.Name, a.Region)
		}
		loc, ok := spyro2Locations[checkKey{"ability", "", a.Name}]
		if !ok {
			t.Fatalf("ability %q not in the init-built table", a.Name)
		}
		if loc != want[a.Name] {
			t.Fatalf("ability %q resolved to %q, want %q", a.Name, loc, want[a.Name])
		}
		id, ok := nameToID[loc]
		if !ok || id != wantID[loc] {
			t.Fatalf("location %q id = %d (present %t), want %d", loc, id, ok, wantID[loc])
		}
	}
	t.Logf("100pct_ref: Swim/Climb/Headbash all collected, all resolve (ids 200004/209002/221003): OK")
}

// Test100pctRefOrbsTalismans: the save holds all 64 orbs and 14 talismans,
// one per catalog key, all collected.
func Test100pctRefOrbsTalismans(t *testing.T) {
	data := loadSave(t, ref100Save)
	entry := mustEntry(t, data, entryIndex(0, 1))

	orbs, stats := ScanOrbs(entry)
	if len(orbs) != 64 {
		t.Fatalf("ScanOrbs found %d orbs (stats %+v), want 64", len(orbs), stats)
	}
	talismans, talStats := ScanTalismans(entry)
	if len(talismans) != 14 {
		t.Fatalf("ScanTalismans found %d talismans (stats %+v), want 14", len(talismans), talStats)
	}

	wantOrbKeys := map[string]bool{}
	wantTalismanKeys := map[string]bool{}
	for region, r := range spyro2RegionsForTest(t) {
		for _, c := range r.Checks {
			if c.Type == "orb" {
				wantOrbKeys[c.Name] = true
				if !orbIn(orbs, region, c.Name) {
					t.Fatalf("orb %q not collected in %s", c.Name, region)
				}
			}
			if c.Type == "talisman" {
				wantTalismanKeys[c.Name] = true
				if !orbIn(talismans, region, c.Name) {
					t.Fatalf("talisman %q not collected in %s", c.Name, region)
				}
			}
		}
	}
	if len(wantOrbKeys) != 64 || len(wantTalismanKeys) != 14 {
		t.Fatalf("catalog shape: %d orb keys, %d talisman keys", len(wantOrbKeys), len(wantTalismanKeys))
	}
	for _, o := range orbs {
		if !o.Collected {
			t.Fatalf("orb %+v not collected", o)
		}
	}
	for _, ta := range talismans {
		if !ta.Collected {
			t.Fatalf("talisman %+v not collected", ta)
		}
	}
	t.Logf("100pct_ref Spyro 2: 64 orbs + 14 talismans, all collected, one per catalog key: OK")
}

// Test100pctRefEntryScoping: the S1 playthrough (entry 0) holds no orb,
// talisman or Spyro 2/3 gem records, its global inventory carries all three
// ability types UNOWNED (S1 entries carry the types but never grant them),
// the S2 playthrough (entry 3) holds no Spyro 1 dragon records, and the S3
// playthrough (entry 6) holds no Spyro 1 dragons either.
func Test100pctRefEntryScoping(t *testing.T) {
	data := loadSave(t, ref100Save)
	s1 := mustEntry(t, data, entryIndex(0, 0))
	s2 := mustEntry(t, data, entryIndex(0, 1))
	s3 := mustEntry(t, data, entryIndex(0, 2))

	if orbs, _ := ScanOrbs(s1); len(orbs) != 0 {
		t.Fatalf("Spyro 1 entry holds orbs: %+v", orbs)
	}
	if tals, _ := ScanTalismans(s1); len(tals) != 0 {
		t.Fatalf("Spyro 1 entry holds talismans: %+v", tals)
	}
	abilities, _ := ScanAbilities(s1)
	if len(abilities) != 3 {
		t.Fatalf("Spyro 1 100%% entry holds %d ability records, want 3 (all types)", len(abilities))
	}
	for _, a := range abilities {
		if a.Collected {
			t.Fatalf("Spyro 1 entry ability %q must be uncollected (S1 never grants these), got %+v", a.Name, a)
		}
		if a.Region != "" {
			t.Fatalf("ability %q must carry no region, got %q", a.Name, a.Region)
		}
	}
	if gems, _ := ScanSpyro2Gems(s1); len(gems) != 0 {
		t.Fatalf("Spyro 1 entry holds Spyro 2 gems: %v", gems)
	}
	if gems, _ := ScanSpyro3Gems(s1); len(gems) != 0 {
		t.Fatalf("Spyro 1 entry holds Spyro 3 gems: %v", gems)
	}
	if dragons, _ := ScanSave(s2); len(dragons) != 0 {
		t.Fatalf("Spyro 2 entry holds Spyro 1 dragons: %+v", dragons)
	}
	if dragons, _ := ScanSave(s3); len(dragons) != 0 {
		t.Fatalf("Spyro 3 entry holds Spyro 1 dragons: %+v", dragons)
	}
	t.Log("entry scoping: S1 entry clean of S2/S3 records, S2/S3 entries clean of S1 dragons: OK")
}

// Test100pctRefSpyro2DaemonBaseline drives the real pollOnce path on the 100%
// Spyro 2 save: the baseline backfill must resolve every orb, talisman,
// ability and boss through locations.json (no "unknown location" skips) and
// carry exactly the 84 gem checks of the 21 gem-bearing levels — none on a
// speedway, boss dungeon or Dragon Shores.
func Test100pctRefSpyro2DaemonBaseline(t *testing.T) {
	d := testDaemon(t, true)
	d.saveDir = t.TempDir()
	if err := os.WriteFile(filepath.Join(d.saveDir, "FalconSave.106.sav"), loadSave(t, ref100Save), 0644); err != nil {
		t.Fatal(err)
	}
	writeSession(t, d, "slot=0\ngame=1\ntoken=s2full\n")
	d.pollOnce()
	drop := readDrop(t, d)
	if d.drops != 1 {
		t.Fatalf("baseline must drop once, drops=%d", d.drops)
	}
	if len(drop.Checks) != 64+14+3+3+21*4+16 {
		t.Fatalf("backfill sent %d checks, want %d", len(drop.Checks), 64+14+3+3+21*4)
	}
	sent := map[string]bool{}
	for _, n := range drop.Names {
		sent[n] = true
	}
	for _, n := range []string{
		"Spyro 2: Summer Forest: Swim Ability",
		"Spyro 2: Autumn Plains: Climb Ability",
		"Spyro 2: Winter Tundra: Headbash Ability",
	} {
		if !sent[n] {
			t.Fatalf("ability location %q missing from the baseline drop %v", n, drop.Names)
		}
	}
	// the speedways/bosses/Dragon Shores hold orbs and boss checks but must
	// send no GEM checks
	for _, region := range []string{"Ocean Speedway", "Icy Speedway", "Metro Speedway",
		"Canyon Speedway", "Crush's Dungeon", "Gulp's Overlook", "Ripto's Arena", "Dragon Shores"} {
		for _, label := range []string{"25% Gems", "50% Gems", "75% Gems", "All Gems"} {
			n := "Spyro 2: " + region + ": " + label
			if sent[n] {
				t.Fatalf("no-gem level %s sent gem check %q", region, n)
			}
		}
	}
	for _, n := range []string{
		"Spyro 2: Crush's Dungeon: Crush Defeated",
		"Spyro 2: Gulp's Overlook: Gulp Defeated",
		"Spyro 2: Ripto's Arena: Ripto Defeated",
	} {
		if !sent[n] {
			t.Fatalf("boss location %q missing from the baseline drop %v", n, drop.Names)
		}
	}
	t.Logf("100pct_ref Spyro 2 baseline: %d checks (%d orbs+talismans, %d abilities, %d bosses, %d gem checks): OK",
		len(drop.Checks), 64+14, 3, 3, 21*4)
}

func orbIn(records []Dragon, region, name string) bool {
	for _, r := range records {
		if r.Region == region && r.Name == name {
			return true
		}
	}
	return false
}

func nameToIDForTest(t *testing.T) map[string]int {
	t.Helper()
	nameToID, _, _, err := embeddedLocations()
	if err != nil {
		t.Fatalf("load locations.json: %v", err)
	}
	return nameToID
}

func spyro2RegionsForTest(t *testing.T) map[string]locRegion {
	t.Helper()
	var doc locationsDoc
	if err := json.Unmarshal(locationsJSON, &doc); err != nil {
		t.Fatalf("parse embedded locations.json: %v", err)
	}
	return doc.Games["spyro2"].Regions
}

func levelGemsForTest(t *testing.T) map[string]int {
	t.Helper()
	var doc locationsDoc
	if err := json.Unmarshal(locationsJSON, &doc); err != nil {
		t.Fatalf("parse embedded locations.json: %v", err)
	}
	out := map[string]int{}
	for region, r := range doc.Games["spyro1"].Regions {
		out[region] = r.GemTotal
	}
	return out
}

func spyro3LevelGemsForTest(t *testing.T) map[string]int {
	t.Helper()
	var doc locationsDoc
	if err := json.Unmarshal(locationsJSON, &doc); err != nil {
		t.Fatalf("parse embedded locations.json: %v", err)
	}
	out := map[string]int{}
	for region, r := range doc.Games["spyro3"].Regions {
		out[region] = r.GemTotal
	}
	return out
}
