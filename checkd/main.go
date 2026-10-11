// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-11

package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"time"
)

const (
	defaultSaveDir = "C:/users/steamuser/AppData/Local/Falcon/Saved/SaveGames"
	defaultDropDir = "C:/srtap_bridge"
	defaultLogPath = "C:/srtap_bridge/checkd.log"
	hbName         = "checkd.hb"
	dropName       = "checks.json"
	hbFreshSecs    = 3
)

func (d *daemon) writeHeartbeat() {
	path := filepath.Join(d.dropDir, hbName)
	if err := os.WriteFile(path, []byte(strconv.FormatInt(time.Now().Unix(), 10)), 0644); err != nil {
		d.logf("heartbeat write error: %v", err)
	}
}

func main() {
	saveDir := flag.String("save-dir", defaultSaveDir, "directory holding FalconSave.*.sav")
	dropDir := flag.String("drop-dir", defaultDropDir, "bridge directory for checks.json drops")
	poll := flag.Duration("poll", time.Second, "save poll interval")
	noBackfill := flag.Bool("no-backfill", false, "do not drop already-collected dragons and eggs at baseline")
	logPath := flag.String("log", defaultLogPath, "log file path (falls back to stderr if unwritable)")
	flag.Parse()

	if err := os.MkdirAll(*dropDir, 0755); err != nil {
		fmt.Fprintf(os.Stderr, "cannot create drop dir %s: %v\n", *dropDir, err)
		os.Exit(1)
	}

	var logWriter = os.Stderr
	if f, err := os.OpenFile(*logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644); err == nil {
		logWriter = f
	} else {
		fmt.Fprintf(os.Stderr, "log %s unwritable (%v); logging to stderr\n", *logPath, err)
	}
	logger := log.New(logWriter, "", log.LstdFlags)
	logf := func(format string, args ...any) { logger.Printf(format, args...) }

	nameToID, eggCatalog, levelGems, err := embeddedLocations()
	if err != nil {
		logf("FATAL: embedded locations.json: %v", err)
		os.Exit(1)
	}

	d := newDaemon(nameToID, eggCatalog, levelGems, logf)
	d.saveDir = *saveDir
	d.dropDir = *dropDir
	d.poll = *poll
	d.backfill = !*noBackfill

	hbPath := filepath.Join(*dropDir, hbName)
	if b, err := os.ReadFile(hbPath); err == nil {
		if secs, err := strconv.ParseInt(string(b), 10, 64); err == nil {
			if age := time.Now().Unix() - secs; age < hbFreshSecs {
				logf("another instance alive (heartbeat %ds old); exiting", age)
				os.Exit(0)
			}
		}
	}

	logf("checkd boot: save-dir=%s drop-dir=%s session=%s poll=%s backfill=%t log=%s locations=%d egg-regions=%d gem-regions=%d",
		*saveDir, *dropDir, sessionName, *poll, d.backfill, *logPath, len(nameToID), len(eggCatalog), len(levelGems))

	d.writeHeartbeat()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt)

	for {
		select {
		case <-sigCh:
			d.summary()
			return
		case <-time.After(d.poll):
		}
		d.writeHeartbeat()
		d.pollOnce()
	}
}
