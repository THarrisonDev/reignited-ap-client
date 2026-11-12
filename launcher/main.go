// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-11-11

package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"html/template"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

//go:embed index.html
var indexHTML string

//go:embed htmx.min.js
var htmxJS []byte

type server struct {
	mu           sync.Mutex
	paths        Paths
	autoConfig   bool // ConfigDir is auto-detected; see loadPaths
	autoGame     bool // GameWin64 is auto-detected; see loadPaths
	tmpl         *template.Template
	feed         *Feed
	token        string // per-run CSRF token; see checkCSRF
	installing   bool   // an install run is in flight; see handleApply
	collectorDir string // where collect-logs.{sh,bat} lives; see handleLogs
}

type view struct {
	Paths      Paths
	Token      string
	Host       string
	Slot       string
	Password   string
	Checks     []Check
	AllOK      bool
	Flash      string
	Feed       feedView
	Hints      hintView
	Install    []installResult
	ConfigAuto bool     // show "(auto-detected)" by the Bridge folder
	GameAuto   bool     // show "(auto-detected)" by the Game folder
	Discovery  []string // what detection found, one short line per item
	Linux      bool     // show the Proton launch-option note
	NextTab    string   // tab the page should switch to; empty to stay put
}

// hintView is the hint panel: the slot's point balance, the price of one hint,
// the hints it already holds, and the names the hint form offers.
type hintView struct {
	Connected   bool
	PointsKnown bool // the room has reported a balance
	Points      int
	Cost        int
	Free        bool // a hint costs nothing, so asking needs no confirmation
	Hints       []feedHint
	Missing     []string
	Items       []string
	Notice      string
}

// hintResults is the hint form's suggestion fragment for one field: the names
// one search offers, capped, or the one-line state saying why it offers none.
type hintResults struct {
	Field  string // "location" or "item"
	Param  string // the input name the query arrived in: loc_name or item_name
	Query  string
	Shown  []string
	Total  int
	Capped bool
	Cost   int
	Free   bool
	Prompt string
}

// newToken returns a random per-run CSRF token. The launcher is a local web UI
// that writes config and installs files, so a page the player visits must not
// be able to drive it (a plain GET or a cross-site form post).
func newToken() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		log.Fatalf("generate CSRF token: %v", err)
	}
	return hex.EncodeToString(b)
}

// checkCSRF reports whether the request carries this run's token, compared in
// constant time. The token is a hidden field of both POST forms; the HTMX
// buttons include #cfg, so their posts carry it too.
func (s *server) checkCSRF(r *http.Request) bool {
	got := r.FormValue("csrf")
	if s.token == "" || got == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(got), []byte(s.token)) == 1
}

func (s *server) configPath() string {
	return filepath.Join(s.paths.ConfigDir, "config.txt")
}

// readConn is what the feed connects with: config.txt as last saved. An
// unreadable config yields the same blank connection the feed idles on.
func (s *server) readConn() (feedConn, error) {
	cfg, err := ReadConfig(s.configPath())
	if err != nil {
		return feedConn{Host: defaultHost}, err
	}
	return feedConn{
		Host:     cfg.Get("host", defaultHost),
		Slot:     cfg.Get("slot", ""),
		Password: cfg.Get("password", ""),
	}, nil
}

// buildView reads current config + verify results into the template model.
// config.txt is the source of truth for host/slot/password; the launcher's own
// folders and their auto flags are held in s.paths/s.autoConfig/s.autoGame.
// install carries the step log of a just-run install (nil for a plain page
// load).
func (s *server) buildView(flash string, install []installResult) view {
	conn, err := s.readConn()
	if err != nil {
		flash = strings.TrimSpace(flash + "  (couldn't read config.txt: " + err.Error() + ")")
	}

	slot := conn.Slot
	if slot == "" {
		slot = defaultSlot
	}
	checks := Verify(s.paths)
	return view{
		Paths:      s.paths,
		Token:      s.token,
		Host:       conn.Host,
		Slot:       slot,
		Password:   conn.Password,
		Checks:     checks,
		AllOK:      AllOK(checks),
		Flash:      strings.TrimSpace(flash),
		Feed:       s.feed.View(),
		Hints:      s.feed.HintView(),
		Install:    install,
		ConfigAuto: s.autoConfig,
		GameAuto:   s.autoGame,
		Discovery:  discoveryLines(),
		Linux:      runtime.GOOS != "windows",
	}
}

