// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-11

package main

import (
	"encoding/binary"
)

type gemType struct {
	tag   string
	value int
}

// Gem tags and values, mirroring GEM_VALUES in scripts/gen_golden.py. Values
// are per gem type, not per game. All three games record the same two tag
// families: the plain S1 tags and the EIT_S2* tags (the S2 scheme: red 1,
// green 2, purple 5, yellow 10, magenta 25). The 100% Spyro 3 fixture holds
// no EIT_S3* tag at all — S3 levels record EIT_S2* gems (Sheila's Alp also
// 10 plain EIT_RedGem), so the EIT_S3* rows stay unused placeholders.
var gemTypes = []gemType{
	{"EIT_RedGem", 1},
	{"EIT_GreenGem", 2},
	{"EIT_BlueGem", 5},
	{"EIT_YellowGem", 10},
	{"EIT_PurpleGem", 25},
	{"EIT_S2RedGem", 1},
	{"EIT_S2GreenGem", 2},
	{"EIT_S2PurpleGem", 5},
	{"EIT_S2YellowGem", 10},
	{"EIT_S2MagentaGem", 25},
	{"EIT_S3RedGem", 1},
	{"EIT_S3GreenGem", 2},
	{"EIT_S3BlueGem", 5},
	{"EIT_S3GoldGem", 10},
	{"EIT_S3PurpleGem", 25},
}

// gemMarkerCount parses the GemHashArray element count behind a gem-type tag
// marker content end at m. The structural layout that must follow:
//
//	[NUL] [len=13] "GemHashArray\0" [len=14] "ArrayProperty\0" [u64 size]
//	[len=12] "IntProperty\0" [00] [u32 count]
//
// The array body is count u32 hashes, so size must equal 4+4*count. Both
// terminator widths are tried (1 byte ASCII, 2 bytes UTF-16): gemCollectionMap
// keys are ASCII strings, so the 1-byte form is the one real records take —
// verified against fixtures whose counts are known from pygvas.
func gemMarkerCount(data []byte, m int) (int, bool) {
	for tail := 1; tail <= 2; tail++ {
		o := asciiTagEnds(data, m+tail, "GemHashArray")
		o = asciiTagEnds(data, o, "ArrayProperty")
		if o < 0 || o+8 > len(data) {
			continue
		}
		size := binary.LittleEndian.Uint64(data[o:])
		o = asciiTagEnds(data, o+8, "IntProperty")
		o = zeroByte(data, o)
		if o < 0 || o+4 > len(data) {
			continue
		}
		count := int(binary.LittleEndian.Uint32(data[o:]))
		if size != uint64(4+4*count) {
			continue
		}
		return count, true
	}
	return 0, false
}

// ScanGems extracts per-region collected gem totals in VALUE units from a
// GVAS FalconSave blob, matching the fixture generator's gem_value_total + the
// watcher's region mapping. For every gem-type marker: the owning region comes from the
// level key preceding it, and the count from the GemHashArray that follows —
// the structural discriminator (GemHashArray within a few bytes after the
// tag) ignores the plain type-string occurrences inside gemHashTypeMap keys
// and saveDataList param blobs. Duplicate (region, type) records across save
// slots merge by MAX count (the collected-wins analog); region total =
// Σ maxCount[type] × value.
func ScanGems(data []byte) (map[string]int, ScanStats) {
	return scanGems(data, levelPathToRegion)
}

// ScanSpyro2Gems is ScanGems against the Spyro 2 level paths.
func ScanSpyro2Gems(data []byte) (map[string]int, ScanStats) {
	return scanGems(data, spyro2PathToRegion)
}

// ScanSpyro3Gems is ScanGems against the Spyro 3 level paths. The S3 save
// records its gems under the same EIT_S2* tags as Spyro 2, so no extra gem
// types exist; the "MoneybagGems" pseudo-key resolves to no region and its
// 8000-value stash stays out of every level total.
func ScanSpyro3Gems(data []byte) (map[string]int, ScanStats) {
	return scanGems(data, spyro3PathToRegion)
}

func scanGems(data []byte, regions map[string]string) (map[string]int, ScanStats) {
	var stats ScanStats
	if len(data) < 4 || string(data[:4]) != "GVAS" {
		return nil, stats
	}
	keys := findLevelKeys(data)
	values := make(map[string]int)
	for _, gt := range gemTypes {
		values[gt.tag] = gt.value
	}
	per := make(map[[2]string]int)
	for _, gt := range gemTypes {
		tag := "EInventoryType::" + gt.tag
		for _, m := range findMarkers(data, tag) {
			stats.Markers++
			count, ok := gemMarkerCount(data, m+len(tag))
			if ok {
				if r := regionFor(keys, m, regions); r != "" {
					k := [2]string{r, gt.tag}
					if count > per[k] {
						per[k] = count
					}
					continue
				}
			}
			stats.Skipped++
		}
	}
	out := make(map[string]int)
	for k, count := range per {
		out[k[0]] += count * values[k[1]]
	}
	return out, stats
}
