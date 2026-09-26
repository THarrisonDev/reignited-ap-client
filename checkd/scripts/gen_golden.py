#!/usr/bin/env python3
"""Regenerate the checkd test goldens from the synthetic fixtures.

Mirrors the Go scanners' semantics over the pygvas property tree:
  - dragons: (region, name, collected), dedup by (region, name), collected wins
  - eggs: collected-only, (region, ordinal 1-based within region, true) in
    file order
  - gems: region -> sum over gem types of count*value, merged by MAX across
    entries (Spyro 1 paths + Spyro 2 paths)
  - s3 eggs / s3 gems: game-2 entries only
  - abilities: (name, collected), collected wins across entries
  - bosses: (region, name, collected) for the three Spyro 2 boss regions
  - sparx: (slot, game) -> obtained power names, the file-global
    globalFloatMap
  - events: per game-0 entry, the Spyro 1 regions whose completion event the
    records prove: a collected EIT_PortalExit (not in a flight or Gnasty's
    Loot), Gnasty Gnorc's collected EIT_S1Boss, a flight whose collected
    EIT_S1FlightReward params cover 4 distinct target sets other than 20
  - skill points: not golden-covered (the tests pin them directly)

Outputs (checked in; regenerate after gen_fixtures.py):
  - ../testdata/<stem>.{,eggs.,gems.,abilities.,s3eggs.,s3gems.,sparx.,bosses.,events.}golden.json

Run from anywhere:
    python3 <repo>/client/checkd/scripts/gen_golden.py [--check]
"""
import argparse
import json
import os
import sys

import pygvas

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKD = os.path.dirname(HERE)
DEFAULT_TESTDATA = os.path.join(CHECKD, "testdata")

STEMS = ["snapshot1", "snapshot2", "snapshot3", "mid_s1",
         "mixed_s1_s2", "s1_events", "100pct_ref"]

DRAGON = "EIT_Dragon"
EGG = "EIT_Egg"
ORB = "EIT_S2GreenOrb"
TALISMAN = "EIT_Talisman"
S3_EGGS = ("EIT_S3Egg", "EIT_S3BonusEgg")
BOSS = "EIT_S2Boss"
ABILITIES = {"EIT_Swimming": "Swim", "EIT_Climbing": "Climb", "EIT_HeadBash": "Headbash"}

GEM_VALUES = {
    "EIT_RedGem": 1, "EIT_GreenGem": 2, "EIT_BlueGem": 5,
    "EIT_YellowGem": 10, "EIT_PurpleGem": 25,
    "EIT_S2RedGem": 1, "EIT_S2GreenGem": 2, "EIT_S2PurpleGem": 5,
    "EIT_S2YellowGem": 10, "EIT_S2MagentaGem": 25,
    "EIT_S3RedGem": 1, "EIT_S3GreenGem": 2, "EIT_S3BlueGem": 5,
    "EIT_S3GoldGem": 10, "EIT_S3PurpleGem": 25,
}

PORTAL_EXIT = "EIT_PortalExit"
S1_BOSS = "EIT_S1Boss"
FLIGHT_REWARD = "EIT_S1FlightReward"
FLIGHT_ALL_IN_ONE = 20
FLIGHT_SETS = 4
S1_FLIGHTS = {"Sunny Flight", "Night Flight", "Crystal Flight", "Wild Flight", "Icy Flight"}
S1_GNASTY = "Gnasty Gnorc"
S1_LOOT = "Gnasty's Loot"

S2_BOSSES = {"Crush's Dungeon": "Crush Defeated",
             "Gulp's Overlook": "Gulp Defeated",
             "Ripto's Arena": "Ripto Defeated"}


def load_regions():
    with open(os.path.join(CHECKD, "locations.json")) as f:
        doc = json.load(f)["games"]
    out = {}
    for game in ("spyro1", "spyro2", "spyro3"):
        out[game] = {r["levelPath"]: name for name, r in doc[game]["regions"].items()
                     if r["levelPath"]}
    return out


def prop_value(prop, name, default=None):
    if isinstance(prop, dict):
        return prop.get(name, default)
    return getattr(prop, name, default)


def struct_fields(prop):
    value = prop.value if hasattr(prop, "value") else prop
    return value if isinstance(value, dict) else {}