// discoveryLines summarizes what detection found for the page: the Steam roots,
// libraries, game, prefix and chosen bridge, one short line each so the player
// can copy them into a support report.
func discoveryLines() []string {
	d := discover()
	lines := []string{
		joinList("Steam roots", d.Roots),
		joinList("Libraries", d.Libraries),
		joinList("Game", []string{d.GameWin64}),
	}
	if d.Prefix != "" {
		lines = append(lines, "Prefix: "+d.Prefix)
	} else {
		lines = append(lines, "Prefix: none — "+d.Note)
	}
	return append(lines, joinList("Bridge", []string{defaultPaths().ConfigDir}))
}

// joinList renders "Label: a, b", dropping empty entries; "Label: none" when
// nothing was found.
func joinList(label string, vals []string) string {
	var kept []string
	for _, v := range vals {
		if v != "" {
			kept = append(kept, v)
		}
	}
	if len(kept) == 0 {
		return label + ": none"
	}
	return label + ": " + strings.Join(kept, ", ")
}

func (s *server) handleRoot(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	flash := ""
	// read-only marker left by handleReset's redirect; never mutates state.
	if r.URL.Query().Get("flash") == "reset" {
		flash = "Folders reset to auto-detected."
		if msg := r.URL.Query().Get("err"); msg != "" {
			flash += " (couldn't remember this: " + msg + ")"
		}
	}
	if err := s.tmpl.ExecuteTemplate(w, "page", s.buildView(flash, nil)); err != nil {
		log.Printf("template execute: %v", err)
	}
}

// requirePost refuses anything that is not a POST carrying a valid CSRF token,
// answering the request itself when it does. A state-changing endpoint must
// check this first: without it the query string alone could install or launch.
func (s *server) requirePost(w http.ResponseWriter, r *http.Request) bool {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return false
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad form", http.StatusBadRequest)
		return false
	}
	if !s.checkCSRF(r) {
		http.Error(w, "bad or missing token — reload the launcher page", http.StatusForbidden)
		return false
	}
	return true
}

// handleReset re-detects folders and forgets any saved overrides, so both
// fields go back to auto. POST only; any posted fields are ignored. It
// redirects to the full page so the path fields re-render with the defaults.
func (s *server) handleReset(w http.ResponseWriter, r *http.Request) {
	if !s.requirePost(w, r) {
		return
	}
	s.mu.Lock()
	s.autoConfig, s.autoGame = true, true
	s.paths = defaultPaths()
	err := savePaths(s.paths, true, true)
	s.mu.Unlock()
	target := "/?flash=reset"
	if err != nil {
		target += "&err=" + url.QueryEscape(err.Error())
	}
	http.Redirect(w, r, target, http.StatusSeeOther)
}

// handleApply applies path overrides + config edits (and optionally launches),
// answering with the "apply" fragment: refreshed setup checks for #panel, and the
// flash as an out-of-band swap so it shows on whichever tab the player is on.
func (s *server) handleApply(w http.ResponseWriter, r *http.Request) {
	if !s.requirePost(w, r) {
		return
	}
	action := r.FormValue("action")
	paths, saveErr := s.applyPathOverrides(r)

	var flash, nextTab string
	var install []installResult
	switch action {
	case "recheck":
		flash = "Setup re-checked."
	case "install":
		var err error
		install, flash, err = s.installAction(paths)
		saveErr = firstError(saveErr, err)
	case "save", "launch":
		flash, nextTab = s.applyConnection(r, action == "launch")
	default:
		flash = "Unknown action."
	}
	if saveErr != nil {
		flash += " (couldn't remember folder overrides: " + saveErr.Error() + ")"
	}

	s.mu.Lock()
	panel := s.buildView(flash, install)
	s.mu.Unlock()
	panel.NextTab = nextTab
	if err := s.tmpl.ExecuteTemplate(w, "apply", panel); err != nil {
		log.Printf("apply execute: %v", err)
	}
}

