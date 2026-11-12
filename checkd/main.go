// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-23

package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"time"
)

const (
	// protonSaveDir is the Falcon save folder inside the Proton compatdata
	// prefix on Linux, used when %LOCALAPPDATA% is unset.
	protonSaveDir = "C:/users/steamuser/AppData/Local/Falcon/Saved/SaveGames"
	// wineDrive is the root of the game's Wine drive. Wine resolves it inside
	// the prefix, so checkd can glob it without knowing the prefix.
	wineDrive       = "C:/"
	bridgeDirName   = "srtap_bridge"
	legacyBridgeDir = "C:/srtap_bridge"
	logFileName     = "checkd.log"
	hbName          = "checkd.hb"
	dropName        = "checks.json"
	hbFreshSecs     = 3
	// hbInterval writes the heartbeat twice per freshness window, so it can
	// never read as stale even when a poll overruns.
	hbInterval = time.Duration(hbFreshSecs) * time.Second / 2
)

// defaultSaveDir returns the Falcon save folder for this machine. On Windows
// that is %LOCALAPPDATA%\Falcon\Saved\SaveGames; Wine sets %LOCALAPPDATA% to
// the same prefix path, so a Proton install resolves identically. Without the
// variable the Wine drive is globbed, then the hardcoded prefix path is used.
func defaultSaveDir() string {
	if local := os.Getenv("LOCALAPPDATA"); local != "" {
		return filepath.Join(local, "Falcon", "Saved", "SaveGames")
	}
	return saveDirUnder(wineDrive)
}

// saveDirUnder returns the Falcon save folder of the user profile under base
// that holds the newest saves. The proton-fallback path is returned when no
// profile has a save.
func saveDirUnder(base string) string {
	pattern := filepath.Join(base, "users", "*", "AppData", "Local", "Falcon", "Saved", "SaveGames")
	dirs, _ := filepath.Glob(pattern)
	var newest string
	var newestTime time.Time
	for _, dir := range dirs {
		mod, ok := newestSaveTime(dir)
		if !ok || (newest != "" && !mod.After(newestTime)) {
			continue
		}
		newest, newestTime = dir, mod
	}
	if newest != "" {
		return newest
	}
	return protonSaveDir
}

// newestSaveTime returns the modification time of the newest save in dir.
func newestSaveTime(dir string) (time.Time, bool) {
	matches, err := filepath.Glob(filepath.Join(dir, "FalconSave.*.sav"))
	if err != nil {
		return time.Time{}, false
	}
	var newest time.Time
	for _, match := range matches {
		st, err := os.Stat(match)
		if err != nil {
			continue
		}
		if st.ModTime().After(newest) {
			newest = st.ModTime()
		}
	}
	return newest, !newest.IsZero()
}

// defaultDropDir returns the bridge folder to drop checks into, chosen by the
// bridge selection rule.
func defaultDropDir() string {
	return selectBridge(bridgeDirUnder(os.Getenv("LOCALAPPDATA")), legacyBridgeDir)
}

// bridgeDirUnder returns the modern bridge folder for a LOCALAPPDATA value, or
// "" when the variable is unset.
func bridgeDirUnder(localAppData string) string {
	if localAppData == "" {
		return ""
	}
	return filepath.Join(localAppData, bridgeDirName)
}

// selectBridge applies the bridge selection rule: the first candidate that
// already holds bridge files wins, and the modern folder wins otherwise. A
// missing modern candidate falls back to the legacy folder.
func selectBridge(newDir, legacyDir string) string {
	if newDir == "" {
		return legacyDir
	}
	if hasBridgeFiles(newDir) || !hasBridgeFiles(legacyDir) {
		return newDir
	}
	return legacyDir
}

// hasBridgeFiles reports whether dir already holds the bridge's config or
// binary.
func hasBridgeFiles(dir string) bool {
	for _, name := range []string{"config.txt", "srtap_checkd.exe"} {
		if _, err := os.Stat(filepath.Join(dir, name)); err == nil {
			return true
		}
	}
	return false
}

