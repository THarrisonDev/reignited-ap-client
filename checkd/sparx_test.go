// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-11

package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"math"
	"path/filepath"
	"testing"
)

// TestScanSparxPowers100pct: the 100% save's file-global globalFloatMap holds
// exactly 3 obtained Sparx powers for slot 0, game 2 (GemFinder is absent —
// Reignited ships the gem radar default-on), each scanning as the enum-name
// suffix of its key.
func TestScanSparxPowers100pct(t *testing.T) {
	data := loadSave(t, ref100Save)
	got, stats := ScanSparxPowers(data, 0, 2)
	want := []string{"ChestBreaking", "ExtraHP", "GemCollectRange"}
	if stats.Markers != 25 || stats.Skipped != 0 {
		t.Fatalf("stats %+v, want 25 markers 0 skipped", stats)
	}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
	// other slots and games stay empty
	for _, c := range []struct{ slot, game int }{{0, 0}, {0, 1}, {1, 2}, {2, 2}} {
		if other, _ := ScanSparxPowers(data, c.slot, c.game); len(other) != 0 {
			t.Fatalf("slot %d game %d: got %v, want none", c.slot, c.game, other)
		}
	}
	t.Log("100pct_ref slot 0 game 2: GemCollectRange/ExtraHP/ChestBreaking obtained: OK")
}

// TestScanSparxPowersFixtures: every other fixture's globalFloatMap holds the
// 4 power keys per slot at 0.0 (never obtained), so every (slot, game) scan is
// empty — the zero-value baseline the flip tests build from.
func TestScanSparxPowersFixtures(t *testing.T) {
	for _, stem := range fixtureStems {
		data := loadSave(t, stem)
		for slot := 0; slot < 3; slot++ {
			for game := 0; game < 3; game++ {
				got, stats := ScanSparxPowers(data, slot, game)
				if len(got) != 0 || stats.Skipped != 0 {
					t.Fatalf("%s slot %d game %d: got %v (stats %+v), want none",
						stem, slot, game, got, stats)
				}
			}
		}
	}
	t.Log("snapshot1/2/3, mirror and mixed: no obtained power in any (slot, game): OK")
}

// TestScanSparxPowersLeakGuard pins entry scoping: a slot 1 game 2 session
// must not see slot 0's powers (100pct_ref holds only collected.0.2.* keys,
// but the mixed save holds all 12 slot keys at 0.0 — the prefix decides).
func TestScanSparxPowersLeakGuard(t *testing.T) {
	data := loadSave(t, ref100Save)
	obtained, _ := ScanSparxPowers(data, 0, 2)
	if len(obtained) != 3 {
		t.Fatalf("precondition: %v", obtained)
	}
	mutated := append([]byte(nil), data...)
	// rewrite slot 0 -> slot 1 in the raw bytes of the Sparx keys: the same
	// records must then scan under (1, 2) and (0, 2) must go empty.
	for _, power := range []string{"GemCollectRange", "ExtraHP", "ChestBreaking"} {
		old := []byte("collected.0.2.EIT_SparxPower_" + power + "\x00")
		new := []byte("collected.1.2.EIT_SparxPower_" + power + "\x00")
		m := bytes.Index(mutated, old)
		if m < 0 {
			t.Fatalf("no key for %s", power)
		}
		copy(mutated[m:m+len(old)], new)
	}
	if got, _ := ScanSparxPowers(mutated, 0, 2); len(got) != 0 {
		t.Fatalf("slot 0 must not see slot 1's powers, got %v", got)
	}
	got, _ := ScanSparxPowers(mutated, 1, 2)
	if len(got) != 3 || got[0] != "ChestBreaking" {
		t.Fatalf("slot 1 game 2: got %v, want the 3 rewritten powers", got)
	}
	t.Log("slot prefix decides: powers move 0.2 -> 1.2 with the key rewrite: OK")
}

