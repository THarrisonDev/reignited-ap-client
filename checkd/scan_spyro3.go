// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-23

package main

// scanSpyro3 is the Spyro 3 poll body: named egg records (the dragon name in
// the record's param, "Al" included) drop as "egg" checks, skill points as
// "skillpoint" checks, obtained Sparx powers as "sparx" checks, and gem totals
// fire thresholds through the same gemFlip rule as Spyro 1 and 2. sendDrop
// resolves every key via spyro3Locations (skill points via the enum table).
// The Sparx scan runs only when armed (sparxEnabled, default on at the
// option-blind boot — the mod-side drop filter already drops option-disabled
// ids; SetSparx wires a future slot-data feed): a disarmed scan leaves the
// Sparx keys entirely out of known/drops. The map lives file-global (outside
// every save entry), so the scan reads the whole save (rawSave) with the
// session's (slot, game).
func (d *daemon) scanSpyro3(path string, entry []byte) {
	eggs, eggStats := ScanS3Eggs(entry)
	gems, gemStats := ScanSpyro3Gems(entry)
	sps, spStats := ScanSkillPoints(entry)
	powers, sparxStats := d.scanSparx()
	if len(eggs) == 0 && len(gems) == 0 && len(sps) == 0 && len(powers) == 0 {
		d.logf("scan: 0 eggs, 0 gem regions, 0 skill points, 0 sparx powers in %s (%d/%d/%d/%d markers, %d/%d/%d/%d skipped): transient, skipping",
			path, eggStats.Markers, gemStats.Markers, spStats.Markers, sparxStats.Markers,
			eggStats.Skipped, gemStats.Skipped, spStats.Skipped, sparxStats.Skipped)
		return
	}
	fresh := d.ingestGroups([]namedGroup{{KindEgg, eggs}})
	fresh = append(fresh, d.gemFlips(gems)...)
	fresh = append(fresh, d.spFlip(sps, 2)...)
	fresh = append(fresh, d.sparxFlip(powers)...)
	if !d.baselineOn {
		d.logBaselineS3(eggs, gems, sps, powers)
	}
	d.finishBaseline(fresh)
}

// scanSparx reads the obtained Sparx powers of the session's (slot, game) when
// the scan is armed.
func (d *daemon) scanSparx() ([]string, ScanStats) {
	if !d.sparxEnabled {
		return nil, ScanStats{}
	}
	return ScanSparxPowers(d.rawSave, d.session.slot, d.session.game)
}

// logBaselineS3 logs what the first Spyro 3 baseline saw.
func (d *daemon) logBaselineS3(eggs []Dragon, gems map[string]int, sps []int, powers []string) {
	d.logf("baseline: %d eggs (%d collected), gems across %d regions, skill points (%d earned), sparx powers (%d obtained) (Spyro 3)",
		len(eggs), countCollected(eggs), len(gems), len(sps), len(powers))
}