def map_values(prop):
    return prop.values if hasattr(prop, "values") else []


def entry_levels(entry):
    """yield (level_key, {obj_name: [items]}, {gem_tag: count})"""
    body = struct_fields(entry)
    lom = body.get("levelObjectMap")
    for key, val in map_values(lom):
        fields = struct_fields(val)
        objects = {}
        for obj_key, obj_val in map_values(fields.get("objectDataMap")):
            items = []
            for item in (obj_val.value["saveDataList"].values
                         if "saveDataList" in struct_fields(obj_val) else []):
                items.append(item)
            objects[obj_key.value] = items
        counts = {}
        for g_key, g_val in map_values(fields.get("gemCollectionMap")):
            tag = g_key.value.split("::")[-1]
            stash = struct_fields(g_val).get("GemHashArray")
            if stash is not None:
                counts[tag] = len(stash.values)
        yield key.value, objects, counts


def item_type(item):
    data = struct_fields(item).get("itemData")
    if data is None:
        return None
    return data.value["ItemType"].value.split("::")[-1]


def item_collected(item):
    data = struct_fields(item).get("itemData")
    return bool(data.value["collected"].value)


def item_params(item):
    body = struct_fields(item).get("itemParamList")
    sps = body.value.get("saveParams")
    return [(s.value["paramName"].value, s.value["paramValue"].value) for s in sps.values]


def scan_dragons(entries, path_to_region):
    out = {}
    for entry in entries:
        for level, objects, _ in entry_levels(entry):
            region = path_to_region.get(level, "")
            for items in objects.values():
                for it in items:
                    if item_type(it) != DRAGON or not region:
                        continue
                    params = item_params(it)
                    name = params[0][0] if params else None
                    if not name:
                        continue
                    key = (region, name)
                    if key in out:
                        out[key] = out[key] or item_collected(it)
                    else:
                        out[key] = item_collected(it)
    return out


def scan_eggs(entries, path_to_region):
    out = []
    counts = {}
    for entry in entries:
        for level, objects, _ in entry_levels(entry):
            region = path_to_region.get(level, "")
            for items in objects.values():
                for it in items:
                    if item_type(it) != EGG or not region or not item_collected(it):
                        continue
                    counts[region] = counts.get(region, 0) + 1
                    out.append((region, counts[region], True))
    return out


def scan_named(entries, path_to_region, types):
    out = {}
    for entry in entries:
        for level, objects, _ in entry_levels(entry):
            region = path_to_region.get(level, "")
            for items in objects.values():
                for it in items:
                    if item_type(it) not in types or not region:
                        continue
                    params = item_params(it)
                    name = params[0][0] if params else None
                    if not name:
                        continue
                    key = (region, name)
                    if key in out:
                        out[key] = out[key] or item_collected(it)
                    else:
                        out[key] = item_collected(it)
    return out


def scan_gems(entries, path_to_region):
    per = {}
    for entry in entries:
        for level, _, counts in entry_levels(entry):
            region = path_to_region.get(level, "")
            if not region:
                continue
            for tag, count in counts.items():
                if tag not in GEM_VALUES:
                    continue
                key = (region, tag)
                per[key] = max(per.get(key, 0), count)
    out = {}
    for (region, tag), count in per.items():
        out[region] = out.get(region, 0) + count * GEM_VALUES[tag]
    return out


def scan_abilities(entries):
    out = {}
    for entry in entries:
        for _, objects, _ in entry_levels(entry):
            for items in objects.values():
                for it in items:
                    tag = item_type(it)
                    if tag not in ABILITIES:
                        continue
                    name = ABILITIES[tag]
                    out[name] = out.get(name, False) or item_collected(it)
    return out


def scan_bosses(entries, path_to_region):
    out = {}
    for entry in entries:
        for level, objects, _ in entry_levels(entry):
            region = path_to_region.get(level, "")
            name = S2_BOSSES.get(region, "")
            if not name:
                continue
            for items in objects.values():
                for it in items:
                    if item_type(it) != BOSS:
                        continue
                    out[(region, name)] = out.get((region, name), False) or item_collected(it)
    return out


