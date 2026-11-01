#!/bin/sh
# Author: Tim Harrison
# Created: 2026-11-01
# Updated: 2026-11-01

# Smoke test for install/collect-logs.sh against a fake Proton library.
# Run from the client repo root: sh tests/collect/test_collect_logs.sh
set -u

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
client=$(CDPATH= cd -- "$here/../.." && pwd)
collect="$client/install/collect-logs.sh"

root=$(mktemp -d "${TMPDIR:-/tmp}/collect-logs-test.XXXXXX")
trap 'rm -rf "$root"' EXIT INT TERM HUP

checks=0
fails=0
ok() {
	checks=$((checks + 1))
	if [ "$1" = 1 ]; then
		printf 'PASS %s\n' "$2"
	else
		fails=$((fails + 1))
		printf 'FAIL %s\n' "$2"
	fi
}
has() {
	case "$1" in
	*"$2"*) ok 1 "$3" ;;
	*) ok 0 "$3" ;;
	esac
}
hasnt() {
	case "$1" in
	*"$2"*) ok 0 "$3" ;;
	*) ok 1 "$3" ;;
	esac
}

home="$root/home"
steam="$root/steam"
prefix="$steam/steamapps/compatdata/996580"
bridge="$prefix/pfx/drive_c/srtap_bridge"
game="$steam/steamapps/common/Spyro Reignited Trilogy/Falcon/Binaries/Win64"
save="$prefix/pfx/drive_c/users/steamuser/AppData/Local/Falcon/Saved/SaveGames"
mkdir -p "$home" "$root/tmp" "$root/bin" "$bridge" "$game/Mods/srt_bridge/Scripts" "$save"

printf '#!/bin/sh\nexit 0\n' > "$root/bin/xdg-open"
chmod +x "$root/bin/xdg-open"
path="$root/bin:$PATH"

printf 'host=127.0.0.1:38281\nslot=SRTPlayer\npassword=hunter2\nspawn_checkd=1\n' > "$bridge/config.txt"
{
	awk 'BEGIN { print "FIRSTLINE"; for (i = 2; i < 5993; i++) print "line " i }'
	cat <<'EOF'
14:05:23 debug srt_bridge armed (host=127.0.0.1:38281 slot=SRTPlayer)
14:05:23 Pick New Game or Continue to connect to 127.0.0.1:38281
14:06:06 Save slot 2 picked (Spyro the Dragon): connecting to 127.0.0.1:38281 as SRTPlayer
14:06:06 debug AP client constructed (async thread) -> 127.0.0.1:38281
14:06:10 [FILLERS] configured: lives_granted=0 (C:/srtap_bridge/fillers_92420042017682081260_SRTPlayer.txt)
EOF
	printf 'retry wss://old.example.net:38281 as SomeoneElse\n'
	printf 'Save slot 3 picked\n'
	printf 'LASTLINE\n'
} > "$bridge/bridge.log"
printf 'checkd: scanning\ncheckd: idle\n' > "$bridge/checkd.log"
printf '{"state":"idle"}\n' > "$bridge/checkd.status.json"
printf '[]\n' > "$bridge/checks.json"
printf 'slot=1\ngame=0\ntoken=abc\n' > "$bridge/session.txt"
printf 'hb\n' > "$bridge/checkd.hb"

printf 'local client_version = { 9, 8, 7 }\n' > "$game/Mods/srt_bridge/Scripts/ap_client.lua"
printf 'Connected to ws://10.1.2.3:38281 as SRTPlayer\nretry ws://10.1.2.3:38281 as SRTPlayer\nTo Bob: Orb\n' > "$game/UE4SS.log"
printf 'not a real save\n' > "$save/FalconSave.1.sav"

members() {
	case "$1" in
	*.zip) unzip -Z1 "$1" ;;
	*) tar -tzf "$1" ;;
	esac
}
read_member() {
	case "$1" in
	*.zip) unzip -p "$1" "$2" ;;
	*) tar -xzOf "$1" "$2" ;;
	esac
}
member_path() {
	members "$1" | grep -F -- "/$2" | head -n 1
}

env PATH="$path" STEAM_ROOT="$steam" HOME="$home" TMPDIR="$root/tmp" sh "$collect" --out "$root/run1.zip" \
	>"$root/stdout1" 2>"$root/stderr1"
if [ $? -eq 0 ]; then ok 1 "collector exits 0 on a discovered library"; else ok 0 "collector exits 0 on a discovered library"; fi
out1=$(sed -n 1p "$root/stdout1")
if [ -n "$out1" ] && [ -f "$out1" ]; then ok 1 "archive written and named on stdout"; else ok 0 "archive written and named on stdout"; fi

list1=$(members "$out1")
for f in meta.txt bridge.log checkd.log UE4SS.log config.txt checkd.status.json checks.json session.txt checkd.hb srt_bridge-files.txt; do
	if [ -n "$(member_path "$out1" "$f")" ]; then ok 1 "archive contains $f"; else ok 0 "archive contains $f"; fi
done
hasnt "$list1" "FalconSave" "no save file anywhere in the archive"

