// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-11

package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func testDaemon(t *testing.T, backfill bool) *daemon {
	t.Helper()
	nameToID, eggCatalog, levelGems, err := embeddedLocations()
	if err != nil {
		t.Fatalf("load locations.json: %v", err)
	}
	d := newDaemon(nameToID, eggCatalog, levelGems, func(string, ...any) {})
	d.dropDir = t.TempDir()
	d.backfill = backfill
	// the fixtures' playthrough lives in save slot 0 (Spyro 1)
	writeSession(t, d, "slot=0\ngame=0\ntoken=t1\n")
	return d
}

func writeSession(t *testing.T, d *daemon, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(d.dropDir, sessionName), []byte(body), 0644); err != nil {
		t.Fatalf("write session: %v", err)
	}
}

// saveStamp seeds a monotonically increasing mtime so a same-path rewrite is
// always seen as changed without sleeping on filesystem mtime resolution.
var saveStamp = time.Now()

// stampSave writes data to path and stamps a strictly newer mtime than any
// previous stampSave call, so the daemon's path+mtime skip always sees a change.
func stampSave(t *testing.T, path string, data []byte) {
	t.Helper()
	saveStamp = saveStamp.Add(time.Second)
	if err := os.WriteFile(path, data, 0644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
	if err := os.Chtimes(path, saveStamp, saveStamp); err != nil {
		t.Fatalf("chtimes %s: %v", path, err)
	}
}

func readDrop(t *testing.T, d *daemon) dropPayload {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(d.dropDir, dropName))
	if err != nil {
		t.Fatalf("read drop: %v", err)
	}
	var p dropPayload
	if err := json.Unmarshal(b, &p); err != nil {
		t.Fatalf("parse drop: %v", err)
	}
	return p
}

func expectDrop(t *testing.T, p dropPayload, want map[string]int) {
	t.Helper()
	if len(p.Checks) != len(p.Names) || len(p.Checks) != len(want) {
		t.Fatalf("drop payload %v does not match expected %v", p, want)
	}
	for i, n := range p.Names {
		id, ok := want[n]
		if !ok {
			t.Fatalf("unexpected check name %q in %v", n, p.Names)
		}
		if p.Checks[i] != id {
			t.Fatalf("check %q: got id %d, want %d", n, p.Checks[i], id)
		}
		delete(want, n)
	}
}

// TestDaemonEggFlipDrop drives the daemon's real pollOnce path across two
// fixture states: snapshot1 (1 dragon, no eggs) as baseline, then snapshot3
// (4 dragons, Stone Hill egg collected) — the flip must drop the three new
// dragons AND the Stone Hill egg-thief check in one mixed drop.
func TestDaemonEggFlipDrop(t *testing.T) {
	d := seedSave(t, true, "FalconSave.99.sav", "snapshot1", "slot=0\ngame=0\ntoken=t1\n")
	d.pollOnce()
	expectDrop(t, readDrop(t, d), map[string]int{
		"Spyro 1: Artisans: Free Nestor": 100000,
	})

	flipToSnapshot3(t, d)
	expectDrop(t, readDrop(t, d), snapshot3Drop())
}

// TestDaemonEggFlipNoBackfill: with --no-backfill the baseline (snapshot1)
// drops nothing, and the snapshot3 flip drops exactly the fresh keys.
func TestDaemonEggFlipNoBackfill(t *testing.T) {
	d := seedSave(t, false, "FalconSave.99.sav", "snapshot1", "slot=0\ngame=0\ntoken=t1\n")
	d.pollOnce()
	if d.drops != 0 {
		t.Fatalf("no-backfill baseline must drop nothing, drops=%d", d.drops)
	}
	if _, err := os.Stat(filepath.Join(d.dropDir, dropName)); !os.IsNotExist(err) {
		t.Fatalf("no-backfill baseline must not write checks.json, err=%v", err)
	}

	flipToSnapshot3(t, d)
	expectDrop(t, readDrop(t, d), snapshot3Drop())
}

