package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
)

type dropPayload struct {
	Seq    int      `json:"seq"`
	Checks []int    `json:"checks"`
	Names  []string `json:"names"`
}

// gameResolver resolves check keys to location names for one game, logging
// and failing ("") for keys its tables do not address.
type gameResolver interface {
	resolve(d *daemon, k checkKey) (string, bool)
}

// tableResolver resolves check keys for a table-driven game (Spyro 2 and 3):
// every kind goes through the game's checkKey map, skill points through its
// enum table. The name prefixes the unknown-key logs.
type tableResolver struct {
	name string
	locs map[checkKey]string
	sps  map[int]string
}

// spyro1Resolver resolves Spyro 1 keys: eggs by per-level ordinal through
// eggCatalog, gems through nameToID, skill points through the enum table,
// completion events by region through spyro1Events, and dragons (every other kind) as "<prefix><Region>: Free <Name>".
type spyro1Resolver struct{}

// resolverFor returns the session game's resolver; game 0 (a Spyro 1 session
// or the idle daemon) resolves S1-style.
func resolverFor(game int) gameResolver {
	switch game {
	case 1:
		return &tableResolver{"Spyro 2", spyro2Locations, spyro2SkillPoints}
	case 2:
		return &tableResolver{"Spyro 3", spyro3Locations, spyro3SkillPoints}
	}
	return spyro1Resolver{}
}

func (res *tableResolver) resolve(d *daemon, k checkKey) (string, bool) {
	if k.kind == KindSkillPoint {
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
	resolved, ok := res.locs[k]
	if !ok {
		d.logf("unknown %s %s location: %s: %s (skipped)", res.name, k.kind, k.region, k.name)
		return "", false
	}
	return resolved, true
}

func (spyro1Resolver) resolve(d *daemon, k checkKey) (string, bool) {
	switch k.kind {
	case KindEgg:
		if n, err := strconv.Atoi(k.name); err == nil {
			if resolved, ok := d.eggLocation(Egg{Region: k.region, Ordinal: n}); ok {
				return resolved, true
			}
		}
		d.logf("unknown egg location: %s #%s (skipped)", k.region, k.name)
		return "", false
	case KindGem:
		resolved, ok := d.gemLocation(k)
		if !ok {
			d.logf("unknown gem location: %s: %s (skipped)", k.region, k.name)
			return "", false
		}
		return resolved, true
	case KindSkillPoint:
		if n, err := strconv.Atoi(k.name); err == nil {
			if resolved, ok := spyro1SkillPoints[n]; ok {
				return resolved, true
			}
		}
		d.logf("unknown skill point location: %s (skipped)", k.name)
		return "", false
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

// game is the session's game index, 0 when no session is open (the S1
// resolver covers both: S1 sessions and the idle daemon).
func (d *daemon) game() int {
	if d.session == nil {
		return 0
	}
	return d.session.game
}

// sendDrop resolves keys (after any pending ones a failed write left behind)
// and writes them as one checks.json drop. Keys that do not resolve are
// logged and dropped for good; if the write fails, the resolved keys go back
// to d.pending so the next poll retries them (resetScan clears it).
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

// writeDrop writes one drop payload atomically (tmp file + rename) and counts
// it.
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
