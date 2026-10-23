// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-11

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
	o, count, ok := gfmBody(data)
	if !ok {
		return nil, stats
	}
	stats.Markers = count
	prefix := []byte("collected." + strconv.Itoa(slot) + "." + strconv.Itoa(game) + "." + sparxPowerTag)
	return gfmPowers(data, o, count, prefix, &stats), stats
}

// gfmBody walks the file's globalFloatMap header and returns the offset of its
// first entry and the entry count.
func gfmBody(data []byte) (int, int, bool) {
	// The property is matched by structure so a value that reads the same
	// cannot be picked up instead (see mapPropertyStarts).
	starts := mapPropertyStarts(data, "globalFloatMap")
	if len(starts) == 0 {
		return 0, 0, false
	}
	r := atReader(data, starts[0])
	r.tag("globalFloatMap")
	r.tag("MapProperty")
	r.skip32() // u32 body size
	r.skip32() // u32 array index (read as a u64 size by the tag's GVAS form)
	r.tag("StrProperty")
	r.tag("FloatProperty")
	r.nul()    // the tag's NUL terminator
	r.zero32() // allocation flags
	if !r.ok {
		return 0, 0, false
	}
	bits, ok := readU32(data, r.o)
	if !ok {
		return 0, 0, false
	}
	count := int(int32(bits))
	if count < 0 || count > 4096 {
		return 0, 0, false
	}
	return r.o + 4, count, true
}

// gfmPowers returns the sorted, deduped suffix names of the map entries whose
// key starts with prefix and whose value is non-zero.
func gfmPowers(data []byte, o, count int, prefix []byte, stats *ScanStats) []string {
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
	return out
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
