// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-23

package main

import (
	"bufio"
	"os"
	"strconv"
	"strings"
)

// The AP session belongs to one in-game save. The mod writes session.txt into
// the bridge dir once the player is in play on a save it picked from the main
// menu, and deletes it when the game returns there; checkd idles without it.
const (
	sessionName  = "session.txt"
	gamesPerSlot = 3 // Spyro 1/2/3
	saveEntries  = 9 // saveDataMapArray: 3 in-game save slots x 3 games
)

type session struct {
	slot  int
	game  int
	token string // changes on every open, so reopening the same save re-baselines
}

// readSession parses session.txt (key=value lines: slot, game, token).
// A missing file or an invalid slot/game means no session.
func readSession(path string) (session, bool) {
	f, err := os.Open(path)
	if err != nil {
		return session{}, false
	}
	defer func() { _ = f.Close() }()
	s := session{slot: -1, game: -1}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		s.set(strings.TrimSpace(sc.Text()))
	}
	if s.slot < 0 || s.slot >= saveEntries/gamesPerSlot || s.game < 0 || s.game >= gamesPerSlot {
		return session{}, false
	}
	return s, true
}

// set applies one key=value line of session.txt, ignoring unknown keys and
// unparsable values.
func (s *session) set(line string) {
	key, val, found := strings.Cut(line, "=")
	if !found {
		return
	}
	val = strings.TrimSpace(val)
	switch strings.TrimSpace(key) {
	case "slot":
		assignInt(&s.slot, val)
	case "game":
		assignInt(&s.game, val)
	case "token":
		s.token = val
	}
}

// assignInt stores val in dst when it parses as an int.
func assignInt(dst *int, val string) {
	if n, err := strconv.Atoi(val); err == nil {
		*dst = n
	}
}

// entryIndex maps an in-game (slot, game) to its saveDataMapArray entry.
// Game-major: live-verified 2026-09-13 — a Spyro 1 New Game in save slot 1
// (slot.index=1, game.index=0) wrote entry 1, not entry 3.
func entryIndex(slot, game int) int {
	return game*gamesPerSlot + slot
}

// saveEntry returns one saveDataMapArray entry of a FalconSave blob, prefixed
// with the GVAS magic the scanners gate on. Each entry starts at its framed
// levelObjectMap property (the finder matches the property's structure, so a
// value that merely reads "levelObjectMap" is not mistaken for a tenth entry);
// the last entry ends at the globalFloatMap that follows the array. Any other
// entry count means an unknown layout.
func saveEntry(data []byte, idx int) ([]byte, bool) {
	starts := mapPropertyStarts(data, "levelObjectMap")
	if len(starts) != saveEntries || idx < 0 || idx >= saveEntries {
		return nil, false
	}
	start := starts[idx]
	end := len(data)
	if idx+1 < len(starts) {
		end = starts[idx+1]
	} else if tails := mapPropertyStarts(data, "globalFloatMap"); len(tails) > 0 && tails[0] >= start {
		end = tails[0]
	}
	out := make([]byte, 0, 4+end-start)
	out = append(out, "GVAS"...)
	return append(out, data[start:end]...), true
}
