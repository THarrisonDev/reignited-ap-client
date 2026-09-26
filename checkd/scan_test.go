package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

const repoFixtures = "testdata"

const redGemMarker = "EInventoryType::EIT_RedGem"
const gemHashArrayTag = "GemHashArray\x00"
const swimMarker = "EInventoryType::EIT_Swimming"

// goldenRows reads testdata/<stem><suffix> (a scripts/gen_golden.py golden)
// and returns the rows under field, each checked to hold width values.
func goldenRows(t *testing.T, stem, suffix, field string, width int) [][]any {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", stem+suffix))
	if err != nil {
		t.Fatalf("read golden %s%s: %v", stem, suffix, err)
	}
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatalf("parse golden %s%s: %v", stem, suffix, err)
	}
	raw, ok := doc[field]
	if !ok {
		t.Fatalf("golden %s%s has no %q field", stem, suffix, field)
	}
	var rows [][]any
	if err := json.Unmarshal(raw, &rows); err != nil {
		t.Fatalf("parse golden %s%s field %q: %v", stem, suffix, field, err)
	}
	for _, r := range rows {
		if len(r) != width {
			t.Fatalf("%s: %s golden entry shape: %v", stem, field, r)
		}
	}
	return rows
}

// namedGolden loads a [region, name, collected] golden as a set keyed by
// (region, name), rejecting duplicate keys.
func namedGolden(t *testing.T, stem, suffix, field string) map[[2]string]bool {
	t.Helper()
	set := make(map[[2]string]bool)
	for _, r := range goldenRows(t, stem, suffix, field, 3) {
		region, _ := r[0].(string)
		name, _ := r[1].(string)
		collected, _ := r[2].(bool)
		key := [2]string{region, name}
		if _, dup := set[key]; dup {
			t.Fatalf("%s: %s golden duplicate: %v", stem, field, key)
		}
		set[key] = collected
	}
	return set
}

// expectNamedGolden checks named scan records against a namedGolden set: the
// same count, and every record present with the golden collected state.
func expectNamedGolden(t *testing.T, stem, what string, got []Dragon, stats ScanStats, want map[[2]string]bool) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("%s: scan returned %d %s records, golden has %d (stats: %+v)",
			stem, len(got), what, len(want), stats)
	}
	for _, d := range got {
		key := [2]string{d.Region, d.Name}
		wantCol, ok := want[key]
		if !ok {
			t.Fatalf("%s: scanned %s %v not in golden", stem, what, key)
		}
		if d.Collected != wantCol {
			t.Fatalf("%s: %s %v collected=%t, golden=%t", stem, what, key, d.Collected, wantCol)
		}
	}
	t.Logf("%s: %d %s records match golden: OK", stem, len(got), what)
}

// gemGolden loads a [region, value] gem golden as region -> value total.
func gemGolden(t *testing.T, stem, suffix string) map[string]int {
	t.Helper()
	want := make(map[string]int)
	for _, g := range goldenRows(t, stem, suffix, "gems", 2) {
		region, _ := g[0].(string)
		value, _ := g[1].(float64)
		want[region] = int(value)
	}
	return want
}

// expectGemGolden checks scanned gem totals against a gemGolden map: the same
// region count and every golden total.
func expectGemGolden(t *testing.T, stem, what string, got, want map[string]int, stats ...ScanStats) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("%s: %s scan returned %d regions, golden has %d (stats: %+v)",
			stem, what, len(got), len(want), stats)
	}
	for r, v := range want {
		if got[r] != v {
			t.Fatalf("%s: %s total for %s = %d, golden %d", stem, what, r, got[r], v)
		}
	}
	t.Logf("%s: %d %s regions match golden: OK", stem, len(got), what)
}

// mustCollectedOff returns the collected value byte offset of the record
// after the marker at m (collectedOff over the rest of the file), failing
// the test when the record has none.
func mustCollectedOff(t *testing.T, data []byte, m int) int {
	t.Helper()
	valOff := collectedOff(data, m, len(data))
	if valOff < 0 {
		t.Fatalf("no collected BoolProperty after the marker at %d", m)
	}
	return valOff
}

