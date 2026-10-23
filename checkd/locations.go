// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-11

package main

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

//go:embed locations.json
var locationsJSON []byte

// Kind enumerates the check kinds checkd sends, as checkKey and the kinds
// gen_locations.py writes into locations.json spell them.
type Kind string

const (
	KindDragon     Kind = "dragon"
	KindEgg        Kind = "egg"
	KindGem        Kind = "gem"
	KindOrb        Kind = "orb"
	KindTalisman   Kind = "talisman"
	KindAbility    Kind = "ability"
	KindBoss       Kind = "boss"
	KindSkillPoint Kind = "skillpoint"
	KindSparx      Kind = "sparx"
	KindEvent      Kind = "event"
	// KindSparxPower is locations.json's sparxpower row kind; checkd keys
	// those rows as KindSparx (the globalFloatMap key, file-global).
	KindSparxPower Kind = "sparxpower"
)

// checkKey identifies one sendable check: kind "dragon" keyed by name, kind
// "egg" keyed by per-level ordinal (as string) since S1 eggs have no name, kind
// "gem" keyed by threshold label ("25% Gems" ... "All Gems"); Spyro 2 kinds
// "orb"/"talisman" keyed by save key, "ability" bare-named with an empty
// region (the inventory record is global), "boss" keyed by the region-fixed
// event name. Spyro 3 gems key like Spyro 2 gems; Spyro 3 "egg" keys carry
// the record's dragon name (named eggs), so they differ from S1 egg keys;
// Spyro 3 "sparx" keys carry the globalFloatMap key's enum-name suffix with an
// empty region (the map is file-global, not level-scoped). Spyro 1 "event" keys
// carry the completed region with an empty name (one event per region).
type checkKey struct {
	kind   Kind
	region string
	name   string
}

type locCheck struct {
	Type      Kind   `json:"type"` // KindDragon | KindEgg | KindGem | KindOrb | KindTalisman | KindAbility | KindBoss | KindSkillPoint | KindSparxPower
	Name      string `json:"name"`
	SaveKey   string `json:"saveKey,omitempty"` // boss rows: the boss dungeon's egg-record param
	Ability   string `json:"ability"`           // bare ability name (KindAbility only)
	Ordinal   int    `json:"ordinal"`
	Threshold int    `json:"threshold"`
	Enum      int    `json:"enum"` // ESkillPoint enum value (KindSkillPoint only)
	Location  string `json:"location"`
	ID        int    `json:"id"`
}

type locRegion struct {
	LevelPath string     `json:"levelPath"`
	GemTotal  int        `json:"gemTotal"`
	Checks    []locCheck `json:"checks"`
	Events    []locCheck `json:"events"` // completion events: location + id only
}

type gameDoc struct {
	BaseID          int                  `json:"baseId"`
	LocationPrefix  string               `json:"locationPrefix"`  // "Spyro 1: ", "Spyro 2: ", "Spyro 3: "
	SkillPointRange []int                `json:"skillPointRange"` // [lo, hi] ESkillPoint enum range
	Regions         map[string]locRegion `json:"regions"`
}

type locationsDoc struct {
	Game          string             `json:"game"`
	GemThresholds [][]any            `json:"gemThresholds"` // [[pct, label], ...], shared by all games
	GemValues     []gemValueRow      `json:"gemValues"`     // [{tag, value}, ...], per gem type
	Games         map[string]gameDoc `json:"games"`         // "spyro1", "spyro2", "spyro3"
}

// gemValueRow is one per-gem-type value from locations.json's "gemValues"
// (generated from world/data/client.json).
type gemValueRow struct {
	Tag   string `json:"tag"`
	Value int    `json:"value"`
}

// embeddedDoc is the embedded locations.json, parsed once by init().
var embeddedDoc locationsDoc

// derive builds the flat lookups checkd uses: location name -> id (checks and
// events), region ->
// egg location names (in ordinal order), region -> gem value total, and level
// map path -> region.
func (doc *gameDoc) derive() (nameToID map[string]int, eggCatalog map[string][]string,
	levelGems map[string]int, pathToRegion map[string]string) {
	nameToID = map[string]int{}
	eggCatalog = map[string][]string{}
	levelGems = map[string]int{}
	pathToRegion = map[string]string{}
	for region, r := range doc.Regions {
		levelGems[region] = r.GemTotal
		if r.LevelPath != "" {
			pathToRegion[r.LevelPath] = region
		}
		for _, e := range r.Events {
			nameToID[e.Location] = e.ID
		}
		var eggs []locCheck
		for _, c := range r.Checks {
			nameToID[c.Location] = c.ID
			if c.Type == KindEgg {
				eggs = append(eggs, c)
			}
		}
		if len(eggs) > 0 {
			sort.Slice(eggs, func(i, j int) bool { return eggs[i].Ordinal < eggs[j].Ordinal })
			names := make([]string, len(eggs))
			for i, e := range eggs {
				names[i] = e.Location
			}
			eggCatalog[region] = names
		}
	}
	return
}