// flipToSnapshot3 rewrites the newer save file with snapshot3 and polls.
func flipToSnapshot3(t *testing.T, d *daemon) {
	t.Helper()
	stampSave(t, filepath.Join(d.saveDir, "FalconSave.98.sav"), loadSave(t, "snapshot3"))
	d.pollOnce()
}

// snapshot3Drop is what the snapshot3 flip drops: three dragons plus the Stone
// Hill egg thief and the Artisans 25% gem check.
func snapshot3Drop() map[string]int {
	return map[string]int{
		"Spyro 1: Artisans: Free Tomas":            100002,
		"Spyro 1: Stone Hill: Free Astor":          100012,
		"Spyro 1: Stone Hill: Free Gildas":         100014,
		"Spyro 1: Stone Hill: Catch the egg thief": 100015,
		"Spyro 1: Artisans: 25% Gems":              102010,
	}
}

// TestDaemonDropWriteFailureRetries: a drop whose write fails (checks.json.tmp
// is a directory, so WriteFile fails for any user) must not lose the fresh
// checks the scan already marked known. They stay pending, the next poll
// retries them even though the save is unchanged, they go out exactly once,
// and a new session forgets whatever is still pending.
func TestDaemonDropWriteFailureRetries(t *testing.T) {
	d := seedSave(t, false, "FalconSave.99.sav", "snapshot1", "slot=0\ngame=0\ntoken=t1\n")
	d.pollOnce()
	requirePending(t, d, 0, 0, "no-backfill baseline")

	blocker := blockDropTmp(t, d)
	writeSave(t, d, "FalconSave.98.sav", "snapshot3")
	d.pollOnce()
	if _, err := os.Stat(filepath.Join(d.dropDir, dropName)); !os.IsNotExist(err) {
		t.Fatalf("failed write must leave no checks.json, err=%v", err)
	}
	requirePending(t, d, 0, 5, "failed write")

	// still blocked, save unchanged: the retry fails again and keeps them
	d.pollOnce()
	requirePending(t, d, 0, 5, "blocked retry")

	if err := os.Remove(blocker); err != nil {
		t.Fatalf("unblock drop tmp: %v", err)
	}
	d.pollOnce()
	expectDrop(t, readDrop(t, d), snapshot3Drop())
	requirePending(t, d, 1, 0, "retry")
	d.pollOnce()
	if d.drops != 1 {
		t.Fatalf("pending checks must go out once, drops=%d", d.drops)
	}

	d.pending = []checkKey{{"dragon", "Artisans", "Tomas"}}
	writeSession(t, d, "slot=0\ngame=0\ntoken=t2\n")
	blockDropTmp(t, d)
	d.pollOnce()
	if len(d.pending) != 0 {
		t.Fatalf("a new session must clear pending, got %v", d.pending)
	}
}

// requirePending asserts the daemon's drop count and pending key count.
func requirePending(t *testing.T, d *daemon, drops, pending int, when string) {
	t.Helper()
	if d.drops != drops || len(d.pending) != pending {
		t.Fatalf("%s: drops=%d pending=%v, want %d drops and %d pending", when, d.drops, d.pending, drops, pending)
	}
}

// TestDaemonAbilityFlipDrop drives the real pollOnce path: mixed_s1_s2 has a
// Spyro 2 playthrough in slot 1 (entry 4, game 1) with no abilities owned.
// Flipping the game-1 entry's EIT_Swimming collected byte to 1 must drop
// exactly the Swim ability location (the fresh Money Bags purchase) on top of
// that fixture's orb/talisman/gem baseline.
func TestDaemonAbilityFlipDrop(t *testing.T) {
	d := mixedDaemon(t, "slot=1\ngame=1\ntoken=s2\n")
	d.pollOnce()
	if d.drops != 1 {
		t.Fatalf("fixture precondition: the unmutated mixed save must baseline once, drops=%d", d.drops)
	}
	prev := readDrop(t, d)

	data := loadMixedSave(t)
	// the game-1 entry's swim marker is the last one in the file
	m := bytes.LastIndex(data, []byte(swimMarker))
	if m < 0 {
		t.Fatal("no swim marker in mixed_s1_s2")
	}
	swimValOff := mustCollectedOff(t, data, m)
	if swimValOff >= len(data) || data[swimValOff] != 0 {
		t.Fatalf("fixture precondition: swim value byte at %d must be 0", swimValOff)
	}
	data[swimValOff] = 1

	path := filepath.Join(d.saveDir, "FalconSave.1.sav")
	stampSave(t, path, data)
	d.pollOnce()
	got := readDrop(t, d)
	if len(got.Checks) != 1 {
		t.Fatalf("ability flip must drop exactly the Swim location, got %v (previous drop %v)", got.Names, prev.Names)
	}
	expectDrop(t, got, map[string]int{"Spyro 2: Summer Forest: Swim Ability": 200004})
}

