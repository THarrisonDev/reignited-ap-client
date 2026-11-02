#!/bin/sh
# Author: Tim Harrison
# Created: 2026-11-01
# Updated: 2026-11-01

# Collect the client's support files into one archive for a bug report.
# Read-only against the bridge, game and save folders: the only writes are a
# scratch dir (trap-cleaned) and the archive. Save files are never included.
set -e

dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

last=4000
out=""
out_given=0
bridge_override=""

usage() {
	cat <<'EOF'
Usage: collect-logs.sh [options]

  --out PATH          archive path (default srtap-logs-<timestamp>.zip here)
  --bridge-dir DIR    use this srtap_bridge folder instead of discovery
  --help              show this help
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--out)
		if [ $# -lt 2 ]; then echo "--out needs a path" >&2; exit 1; fi
		out=$2
		out_given=1
		shift 2
		;;
	--bridge-dir)
		if [ $# -lt 2 ]; then echo "--bridge-dir needs a path" >&2; exit 1; fi
		bridge_override=$2
		shift 2
		;;
	--help | -\?)
		usage
		exit 0
		;;
	*)
		echo "unknown option: $1" >&2
		usage >&2
		exit 1
		;;
	esac
done

ts=$(date -u +%Y%m%d-%H%M%S)
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [ -z "$out" ]; then
	out="$dir/srtap-logs-$ts.zip"
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/srtap-logs.XXXXXX")
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

roots="$scratch/roots.list"
: > "$roots"

