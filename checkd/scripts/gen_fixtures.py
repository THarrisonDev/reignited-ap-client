#!/usr/bin/env python3
"""Generate the synthetic FalconSave fixtures checkd's tests run against.

Every fixture is constructed from scratch with pygvas (no real save data):
the GVAS header mirrors the real Falcon save (UE4.19, FalconModuleSaveGame)
and each saveDataMapArray entry is a levelObjectMap whose objectDataMap
holds the item records the Go scanners look for (dragons, eggs, orbs,
talismans, abilities, bosses, gems, skill points, Spyro 1 level completions).

Fixture stems and their content follow the checked-in goldens and the test
files' expectations:
  - snapshot1: near-empty S1 slot-0 playthrough (Nestor collected)
  - snapshot2: + Tomas + Artisans gems at exactly 25 value
  - snapshot3: + Stone Hill dragons/egg/collected, Artisans 33 Stone Hill 44
  - mid_s1: a mid-S1 save (14 dragons, 4 eggs, 5 gem regions,
    skill point 4 earned)
  - mixed_s1_s2: slot-0 full-ish S1 playthrough, slot-1 S1 (skill point 1)
    and S2 (Glimmer) playthroughs
  - s1_events: Spyro 1 level-completion records (docs/s1_level_completion.md)
    in slot 0 (exits, Gnasty's S1Boss, full/partial flights, a full Loot) and
    slot 1 (a Loot exit at half gems, a partial flight)
  - 100pct_ref: a synthetic 100% playthrough of all three games (80 dragons,
    64 orbs, 14 talismans, 150 named S3 eggs, all gem totals, all skill
    points, 3 obtained Sparx powers)

Outputs (checked in; regenerate after editing any content):
  - ../testdata/<stem>.sav

Run from anywhere:
    python3 <repo>/client/checkd/scripts/gen_fixtures.py [--out DIR] [--check]
"""
import argparse
import io
import json
import os
import struct
import sys

import pygvas
from pygvas.engine_tools import CompressionType, FEngineVersion, GameVersion
from pygvas.gvas_file import GameFileFormat, GvasHeader, GVASFile
from pygvas.properties.aggregator_properties import ArrayProperty, MapProperty, StructProperty
from pygvas.properties.enum_property import EnumProperty
from pygvas.properties.numerical_properties import BoolProperty, FloatProperty, IntProperty
from pygvas.properties.str_property import StrProperty

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKD = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(CHECKD))
DEFAULT_OUT = os.path.join(CHECKD, "testdata")

LOCATIONS = os.path.join(CHECKD, "locations.json")

SAVE_ENTRIES = 9
GAMES_PER_SLOT = 3


def entry_index(slot, game):
    return game * GAMES_PER_SLOT + slot


def load_locations():
    with open(LOCATIONS) as f:
        return json.load(f)["games"]


# ---------------------------------------------------------------------------
# pygvas property constructors


def enum_prop(value, enum_type="EInventoryType"):
    return EnumProperty(type="EnumProperty", enum_type=enum_type, value=value)


def save_param(name=None, value=0.0):
    fields = {
        "paramName": StrProperty(type="StrProperty", value=name),
        "paramValue": FloatProperty(type="FloatProperty", value=float(value)),
    }
    return StructProperty(type="StructProperty", value=fields)


def save_params(params):
    return ArrayProperty(
        type="ArrayProperty",
        field_name="saveParams",
        property_type="StructProperty",
        type_name="PhasmidSaveParam",
        values=[save_param(n, v) for n, v in params],
    )


def item_param_list(params):
    body = {"saveParams": save_params(params)}
    return StructProperty(type="StructProperty", type_name="PhasmidSaveParamList", value=body)


def item_data(item_type, collected):
    return StructProperty(
        type="StructProperty",
        type_name="PhasmidInventoryData",
        value={
            "ItemType": enum_prop(item_type),
            "collected": BoolProperty(type="BoolProperty", value=collected),
        },
    )


def item(item_type, collected, params=()):
    return StructProperty(
        type="StructProperty",
        value={
            "itemData": item_data(item_type, collected),
            "itemParamList": item_param_list(params),
        },
    )


