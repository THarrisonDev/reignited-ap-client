// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-23

package main

import (
	"bytes"
	"encoding/binary"
	"sort"
	"strings"
	"unicode/utf16"
)

type Dragon struct {
	Region    string
	Name      string
	Collected bool
}

type Egg struct {
	Region    string
	Ordinal   int
	Collected bool
}

type ScanStats struct {
	Markers int
	Skipped int
}

const dragonMarker = "EInventoryType::EIT_Dragon"
const eggMarker = "EInventoryType::EIT_Egg"
const orbMarker = "EInventoryType::EIT_S2GreenOrb"
const talismanMarker = "EInventoryType::EIT_Talisman"
const s3EggMarker = "EInventoryType::EIT_S3Egg"
const s3BonusEggMarker = "EInventoryType::EIT_S3BonusEgg"

// abilityTypes are the Spyro 2 Money Bags abilities: the tag after
// "EInventoryType::" in the global inventory and the bare check name.
// EIT_Superflame (the Dragon Shores 100% reward, not a Money Bags purchase)
// is deliberately absent.
var abilityTypes = []struct{ tag, name string }{
	{"EIT_Swimming", "Swim"},
	{"EIT_Climbing", "Climb"},
	{"EIT_HeadBash", "Headbash"},
}

func utf16Bytes(s string) []byte {
	out := make([]byte, 2*len(s))
	for i := 0; i < len(s); i++ {
		out[2*i] = s[i]
	}
	return out
}

// findMarkers returns the offsets of every occurrence of s in data in either
// ASCII or UTF-16LE form, ascending.
func findMarkers(data []byte, s string) []int {
	out := findAll(data, []byte(s))
	out = append(out, findAll(data, utf16Bytes(s))...)
	sort.Ints(out)
	return out
}

func findAll(data, pat []byte) []int {
	var out []int
	off := 0
	for {
		i := bytes.Index(data[off:], pat)
		if i < 0 {
			return out
		}
		off += i
		out = append(out, off)
		off++
	}
}

// findTag returns the earliest occurrence of tag in data[from:to] across both
// encodings, with the byte length of the matched tag including its NUL
// terminator (1 byte ASCII, one 2-byte NUL code unit UTF-16). Unlike tagEnds
// it searches rather than matching at a fixed offset, and ignores the FString
// length prefix: the record parsers use it to skip over property headers
// whose layout they do not pin.
func findTag(data []byte, tag string, from, to int) (off, tagLen int) {
	if from < 0 {
		from = 0
	}
	if to > len(data) {
		to = len(data)
	}
	if from >= to {
		return -1, 0
	}
	best := -1
	bestLen := 0
	for _, pat := range [][]byte{[]byte(tag), utf16Bytes(tag)} {
		i := bytes.Index(data[from:to], pat)
		if i >= 0 && (best < 0 || from+i < best) {
			best = from + i
			if len(pat) == len(tag) {
				bestLen = len(pat) + 1
			} else {
				bestLen = len(pat) + 2
			}
		}
	}
	return best, bestLen
}

// tagEnds checks that the FString with the given content (ASCII or UTF-16,
// NUL-terminated, exact length prefix) starts at o and returns the offset
// past its NUL, or -1.
func tagEnds(data []byte, o int, tag string) int {
	if e := asciiTagEnds(data, o, tag); e >= 0 {
		return e
	}
	if o < 0 || o+4 > len(data) {
		return -1
	}
	if int32(binary.LittleEndian.Uint32(data[o:])) != -int32(len(tag)+1) {
		return -1
	}
	end := o + 4 + 2*(len(tag)+1)
	if end <= len(data) && bytes.Equal(data[o+4:end], append(utf16Bytes(tag), 0, 0)) {
		return end
	}
	return -1
}

// asciiTagEnds is tagEnds accepting only the ASCII form (the gem records'
// GemHashArray chain is only ever written ASCII).
func asciiTagEnds(data []byte, o int, tag string) int {
	if o < 0 || o+4 > len(data) {
		return -1
	}
	if int32(binary.LittleEndian.Uint32(data[o:])) != int32(len(tag)+1) {
		return -1
	}
	end := o + 4 + len(tag) + 1
	if end <= len(data) && bytes.Equal(data[o+4:end], []byte(tag+"\x00")) {
		return end
	}
	return -1
}