func loadSave(t *testing.T, stem string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(repoFixtures, stem+".sav"))
	if err != nil {
		t.Fatalf("read save fixture: %v", err)
	}
	return b
}

// fixture stems shared by the golden-driven suites; kept in step with
// scripts/gen_fixtures.py's STEMS. allFixtureStems adds the full 100%
// playthrough fixture the per-fixture suites cover separately.
var (
	fixtureStems    = []string{"snapshot1", "snapshot2", "snapshot3", "mid_s1", "mixed_s1_s2", eventsSave}
	allFixtureStems = append(fixtureStems, ref100Save)
)

func testScanMatchesGolden(t *testing.T, stem string) {
	t.Helper()
	got, stats := ScanSave(loadSave(t, stem))
	expectNamedGolden(t, stem, "dragon", got, stats, namedGolden(t, stem, ".golden.json", "dragons"))
}

func TestScanSnapshot1(t *testing.T) { testScanMatchesGolden(t, "snapshot1") }
func TestScanSnapshot2(t *testing.T) { testScanMatchesGolden(t, "snapshot2") }
func TestScanSnapshot3(t *testing.T) { testScanMatchesGolden(t, "snapshot3") }
func TestScanMidS1(t *testing.T)     { testScanMatchesGolden(t, "mid_s1") }
func TestScanMixedS1S2(t *testing.T) { testScanMatchesGolden(t, "mixed_s1_s2") }
func TestScan100pctRef(t *testing.T) { testScanMatchesGolden(t, "100pct_ref") }

func loadEggGolden(t *testing.T, stem string) [][3]any {
	t.Helper()
	var out [][3]any
	for _, e := range goldenRows(t, stem, ".eggs.golden.json", "eggs", 3) {
		region, _ := e[0].(string)
		ord, _ := e[1].(float64)
		collected, _ := e[2].(bool)
		out = append(out, [3]any{region, int(ord), collected})
	}
	return out
}

func TestScanEggsMatchesGolden(t *testing.T) {
	for _, stem := range allFixtureStems {
		want := loadEggGolden(t, stem)
		data := loadSave(t, stem)
		got, stats := ScanEggs(data)
		if len(got) != len(want) {
			t.Fatalf("%s: ScanEggs returned %d eggs, golden has %d (stats: %+v)",
				stem, len(got), len(want), stats)
		}
		for i, e := range got {
			w := want[i]
			if e.Region != w[0] || e.Ordinal != w[1] || e.Collected != w[2] {
				t.Fatalf("%s: egg %d = {%s %d %t}, golden %v", stem, i,
					e.Region, e.Ordinal, e.Collected, w)
			}
			if !e.Collected {
				t.Fatalf("%s: egg %d golden entries are collected-only", stem, i)
			}
		}
		t.Logf("%s: %d eggs match golden: OK", stem, len(got))
	}
}

// TestScanEggsFlip mutates snapshot3's collected egg record so the Stone Hill
// egg reads uncollected and asserts the scan result follows (real fixture
// byte flip): no collected eggs remain, the record itself still scans as
// {Stone Hill, ordinal 0, false}, and catalog lookups for skipped ordinals
// fail.
func TestScanEggsFlip(t *testing.T) {
	data := loadSave(t, "snapshot3")
	m := bytes.Index(data, []byte(eggMarker))
	if m < 0 {
		t.Fatal("no egg marker in snapshot3")
	}
	valOff := mustCollectedOff(t, data, m)
	if data[valOff] != 1 {
		t.Fatalf("expected collected egg value byte 1 at %d, got %d", valOff, data[valOff])
	}
	mutated := append([]byte(nil), data...)
	mutated[valOff] = 0
	eggs, _ := ScanEggs(mutated)
	if len(eggs) != 1 {
		t.Fatalf("expected 1 scanned record after clearing the Stone Hill egg, got %v", eggs)
	}
	if eggs[0].Region != "Stone Hill" || eggs[0].Collected || eggs[0].Ordinal != 0 {
		t.Fatalf("uncollected record must be {Stone Hill 0 false}, got %v", eggs[0])
	}
	d := newDaemon(nil, mustEggCatalog(t), nil, func(string, ...any) {})
	if _, ok := d.eggLocation(Egg{Region: "Stone Hill", Ordinal: 0}); ok {
		t.Fatal("ordinal 0 must not resolve to a location")
	}
	t.Log("Stone Hill collected flip -> record {Stone Hill, 0, false}: OK")
}

