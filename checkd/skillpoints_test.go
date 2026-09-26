package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// spRecord builds one GVAS skill-point record: the EIT_SkillPoint item with a
// saveParams array holding one empty-named param per value (the layout
// scanSkillPointsOne pins, byte-verified against the real saves), followed by
// a trailing filler byte.
func spRecord(vals ...float32) []byte {
	var b bytes.Buffer
	enc := func(s string) {
		_ = binary.Write(&b, binary.LittleEndian, int32(len(s)+1))
		b.WriteString(s)
		b.WriteByte(0)
	}
	u32 := func(v uint32) { _ = binary.Write(&b, binary.LittleEndian, v) }
	guid := func() {
		for i := 0; i < 16; i++ {
			b.WriteByte(0)
		}
	}
	// itemData struct (sizes/array-indices/guids are never validated by the
	// scanner — only the saveParams array's shape is)
	enc("itemData")
	enc("StructProperty")
	u32(0)
	u32(0)
	enc("PhasmidInventoryData")
	guid()
	b.WriteByte(0)
	enc("ItemType")
	enc("EnumProperty")
	u32(0)
	u32(0)
	enc("EInventoryType")
	b.WriteByte(0) // the enum value byte (EIT_SkillPoint = 36)
	enc(skillPointMarker)
	// collected BoolProperty: always false, only shape-checked
	enc("collected")
	enc("BoolProperty")
	u32(0)
	u32(0)
	b.WriteByte(0) // value byte
	b.WriteByte(0) // terminator
	enc("None")
	// itemParamList struct
	enc("itemParamList")
	enc("StructProperty")
	u32(0) // size
	u32(0) // array index
	enc("PhasmidSaveParamList")
	guid()
	b.WriteByte(0)
	// saveParams array: u64 bodyLen, inner type tag + its NUL + the array's
	// own NUL, u32 count, repeated field name + member type, per-element header
	enc("saveParams")
	enc("ArrayProperty")
	arrSizeAt := b.Len()
	u32(0) // bodyLen low half, patched below
	u32(0) // bodyLen high half
	enc("StructProperty")
	b.WriteByte(0) // the array's own NUL (real saves carry it before the count)
	bodyStart := b.Len()
	u32(uint32(len(vals)))
	enc("saveParams")
	enc("StructProperty")
	elemBodyLenAt := b.Len()
	u32(0) // element bodyLen, patched below
	u32(0) // element array index
	enc("PhasmidSaveParam")
	guid()
	b.WriteByte(0)
	elemStart := b.Len()
	for _, v := range vals {
		enc("paramName")
		enc("StrProperty")
		u32(4)
		u32(0)
		b.WriteByte(0)
		u32(0)
		enc("paramValue")
		enc("FloatProperty")
		u32(4)
		u32(0)
		b.WriteByte(0)
		_ = binary.Write(&b, binary.LittleEndian, math.Float32bits(v))
		enc("None")
	}
	elemEnd := b.Len()
	enc("None") // PhasmidSaveParamList terminator
	bodyEnd := b.Len()
	// patch: the array's u64 bodyLen and the elements' u32 bodyLen
	binary.LittleEndian.PutUint32(b.Bytes()[arrSizeAt:], uint32(bodyEnd-bodyStart))
	binary.LittleEndian.PutUint32(b.Bytes()[elemBodyLenAt:], uint32(elemEnd-elemStart))
	b.WriteByte('E') // trailing byte past the record
	return b.Bytes()
}

func TestScanSkillPoints100pct(t *testing.T) {
	data := loadSave(t, ref100Save)
	want := map[int][]int{
		entryIndex(0, 0): {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14},
		entryIndex(0, 1): {15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30},
		entryIndex(0, 2): {31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50},
	}
	for idx, wantVals := range want {
		got, stats := ScanSkillPoints(mustEntry(t, data, idx))
		if stats.Markers != 1 || stats.Skipped != 0 {
			t.Fatalf("entry %d: stats %+v, want 1 marker 0 skipped", idx, stats)
		}
		if len(got) != len(wantVals) {
			t.Fatalf("entry %d: got %v, want %v", idx, got, wantVals)
		}
		for i, v := range got {
			if v != wantVals[i] {
				t.Fatalf("entry %d: got %v, want %v", idx, got, wantVals)
			}
		}
		t.Logf("entry %d: %d skill points: OK", idx, len(got))
	}
}