// gemThreshold is one gem value checkpoint: the percentage of a region's gem
// total and the location label it resolves to.
type gemThreshold struct {
	pct   int
	label string
}

// gemThresholds are the gem value checkpoints per region, from the embedded
// locations.json's top-level "gemThresholds" (the apworld's gem checks;
// "All Gems" is the 100% one). init() populates it.
var gemThresholds []gemThreshold

// parseGemThresholds converts the doc's [[pct, label], ...] rows.
func parseGemThresholds(rows [][]any) ([]gemThreshold, error) {
	out := make([]gemThreshold, 0, len(rows))
	for _, row := range rows {
		if len(row) != 2 {
			return nil, fmt.Errorf("gemThresholds row %v is not [pct, label]", row)
		}
		pct, okPct := row[0].(float64)
		label, okLabel := row[1].(string)
		if !okPct || !okLabel || label == "" {
			return nil, fmt.Errorf("gemThresholds row %v is not [pct, label]", row)
		}
		out = append(out, gemThreshold{int(pct), label})
	}
	return out, nil
}

// parseGemValues converts the doc's [{tag, value}, ...] rows into the scan's
// gem table, rejecting an empty tag, a non-positive value or a repeat.
func parseGemValues(rows []gemValueRow) ([]gemType, error) {
	out := make([]gemType, 0, len(rows))
	seen := map[string]bool{}
	for _, r := range rows {
		if r.Tag == "" || r.Value <= 0 {
			return nil, fmt.Errorf("gemValues row %+v needs a tag and a positive value", r)
		}
		if seen[r.Tag] {
			return nil, fmt.Errorf("gemValues repeats tag %q", r.Tag)
		}
		seen[r.Tag] = true
		out = append(out, gemType{tag: r.Tag, value: r.Value})
	}
	return out, nil
}

// embeddedLocations derives the daemon's lookups from the embedded doc that
// init() parsed once.
func embeddedLocations() (map[string]int, map[string][]string, map[string]int, error) {
	return deriveLocations(&embeddedDoc)
}

// deriveLocations builds the cross-game lookups from a parsed doc: location
// name -> id (all games), S1 region -> egg location names, and region -> gem
// value total (all games; region names must be game-unique).
func deriveLocations(doc *locationsDoc) (map[string]int, map[string][]string, map[string]int, error) {
	s1, s2, s3 := doc.Games["spyro1"], doc.Games["spyro2"], doc.Games["spyro3"]
	if len(s1.Regions) == 0 || len(s2.Regions) == 0 || len(s3.Regions) == 0 {
		return nil, nil, nil, fmt.Errorf("locations.json has no spyro1/spyro2/spyro3 regions")
	}
	nameToID, eggCatalog, levelGems, s1Paths := s1.derive()
	s2IDs, _, s2Gems, s2Paths := s2.derive()
	s3IDs, _, s3Gems, s3Paths := s3.derive()
	if err := requireSections([3]map[string]string{s1Paths, s2Paths, s3Paths},
		[3]map[string]int{nameToID, s2IDs, s3IDs}); err != nil {
		return nil, nil, nil, err
	}
	mergeIDs(nameToID, s2IDs)
	mergeIDs(nameToID, s3IDs)
	for _, gems := range []map[string]int{s2Gems, s3Gems} {
		if err := mergeGems(levelGems, gems); err != nil {
			return nil, nil, nil, err
		}
	}
	return nameToID, eggCatalog, levelGems, nil
}

// requireSections guards that every game section carries checks and level
// paths.
func requireSections(paths [3]map[string]string, ids [3]map[string]int) error {
	for _, m := range ids {
		if len(m) == 0 {
			return fmt.Errorf("locations.json regions have no checks")
		}
	}
	for _, m := range paths {
		if len(m) == 0 {
			return fmt.Errorf("locations.json regions have no level paths")
		}
	}
	return nil
}