// installAction runs one install and adopts the folders it used. Install runs
// WITHOUT the lock: the UE4SS download takes minutes and the feed goroutine must
// keep answering the page while it does. It returns the step log, the flash text
// and a state-save error (nil when the run could not start).
func (s *server) installAction(paths Paths) ([]installResult, string, error) {
	if !s.tryStartInstall() {
		return nil, "An install is already running — wait for it to finish.", nil
	}
	install, effective := Install(paths, sourceDir(), installOptions{})
	s.finishInstall()
	return install, summarizeInstall(install), s.adoptInstallPaths(effective)
}

// adoptInstallPaths stores the folders an install wrote to and saves them with
// the current auto flags, so the UI and later config writes follow a bridge
// folder the install migrated.
func (s *server) adoptInstallPaths(effective Paths) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.paths = effective
	return savePaths(s.paths, s.autoConfig, s.autoGame)
}

// firstError returns a when it is set, else b, so the flash names the first
// failure without repeating either.
func firstError(a, b error) error {
	if a != nil {
		return a
	}
	return b
}

// applyPathOverrides merges the posted folders into the launcher's own state,
// persists them so they survive a restart, and returns the paths the action
// should use. A posted value equal to what the page rendered keeps that field's
// auto flag; a different value makes it an explicit override. Auto fields are
// re-detected, with the bridge following the game folder so a fixed Game folder
// still resolves to the right Proton prefix on Linux.
func (s *server) applyPathOverrides(r *http.Request) (Paths, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if v := strings.TrimSpace(r.FormValue("config_dir")); v != "" && !samePath(v, s.paths.ConfigDir) {
		s.paths.ConfigDir, s.autoConfig = v, false
	}
	if v := strings.TrimSpace(r.FormValue("game_win64")); v != "" && !samePath(v, s.paths.GameWin64) {
		s.paths.GameWin64, s.autoGame = v, false
	}
	base := defaultPaths()
	if s.autoGame {
		s.paths.GameWin64 = base.GameWin64
	}
	if s.autoConfig {
		if bridge, ready := bridgeForGameWin64(s.paths.GameWin64); bridge != "" {
			s.paths.ConfigDir, s.paths.PrefixReady = bridge, ready
		} else {
			s.paths.ConfigDir, s.paths.PrefixReady = base.ConfigDir, base.PrefixReady
		}
	}
	return s.paths, savePaths(s.paths, s.autoConfig, s.autoGame)
}

// tryStartInstall claims the single install slot, reporting false when an
// install is already running.
func (s *server) tryStartInstall() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.installing {
		return false
	}
	s.installing = true
	return true
}

// finishInstall releases the install slot.
func (s *server) finishInstall() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.installing = false
}

// summarizeInstall is the one-line flash shown above the refreshed setup
// checks after an install run.
func summarizeInstall(results []installResult) string {
	failed := 0
	for _, r := range results {
		if !r.OK {
			failed++
		}
	}
	if failed == 0 {
		return "Install complete — setup checks refreshed below."
	}
	return fmt.Sprintf("Install finished, but %d step(s) still need attention.", failed)
}

// applyConnection merges the posted host/slot/password into config.txt and
// returns the flash text plus the tab to show next (empty to stay put). It never
// rewrites a config.txt it could not read, so keys the launcher does not manage
// are preserved. When launch is set it also starts the game through Steam.
func (s *server) applyConnection(r *http.Request, launch bool) (string, string) {
	if msg, handled := s.deferWithoutPrefix(launch); handled {
		return msg, ""
	}
	msg, written := s.writeConnection(r)
	if !written || !launch {
		return msg, ""
	}
	return launchAfterSave()
}

// deferWithoutPrefix reports the flash text and handled=true when the bridge
// folder is unknown or, on Linux, sits above a Proton prefix the game has not
// created yet. Saving then would fabricate the prefix, so it only offers the
// launch-once guidance; launching stays available to create it.
func (s *server) deferWithoutPrefix(launch bool) (string, bool) {
	if s.paths.ConfigDir == "" {
		return "No bridge folder is known yet — set the Bridge folder under Folder locations, then save.", true
	}
	if runtime.GOOS == "windows" || s.paths.PrefixReady || dirExists(filepath.Dir(s.paths.ConfigDir)) {
		return "", false
	}
	if !launch {
		return "Not saved yet: launch the game once through Steam so it creates the Proton prefix, then click Save again.", true
	}
	if err := launchGame(); err != nil {
		return "Launching the game failed: " + err.Error() + " — start it from Steam once, then save your config.", true
	}
	return "Launching Spyro… the first run creates the Proton prefix; after you pick a save, click Save & launch again to store your connection.", true
}