def named_item(item_type, name, collected=True, param_value=0.0):
    return item(item_type, collected, [(name, param_value)])


def save_data_list(items):
    return ArrayProperty(
        type="ArrayProperty",
        field_name="saveDataList",
        property_type="StructProperty",
        type_name="PhasmidObjectSaveData",
        values=items,
    )


def object_entry(obj_name, items):
    return StructProperty(type="StructProperty", value={"saveDataList": save_data_list(items)})


def gem_hash(i):
    return ((i + 1) * 2654435761 + 12345) & 0xFFFFFFFF


def gem_stash(counts):
    """counts: {gem_tag: n} -> the gemCollectionMap value-struct body: one
    GemHashArray per gem type."""
    body = {}
    for tag, count in counts.items():
        body["GemHashArray"] = ArrayProperty(
            type="ArrayProperty",
            property_type="IntProperty",
            values=[struct.unpack("<i", struct.pack("<I", gem_hash(i)))[0]
                    for i in range(count)],
        )
    return body


def struct_of(body, type_name=None):
    return StructProperty(type="StructProperty", type_name=type_name, value=body)


def gem_collection_map(counts):
    if not counts:
        return MapProperty(key_type="EnumProperty", value_type="StructProperty", values=[])
    values = []
    for tag, count in counts.items():
        values.append((enum_prop("EInventoryType::" + tag),
                       struct_of(gem_stash({tag: count}))))
    return MapProperty(key_type="EnumProperty", value_type="StructProperty", values=values)


def gem_hash_type_map(counts):
    if not counts:
        return MapProperty(key_type="IntProperty", value_type="EnumProperty", values=[])
    values = []
    for tag, count in counts.items():
        for i in range(count):
            values.append((IntProperty(type="IntProperty", value=struct.unpack(
                "<i", struct.pack("<I", gem_hash(i)))[0]),
                enum_prop("EInventoryType::" + tag)))
    return MapProperty(key_type="IntProperty", value_type="EnumProperty", values=values)


def level_objects(level_key, objects, counts=None):
    """objects: {obj_name: [item, ...]}; counts: {gem_tag: n}."""
    odm_values = [
        (StrProperty(type="StrProperty", value=name), object_entry(name, items))
        for name, items in objects.items()
    ]
    body = {}
    body["objectDataMap"] = MapProperty(
        key_type="StrProperty", value_type="StructProperty", values=odm_values
    )
    counts = counts or {}
    body["gemCollectionMap"] = gem_collection_map(counts)
    body["gemHashTypeMap"] = gem_hash_type_map(counts)
    return (StrProperty(type="StrProperty", value=level_key), struct_of(body))


def level_object_map(levels):
    """levels: [(level_key, objects, counts), ...]"""
    return MapProperty(
        key_type="StrProperty",
        value_type="StructProperty",
        values=[level_objects(k, objs, counts) for k, objs, counts in levels],
    )


def save_entry_struct(levels):
    return struct_of({"levelObjectMap": level_object_map(levels)},
                     type_name="PhasmidGameSaveLevelObjectMap")


def save_data_map_array(entries):
    return ArrayProperty(
        type="ArrayProperty",
        field_name="saveDataMapArray",
        property_type="StructProperty",
        type_name="PhasmidGameSaveLevelObjectMap",
        values=entries,
    )


def quest_save_data():
    names = struct_of(
        {
            "m_names": struct_of(
                {
                    "m_names": ArrayProperty(
                        type="ArrayProperty",
                        property_type="StrProperty",
                        values=["GameBoard"],
                    ),
                    "m_alpha": ArrayProperty(
                        type="ArrayProperty", property_type="IntProperty", values=[1]
                    ),
                },
                type_name="NameTable",
            )
        },
        type_name="QuestNameTable",
    )
    boards = MapProperty(
        key_type="StructProperty",
        value_type="StructProperty",
        values=[],
    )
    return struct_of({"names": names, "boards": boards}, type_name="QuestSaveData")