// zeroByte reads the NUL byte at o, returning the offset past it or -1.
func zeroByte(data []byte, o int) int {
	if o < 0 || o >= len(data) || data[o] != 0 {
		return -1
	}
	return o + 1
}

// zeroU32 reads a u32 at o that must be 0, returning the offset past it or
// -1.
func zeroU32(data []byte, o int) int {
	if o < 0 || o+4 > len(data) || binary.LittleEndian.Uint32(data[o:]) != 0 {
		return -1
	}
	return o + 4
}

// skipU32 skips a u32 field at o (only bounds-checked), returning the offset
// past it or -1.
func skipU32(data []byte, o int) int {
	if o < 0 || o+4 > len(data) {
		return -1
	}
	return o + 4
}

// readU32 reads the u32 at o.
func readU32(data []byte, o int) (uint32, bool) {
	if o < 0 || o+4 > len(data) {
		return 0, false
	}
	return binary.LittleEndian.Uint32(data[o:]), true
}

// reader walks a fixed-shape save record. The first field that does not match
// latches ok false and leaves every later step a no-op, so a caller checks the
// chain once.
type reader struct {
	data []byte
	o    int
	ok   bool
}

// atReader starts reading data at o.
func atReader(data []byte, o int) *reader {
	return &reader{data: data, o: o, ok: o >= 0}
}

// tag advances past the FString tag.
func (r *reader) tag(name string) {
	if r.ok {
		if r.o = tagEnds(r.data, r.o, name); r.o < 0 {
			r.ok = false
		}
	}
}

// skip32 advances past a u32 field's bytes without checking its value.
func (r *reader) skip32() {
	if r.ok {
		if r.o = skipU32(r.data, r.o); r.o < 0 {
			r.ok = false
		}
	}
}

// skip0 advances past a u32 size field and its u32 zero array index.
func (r *reader) skip0() {
	if r.ok {
		if r.o = skipU32(r.data, r.o); r.o < 0 {
			r.ok = false
			return
		}
		if r.o = zeroU32(r.data, r.o); r.o < 0 {
			r.ok = false
		}
	}
}

// zero32 advances past a u32 that must be 0.
func (r *reader) zero32() {
	if r.ok {
		if r.o = zeroU32(r.data, r.o); r.o < 0 {
			r.ok = false
		}
	}
}

// nul advances past a NUL byte.
func (r *reader) nul() {
	if r.ok {
		if r.o = zeroByte(r.data, r.o); r.o < 0 {
			r.ok = false
		}
	}
}

// guid advances past a 16-byte GUID.
func (r *reader) guid() {
	if !r.ok {
		return
	}
	if r.o+16 > len(r.data) {
		r.ok = false
		return
	}
	r.o += 16
}

// boolValue advances past a BoolProperty's value byte, which must equal want.
func (r *reader) boolValue(want byte) {
	if !r.ok {
		return
	}
	if r.o >= len(r.data) || r.data[r.o] != want {
		r.ok = false
		return
	}
	r.o++
}

// structHeader advances past a StructProperty body header: a u32 size, a u32
// zero array index, the type-name FString, a 16-byte GUID and the NUL.
func (r *reader) structHeader(typeName string) {
	r.skip0()
	r.tag(typeName)
	r.guid()
	r.nul()
}

// fstringBody splits the GVAS FString at off: i32 length prefix; positive =
// ANSI bytes (length includes the NUL), negative = UTF-16LE (-length code
// units including the NUL unit), 0 = empty. body is the raw content including
// its terminator, wide reports the UTF-16 form, next is the offset past it.
func fstringBody(data []byte, off int) (body []byte, wide bool, next int, ok bool) {
	if off < 0 || off+4 > len(data) {
		return nil, false, -1, false
	}
	n := int(int32(binary.LittleEndian.Uint32(data[off:])))
	o := off + 4
	switch {
	case n > 0:
		if o+n > len(data) {
			return nil, false, -1, false
		}
		return data[o : o+n], false, o + n, true
	case n < 0:
		if o+2*-n > len(data) {
			return nil, false, -1, false
		}
		return data[o : o+2*-n], true, o + 2*-n, true
	}
	return nil, false, o, true
}

