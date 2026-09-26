package main

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"
)

const eventsSave = "s1_events"

// the s1_events fixture's expected drops (gen_fixtures.py s1_events): slot 0
// proves six events by record plus the full Loot, slot 1 one event and half
// the Loot's gems.
var (
	eventsSlot0Drop = map[string]int{
		"Spyro 1: Stone Hill Complete":     103003,
		"Spyro 1: Toasty Defeated":         103005,
		"Spyro 1: Dark Passage Complete":   103026,
		"Spyro 1: Gnasty Gnorc Defeated":   103034,
		"Spyro 1: Sunny Flight Complete":   103006,
		"Spyro 1: Wild Flight Complete":    103024,
		"Spyro 1: Gnasty's Loot: 25% Gems": 102350,
		"Spyro 1: Gnasty's Loot: 50% Gems": 102351,
		"Spyro 1: Gnasty's Loot: 75% Gems": 102352,
		"Spyro 1: Gnasty's Loot: All Gems": 102353,
		"Spyro 1: Gnasty's Loot Complete":  103035,
	}
	eventsSlot1Drop = map[string]int{
		"Spyro 1: Dark Hollow Complete":    103004,
		"Spyro 1: Gnasty's Loot: 25% Gems": 102350,
		"Spyro 1: Gnasty's Loot: 50% Gems": 102351,
	}
)

