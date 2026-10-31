// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-23

package main

import (
	"sort"
)

// recordWindow caps how far past its marker a record body is searched: ~800
// bytes is generous for both ASCII and UTF-16 record bodies.
const recordWindow = 800

// recordEnd returns the end of the search window for the record following
// offs[i]: recordWindow past the marker, the next marker when closer, and
// never past the data.
func recordEnd(data []byte, offs []int, i int) int {
	end := offs[i] + recordWindow
	if i+1 < len(offs) && offs[i+1] < end {
		end = offs[i+1]
	}
	if end > len(data) {
		end = len(data)
	}
	return end
}

// collectedOff locates the value byte of the collected BoolProperty in the
// record following a marker at m (searched in data[m:end]): the "collected"
// tag, then the "BoolProperty" tag + NUL, u64 size, then the value byte.
// Returns -1 when the record has none.
func collectedOff(data []byte, m, end int) int {
	c, _ := findTag(data, "collected", m, end)
	if c < 0 {
		return -1
	}
	b, bLen := findTag(data, "BoolProperty", c, end)
	if b < 0 {
		return -1
	}
	// tag + NUL, u64 size, then the value byte. Bounded by the record window,
	// not the buffer: past `end` is the next record, and reading its first byte
	// as this record's flag silently misclassifies a collected item.
	valOff := b + bLen + 8
	if valOff >= end {
		return -1
	}
	return valOff
}

// recordSet collects named records deduped by (region, name): duplicates
// (multi-slot saves) merge and a collected record wins.
type recordSet struct {
	seen map[[2]string]int
	out  []Dragon
}

func (s *recordSet) add(d Dragon) {
	k := [2]string{d.Region, d.Name}
	if idx, dup := s.seen[k]; dup {
		if d.Collected {
			s.out[idx].Collected = true
		}
		return
	}
	if s.seen == nil {
		s.seen = make(map[[2]string]int)
	}
	s.seen[k] = len(s.out)
	s.out = append(s.out, d)
}

// scanRecords parses the record following each marker in offs (ascending)
// within its recordEnd window, counting the markers and the records parse
// rejects in stats and collecting the rest into set.
func scanRecords(data []byte, offs []int, stats *ScanStats, set *recordSet, parse func(m, end int) (Dragon, bool)) {
	stats.Markers += len(offs)
	for i, m := range offs {
		d, ok := parse(m, recordEnd(data, offs, i))
		if !ok {
			stats.Skipped++
			continue
		}
		set.add(d)
	}
}

// scanOne parses the record following a dragon (or orb) marker at m. end caps
// the search window (see recordEnd). regions maps the owning level path to
// its region; records with no resolvable region (filed under "Global", or a
// level not in the table) fail.
func scanOne(data []byte, m, end int, keys []levelKey, regions map[string]string) (Dragon, bool) {
	var d Dragon
	valOff := collectedOff(data, m, end)
	if valOff < 0 {
		return d, false
	}
	d.Collected = data[valOff] != 0
	p, _ := findTag(data, "paramName", valOff, end)
	if p < 0 {
		return d, false
	}
	s, sLen := findTag(data, "StrProperty", p, end)
	if s < 0 {
		return d, false
	}
	// StrProperty header: content + NUL, u32 size, u32 arrayIndex, 1
	// terminator byte, then the FString body.
	name, ok := readFString(data, s+sLen+9)
	if !ok || name == "" {
		return d, false
	}
	d.Name = name
	d.Region = regionFor(keys, m, regions)
	if d.Region == "" {
		return d, false
	}
	return d, true
}

// eggOne parses the record following an egg marker at m. Eggs carry no name;
// identity is the per-level ordinal assigned later. Records with no
// resolvable region (a level not in the table) fail.
func eggOne(data []byte, m, end int, keys []levelKey) (Egg, bool) {
	var e Egg
	valOff := collectedOff(data, m, end)
	if valOff < 0 {
		return e, false
	}
	e.Collected = data[valOff] != 0
	e.Region = regionFor(keys, m, levelPathToRegion)
	if e.Region == "" {
		return e, false
	}
	return e, true
}

// ScanEggs extracts egg records from a GVAS FalconSave blob. Only caught
// (collected=true) eggs have save records; the ordinal is the egg's index
// among that region's collected records in scan (file) order, 1-based.
// Uncollected records (not seen in practice; pygvas drops them) scan with
// ordinal 0 and are never counted.
func ScanEggs(data []byte) ([]Egg, ScanStats) {
	var stats ScanStats
	if len(data) < 4 || string(data[:4]) != "GVAS" {
		return nil, stats
	}
	keys := findLevelKeys(data)
	markers := findMarkers(data, eggMarker)
	stats.Markers = len(markers)
	counts := make(map[string]int)
	var out []Egg
	for i, m := range markers {
		e, ok := eggOne(data, m, recordEnd(data, markers, i), keys)
		if !ok {
			stats.Skipped++
			continue
		}
		if e.Collected {
			e.Ordinal = counts[e.Region] + 1
			counts[e.Region] = e.Ordinal
		}
		out = append(out, e)
	}
	return out, stats
}

// ScanSave extracts named dragon records from a GVAS FalconSave blob.
func ScanSave(data []byte) ([]Dragon, ScanStats) {
	return scanNamed(data, levelPathToRegion, dragonMarker)
}

