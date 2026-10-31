// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-23

package main

import (
	"math"
	"sort"
)

const skillPointMarker = "EInventoryType::EIT_SkillPoint"

// skillPointRanges is the ESkillPoint enum range per game index (0/1/2):
// S1 1..14, S2 15..30, S3 31..50 (the game's own Falcon_enums),
// populated by init() from each game's "skillPointRange" in the embedded
// locations.json. Values outside the session game's range are ignored.
var skillPointRanges [3][2]int

// spParam reads one saveParams element at o (a StructProperty body: property
// list + "None" terminator) whose paramName must be an empty FString, and
// returns the paramValue float.
func spParam(data []byte, o int) (float32, int, bool) {
	r := atReader(data, o)
	r.tag("paramName")
	r.tag("StrProperty")
	r.skip0() // u32 size 4 (the empty FString's prefix) + ai 0
	r.nul()
	r.zero32() // the empty FString: u32 0
	r.tag("paramValue")
	r.tag("FloatProperty")
	r.skip0() // u32 size 4 + ai 0
	r.nul()
	if !r.ok {
		return 0, -1, false
	}
	bits, ok := readU32(data, r.o)
	if !ok {
		return 0, -1, false
	}
	return math.Float32frombits(bits), r.o + 4, true
}

// spArrayBody parses the ArrayProperty<StructProperty> body at o (after the
// inner-type tag's NUL, which the caller consumes): u32 count, repeated field
// name ("saveParams"), member type ("StructProperty"), u32 bodyLen, u32 0,
// type-name FString ("PhasmidSaveParam"), 16-byte GUID, 1 NUL, then count
// struct elements, returning the offset past the array body and the
// per-element paramValues. The element count and the consumed element bytes
// (against bodyLen) are validated so a truncated record fails instead of
// reading past the array.
func spArrayBody(data []byte, o int) ([]float32, int, bool) {
	count, ok := spCount(data, o)
	if !ok {
		return nil, -1, false
	}
	r := atReader(data, o+4)
	r.tag("saveParams")
	r.tag("StructProperty")
	bodyLen, ok := readU32(data, r.o)
	if !ok {
		return nil, -1, false
	}
	r.o += 4
	r.zero32()
	r.tag("PhasmidSaveParam")
	r.guid()
	r.nul()
	if !r.ok {
		return nil, -1, false
	}
	vals, end, ok := spParams(data, r.o, count)
	if !ok || end-r.o != int(bodyLen) {
		return nil, -1, false
	}
	return vals, end, true
}

// spCount reads the saveParams element count at o, which must be 0..64.
func spCount(data []byte, o int) (int, bool) {
	bits, ok := readU32(data, o)
	if !ok {
		return 0, false
	}
	c := int(bits)
	if c < 0 || c > 64 {
		return 0, false
	}
	return c, true
}

// spParams reads n saveParams elements from o, returning their values and the
// offset past the last one.
func spParams(data []byte, o, n int) ([]float32, int, bool) {
	var vals []float32
	for i := 0; i < n; i++ {
		v, next, ok := spParam(data, o)
		if !ok {
			return nil, -1, false
		}
		r := atReader(data, next)
		r.tag("None")
		if !r.ok {
			return nil, -1, false
		}
		o = r.o
		vals = append(vals, v)
	}
	return vals, o, true
}

