#!/usr/bin/env python3
# Author: Tim Harrison
# Created: 2026-09-26
# Updated: 2026-10-23

"""Generate the comprehensive location data the client tools consume.

Single source of truth: the repo's JSON data files.
  - <repo>/world/data/spyro{1,2,3}.json -> every check's name, kind and
    region (the same data the apworld ships); every location ID is derived by
    the world's data engine, <repo>/world/data/__init__.py, which this script
    loads standalone (it is stdlib-only), so the client and the apworld can
    never disagree on an ID
  - <repo>/world/data/client.json        -> map path -> region per game, and
    the SkillPointsTable enum -> task rows

Outputs (checked in; regenerate after editing any source):
  - ../locations.json -> the comprehensive, self-documenting pool
        {game, gemThresholds[[pct, label]...], games{
           spyro1: {baseId, locationPrefix, skillPointRange[lo, hi], regions{<region>: {levelPath, gemTotal, checks[], events[]}}},
           spyro2: {baseId, locationPrefix, skillPointRange[lo, hi], regions{<region>: {levelPath, gemTotal, checks[]}}},
           spyro3: {baseId, locationPrefix, skillPointRange[lo, hi], regions{<region>: {levelPath, gemTotal, checks[]}}}}}
    gemThresholds is spyro1.json's shared gem-threshold table (percentage ->
    location label, all three games); skillPointRange is the min/max
    ESkillPoint enum of the game's client.json skillPoints rows.
    Spyro 1 checks: {type: dragon|egg|gem|skillpoint, ..., location, id};
    events separately as {location, id}. Spyro 2/3 list only the levels
    that have checks (gemTotal 0 = no gems). checkd embeds this and derives its lookups from "regions".
  - ../../ue4ss_mod/srt_bridge/Scripts/regions.lua -> path->region for all
    three games, required by the mod.
  - ../../ue4ss_mod/srt_bridge/Scripts/constants.lua -> the EIT type ids the
    mod's save readback/writes use (world/data/client.json), the per-game
    homeworld sets and the collectible totals (world level data). Also required
    by the mod.

No AP machinery needed — the JSON and the data engine are standalone. Run
from anywhere:
    python3 <repo>/client/checkd/scripts/gen_locations.py
"""
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKD = os.path.dirname(HERE)
CLIENT = os.path.dirname(CHECKD)
REPO = os.path.dirname(CLIENT)
DATA = os.path.join(REPO, "world", "data")
OUT = os.path.join(CHECKD, "locations.json")
OUT_LUA = os.path.join(
    CLIENT, "ue4ss_mod", "srt_bridge", "Scripts", "regions.lua")
OUT_LUA_CONST = os.path.join(
    CLIENT, "ue4ss_mod", "srt_bridge", "Scripts", "constants.lua")

GAME = "Spyro Reignited Trilogy"
GAMES = ("spyro1", "spyro2", "spyro3")


def load(name: str) -> dict:
    with open(os.path.join(DATA, name)) as f:
        return json.load(f)