// writeConnection reads config.txt, merges the posted connection fields and
// writes it back, reporting whether the file was written.
func (s *server) writeConnection(r *http.Request) (string, bool) {
	cfg, err := ReadConfig(s.configPath())
	if err != nil {
		return "Could not read config.txt, so it was left unchanged: " + err.Error(), false
	}
	host := normalizeHost(r.FormValue("host"))
	if host == "" {
		host = defaultHost
	}
	cfg.Set("host", host)
	cfg.Set("slot", strings.TrimSpace(r.FormValue("slot")))
	cfg.Set("password", r.FormValue("password"))
	// keep the keys the launcher doesn't manage sensible if fresh
	if cfg.Get("spawn_checkd", "") == "" {
		cfg.Set("spawn_checkd", "1")
	}
	if err := cfg.Write(s.configPath()); err != nil {
		return "Could not write config.txt: " + err.Error(), false
	}
	return "Config saved to " + s.configPath(), true
}

// launchAfterSave starts the game once the config is on disk and moves the page
// to the Play tab, where checks arrive. A launch failure keeps the player on
// Setup with the error, since that is where it gets fixed.
func launchAfterSave() (string, string) {
	if err := launchGame(); err != nil {
		return "Config saved, but launching the game failed: " + err.Error(), ""
	}
	return "Config saved. Launching Spyro…", "play"
}

func (s *server) handleHTMX(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/javascript")
	_, _ = w.Write(htmxJS)
}

// handleFeed returns the live check list fragment the page polls.
func (s *server) handleFeed(w http.ResponseWriter, r *http.Request) {
	if err := s.tmpl.ExecuteTemplate(w, "feed", s.feed.View()); err != nil {
		log.Printf("feed execute: %v", err)
	}
}

// handleHints returns the hint panel fragment the page polls.
func (s *server) handleHints(w http.ResponseWriter, r *http.Request) {
	s.renderHints(w)
}

// renderHints writes the hint panel fragment that both hint endpoints answer
// with.
func (s *server) renderHints(w http.ResponseWriter) {
	if err := s.tmpl.ExecuteTemplate(w, "hints", s.feed.HintView()); err != nil {
		log.Printf("hints execute: %v", err)
	}
}

// errNoHintName is the notice for a hint request with no name to look up.
var errNoHintName = errors.New("pick a name from the list first")

// hintResultCap is how many suggestions one search shows.
const hintResultCap = 20

// handleHintSearch renders the suggestion list for one hint field, reading the
// feed per request so an early page load still finds the names.
func (s *server) handleHintSearch(w http.ResponseWriter, r *http.Request) {
	field, param := hintField(r.FormValue("field"))
	res := buildHintResults(field, param, strings.TrimSpace(r.FormValue(param)), s.feed.HintView())
	if err := s.tmpl.ExecuteTemplate(w, "hintResults", res); err != nil {
		log.Printf("hint search execute: %v", err)
	}
}

// hintField maps a search's field to its hint kind and the input name its query
// arrives in. Anything but "item" searches the slot's unchecked locations.
func hintField(field string) (kind, param string) {
	if field == "item" {
		return "item", "item_name"
	}
	return "location", "loc_name"
}

// buildHintResults picks the names one search offers: the view's own order,
// capped, with the state line set when it offers none.
func buildHintResults(field, param, q string, v hintView) hintResults {
	res := hintResults{Field: field, Param: param, Query: q, Cost: v.Cost, Free: v.Free}
	if q == "" {
		res.Prompt = "Type a few letters to search."
		return res
	}
	if !v.Connected {
		res.Prompt = "Waiting for the server."
		return res
	}
	names := v.Missing
	if field == "item" {
		names = v.Items
	}
	matches := containing(names, q)
	res.Total = len(matches)
	if res.Total == 0 {
		res.Prompt = fmt.Sprintf("no match for %q", q)
		return res
	}
	res.Shown = spread(matches)
	res.Shown = res.Shown[:min(len(res.Shown), hintResultCap)]
	res.Capped = res.Total > hintResultCap
	return res
}