// TestScanSparxPowersZeroValue: a power at 0.0 is not obtained even when the
// key exists (the mixed save's 24 collected.* keys are all 0.0).
func TestScanSparxPowersZeroValue(t *testing.T) {
	data := loadSave(t, "mixed_s1_s2")
	got, _ := ScanSparxPowers(data, 0, 2)
	if len(got) != 0 {
		t.Fatalf("0.0 keys must not read obtained, got %v", got)
	}
	// flip one key's float to 1.0 in the raw bytes
	key := []byte("collected.0.2.EIT_SparxPower_ExtraHP\x00")
	m := bytes.Index(data, key)
	if m < 0 {
		t.Fatal("no ExtraHP key in mixed_s1_s2")
	}
	valOff := m + len(key)
	if v := binary.LittleEndian.Uint32(data[valOff:]); v != 0 {
		t.Fatalf("fixture precondition: value at %d = %#x, want 0", valOff, v)
	}
	mutated := append([]byte(nil), data...)
	binary.LittleEndian.PutUint32(mutated[valOff:], math.Float32bits(1))
	got, _ = ScanSparxPowers(mutated, 0, 2)
	if len(got) != 1 || got[0] != "ExtraHP" {
		t.Fatalf("flipped key must scan obtained, got %v", got)
	}
	t.Log("0.0 stays unobtained; the flipped ExtraHP key reads obtained: OK")
}

// TestScanSparxPowersRejectsNonGVAS: garbage input yields nothing.
func TestScanSparxPowersRejectsNonGVAS(t *testing.T) {
	got, stats := ScanSparxPowers([]byte("NOT_GVAS at all"), 0, 2)
	if got != nil || stats.Markers != 0 {
		t.Fatalf("non-GVAS input must yield nothing, got %v %+v", got, stats)
	}
	data := loadSave(t, "snapshot1")
	i := bytes.Index(data, []byte("globalFloatMap"))
	got, stats = ScanSparxPowers(data[:i], 0, 2)
	if got != nil || stats.Markers != 0 {
		t.Fatalf("map-less input must yield nothing, got %v %+v", got, stats)
	}
	t.Log("non-GVAS and map-less inputs rejected: OK")
}

// gfmRecord builds one GVAS blob with a globalFloatMap (the layout
// ScanSparxPowers pins, byte-verified against the real saves): count
// entries of key FString + float, after the MapProperty header.
func gfmRecord(entries ...[2]any) []byte {
	var w gvasWriter
	w.str("globalFloatMap")
	w.str("MapProperty")
	bodyAt := w.Len()
	w.u32(0) // body size, patched below
	w.u32(0) // array index
	w.str("StrProperty")
	w.str("FloatProperty")
	w.WriteByte(0) // the tag's NUL terminator
	w.u32(0)       // allocation flags
	w.u32(uint32(len(entries)))
	for _, e := range entries {
		key, _ := e[0].(string)
		val, _ := e[1].(float32)
		w.str(key)
		w.f32(val)
	}
	w.patchU32(bodyAt, uint32(w.Len()-bodyAt))
	return w.Bytes()
}

func TestScanSparxPowersSynthetic(t *testing.T) {
	key := func(slot, game int, power string) string {
		return fmt.Sprintf("collected.%d.%d.EIT_SparxPower_%s", slot, game, power)
	}
	data := bytes.Join([][]byte{[]byte("GVAS"), gfmRecord(
		[2]any{"menu.ui_sound", float32(1)},
		[2]any{key(1, 2, "GemCollectRange"), float32(1)},
		[2]any{key(1, 2, "ExtraHP"), float32(0)},
		[2]any{key(0, 2, "ChestBreaking"), float32(1)},
	)}, nil)
	got, stats := ScanSparxPowers(data, 1, 2)
	if stats.Markers != 4 || stats.Skipped != 0 {
		t.Fatalf("stats %+v, want 4 markers 0 skipped", stats)
	}
	if len(got) != 1 || got[0] != "GemCollectRange" {
		t.Fatalf("got %v, want [GemCollectRange]", got)
	}
	if got, _ := ScanSparxPowers(data, 0, 2); len(got) != 1 || got[0] != "ChestBreaking" {
		t.Fatalf("(0, 2): got %v, want [ChestBreaking]", got)
	}
	t.Log("synthetic map: prefix + 0/1 float decide, other keys ignored: OK")
}