// TestScanS3EggsMatchesGolden checks the Spyro 3 egg records against the
// pygvas golden (game-2 entries only): the 100% playthrough's 150 named eggs,
// zero for every other fixture's game-2 entries.
func TestScanS3EggsMatchesGolden(t *testing.T) {
	for _, stem := range allFixtureStems {
		got, stats := ScanS3Eggs(loadSave(t, stem))
		expectNamedGolden(t, stem, "Spyro 3 egg", got, stats, namedGolden(t, stem, ".s3eggs.golden.json", "eggs"))
	}
}

// TestScanS3EggsSpotChecks pins the named-egg identities the spec calls out,
// each resolving through the init-built spyro3Locations table (including the
// one EIT_S3BonusEgg record, "Al").
func TestScanS3EggsSpotChecks(t *testing.T) {
	data := loadSave(t, ref100Save)
	eggs, stats := ScanS3Eggs(data)
	if len(eggs) != 150 {
		t.Fatalf("ScanS3Eggs found %d records (stats %+v), want 150", len(eggs), stats)
	}
	want := map[[2]string]bool{
		{"Sunny Villa", "Sanders"}:       true,
		{"Midnight Mountain", "Al"}:      true,
		{"Super Bonus Round", "YinYang"}: true,
		{"Sorceress Lair", "George"}:     true,
		{"Buzz's Dungeon", "Grayson"}:    true,
	}
	for _, e := range eggs {
		if !want[[2]string{e.Region, e.Name}] {
			continue
		}
		if !e.Collected {
			t.Fatalf("spot-check egg %v must be collected in the 100%% save", e)
		}
		loc, ok := spyro3Locations[checkKey{"egg", e.Region, e.Name}]
		if !ok {
			t.Fatalf("egg %v missing from the init-built table", e)
		}
		if _, ok := nameToIDForTest(t)[loc]; !ok {
			t.Fatalf("location %q not in nameToID", loc)
		}
		want[[2]string{e.Region, e.Name}] = false
	}
	for k, pending := range want {
		if pending {
			t.Fatalf("spot-check egg %v not scanned from the 100%% save", k)
		}
	}
	t.Log("Sanders/Al/YinYang/George/Grayson all scanned and resolve: OK")
}

// TestScanS3EggsFlip mutates 100pct_ref's first egg record (Sunrise Spring,
// the earliest marker in the file) collected 1->0 and asserts the scan result
// follows: exactly that one record reads uncollected, all 149 others stay.
func TestScanS3EggsFlip(t *testing.T) {
	data := loadSave(t, ref100Save)
	eggs, stats := ScanS3Eggs(data)
	if len(eggs) != 150 {
		t.Fatalf("fixture precondition: %d egg records, want 150 (stats %+v)", len(eggs), stats)
	}
	m := bytes.Index(data, []byte(s3EggMarker))
	if m < 0 {
		t.Fatal("no S3 egg marker in 100pct_ref")
	}
	valOff := mustCollectedOff(t, data, m)
	if data[valOff] != 1 {
		t.Fatalf("fixture precondition: egg value byte at %d must be 1", valOff)
	}
	mutated := append([]byte(nil), data...)
	mutated[valOff] = 0
	got, _ := ScanS3Eggs(mutated)
	if len(got) != 150 {
		t.Fatalf("flip changed record count: %d records, want 150", len(got))
	}
	uncollected := 0
	for _, e := range got {
		if !e.Collected {
			uncollected++
			if e.Region != "Sunrise Spring" {
				t.Fatalf("cleared record must be the first egg's region, got %v", e)
			}
		}
	}
	if uncollected != 1 {
		t.Fatalf("flip must clear exactly 1 record, cleared %d", uncollected)
	}
	t.Log("first egg collected flip 1->0: record uncollected, the other 149 untouched: OK")
}