// spread interleaves matches that share a parent (the text before a name's last
// colon), so a capped list covers every game and level, not one family of them.
func spread(names []string) []string {
	var order []string
	buckets := map[string][]string{}
	for _, n := range names {
		key := n
		if i := strings.LastIndex(n, ":"); i >= 0 {
			key = n[:i]
		}
		if _, seen := buckets[key]; !seen {
			order = append(order, key)
		}
		buckets[key] = append(buckets[key], n)
	}
	out := make([]string, 0, len(names))
	for round := 0; len(out) < len(names); round++ {
		for _, key := range order {
			if round < len(buckets[key]) {
				out = append(out, buckets[key][round])
			}
		}
	}
	return out
}

// containing returns the names holding q, ignoring case.
func containing(names []string, q string) []string {
	needle := strings.ToLower(q)
	out := make([]string, 0, len(names))
	for _, n := range names {
		if strings.Contains(strings.ToLower(n), needle) {
			out = append(out, n)
		}
	}
	return out
}

// handleHint turns a posted name into the server's chat hint command and hands
// it to the live connection; the server's answer arrives later as a notice.
func (s *server) handleHint(w http.ResponseWriter, r *http.Request) {
	if !s.requirePost(w, r) {
		return
	}
	cmd := hintCommand(r.FormValue("kind"), hintName(r, "loc_name"), hintName(r, "item_name"))
	if cmd == "" {
		s.feed.SetNotice(errNoHintName.Error())
	} else if err := s.feed.RequestHint(cmd); err != nil {
		s.feed.SetNotice(err.Error())
	}
	s.renderHints(w)
}

// hintName reads one hint name, letting a result button's query string win over
// the partial text the form's input still holds.
func hintName(r *http.Request, key string) string {
	if v := r.URL.Query().Get(key); v != "" {
		return v
	}
	return r.FormValue(key)
}

// hintCommand builds the chat command for one hint request: a location in the
// player's own world, or an item they can receive in any world. It returns an
// empty command when no name was typed.
func hintCommand(kind, loc, item string) string {
	switch kind {
	case "location":
		if name := strings.TrimSpace(loc); name != "" {
			return "!hint_location " + name
		}
	case "item":
		if name := strings.TrimSpace(item); name != "" {
			return "!hint " + name
		}
	}
	return ""
}

// currentConn reads the saved connection under the lock, for the feed goroutine.
func (s *server) currentConn() feedConn {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, _ := s.readConn()
	return c
}

// launchGame asks Steam to run the game via the steam:// protocol handler,
// which works the same on Linux and Windows. A variable so tests can stub it.
var launchGame = func() error {
	return openURL("steam://rungameid/" + appID)
}

// openURL opens a URL/URI with the host OS's default handler.
func openURL(u string) error {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", u)
	case "darwin":
		cmd = exec.Command("open", u)
	default:
		cmd = exec.Command("xdg-open", u)
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	// reap the child once it exits, or it stays a zombie for the launcher's life
	go func() { _ = cmd.Wait() }()
	return nil
}

