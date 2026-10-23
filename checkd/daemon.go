// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-12

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

type daemon struct {
	saveDir      string
	session      *session // the save the player picked in-game; nil = idle
	dropDir      string
	poll         time.Duration
	backfill     bool
	sparxEnabled bool   // slot option games.spyro3.options.sparx_powers (SetSparx)
	rawSave      []byte // the newest save's bytes, for the file-global Sparx map
	nameToID     map[string]int
	eggCatalog   map[string][]string
	levelGems    map[string]int
	known        map[checkKey]bool
	gemKnown     map[string]int
	spKnown      map[int]bool
	sparxKnown   map[string]bool
	lastPath     string
	lastMtime    int64
	layoutErrs   int    // consecutive polls whose save entry could not be read
	noticeText   string // current player notice ("" = none)
	baselineOn   bool
	warnedNoSave bool // the missing-save WARN has fired for this session
	lastSeq      int
	pending      []checkKey // resolved keys whose drop write failed; retried next poll
	dropTried    bool       // this poll already called sendDrop (which retries pending)
	drops        int
	checksSent   int
	logf         func(string, ...any)
}

// newDaemon builds a daemon over the embedded location tables with every
// per-session map made by resetScan. The Sparx scan boots armed: the daemon
// is option-blind (no slot data), the mod-side drop filter already drops
// option-disabled ids, and a slot-data feed can disarm it with SetSparx
// (TestDaemonSparxOptionGate). Callers set the directories, poll interval and
// backfill.
func newDaemon(nameToID map[string]int, eggCatalog map[string][]string, levelGems map[string]int, logf func(string, ...any)) *daemon {
	d := &daemon{
		sparxEnabled: true,
		nameToID:     nameToID,
		eggCatalog:   eggCatalog,
		levelGems:    levelGems,
		logf:         logf,
	}
	d.resetScan()
	return d
}

func (d *daemon) eggKey(e Egg) checkKey {
	return checkKey{KindEgg, e.Region, strconv.Itoa(e.Ordinal)}
}

// ingestNamed ingests one named record's state (dragons, orbs, talismans,
// bosses, abilities, Spyro 3 eggs): a collected record not yet known becomes
// fresh; an uncollected one seeds known=false so the baseline log counts it.
// Returns the key when it is fresh.
func (d *daemon) ingestNamed(kind Kind, r Dragon) (checkKey, bool) {
	k := checkKey{kind, r.Region, r.Name}
	if r.Collected {
		if !d.known[k] {
			d.known[k] = true
			return k, true
		}
		return k, false
	}
	if _, ok := d.known[k]; !ok {
		d.known[k] = false
	}
	return k, false
}

func (d *daemon) gemKey(region, label string) checkKey {
	return checkKey{KindGem, region, label}
}

// gemLocation resolves a gem threshold key to "<prefix><Region>: <label>". Fails
// for thresholds the apworld does not address (boss levels only carry "All Gems").
func (d *daemon) gemLocation(k checkKey) (string, bool) {
	locName := locationPrefix + k.region + ": " + k.name
	if _, ok := d.nameToID[locName]; !ok {
		return "", false
	}
	return locName, true
}

// gemEvents diffs a scanned gem total against the last known one and returns
// every threshold it crossed: threshold = total*pct//100, crossed when
// prev < threshold <= cur. A drop
// (cur < prev) updates the known value and fires nothing — re-ascending may
// re-fire; the mod-side dedup handles it.
func (d *daemon) gemEvents(region string, prev, cur int) []checkKey {
	total, ok := d.levelGems[region]
	if !ok {
		return nil
	}
	var out []checkKey
	for _, th := range gemThresholds {
		threshold := total * th.pct / 100
		if prev < threshold && threshold <= cur {
			out = append(out, d.gemKey(region, th.label))
		}
	}
	return out
}

func (d *daemon) eggLocation(e Egg) (string, bool) {
	names, ok := d.eggCatalog[e.Region]
	if !ok || e.Ordinal < 1 || e.Ordinal > len(names) {
		return "", false
	}
	return names[e.Ordinal-1], true
}

// resetScan forgets everything learned from the previous session's save, so
// the next scan baselines the newly picked one from scratch.
func (d *daemon) resetScan() {
	d.known = make(map[checkKey]bool)
	d.gemKnown = make(map[string]int)
	d.spKnown = make(map[int]bool)
	d.sparxKnown = make(map[string]bool)
	d.pending = nil
	d.baselineOn = false
	d.warnedNoSave = false
	d.lastPath, d.lastMtime = "", 0
}