def global_float_map(pairs):
    return MapProperty(
        key_type="StrProperty",
        value_type="FloatProperty",
        values=[(StrProperty(type="StrProperty", value=k),
                 FloatProperty(type="FloatProperty", value=v)) for k, v in pairs],
    )


def falcon_header():
    return GvasHeader(
        type="Version2",
        package_file_version=516,
        engine_version=FEngineVersion(major=4, minor=19, patch=0, change_list=0,
                                      branch="++UE4+Release-4.19"),
        custom_version_format=3,
        custom_versions={},
        save_game_class_name="FalconModuleSaveGame",
    )


def build_save(entries, gfm_pairs):
    file = GVASFile(
        game_file_format=GameFileFormat(GameVersion.DEFAULT, CompressionType.NONE),
        header=falcon_header(),
        properties={
            "QuestSaveData": quest_save_data(),
            "saveDataMapArray": save_data_map_array(entries),
            "globalFloatMap": global_float_map(gfm_pairs),
        },
    )
    return file


def empty_entry():
    return save_entry_struct([])


def falcon_header_magic():
    return b"GVAS"


# ---------------------------------------------------------------------------
# item-type constants

DRAGON = "EInventoryType::EIT_Dragon"
EGG = "EInventoryType::EIT_Egg"
ORB = "EInventoryType::EIT_S2GreenOrb"
TALISMAN = "EInventoryType::EIT_Talisman"
S3_EGG = "EInventoryType::EIT_S3Egg"
S3_BONUS_EGG = "EInventoryType::EIT_S3BonusEgg"
BOSS = "EInventoryType::EIT_S2Boss"
SWIM = "EInventoryType::EIT_Swimming"
CLIMB = "EInventoryType::EIT_Climbing"
HEADBASH = "EInventoryType::EIT_HeadBash"
SKILL_POINT = "EInventoryType::EIT_SkillPoint"
PORTAL_EXIT = "EInventoryType::EIT_PortalExit"
S1_BOSS = "EInventoryType::EIT_S1Boss"
FLIGHT_REWARD = "EInventoryType::EIT_S1FlightReward"
FLIGHT_ALL_IN_ONE = 20

ABILITY_ITEMS = {"Swim": SWIM, "Climb": CLIMB, "Headbash": HEADBASH}

MENU_GFM = [
    ("eulappsigned", 0.0),
    ("slot.index", 0.0),
    ("game.index", 0.0),
    ("map", 1.0),
    ("Music_Volume", 50.0),
    ("SFX_Volume", 50.0),
]


def sparx_keys(slot, value=0.0):
    return [("collected.%d.%d.EIT_SparxPower_%s" % (slot, game, power), value)
            for game in range(3)
            for power in ("GemCollectRange", "GemFinder", "ExtraHP", "ChestBreaking")]


def abilities_items(collected=False):
    return [named_item(tag, "", collected) for tag in ABILITY_ITEMS.values()]


def global_level(objects):
    return ("Global", objects, {})


def skill_point_record(enums):
    return item(SKILL_POINT, False, [(None, float(e)) for e in enums])


# ---------------------------------------------------------------------------
# fixture builders

def s1_dragon_level(games, region, names, egg=False, collected=True, counts=None):
    path = games["spyro1"]["regions"][region]["levelPath"]
    items = [named_item(DRAGON, n, collected) for n in names]
    if egg:
        items.append(item(EGG, collected))
    return (path, {"Main": items}, counts or {})


def snapshot1():
    games = load_locations()
    levels = [
        global_level({"Global": [skill_point_record([])] + abilities_items()}),
        s1_dragon_level(games, "Artisans", ["Nestor"]),
    ]
    entries = [save_entry_struct(levels)]
    entries += [empty_entry() for _ in range(SAVE_ENTRIES - 1)]
    return build_save(entries, MENU_GFM + sparx_keys(0))


def snapshot2():
    games = load_locations()
    levels = [
        global_level({"Global": [skill_point_record([])] + abilities_items()}),
        s1_dragon_level(games, "Artisans", ["Nestor", "Tomas"],
                        counts={"EIT_RedGem": 18, "EIT_GreenGem": 2, "EIT_S2RedGem": 3}),
    ]
    entries = [save_entry_struct(levels)]
    entries += [empty_entry() for _ in range(SAVE_ENTRIES - 1)]
    return build_save(entries, MENU_GFM + sparx_keys(0))


