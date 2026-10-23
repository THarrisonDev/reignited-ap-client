#!/usr/bin/env python3
"""Guard the client protocol version against drift between the mod and the launcher.

The version the mod reports at ConnectSlot (ap_client.lua) and the one the
launcher sends in its Connect request (launcher/feed.go) must be identical;
nothing else compares them, so a hand-edit to one would silently split the
handshake. Exits non-zero when they disagree.
"""

import re
import sys
from pathlib import Path

CLIENT = Path(__file__).resolve().parents[1]
AP_LUA = CLIENT / "ue4ss_mod/srt_bridge/Scripts/ap_client.lua"
FEED_GO = CLIENT / "launcher/feed.go"

LUA_RE = re.compile(r"client_version\s*=\s*\{\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\}")
GO_RE = re.compile(
    r'"version":\s*map\[string\]any\{\s*"major":\s*(\d+),\s*"minor":\s*(\d+),\s*"build":\s*(\d+)'
)


def version_of(path: Path, pattern: re.Pattern) -> tuple[int, int, int]:
    """Return the (major, minor, build) tuple matched in path, or exit on a miss."""
    match = pattern.search(path.read_text())
    if not match:
        sys.exit(f"ERROR: no client version found in {path}")
    return (int(match.group(1)), int(match.group(2)), int(match.group(3)))


def main() -> None:
    lua = version_of(AP_LUA, LUA_RE)
    go = version_of(FEED_GO, GO_RE)
    if lua != go:
        sys.exit(
            f"ERROR: client version drift: {AP_LUA.name}={lua} "
            f"but {FEED_GO.name}={go}"
        )
    print("client version OK: %d.%d.%d" % lua)


if __name__ == "__main__":
    main()