func TestScanSkillPointsFreshAndMirror(t *testing.T) {
	// fresh-ish S1 snapshots hold the record with an empty saveParams array;
	// the mirror blob holds one earned point (enum 4); mixed_s1_s2's S1 slot-1
	// playthrough holds {1}, its S2 slot-1 entry none yet.
	cases := []struct {
		stem string
		idx  int
		want []int
	}{
		{"snapshot1", 0, nil},
		{"snapshot2", 0, nil},
		{"snapshot3", 0, nil},
		{"mid_s1", 0, []int{4}},
		{"mixed_s1_s2", 1, []int{1}},
		{"mixed_s1_s2", 4, nil},
	}
	for _, c := range cases {
		got, stats := ScanSkillPoints(mustEntry(t, loadSave(t, c.stem), c.idx))
		if stats.Skipped != 0 {
			t.Fatalf("%s entry %d: stats %+v", c.stem, c.idx, stats)
		}
		if len(got) != len(c.want) {
			t.Fatalf("%s entry %d: got %v, want %v (stats %+v)", c.stem, c.idx, got, c.want, stats)
		}
		for i, v := range got {
			if v != c.want[i] {
				t.Fatalf("%s entry %d: got %v, want %v", c.stem, c.idx, got, c.want)
			}
		}
	}
	t.Log("fresh entries scan empty, mirror {4}, mixed S1 {1}: OK")
}

func TestScanSkillPointsMergesMarkers(t *testing.T) {
	a := spRecord(1, 4, 7)
	b := spRecord(7, 9)
	data := bytes.Join([][]byte{[]byte("GVAS"), a, b}, nil)
	got, stats := ScanSkillPoints(data)
	if stats.Markers != 2 || stats.Skipped != 0 {
		t.Fatalf("stats %+v, want 2 markers 0 skipped", stats)
	}
	want := []int{1, 4, 7, 9}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v (dedupe+sort)", got, want)
	}
	for i, v := range got {
		if v != want[i] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
	t.Log("two markers merged deduped sorted: OK")
}

func TestScanSkillPointsRejectsNonGVAS(t *testing.T) {
	got, stats := ScanSkillPoints([]byte("NOT_GVAS at all"))
	if got != nil || stats.Markers != 0 {
		t.Fatalf("non-GVAS input must yield nothing, got %v %+v", got, stats)
	}
	t.Log("non-GVAS rejected: OK")
}

func TestScanSkillPointsSkipsTruncatedRecord(t *testing.T) {
	data := loadSave(t, ref100Save)
	m := bytes.Index(data, []byte(skillPointMarker))
	if m < 0 {
		t.Fatal("no skill-point marker in 100pct_ref")
	}
	got, stats := ScanSkillPoints(data[:m+60])
	if len(got) != 0 || stats.Markers != 1 || stats.Skipped != 1 {
		t.Fatalf("truncated record: got %v stats %+v, want [] 1 marker 1 skipped", got, stats)
	}
	t.Log("truncated record skipped: OK")
}

// TestSkillPointTables pins the init-built enum tables against the embedded
// locations.json: every ESkillPoint range is covered, and each location
// resolves through nameToID.
func TestSkillPointTables(t *testing.T) {
	nameToID := nameToIDForTest(t)
	for game, table := range []map[int]string{spyro1SkillPoints, spyro2SkillPoints, spyro3SkillPoints} {
		lo, hi := skillPointRanges[game][0], skillPointRanges[game][1]
		if len(table) != hi-lo+1 {
			t.Fatalf("game %d: enum table has %d rows, want %d", game, len(table), hi-lo+1)
		}
		for v := lo; v <= hi; v++ {
			loc, ok := table[v]
			if !ok {
				t.Fatalf("game %d: enum %d missing from the table", game, v)
			}
			if _, ok := nameToID[loc]; !ok {
				t.Fatalf("game %d: location %q not in nameToID", game, loc)
			}
		}
	}
	t.Log("enum tables cover 1..14/15..30/31..50, all resolving: OK")
}

// spTestNames builds the synthetic enum -> location table used by the daemon
// tests below, plus the nameToID extension for it.
func spTestNames(game int) (map[int]string, map[string]int) {
	lo, hi := skillPointRanges[game][0], skillPointRanges[game][1]
	table := map[int]string{}
	ids := map[string]int{}
	for v := lo; v <= hi; v++ {
		name := fmt.Sprintf("Spyro %d: Test Skill Point %d", game+1, v)
		table[v] = name
		ids[name] = 900000 + game*1000 + v
	}
	return table, ids
}