// mergeIDs adds one game's location ids to the cross-game table.
func mergeIDs(to, from map[string]int) {
	for name, id := range from {
		to[name] = id
	}
}

// mergeGems adds one game's gem totals, refusing a region two games share
// because gemEvents looks a region up without its game.
func mergeGems(to, from map[string]int) error {
	for region, total := range from {
		if _, dup := to[region]; dup {
			return fmt.Errorf("locations.json region %q is in more than one game", region)
		}
		to[region] = total
	}
	return nil
}

// Internal level path -> region name. Loaded from the embedded locations.json
// (generated by scripts/gen_locations.py from world/data/client.json, the
// single source of truth). init() populates it so both the daemon and the
// tests use the exact same table as the mod's generated regions.lua.
var levelPathToRegion map[string]string

// locationPrefix leads every location name checkd builds ("Spyro 1: "), taken
// from the same embedded locations.json.
var locationPrefix string

// spyro2PathToRegion and spyro2Locations are the Spyro 2 counterparts, from the
// "spyro2" section: level path -> region, and check key -> location name. Orb
// and talisman keys carry the save key; gem keys carry the threshold's label;
// boss keys carry the region-fixed event name. Ability keys are bare-named
// with an empty region (the inventory record is global, not level-scoped).
var spyro2PathToRegion map[string]string
var spyro2Locations map[checkKey]string

// spyro3PathToRegion and spyro3Locations are the Spyro 3 counterparts, from
// the "spyro3" section. Gem keys carry the threshold's label, like Spyro 2's;
// egg keys carry the dragon name the save params hold (EIT_S3Egg and
// EIT_S3BonusEgg records alike).
var spyro3PathToRegion map[string]string
var spyro3Locations map[checkKey]string

// spyro3SparxPowers maps a Sparx-power enum-name suffix ("GemCollectRange",
// the EIT_SparxPower_<Name> tag of the globalFloatMap key) to its location
// name, from the "sparxpower" checks of the spyro3 section.
var spyro3SparxPowers map[string]string

// sparxPowerTag is the enum tag prefix of a sparxpower row's name; the global-
// FloatMap key suffix the scan emits is the row name minus this prefix.
const sparxPowerTag = "EIT_SparxPower_"

// spyro1SkillPoints, spyro2SkillPoints and spyro3SkillPoints map the
// ESkillPoint enum value of an earned skill point to its location name, from
// the "skillpoint" checks of each game's section.
var spyro1SkillPoints map[int]string
var spyro2SkillPoints map[int]string
var spyro3SkillPoints map[int]string

// spyro1Events maps a Spyro 1 region to its completion event's location name
// ("Spyro 1: Stone Hill Complete", "Spyro 1: Toasty Defeated"), from the
// regions' "events" in the embedded locations.json. Only regions with exactly
// one event are addressable (TestSpyro1EventTable pins that every region with
// events has exactly one).
var spyro1Events map[string]string

// eventTable builds the region -> event location map for one game's section,
// skipping regions without exactly one event.
func eventTable(doc *gameDoc) map[string]string {
	out := map[string]string{}
	for region, r := range doc.Regions {
		if len(r.Events) == 1 {
			out[region] = r.Events[0].Location
		}
	}
	return out
}

// skillPointTable builds the enum -> location map for one game's skill-point
// checks from its locations.json section.
func skillPointTable(doc *gameDoc) map[int]string {
	out := map[int]string{}
	for _, r := range doc.Regions {
		for _, c := range r.Checks {
			if c.Type == KindSkillPoint {
				out[c.Enum] = c.Location
			}
		}
	}
	return out
}

// gemLabel is the gemThresholds label for a percentage ("" if none).
func gemLabel(pct int) string {
	for _, th := range gemThresholds {
		if th.pct == pct {
			return th.label
		}
	}
	return ""
}

func init() {
	if err := json.Unmarshal(locationsJSON, &embeddedDoc); err != nil {
		panic("checkd: embedded locations.json is not valid JSON: " + err.Error())
	}
	doc := &embeddedDoc
	s1, s2, s3 := doc.Games["spyro1"], doc.Games["spyro2"], doc.Games["spyro3"]
	requirePrefixes(s1, s2, s3)
	loadThresholds(doc)
	loadGemTypes(doc)
	loadSkillPointRanges(s1, s2, s3)
	loadTables(s1, s2, s3)
}

// requirePrefixes panics when a game section carries no location prefix.
func requirePrefixes(games ...gameDoc) {
	for _, g := range games {
		if g.LocationPrefix == "" {
			panic("checkd: embedded locations.json has no per-game locationPrefix; regenerate with scripts/gen_locations.py")
		}
	}
}