// TestScanS3EggsLeakGuard: the S1/S2 fixtures hold no S3 egg markers (the S1
// egg marker differs and the S2 games record none), so their scans must stay
// empty — entry scoping by marker type alone.
func TestScanS3EggsLeakGuard(t *testing.T) {
	for _, stem := range fixtureStems {
		got, stats := ScanS3Eggs(loadSave(t, stem))
		if len(got) != 0 || stats.Markers != 0 {
			t.Fatalf("%s: want no S3 egg records, got %d (stats %+v)", stem, len(got), stats)
		}
	}
	// the 100% save's S1 (entry 0) and S2 (entry 3) playthroughs hold none either
	data := loadSave(t, ref100Save)
	if got, _ := ScanS3Eggs(mustEntry(t, data, entryIndex(0, 0))); len(got) != 0 {
		t.Fatalf("Spyro 1 entry holds S3 egg records: %+v", got)
	}
	if got, _ := ScanS3Eggs(mustEntry(t, data, entryIndex(0, 1))); len(got) != 0 {
		t.Fatalf("Spyro 2 entry holds S3 egg records: %+v", got)
	}
	t.Log("S3 egg scan empty on every non-S3 entry: OK")
}

func TestScanGemsMatchesGolden(t *testing.T) {
	for _, stem := range allFixtureStems {
		data := loadSave(t, stem)
		got1, stats := ScanGems(data)
		got2, stats2 := ScanSpyro2Gems(data)
		got := make(map[string]int)
		for r, v := range got1 {
			got[r] = v
		}
		for r, v := range got2 {
			if v > got[r] {
				got[r] = v
			}
		}
		expectGemGolden(t, stem, "ScanGems+ScanSpyro2Gems", got, gemGolden(t, stem, ".gems.golden.json"), stats, stats2)
	}
}

// TestScanAbilitiesMatchesGolden checks the Money Bags ability records against
// the pygvas golden: bare names only (EIT_Superflame must never appear), all
// three types present per fixture.
func TestScanAbilitiesMatchesGolden(t *testing.T) {
	for _, stem := range allFixtureStems {
		want := make(map[[2]string]bool)
		for _, a := range goldenRows(t, stem, ".abilities.golden.json", "abilities", 2) {
			name, _ := a[0].(string)
			collected, _ := a[1].(bool)
			want[[2]string{"", name}] = collected
		}
		got, stats := ScanAbilities(loadSave(t, stem))
		for _, d := range got {
			if d.Region != "" {
				t.Fatalf("%s: ability record must have no region, got %+v", stem, d)
			}
		}
		expectNamedGolden(t, stem, "ability", got, stats, want)
	}
}

// TestScanSpyro3GemsMatchesGolden checks the Spyro 3 gem totals against the
// pygvas golden (game-2 entries only): the 100% playthrough's 29 gem-bearing
// regions, empty for every other fixture.
func TestScanSpyro3GemsMatchesGolden(t *testing.T) {
	for _, stem := range allFixtureStems {
		got, stats := ScanSpyro3Gems(loadSave(t, stem))
		expectGemGolden(t, stem, "ScanSpyro3Gems", got, gemGolden(t, stem, ".s3gems.golden.json"), stats)
	}
}