blog=$(read_member "$out1" "$(member_path "$out1" bridge.log)")
n=$(printf '%s\n' "$blog" | wc -l)
if [ "$n" -eq 4000 ]; then ok 1 "bridge.log keeps the last 4000 lines"; else ok 0 "bridge.log keeps the last 4000 lines (got $n)"; fi
has "$blog" "LASTLINE" "bridge.log keeps the newest line"
hasnt "$blog" "FIRSTLINE" "bridge.log drops the first line"
hasnt "$blog" "127.0.0.1" "bridge.log keeps no configured host"
hasnt "$blog" "38281" "bridge.log keeps no configured port"
hasnt "$blog" "SRTPlayer" "bridge.log keeps no configured slot name"
has "$blog" "host=<redacted> slot=<redacted>" "bridge.log redacts the host/slot prose"
has "$blog" "as <redacted>" "bridge.log redacts the join line"
hasnt "$blog" "old.example.net" "bridge.log scrubs a stale wss:// address"
has "$blog" "Save slot 3 picked" "bridge.log keeps text that merely resembles the slot"

cfg=$(read_member "$out1" "$(member_path "$out1" config.txt)")
has "$cfg" "password=<redacted>" "config.txt redacts password"
has "$cfg" "host=<redacted>" "config.txt redacts host"
has "$cfg" "slot=<redacted>" "config.txt redacts slot"
has "$cfg" "spawn_checkd=1" "config.txt keeps spawn_checkd"

sess=$(read_member "$out1" "$(member_path "$out1" session.txt)")
has "$sess" "token=abc" "session.txt keeps token"
has "$sess" "slot=1" "session.txt keeps slot"

ue=$(read_member "$out1" "$(member_path "$out1" UE4SS.log)")
has "$ue" "ws://<redacted>" "UE4SS.log redacts the address"
has "$ue" "To <redacted>:" "UE4SS.log redacts peer names"
hasnt "$ue" "10.1.2.3" "UE4SS.log keeps no IP address"
hasnt "$ue" "SRTPlayer" "UE4SS.log keeps no player name"
hasnt "$ue" "Bob" "UE4SS.log keeps no peer name"

meta=$(read_member "$out1" "$(member_path "$out1" meta.txt)")
has "$meta" "mod client_version: client_version = { 9, 8, 7 }" "meta.txt records the mod version"
has "$meta" "bridge.log: 6000 lines" "meta.txt counts the bridge.log lines"
has "$meta" "checkd.log: 2 lines" "meta.txt counts the checkd.log lines"
hasnt "$meta" "all included" "meta.txt drops the old phrasing"
hasnt "$meta" "proton version" "meta.txt has no proton version"
hasnt "$meta" "prefix-" "meta.txt has no per-prefix parts"
has "$meta" "save files: not included" "meta.txt states save files are excluded"

files=$(read_member "$out1" "$(member_path "$out1" srt_bridge-files.txt)")
has "$files" "Scripts/ap_client.lua" "srt_bridge-files.txt lists the mod scripts"

home2="$root/home-empty"
mkdir -p "$home2"
env -u STEAM_ROOT PATH="$path" HOME="$home2" TMPDIR="$root/tmp" sh "$collect" --bridge-dir "$bridge" --out "$root/run2.zip" \
	>"$root/stdout2" 2>"$root/stderr2"
if [ $? -eq 0 ]; then ok 1 "--bridge-dir overrides discovery"; else ok 0 "--bridge-dir overrides discovery"; fi
out2=$(sed -n 1p "$root/stdout2")
if [ -n "$out2" ] && [ -f "$out2" ]; then ok 1 "override run writes an archive"; else ok 0 "override run writes an archive"; fi

home3="$root/home-nothing"
mkdir -p "$home3"
env -u STEAM_ROOT PATH="$path" HOME="$home3" TMPDIR="$root/tmp" sh "$collect" --out "$root/run3.zip" \
	>"$root/stdout3" 2>"$root/stderr3"
rc=$?
if [ "$rc" -ne 0 ]; then ok 1 "nothing found exits non-zero"; else ok 0 "nothing found exits non-zero"; fi
has "$(cat "$root/stderr3")" "--bridge-dir" "nothing found points at --bridge-dir"
if [ -f "$root/run3.zip" ] || [ -f "$root/run3.zip.tar.gz" ]; then ok 0 "nothing found writes no archive"; else ok 1 "nothing found writes no archive"; fi

steam2="$root/steam2"
bridge2="$steam2/steamapps/compatdata/996580/pfx/drive_c/srtap_bridge"
mkdir -p "$bridge2" "$steam/steamapps"
printf 'second\n' > "$bridge2/bridge.log"
printf '"libraryfolders"\n{\n\t"1"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n}\n' "$steam2" > "$steam/steamapps/libraryfolders.vdf"
env PATH="$path" STEAM_ROOT="$steam" HOME="$home" TMPDIR="$root/tmp" sh "$collect" --out "$root/run4.zip" \
	>"$root/stdout4" 2>"$root/stderr4"
out4=$(sed -n 1p "$root/stdout4")
meta4=$(read_member "$out4" "$(member_path "$out4" meta.txt)")
has "$meta4" "other bridge folders: $bridge2" "meta.txt names the other bridge folders"
if [ "$(members "$out4" | grep -c 'prefix-')" -eq 0 ]; then ok 1 "one flat archive folder"; else ok 0 "one flat archive folder"; fi

env PATH="$path" STEAM_ROOT="$steam" HOME="$home" TMPDIR="$root/tmp" sh "$collect" --help \
	>"$root/stdout5" 2>"$root/stderr5"
if [ $? -eq 0 ]; then ok 1 "--help exits 0"; else ok 0 "--help exits 0"; fi
has "$(cat "$root/stdout5")" "--bridge-dir" "--help lists --bridge-dir"
hasnt "$(cat "$root/stdout5")" "--last" "--help no longer lists --last"

printf '%d/%d passed\n' $((checks - fails)) "$checks"
if [ "$fails" -ne 0 ]; then exit 1; fi
exit 0