// loadThresholds sets the gem value checkpoints from the doc.
func loadThresholds(doc *locationsDoc) {
	ths, err := parseGemThresholds(doc.GemThresholds)
	if err != nil || len(ths) == 0 {
		panic(fmt.Sprintf("checkd: embedded locations.json has no valid gemThresholds (%v); regenerate with scripts/gen_locations.py", err))
	}
	gemThresholds = ths
}

// loadGemTypes sets the per-gem-type values from the doc.
func loadGemTypes(doc *locationsDoc) {
	gems, err := parseGemValues(doc.GemValues)
	if err != nil || len(gems) == 0 {
		panic(fmt.Sprintf("checkd: embedded locations.json has no valid gemValues (%v); regenerate with scripts/gen_locations.py", err))
	}
	gemTypes = gems
}

// loadSkillPointRanges sets each game's ESkillPoint enum range.
func loadSkillPointRanges(games ...gameDoc) {
	for game, g := range games {
		r := g.SkillPointRange
		if len(r) != 2 || r[0] < 1 || r[0] > r[1] {
			panic(fmt.Sprintf("checkd: embedded locations.json game %d has no valid skillPointRange %v; regenerate with scripts/gen_locations.py", game, r))
		}
		skillPointRanges[game] = [2]int{r[0], r[1]}
	}
}

// loadTables fills the per-game lookup tables the scans resolve through.
func loadTables(s1, s2, s3 gameDoc) {
	spyro1SkillPoints = skillPointTable(&s1)
	spyro2SkillPoints = skillPointTable(&s2)
	spyro3SkillPoints = skillPointTable(&s3)
	spyro1Events = eventTable(&s1)
	_, _, _, levelPathToRegion = s1.derive()
	locationPrefix = s1.LocationPrefix
	_, _, _, spyro2PathToRegion = s2.derive()
	spyro2Locations = spyro2CheckTable(&s2)
	_, _, _, spyro3PathToRegion = s3.derive()
	spyro3Locations, spyro3SparxPowers = spyro3CheckTable(&s3)
}

// checkName is the name a check keys by: a gem check by its threshold's label,
// every other check by its own name.
func checkName(c locCheck) string {
	if c.Type == KindGem {
		return gemLabel(c.Threshold)
	}
	return c.Name
}

// spyro2CheckTable builds the check key -> location table of the Spyro 2
// section. Abilities are bare-named with an empty region (the inventory record
// is global, not level-scoped).
func spyro2CheckTable(doc *gameDoc) map[checkKey]string {
	out := map[checkKey]string{}
	for region, r := range doc.Regions {
		for _, c := range r.Checks {
			if c.Type == KindAbility {
				out[checkKey{KindAbility, "", c.Ability}] = c.Location
				continue
			}
			out[checkKey{c.Type, region, checkName(c)}] = c.Location
		}
	}
	return out
}

// spyro3CheckTable builds the check key -> location table of the Spyro 3
// section, plus the Sparx-power suffix -> location table.
func spyro3CheckTable(doc *gameDoc) (map[checkKey]string, map[string]string) {
	out := map[checkKey]string{}
	powers := map[string]string{}
	for region, r := range doc.Regions {
		for _, c := range r.Checks {
			// Spyro 3 boss kills save as the boss dungeon's named egg record
			// (no EIT_S3Boss exists in saves): ScanS3Eggs emits the record's
			// egg param as an "egg" check, so the boss row registers under
			// both keys — the event-name key (name-resolvable like S2's) and
			// the egg-param alias its scan flow resolves through.
			if c.Type == KindBoss {
				out[checkKey{KindBoss, region, c.Name}] = c.Location
				out[checkKey{KindEgg, region, c.SaveKey}] = c.Location
				continue
			}
			// Sparx-power rows register under their globalFloatMap key's
			// enum-name suffix ("GemCollectRange" — the row's name minus the
			// EIT_SparxPower_ prefix), the same alias shape the boss rows
			// register for their egg param: the scan flow's key, with no
			// region (the map key is file-global).
			if c.Type == KindSparxPower {
				power := strings.TrimPrefix(c.Name, sparxPowerTag)
				out[checkKey{KindSparx, "", power}] = c.Location
				powers[power] = c.Location
				continue
			}
			out[checkKey{c.Type, region, checkName(c)}] = c.Location
		}
	}
	return out, powers
}