def snapshot3():
    games = load_locations()
    levels = [
        global_level({"Global": [skill_point_record([])] + abilities_items()}),
        s1_dragon_level(games, "Artisans", ["Nestor", "Tomas"],
                        counts={"EIT_RedGem": 33}),
        s1_dragon_level(games, "Stone Hill", ["Astor", "Gildas"], egg=True,
                        counts={"EIT_RedGem": 44}),
    ]
    entries = [save_entry_struct(levels)]
    entries += [empty_entry() for _ in range(SAVE_ENTRIES - 1)]
    return build_save(entries, MENU_GFM + sparx_keys(0))


def mirror_levels(games):
    """mid_s1 content: 14 dragons, 4 collected eggs, 5 gem regions,
    skill point 4 earned (all in the slot-0 game-0 entry)."""
    egg_levels = ["Stone Hill", "Town Square", "Peace Keepers", "Cliff Town"]
    dragon_regions = ["Artisans", "Stone Hill", "Town Square", "Peace Keepers", "Cliff Town"]
    dragons = {
        "Artisans": ["Nestor", "Delbin", "Tomas", "Argus"],
        "Stone Hill": ["Lindar", "Astor", "Gavin", "Gildas"],
        "Town Square": ["Nils", "Devlin", "Alvar"],
        "Peace Keepers": ["Titan", "Gunnar"],
        "Cliff Town": ["Halvor"],
    }
    gems = {"Artisans": {"EIT_RedGem": 53},
            "Stone Hill": {"EIT_RedGem": 41},
            "Town Square": {"EIT_RedGem": 40},
            "Peace Keepers": {"EIT_RedGem": 26},
            "Cliff Town": {"EIT_RedGem": 53}}
    levels = [global_level({"Global": [skill_point_record([4])] + abilities_items()})]
    for region in dragon_regions:
        names = dragons[region]
        items = [named_item(DRAGON, n) for n in names]
        if region in egg_levels:
            items.append(item(EGG, True))
        levels.append((games["spyro1"]["regions"][region]["levelPath"],
                       {"Main": items}, gems.get(region, {})))
    return levels


def mid_s1():
    games = load_locations()
    entries = [save_entry_struct(mirror_levels(games))]
    entries += [empty_entry() for _ in range(SAVE_ENTRIES - 1)]
    return build_save(entries, MENU_GFM + sparx_keys(0))


