package main

import (
	"bufio"
	"bytes"
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
		key, val, found := strings.Cut(strings.TrimSpace(sc.Text()), "=")
		if !found {
			continue
		}
		val = strings.TrimSpace(val)
		switch strings.TrimSpace(key) {
		case "slot":
			if n, err := strconv.Atoi(val); err == nil {
				s.slot = n
			}
		case "game":
			if n, err := strconv.Atoi(val); err == nil {
				s.game = n
			}
		case "token":
			s.token = val
		}
	}
	if s.slot < 0 || s.slot >= saveEntries/gamesPerSlot || s.game < 0 || s.game >= gamesPerSlot {
		return session{}, false
	}
	return s, true
}

// entryIndex maps an in-game (slot, game) to its saveDataMapArray entry.
// Game-major: live-verified 2026-09-13 — a Spyro 1 New Game in save slot 1
// (slot.index=1, game.index=0) wrote entry 1, not entry 3.
func entryIndex(slot, game int) int {
	return game*gamesPerSlot + slot
}

// saveEntry returns one saveDataMapArray entry of a FalconSave blob, prefixed
// with the GVAS magic the scanners gate on. Each entry starts at its
// levelObjectMap property name; the last one ends at the globalFloatMap that
// follows the array. Any other levelObjectMap count means an unknown layout.
func saveEntry(data []byte, idx int) ([]byte, bool) {
	starts := findAll(data, []byte("levelObjectMap"))
	if len(starts) != saveEntries || idx < 0 || idx >= saveEntries {
		return nil, false
	}
	start, end := starts[idx], len(data)
	if idx+1 < len(starts) {
		end = starts[idx+1]
	} else if g := bytes.Index(data[start:], []byte("globalFloatMap")); g >= 0 {
		end = start + g
	}
	out := make([]byte, 0, 4+end-start)
	out = append(out, "GVAS"...)
	return append(out, data[start:end]...), true
}