// TestScanGemsFlip mutates snapshot2's Artisans GemHashArray count fields so
// the scanned value crosses thresholds and asserts the totals move by exactly
// value x delta against the real fixture bytes (Artisans: 18 red, 2 green,
// 3 S2 red = 25 value). Bumping red by 30 (+30 value) reaches 55: past the
// 25% threshold of Artisans' 100 total (25) and the 50% one (50), under 75.
func TestScanGemsFlip(t *testing.T) {
	data := loadSave(t, "snapshot2")
	before, stats := ScanGems(data)
	if before["Artisans"] != 25 {
		t.Fatalf("fixture precondition: Artisans = %d, want 25 (stats %+v)", before["Artisans"], stats)
	}
	m := bytes.Index(data, []byte(redGemMarker+"\x00\x0d\x00\x00\x00"+gemHashArrayTag))
	if m < 0 {
		t.Fatal("no EIT_RedGem GemHashArray record in snapshot2")
	}
	countOff := m + len(redGemMarker) + 1 + 4 + 13 + 4 + 14 + 8 + 4 + 12 + 1
	if count := int(binary.LittleEndian.Uint32(data[countOff:])); count != 18 {
		t.Fatalf("fixture precondition: red count at %d = %d, want 18", countOff, count)
	}
	mutated := append([]byte(nil), data...)
	binary.LittleEndian.PutUint32(mutated[countOff:], 18+30)
	binary.LittleEndian.PutUint64(mutated[countOff-25:], uint64(4+4*(18+30)))
	after, _ := ScanGems(mutated)
	if after["Artisans"] != 25+30 {
		t.Fatalf("bumping red count 18->48: total %d, want 55", after["Artisans"])
	}
	if before["Artisans"] != 25 {
		t.Fatalf("ScanGems must not alias input, before mutated: %v", before)
	}
	t.Log("real-fixture count bump: total follows count*value exactly: OK")
}

// TestScanAbilitiesFlip sets the Swim flag of mixed_s1_s2's first record
// (the Spyro 1 entry's, 0->1 like a fresh purchase) and asserts the merged
// whole-file scan follows via collected-wins: Swim turns collected while the
// still-false Spyro 2 entry stays outvoted, exactly like the pygvas merge.
func TestScanAbilitiesFlip(t *testing.T) {
	data := loadSave(t, "mixed_s1_s2")
	abilities, _ := ScanAbilities(data)
	if len(abilities) != 3 {
		t.Fatalf("fixture precondition: %d ability records, want 3", len(abilities))
	}
	for _, a := range abilities {
		if a.Collected {
			t.Fatalf("fixture precondition: mixed_s1_s2 abilities all uncollected, got %+v", a)
		}
	}
	m := bytes.Index(data, []byte(swimMarker))
	if m < 0 {
		t.Fatal("no swim marker in mixed_s1_s2")
	}
	valOff := mustCollectedOff(t, data, m)
	if valOff >= len(data) || data[valOff] != 0 {
		t.Fatalf("fixture precondition: swim value byte at %d must be 0", valOff)
	}
	mutated := append([]byte(nil), data...)
	mutated[valOff] = 1
	got, _ := ScanAbilities(mutated)
	if len(got) != 3 {
		t.Fatalf("flip changed record count: %d records, want 3", len(got))
	}
	for _, a := range got {
		want := a.Name == "Swim"
		if a.Collected != want {
			t.Fatalf("after the flip %q collected=%t, want %t (collected-wins merge)", a.Name, a.Collected, want)
		}
	}
	t.Log("swim flag flip 0->1: merged record collected, others untouched: OK")
}

func TestScanRejectsNonGVAS(t *testing.T) {
	dragons, stats := ScanSave([]byte("NOT_GVAS at all"))
	if dragons != nil || stats.Markers != 0 {
		t.Fatalf("non-GVAS input must yield nothing, got %v %+v", dragons, stats)
	}
	gems, gemStats := ScanGems([]byte("NOT_GVAS at all"))
	if gems != nil || gemStats.Markers != 0 {
		t.Fatalf("non-GVAS gem input must yield nothing, got %v %+v", gems, gemStats)
	}
	abilities, abilityStats := ScanAbilities([]byte("NOT_GVAS at all"))
	if abilities != nil || abilityStats.Markers != 0 {
		t.Fatalf("non-GVAS ability input must yield nothing, got %v %+v", abilities, abilityStats)
	}
	eggs, eggStats := ScanS3Eggs([]byte("NOT_GVAS at all"))
	if eggs != nil || eggStats.Markers != 0 {
		t.Fatalf("non-GVAS egg input must yield nothing, got %v %+v", eggs, eggStats)
	}
	t.Log("non-GVAS rejected: OK")
}