// withSkillPointTable swaps one game's enum table for a synthetic one and
// restores it when the test ends.
func withSkillPointTable(t *testing.T, game int, table map[int]string) {
	t.Helper()
	orig := [...]map[int]string{spyro1SkillPoints, spyro2SkillPoints, spyro3SkillPoints}[game]
	var restore func()
	switch game {
	case 0:
		spyro1SkillPoints = table
		restore = func() { spyro1SkillPoints = orig }
	case 1:
		spyro2SkillPoints = table
		restore = func() { spyro2SkillPoints = orig }
	default:
		spyro3SkillPoints = table
		restore = func() { spyro3SkillPoints = orig }
	}
	t.Cleanup(restore)
}

// TestDaemonSkillPointBackfill drives the real pollOnce path on the 100% Spyro
// 1 save: with backfill, the baseline drop contains exactly the 14 earned S1
// skill points resolved through the (synthetic) enum table, alongside the
// dragons/eggs/gems.
func TestDaemonSkillPointBackfill(t *testing.T) {
	table, ids := spTestNames(0)
	withSkillPointTable(t, 0, table)
	d := testDaemon(t, true)
	for name, id := range ids {
		d.nameToID[name] = id
	}
	d.saveDir = t.TempDir()
	if err := os.WriteFile(filepath.Join(d.saveDir, "FalconSave.106.sav"), loadSave(t, ref100Save), 0644); err != nil {
		t.Fatal(err)
	}
	writeSession(t, d, "slot=0\ngame=0\ntoken=sps1\n")
	d.pollOnce()
	drop := readDrop(t, d)
	sent := map[string]bool{}
	for _, n := range drop.Names {
		sent[n] = true
	}
	for v := 1; v <= 14; v++ {
		name := table[v]
		if !sent[name] {
			t.Fatalf("skill point %d (%q) missing from the baseline drop %v", v, name, drop.Names)
		}
		if id := nameToIDCheck(t, d, name); id != ids[name] {
			t.Fatalf("skill point %d id %d, want %d", v, id, ids[name])
		}
	}
	if len(d.spKnown) != 14 {
		t.Fatalf("spKnown has %d entries, want 14", len(d.spKnown))
	}
	t.Logf("100pct_ref S1 baseline: %d checks incl. all 14 skill points: OK", len(drop.Checks))
}

// TestDaemonSkillPointFlip drives the real pollOnce path across two fixture
// saves in one session: the mirror blob's {4} baselines (backfill sends
// exactly that one skill point), then the 100% save's {1..14} drops the 13
// fresh ones — enum 4 stays known and is not re-sent.
func TestDaemonSkillPointFlip(t *testing.T) {
	table, ids := spTestNames(0)
	withSkillPointTable(t, 0, table)
	d := testDaemon(t, true)
	for name, id := range ids {
		d.nameToID[name] = id
	}
	d.saveDir = t.TempDir()

	path := filepath.Join(d.saveDir, "FalconSave.106.sav")
	if err := os.WriteFile(path, loadSave(t, "mid_s1"), 0644); err != nil {
		t.Fatal(err)
	}
	writeSession(t, d, "slot=0\ngame=0\ntoken=spflip\n")
	d.pollOnce()
	base := readDrop(t, d)
	sent := map[string]bool{}
	spBase := 0
	for _, n := range base.Names {
		sent[n] = true
		if _, ok := ids[n]; ok {
			spBase++
		}
	}
	if spBase != 1 || !sent[table[4]] {
		t.Fatalf("baseline must backfill exactly the mirror's 1 skill point, got %d (%v)", spBase, base.Names)
	}
	baseDrops := d.drops

	// flip: the 100% save adds 13 new skill points
	time.Sleep(20 * time.Millisecond)
	if err := os.WriteFile(filepath.Join(d.saveDir, "FalconSave.105.sav"), loadSave(t, ref100Save), 0644); err != nil {
		t.Fatal(err)
	}
	d.pollOnce()
	got := readDrop(t, d)
	spFlip := 0
	for _, n := range got.Names {
		if _, ok := ids[n]; ok {
			spFlip++
			sent[n] = true
		}
	}
	if spFlip != 13 {
		t.Fatalf("flip must drop exactly the 13 new skill points, got %d (%v)", spFlip, got.Names)
	}
	if sent[table[4]] && spBase == 1 {
		if n := table[4]; contains(got.Names, n) {
			t.Fatalf("already-known skill point 4 re-sent in the flip drop")
		}
	}
	if len(d.spKnown) != 14 {
		t.Fatalf("spKnown has %d entries, want 14", len(d.spKnown))
	}
	_ = baseDrops
	t.Log("baseline {4} then flip {1..14}\\{4}: OK")
}

