#!/bin/sh
# Author: Tim Harrison
# Created: 2026-11-01
# Updated: 2026-11-09

# Collect the client's support files into one archive for a bug report.
# Read-only against the bridge, game and save folders: the only writes are a
# scratch dir (trap-cleaned) and the archive. Save files are never included.
# Path discovery follows docs/client_paths.md.
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

seeds="$scratch/seeds.list"
roots="$scratch/roots.list"
bridges="$scratch/bridges.list"
: > "$seeds"
: > "$roots"
: > "$bridges"

normalize_dir() {
	_n=$(readlink -f -- "$1" 2>/dev/null) || _n=""
	if [ -n "$_n" ]; then
		printf '%s\n' "$_n"
		return 0
	fi
	(cd -- "$1" 2>/dev/null && pwd)
}

# Append an absolute, existing, symlink-resolved directory to a list file.
add_path() {
	case "${2:-}" in /*) ;; *) return 0 ;; esac
	if [ ! -d "$2" ]; then return 0; fi
	_p=$(normalize_dir "$2") || return 0
	case "$_p" in /*) ;; *) return 0 ;; esac
	if grep -Fqx -- "$_p" "$1"; then return 0; fi
	printf '%s\n' "$_p" >> "$1"
}

add_path "$seeds" "${STEAM_ROOT:-}"
if [ -n "${XDG_DATA_HOME:-}" ]; then
	add_path "$seeds" "$XDG_DATA_HOME/Steam"
else
	add_path "$seeds" "${HOME:-}/.local/share/Steam"
fi
add_path "$seeds" "${HOME:-}/.steam/steam"
add_path "$seeds" "${HOME:-}/.var/app/com.valvesoftware.Steam/.local/share/Steam"
add_path "$seeds" "${HOME:-}/snap/steam/common/.local/share/Steam"
cat "$seeds" >> "$roots"

# Each root's libraryfolders.vdf adds libraries, which may carry their own vdf:
# walk the list as it grows. Keys are "path" (modern) or "<n>" (legacy).
i=0
while :; do
	i=$((i + 1))
	r=$(sed -n "${i}p" "$roots")
	if [ -z "$r" ]; then break; fi
	vdf="$r/steamapps/libraryfolders.vdf"
	if [ ! -f "$vdf" ]; then continue; fi
	sed -E -n 's/^[[:space:]]*"(path|[0-9]+)"[[:space:]]*"([^"]+)".*$/\2/p' "$vdf" > "$scratch/libs.list"
	while IFS= read -r p; do
		add_path "$roots" "$p"
	done < "$scratch/libs.list"
done

game=""
game_any=""
while IFS= read -r r; do
	c="$r/steamapps/common/Spyro Reignited Trilogy/Falcon/Binaries/Win64"
	if [ ! -d "$c" ]; then continue; fi
	if [ -z "$game_any" ]; then game_any=$c; fi
	if [ -f "$r/steamapps/appmanifest_996580.acf" ]; then
		game=$c
		break
	fi
done < "$roots"
if [ -z "$game" ]; then game=$game_any; fi

save_dir="not found"
save_user=""
best_save=""
save_any=""
save_any_user=""
save_su=""
save_su_user=""
while IFS= read -r r; do
	users="$r/steamapps/compatdata/996580/pfx/drive_c/users"
	if [ ! -d "$users" ]; then continue; fi
	for u in "$users"/*; do
		if [ ! -d "$u" ]; then continue; fi
		sd="$u/AppData/Local/Falcon/Saved/SaveGames"
		if [ ! -d "$sd" ]; then continue; fi
		name=$(basename "$u")
		if [ -z "$save_any" ]; then
			save_any=$sd
			save_any_user=$name
		fi
		if [ "$name" = steamuser ] && [ -z "$save_su" ]; then
			save_su=$sd
			save_su_user=$name
		fi
		for f in "$sd"/FalconSave.*.sav; do
			if [ ! -f "$f" ]; then continue; fi
			if [ -z "$best_save" ] || [ "$f" -nt "$best_save" ]; then
				best_save=$f
				save_user=$name
			fi
		done
	done
done < "$roots"
if [ -n "$best_save" ]; then
	save_dir=${best_save%/*}
elif [ -n "$save_su" ]; then
	save_dir=$save_su
	save_user=$save_su_user
elif [ -n "$save_any" ]; then
	save_dir=$save_any
	save_user=$save_any_user
fi

has_marker() { [ -f "$1/config.txt" ] || [ -f "$1/srtap_checkd.exe" ]; }

# Print the new-location bridge of a prefix: steamuser's (the account Steam runs
# games as), then any profile with bridge files, then the newest-save profile,
# then the first in lexical order.
new_bridge_for() {
	users="$1/steamapps/compatdata/996580/pfx/drive_c/users"
	if [ ! -d "$users" ]; then return 0; fi
	first=""
	marker=""
	steamuser_bridge=""
	for u in "$users"/*; do
		if [ ! -d "$u" ]; then continue; fi
		b="$u/AppData/Local/srtap_bridge"
		if [ ! -d "$b" ]; then continue; fi
		name=$(basename "$u")
		if [ -z "$first" ]; then first=$b; fi
		if [ "$name" = steamuser ] && [ -z "$steamuser_bridge" ]; then steamuser_bridge=$b; fi
		if has_marker "$b"; then
			if [ -z "$marker" ]; then marker=$b; fi
		fi
	done
	if [ -n "$steamuser_bridge" ]; then
		printf '%s\n' "$steamuser_bridge"
		return 0
	fi
	if [ -n "$marker" ]; then
		printf '%s\n' "$marker"
		return 0
	fi
	if [ -n "$save_user" ]; then
		b="$users/$save_user/AppData/Local/srtap_bridge"
		if [ -d "$b" ]; then
			printf '%s\n' "$b"
			return 0
		fi
	fi
	if [ -n "$first" ]; then printf '%s\n' "$first"; fi
	return 0
}

record_bridge() {
	if grep -Fqx -- "$1" "$bridges"; then return 0; fi
	printf '%s\n' "$1" >> "$bridges"
}

if [ -n "$bridge_override" ]; then
	if [ ! -d "$bridge_override" ]; then
		echo "bridge folder not found: $bridge_override" >&2
		exit 1
	fi
	printf '%s\n' "$(CDPATH= cd -- "$bridge_override" && pwd)" >> "$bridges"
else
	while IFS= read -r r; do
		newb=$(new_bridge_for "$r")
		legacy="$r/steamapps/compatdata/996580/pfx/drive_c/srtap_bridge"
		legacy_ok=0
		if [ -d "$legacy" ]; then legacy_ok=1; fi
		chosen=""
		if [ -n "$newb" ] && has_marker "$newb"; then
			chosen=$newb
		elif [ "$legacy_ok" = 1 ] && has_marker "$legacy"; then
			chosen=$legacy
		elif [ -n "$newb" ]; then
			chosen=$newb
		elif [ "$legacy_ok" = 1 ]; then
			chosen=$legacy
		fi
		if [ -z "$chosen" ]; then continue; fi
		record_bridge "$chosen"
		for b in "$r/steamapps/compatdata/996580/pfx/drive_c/users"/*/AppData/Local/srtap_bridge; do
			if [ ! -d "$b" ]; then continue; fi
			if [ "$b" = "$chosen" ]; then continue; fi
			record_bridge "$b"
		done
		if [ "$legacy_ok" = 1 ] && [ "$legacy" != "$chosen" ]; then record_bridge "$legacy"; fi
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

join_list() {
	awk 'NR > 1 { printf "; " } { printf "%s", $0 } END { printf "\n" }' "$1"
}
seed_line=$(join_list "$seeds")
root_line=$(join_list "$roots")

{
	printf '%s\n' 'Reignited AP support bundle'
	printf 'created: %s\n' "$created"
	printf 'os: %s\n' "$(uname -srm)"
	printf 'mod client_version: %s\n' "$version"
	printf 'steam roots: %s\n' "${seed_line:-not found}"
	printf 'libraries: %s\n' "${root_line:-not found}"
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