// readFString decodes a GVAS FString at off (see fstringBody), trimming
// trailing NULs.
func readFString(data []byte, off int) (string, bool) {
	body, wide, _, ok := fstringBody(data, off)
	if !ok {
		return "", false
	}
	if !wide {
		return strings.TrimRight(string(body), "\x00"), true
	}
	codes := make([]uint16, len(body)/2)
	for i := range codes {
		codes[i] = binary.LittleEndian.Uint16(body[2*i:])
	}
	return strings.TrimRight(string(utf16.Decode(codes)), "\x00"), true
}

type levelKey struct {
	off  int
	path string
}

// isLevelKeyAt checks that the level-path FString whose NUL terminator sits at
// nulOff is followed by the level struct's leading property name, the
// "objectDataMap" FString. That tail is what separates a true levelObjectMap
// TMap key from a level path occurring as a paramName value (followed by
// "paramValue" instead) — both appear in live saves. The path's own terminator
// width decides how far to step; the tag itself is an engine property name and
// is matched in either encoding.
func isLevelKeyAt(data []byte, nulOff int) bool {
	if tagEnds(data, nulOff+1, "objectDataMap") >= 0 { // ASCII path: 1-byte NUL
		return true
	}
	return tagEnds(data, nulOff+2, "objectDataMap") >= 0 // UTF-16 path: 2-byte NUL unit
}

func validLevelPath(p string) bool {
	if !strings.HasPrefix(p, "/LS") || !strings.HasSuffix(p, "/Maps/") {
		return false
	}
	p = strings.TrimSuffix(p, "/Maps/")
	if len(p) < 5 {
		return false
	}
	i := 3
	for i < len(p) && p[i] >= '0' && p[i] <= '9' {
		i++
	}
	if i < 4 || i >= len(p) || p[i] != '_' {
		return false
	}
	return isIdent(p[i+1:])
}

// isIdent reports whether every byte of s can appear in a level-folder name
// segment. An empty s passes.
func isIdent(s string) bool {
	for i := 0; i < len(s); i++ {
		if !isIdentByte(s[i]) {
			return false
		}
	}
	return true
}

// isIdentByte reports whether c can appear in a level-folder name segment.
func isIdentByte(c byte) bool {
	return c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_'
}

// findLevelKeys locates every true levelObjectMap key: a "/LS###_.../Maps/"
// FString whose terminator is immediately followed by the objectDataMap
// property tag. ASCII and UTF-16 forms both handled (stride 1 vs 2). The S3
// save also holds a non-level "MoneybagGems" TMap key with the same tail; it
// is included so the markers it owns (its gemCollectionMap) attribute to it
// instead of the level key before it, and resolve to no region there.
func findLevelKeys(data []byte) []levelKey {
	out := mapsLevelKeys(data)
	out = append(out, moneybagKeys(data)...)
	sort.Slice(out, func(i, j int) bool { return out[i].off < out[j].off })
	return out
}

// mapsLevelKeys finds the level keys whose path ends in "/Maps/".
func mapsLevelKeys(data []byte) []levelKey {
	var out []levelKey
	for _, mapsPat := range [][]byte{[]byte("/Maps/"), utf16Bytes("/Maps/")} {
		stride := 1
		if len(mapsPat) == 12 {
			stride = 2
		}
		out = append(out, keysBeforeMaps(data, mapsPat, stride)...)
	}
	return out
}

// keysBeforeMaps returns the level keys whose "/Maps/" match at the given
// stride holds mapsPat.
func keysBeforeMaps(data, mapsPat []byte, stride int) []levelKey {
	var out []levelKey
	off := 0
	for {
		i := bytes.Index(data[off:], mapsPat)
		if i < 0 {
			return out
		}
		off += i
		if k, ok := levelKeyAt(data, off, stride); ok {
			out = append(out, k)
		}
		off++
	}
}

