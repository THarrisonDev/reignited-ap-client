// Author: Tim Harrison
// Created: 2026-10-21
// Updated: 2026-10-21

package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// gvasWriter builds the little-endian records the synthetic scan tests feed
// the parsers.
type gvasWriter struct{ bytes.Buffer }

// str writes a GVAS FString: its length prefix counts the NUL terminator.
func (w *gvasWriter) str(s string) {
	_ = binary.Write(w, binary.LittleEndian, int32(len(s)+1))
	w.WriteString(s)
	w.WriteByte(0)
}

// u32 writes one little-endian uint32.
func (w *gvasWriter) u32(v uint32) {
	_ = binary.Write(w, binary.LittleEndian, v)
}

// f32 writes one little-endian float32.
func (w *gvasWriter) f32(v float32) {
	_ = binary.Write(w, binary.LittleEndian, math.Float32bits(v))
}

// guid writes one zeroed 16-byte GUID.
func (w *gvasWriter) guid() {
	for i := 0; i < 16; i++ {
		w.WriteByte(0)
	}
}

// patchU32 writes v over the u32 at off in the bytes built so far.
func (w *gvasWriter) patchU32(off int, v uint32) {
	binary.LittleEndian.PutUint32(w.Bytes()[off:], v)
}

// writeSave writes a fixture into the daemon's save folder as one save file,
// stamped newer than any earlier write.
func writeSave(t *testing.T, d *daemon, name, stem string) {
	t.Helper()
	stampSave(t, filepath.Join(d.saveDir, name), loadSave(t, stem))
}

// writeSaveBytes writes save bytes into the daemon's save folder, stamped newer
// than any earlier write.
func writeSaveBytes(t *testing.T, d *daemon, name string, data []byte) {
	t.Helper()
	stampSave(t, filepath.Join(d.saveDir, name), data)
}

// testDaemonSession is a test daemon with a fresh save folder and the given
// session body, holding no save file yet.
func testDaemonSession(t *testing.T, backfill bool, session string) *daemon {
	t.Helper()
	d := testDaemon(t, backfill)
	d.saveDir = t.TempDir()
	writeSession(t, d, session)
	return d
}

// seedSave is a test daemon with a fresh save folder holding fixture stem as
// one save file, plus the session body it plays with.
func seedSave(t *testing.T, backfill bool, name, stem, session string) *daemon {
	t.Helper()
	d := testDaemonSession(t, backfill, session)
	writeSave(t, d, name, stem)
	return d
}

// testDaemonWithIDs is a test daemon whose nameToID also holds the synthetic
// ids a stubbed table resolves to.
func testDaemonWithIDs(t *testing.T, backfill bool, ids map[string]int) *daemon {
	t.Helper()
	d := testDaemon(t, backfill)
	for name, id := range ids {
		d.nameToID[name] = id
	}
	return d
}

// nameSet is the set of names a drop sent.
func nameSet(names []string) map[string]bool {
	set := make(map[string]bool, len(names))
	for _, name := range names {
		set[name] = true
	}
	return set
}

// gameNameSet is the set of a drop's names, refusing any name outside the
// game's prefix ("Spyro 3: ").
func gameNameSet(t *testing.T, names []string, game string) map[string]bool {
	t.Helper()
	for _, n := range names {
		if !strings.HasPrefix(n, game+": ") {
			t.Fatalf("%s session dropped non-%s check %q", game, game, n)
		}
	}
	return nameSet(names)
}

// expectSent asserts the drop sent every one of the named locations.
func expectSent(t *testing.T, sent map[string]bool, names ...string) {
	t.Helper()
	for _, n := range names {
		if !sent[n] {
			t.Fatalf("location %q missing from the drop", n)
		}
	}
}

// countIDs counts the names that resolve through ids.
func countIDs(names []string, ids map[string]int) int {
	n := 0
	for _, name := range names {
		if _, ok := ids[name]; ok {
			n++
		}
	}
	return n
}

// blockDropTmp makes the drop's temporary path unwritable by taking it as a
// directory, and returns it.
func blockDropTmp(t *testing.T, d *daemon) string {
	t.Helper()
	blocker := filepath.Join(d.dropDir, dropName+".tmp")
	if err := os.Mkdir(blocker, 0755); err != nil {
		t.Fatalf("block drop tmp: %v", err)
	}
	return blocker
}

// parsedDoc parses the embedded locations.json for the table tests.
func parsedDoc(t *testing.T) locationsDoc {
	t.Helper()
	var doc locationsDoc
	if err := json.Unmarshal(locationsJSON, &doc); err != nil {
		t.Fatalf("parse embedded locations.json: %v", err)
	}
	return doc
}
