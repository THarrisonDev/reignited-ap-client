// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-11

package main

// scanSpyro1 is the Spyro 1 poll body: dragon, egg, gem-total, skill-point and
// level-completion records from the session's save entry drop as "dragon"/
// "egg"/"gem"/"skillpoint"/"event" checks with the same baseline/backfill and
// dedup flow the Spyro 2/3 scans follow; gem totals fire thresholds through
// the same gemFlip rule. sendDrop resolves dragons as "<prefix><Region>: Free
// <Name>", eggs through eggCatalog, gems through nameToID, skill points via
// the enum table and events via spyro1Events. saveLen is the whole save's
// byte length for the transient-skip log. S1 eggs and completion events never
// seed known=false (only done ones have save records), so they bypass
// ingestNamed. Gnasty's Loot has no completion record: its event fires with
// the Loot's "All Gems" gem threshold.
func (d *daemon) scanSpyro1(path string, entry []byte, saveLen int) {
	dragons, stats := ScanSave(entry)
	eggs, eggStats := ScanEggs(entry)
	gems, gemStats := ScanGems(entry)
	sps, spStats := ScanSkillPoints(entry)
	events, evStats := ScanS1Events(entry)
	if len(dragons) == 0 && len(eggs) == 0 && len(gems) == 0 && len(sps) == 0 && len(events) == 0 {
		d.logf("scan: 0 dragons, 0 eggs, 0 gem regions, 0 skill points, 0 completions in %s (%d bytes, %d/%d/%d/%d/%d markers, %d/%d/%d/%d/%d skipped): transient, skipping",
			path, saveLen, stats.Markers, eggStats.Markers, gemStats.Markers, spStats.Markers, evStats.Markers,
			stats.Skipped, eggStats.Skipped, gemStats.Skipped, spStats.Skipped, evStats.Skipped)
		return
	}
	fresh := d.s1Fresh(dragons, eggs, gems, sps, events)
	if !d.baselineOn {
		d.logBaselineS1(dragons, eggs, gems, sps)
	}
	d.finishBaseline(fresh)
}

// s1Fresh marks the scanned Spyro 1 records known and returns the checks the
// slot has not sent or baselined yet.
func (d *daemon) s1Fresh(dragons []Dragon, eggs []Egg, gems map[string]int, sps []int, events []string) []checkKey {
	var fresh []checkKey
	for _, dr := range dragons {
		if k, ok := d.ingestNamed(KindDragon, dr); ok {
			fresh = append(fresh, k)
		}
	}
	for _, e := range eggs {
		k := d.eggKey(e)
		if e.Collected && !d.known[k] {
			d.known[k] = true
			fresh = append(fresh, k)
		}
	}
	fresh = append(fresh, d.s1GemFlips(gems)...)
	fresh = append(fresh, d.spFlip(sps, 0)...)
	for _, region := range events {
		fresh = append(fresh, d.eventFlip(region)...)
	}
	return fresh
}

// s1GemFlips fires the gem thresholds each region crossed. Gnasty's Loot has no
// completion record: its event fires with the Loot's All Gems threshold.
func (d *daemon) s1GemFlips(gems map[string]int) []checkKey {
	var fresh []checkKey
	allGems := gemLabel(100)
	for region, value := range gems {
		crossed := d.gemFlip(region, value)
		fresh = append(fresh, crossed...)
		if region != spyro1LootRegion {
			continue
		}
		for _, k := range crossed {
			if k.name == allGems {
				fresh = append(fresh, d.eventFlip(region)...)
			}
		}
	}
	return fresh
}

// logBaselineS1 logs what the first Spyro 1 baseline saw.
func (d *daemon) logBaselineS1(dragons []Dragon, eggs []Egg, gems map[string]int, sps []int) {
	dCollected, eCollected, completions := 0, 0, 0
	for k, v := range d.known {
		if !v {
			continue
		}
		switch k.kind { //nolint:exhaustive // only the kinds the baseline counts
		case KindEgg:
			eCollected++
		case KindDragon:
			dCollected++
		case KindEvent:
			completions++
		}
	}
	d.logf("baseline: %d dragons (%d collected), %d eggs (%d collected), gems across %d regions, skill points (%d earned), %d completions",
		len(dragons), dCollected, len(eggs), eCollected, len(gems), len(sps), completions)
}