func (d *daemon) newestSave() (string, int64, bool) {
	matches, err := filepath.Glob(filepath.Join(d.saveDir, "FalconSave.*.sav"))
	if err != nil || len(matches) == 0 {
		return "", 0, false
	}
	best := ""
	var bestMtime int64
	for _, m := range matches {
		fi, err := os.Stat(m)
		if err != nil {
			continue
		}
		mt := fi.ModTime().UnixNano()
		if best == "" || mt > bestMtime {
			best, bestMtime = m, mt
		}
	}
	if best == "" {
		return "", 0, false
	}
	return best, bestMtime, true
}

func (d *daemon) pollOnce() {
	s, open := readSession(filepath.Join(d.dropDir, sessionName))
	if !open {
		d.closeSession()
		return
	}
	d.openSession(s)
	// a failed drop write left keys pending: retry them this poll even when
	// the save is unchanged, unless the scan below already sent a drop (which
	// carries them)
	d.dropTried = false
	defer func() {
		if len(d.pending) > 0 && !d.dropTried {
			d.sendDrop(nil)
		}
	}()
	d.scanNewest(s)
}

// closeSession goes idle when the player returns to the main menu.
func (d *daemon) closeSession() {
	if d.session == nil {
		return
	}
	d.logf("session closed (back at the main menu): idle until a save is picked")
	d.session = nil
	d.resetScan()
}

// openSession adopts the picked save, resetting the scan when it changes.
func (d *daemon) openSession(s session) {
	if d.session != nil && *d.session == s {
		return
	}
	d.logf("session open: save slot %d, game %d (save entry %d)", s.slot, s.game, entryIndex(s.slot, s.game))
	d.session = &s
	d.resetScan()
}

// scanNewest scans the newest save once it has changed since the last poll.
func (d *daemon) scanNewest(s session) {
	path, mtime, ok := d.newestSave()
	if !ok {
		if !d.warnedNoSave {
			d.warnedNoSave = true
			d.logf("no FalconSave.*.sav found in %s — set --save-dir to the game's save folder", d.saveDir)
		}
		return
	}
	if path == d.lastPath && mtime == d.lastMtime {
		return
	}
	d.lastPath, d.lastMtime = path, mtime
	entry, data, ok := d.readSave(path, s)
	if !ok {
		return
	}
	d.scanGame(s, path, entry, data)
}

// readSave reads the newest save and returns the session's entry from it.
func (d *daemon) readSave(path string, s session) (entry, data []byte, ok bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		d.logf("scan error: read %s: %v", path, err)
		return nil, nil, false
	}
	if len(data) < 4 || string(data[:4]) != "GVAS" {
		d.logf("scan error: %s is not GVAS (mid-write?), skipping", path)
		return nil, nil, false
	}
	// only the picked save counts: another slot's playthrough sends nothing
	idx := entryIndex(s.slot, s.game)
	entry, found := saveEntry(data, idx)
	if !found {
		d.layoutErrs++
		d.logf("scan error: %s has no save entry %d (unexpected layout), skipping", path, idx)
		if d.layoutErrs >= noticeLayoutErrs {
			d.setNotice(noticeSaveScanFailed)
		}
		return nil, nil, false
	}
	d.layoutErrs = 0
	d.setNotice("")
	return entry, data, true
}

// scanGame runs the session game's scan body over the save entry.
func (d *daemon) scanGame(s session, path string, entry, data []byte) {
	switch s.game {
	case 0:
		d.scanSpyro1(path, entry, len(data))
	case 1:
		d.scanSpyro2(path, entry)
	case 2:
		d.rawSave = data
		d.scanSpyro3(path, entry)
	}
}

// namedGroup is one family of named records to ingest under one check kind.
type namedGroup struct {
	kind    Kind
	records []Dragon
}

// ingestGroups ingests each group's records in order and returns the fresh
// keys.
func (d *daemon) ingestGroups(groups []namedGroup) []checkKey {
	var fresh []checkKey
	for _, g := range groups {
		for _, r := range g.records {
			if k, ok := d.ingestNamed(g.kind, r); ok {
				fresh = append(fresh, k)
			}
		}
	}
	return fresh
}