// TestDaemonS3EggFlipDrop drives the real pollOnce path on the 100% Spyro 3
// save: after the egg+gem baseline backfill, one egg's collected byte flipped
// 1->0 must drop nothing (a de-collect fires nothing), and flipping it back
// must re-drop exactly that one egg check — collected-state transitions drive
// the dedup map, and the mod-side dedup handles the server-side re-fire.
func TestDaemonS3EggFlipDrop(t *testing.T) {
	d := testDaemon(t, true)
	d.saveDir = t.TempDir()

	// 100pct_ref's eggs are all collected; confirm the first S3 egg marker's
	// collected byte reads 1 before mutating it.
	data := loadSave(t, ref100Save)
	if eggs, _ := ScanS3Eggs(data); len(eggs) != 150 {
		t.Fatalf("fixture precondition: %d egg records, want 150", len(eggs))
	}
	valOff := collectedEggOff(t, data)

	// de-collect at baseline: the record scans uncollected, so its check must
	// stay out of the baseline drop while the other 149 eggs backfill
	decoll := append([]byte(nil), data...)
	decoll[valOff] = 0
	writeSaveBytes(t, d, "FalconSave.106.sav", decoll)
	writeSession(t, d, "slot=0\ngame=2\ntoken=s3egg\n")
	d.pollOnce()
	if d.drops != 1 {
		t.Fatalf("baseline must drop once, drops=%d", d.drops)
	}
	target := eggBaselineTarget(t, d, decoll)
	baseDrops := d.drops

	// re-collect: exactly the one egg check drops
	writeSaveBytes(t, d, "FalconSave.105.sav", data)
	d.pollOnce()
	got := readDrop(t, d)
	if d.drops != baseDrops+1 {
		t.Fatalf("the re-collect must drop once, drops=%d (base %d)", d.drops, baseDrops)
	}
	loc := spyro3Locations[checkKey{"egg", target.Region, target.Name}]
	id, ok := nameToIDForTest(t)[loc]
	if !ok {
		t.Fatalf("egg location %q not in nameToID", loc)
	}
	expectDrop(t, got, map[string]int{"Spyro 3: " + target.Region + ": " + target.Name: id})

	// unchanged save: no re-drop (dedup)
	d.lastPath = ""
	d.pollOnce()
	if d.drops != baseDrops+1 {
		t.Fatalf("already-sent egg check must not drop again, drops=%d", d.drops)
	}
}

// collectedEggOff is the first S3 egg record's collected byte, which must read
// collected in the fixture.
func collectedEggOff(t *testing.T, data []byte) int {
	t.Helper()
	m := bytes.Index(data, []byte(s3EggMarker))
	if m < 0 {
		t.Fatal("no S3 egg marker in the save")
	}
	valOff := mustCollectedOff(t, data, m)
	if data[valOff] != 1 {
		t.Fatalf("fixture precondition: egg value byte at %d must be 1", valOff)
	}
	return valOff
}

// eggBaselineTarget checks the de-collected baseline backfilled the other 149
// eggs and returns the record the mutation de-collected.
func eggBaselineTarget(t *testing.T, d *daemon, decoll []byte) Dragon {
	t.Helper()
	if n := countIDs(readDrop(t, d).Names, eggLocationIDs()); n != 149 {
		t.Fatalf("baseline must backfill 149 collected eggs, got %d", n)
	}
	target := firstUncollectedEgg(t, decoll)
	if nameSet(readDrop(t, d).Names)["Spyro 3: "+target.Region+": "+target.Name] {
		t.Fatalf("uncollected egg %v must not backfill", target)
	}
	return target
}

