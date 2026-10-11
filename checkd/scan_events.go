// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-11

package main

import (
	"sort"
)

// Spyro 1 level-completion records (docs/s1_level_completion.md). Every one
// is written collected=true only, so presence means done.
const (
	portalExitMarker   = "EInventoryType::EIT_PortalExit"
	s1BossMarker       = "EInventoryType::EIT_S1Boss"
	flightRewardMarker = "EInventoryType::EIT_S1FlightReward"

	// flightAllInOne is EFLT_AllInOne, the extra EFlightLevelTargetType a
	// cleared flight also records; it is not one of the four target sets.
	flightAllInOne = 20
	// flightSetsNeeded is the number of distinct target sets (values other
	// than flightAllInOne) that complete a flight, across any number of runs.
	flightSetsNeeded = 4
)

// spyro1FlightRegions complete through their EIT_S1FlightReward target sets
// only: their FlightLevelTransporter also writes an EIT_PortalExit, which
// must not fire the flight's event.
var spyro1FlightRegions = map[string]bool{
	"Sunny Flight":   true,
	"Night Flight":   true,
	"Crystal Flight": true,
	"Wild Flight":    true,
	"Icy Flight":     true,
}

// spyro1GnastyRegion is the only region whose EIT_S1Boss record fires its
// event; spyro1LootRegion's event ("Gnasty's Loot Complete") has no save
// record and fires from the gem flow when the Loot's "All Gems" threshold is
// crossed, so the Loot's own EIT_PortalExit fires nothing.
const (
	spyro1GnastyRegion = "Gnasty Gnorc"
	spyro1LootRegion   = "Gnasty's Loot"
)

// scanCollectedRegions returns the regions (from the containing level key,
// never from a param) holding a collected record behind marker. Records with
// no collected BoolProperty or no resolvable region count as skipped.
func scanCollectedRegions(data []byte, keys []levelKey, marker string, stats *ScanStats) map[string]bool {
	var set recordSet
	scanRecords(data, findMarkers(data, marker), stats, &set, func(m, end int) (Dragon, bool) {
		d, ok := abilityOne(data, m, end)
		if !ok {
			return d, false
		}
		d.Region = regionFor(keys, m, levelPathToRegion)
		return d, d.Region != ""
	})
	out := map[string]bool{}
	for _, d := range set.out {
		if d.Collected {
			out[d.Region] = true
		}
	}
	return out
}

// scanFlightSets returns region -> the EFlightLevelTargetType values of its
// collected EIT_S1FlightReward records (one nameless float param each, the
// skill-point param-array shape with collected=true). Records that do not
// parse or resolve count as skipped.
func scanFlightSets(data []byte, keys []levelKey, stats *ScanStats) map[string]map[int]bool {
	markers := findMarkers(data, flightRewardMarker)
	stats.Markers += len(markers)
	out := map[string]map[int]bool{}
	for _, m := range markers {
		vals, ok := scanParamRecord(data, m, flightRewardMarker, 1)
		region := regionFor(keys, m, levelPathToRegion)
		if !ok || region == "" {
			stats.Skipped++
			continue
		}
		if out[region] == nil {
			out[region] = map[int]bool{}
		}
		for _, v := range vals {
			out[region][int(v)] = true
		}
	}
	return out
}

// s1EventRegions applies the completion rules to the scanned evidence and
// returns the regions whose event fires, sorted:
//   - a collected EIT_PortalExit fires its region, except in the flights and
//     Gnasty's Loot;
//   - a collected EIT_S1Boss fires Gnasty Gnorc (only there);
//   - a flight fires once its rewards cover flightSetsNeeded distinct target
//     sets other than flightAllInOne.
func s1EventRegions(exits, bosses map[string]bool, flights map[string]map[int]bool) []string {
	fired := map[string]bool{}
	for r := range exits {
		if !spyro1FlightRegions[r] && r != spyro1LootRegion {
			fired[r] = true
		}
	}
	if bosses[spyro1GnastyRegion] {
		fired[spyro1GnastyRegion] = true
	}
	for r, sets := range flights {
		if !spyro1FlightRegions[r] {
			continue
		}
		n := 0
		for v := range sets {
			if v != flightAllInOne {
				n++
			}
		}
		if n >= flightSetsNeeded {
			fired[r] = true
		}
	}
	out := make([]string, 0, len(fired))
	for r := range fired {
		out = append(out, r)
	}
	sort.Strings(out)
	return out
}

// ScanS1Events extracts the Spyro 1 regions whose "<Level> Complete" /
// "<Boss> Defeated" event the save proves (s1EventRegions' rules) from a
// GVAS FalconSave blob or one save entry. Gnasty's Loot never appears: its
// event comes from the gem flow. Stats sum the three record markers.
func ScanS1Events(data []byte) ([]string, ScanStats) {
	var stats ScanStats
	if len(data) < 4 || string(data[:4]) != "GVAS" {
		return nil, stats
	}
	keys := findLevelKeys(data)
	exits := scanCollectedRegions(data, keys, portalExitMarker, &stats)
	bosses := scanCollectedRegions(data, keys, s1BossMarker, &stats)
	flights := scanFlightSets(data, keys, &stats)
	return s1EventRegions(exits, bosses, flights), stats
}