def mixed_s1_s2():
    games = load_locations()
    s1 = games["spyro1"]["regions"]
    # slot 0, game 0: a full-ish S1 playthrough (levels the mixed golden lists)
    slot0_names = {
        "Artisans": ["Nestor", "Delbin", "Tomas", "Argus"],
        "Dark Hollow": ["Alban", "Oswin", "Darius"],
        "Peace Keepers": ["Titan", "Magnus", "Gunnar"],
        "Stone Hill": ["Lindar", "Astor", "Gavin", "Gildas"],
        "Toasty": ["Nevin"],
        "Town Square": ["Nils", "Devlin", "Alvar", "Thor"],
    }
    egg_regions = {"Stone Hill", "Town Square", "Peace Keepers"}
    full_gems = {"Artisans": 100, "Dark Hollow": 100, "Peace Keepers": 200,
                 "Stone Hill": 200, "Toasty": 100, "Town Square": 200}
    # Town Square mixes red and yellow gems: only the 10-value yellow gems
    # (4 x 10 = 40 on top of 160 red) reach the 200 total.
    def region_counts(region):
        if region not in full_gems:
            return {}
        if region == "Town Square":
            return {"EIT_RedGem": 160, "EIT_YellowGem": 4}
        return {"EIT_RedGem": full_gems[region]}
    slot0 = [global_level({"Global": [skill_point_record([])]})]
    for region, names in slot0_names.items():
        items = [named_item(DRAGON, n) for n in names]
        if region in egg_regions:
            items.append(item(EGG, True))
        slot0.append((s1[region]["levelPath"], {"Main": items}, region_counts(region)))
    # slot 1, game 0: S1 with skill point 1 earned
    slot1_s1 = [
        global_level({"Global": [skill_point_record([1])]}),
        (s1["Artisans"]["levelPath"], {"Main": [named_item(DRAGON, "Nestor")]}, {}),
    ]
    # slot 1, game 1: the Glimmer playthrough
    glimmer_counts = {"EIT_S2RedGem": 21, "EIT_S2GreenGem": 39,
                      "EIT_S2PurpleGem": 21, "EIT_S2YellowGem": 2}
    s2g1 = games["spyro2"]["regions"]["Glimmer"]["levelPath"]
    slot1_s2 = [
        global_level({"Global": abilities_items() + [skill_point_record([])]}),
        (s2g1, {"Main": [
            named_item(ORB, "Lizard hunt"),
            named_item(ORB, "Gem Lamp Flight outdoors"),
            named_item(TALISMAN, "Magic Pick"),
        ]}, glimmer_counts),
    ]
    entries = [empty_entry() for _ in range(SAVE_ENTRIES)]
    entries[entry_index(0, 0)] = save_entry_struct(slot0)
    entries[entry_index(1, 0)] = save_entry_struct(slot1_s1)
    entries[entry_index(1, 1)] = save_entry_struct(slot1_s2)
    gfm = [
        ("eulappsigned", 0.0),
        ("slot.index", 1.0),
        ("slot.active.0", 1.0),
        ("game.index", 1.0),
        ("map", 1.0),
    ]
    gfm += sparx_keys(0) + sparx_keys(1)
    return build_save(entries, gfm)


def full_s1_levels(games):
    """The 100% Spyro 1 playthrough: 80 dragons, every non-flight level at its
    gemTotal (flights 0), all 14 skill points."""
    s1 = games["spyro1"]["regions"]
    flights = {"Sunny Flight", "Night Flight", "Crystal Flight", "Wild Flight", "Icy Flight"}
    levels = [global_level({"Global": [
        skill_point_record(range(1, 15))] + abilities_items()})]
    for region, r in s1.items():
        dragons = [c["name"] for c in r["checks"] if c["type"] == "dragon"]
        eggs = sum(1 for c in r["checks"] if c["type"] == "egg")
        items = [named_item(DRAGON, n) for n in dragons]
        for _ in range(eggs):
            items.append(item(EGG, True))
        counts = {} if region in flights else {"EIT_RedGem": r["gemTotal"]}
        levels.append((r["levelPath"], {"Main": items}, counts))
    return levels


def full_s2_levels(games):
    """The 100% Spyro 2 playthrough: 64 orbs, 14 talismans, the 21 gem levels
    at 400, 3 collected abilities, 3 collected bosses, 16 skill points."""
    s2 = games["spyro2"]["regions"]
    boss_paths = {"Crush's Dungeon": "Crush Defeated",
                 "Gulp's Overlook": "Gulp Defeated",
                 "Ripto's Arena": "Ripto Defeated"}
    levels = [global_level({"Global": [
        named_item(SWIM, "", True), named_item(CLIMB, "", True),
        named_item(HEADBASH, "", True), skill_point_record(range(15, 31)),
    ]})]
    for region, r in s2.items():
        items = []
        for c in r["checks"]:
            if c["type"] == "orb":
                items.append(named_item(ORB, c["name"]))
            elif c["type"] == "talisman":
                items.append(named_item(TALISMAN, c["name"]))
            elif c["type"] == "boss":
                items.append(item(BOSS, True))
        counts = {} if r["gemTotal"] == 0 else {"EIT_S2RedGem": r["gemTotal"]}
        if items or counts:
            levels.append((r["levelPath"], {"Main": items} if items else {"Main": []},
                           counts))
    return levels