func copyDrop(m map[string]int) map[string]int {
	out := make(map[string]int, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

func gameEntry(t *testing.T, stem string, slot int) []byte {
	t.Helper()
	entry, ok := saveEntry(loadSave(t, stem), entryIndex(slot, 0))
	if !ok {
		t.Fatalf("%s: no save entry for slot %d", stem, slot)
	}
	return entry
}

// TestSpyro1EventTable: every Spyro 1 region with events carries exactly one
// (the resolver keys events by region), all 29 are addressable and in
// nameToID at 103000+levelId, and the rule constants name real event regions.
func TestSpyro1EventTable(t *testing.T) {
	nameToID, _, _, err := embeddedLocations()
	if err != nil {
		t.Fatal(err)
	}
	with := 0
	for region, r := range embeddedDoc.Games["spyro1"].Regions {
		if len(r.Events) == 0 {
			continue
		}
		with++
		if len(r.Events) != 1 {
			t.Fatalf("region %q has %d events, the event resolver needs exactly one", region, len(r.Events))
		}
		e := r.Events[0]
		if spyro1Events[region] != e.Location {
			t.Fatalf("spyro1Events[%q] = %q, want %q", region, spyro1Events[region], e.Location)
		}
		if nameToID[e.Location] != e.ID || e.ID < 103000 || e.ID >= 104000 {
			t.Fatalf("event %q id %d, nameToID %d", e.Location, e.ID, nameToID[e.Location])
		}
	}
	if with != 29 || len(spyro1Events) != 29 {
		t.Fatalf("%d regions with events, %d addressable; want 29", with, len(spyro1Events))
	}
	regions := []string{spyro1GnastyRegion, spyro1LootRegion}
	for r := range spyro1FlightRegions {
		regions = append(regions, r)
	}
	for _, r := range regions {
		if _, ok := spyro1Events[r]; !ok {
			t.Fatalf("rule region %q has no event", r)
		}
	}
	if spyro1Events[spyro1LootRegion] != "Spyro 1: Gnasty's Loot Complete" {
		t.Fatalf("Loot event = %q", spyro1Events[spyro1LootRegion])
	}
	if gemLabel(100) == "" {
		t.Fatal("no 100% gem threshold label for the Loot rule")
	}
}

func regionSet(rs ...string) map[string]bool {
	out := map[string]bool{}
	for _, r := range rs {
		out[r] = true
	}
	return out
}

func flightSet(vals ...int) map[int]bool {
	out := map[int]bool{}
	for _, v := range vals {
		out[v] = true
	}
	return out
}

// TestS1EventRules pins each completion rule on synthetic evidence.
func TestS1EventRules(t *testing.T) {
	cases := []struct {
		name    string
		exits   map[string]bool
		bosses  map[string]bool
		flights map[string]map[int]bool
		want    []string
	}{
		{"normal level exit", regionSet("Stone Hill"), nil, nil, []string{"Stone Hill"}},
		{"boss level exit", regionSet("Toasty", "Jacques"), nil, nil, []string{"Jacques", "Toasty"}},
		{"flight exit alone", regionSet("Sunny Flight"), nil, nil, []string{}},
		{"loot exit", regionSet(spyro1LootRegion), nil, nil, []string{}},
		{"gnasty boss", nil, regionSet(spyro1GnastyRegion), nil, []string{spyro1GnastyRegion}},
		{"gnasty boss and exit dedup", regionSet(spyro1GnastyRegion), regionSet(spyro1GnastyRegion), nil, []string{spyro1GnastyRegion}},
		{"S1Boss outside Gnasty", nil, regionSet("Toasty", spyro1LootRegion), nil, []string{}},
		{"flight 4 sets + 20", nil, nil, map[string]map[int]bool{"Sunny Flight": flightSet(3, 1, 5, 4, 20)}, []string{"Sunny Flight"}},
		{"flight 4 sets, no 20", nil, nil, map[string]map[int]bool{"Wild Flight": flightSet(5, 4, 3, 7)}, []string{"Wild Flight"}},
		{"flight 3 sets + 20", nil, nil, map[string]map[int]bool{"Icy Flight": flightSet(1, 27, 5, 20)}, []string{}},
		{"flight 2 sets", nil, nil, map[string]map[int]bool{"Night Flight": flightSet(5, 4)}, []string{}},
		{"flight 20 only", nil, nil, map[string]map[int]bool{"Crystal Flight": flightSet(20)}, []string{}},
		{"sets outside a flight", nil, nil, map[string]map[int]bool{"Stone Hill": flightSet(1, 2, 3, 4)}, []string{}},
	}
	for _, c := range cases {
		got := s1EventRegions(c.exits, c.bosses, c.flights)
		if !reflect.DeepEqual(got, c.want) {
			t.Fatalf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

// TestScanS1EventsMatchesGolden: every fixture's game-0 entries scan to the
// pygvas-side events golden (gen_golden.py scan_events), with no skipped
// record.
func TestScanS1EventsMatchesGolden(t *testing.T) {
	for _, stem := range allFixtureStems {
		want := map[int][]string{}
		for _, row := range goldenRows(t, stem, ".events.golden.json", "events", 2) {
			var regs []string
			for _, r := range row[1].([]any) {
				regs = append(regs, r.(string))
			}
			want[int(row[0].(float64))] = regs
		}
		for slot := 0; slot < 3; slot++ {
			got, stats := ScanS1Events(gameEntry(t, stem, slot))
			if stats.Skipped != 0 {
				t.Fatalf("%s slot %d: %d records skipped (%+v)", stem, slot, stats.Skipped, stats)
			}
			if len(got) == 0 && len(want[slot]) == 0 {
				continue
			}
			if !reflect.DeepEqual(got, want[slot]) {
				t.Fatalf("%s slot %d: events %v, golden %v", stem, slot, got, want[slot])
			}
		}
	}
	got, stats := ScanS1Events(gameEntry(t, eventsSave, 0))
	// 7 exits (Stone Hill, Toasty, Dark Passage, Gnasty, Sunny, Night, Loot),
	// 1 S1Boss, 5+4+3+4+1 flight rewards
	if stats.Markers != 7+1+17 || len(got) != 6 {
		t.Fatalf("s1_events slot 0: %v, stats %+v", got, stats)
	}
}

// TestScanFlightSets: the flight rewards decode through the generalised
// param-record walk, per region, repeated sets merging; the walk refuses a
// record whose collected value is not the expected one.
func TestScanFlightSets(t *testing.T) {
	entry := gameEntry(t, eventsSave, 0)
	var stats ScanStats
	got := scanFlightSets(entry, findLevelKeys(entry), &stats)
	want := map[string]map[int]bool{
		"Sunny Flight":   flightSet(1, 3, 4, 5, 20),
		"Wild Flight":    flightSet(3, 4, 5, 7),
		"Night Flight":   flightSet(4, 5, 20),
		"Crystal Flight": flightSet(2, 4, 20),
		"Icy Flight":     flightSet(20),
	}
	if !reflect.DeepEqual(got, want) || stats.Markers != 17 || stats.Skipped != 0 {
		t.Fatalf("flight sets %v (stats %+v), want %v", got, stats, want)
	}
	m := findMarkers(entry, flightRewardMarker)[0]
	if _, ok := scanParamRecord(entry, m, flightRewardMarker, 0); ok {
		t.Fatal("a collected=true flight reward must not parse as collected=false")
	}
	if vals, ok := scanParamRecord(entry, m, flightRewardMarker, 1); !ok || len(vals) != 1 {
		t.Fatalf("flight reward walk: vals=%v ok=%v", vals, ok)
	}
}

// TestScanPortalExitRegionFromKey: a PortalExit's region comes from the
// containing level key, never its param: the Loot's exit names LS131 (Gnorc
// Gnexus) but files under Gnasty's Loot, and the flight exits under their
// flights; neither fires.
func TestScanPortalExitRegionFromKey(t *testing.T) {
	entry := gameEntry(t, eventsSave, 0)
	var stats ScanStats
	exits := scanCollectedRegions(entry, findLevelKeys(entry), portalExitMarker, &stats)
	want := regionSet("Stone Hill", "Toasty", "Dark Passage", spyro1GnastyRegion, "Sunny Flight", "Night Flight", spyro1LootRegion)
	if !reflect.DeepEqual(exits, want) || stats.Skipped != 0 {
		t.Fatalf("exit regions %v (stats %+v), want %v", exits, stats, want)
	}
	events, _ := ScanS1Events(entry)
	for _, r := range events {
		if r == spyro1LootRegion || r == "Night Flight" || r == "Gnorc Gnexus" {
			t.Fatalf("%s must not fire from its exit: %v", r, events)
		}
	}
}

func eventsDaemon(t *testing.T, backfill bool, session string) *daemon {
	t.Helper()
	d := testDaemon(t, backfill)
	d.saveDir = t.TempDir()
	writeSession(t, d, session)
	return d
}

func writeSave(t *testing.T, d *daemon, name, stem string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(d.saveDir, name), loadSave(t, stem), 0644); err != nil {
		t.Fatal(err)
	}
}

// TestDaemonEventsBackfill drives pollOnce on s1_events slot 0 with backfill:
// the baseline drop carries the six record-proven events (103xxx) and
// "Gnasty's Loot Complete" together with the Loot's All Gems gem check, and
// nothing else; the Loot exit and the partial flights fire nothing.
func TestDaemonEventsBackfill(t *testing.T) {
	d := eventsDaemon(t, true, "slot=0\ngame=0\ntoken=ev0\n")
	writeSave(t, d, "FalconSave.99.sav", eventsSave)
	d.pollOnce()
	expectDrop(t, readDrop(t, d), copyDrop(eventsSlot0Drop))
	n := 0
	for k, v := range d.known {
		if k.kind == "event" && v {
			n++
		}
	}
	if n != 7 {
		t.Fatalf("known events = %d, want 7", n)
	}

	// an unchanged-content rewrite drops nothing more
	time.Sleep(20 * time.Millisecond)
	writeSave(t, d, "FalconSave.98.sav", eventsSave)
	d.pollOnce()
	if d.drops != 1 {
		t.Fatalf("rescan re-dropped: drops=%d", d.drops)
	}
}

// TestDaemonEventsFlip: a no-backfill baseline on snapshot3 (no completion
// records) drops nothing; the s1_events rewrite of the same slot then drops
// exactly the fresh events and Loot gem checks, Loot Complete included.
func TestDaemonEventsFlip(t *testing.T) {
	var logs []string
	d := eventsDaemon(t, false, "slot=0\ngame=0\ntoken=ev1\n")
	d.logf = func(f string, a ...any) { logs = append(logs, fmt.Sprintf(f, a...)) }
	writeSave(t, d, "FalconSave.99.sav", "snapshot3")
	d.pollOnce()
	if d.drops != 0 {
		t.Fatalf("no-backfill baseline dropped %d", d.drops)
	}
	time.Sleep(20 * time.Millisecond)
	writeSave(t, d, "FalconSave.98.sav", eventsSave)
	d.pollOnce()
	expectDrop(t, readDrop(t, d), copyDrop(eventsSlot0Drop))
	if !strings.Contains(strings.Join(logs, "\n"), ", 0 completions") {
		t.Fatalf("baseline log lacks the completion count: %v", logs)
	}
}

// TestDaemonLootExitNoComplete: slot 1 holds the Loot exit at half the Loot's
// gems and a 3-set Icy Flight with its exit: only Dark Hollow and the Loot's
// crossed gem thresholds drop, never "Gnasty's Loot Complete".
func TestDaemonLootExitNoComplete(t *testing.T) {
	d := eventsDaemon(t, true, "slot=1\ngame=0\ntoken=ev2\n")
	writeSave(t, d, "FalconSave.99.sav", eventsSave)
	d.pollOnce()
	expectDrop(t, readDrop(t, d), copyDrop(eventsSlot1Drop))
}

// TestDaemonEventsGameGate: completion scanning runs only in Spyro 1
// sessions: the fixture's Spyro 2 entry for slot 0 is empty, so a game-1
// session over the same file drops nothing.
func TestDaemonEventsGameGate(t *testing.T) {
	d := eventsDaemon(t, true, "slot=0\ngame=1\ntoken=ev3\n")
	writeSave(t, d, "FalconSave.99.sav", eventsSave)
	d.pollOnce()
	if d.drops != 0 {
		t.Fatalf("game-1 session dropped %d", d.drops)
	}
	if _, ok := resolverFor(1).resolve(d, checkKey{"event", "Stone Hill", ""}); ok {
		t.Fatal("the Spyro 2 resolver must not resolve a Spyro 1 event key")
	}
}

// TestSpyro1ResolverUnknownEvent: an event key for a region without an event
// logs in the resolver's "unknown ... (skipped)" shape and resolves nothing.
func TestSpyro1ResolverUnknownEvent(t *testing.T) {
	d := testDaemon(t, true)
	var logs []string
	d.logf = func(f string, a ...any) { logs = append(logs, fmt.Sprintf(f, a...)) }
	if _, ok := (spyro1Resolver{}).resolve(d, checkKey{"event", "Artisans", ""}); ok {
		t.Fatal("Artisans has no event")
	}
	if len(logs) != 1 || logs[0] != "unknown event location: Artisans (skipped)" {
		t.Fatalf("logs = %v", logs)
	}
	got, ok := (spyro1Resolver{}).resolve(d, checkKey{"event", "Toasty", ""})
	if !ok || got != "Spyro 1: Toasty Defeated" {
		t.Fatalf("Toasty event = %q, %v", got, ok)
	}
	keys := make([]string, 0, len(spyro1Events))
	for r := range spyro1Events {
		keys = append(keys, r)
	}
	sort.Strings(keys)
	for _, r := range keys {
		if _, ok := (spyro1Resolver{}).resolve(d, checkKey{"event", r, ""}); !ok {
			t.Fatalf("event region %q does not resolve", r)
		}
	}
}