// eggLocationIDs keys every Spyro 3 egg location, for counting drop names.
func eggLocationIDs() map[string]int {
	ids := map[string]int{}
	for k, loc := range spyro3Locations {
		if k.kind == "egg" {
			ids[loc] = 0
		}
	}
	return ids
}

// firstUncollectedEgg returns the first egg that scans uncollected.
func firstUncollectedEgg(t *testing.T, data []byte) Dragon {
	t.Helper()
	eggs, _ := ScanS3Eggs(data)
	for _, e := range eggs {
		if !e.Collected {
			return e
		}
	}
	t.Fatal("the mutated record must scan uncollected")
	return Dragon{}
}

// TestDaemonS3EggsWithoutGems pins the transient-skip ordering: an S3 entry
// truncated right after the first egg record (a mid-write save) scans 1 egg,
// 0 gem regions and 20 skill points (the Global SP record precedes the first
// egg) — the eggs must still baseline and backfill, not take the skip path.
func TestDaemonS3EggsWithoutGems(t *testing.T) {
	d := testDaemon(t, true)
	truncated := truncatedS3Entry(t)
	s := session{slot: 0, game: 2, token: "s3eggonly"}
	d.session = &s
	d.scanSpyro3("truncated", truncated)
	if d.drops != 1 {
		t.Fatalf("egg-only entry must baseline and drop, drops=%d", d.drops)
	}
	want := s3EggOnlyDrop(t)
	p := readDrop(t, d)
	if len(p.Checks) != len(want) {
		t.Fatalf("drop sent %d checks, want %d: %v", len(p.Checks), len(want), p.Names)
	}
	for _, id := range p.Checks {
		if _, ok := want[id]; !ok {
			t.Fatalf("unexpected check id %d in the drop", id)
		}
		delete(want, id)
	}
	if len(want) != 0 {
		t.Fatalf("missing checks: %v", want)
	}
}

// truncatedS3Entry is the 100% save's Spyro 3 entry cut off right after its
// first egg record, the shape a mid-write save leaves.
func truncatedS3Entry(t *testing.T) []byte {
	t.Helper()
	entry := mustEntry(t, loadSave(t, ref100Save), entryIndex(0, 2))
	m := bytes.Index(entry, []byte(s3EggMarker))
	if m < 0 {
		t.Fatal("no S3 egg marker in the game-2 entry")
	}
	truncated := entry[:m+400]
	eggs, _ := ScanS3Eggs(truncated)
	if len(eggs) != 1 || !eggs[0].Collected || eggs[0].Region != "Sunrise Spring" {
		t.Fatalf("truncated entry precondition: %v", eggs)
	}
	if gems, _ := ScanSpyro3Gems(truncated); len(gems) != 0 {
		t.Fatalf("truncated entry precondition: gem regions %v, want none", gems)
	}
	return truncated
}

// s3EggOnlyDrop is the check id set the truncated entry's baseline sends: the
// one egg plus the 20 skill points of the Global SP record it still carries
// (the record precedes the first egg, enums 31..50 -> their ids).
func s3EggOnlyDrop(t *testing.T) map[int]int {
	t.Helper()
	want := map[int]int{300004: 1}
	for enum := 31; enum <= 50; enum++ {
		id, ok := spIDByEnum(t, 2, enum)
		if !ok {
			t.Fatalf("locations.json has no Spyro 3 skill point for enum %d", enum)
		}
		want[id] = 1
	}
	return want
}

// spIDByEnum finds the location id of a game's "skillpoint" check by enum.
func spIDByEnum(t *testing.T, game int, enum int) (int, bool) {
	t.Helper()
	doc := parsedDoc(t)
	key := map[int]string{0: "spyro1", 1: "spyro2", 2: "spyro3"}[game]
	for _, r := range doc.Games[key].Regions {
		for _, c := range r.Checks {
			if c.Type == "skillpoint" && c.Enum == enum {
				return c.ID, true
			}
		}
	}
	return 0, false
}

