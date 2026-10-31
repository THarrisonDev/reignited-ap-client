// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-23

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
)

// dropPayload is the wire format of a checks.json drop: a monotonic sequence
// together with the resolved location IDs and their names.
type dropPayload struct {
	Seq    int      `json:"seq"`
	Checks []int    `json:"checks"`
	Names  []string `json:"names"`
}

// gameResolver resolves a check key to a location name for one game. It
// returns false, after logging, for a key the game's tables do not address.
type gameResolver interface {
	resolve(d *daemon, k checkKey) (string, bool)
}

// tableResolver resolves Spyro 2 and 3 keys from prebuilt per-game maps. Its
// name field prefixes the unknown-key log messages.
type tableResolver struct {
	name string
	locs map[checkKey]string
	sps  map[int]string
}

// spyro1Resolver resolves Spyro 1 keys from the S1 tables. Any kind without a
// table is treated as a region-prefixed dragon location.
type spyro1Resolver struct{}

// resolverFor returns the resolver for the session's game. Game 0, whether a
// Spyro 1 session or the idle daemon, resolves Spyro 1-style.
func resolverFor(game int) gameResolver {
	switch game {
	case 1:
		return &tableResolver{"Spyro 2", spyro2Locations, spyro2SkillPoints}
	case 2:
		return &tableResolver{"Spyro 3", spyro3Locations, spyro3SkillPoints}
	}
	return spyro1Resolver{}
}

// resolve returns the location name for a key, sending skill points through
// the numeric enum table and every other kind through the per-game check map.
// It logs and returns false for a key that is absent.
func (res *tableResolver) resolve(d *daemon, k checkKey) (string, bool) {
	if k.kind == KindSkillPoint {
		return res.resolveSkillPoint(d, k)
	}
	resolved, ok := res.locs[k]
	if !ok {
		d.logf("unknown %s %s location: %s: %s (skipped)", res.name, k.kind, k.region, k.name)
		return "", false
	}
	return resolved, true
}

// resolveSkillPoint resolves a skill-point key through the enum table.
func (res *tableResolver) resolveSkillPoint(d *daemon, k checkKey) (string, bool) {
	n, err := strconv.Atoi(k.name)
	if err != nil {
		d.logf("unknown %s skill point location: %s (skipped)", res.name, k.name)
		return "", false
	}
	resolved, ok := res.sps[n]
	if !ok {
		d.logf("unknown %s skill point location: %d (skipped)", res.name, n)
		return "", false
	}
	return resolved, true
}

// resolve returns the location name for a Spyro 1 key, dispatching eggs, gems,
// skill points and completion events to their tables. Every other kind is a
// dragon, named from its region. It logs and returns false for a key that is
// absent.
func (spyro1Resolver) resolve(d *daemon, k checkKey) (string, bool) {
	switch k.kind { //nolint:exhaustive // eggs, gems, skill points and completion events only; the default is a dragon
	case KindEgg:
		return s1EggLocation(d, k)
	case KindGem:
		resolved, ok := d.gemLocation(k)
		if !ok {
			d.logf("unknown gem location: %s: %s (skipped)", k.region, k.name)
			return "", false
		}
		return resolved, true
	case KindSkillPoint:
		return s1SkillPointLocation(d, k)
	case KindEvent:
		resolved, ok := spyro1Events[k.region]
		if !ok {
			d.logf("unknown event location: %s (skipped)", k.region)
			return "", false
		}
		return resolved, true
	}
	return locationPrefix + k.region + ": Free " + k.name, true
}

// s1EggLocation resolves a Spyro 1 egg key through its region's ordinal
// catalog.
func s1EggLocation(d *daemon, k checkKey) (string, bool) {
	if n, err := strconv.Atoi(k.name); err == nil {
		if resolved, ok := d.eggLocation(Egg{Region: k.region, Ordinal: n}); ok {
			return resolved, true
		}
	}
	d.logf("unknown egg location: %s #%s (skipped)", k.region, k.name)
	return "", false
}

// s1SkillPointLocation resolves a Spyro 1 skill-point key through its enum
// table.
func s1SkillPointLocation(d *daemon, k checkKey) (string, bool) {
	if n, err := strconv.Atoi(k.name); err == nil {
		if resolved, ok := spyro1SkillPoints[n]; ok {
			return resolved, true
		}
	}
	d.logf("unknown skill point location: %s (skipped)", k.name)
	return "", false
}

// game returns the session's game index, or 0 when no session is open. Both a
// Spyro 1 session and the idle daemon report 0 and use the Spyro 1 resolver.
func (d *daemon) game() int {
	if d.session == nil {
		return 0
	}
	return d.session.game
}

// sendDrop resolves keys, together with any pending ones left by a failed
// write, and writes them as a single checks.json drop. A key that does not
// resolve is logged and discarded; if the write itself fails, the resolved
// keys are kept in d.pending so the next poll retries them. resetScan clears
// that field.
func (d *daemon) sendDrop(keys []checkKey) {
	d.dropTried = true
	if len(d.pending) > 0 {
		merged := append([]checkKey(nil), d.pending...)
		seen := map[checkKey]bool{}
		for _, k := range merged {
			seen[k] = true
		}
		for _, k := range keys {
			if !seen[k] {
				merged = append(merged, k)
			}
		}
		keys = merged
		d.pending = nil
	}
	res := resolverFor(d.game())
	var sent []checkKey
	var ids []int
	var names []string
	for _, k := range keys {
		locName, ok := res.resolve(d, k)
		if !ok {
			continue
		}
		id, ok := d.nameToID[locName]
		if !ok {
			d.logf("unknown location: %s (skipped)", locName)
			continue
		}
		sent = append(sent, k)
		ids = append(ids, id)
		names = append(names, locName)
	}
	if len(ids) == 0 {
		return
	}
	if err := d.writeDrop(ids, names); err != nil {
		d.logf("drop error: %v", err)
		d.pending = sent
		d.logf("drop failed: %d checks pending retry", len(sent))
	}
}

// writeDrop writes a drop payload atomically, via a temporary file followed by
// a rename, and records it in the daemon's counters.
func (d *daemon) writeDrop(ids []int, names []string) error {
	seq := d.lastSeq + 1
	b, err := json.Marshal(dropPayload{Seq: seq, Checks: ids, Names: names})
	if err != nil {
		return fmt.Errorf("marshal: %w", err)
	}
	tmp := filepath.Join(d.dropDir, dropName+".tmp")
	if err := os.WriteFile(tmp, b, 0644); err != nil {
		return fmt.Errorf("write %s: %w", tmp, err)
	}
	if err := os.Rename(tmp, filepath.Join(d.dropDir, dropName)); err != nil {
		return fmt.Errorf("rename: %w", err)
	}
	d.lastSeq = seq
	d.drops++
	d.checksSent += len(ids)
	d.logf("drop seq=%d checks=%v names=%v", seq, ids, names)
	return nil
}