// defaultLogPath returns the daemon log beside the selected bridge folder.
func defaultLogPath() string {
	return filepath.Join(defaultDropDir(), logFileName)
}

func (d *daemon) writeHeartbeat() {
	path := filepath.Join(d.dropDir, hbName)
	if err := os.WriteFile(path, []byte(strconv.FormatInt(time.Now().Unix(), 10)), 0644); err != nil {
		d.logf("heartbeat write error: %v", err)
	}
}

func main() {
	o := parseFlags()
	if err := os.MkdirAll(o.dropDir, 0755); err != nil {
		fmt.Fprintf(os.Stderr, "cannot create drop dir %s: %v\n", o.dropDir, err)
		os.Exit(1)
	}
	d := startDaemon(o)
	d.run()
}

// options are the parsed command-line flags.
type options struct {
	saveDir, dropDir, logPath string
	poll                      time.Duration
	backfill                  bool
}

// parseFlags parses the command line into the daemon's options.
func parseFlags() options {
	saveDir := flag.String("save-dir", defaultSaveDir(), "directory holding FalconSave.*.sav")
	dropDir := flag.String("drop-dir", defaultDropDir(), "bridge directory for checks.json drops")
	poll := flag.Duration("poll", time.Second, "save poll interval")
	noBackfill := flag.Bool("no-backfill", false, "do not drop already-collected dragons and eggs at baseline")
	logPath := flag.String("log", defaultLogPath(), "log file path (falls back to stderr if unwritable)")
	flag.Parse()
	return options{saveDir: *saveDir, dropDir: *dropDir, logPath: *logPath, poll: *poll, backfill: !*noBackfill}
}

// startDaemon builds the daemon over the embedded tables, refuses to start
// beside a live instance, and logs the boot line.
func startDaemon(o options) *daemon {
	logf := newLogger(o.logPath)
	nameToID, eggCatalog, levelGems, err := embeddedLocations()
	if err != nil {
		logf("FATAL: embedded locations.json: %v", err)
		os.Exit(1)
	}
	d := newDaemon(nameToID, eggCatalog, levelGems, logf)
	d.saveDir, d.dropDir, d.poll, d.backfill = o.saveDir, o.dropDir, o.poll, o.backfill
	if age, alive := heartbeat(o.dropDir); alive {
		logf("another instance alive (heartbeat %ds old); exiting", age)
		os.Exit(0)
	}
	logf("checkd boot: save-dir=%s drop-dir=%s session=%s poll=%s backfill=%t log=%s locations=%d egg-regions=%d gem-regions=%d",
		o.saveDir, o.dropDir, sessionName, o.poll, d.backfill, o.logPath, len(nameToID), len(eggCatalog), len(levelGems))
	d.writeHeartbeat()
	return d
}

// newLogger returns the daemon's log function, falling back to stderr when the
// log file is unwritable.
func newLogger(path string) func(string, ...any) {
	var w io.Writer = os.Stderr
	if f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644); err == nil {
		w = f
	} else {
		fmt.Fprintf(os.Stderr, "log %s unwritable (%v); logging to stderr\n", path, err)
	}
	logger := log.New(w, "", log.LstdFlags)
	return func(format string, args ...any) { logger.Printf(format, args...) }
}

// heartbeat reports a previous instance's heartbeat age in seconds and whether
// it is still fresh.
func heartbeat(dropDir string) (int64, bool) {
	b, err := os.ReadFile(filepath.Join(dropDir, hbName))
	if err != nil {
		return 0, false
	}
	secs, err := strconv.ParseInt(string(b), 10, 64)
	if err != nil {
		return 0, false
	}
	age := time.Now().Unix() - secs
	return age, age < hbFreshSecs
}

// run polls the save folder and writes the heartbeat until interrupted.
func (d *daemon) run() {
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt)

	pollT := time.NewTicker(d.poll)
	hbT := time.NewTicker(hbInterval)
	defer pollT.Stop()
	defer hbT.Stop()

	for {
		select {
		case <-sigCh:
			d.summary()
			return
		case <-hbT.C:
			d.writeHeartbeat()
		case <-pollT.C:
			d.pollOnce()
		}
	}
}