// localOnly rejects requests whose Host is not loopback. The launcher listens
// on 127.0.0.1 by default; without this, a page the player visits could reach
// it by resolving a domain to 127.0.0.1 (DNS rebinding). A non-loopback -addr
// disables the check, since then accepting remote hosts is the point.
func localOnly(next http.Handler, enabled bool) http.Handler {
	if !enabled {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Frame-Options", "DENY")
		if !isLoopbackHost(r.Host) {
			http.Error(w, "forbidden host", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// isLoopbackHost reports whether a request Host ("name" or "name:port") is loopback.
func isLoopbackHost(hostport string) bool {
	host := hostport
	if h, _, err := net.SplitHostPort(hostport); err == nil {
		host = h
	}
	return isLoopbackName(host)
}

// isLoopbackAddr reports whether a listen address binds loopback only.
func isLoopbackAddr(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		host = addr
	}
	return isLoopbackName(host)
}

func isLoopbackName(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// launcherStateFile is where path overrides persist between runs. A variable
// so tests can point it away from the real user config dir.
var launcherStateFile = defaultStateFile

func defaultStateFile() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		return ""
	}
	return filepath.Join(dir, "srtap-launcher", "paths.json")
}

// savedPaths is the launcher's persisted folder state. A nil auto flag marks an
// older file written before flags existed; loadPaths then infers the flag from
// the value.
type savedPaths struct {
	ConfigDir  string `json:"config_dir"`
	GameWin64  string `json:"game_win64"`
	ConfigAuto *bool  `json:"config_dir_auto,omitempty"`
	GameAuto   *bool  `json:"game_win64_auto,omitempty"`
}

// loadPaths returns the folders to use and whether each is auto-detected. Auto
// folders are re-detected on every start; an older state file without flags is
// auto when its value matches the current detection (or is empty), and an
// override otherwise. A missing or unreadable file leaves both auto.
func loadPaths() (p Paths, autoConfig, autoGame bool) {
	base := defaultPaths()
	p = base
	f := launcherStateFile()
	if f == "" {
		return p, true, true
	}
	b, err := os.ReadFile(f)
	if err != nil {
		return p, true, true
	}
	var saved savedPaths
	if json.Unmarshal(b, &saved) != nil {
		return p, true, true
	}
	saved = withLegacyFields(b, saved)
	autoConfig = autoFlag(saved.ConfigAuto, saved.ConfigDir, base.ConfigDir)
	autoGame = autoFlag(saved.GameAuto, saved.GameWin64, base.GameWin64)
	if !autoConfig && saved.ConfigDir != "" {
		p.ConfigDir = saved.ConfigDir
	}
	if !autoGame && saved.GameWin64 != "" {
		p.GameWin64 = saved.GameWin64
	}
	return p, autoConfig, autoGame
}

// withLegacyFields fills an empty savedPaths from the state file the releases
// before the auto flags wrote, which marshalled Paths under its Go field names.
func withLegacyFields(b []byte, saved savedPaths) savedPaths {
	if saved.ConfigDir != "" || saved.GameWin64 != "" {
		return saved
	}
	var legacy Paths
	if json.Unmarshal(b, &legacy) == nil {
		saved.ConfigDir, saved.GameWin64 = legacy.ConfigDir, legacy.GameWin64
	}
	return saved
}

// autoFlag resolves one field's auto flag: an explicit flag wins, otherwise a
// saved value matching the current detection (or empty) counts as auto.
func autoFlag(saved *bool, value, detected string) bool {
	if saved != nil {
		return *saved
	}
	return value == "" || samePath(value, detected)
}

// savePaths persists the folders and their auto flags.
func savePaths(p Paths, autoConfig, autoGame bool) error {
	f := launcherStateFile()
	if f == "" {
		return errors.New("no user config dir")
	}
	if err := os.MkdirAll(filepath.Dir(f), 0755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(savedPaths{
		ConfigDir:  p.ConfigDir,
		GameWin64:  p.GameWin64,
		ConfigAuto: &autoConfig,
		GameAuto:   &autoGame,
	}, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(f, b, 0644)
}

// runInstall performs a headless install using the resolved paths and prints
// one line per step. It returns a process exit code.
func runInstall(noDownload bool) int {
	p, autoConfig, autoGame := loadPaths()
	results, effective := Install(p, sourceDir(), installOptions{NoDownload: noDownload})
	if !samePath(effective.ConfigDir, p.ConfigDir) {
		if err := savePaths(effective, autoConfig, autoGame); err != nil {
			fmt.Printf("(couldn't remember the migrated Bridge folder: %v)\n", err)
		}
	}
	ok := true
	for _, r := range results {
		mark := "ok  "
		if !r.OK {
			mark = "FAIL"
			ok = false
		}
		fmt.Printf("[%s] %s: %s\n", mark, r.Step, r.Detail)
	}
	if !ok {
		fmt.Println("Some steps failed — open the launcher to re-check setup.")
		return 1
	}
	fmt.Println("Install complete. Open the launcher to set your connection and play.")
	return 0
}

// detectReport renders what detection found from the filesystem: the host OS,
// every Steam root and library, the game, every usable prefix with its bridge
// and evidence times, the chosen prefix, and the resolved folders with their
// auto flags. It creates nothing.
func detectReport() string {
	d := discover()
	p, autoConfig, autoGame := loadPaths()
	var b strings.Builder
	fmt.Fprintf(&b, "os: %s\n", runtime.GOOS)
	for _, root := range d.Roots {
		fmt.Fprintf(&b, "steam root: %s\n", root)
	}
	for _, lib := range d.Libraries {
		fmt.Fprintf(&b, "library: %s\n", lib)
	}
	if d.GameWin64 == "" {
		b.WriteString("game: not found\n")
	} else {
		fmt.Fprintf(&b, "game: %s\n", d.GameWin64)
	}
	for _, pf := range d.Prefixes {
		fmt.Fprintf(&b, "prefix: %s bridge=%s log=%d save=%d\n",
			pf.prefixDir(), pf.Bridge, pf.LogTime, pf.SaveTime)
	}
	if d.Prefix == "" {
		fmt.Fprintf(&b, "chosen prefix: none (%s)\n", d.Note)
	} else {
		fmt.Fprintf(&b, "chosen prefix: %s\n", d.Prefix)
	}
	fmt.Fprintf(&b, "config dir: %s (auto=%v)\n", p.ConfigDir, autoConfig)
	fmt.Fprintf(&b, "game win64: %s (auto=%v)\n", p.GameWin64, autoGame)
	return b.String()
}

func main() {
	addr := flag.String("addr", "127.0.0.1:0", "listen address (default: random localhost port)")
	noBrowser := flag.Bool("no-browser", false, "do not open a browser automatically")
	install := flag.Bool("install", false, "copy the client files into place, then exit")
	noDownload := flag.Bool("no-download", false, "with -install, do not fetch UE4SS; report it missing")
	detect := flag.Bool("detect", false, "print the detected Steam, game, prefix and bridge paths, then exit")
	flag.Parse()

	if *detect {
		fmt.Print(detectReport())
		os.Exit(0)
	}
	if *install {
		os.Exit(runInstall(*noDownload))
	}

	tmpl, err := template.New("index").Parse(indexHTML)
	if err != nil {
		log.Fatalf("parse template: %v", err)
	}

	paths, autoConfig, autoGame := loadPaths()
	s := &server{paths: paths, autoConfig: autoConfig, autoGame: autoGame,
		tmpl: tmpl, feed: NewFeed(), token: newToken(), collectorDir: "."}
	if exe, err := os.Executable(); err == nil {
		s.collectorDir = filepath.Dir(exe)
	}
	go s.feed.Run(context.Background(), s.currentConn)

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatalf("listen on %s: %v", *addr, err)
	}
	uiURL := "http://" + ln.Addr().String()

	mux := http.NewServeMux()
	mux.HandleFunc("/", s.handleRoot)
	mux.HandleFunc("/apply", s.handleApply)
	mux.HandleFunc("/reset", s.handleReset)
	mux.HandleFunc("/htmx.min.js", s.handleHTMX)
	mux.HandleFunc("/feed", s.handleFeed)
	mux.HandleFunc("/hints", s.handleHints)
	mux.HandleFunc("/hint", s.handleHint)
	mux.HandleFunc("/hint/search", s.handleHintSearch)
	mux.HandleFunc("/logs.zip", s.handleLogs)

	srv := &http.Server{
		Handler:           localOnly(mux, isLoopbackAddr(*addr)),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		// An install holds the response open across the UE4SS download, so the
		// write bound is generous rather than the default (none).
		WriteTimeout: 5 * time.Minute,
		IdleTimeout:  2 * time.Minute,
	}

	fmt.Printf("Spyro Reignited Launcher running at %s\n", uiURL)
	if !*noBrowser {
		if err := openURL(uiURL); err != nil {
			fmt.Printf("(couldn't open a browser automatically: %v — open the URL above manually)\n", err)
		}
	}
	if err := srv.Serve(ln); !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
