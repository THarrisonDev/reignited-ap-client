package main

import (
	"encoding/binary"
	"math"
	"sort"
)

const skillPointMarker = "EInventoryType::EIT_SkillPoint"

// skillPointRanges is the ESkillPoint enum range per game index (0/1/2):
// S1 1..14, S2 15..30, S3 31..50 (docs/falcon_sdk_dump/Falcon_enums.hpp),
// populated by init() from each game's "skillPointRange" in the embedded
// locations.json. Values outside the session game's range are ignored.
var skillPointRanges [3][2]int

// spSkip0 reads a u32 size field plus its u32 0 array index at o, returning
// the offset past both.
func spSkip0(data []byte, o int) int {
	if o = skipU32(data, o); o < 0 {
		return -1
	}
	return zeroU32(data, o)
}

// spStructHeader parses a StructProperty-style header at o after its
// "StructProperty\0" tag: u32 size, u32 0 array index, type-name FString,
// 16-byte GUID and the terminating NUL, returning the offset past it.
func spStructHeader(data []byte, o int, typeName string) int {
	if o = spSkip0(data, o); o < 0 {
		return -1
	}
	if o = tagEnds(data, o, typeName); o < 0 {
		return -1
	}
	if o+16 > len(data) {
		return -1
	}
	o += 16
	return zeroByte(data, o)
}

// spParam reads one saveParams element at o (a StructProperty body: property
// list + "None" terminator) whose paramName must be an empty FString, and
// returns the paramValue float.
func spParam(data []byte, o int) (float32, int, bool) {
	if o = tagEnds(data, o, "paramName"); o < 0 {
		return 0, -1, false
	}
	if o = tagEnds(data, o, "StrProperty"); o < 0 {
		return 0, -1, false
	}
	if o = spSkip0(data, o); o < 0 { // u32 size 4 (the empty FString's prefix) + ai 0
		return 0, -1, false
	}
	if o = zeroByte(data, o); o < 0 {
		return 0, -1, false
	}
	if o = zeroU32(data, o); o < 0 { // the empty FString: u32 0
		return 0, -1, false
	}
	if o = tagEnds(data, o, "paramValue"); o < 0 {
		return 0, -1, false
	}
	if o = tagEnds(data, o, "FloatProperty"); o < 0 {
		return 0, -1, false
	}
	if o = spSkip0(data, o); o < 0 { // u32 size 4 + ai 0
		return 0, -1, false
	}
	if o = zeroByte(data, o); o < 0 {
		return 0, -1, false
	}
	if o+4 > len(data) {
		return 0, -1, false
	}
	v := math.Float32frombits(binary.LittleEndian.Uint32(data[o:]))
	return v, o + 4, true
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
	count := -1
	if o >= 0 && o+4 <= len(data) {
		c := int(binary.LittleEndian.Uint32(data[o:]))
		if c >= 0 && c <= 64 {
			count = c
		}
	}
	if count < 0 {
		return nil, -1, false
	}
	o += 4
	if o = tagEnds(data, o, "saveParams"); o < 0 {
		return nil, -1, false
	}
	if o = tagEnds(data, o, "StructProperty"); o < 0 {
		return nil, -1, false
	}
	if o+4 > len(data) {
		return nil, -1, false
	}
	bodyLen := int(binary.LittleEndian.Uint32(data[o:]))
	o += 4
	if o = zeroU32(data, o); o < 0 {
		return nil, -1, false
	}
	if o = tagEnds(data, o, "PhasmidSaveParam"); o < 0 {
		return nil, -1, false
	}
	if o+16 > len(data) {
		return nil, -1, false
	}
	o += 16
	if o = zeroByte(data, o); o < 0 {
		return nil, -1, false
	}
	start := o
	var vals []float32
	for i := 0; i < count; i++ {
		var v float32
		var ok bool
		if v, o, ok = spParam(data, o); !ok {
			return nil, -1, false
		}
		if o = tagEnds(data, o, "None"); o < 0 {
			return nil, -1, false
		}
		vals = append(vals, v)
	}
	if o-start != bodyLen {
		return nil, -1, false
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
	var o int
	for _, skip := range []int{1, 2} { // the marker value's own NUL (1/2 bytes)
		if e := tagEnds(data, m+len(marker)+skip, "collected"); e >= 0 {
			o = e
			break
		}
	}
	if o <= 0 {
		return nil, false
	}
	if o = tagEnds(data, o, "BoolProperty"); o < 0 {
		return nil, false
	}
	if o = spSkip0(data, o); o < 0 { // u32 size 0 + u32 arrayIndex 0
		return nil, false
	}
	if o >= len(data) || data[o] != collected { // the value byte
		return nil, false
	}
	if o = zeroByte(data, o+1); o < 0 {
		return nil, false
	}
	if o = tagEnds(data, o, "None"); o < 0 {
		return nil, false
	}
	if o = tagEnds(data, o, "itemParamList"); o < 0 {
		return nil, false
	}
	if o = tagEnds(data, o, "StructProperty"); o < 0 {
		return nil, false
	}
	if o = spStructHeader(data, o, "PhasmidSaveParamList"); o < 0 {
		return nil, false
	}
	if o = tagEnds(data, o, "saveParams"); o < 0 {
		return nil, false
	}
	if o = tagEnds(data, o, "ArrayProperty"); o < 0 {
		return nil, false
	}
	if o = spSkip0(data, o); o < 0 { // u32 size + u32 arrayIndex 0
		return nil, false
	}
	if o = tagEnds(data, o, "StructProperty"); o < 0 {
		return nil, false
	}
	if o = zeroByte(data, o); o < 0 {
		return nil, false
	}
	vals, end, ok := spArrayBody(data, o)
	if !ok {
		return nil, false
	}
	if o = tagEnds(data, end, "None"); o < 0 {
		return nil, false
	}
	return vals, true
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