// TestScanSparxPowersUTF16Key: a key written as UTF-16 (negative length)
// scans like its ASCII twin.
func TestScanSparxPowersUTF16Key(t *testing.T) {
	var w gvasWriter
	w.str("globalFloatMap")
	w.str("MapProperty")
	bodyAt := w.Len()
	w.u32(0)
	w.u32(0)
	w.str("StrProperty")
	w.str("FloatProperty")
	w.WriteByte(0)
	w.u32(0)
	w.u32(1)
	// one UTF-16 key + 4-byte float value
	w.Write(utf16FString("collected.0.2.EIT_SparxPower_ExtraHP"))
	w.f32(1)
	w.patchU32(bodyAt, uint32(w.Len()-bodyAt))
	data := bytes.Join([][]byte{[]byte("GVAS"), w.Bytes()}, nil)
	got, stats := ScanSparxPowers(data, 0, 2)
	if stats.Markers != 1 || stats.Skipped != 0 {
		t.Fatalf("stats %+v, want 1 marker 0 skipped", stats)
	}
	if len(got) != 1 || got[0] != "ExtraHP" {
		t.Fatalf("got %v, want [ExtraHP]", got)
	}
	t.Log("UTF-16 key decodes like ASCII: OK")
}

// utf16FString is s as a GVAS UTF-16LE FString: a negative length prefix, a
// NUL after every code unit, and the closing NUL unit.
func utf16FString(s string) []byte {
	var b bytes.Buffer
	_ = binary.Write(&b, binary.LittleEndian, int32(-(len(s) + 1)))
	for i := 0; i < len(s); i++ {
		b.WriteByte(s[i])
		b.WriteByte(0)
	}
	b.WriteByte(0)
	b.WriteByte(0)
	return b.Bytes()
}

// TestSpyro3SparxKeys pins the init-built spyro3Locations shape for the three
// sparxpower rows: the "sparx" alias key (the globalFloatMap key's enum-name
// suffix, empty region) resolves to the location and its locations.json id.
func TestSpyro3SparxKeys(t *testing.T) {
	nameToID := nameToIDForTest(t)
	want := []struct {
		power string
		id    int
	}{
		{"GemCollectRange", 308005},
		{"ExtraHP", 326005},
		{"ChestBreaking", 335005},
	}
	for _, w := range want {
		k := checkKey{"sparx", "", w.power}
		loc, ok := spyro3Locations[k]
		if !ok {
			t.Fatalf("no sparxpower row for %s in the embedded locations.json (run scripts/gen_locations.py)", w.power)
		}
		wantLoc := fmt.Sprintf("Spyro 3: %s: Sparx %s (Power)",
			map[string]string{
				"GemCollectRange": "Crawdad Farm",
				"ExtraHP":         "Starfish Reef",
				"ChestBreaking":   "Bugbot Factory",
			}[w.power], sparxDisplayName(w.power))
		if loc != wantLoc {
			t.Fatalf("key %+v resolved to %q, want %q", k, loc, wantLoc)
		}
		if id, ok := nameToID[loc]; !ok || id != w.id {
			t.Fatalf("location %q id = %d (present %t), want %d", loc, id, ok, w.id)
		}
	}
	t.Log("3 sparxpower rows registered under their power keys, all resolving: OK")
}

