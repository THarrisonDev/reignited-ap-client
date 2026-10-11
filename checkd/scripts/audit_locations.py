#!/usr/bin/env python3
# Author: Tim Harrison
# Created: 2026-09-26
# Updated: 2026-10-11

"""Guard: the generated client files match what gen_locations.py would produce.

Regenerates client/checkd/locations.json and the mod's regions.lua in memory
(from world/data/*.json via gen_locations.py) and diffs them against the
checked-in files. Exits non-zero if they drift — i.e. a source was edited but
gen_locations.py wasn't re-run, so the client would resolve a region or
location name (or ID) the apworld no longer uses.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_locations as gen  # noqa: E402


def main():
    if not os.path.isdir(gen.DATA):
        sys.exit(f"ERROR: {gen.DATA} not found — run from a full checkout "
                 "(the client submodule needs the sibling world/ data)")

    client = gen.load("client.json")
    expected = gen.build_doc(client)

    problems = []

    with open(gen.OUT, encoding="utf-8") as f:
        on_disk = json.load(f)
    if on_disk != expected:
        problems.append(f"{os.path.relpath(gen.OUT, gen.REPO)} is STALE — "
                        "run client/checkd/scripts/gen_locations.py")
        eg, dg = expected["games"], on_disk.get("games", {})
        for game in sorted(set(eg) | set(dg)):
            e, d = eg.get(game, {}), dg.get(game, {})
            er, dr = e.get("regions", {}), d.get("regions", {})
            for region in sorted(set(er) | set(dr)):
                if er.get(region) != dr.get(region):
                    problems.append(f"    {game} region differs: {region}")
            for field in sorted((set(e) | set(d)) - {"regions"}):
                if e.get(field) != d.get(field):
                    problems.append(f"    {game} {field} differs")
        if expected["game"] != on_disk.get("game"):
            problems.append("    game differs")
        if expected["gemThresholds"] != on_disk.get("gemThresholds"):
            problems.append("    gemThresholds differs")

    with open(gen.OUT_LUA, encoding="utf-8") as f:
        if f.read() != gen.regions_lua_text():
            problems.append(f"{os.path.relpath(gen.OUT_LUA, gen.REPO)} is "
                            "STALE — run client/checkd/scripts/gen_locations.py")

    if problems:
        print("DRIFT — generated files out of sync with sources:")
        for p in problems:
            print("  " + p)
        sys.exit(1)

    parts = []
    for game, doc in expected["games"].items():
        r = doc["regions"]
        checks = sum(len(x["checks"]) + len(x.get("events", [])) for x in r.values())
        parts.append(f"{game} {len(r)} regions / {checks} checks")
    print(f"OK: {'; '.join(parts)} — locations.json + regions.lua match the data sources.")


if __name__ == "__main__":
    main()