def scan_events(entry, path_to_region):
    """Sorted Spyro 1 regions whose completion event one entry proves."""
    fired = set()
    flights = {}
    for level, objects, _ in entry_levels(entry):
        region = path_to_region.get(level, "")
        if not region:
            continue
        for items in objects.values():
            for it in items:
                tag = item_type(it)
                if tag not in (PORTAL_EXIT, S1_BOSS, FLIGHT_REWARD) or not item_collected(it):
                    continue
                if tag == PORTAL_EXIT and region not in S1_FLIGHTS and region != S1_LOOT:
                    fired.add(region)
                elif tag == S1_BOSS and region == S1_GNASTY:
                    fired.add(region)
                elif tag == FLIGHT_REWARD:
                    flights.setdefault(region, set()).update(
                        int(v) for _, v in item_params(it))
    for region, sets in flights.items():
        if region in S1_FLIGHTS and len(sets - {FLIGHT_ALL_IN_ONE}) >= FLIGHT_SETS:
            fired.add(region)
    return sorted(fired)


def scan_sparx(gvas, entries):
    """[(slot, game, [names sorted])] for every (slot, game) with a power != 0."""
    powers = {}
    for key, val in map_values(gvas.properties["globalFloatMap"]):
        k = key.value
        if not k.startswith("collected.") or ".EIT_SparxPower_" not in k:
            continue
        parts = k.split(".")
        slot, game = int(parts[1]), int(parts[2])
        name = parts[3].split("EIT_SparxPower_")[-1]
        if val.value != 0:
            powers.setdefault((slot, game), set()).add(name)
    return [[slot, game, sorted(names)] for (slot, game), names in sorted(powers.items())]


def write_golden(testdata, stem, suffix, doc):
    path = os.path.join(testdata, stem + suffix + "golden.json")
    with open(path, "w") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    return path


def build_goldens(gvas, regions):
    entries = gvas.properties["saveDataMapArray"].values
    s1, s2, s3 = regions["spyro1"], regions["spyro2"], regions["spyro3"]
    game2 = [entries[6 + slot] for slot in range(3)]
    docs = {
        ".": {"dragons": [[r, n, c] for (r, n), c in sorted(scan_dragons(entries, s1).items())]},
        ".eggs.": {"eggs": [list(e) for e in scan_eggs(entries, s1)]},
        ".gems.": None,
        ".abilities.": {"abilities": sorted(scan_abilities(entries).items())},
        ".s3eggs.": {"eggs": [[r, n, c] for (r, n), c in sorted(scan_named(game2, s3, S3_EGGS).items())]},
        ".s3gems.": {"gems": sorted(scan_gems(game2, s3).items())},
        ".sparx.": {"powers": scan_sparx(gvas, entries)},
        ".bosses.": {"bosses": [[r, n, c] for (r, n), c in sorted(scan_bosses(entries, s2).items())]},
        ".events.": {"events": [[slot, regs] for slot, regs in
                                ((slot, scan_events(entries[slot], s1)) for slot in range(3))
                                if regs]},
    }
    gems = scan_gems(entries, s1)
    for region, value in scan_gems(entries, s2).items():
        gems[region] = max(gems.get(region, 0), value)
    docs[".gems."] = {"gems": sorted(gems.items())}
    return docs


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--testdata", default=DEFAULT_TESTDATA)
    ap.add_argument("--check", action="store_true",
                    help="verify the checked-in goldens match a fresh scan")
    args = ap.parse_args()

    regions = load_regions()
    failed = False
    for stem in STEMS:
        sav = os.path.join(args.testdata, stem + ".sav")
        gvas = pygvas.GVASFile.deserialize_gvas_file(sav)
        docs = build_goldens(gvas, regions)
        for suffix, doc in docs.items():
            path = os.path.join(args.testdata, stem + suffix + "golden.json")
            fresh = json.dumps(doc, indent=2) + "\n"
            if args.check:
                try:
                    with open(path) as f:
                        current = f.read()
                except FileNotFoundError:
                    print("MISSING %s" % path)
                    failed = True
                    continue
                if current != fresh:
                    print("DRIFT %s" % path)
                    failed = True
            else:
                with open(path, "w") as f:
                    f.write(fresh)
        print("%s %s goldens" % ("checked" if args.check else "wrote", stem))
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()