// ScanOrbs extracts Spyro 2 orb records: the same record shape as a dragon,
// with Name holding the orb's save key (the first paramName).
func ScanOrbs(data []byte) ([]Dragon, ScanStats) {
	return scanNamed(data, spyro2PathToRegion, orbMarker)
}

// ScanTalismans extracts Spyro 2 talisman records (Name = the talisman's save
// key, e.g. "Magic Pick"): the same record shape as an orb.
func ScanTalismans(data []byte) ([]Dragon, ScanStats) {
	return scanNamed(data, spyro2PathToRegion, talismanMarker)
}

// ScanS3Eggs extracts the Spyro 3 egg records (Name = the dragon name the
// record's single paramName carries, e.g. "Sanders"; the one EIT_S3BonusEgg
// record is named "Al" by the same param and needs no special-casing beyond
// its marker). Records with no resolvable region (the non-level
// "MoneybagGems" pseudo-key owns none) fail like any unresolvable record.
func ScanS3Eggs(data []byte) ([]Dragon, ScanStats) {
	return scanNamed(data, spyro3PathToRegion, s3EggMarker, s3BonusEggMarker)
}

// scanNamed extracts the named records following each marker (the dual-form
// finder handles ASCII and UTF-16): the same record shape for dragons, orbs,
// talismans and Spyro 3 eggs — collected BoolProperty, then paramName. Dedup
// by (region, name): multi-slot saves repeat records and a collected one wins.
func scanNamed(data []byte, regions map[string]string, markers ...string) ([]Dragon, ScanStats) {
	var stats ScanStats
	if len(data) < 4 || string(data[:4]) != "GVAS" {
		return nil, stats
	}
	var offs []int
	for _, marker := range markers {
		offs = append(offs, findMarkers(data, marker)...)
	}
	sort.Ints(offs)
	keys := findLevelKeys(data)
	var set recordSet
	scanRecords(data, offs, &stats, &set, func(m, end int) (Dragon, bool) {
		return scanOne(data, m, end, keys, regions)
	})
	return set.out, stats
}

// abilityOne parses the record following an ability marker at m: the same
// collected BoolProperty as an egg, with no paramName (the type IS the
// identity) and no region (the record lives in the global inventory, not a
// level's saveDataList — the backward-walk finding no /LS path is expected).
func abilityOne(data []byte, m, end int) (Dragon, bool) {
	var d Dragon
	valOff := collectedOff(data, m, end)
	if valOff < 0 {
		return d, false
	}
	d.Collected = data[valOff] != 0
	return d, true
}

// regionOfRecord reads a level-scoped record and resolves its region from the
// backward level-key walk. ok is false when the record has no collected
// BoolProperty or no region (another game's save entry).
func regionOfRecord(data []byte, keys []levelKey, m, end int,
	regions map[string]string) (Dragon, bool) {
	d, ok := abilityOne(data, m, end)
	if !ok {
		return d, false
	}
	d.Region = regionFor(keys, m, regions)
	if d.Region == "" {
		return d, false
	}
	return d, true
}

// ScanAbilities extracts the Spyro 2 Money Bags ability records from a GVAS
// FalconSave blob (global inventory, one per ability type; EIT_Superflame is
// not a Money Bags purchase and never scans). Dedup across save entries is
// collected-wins.
func ScanAbilities(data []byte) ([]Dragon, ScanStats) {
	var stats ScanStats
	if len(data) < 4 || string(data[:4]) != "GVAS" {
		return nil, stats
	}
	var set recordSet
	for _, at := range abilityTypes {
		markers := findMarkers(data, "EInventoryType::"+at.tag)
		scanRecords(data, markers, &stats, &set, func(m, end int) (Dragon, bool) {
			d, ok := abilityOne(data, m, end)
			d.Name = at.name
			return d, ok
		})
	}
	return set.out, stats
}

// bossNameByRegion is the fixed check name of each Spyro 2 boss kill: the
// record (one EIT_S2Boss item per boss level, on the BossCompletionPercent
// object) carries no name param, so the region IS the identity.
var bossNameByRegion = map[string]string{
	"Crush's Dungeon": "Crush Defeated",
	"Gulp's Overlook": "Gulp Defeated",
	"Ripto's Arena":   "Ripto Defeated",
}

const s2BossMarker = "EInventoryType::EIT_S2Boss"

// ScanS2Bosses extracts the Spyro 2 boss-kill records from a GVAS
// FalconSave blob. Unlike the abilities, the records are level-scoped (they
// live in the boss level's saveDataList), so the region comes from the
// backward level-key walk and the name from bossNameByRegion; records in any
// other region are skipped. Dedup across save entries is collected-wins.
func ScanS2Bosses(data []byte) ([]Dragon, ScanStats) {
	var stats ScanStats
	if len(data) < 4 || string(data[:4]) != "GVAS" {
		return nil, stats
	}
	keys := findLevelKeys(data)
	var set recordSet
	scanRecords(data, findMarkers(data, s2BossMarker), &stats, &set, func(m, end int) (Dragon, bool) {
		d, ok := regionOfRecord(data, keys, m, end, spyro2PathToRegion)
		d.Name = bossNameByRegion[d.Region]
		return d, ok && d.Name != ""
	})
	return set.out, stats
}