def full_s3_levels(games):
    """The 100% Spyro 3 playthrough: 150 named eggs (Al as the bonus egg),
    29 gem levels at their gemTotal, 20 skill points, the MoneybagGems stash."""
    s3 = games["spyro3"]["regions"]
    levels = [global_level({"Global": [skill_point_record(range(31, 51))]})]
    for region, r in s3.items():
        items = []
        for c in r["checks"]:
            if c["type"] == "egg":
                tag = S3_BONUS_EGG if c["name"] == "Al" else S3_EGG
                items.append(named_item(tag, c["name"]))
            elif c["type"] == "boss":
                items.append(named_item(S3_EGG, c["saveKey"]))
        counts = {} if r["gemTotal"] == 0 else {"EIT_S2RedGem": r["gemTotal"]}
        if items or counts:
            levels.append((r["levelPath"], {"Main": items} if items else {"Main": []},
                           counts))
    levels.append(("MoneybagGems", {}, {"EIT_S2RedGem": 100}))
    return levels


def ref100_gfm():
    filler = [
        ("eulappsigned", 0.0),
        ("menu.ui_systemoptions", 1.0),
        ("slot.index", 0.0),
        ("slot.active.0", 1.0),
        ("game.index", 0.0),
        ("map", 1.0),
        ("menu.ui_camera", 0.0),
        ("activeCameraOn", 1.0),
        ("menu.ui_soundoptions", 1.0),
        ("menu.ui_sound", 2.0),
        ("Music_Volume", 50.0),
        ("SFX_Volume", 50.0),
        ("Voice_Volume", 30.0),
        ("vibration", 1.0),
        ("code.color", 2.0),
        ("mouse_sensitivity", 0.25),
        ("RetroControlsOn", 1.0),
        ("use_mouse_for_flying", 1.0),
        ("credits.unlock", 1.0),
        ("debug.PhasmidNoCull", 1.0),
        ("SuperflameAllSlotUnlock", 1.0),
        ("menu.ui_controls", 0.0),
    ]
    sparx = [
        ("collected.0.2.EIT_SparxPower_GemCollectRange", 1.0),
        ("collected.0.2.EIT_SparxPower_ExtraHP", 1.0),
        ("collected.0.2.EIT_SparxPower_ChestBreaking", 1.0),
    ]
    return filler + sparx


def portal_exit(param_path):
    """The exit vortex record: one param naming a level path, value 0.0."""
    return named_item(PORTAL_EXIT, param_path)


def flight_rewards(values):
    """One collected EIT_S1FlightReward per EFlightLevelTargetType value, each
    with one nameless float param."""
    return [item(FLIGHT_REWARD, True, [(None, float(v))]) for v in values]


