// Author: Tim Harrison
// Created: 2026-10-15

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// noticeName is the one-line player notice checkd writes into the bridge
// directory; the mod polls it and shows the text on the fanfare banner
// (srt_bridge/Scripts/checkd_notice.lua). The file states the current notice:
// {"text":""} means "no notice".
const noticeName = "checkd.status.json"

// noticeSaveScanFailed tells the player checkd cannot read the picked save's
// entry, so no checks will be sent for the whole session — otherwise silent.
const noticeSaveScanFailed = "Save Scanning Failed!"

// noticeLayoutErrs is how many consecutive unreadable entries it takes before
// the player is told. One failure is usually a mid-write save (the game
// rewrites the file constantly) and must not raise an alarm; a real format
// break fails every rewrite and clears this in a few seconds.
const noticeLayoutErrs = 3

type noticePayload struct {
	Text string `json:"text"`
}

// setNotice writes the current player notice ("" clears it), atomically. Only
// a change is written; checkd.log stays the durable record either way.
func (d *daemon) setNotice(text string) {
	if text == d.noticeText {
		return
	}
	d.noticeText = text
	b, err := json.Marshal(noticePayload{Text: text})
	if err != nil {
		d.logf("notice encode error: %v", err)
		return
	}
	tmp := filepath.Join(d.dropDir, noticeName+".tmp")
	if err := os.WriteFile(tmp, b, 0644); err != nil {
		d.logf("notice write error: %v", err)
		return
	}
	if err := os.Rename(tmp, filepath.Join(d.dropDir, noticeName)); err != nil {
		d.logf("notice rename error: %v", err)
		return
	}
	if text == "" {
		d.logf("notice cleared")
	} else {
		d.logf("notice: %s", text)
	}
}
