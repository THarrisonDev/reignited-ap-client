#!/usr/bin/env python3
"""Report module functions nothing in the mod calls.

luacheck sees unused locals, but not a function a module hangs off its return
table: those are dead only if no other script (or the host's dynamic dispatch,
`state.each("method", ...)`) ever names them. A function referenced only by the
specs is reported separately — it is API the tests pin, not dead weight.

Run from the client repo root: `make deadcode`. Exits non-zero when a function
has no reference at all.
"""

import re
import sys
from pathlib import Path

CLIENT = Path(__file__).resolve().parents[1]
SCRIPTS = CLIENT / "ue4ss_mod/srt_bridge/Scripts"
SPECS = CLIENT / "tests/lua"

# function M.name(...) / M.name = function. The indent is spaces/tabs only, so
# a match never starts on the blank line above and blanking it stays exact.
DEFS = (
    re.compile(r"^[ \t]*function\s+([A-Za-z_]\w*)\.([A-Za-z_]\w*)\s*\(", re.MULTILINE),
    re.compile(r"^[ \t]*([A-Za-z_]\w*)\.([A-Za-z_]\w*)\s*=\s*function\b", re.MULTILINE),
)
# A table declared at file scope, e.g. `local M = {}`; the module's own table.
MODULE_TABLES = re.compile(r"^local\s+([A-Za-z_]\w*)\s*=\s*\{", re.MULTILINE)


def definitions(text: str) -> list[tuple[str, str, int]]:
    """Return (table, name, offset) for each function hung off a module table."""
    tables = set(MODULE_TABLES.findall(text))
    found = []
    for pattern in DEFS:
        for match in pattern.finditer(text):
            table, name = match.group(1), match.group(2)
            if table in tables:
                found.append((table, name, match.start()))
    return found


def references(name: str, text: str) -> int:
    """Count uses of name as a field, method or dispatch string."""
    field = re.compile(r"[.:]" + re.escape(name) + r"\b")
    literal = re.compile(r"[\"']" + re.escape(name) + r"[\"']")
    return len(field.findall(text)) + len(literal.findall(text))


def main() -> None:
    prod = {path: path.read_text() for path in sorted(SCRIPTS.rglob("*.lua"))}
    specs = "\n".join(path.read_text() for path in sorted(SPECS.glob("*.lua")))
    exported = 0
    dead: list[str] = []
    test_only: list[str] = []
    bodies: dict[Path, str] = {}

    for path, text in prod.items():
        trimmed = list(text)
        for _table, _name, start in definitions(text):
            exported += 1
            # Blank the definition so it cannot count as its own use.
            end = text.find("\n", start)
            for i in range(start, len(text) if end < 0 else end):
                trimmed[i] = " "
        bodies[path] = "".join(trimmed)
    corpus = "\n".join(bodies.values())

    for path, text in prod.items():
        for _table, name, _start in definitions(text):
            if references(name, corpus):
                continue
            where = "%s: %s" % (path.relative_to(SCRIPTS), name)
            (test_only if references(name, specs) else dead).append(where)

    print("%d module functions in %d scripts" % (exported, len(prod)))
    if test_only:
        print("test-only (kept for the specs):")
        for line in test_only:
            print("  " + line)
    if dead:
        print("dead (no reference in the mod or the specs):")
        for line in dead:
            print("  " + line)
        sys.exit(1)


if __name__ == "__main__":
    main()