// sparxDisplayName maps the enum-name suffix to the location name's display
// part (the apworld names them "Sparx Gem Collect Range (Power)" etc.).
func sparxDisplayName(power string) string {
	switch power {
	case "GemCollectRange":
		return "Gem Collect Range"
	case "ExtraHP":
		return "Extra Hit Point"
	case "ChestBreaking":
		return "Chest Breaking"
	}
	return power
}

// withSparxTable stubs the init-built Sparx tables for the daemon tests: the
// suffix table AND the "sparx" alias keys of spyro3Locations (sendDrop
// resolves through it), copied over the originals and restored on cleanup.
// Registering the aliases unconditionally keeps the tests green both before
// and after the embedded locations.json gains the real sparxpower rows.
func withSparxTable(t *testing.T, table map[string]string) {
	t.Helper()
	origPowers := spyro3SparxPowers
	spyro3SparxPowers = table
	origLocs := spyro3Locations
	locs := make(map[checkKey]string, len(origLocs)+len(table))
	for k, v := range origLocs {
		locs[k] = v
	}
	for power, loc := range table {
		locs[checkKey{"sparx", "", power}] = loc
	}
	spyro3Locations = locs
	t.Cleanup(func() {
		spyro3SparxPowers = origPowers
		spyro3Locations = origLocs
	})
}

// sparxTestNames builds the synthetic suffix -> location table the daemon
// tests use, plus the nameToID extension for it.
func sparxTestNames() (map[string]string, map[string]int) {
	table := map[string]string{}
	ids := map[string]int{}
	for i, power := range []string{"GemCollectRange", "ExtraHP", "ChestBreaking"} {
		name := fmt.Sprintf("Spyro 3: Test Sparx Power %d", i)
		table[power] = name
		ids[name] = 950000 + i
	}
	return table, ids
}

// sparxDaemon is a Spyro 3 daemon with the synthetic suffix table, the ids it
// resolves to, and fixture stem as its only save file.
func sparxDaemon(t *testing.T, backfill bool, stem string) (*daemon, map[string]string, map[string]int) {
	t.Helper()
	table, ids := sparxTestNames()
	withSparxTable(t, table)
	d := testDaemonWithIDs(t, backfill, ids)
	d.saveDir = t.TempDir()
	writeSave(t, d, "FalconSave.106.sav", stem)
	return d, table, ids
}

// TestDaemonSparxBackfill drives the real pollOnce path on the 100% Spyro 3
// save: with backfill, the baseline drop contains exactly the 3 obtained
// powers resolved through the (synthetic) suffix table, alongside the
// eggs/gems/skill points.
func TestDaemonSparxBackfill(t *testing.T) {
	d, table, ids := sparxDaemon(t, true, ref100Save)
	writeSession(t, d, "slot=0\ngame=2\ntoken=sparxbf\n")
	d.pollOnce()
	drop := readDrop(t, d)
	sent := nameSet(drop.Names)
	for power, name := range table {
		if !sent[name] {
			t.Fatalf("sparx power %s (%q) missing from the baseline drop %v", power, name, drop.Names)
		}
		if id := nameToIDCheck(t, d, name); id != ids[name] {
			t.Fatalf("sparx power %s id %d, want %d", power, id, ids[name])
		}
	}
	if len(d.sparxKnown) != 3 {
		t.Fatalf("sparxKnown has %d entries, want 3", len(d.sparxKnown))
	}
	t.Logf("100pct_ref S3 baseline: %d checks incl. all 3 sparx powers: OK", len(drop.Checks))
}