def s1_events():
    """Spyro 1 completion records in two game-0 entries.

    slot 0 fires Stone Hill, Toasty and Dark Passage (exits), Gnasty Gnorc
    (S1Boss, plus its exit), Sunny Flight (4 sets + 20) and Wild Flight (4 sets,
    no 20); Night (2 sets + 20, with an exit), Crystal (a repeated set: 2
    distinct) and Icy (20 only) stay open; the Loot exit fires nothing, but the
    Loot's full 2000 gems fire its event through the gem flow.
    slot 1 fires Dark Hollow only: Icy Flight has 3 sets and an exit, and the
    Loot exit sits at half the Loot's gems."""
    s1 = load_locations()["spyro1"]["regions"]

    def path(region):
        return s1[region]["levelPath"]

    slot0 = [
        global_level({"Global": [skill_point_record([])]}),
        (path("Stone Hill"), {"WhirlwindTransporter": [portal_exit(path("Stone Hill"))]}, {}),
        (path("Toasty"), {"WhirlwindTransporter_297": [portal_exit(path("Toasty"))]}, {}),
        (path("Dark Passage"), {"LevelPortal": [portal_exit(path("Dark Passage"))]}, {}),
        (path("Gnasty Gnorc"), {
            "CBS1005_GnastyGnorc_410_Death_Collectible_4": [item(S1_BOSS, True)],
            "WhirlwindTransporter_614": [portal_exit(path("Gnasty Gnorc"))],
        }, {}),
        (path("Sunny Flight"), {
            "Flight_StageController_S2_197": flight_rewards([3, 1, 5, 4, FLIGHT_ALL_IN_ONE]),
            "FlightLevelTransporter_320": [portal_exit(path("Sunny Flight"))],
        }, {}),
        (path("Wild Flight"), {
            "Flight_StageController_S2_284": flight_rewards([5, 4, 3, 7]),
        }, {}),
        (path("Night Flight"), {
            "Flight_StageController_S2_188": flight_rewards([5, 4, FLIGHT_ALL_IN_ONE]),
            "FlightLevelTransporter_284": [portal_exit(path("Night Flight"))],
        }, {}),
        (path("Crystal Flight"), {
            "Flight_StageController_S2_116": flight_rewards([4, 4, 2, FLIGHT_ALL_IN_ONE]),
        }, {}),
        (path("Icy Flight"), {
            "Flight_StageController_S2_122": flight_rewards([FLIGHT_ALL_IN_ONE]),
        }, {}),
        (path("Gnasty's Loot"), {"WhirlwindTransporter": [portal_exit(path("Gnorc Gnexus"))]},
         {"EIT_PurpleGem": 80}),
    ]
    slot1 = [
        global_level({"Global": [skill_point_record([])]}),
        (path("Dark Hollow"), {"WhirlwindTransporter_262": [portal_exit(path("Dark Hollow"))]}, {}),
        (path("Icy Flight"), {
            "Flight_StageController_S2_122": flight_rewards([1, 27, 5]),
            "FlightLevelTransporter_356": [portal_exit(path("Icy Flight"))],
        }, {}),
        (path("Gnasty's Loot"), {"WhirlwindTransporter": [portal_exit(path("Gnorc Gnexus"))]},
         {"EIT_PurpleGem": 40}),
    ]
    entries = [empty_entry() for _ in range(SAVE_ENTRIES)]
    entries[entry_index(0, 0)] = save_entry_struct(slot0)
    entries[entry_index(1, 0)] = save_entry_struct(slot1)
    return build_save(entries, MENU_GFM + sparx_keys(0) + sparx_keys(1))


def pct100_ref():
    games = load_locations()
    entries = [empty_entry() for _ in range(SAVE_ENTRIES)]
    entries[entry_index(0, 0)] = save_entry_struct(full_s1_levels(games))
    entries[entry_index(0, 1)] = save_entry_struct(full_s2_levels(games))
    entries[entry_index(0, 2)] = save_entry_struct(full_s3_levels(games))
    return build_save(entries, ref100_gfm())


BUILDERS = {
    "snapshot1": snapshot1,
    "snapshot2": snapshot2,
    "snapshot3": snapshot3,
    "mid_s1": mid_s1,
    "mixed_s1_s2": mixed_s1_s2,
    "s1_events": s1_events,
    "100pct_ref": pct100_ref,
}


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", default=DEFAULT_OUT, help="output directory")
    ap.add_argument("--check", action="store_true",
                    help="verify the checked-in fixtures match a fresh build")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    failed = False
    for stem, build in BUILDERS.items():
        path = os.path.join(args.out, stem + ".sav")
        data = serialize(build())
        if args.check:
            try:
                with open(path, "rb") as f:
                    current = f.read()
            except FileNotFoundError:
                print("MISSING %s" % path)
                failed = True
                continue
            if current != data:
                print("DRIFT %s (%d bytes on disk, %d fresh)" % (path, len(current), len(data)))
                failed = True
            else:
                print("ok %s (%d bytes)" % (path, len(data)))
        else:
            with open(path, "wb") as f:
                f.write(data)
            reread = pygvas.GVASFile.deserialize_gvas_file(path)
            buf2 = io.BytesIO()
            reread.write(buf2, None)
            if buf2.getvalue() != data:
                print("ERROR %s: pygvas round-trip is not byte-stable" % path)
                failed = True
                continue
            print("wrote %s (%d bytes)" % (path, len(data)))
    if failed:
        sys.exit(1)


def serialize(gvas):
    buf = io.BytesIO()
    gvas.write(buf, None)
    return buf.getvalue()


if __name__ == "__main__":
    main()