// levelKeyAt walks backward from the "/Maps/" match at mapsOff to the path's
// start, returning the key when the record is a real level key.
func levelKeyAt(data []byte, mapsOff, stride int) (levelKey, bool) {
	start := pathStart(data, mapsOff, stride)
	if start < 0 {
		return levelKey{}, false
	}
	end := mapsOff + 6*stride
	path := decodePath(data[start:end], stride)
	if !validLevelPath(path) || !isLevelKeyAt(data, end) {
		return levelKey{}, false
	}
	return levelKey{start, path}, true
}

// pathStart walks backward from the character before a "/Maps/" match to the
// '/' that opens the level path, or -1 when none opens within 64 steps.
func pathStart(data []byte, mapsOff, stride int) int {
	p := mapsOff - stride
	for k := 0; k < 64; k++ {
		if p < 0 {
			return -1
		}
		c := data[p]
		if stride == 2 && data[p+1] != 0 {
			return -1
		}
		if c == '/' && k > 0 {
			return p
		}
		if !isIdentByte(c) {
			return -1
		}
		p -= stride
	}
	return -1
}

// decodePath decodes path bytes at one stride (1 = ASCII, 2 = UTF-16LE).
func decodePath(content []byte, stride int) string {
	if stride == 1 {
		return string(content)
	}
	codes := make([]uint16, len(content)/2)
	for j := range codes {
		codes[j] = binary.LittleEndian.Uint16(content[2*j:])
	}
	return string(utf16.Decode(codes))
}

// moneybagKeys finds the "MoneybagGems" pseudo-key, which carries no "/Maps/"
// tail and so is matched directly. Resolves to no region (not in any path
// table) but stops the backward walk from filing its gems under Harbor
// Speedway, the level key before it in the 100% save.
func moneybagKeys(data []byte) []levelKey {
	var out []levelKey
	for _, pat := range [][]byte{[]byte("MoneybagGems\x00"), utf16Bytes("MoneybagGems\x00")} {
		off := 0
		for {
			i := bytes.Index(data[off:], pat)
			if i < 0 {
				break
			}
			at := off + i
			// the pattern includes the NUL terminator, so the property tag
			// starts at at+len(pat); isLevelKeyAt wants the NUL's offset.
			if isLevelKeyAt(data, at+len(pat)-1) {
				out = append(out, levelKey{at, "MoneybagGems"})
			}
			off = at + 1
		}
	}
	return out
}

// framedTagStarts returns the offset of every FString whose i32 length prefix
// and NUL framing are exactly tag: a real property/tag name, not the same bytes
// inside some value. The returned offset is the length prefix, so callers slice
// from the property boundary.
func framedTagStarts(data []byte, tag string) []int {
	var out []int
	needle := []byte(tag)
	for off := 0; ; {
		i := bytes.Index(data[off:], needle)
		if i < 0 {
			return out
		}
		at := off + i - 4 // the FString length prefix precedes the content
		off += i + 1
		if at >= 0 && tagEnds(data, at, tag) >= 0 {
			out = append(out, at)
		}
	}
}

// mapPropertyStarts returns the offset of every framed `name` immediately
// followed by the framed "MapProperty" type tag: the structure of a
// saveDataMapArray entry's levelObjectMap property (and of the file's single
// globalFloatMap). Matching the structure, not the bare bytes, keeps a save
// whose *value* reads the same as the property name from looking like an extra
// entry — that mistake silently disabled scanning for the whole session.
func mapPropertyStarts(data []byte, name string) []int {
	var out []int
	for _, at := range framedTagStarts(data, name) {
		after := tagEnds(data, at, name)
		if after >= 0 && tagEnds(data, after, "MapProperty") >= 0 {
			out = append(out, at)
		}
	}
	return out
}

// regionFor resolves the region for a marker at m: the last level key
// preceding it, mapped through a game's path table (levelPathToRegion,
// spyro2PathToRegion, spyro3PathToRegion). Unknown paths (e.g. another game's
// levels) resolve to "" and the record is skipped — the mod never sends
// unknown levels.
func regionFor(keys []levelKey, m int, regions map[string]string) string {
	return regions[levelPathBefore(keys, m)]
}

func levelPathBefore(keys []levelKey, m int) string {
	path := ""
	for _, k := range keys {
		if k.off >= m {
			break
		}
		path = k.path
	}
	return path
}