// gemFlips returns the thresholds every scanned region crossed.
func (d *daemon) gemFlips(gems map[string]int) []checkKey {
	var fresh []checkKey
	for region, value := range gems {
		fresh = append(fresh, d.gemFlip(region, value)...)
	}
	return fresh
}

// countCollected counts the collected records.
func countCollected(records []Dragon) int {
	n := 0
	for _, r := range records {
		if r.Collected {
			n++
		}
	}
	return n
}

// gemFlip compares a scanned gem value with the daemon's last known total for
// the region and returns the freshly crossed thresholds as check keys. The
// first sighting (no known value) starts from prev=0, so a progressed save
// backfills every already-crossed threshold at baseline — the same
// ingest-existing-state-as-baseline rule the dragons and eggs follow. A drop
// (cur < prev) updates the known value and fires nothing — re-ascending may
// re-fire; the mod-side dedup handles it.
func (d *daemon) gemFlip(region string, cur int) []checkKey {
	prev := d.gemKnown[region]
	d.gemKnown[region] = cur
	if cur <= prev {
		return nil
	}
	return d.gemEvents(region, prev, cur)
}

// spFlip records the scanned skill-point enum values and returns the freshly
// seen ones as check keys (name = the enum value as string; sendDrop resolves
// it through the session game's enum -> location table). Values outside the
// session game's enum range are ignored. The first sighting ingests existing
// state, so a progressed save backfills its earned points at baseline — the
// same rule the dragons and eggs follow.
func (d *daemon) spFlip(cur []int, game int) []checkKey {
	lo, hi := skillPointRanges[game][0], skillPointRanges[game][1]
	var out []checkKey
	for _, v := range cur {
		if v < lo || v > hi || d.spKnown[v] {
			continue
		}
		d.spKnown[v] = true
		out = append(out, checkKey{KindSkillPoint, "", strconv.Itoa(v)})
	}
	return out
}

// eventFlip marks a Spyro 1 region's completion event known and returns its
// check key when it is fresh. Completion records are only ever written done,
// so there is no known=false seeding and no un-learning; the first sighting
// ingests existing state (baseline backfill), the rule the S1 eggs follow.
func (d *daemon) eventFlip(region string) []checkKey {
	k := checkKey{KindEvent, region, ""}
	if d.known[k] {
		return nil
	}
	d.known[k] = true
	return []checkKey{k}
}

// sparxFlip records the scanned Sparx-power names and returns the freshly
// obtained ones as check keys (name = the enum-name suffix; sendDrop resolves
// it through spyro3SparxPowers). A 0->1 flip drops once; a de-collect (1->0)
// fires nothing and never un-learns, so a re-obtain stays deduped until a
// session reset (the mod-side sent-checks set handles the server-side
// re-fire). The first sighting ingests existing state, so a progressed save
// backfills its obtained powers at baseline, the same rule the dragons and
// eggs follow.
func (d *daemon) sparxFlip(cur []string) []checkKey {
	var out []checkKey
	for _, name := range cur {
		if d.sparxKnown[name] {
			continue
		}
		d.sparxKnown[name] = true
		out = append(out, checkKey{KindSparx, "", name})
	}
	return out
}

// SetSparx arms (on) or disarms (off) the Sparx-power scan: the AP slot's
// games.spyro3.options.sparx_powers flag. The daemon is option-blind today
// (no slot data reaches it), so boot keeps the scan on and the mod-side drop
// filter drops option-disabled ids; when a slot-data feed lands it calls this
// once per slot and scanSpyro3 gates on the flag directly.
func (d *daemon) SetSparx(on bool) {
	d.sparxEnabled = on
}

// finishBaseline is the tail every scan body shares: the first poll logs the
// baseline and returns without dropping unless backfill is on; later polls
// return when nothing is fresh. A non-empty fresh list drops.
func (d *daemon) finishBaseline(fresh []checkKey) {
	if !d.baselineOn {
		d.baselineOn = true
		if !d.backfill {
			return
		}
	} else if len(fresh) == 0 {
		return
	}
	d.sendDrop(fresh)
}

func (d *daemon) summary() {
	d.logf("session summary: drops=%d checks sent=%d", d.drops, d.checksSent)
	fmt.Printf("session summary: drops=%d checks sent=%d\n", d.drops, d.checksSent)
}