func TestFindMarkersBothForms(t *testing.T) {
	ascii := "EIT_Dragon"
	data := []byte("xx" + ascii + "yy")
	u16 := utf16Bytes(ascii)
	data = append(data, 'B')
	data = append(data, u16...)
	offs := findMarkers(data, ascii)
	if len(offs) != 2 {
		t.Fatalf("expected 2 markers, got %v", offs)
	}
	if string(data[offs[0]:offs[0]+len(ascii)]) != ascii {
		t.Fatalf("ascii marker mismatch at %d", offs[0])
	}
	if string(data[offs[1]:offs[1]+2*len(ascii)]) != string(u16) {
		t.Fatalf("utf16 marker mismatch at %d", offs[1])
	}
	t.Log("ASCII + UTF-16LE marker forms both found: OK")
}

func TestReadFStringANSI(t *testing.T) {
	data := []byte{0x07, 0x00, 0x00, 0x00}
	data = append(data, "Nestor\x00"...)
	s, ok := readFString(data, 0)
	if !ok || s != "Nestor" {
		t.Fatalf("ANSI FString: got %q ok=%t", s, ok)
	}
	t.Log("FString positive/ANSI decode: OK")
}

func TestReadFStringUTF16(t *testing.T) {
	// -6 code units: 5 chars + NUL unit
	data := []byte{0xfa, 0xff, 0xff, 0xff}
	for _, c := range "Gildas" {
		data = append(data, byte(c), 0)
	}
	data = append(data, 0, 0)
	s, ok := readFString(data, 0)
	if !ok || s != "Gildas" {
		t.Fatalf("UTF-16 FString: got %q ok=%t", s, ok)
	}
	t.Log("FString negative/UTF-16 decode: OK")
}

func TestFStringZeroLength(t *testing.T) {
	s, ok := readFString([]byte{0, 0, 0, 0}, 0)
	if !ok || s != "" {
		t.Fatalf("empty FString: got %q ok=%t", s, ok)
	}
	t.Log("FString zero length: OK")
}

func mustEggCatalog(t *testing.T) map[string][]string {
	t.Helper()
	_, eggCatalog, _, err := embeddedLocations()
	if err != nil {
		t.Fatalf("load embedded eggCatalog: %v", err)
	}
	return eggCatalog
}

func TestEggCatalogResolution(t *testing.T) {
	d := newDaemon(nil, mustEggCatalog(t), nil, func(string, ...any) {})

	startArea, ok := d.eggLocation(Egg{Region: "Magic Crafters", Ordinal: 1})
	if !ok || startArea != "Spyro 1: Magic Crafters: Catch the egg thief (start area)" {
		t.Fatalf("Magic Crafters #1: got %q ok=%t", startArea, ok)
	}
	ramp, ok := d.eggLocation(Egg{Region: "Magic Crafters", Ordinal: 2})
	if !ok || ramp != "Spyro 1: Magic Crafters: Catch the egg thief (supercharge ramp)" {
		t.Fatalf("Magic Crafters #2: got %q ok=%t", ramp, ok)
	}
	if _, ok := d.eggLocation(Egg{Region: "Magic Crafters", Ordinal: 3}); ok {
		t.Fatal("Magic Crafters #3 must be out of range")
	}
	if _, ok := d.eggLocation(Egg{Region: "Nowhere", Ordinal: 1}); ok {
		t.Fatal("unknown region must not resolve")
	}
	if _, ok := d.eggLocation(Egg{Region: "Stone Hill", Ordinal: 0}); ok {
		t.Fatal("ordinal 0 must not resolve")
	}

	nameToID, _, _, err := embeddedLocations()
	if err != nil {
		t.Fatalf("load locations.json: %v", err)
	}
	if id := nameToID[startArea]; id != 100045 {
		t.Fatalf("Magic Crafters egg-thief id: got %d", id)
	}
	t.Log("eggCatalog (region, ordinal) -> name resolution: OK")
}