def load_engine():
    """world/data/__init__.py as a standalone module (not as part of the world
    package, whose __init__ needs Archipelago)."""
    spec = importlib.util.spec_from_file_location(
        "srt_world_data", os.path.join(DATA, "__init__.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ENGINE = load_engine()


def skill_point_range(game: str, client: dict) -> list:
    enums = [int(k) for k in client["skillPoints"][game]]
    if not enums:
        sys.exit(f"ERROR: {game} has no skillPoints rows in client.json")
    return [min(enums), max(enums)]


def build_spyro1(engine_data, client: dict) -> dict:
    """Regions/checks/events from spyro1.json. The JSON lists only the unique
    checks (dragons, eggs, skill points); the gem-threshold and event checks
    come from the data engine's derivation, the same the apworld uses."""
    data = engine_data.raw
    regions = {}
    path_of_region = client["levelPaths"]["spyro1"]
    path_of_region = {r: p for p, r in path_of_region.items()}
    sp_rows = client["skillPoints"]["spyro1"]
    sp_regions = client["skillPointLevelToRegion"]["spyro1"]
    prefix = "Spyro 1: "

    def full(name: str) -> str:
        return name if name.startswith(prefix) else prefix + name

    def sp_enum(level_display: str, task: str):
        for k, v in sp_rows.items():
            if v["task"] == task and sp_regions.get(v["level"]) == level_display:
                return k
        return None

    for level in data["levels"]:
        region = level["name"]
        if region not in path_of_region:
            sys.exit(f"ERROR: spyro1 level {region!r} has no levelPath")
        entry = {"levelPath": path_of_region[region],
                 "gemTotal": int(level["gemTotal"]),
                 "checks": [], "events": []}
        egg_ord = 0
        for c in level["checks"]:
            kind = ENGINE.CheckType(c["type"]).name.lower()
            loc_id = c["id"]
            plain = c["name"].split(": ", 1)[1]
            if kind == "dragon":
                entry["checks"].append({"type": kind,
                                        "name": plain.removeprefix("Free "),
                                        "location": full(c["name"]), "id": loc_id})
            elif kind == "egg":
                egg_ord += 1
                entry["checks"].append({"type": kind, "ordinal": egg_ord,
                                        "location": full(c["name"]), "id": loc_id})
            elif kind == "skill_point":
                task = plain.removesuffix(" (Skill Point)")
                enum = sp_enum(region, task)
                if enum is None:
                    sys.exit(f"ERROR: spyro1 skill-point {c['name']!r} "
                             f"does not resolve through SkillPointsTable")
                entry["checks"].append({"type": "skillpoint", "name": task,
                                        "enum": int(enum),
                                        "location": full(c["name"]), "id": loc_id})
        for loc_id, name, pct in engine_data.gem_threshold_checks(level):
            entry["checks"].append({"type": "gem", "threshold": pct,
                                    "location": prefix + name, "id": loc_id})
        # Boss kill / level complete (flights included): the save records the
        # level's completion key; regions.lua resolves it.
        event = engine_data.event_check(level)
        if event:
            entry["events"].append({"location": prefix + event[1], "id": event[0]})
        regions[region] = entry

    # No two checks or events may share an id.
    all_ids = [c["id"] for r in regions.values() for c in r["checks"]]
    all_ids += [e["id"] for r in regions.values() for e in r["events"]]
    if len(set(all_ids)) != len(all_ids):
        sys.exit("ERROR: spyro1 duplicate location ids")

    return {"baseId": data["baseId"], "locationPrefix": "Spyro 1: ",
            "skillPointRange": skill_point_range("spyro1", client),
            "regions": regions}


def build_tabular(game: str, engine_data, client: dict) -> dict:
    """spyro2/spyro3: straight from the JSON's per-level location rows, with
    the IDs the data engine assigns (baseId + tableOffset * regionIndex +
    row)."""
    data = engine_data.raw
    path_of_region = {r: p for p, r in client["levelPaths"][game].items()}
    sp_rows = client["skillPoints"][game]
    sp_regions = client["skillPointLevelToRegion"][game]
    regions = {}
    for region, rows in engine_data.regions.items():
        if not rows:
            continue
        if region not in path_of_region:
            sys.exit(f"ERROR: {game} region {region!r} has no levelPath")
        checks = []
        for loc in rows:
            row = {"type": loc["kind"].value, "location": loc["name"], "id": loc["id"]}
            if loc["kind"].value == "gem":
                row["threshold"] = loc["threshold"]
            elif loc["kind"].value in ("orb", "talisman", "egg"):
                row["name"] = loc.get("saveKey", "")
                if loc["kind"].value == "egg":
                    row["saveKey"] = loc.get("saveKey", "")
            elif loc["kind"].value == "ability":
                row["ability"] = loc["plain"].split(": ")[-1].removesuffix(" Ability")
            elif loc["kind"].value == "boss":
                row["name"] = loc["plain"].split(": ")[-1]
                if loc.get("saveKey"):
                    row["saveKey"] = loc["saveKey"]
            elif loc["kind"].value == "skillpoint":
                rest = loc["plain"]
                level_display = rest.split(": ", 1)[0]
                task = rest.split(": ", 1)[1].removesuffix(" (Skill Point)")
                enum = next((k for k, v in sp_rows.items()
                             if v["task"] == task
                             and sp_regions.get(v["level"]) == level_display), None)
                if enum is None:
                    sys.exit(f"ERROR: {game} skill-point {loc['name']!r} "
                             f"does not resolve through SkillPointsTable")
                row["name"] = task
                row["enum"] = int(enum)
            elif loc["kind"].value == "sparxpower":
                row["name"] = "EIT_SparxPower_" + loc["saveKey"]
            checks.append(row)
        regions[region] = {"levelPath": path_of_region[region],
                           "gemTotal": engine_data.gem_totals[region],
                           "checks": checks}
    # checkd fires gem checks from the save's per-level gem records; a level
    # the save records no gems for could never fire one.
    for region, entry in regions.items():
        gems = [c for c in entry["checks"] if c["type"] == "gem"]
        if entry["gemTotal"] == 0 and gems:
            sys.exit(f"ERROR: {game} region {region} has gemTotal 0 but "
                     f"{len(gems)} gem checks (no save-recordable gems there)")
    prefix = {"spyro2": "Spyro 2: ", "spyro3": "Spyro 3: "}[game]
    return {"baseId": data["baseId"], "locationPrefix": prefix,
            "skillPointRange": skill_point_range(game, client),
            "regions": regions}


def build_doc(client: dict) -> dict:
    """The whole locations.json document (main writes it, the audit diffs it)."""
    s1_data = ENGINE.load("spyro1")
    s1 = build_spyro1(s1_data, client)
    s2 = build_tabular("spyro2", ENGINE.load("spyro2"), client)
    s3 = build_tabular("spyro3", ENGINE.load("spyro3"), client)
    return {"game": GAME,
            "gemThresholds": [[int(pct), label]
                              for pct, label in s1_data.gem_thresholds],
            # Per-gem-type values (client save semantics, never computed in Lua).
            # checkd embeds these; scripts/gen_golden.py reads the same rows.
            "gemValues": client["gemValues"],
            "games": {"spyro1": s1, "spyro2": s2, "spyro3": s3}}


def main() -> None:
    client = load("client.json")
    doc = build_doc(client)
    s1, s2, s3 = (doc["games"][g] for g in GAMES)

    with open(OUT, "w") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    write_lua_files()

    n_checks = sum(len(r["checks"]) for r in s1["regions"].values())
    n_events = sum(len(r["events"]) for r in s1["regions"].values())
    n_s2 = sum(len(r["checks"]) for r in s2["regions"].values())
    n_s3 = sum(len(r["checks"]) for r in s3["regions"].values())
    print(f"wrote {OUT}: spyro1 {len(s1['regions'])} regions / {n_checks} "
          f"per-region checks, {n_events} events; "
          f"spyro2 {len(s2['regions'])} regions / {n_s2} per-region checks; "
          f"spyro3 {len(s3['regions'])} regions / {n_s3} per-region checks")
    n_paths = sum(len(v) for v in client["levelPaths"].values())
    print(f"wrote {OUT_LUA}: {n_paths} path->region entries")
    c = build_constants(client)
    print(f"wrote {OUT_LUA_CONST}: {len(c['eitTypes'])} EIT ids, "
          f"homeworlds {len(c['homeworlds']['spyro1'])}/"
          f"{len(c['homeworlds']['spyro2'])}/{len(c['homeworlds']['spyro3'])}, "
          f"totals dragons={c['totals']['dragons']} orbs={c['totals']['orbs']} "
          f"eggs={c['totals']['eggs']}")

    # Hard totals guard: the documented counts must hold.
    expected = {"spyro1": 237, "spyro2": 184, "spyro3": 289}
    got = {
        "spyro1": n_checks + n_events,
        "spyro2": n_s2,
        "spyro3": n_s3,
    }
    for game, want in expected.items():
        if got[game] != want:
            print(f"ERROR: {game} documented {got[game]} locations, "
                  f"expected {want}", file=sys.stderr)
            sys.exit(1)


def build_constants(client: dict) -> dict:
    """The facts constants.lua carries: EIT type ids (client.json's eitTypes),
    the per-game homeworld sets and the reconcile collectible totals. The
    homeworlds and totals come from the world level data so they cannot drift
    from the checks the mod resolves."""
    s1 = ENGINE.load("spyro1")
    homeworlds = {
        "spyro1": [lv["name"] for lv in s1.raw["levels"]
                   if lv["type"] == ENGINE.LevelType.HUB.value],
        "spyro2": list(ENGINE.load("spyro2").raw["homeworlds"]),
        "spyro3": list(ENGINE.load("spyro3").raw["homeworlds"]),
    }
    dragons = sum(1 for lv in s1.raw["levels"] for c in lv["checks"]
                  if c["type"] == ENGINE.CheckType.DRAGON.value)
    orbs = sum(1 for rows in ENGINE.load("spyro2").regions.values()
               for loc in rows if loc["kind"] is ENGINE.Spyro2Kind.ORB)
    eggs = sum(1 for rows in ENGINE.load("spyro3").regions.values()
               for loc in rows if loc["kind"] is ENGINE.Spyro3Kind.EGG)
    return {"eitTypes": client["eitTypes"], "homeworlds": homeworlds,
            "totals": {"dragons": dragons, "orbs": orbs, "eggs": eggs}}


def constants_lua_text() -> str:
    c = build_constants(load("client.json"))
    lines = [
        "-- AUTO-GENERATED by client/checkd/scripts/gen_locations.py from",
        "-- world/data/client.json (EIT ids) and world/data/spyro{1,2,3}.json",
        "-- (homeworlds, collectible totals). Do not edit by hand.",
        "-- Regenerate: python3 <repo>/client/checkd/scripts/gen_locations.py",
        "return {",
        "    eit = {",
    ]
    for name in sorted(c["eitTypes"]):
        lines.append(f'        ["{name}"] = {int(c["eitTypes"][name])},')
    lines += ["    },", "    homeworlds = {"]
    for game in GAMES:
        lines.append(f"        {game} = {{")
        for region in sorted(c["homeworlds"][game]):
            lines.append(f'            ["{region}"] = true,')
        lines.append("        },")
    lines += ["    },", "    totals = {"]
    for name in ("dragons", "orbs", "eggs"):
        lines.append(f'        {name} = {int(c["totals"][name])},')
    lines += ["    },", "}"]
    return "\n".join(lines) + "\n"


def regions_lua_text() -> str:
    client = load("client.json")
    lines = [
        "-- AUTO-GENERATED by client/checkd/scripts/gen_locations.py from",
        "-- world/data/client.json. Do not edit by hand.",
        "-- Regenerate: python3 <repo>/client/checkd/scripts/gen_locations.py",
        "return {",
    ]
    paths = {**client["levelPaths"]["spyro1"],
             **client["levelPaths"]["spyro2"],
             **client["levelPaths"]["spyro3"]}
    for path in sorted(paths):
        lines.append(f'    ["{path}"] = "{paths[path]}",')
    lines.append("}")
    return "\n".join(lines) + "\n"


def write_lua_files() -> None:
    with open(OUT_LUA, "w") as f:
        f.write(regions_lua_text())
    with open(OUT_LUA_CONST, "w") as f:
        f.write(constants_lua_text())


if __name__ == "__main__":
    main()