add_root() {
	if [ -z "$1" ]; then return 0; fi
	case "$1" in
	/*) ;;
	*) return 0 ;;
	esac
	if [ ! -d "$1" ]; then return 0; fi
	if grep -Fqx -- "$1" "$roots"; then return 0; fi
	printf '%s\n' "$1" >> "$roots"
}

add_root "${STEAM_ROOT:-}"
add_root "${HOME:-}/.local/share/Steam"
add_root "${HOME:-}/.var/app/com.valvesoftware.Steam/.local/share/Steam"

base=$(awk 'END { print NR }' "$roots")
i=0
while [ "$i" -lt "$base" ]; do
	i=$((i + 1))
	r=$(sed -n "${i}p" "$roots")
	vdf="$r/steamapps/libraryfolders.vdf"
	if [ -f "$vdf" ]; then
		sed -n 's/.*"path"[[:space:]]*"\([^"]*\)".*/\1/p' "$vdf" > "$scratch/paths.list"
		while IFS= read -r p; do
			add_root "$p"
		done < "$scratch/paths.list"
	fi
done

bridges="$scratch/bridges.list"
: > "$bridges"
if [ -n "$bridge_override" ]; then
	if [ ! -d "$bridge_override" ]; then
		echo "bridge folder not found: $bridge_override" >&2
		exit 1
	fi
	printf '%s\n' "$(CDPATH= cd -- "$bridge_override" && pwd)" >> "$bridges"
else
	while IFS= read -r r; do
		b="$r/steamapps/compatdata/996580/pfx/drive_c/srtap_bridge"
		if [ -d "$b" ]; then printf '%s\n' "$b" >> "$bridges"; fi
	done < "$roots"
fi
if [ ! -s "$bridges" ]; then
	echo "Nothing found — run with --bridge-dir <path to srtap_bridge>" >&2
	exit 1
fi

count=$(awk 'END { print NR }' "$bridges")
bridge=$(sed -n 1p "$bridges")
other=""
if [ "$count" -gt 1 ]; then
	other=$(awk 'NR > 1 { printf "%s%s", sep, $0; sep = "; " }' "$bridges")
fi

game=""
save_dir="not found"
while IFS= read -r r; do
	c="$r/steamapps/common/Spyro Reignited Trilogy/Falcon/Binaries/Win64"
	if [ -z "$game" ] && [ -d "$c" ]; then game=$c; fi
	sd="$r/steamapps/compatdata/996580/pfx/drive_c/users/steamuser/AppData/Local/Falcon/Saved/SaveGames"
	if [ "$save_dir" = "not found" ] && [ -d "$sd" ]; then save_dir=$sd; fi
done < "$roots"

stage="$scratch/srtap-logs-$ts"
mkdir -p "$stage"

# The three connection values, read once from config.txt. Each is replaced
# verbatim wherever it appears in a copied text file.
cfg_val() {
	[ -f "$bridge/config.txt" ] || return 0
	sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$bridge/config.txt" |
		head -n 1 | tr -d '\r' | sed 's/[[:space:]]*$//'
}
cfg_password=$(cfg_val password)
cfg_host=$(cfg_val host)
cfg_slot=$(cfg_val slot)

sed_esc() { printf '%s' "$1" | sed 's/[][\.*^$/&]/\\&/g'; }

# Redact secrets from a copied text file: the password/host/slot values as
# literals, ws:// and wss:// addresses, "To <player>:" peer lines.
redact() {
	set --
	for v in "$cfg_password" "$cfg_host" "$cfg_slot"; do
		if [ "${#v}" -ge 3 ]; then
			set -- "$@" -e "s/$(sed_esc "$v")/<redacted>/g"
		fi
	done
	sed -E "$@" \
		-e 's/(wss?:\/\/)[^ \t]+/\1<redacted>/' \
		-e 's/To [^:]*:/To <redacted>:/'
}

version="not found"
if [ -n "$game" ] && [ -f "$game/Mods/srt_bridge/Scripts/ap_client.lua" ]; then
	v=$(sed -n -E 's/^.*(client_version[[:space:]]*=[[:space:]]*\{[^}]*\}).*$/\1/p' \
		"$game/Mods/srt_bridge/Scripts/ap_client.lua" | head -n 1)
	if [ -n "$v" ]; then version=$v; fi
fi

bridge_meta="not found"
if [ -f "$bridge/bridge.log" ]; then
	bridge_meta="$(awk 'END { print NR }' "$bridge/bridge.log") lines"
	tail -n "$last" "$bridge/bridge.log" | redact > "$stage/bridge.log"
fi
checkd_meta="not found"
if [ -f "$bridge/checkd.log" ]; then
	checkd_meta="$(awk 'END { print NR }' "$bridge/checkd.log") lines"
	tail -n "$last" "$bridge/checkd.log" | redact > "$stage/checkd.log"
fi
if [ -n "$game" ] && [ -f "$game/UE4SS.log" ]; then
	tail -n "$last" "$game/UE4SS.log" | redact > "$stage/UE4SS.log"
fi
if [ -f "$bridge/config.txt" ]; then
	redact < "$bridge/config.txt" > "$stage/config.txt"
fi
for f in checkd.status.json checks.json checkd.hb; do
	if [ -f "$bridge/$f" ]; then cp "$bridge/$f" "$stage/$f"; fi
done
if [ -f "$bridge/session.txt" ]; then
	redact < "$bridge/session.txt" > "$stage/session.txt"
fi
if [ -n "$game" ] && [ -d "$game/Mods/srt_bridge" ]; then
	(
		cd "$game/Mods/srt_bridge"
		find . -type f | sed 's|^\./||' | sort | while IFS= read -r rel; do
			printf '%s\t%s\n' "$(wc -c < "$rel" | tr -d ' ')" "$rel"
		done
	) > "$stage/srt_bridge-files.txt"
fi

{
	printf '%s\n' 'Reignited AP support bundle'
	printf 'created: %s\n' "$created"
	printf 'os: %s\n' "$(uname -srm)"
	printf 'mod client_version: %s\n' "$version"
	printf 'bridge dir: %s\n' "$bridge"
	printf 'game dir: %s\n' "${game:-not found}"
	printf 'save dir: %s\n' "$save_dir"
	if [ -n "$other" ]; then printf 'other bridge folders: %s\n' "$other"; fi
	printf 'bridge.log: %s\n' "$bridge_meta"
	printf 'checkd.log: %s\n' "$checkd_meta"
	printf '%s\n' 'redacted: password, host, slot, ws:// and wss:// addresses, "Connected to ... as ...", "To <player>:"'
	printf '%s\n' 'save files: not included'
} > "$stage/meta.txt"

case "$out" in
/*) final=$out ;;
*) final="$PWD/$out" ;;
esac

if command -v zip >/dev/null 2>&1; then
	tmparch="$scratch/archive.zip"
	if ! (cd "$scratch" && zip -q -r "$tmparch" "srtap-logs-$ts"); then
		rm -f "$tmparch"
		echo "archive write failed: $final" >&2
		exit 1
	fi
else
	case "$final" in
	*.zip) final=${final%.zip} ;;
	esac
	final="$final.tar.gz"
	tmparch="$scratch/archive.tar.gz"
	echo "zip not found — writing $final instead" >&2
	if ! tar -czf "$tmparch" -C "$scratch" "srtap-logs-$ts"; then
		rm -f "$tmparch"
		echo "archive write failed: $final" >&2
		exit 1
	fi
fi

if ! mv -f "$tmparch" "$final"; then
	rm -f "$tmparch"
	echo "archive write failed: $final" >&2
	exit 1
fi

printf '%s\n' "$final"
printf '%s\n' 'Attach this file to your report. Connection details were redacted; save files are not included.'
# Only reveal the folder for a direct run: --out means a caller (the launcher)
# owns the file and may delete it immediately.
if [ "$out_given" = 0 ]; then
	xdg-open "$(dirname "$final")" >/dev/null 2>&1 || true
fi
