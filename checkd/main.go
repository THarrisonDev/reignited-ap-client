// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-12

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
	protonSaveDir  = "C:/users/steamuser/AppData/Local/Falcon/Saved/SaveGames"
	defaultDropDir = "C:/srtap_bridge"
	defaultLogPath = "C:/srtap_bridge/checkd.log"
	hbName         = "checkd.hb"
	dropName       = "checks.json"
	hbFreshSecs    = 3
	// hbInterval writes the heartbeat twice per freshness window, so it can
	// never read as stale even when a poll overruns.
	hbInterval = time.Duration(hbFreshSecs) * time.Second / 2
)

// defaultSaveDir returns the Falcon save folder for this machine. On Windows
// that is %LOCALAPPDATA%\Falcon\Saved\SaveGames; Wine sets %LOCALAPPDATA% to
// the same prefix path, so a Proton install resolves identically. The hardcoded
// prefix path is the fallback when the variable is unset.
func defaultSaveDir() string {
	if local := os.Getenv("LOCALAPPDATA"); local != "" {
		return filepath.Join(local, "Falcon", "Saved", "SaveGames")
	}
	return protonSaveDir
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
	dropDir := flag.String("drop-dir", defaultDropDir, "bridge directory for checks.json drops")
	poll := flag.Duration("poll", time.Second, "save poll interval")
	noBackfill := flag.Bool("no-backfill", false, "do not drop already-collected dragons and eggs at baseline")
	logPath := flag.String("log", defaultLogPath, "log file path (falls back to stderr if unwritable)")
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