// TestDaemonSparxFlip drives the real pollOnce path across two fixture saves
// in one session, the S3-egg flip pattern: a save with one power's float
// zeroed baselines (backfilling exactly the other 2 obtained powers), then the
// power's 0->1 flip drops exactly that one check, a further 1->0 drops
// nothing, and the flip back (already known — the sent-checks dedup) fires
// nothing either.
func TestDaemonSparxFlip(t *testing.T) {
	table, ids := sparxTestNames()
	withSparxTable(t, table)
	d := testDaemonWithIDs(t, true, ids)
	d.saveDir = t.TempDir()

	zeroed := sparxZeroedChest(t)
	baseDrops := sparxBackfill(t, d, ids, zeroed, "sparxflip")
	if d.sparxKnown["ChestBreaking"] {
		t.Fatal("the 0.0 key must stay unknown at baseline")
	}

	// 0->1 back: exactly one new drop with exactly the ChestBreaking check
	path := filepath.Join(d.saveDir, "FalconSave.106.sav")
	stampSave(t, path, loadSave(t, ref100Save))
	d.pollOnce()
	got := readDrop(t, d)
	if d.drops != baseDrops+1 {
		t.Fatalf("0->1 must drop once, drops=%d (base %d)", d.drops, baseDrops)
	}
	name := table["ChestBreaking"]
	if id := nameToIDCheck(t, d, name); got.Checks[0] != id || got.Names[0] != name {
		t.Fatalf("flip drop %v/%v must be exactly %q (id %d)", got.Names, got.Checks, name, id)
	}

	// 1->0: fires nothing, the known set does not un-learn
	stampSave(t, path, zeroed)
	d.pollOnce()
	if d.drops != baseDrops+1 {
		t.Fatalf("1->0 must drop nothing, drops=%d (base %d)", d.drops, baseDrops)
	}
	if !d.sparxKnown["ChestBreaking"] {
		t.Fatal("1->0 must not clear the known set (no un-learn)")
	}

	// unchanged save: no re-drop (dedup)
	d.lastPath = ""
	d.pollOnce()
	if d.drops != baseDrops+1 {
		t.Fatalf("already-sent sparx check must not drop again, drops=%d", d.drops)
	}
	t.Log("baseline {2} then 0->1 exactly ChestBreaking, then 1->0 nothing: OK")
}

// sparxZeroedChest is the 100% save with ChestBreaking's float zeroed: the
// shape a save that never obtained the power scans as.
func sparxZeroedChest(t *testing.T) []byte {
	t.Helper()
	data := loadSave(t, ref100Save)
	m := bytes.Index(data, []byte("collected.0.2.EIT_SparxPower_ChestBreaking\x00"))
	if m < 0 {
		t.Fatal("no ChestBreaking key in 100pct_ref")
	}
	valOff := m + len("collected.0.2.EIT_SparxPower_ChestBreaking\x00")
	if binary.LittleEndian.Uint32(data[valOff:]) != math.Float32bits(1) {
		t.Fatalf("fixture precondition: ChestBreaking value at %d must be 1", valOff)
	}
	zeroed := append([]byte(nil), data...)
	binary.LittleEndian.PutUint32(zeroed[valOff:], 0)
	return zeroed
}

// sparxBackfill polls the zeroed save in a fresh Spyro 3 session, asserts the
// baseline backfilled exactly the two obtained powers, and returns the drop
// count.
func sparxBackfill(t *testing.T, d *daemon, ids map[string]int, zeroed []byte, token string) int {
	t.Helper()
	writeSaveBytes(t, d, "FalconSave.106.sav", zeroed)
	writeSession(t, d, "slot=0\ngame=2\ntoken="+token+"\n")
	d.pollOnce()
	base := readDrop(t, d)
	if n := countIDs(base.Names, ids); n != 2 {
		t.Fatalf("baseline must backfill exactly the 2 obtained powers, got %d (%v)", n, base.Names)
	}
	return d.drops
}

// zeroSparxPower zeroes one Sparx power key's float in data.
func zeroSparxPower(t *testing.T, data []byte, power string) {
	t.Helper()
	key := []byte("collected.0.2.EIT_SparxPower_" + power + "\x00")
	m := bytes.Index(data, key)
	if m < 0 {
		t.Fatalf("no %s key", power)
	}
	binary.LittleEndian.PutUint32(data[m+len(key):], 0)
}

