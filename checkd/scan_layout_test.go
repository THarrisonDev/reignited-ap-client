// Author: Tim Harrison
// Created: 2026-10-16

package main

import "testing"

// TestScanSaveReadsUTF16Value: a non-ASCII FString is written as UTF-16LE with a
// negative length prefix. The record's *value* read must handle the wide form;
// the property header in front of it is width-independent (u32 size, u32 array
// index, u8 guid flag), so only the FString body differs.
func TestScanSaveReadsUTF16Value(t *testing.T) {
	data := loadSave(t, "unicode_s1")
	dragons, stats := ScanSave(data)
	if len(dragons) != 1 {
		t.Fatalf("got %d dragons (stats %+v), want 1", len(dragons), stats)
	}
	if want := "N\u00e9stor"; dragons[0].Name != want {
		t.Fatalf("name = %q, want %q", dragons[0].Name, want)
	}
	if dragons[0].Region != "Stone Hill" {
		t.Fatalf("region = %q, want Stone Hill", dragons[0].Region)
	}
	if !dragons[0].Collected {
		t.Fatal("the fixture's dragon is collected")
	}
}

// TestSaveEntryIgnoresKeywordInValue pins the structural entry finder: a save
// whose *value* reads exactly "levelObjectMap" has ten raw occurrences of those
// bytes. The earlier bare-byte count saw ten and refused to yield any entry, so
// the whole session silently scanned nothing.
func TestSaveEntryIgnoresKeywordInValue(t *testing.T) {
	data := loadSave(t, "keyword_collision")
	if got := len(findAll(data, []byte("levelObjectMap"))); got != saveEntries+1 {
		t.Fatalf("fixture precondition: raw levelObjectMap count = %d, want %d",
			got, saveEntries+1)
	}
	if got := len(mapPropertyStarts(data, "levelObjectMap")); got != saveEntries {
		t.Fatalf("structural levelObjectMap count = %d, want %d", got, saveEntries)
	}
	entry, ok := saveEntry(data, entryIndex(0, 0))
	if !ok {
		t.Fatal("a value collision must not hide the entry")
	}
	dragons, _ := ScanSave(entry)
	if len(dragons) != 1 || dragons[0].Name != "levelObjectMap" {
		t.Fatalf("entry 0 dragons = %+v, want the colliding name", dragons)
	}
}
