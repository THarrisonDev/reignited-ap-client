// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-11

package main

// scanSpyro2 is the Spyro 2 poll body: orb, talisman, Money Bags ability,
// boss-kill and skill-point records from the session's save entry drop as
// "orb"/"talisman"/"ability"/"boss"/"skillpoint" checks with the same
// baseline/backfill and dedup as dragons (ingestNamed); gem totals fire
// thresholds through the same gemFlip rule as Spyro 1. sendDrop resolves
// every key via spyro2Locations (skill points via the enum table).
func (d *daemon) scanSpyro2(path string, entry []byte) {
	orbs, orbStats := ScanOrbs(entry)
	talismans, talStats := ScanTalismans(entry)
	abilities, abilityStats := ScanAbilities(entry)
	bosses, bossStats := ScanS2Bosses(entry)
	gems, gemStats := ScanSpyro2Gems(entry)
	sps, spStats := ScanSkillPoints(entry)
	if len(orbs) == 0 && len(talismans) == 0 && len(abilities) == 0 && len(bosses) == 0 && len(gems) == 0 && len(sps) == 0 {
		d.logf("scan: 0 orbs, 0 talismans, 0 abilities, 0 bosses, 0 gem regions, 0 skill points in %s (%d/%d/%d/%d/%d/%d markers, %d/%d/%d/%d/%d/%d skipped): transient, skipping",
			path, orbStats.Markers, talStats.Markers, abilityStats.Markers, bossStats.Markers, gemStats.Markers, spStats.Markers,
			orbStats.Skipped, talStats.Skipped, abilityStats.Skipped, bossStats.Skipped, gemStats.Skipped, spStats.Skipped)
		return
	}
	var fresh []checkKey
	for _, named := range []struct {
		kind    Kind
		records []Dragon
	}{{KindOrb, orbs}, {KindTalisman, talismans}, {KindBoss, bosses}, {KindAbility, abilities}} {
		for _, r := range named.records {
			if k, ok := d.ingestNamed(named.kind, r); ok {
				fresh = append(fresh, k)
			}
		}
	}
	for region, value := range gems {
		fresh = append(fresh, d.gemFlip(region, value)...)
	}
	fresh = append(fresh, d.spFlip(sps, 1)...)
	if !d.baselineOn {
		collected := 0
		for _, a := range abilities {
			if a.Collected {
				collected++
			}
		}
		bossCollected := 0
		for _, b := range bosses {
			if b.Collected {
				bossCollected++
			}
		}
		d.logf("baseline: %d orbs, %d talismans, %d abilities (%d collected), %d bosses (%d collected), gems across %d regions, skill points (%d earned)",
			len(orbs), len(talismans), len(abilities), collected, len(bosses), bossCollected, len(gems), len(sps))
	}
	d.finishBaseline(fresh)
}