// TestDaemonSparxStaysZero pins the no-drop half of the flip contract: a save
// whose power float stays 0 (or goes 1->0 while already known from a zeroed
// baseline) drops nothing at all.
func TestDaemonSparxStaysZero(t *testing.T) {
	table, ids := sparxTestNames()
	withSparxTable(t, table)
	d := testDaemonWithIDs(t, true, ids)
	d.saveDir = t.TempDir()

	// baseline with ChestBreaking zeroed: 2 powers backfill, none for the 0.0 key
	zeroed := sparxZeroedChest(t)
	baseDrops := sparxBackfill(t, d, ids, zeroed, "sparxzero")
	if len(d.sparxKnown) != 2 {
		t.Fatalf("sparxKnown has %d entries, want 2 (the 0.0 key stays unknown)", len(d.sparxKnown))
	}

	// a save where the same float stays 0: nothing new drops
	zeroed2 := append([]byte(nil), zeroed...)
	// same content, fresh file: only the mtime changes
	stampSave(t, filepath.Join(d.saveDir, "FalconSave.105.sav"), zeroed2)
	d.pollOnce()
	if d.drops != baseDrops {
		t.Fatalf("staying 0 must drop nothing, drops=%d (base %d)", d.drops, baseDrops)
	}
	// and 1->0 on an already-known power (GemCollectRange) fires nothing either
	zeroSparxPower(t, zeroed2, "GemCollectRange")
	stampSave(t, filepath.Join(d.saveDir, "FalconSave.104.sav"), zeroed2)
	d.pollOnce()
	if d.drops != baseDrops {
		t.Fatalf("1->0 on a known power must drop nothing, drops=%d (base %d)", d.drops, baseDrops)
	}
	if len(d.sparxKnown) != 2 {
		t.Fatalf("sparxKnown must stay at 2, got %d", len(d.sparxKnown))
	}
	t.Log("0->0 and 1->0 on a known power both fire nothing: OK")
}

// TestDaemonSparxOptionGate pins the slot-option gating: sparxEnabled off must
// skip the scan entirely (the 100% save's 3 powers never enter known/drops),
// mirroring how the mod filters option-disabled checks.
func TestDaemonSparxOptionGate(t *testing.T) {
	d, _, ids := sparxDaemon(t, true, ref100Save)
	d.SetSparx(false)
	writeSession(t, d, "slot=0\ngame=2\ntoken=sparxoff\n")
	d.pollOnce()
	drop := readDrop(t, d)
	sent := nameSet(drop.Names)
	for name := range ids {
		if sent[name] {
			t.Fatalf("sparx-off slot must not send %q", name)
		}
	}
	if len(d.sparxKnown) != 0 {
		t.Fatalf("sparx-off slot must not learn powers, sparxKnown=%v", d.sparxKnown)
	}
	// re-arming mid-session: the next poll baselines-in (powers already sent
	// would be filtered by the mod; the daemon-side known set is empty, so a
	// fresh backfill is the expected behavior — the mod dedups)
	d.SetSparx(true)
	d.lastPath = ""
	d.pollOnce()
	got := readDrop(t, d)
	sparxSent := 0
	for _, n := range got.Names {
		if _, ok := ids[n]; ok {
			sparxSent++
		}
	}
	if sparxSent != 3 {
		t.Fatalf("re-armed slot must backfill the 3 powers, got %d (%v)", sparxSent, got.Names)
	}
	t.Log("sparx off: scan skipped; re-arm: baseline backfill: OK")
}