// TestDaemonSkillPointNoBackfill: with --no-backfill the baseline logs the
// earned skill points but sends nothing until a new enum appears.
func TestDaemonSkillPointNoBackfill(t *testing.T) {
	table, ids := spTestNames(0)
	withSkillPointTable(t, 0, table)
	d := testDaemon(t, false)
	for name, id := range ids {
		d.nameToID[name] = id
	}
	d.saveDir = t.TempDir()

	path := filepath.Join(d.saveDir, "FalconSave.106.sav")
	if err := os.WriteFile(path, loadSave(t, "mid_s1"), 0644); err != nil {
		t.Fatal(err)
	}
	writeSession(t, d, "slot=0\ngame=0\ntoken=spnb\n")
	d.pollOnce()
	if d.drops != 0 {
		t.Fatalf("no-backfill baseline must drop nothing, drops=%d", d.drops)
	}
	if len(d.spKnown) != 1 || !d.spKnown[4] {
		t.Fatalf("baseline must still learn {4}, spKnown=%v", d.spKnown)
	}

	time.Sleep(20 * time.Millisecond)
	if err := os.WriteFile(filepath.Join(d.saveDir, "FalconSave.105.sav"), loadSave(t, ref100Save), 0644); err != nil {
		t.Fatal(err)
	}
	d.pollOnce()
	got := readDrop(t, d)
	spSent := []string{}
	for _, n := range got.Names {
		if _, ok := ids[n]; ok {
			spSent = append(spSent, n)
		}
	}
	if len(spSent) != 13 {
		t.Fatalf("post-baseline flip must send the 13 new skill points, got %v", spSent)
	}
	for _, n := range spSent {
		if n == table[4] {
			t.Fatalf("enum 4 was known at baseline and must not re-send")
		}
	}
	t.Log("no-backfill: baseline logs only, first flip sends the 13 new enums: OK")
}

// TestDaemonSpyro1IgnoresForeignSkillPoints pins the range filter: a Spyro 1
// session must not send the S2/S3 enums its save entry does not hold (the
// synthetic table only covers S1's 1..14, and out-of-range values never
// become keys).
func TestDaemonSpyro1IgnoresForeignSkillPoints(t *testing.T) {
	table, ids := spTestNames(0)
	withSkillPointTable(t, 0, table)
	d := testDaemon(t, true)
	for name, id := range ids {
		d.nameToID[name] = id
	}
	sps := []int{1, 15, 31, 50}
	got := d.spFlip(sps, 0)
	if len(got) != 1 || got[0].name != "1" {
		t.Fatalf("spFlip game 0 on %v must keep only enum 1, got %v", sps, got)
	}
	got = d.spFlip([]int{15, 16}, 1)
	if len(got) != 2 {
		t.Fatalf("spFlip game 1 must keep 15/16, got %v", got)
	}
	if d.spFlip([]int{1}, 0) != nil {
		t.Fatal("already-known enum must not re-fire")
	}
	t.Log("range filter + dedup on spFlip: OK")
}

func contains(names []string, n string) bool {
	for _, s := range names {
		if s == n {
			return true
		}
	}
	return false
}

func nameToIDCheck(t *testing.T, d *daemon, name string) int {
	t.Helper()
	id, ok := d.nameToID[name]
	if !ok {
		t.Fatalf("location %q not in nameToID", name)
	}
	return id
}

func TestScanSkillPointsRejectsBadBodyLen(t *testing.T) {
	rec := spRecord(1, 4)
	k := bytes.Index(rec, []byte("PhasmidSaveParam\x00"))
	if k < 12 {
		t.Fatal("element header not found in the synthetic record")
	}
	bodyLenAt := k - 12 // u32 bodyLen, u32 array index, u32 FString length
	n := binary.LittleEndian.Uint32(rec[bodyLenAt:])
	binary.LittleEndian.PutUint32(rec[bodyLenAt:], n+1)
	got, stats := ScanSkillPoints(bytes.Join([][]byte{[]byte("GVAS"), rec}, nil))
	if len(got) != 0 || stats.Markers != 1 || stats.Skipped != 1 {
		t.Fatalf("got %v stats %+v, want the record skipped", got, stats)
	}
}
