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
	fresh := d.ingestGroups([]namedGroup{
		{KindOrb, orbs}, {KindTalisman, talismans}, {KindBoss, bosses}, {KindAbility, abilities},
	})
	fresh = append(fresh, d.gemFlips(gems)...)
	fresh = append(fresh, d.spFlip(sps, 1)...)
	if !d.baselineOn {
		d.logBaselineS2(orbs, talismans, abilities, bosses, gems, sps)
	}
	d.finishBaseline(fresh)
}

// logBaselineS2 logs what the first Spyro 2 baseline saw.
func (d *daemon) logBaselineS2(orbs, talismans, abilities, bosses []Dragon, gems map[string]int, sps []int) {
	d.logf("baseline: %d orbs, %d talismans, %d abilities (%d collected), %d bosses (%d collected), gems across %d regions, skill points (%d earned)",
		len(orbs), len(talismans), len(abilities), countCollected(abilities),
		len(bosses), countCollected(bosses), len(gems), len(sps))
}