// TestDaemonSparxTransientSkip pins the transient-skip guards: an entry whose
// only scan surface is the file-global Sparx map (empty entries everywhere
// else) must not take the skip path when powers exist, and an all-zero Sparx
// map must not baseline an empty entry.
func TestDaemonSparxTransientSkip(t *testing.T) {
	table, ids := sparxTestNames()
	withSparxTable(t, table)
	d := testDaemon(t, true)
	for name, id := range ids {
		d.nameToID[name] = id
	}
	// synthetic save: no levelObjectMap entries at all (saveEntry fails for a
	// real pollOnce, so drive scanSpyro3 directly with a bare GVAS blob)
	blob := bytes.Join([][]byte{[]byte("GVAS"), gfmRecord(
		[2]any{"collected.0.2.EIT_SparxPower_GemCollectRange", float32(1)},
	)}, nil)
	s := session{slot: 0, game: 2, token: "sparxonly"}
	d.session = &s
	d.rawSave = blob
	d.scanSpyro3("synthetic", []byte("GVAS"))
	if d.drops != 1 {
		t.Fatalf("sparx-only scan must baseline and drop, drops=%d", d.drops)
	}
	got := readDrop(t, d)
	if len(got.Checks) != 1 || got.Names[0] != table["GemCollectRange"] {
		t.Fatalf("drop %v must be exactly %q", got.Names, table["GemCollectRange"])
	}
	// all-zero map: nothing scans, nothing baselines
	d2 := testDaemon(t, true)
	d2.session = &s
	d2.rawSave = bytes.Join([][]byte{[]byte("GVAS"), gfmRecord(
		[2]any{"collected.0.2.EIT_SparxPower_ExtraHP", float32(0)},
	)}, nil)
	d2.scanSpyro3("synthetic2", []byte("GVAS"))
	if d2.drops != 0 || d2.baselineOn {
		t.Fatalf("zero-powers-only scan must skip, drops=%d baseline=%t", d2.drops, d2.baselineOn)
	}
	t.Log("sparx-only scan baselines; zero-only map skips: OK")
}

// TestScanSparxPowersTruncated guards a mid-write save: a globalFloatMap
// header with a count past the file end fails without panicking.
func TestScanSparxPowersTruncated(t *testing.T) {
	data := loadSave(t, ref100Save)
	i := bytes.Index(data, []byte("globalFloatMap"))
	got, stats := ScanSparxPowers(data[:i+40], 0, 2)
	if len(got) != 0 || stats.Markers != 0 {
		t.Fatalf("truncated map must yield nothing, got %v (stats %+v)", got, stats)
	}
	t.Log("truncated map fails safe: OK")
}

// The Sparx golden shape: {"powers": [[slot, game, [names sorted]]] per
// fixture} — like the s3eggs goldens, generated by scripts/gen_golden.py
// against pygvas.
func TestScanSparxPowersGolden(t *testing.T) {
	for _, stem := range allFixtureStems {
		want := map[[2]int][]string{}
		for _, p := range goldenRows(t, stem, ".sparx.golden.json", "powers", 3) {
			slot := int(p[0].(float64))
			game := int(p[1].(float64))
			var names []string
			for _, raw := range p[2].([]any) {
				names = append(names, raw.(string))
			}
			want[[2]int{slot, game}] = names
		}
		data := loadSave(t, stem)
		for pair, names := range want {
			got, stats := ScanSparxPowers(data, pair[0], pair[1])
			if len(got) != len(names) {
				t.Fatalf("%s (%d,%d): got %v, want %v (stats %+v)", stem, pair[0], pair[1], got, names, stats)
			}
			for i := range names {
				if got[i] != names[i] {
					t.Fatalf("%s (%d,%d): got %v, want %v", stem, pair[0], pair[1], got, names)
				}
			}
		}
		t.Logf("%s: %d sparx golden pairs match: OK", stem, len(want))
	}
}

func TestScanSparxPowersTruncatedTag(t *testing.T) {
	data := []byte("GVASglobalFloatMap\x00\xff\xff\xff\x7f")
	got, _ := ScanSparxPowers(data, 0, 2)
	if got != nil {
		t.Fatalf("got %v, want nil for a tag length past the end of the save", got)
	}
}
