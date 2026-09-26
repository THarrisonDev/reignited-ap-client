package main

import (
	"bytes"
	"encoding/binary"
	"math"
	"sort"
	"strconv"
)

// ScanSparxPowers extracts the Sparx-power names obtained for one (slot, game)
// pair from a GVAS FalconSave blob: the file's single top-level globalFloatMap
// (StrProperty keys -> FloatProperty values, after the last levelObjectMap
// entry) holds one "collected.<slot>.<game>.EIT_SparxPower_<Name>" key per
// power the save knows about; a float != 0 means obtained. The returned names
// are the enum-name suffixes (e.g. "GemCollectRange"), deduped and sorted.
// Markers = the total globalFloatMap entries scanned, Skipped = entries whose
// key FString or value failed to parse. The map is file-global (not inside any
// save entry), so the caller passes the session's slot and game and other
// slots' keys are ignored.
func ScanSparxPowers(data []byte, slot, game int) ([]string, ScanStats) {
	var stats ScanStats
	if len(data) < 4 || string(data[:4]) != "GVAS" {
		return nil, stats
	}
	off := bytes.Index(data, []byte("globalFloatMap\x00"))
	if off < 0 {
		return nil, stats
	}
	o := off + len("globalFloatMap") + 1
	if o = tagEnds(data, o, "MapProperty"); o < 0 {
		return nil, stats
	}
	if o = skipU32(data, o); o < 0 { // u32 body size
		return nil, stats
	}
	if o = skipU32(data, o); o < 0 { // u32 array index (the two u32s
		return nil, stats // read as a u64 size by the tag's GVAS form)
	}
	if o = tagEnds(data, o, "StrProperty"); o < 0 {
		return nil, stats
	}
	if o = tagEnds(data, o, "FloatProperty"); o < 0 {
		return nil, stats
	}
	if o = zeroByte(data, o); o < 0 { // the tag's NUL terminator
		return nil, stats
	}
	if o = zeroU32(data, o); o < 0 { // allocation flags
		return nil, stats
	}
	if o+4 > len(data) {
		return nil, stats
	}
	count := int(int32(binary.LittleEndian.Uint32(data[o:])))
	if count < 0 || count > 4096 {
		return nil, stats
	}
	o += 4
	stats.Markers = count
	prefix := []byte("collected." + strconv.Itoa(slot) + "." + strconv.Itoa(game) + "." + sparxPowerTag)
	seen := make(map[string]bool)
	for i := 0; i < count; i++ {
		key, val, next, ok := gfmEntry(data, o)
		if !ok {
			stats.Skipped += count - i
			break
		}
		o = next
		if !bytes.HasPrefix(key, prefix) {
			continue
		}
		name := string(key[len(prefix):])
		if name == "" {
			continue
		}
		if val != 0 {
			seen[name] = true
		}
	}
	out := make([]string, 0, len(seen))
	for name := range seen {
		out = append(out, name)
	}
	sort.Strings(out)
	return out, stats
}

// gfmEntry parses one globalFloatMap entry at o (key FString + 4-byte float),
// returning the key content, the value and the offset past the entry. Unlike
// readFString the key stays raw bytes: exactly its terminator is dropped and
// UTF-16 keys narrow to their low bytes (utf16ToASCII), so it is matched
// byte-for-byte against the ASCII key prefix.
func gfmEntry(data []byte, o int) (key []byte, val float32, next int, ok bool) {
	body, wide, o, ok := fstringBody(data, o)
	if !ok {
		return nil, 0, -1, false
	}
	switch {
	case wide:
		key = utf16ToASCII(body[:len(body)-2])
	case len(body) > 0:
		key = body[:len(body)-1]
	}
	if o+4 > len(data) {
		return nil, 0, -1, false
	}
	val = math.Float32frombits(binary.LittleEndian.Uint32(data[o:]))
	return key, val, o + 4, true
}

// utf16ToASCII decodes UTF-16LE bytes to an ASCII byte string (code units
// 0..255 pass through, matching the key alphabet the game writes).
func utf16ToASCII(b []byte) []byte {
	out := make([]byte, len(b)/2)
	for i := range out {
		out[i] = b[2*i]
	}
	return out
}
