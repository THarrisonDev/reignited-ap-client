// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-11

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
	var powers []string
	var sparxStats ScanStats
	if d.sparxEnabled {
		powers, sparxStats = ScanSparxPowers(d.rawSave, d.session.slot, d.session.game)
	}
	if len(eggs) == 0 && len(gems) == 0 && len(sps) == 0 && len(powers) == 0 {
		d.logf("scan: 0 eggs, 0 gem regions, 0 skill points, 0 sparx powers in %s (%d/%d/%d/%d markers, %d/%d/%d/%d skipped): transient, skipping",
			path, eggStats.Markers, gemStats.Markers, spStats.Markers, sparxStats.Markers,
			eggStats.Skipped, gemStats.Skipped, spStats.Skipped, sparxStats.Skipped)
		return
	}
	var fresh []checkKey
	for _, e := range eggs {
		if k, ok := d.ingestNamed(KindEgg, e); ok {
			fresh = append(fresh, k)
		}
	}
	for region, value := range gems {
		fresh = append(fresh, d.gemFlip(region, value)...)
	}
	fresh = append(fresh, d.spFlip(sps, 2)...)
	fresh = append(fresh, d.sparxFlip(powers)...)
	if !d.baselineOn {
		eggCollected := 0
		for _, e := range eggs {
			if e.Collected {
				eggCollected++
			}
		}
		d.logf("baseline: %d eggs (%d collected), gems across %d regions, skill points (%d earned), sparx powers (%d obtained) (Spyro 3)",
			len(eggs), eggCollected, len(gems), len(sps), len(powers))
	}
	d.finishBaseline(fresh)
}