// scanSkillPointsOne parses the skill-point record whose marker sits at m,
// returning the ESkillPoint enum values of the earned points. The record
// layout (verified byte-by-byte against the 100% save's three entries, the
// mirror blob and pygvas's readers):
//
//	[NUL] [len]"collected\0" [len]"BoolProperty\0" u64 0 1 value 1 NUL
//	[len]"None\0"
//	[len]"itemParamList\0" [len]"StructProperty\0" u32 size u32 0
//	[len]"PhasmidSaveParamList\0" 16B guid 1 NUL
//	[len]"saveParams\0" [len]"ArrayProperty\0" u32 size u32 0
//	[len]"StructProperty\0" 1 NUL
//	u32 count [len]"saveParams\0" [len]"StructProperty\0"
//	u32 bodyLen u32 0 [len]"PhasmidSaveParam\0" 16B guid 1 NUL
//	count x ([len]"paramName\0" [len]"StrProperty\0" u32 4 u32 0 1 NUL
//	         u32 0 [len]"paramValue\0" [len]"FloatProperty\0" u32 4 u32 0 1 NUL
//	         4B float [len]"None\0")
//	[len]"None\0"
//
// paramName is an empty FString for every skill point (u32 0 — an empty
// FString, not the 1-byte "None" encoding) and the float is the ESkillPoint
// enum value. The ArrayProperty body repeats the field name ("saveParams")
// and member type ("StructProperty") before its own size/guid header —
// pygvas's ArrayProperty.read_body order, which the Phasmid fixed-shape
// serialization follows. The collected BoolProperty is always false and is
// only shape-checked.
func scanSkillPointsOne(data []byte, m int) ([]float32, bool) {
	return scanParamRecord(data, m, skillPointMarker, 0)
}

// scanParamRecord walks the record whose marker (the full "EInventoryType::"
// tag) sits at m through the layout scanSkillPointsOne documents, requiring
// the collected BoolProperty's value byte to equal collected, and returns the
// saveParams paramValues. Skill points (collected=false) and the Spyro 1
// flight rewards (collected=true) share it.
func scanParamRecord(data []byte, m int, marker string, collected byte) ([]float32, bool) {
	o := spCollectedTag(data, m, marker)
	if o <= 0 {
		return nil, false
	}
	r := atReader(data, o)
	r.tag("BoolProperty")
	r.skip0() // u32 size 0 + u32 arrayIndex 0
	r.boolValue(collected)
	r.nul()
	r.tag("None")
	r.tag("itemParamList")
	r.tag("StructProperty")
	r.structHeader("PhasmidSaveParamList")
	r.tag("saveParams")
	r.tag("ArrayProperty")
	r.skip0() // u32 size + u32 arrayIndex 0
	r.tag("StructProperty")
	r.nul()
	if !r.ok {
		return nil, false
	}
	vals, end, ok := spArrayBody(data, r.o)
	if !ok {
		return nil, false
	}
	tail := atReader(data, end)
	tail.tag("None")
	if !tail.ok {
		return nil, false
	}
	return vals, true
}

// spCollectedTag finds the "collected" property that follows the marker's own
// NUL terminator (1 byte ASCII, 2 bytes UTF-16), returning its offset or -1.
func spCollectedTag(data []byte, m int, marker string) int {
	for _, skip := range []int{1, 2} {
		if o := tagEnds(data, m+len(marker)+skip, "collected"); o >= 0 {
			return o
		}
	}
	return -1
}

// ScanSkillPoints extracts the ESkillPoint enum values of the earned skill
// points from a GVAS FalconSave blob (or one save entry, which the daemon
// scans): each game entry's Global level holds exactly one
// EInventoryType::EIT_SkillPoint record whose saveParams array carries one
// nameless {enumValue: float} param per earned skill point. Multiple markers
// merge (dedupe, sorted) defensively; markers whose record does not parse are
// counted in Skipped.
func ScanSkillPoints(data []byte) ([]int, ScanStats) {
	var stats ScanStats
	if len(data) < 4 || string(data[:4]) != "GVAS" {
		return nil, stats
	}
	markers := findMarkers(data, skillPointMarker)
	stats.Markers = len(markers)
	seen := make(map[int]bool)
	for _, m := range markers {
		vals, ok := scanSkillPointsOne(data, m)
		if !ok {
			stats.Skipped++
			continue
		}
		for _, v := range vals {
			seen[int(v)] = true
		}
	}
	out := make([]int, 0, len(seen))
	for v := range seen {
		out = append(out, v)
	}
	sort.Ints(out)
	return out, stats
}