// TestDaemonGemBaselineAndFlip drives the real pollOnce path: snapshot2
// (Artisans 25/100 gems + 2 dragons) baseline-backfills the exactly-at-
// threshold "Spyro 1: Artisans: 25% Gems" (prev=0 < 25 <= 25; 50/75/100 do not fire).
// Then a mutated save (Artisans 55) drops the 50% threshold in one mixed
// gem drop.
func TestDaemonGemBaselineAndFlip(t *testing.T) {
	d := seedSave(t, true, "FalconSave.99.sav", "snapshot2", "slot=0\ngame=0\ntoken=t1\n")
	d.pollOnce()
	expectDrop(t, readDrop(t, d), map[string]int{
		"Spyro 1: Artisans: Free Nestor": 100000,
		"Spyro 1: Artisans: Free Tomas":  100002,
		"Spyro 1: Artisans: 25% Gems":    102010,
	})

	data := loadSave(t, "snapshot2")
	pat := []byte(redGemMarker + "\x00\x0d\x00\x00\x00" + gemHashArrayTag)
	m := bytes.Index(data, pat)
	if m < 0 {
		t.Fatal("no red gem record in snapshot2")
	}
	countOff := m + len(redGemMarker) + 1 + 4 + 13 + 4 + 14 + 8 + 4 + 12 + 1
	binary.LittleEndian.PutUint32(data[countOff:], 18+30)
	binary.LittleEndian.PutUint64(data[countOff-25:], uint64(4+4*(18+30)))
	writeSaveBytes(t, d, "FalconSave.98.sav", data)
	d.pollOnce()
	expectDrop(t, readDrop(t, d), map[string]int{
		"Spyro 1: Artisans: 50% Gems": 102011,
	})
}

// TestGemThresholdBoundaries pins the crossing rule prev < t <= cur with
// integer division (threshold = total*pct/100) including exact boundaries,
// drops, and boss-level names that have no 25/50/75 locations.
func TestGemThresholdBoundaries(t *testing.T) {
	d := testDaemon(t, true)
	cases := []struct {
		region string
		prev   int
		cur    int
		want   []string
	}{
		{"Artisans", 0, 24, nil},
		{"Artisans", 0, 25, []string{"25% Gems"}},
		{"Artisans", 24, 25, []string{"25% Gems"}},
		{"Artisans", 25, 25, nil},
		{"Artisans", 25, 26, nil},
		{"Artisans", 0, 100, []string{"25% Gems", "50% Gems", "75% Gems", "All Gems"}},
		{"Artisans", 0, 1000, []string{"25% Gems", "50% Gems", "75% Gems", "All Gems"}},
		{"Artisans", 50, 40, nil},
		{"Toasty", 0, 100, []string{"25% Gems", "50% Gems", "75% Gems", "All Gems"}},
		{"Toasty", 0, 25, []string{"25% Gems"}},
	}
	for _, c := range cases {
		got := d.gemEvents(c.region, c.prev, c.cur)
		labels := make([]string, 0, len(got))
		for _, k := range got {
			labels = append(labels, k.name)
		}
		want := make([]string, 0, len(c.want))
		want = append(want, c.want...)
		if len(labels) != len(want) {
			t.Fatalf("%s %d->%d: got %v, want %v", c.region, c.prev, c.cur, labels, want)
		}
		for i := range want {
			if labels[i] != want[i] {
				t.Fatalf("%s %d->%d: got %v, want %v", c.region, c.prev, c.cur, labels, want)
			}
		}
	}
	// Unknown region yields nothing. Boss levels (Toasty) DO produce 25/50/75
	// keys here — they are filtered later in sendDrop (unresolvable name), not
	// in gemEvents; the boundary test pins the crossing rule, not name resolvability.
	if got := d.gemEvents("Nowhere", 0, 999); got != nil {
		t.Fatalf("unknown region must yield nothing, got %v", got)
	}
	t.Log("threshold boundary table: OK")
}
