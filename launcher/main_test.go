// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-11-13

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"html/template"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// TestMain points the state file at a temp dir so no test ever writes to the
// real user config dir.
func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "srtap-launcher-test")
	if err != nil {
		panic(err)
	}
	launcherStateFile = func() string { return filepath.Join(dir, "state", "paths.json") }
	code := m.Run()
	_ = os.RemoveAll(dir)
	os.Exit(code)
}

// useStateFile redirects the state file for one test.
func useStateFile(t *testing.T, path string) {
	t.Helper()
	prev := launcherStateFile
	launcherStateFile = func() string { return path }
	t.Cleanup(func() { launcherStateFile = prev })
}

func testServer(t *testing.T, p Paths) *server {
	t.Helper()
	return &server{paths: p, tmpl: template.Must(template.New("index").Parse(indexHTML)),
		feed: NewFeed(), token: newToken()}
}

// autoServer is a test server whose folders are both auto-detected.
func autoServer(t *testing.T, p Paths) *server {
	t.Helper()
	s := testServer(t, p)
	s.autoConfig, s.autoGame = true, true
	return s
}

// writeState writes a launcher state file verbatim.
func writeState(t *testing.T, path string, v any) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		t.Fatal(err)
	}
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, b, 0644); err != nil {
		t.Fatal(err)
	}
}

// postRequest builds an /apply request carrying form, without the CSRF token.
func postRequest(t *testing.T, form url.Values) *http.Request {
	t.Helper()
	req := httptest.NewRequest("POST", "/apply", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	return req
}

// postReset resets the server and returns the redirect response.
func postReset(t *testing.T, s *server) *httptest.ResponseRecorder {
	t.Helper()
	rec := s.postForm(s.handleReset, "/reset", url.Values{
		"config_dir": {"/posted/ignored"}, "game_win64": {"/posted/ignored"}})
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("POST /reset: got %d, want 303", rec.Code)
	}
	return rec
}

// assertFlags fails unless the server's auto flags match.
func assertFlags(t *testing.T, s *server, wantConfig, wantGame bool) {
	t.Helper()
	if s.autoConfig != wantConfig {
		t.Fatalf("config auto = %v, want %v", s.autoConfig, wantConfig)
	}
	if s.autoGame != wantGame {
		t.Fatalf("game auto = %v, want %v", s.autoGame, wantGame)
	}
}

// readSaved loads the launcher state file at path.
func readSaved(t *testing.T, path string) savedPaths {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("state file: %v", err)
	}
	var saved savedPaths
	if err := json.Unmarshal(b, &saved); err != nil {
		t.Fatalf("state file: %v", err)
	}
	return saved
}

// assertSavedFlags fails unless the persisted auto flags match.
func assertSavedFlags(t *testing.T, saved savedPaths, wantConfig, wantGame bool) {
	t.Helper()
	if got := savedFlag(t, saved.ConfigAuto, "config auto"); got != wantConfig {
		t.Fatalf("persisted config auto = %v, want %v", got, wantConfig)
	}
	if got := savedFlag(t, saved.GameAuto, "game auto"); got != wantGame {
		t.Fatalf("persisted game auto = %v, want %v", got, wantGame)
	}
}

// savedFlag dereferences a persisted auto flag, failing the test when the state
// file omitted it.
func savedFlag(t *testing.T, flag *bool, name string) bool {
	t.Helper()
	if flag == nil {
		t.Fatalf("%s flag missing from the state file", name)
	}
	return *flag
}

// postForm posts a form to a handler with this server's CSRF token, as the
// page's hidden field would. Pass a nil form for an empty post.
func (s *server) postForm(h http.HandlerFunc, path string, form url.Values) *httptest.ResponseRecorder {
	if form == nil {
		form = url.Values{}
	}
	form.Set("csrf", s.token)
	req := httptest.NewRequest("POST", path, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	h(rec, req)
	return rec
}

// newTestServer builds a server over throwaway state and game paths.
func newTestServer(t *testing.T) *server {
	t.Helper()
	useStateFile(t, filepath.Join(t.TempDir(), "paths.json"))
	return testServer(t, Paths{ConfigDir: t.TempDir(), GameWin64: t.TempDir()})
}

// rootPage returns a fresh server and the rendered root page.
func rootPage(t *testing.T) (*server, string) {
	t.Helper()
	s := newTestServer(t)
	rec := httptest.NewRecorder()
	s.handleRoot(rec, httptest.NewRequest("GET", "/", nil))
	return s, rec.Body.String()
}

// TestApplyRejectsGet pins the method guard: /apply installs and launches, so a
// GET (which any <img src> can trigger) must not reach it.
func TestApplyRejectsGet(t *testing.T) {
	s := newTestServer(t)

	rec := httptest.NewRecorder()
	s.handleApply(rec, httptest.NewRequest("GET", "/apply?action=install", nil))
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET /apply: got %d, want 405", rec.Code)
	}
}

// TestApplyAndResetRejectBadToken pins the CSRF guard on both POST endpoints.
func TestApplyAndResetRejectBadToken(t *testing.T) {
	s := newTestServer(t)

	for _, tc := range []struct {
		name string
		h    http.HandlerFunc
		path string
	}{
		{"apply", s.handleApply, "/apply"},
		{"reset", s.handleReset, "/reset"},
	} {
		for _, tok := range []string{"", "wrong"} {
			req := httptest.NewRequest("POST", tc.path, strings.NewReader("action=save&csrf="+tok))
			req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
			rec := httptest.NewRecorder()
			tc.h(rec, req)
			if rec.Code != http.StatusForbidden {
				t.Fatalf("%s with token %q: got %d, want 403", tc.name, tok, rec.Code)
			}
		}
	}
}

// TestLocalOnlyRejectsForeignHost pins the DNS-rebinding guard: only loopback
// Hosts may reach the handler while the listener is loopback.
func TestLocalOnlyRejectsForeignHost(t *testing.T) {
	ok := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	h := localOnly(ok, true)

	for _, host := range []string{"evil.example", "evil.example:1234", "127.0.0.1.evil.example"} {
		req := httptest.NewRequest("GET", "/", nil)
		req.Host = host
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != http.StatusForbidden {
			t.Fatalf("Host %q: got %d, want 403", host, rec.Code)
		}
	}
	for _, host := range []string{"127.0.0.1:1234", "localhost:1234", "[::1]:1234"} {
		req := httptest.NewRequest("GET", "/", nil)
		req.Host = host
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("Host %q: got %d, want 200", host, rec.Code)
		}
	}
	// widened listener: the check is off
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/", nil)
	req.Host = "evil.example"
	localOnly(ok, false).ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("disabled check: got %d, want 200", rec.Code)
	}
}

// TestConfigSetStripsNewlines pins the injection guard: a value cannot add keys.
func TestConfigSetStripsNewlines(t *testing.T) {
	c := &Config{values: map[string]string{}}
	c.Set("password", "pw\nspawn_checkd=0\rmore")
	for _, line := range strings.Split(c.render(), "\n") {
		if strings.HasPrefix(line, "spawn_checkd=") {
			t.Fatalf("newline injected a key: %q", line)
		}
	}
	if got := c.Get("password", ""); got != "pwspawn_checkd=0more" {
		t.Fatalf("password = %q, want the newlines stripped", got)
	}
}

func TestApplyUnreadableConfigLeftUnchanged(t *testing.T) {
	useStateFile(t, filepath.Join(t.TempDir(), "paths.json"))
	s, _, cfgPath := applyServer(t)
	// a directory where config.txt should be: opens fine, reads fail
	if err := os.MkdirAll(filepath.Join(cfgPath, "keep"), 0755); err != nil {
		t.Fatal(err)
	}

	rec := s.postForm(s.handleApply, "/apply", url.Values{"action": {"save"}, "host": {"archipelago.gg"}, "slot": {"Me"}})
	body := rec.Body.String()
	if !strings.Contains(body, "Could not read config.txt, so it was left unchanged") {
		t.Fatalf("flash should explain the config was left alone:\n%s", body)
	}
	fi, err := os.Stat(cfgPath)
	if err != nil || !fi.IsDir() {
		t.Fatalf("config.txt must be untouched (still a dir): fi=%v err=%v", fi, err)
	}
	if _, err := os.Stat(filepath.Join(cfgPath, "keep")); err != nil {
		t.Fatalf("config.txt contents changed: %v", err)
	}
	if _, err := os.Stat(cfgPath + ".tmp"); !os.IsNotExist(err) {
		t.Fatalf("no temp file should be written: %v", err)
	}
}

func TestApplySavesConfigAndPreservesExtras(t *testing.T) {
	useStateFile(t, filepath.Join(t.TempDir(), "paths.json"))
	s, _, cfgPath := applyServer(t)
	if err := os.WriteFile(cfgPath, []byte("experimental_flag=42\n"), 0644); err != nil {
		t.Fatal(err)
	}

	rec := s.postForm(s.handleApply, "/apply", url.Values{"action": {"save"}, "host": {"http://h:1"}, "slot": {"Me"}})
	if !strings.Contains(rec.Body.String(), "Config saved to") {
		t.Fatalf("expected save flash:\n%s", rec.Body.String())
	}
	raw, _ := os.ReadFile(cfgPath)
	want := "host=ws://h:1\nslot=Me\npassword=\nspawn_checkd=1\nexperimental_flag=42\n"
	if string(raw) != want {
		t.Fatalf("config.txt:\n%s\nwant:\n%s", raw, want)
	}
}

func TestApplyEmptyHostKeepsDefault(t *testing.T) {
	useStateFile(t, filepath.Join(t.TempDir(), "paths.json"))
	s, _, cfgPath := applyServer(t)

	rec := s.postForm(s.handleApply, "/apply", url.Values{"action": {"save"}, "host": {""}, "slot": {"Me"}})
	if !strings.Contains(rec.Body.String(), "Config saved to") {
		t.Fatalf("expected save flash:\n%s", rec.Body.String())
	}
	cfg, err := ReadConfig(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	if got := cfg.Get("host", ""); got != defaultHost {
		t.Fatalf("host = %q, want the default %q", got, defaultHost)
	}
}

func TestApplyFlashesStateSaveError(t *testing.T) {
	useStateFileBlocked(t)
	s, root, _ := applyServer(t)

	rec := s.postForm(s.handleApply, "/apply", url.Values{"action": {"save"}, "slot": {"Me"}})
	body := rec.Body.String()
	if !strings.Contains(body, "Config saved to") || !strings.Contains(body, "couldn&#39;t remember folder overrides") {
		t.Fatalf("expected config saved + state error in flash:\n%s", body)
	}
	if _, err := os.Stat(filepath.Join(root, "config.txt")); err != nil {
		t.Fatalf("config save must not abort on a state error: %v", err)
	}
}

func TestApplyInstallActionRunsSteps(t *testing.T) {
	useStateFile(t, filepath.Join(t.TempDir(), "paths.json"))
	root := t.TempDir()
	win64 := filepath.Join(root, "win64")
	// UE4SS already present so the handler never attempts a download.
	mkfile(t, filepath.Join(win64, "dwmapi.dll"))
	mkfile(t, filepath.Join(win64, "UE4SS.dll"))
	mkfile(t, filepath.Join(win64, "Mods", "mods.txt"))
	s := testServer(t, Paths{ConfigDir: filepath.Join(root, "bridge"), GameWin64: win64, PrefixReady: true})

	rec := s.postForm(s.handleApply, "/apply", url.Values{"action": {"install"}})
	body := rec.Body.String()
	if !strings.Contains(body, "Install") || !strings.Contains(body, "Enable mod") {
		t.Fatalf("panel should show install step results:\n%s", body)
	}
}

func TestResetRejectsGet(t *testing.T) {
	state := filepath.Join(t.TempDir(), "paths.json")
	useStateFile(t, state)
	custom := Paths{ConfigDir: "/custom/cfg", GameWin64: "/custom/win64"}
	s := testServer(t, custom)

	rec := httptest.NewRecorder()
	s.handleReset(rec, httptest.NewRequest("GET", "/reset", nil))
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET /reset: got %d, want 405", rec.Code)
	}
	if s.paths != custom {
		t.Fatalf("GET /reset changed paths: %+v", s.paths)
	}
	if _, err := os.Stat(state); !os.IsNotExist(err) {
		t.Fatalf("GET /reset wrote the state file: %v", err)
	}
}

func TestResetPostResetsAndRedirects(t *testing.T) {
	state := filepath.Join(t.TempDir(), "paths.json")
	useStateFile(t, state)
	s := testServer(t, Paths{ConfigDir: "/custom/cfg", GameWin64: "/custom/win64"})

	rec := postReset(t, s)
	if loc := rec.Header().Get("Location"); loc != "/?flash=reset" {
		t.Fatalf("redirect Location: %q", loc)
	}
	if s.paths != defaultPaths() {
		t.Fatalf("paths not reset: %+v", s.paths)
	}
	assertFlags(t, s, true, true)
}

// TestResetPostPersistsAutoDetection pins what the reset writes back: both
// folders at their detected values, both flags auto, and a page that says so.
func TestResetPostPersistsAutoDetection(t *testing.T) {
	state := filepath.Join(t.TempDir(), "paths.json")
	useStateFile(t, state)
	s := testServer(t, Paths{ConfigDir: "/custom/cfg", GameWin64: "/custom/win64"})

	postReset(t, s)
	saved := readSaved(t, state)
	assertSavedFlags(t, saved, true, true)
	base := defaultPaths()
	if saved.ConfigDir != base.ConfigDir || saved.GameWin64 != base.GameWin64 {
		t.Fatalf("persisted paths: %+v, want %+v", saved, base)
	}

	page := httptest.NewRecorder()
	s.handleRoot(page, httptest.NewRequest("GET", "/?flash=reset", nil))
	if !strings.Contains(page.Body.String(), "Folders reset to auto-detected.") {
		t.Fatalf("page after reset missing flash:\n%s", page.Body.String())
	}
}

func TestResetPostSurfacesSaveError(t *testing.T) {
	useStateFileBlocked(t)
	s := testServer(t, Paths{ConfigDir: "/custom/cfg", GameWin64: "/custom/win64"})

	rec := s.postForm(s.handleReset, "/reset", nil)
	loc := rec.Header().Get("Location")
	if rec.Code != http.StatusSeeOther || !strings.Contains(loc, "err=") {
		t.Fatalf("expected 303 with err marker, got %d %q", rec.Code, loc)
	}
	page := httptest.NewRecorder()
	s.handleRoot(page, httptest.NewRequest("GET", loc, nil))
	if !strings.Contains(page.Body.String(), "couldn&#39;t remember this") {
		t.Fatalf("page should show the save error:\n%s", page.Body.String())
	}
}

func TestRootNeverWritesState(t *testing.T) {
	state := filepath.Join(t.TempDir(), "paths.json")
	useStateFile(t, state)
	custom := Paths{ConfigDir: t.TempDir(), GameWin64: "/custom/win64"}
	s := testServer(t, custom)

	for _, u := range []string{"/", "/?reset=1", "/?flash=reset"} {
		rec := httptest.NewRecorder()
		s.handleRoot(rec, httptest.NewRequest("GET", u, nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("GET %s: %d", u, rec.Code)
		}
	}
	if s.paths != custom {
		t.Fatalf("GET / changed paths: %+v", s.paths)
	}
	if _, err := os.Stat(state); !os.IsNotExist(err) {
		t.Fatalf("GET / wrote the state file: %v", err)
	}
}

// TestRootShowsFrameRateNote pins the frame-rate workaround: uncapped, the
// game's movement breaks, so the note must stay on the page the player sees.
func TestRootShowsFrameRateNote(t *testing.T) {
	_, body := rootPage(t)

	for _, want := range []string{"Cap the frame rate", "60 FPS", "Max Frame Rate", "Frame Rate Target Control"} {
		if !strings.Contains(body, want) {
			t.Fatalf("page is missing %q from the frame-rate note", want)
		}
	}
}

// TestPageHasSetupPlayAndHelpTabs pins the tab layout: each section renders, and
// an /apply answer carries its flash out of band so the message is visible
// whichever tab the player is on.
func TestPageHasSetupPlayAndHelpTabs(t *testing.T) {
	s, page := rootPage(t)
	for _, want := range []string{`id="tab-setup"`, `id="tab-play"`, `id="tab-help"`, `data-tab="play"`} {
		if !strings.Contains(page, want) {
			t.Fatalf("page is missing %q", want)
		}
	}

	rec := s.postForm(s.handleApply, "/apply", url.Values{"action": {"recheck"}})
	body := rec.Body.String()
	if !strings.Contains(body, `hx-swap-oob="true"`) || !strings.Contains(body, "Setup re-checked.") {
		t.Fatalf("apply response must flash out of band:\n%s", body)
	}
	if strings.Contains(body, `id="tab-setup"`) {
		t.Fatalf("apply response should only swap the panel, got a whole tab:\n%s", body)
	}
}

// TestSetupTabKeepsLaunchAndInstall pins the landing tab: connection, launch and
// the install button all sit on the tab the page opens on, so the player can
// start playing without hunting for a second tab.
func TestSetupTabKeepsLaunchAndInstall(t *testing.T) {
	_, body := rootPage(t)

	setup, play := strings.Index(body, `id="tab-setup"`), strings.Index(body, `id="tab-play"`)
	if setup < 0 || play < 0 || setup > play {
		t.Fatalf("Setup must come first: setup=%d play=%d", setup, play)
	}
	for _, want := range []string{`"action":"launch"`, `"action":"install"`} {
		at := strings.Index(body, want)
		if at < setup || at > play {
			t.Fatalf("%s must sit on the Setup tab, found at %d (setup=%d play=%d)", want, at, setup, play)
		}
	}
	if !strings.Contains(body, `show((location.hash || '').replace('#', '') || 'setup')`) {
		t.Fatal("the page must open on the Setup tab")
	}
}

// TestPlayTabIsChecksAndHints pins what the Play tab is for: the live check feed
// and the hint panel, nothing else.
func TestPlayTabIsChecksAndHints(t *testing.T) {
	_, body := rootPage(t)

	play, help := strings.Index(body, `id="tab-play"`), strings.Index(body, `id="tab-help"`)
	if play < 0 || help < 0 || play > help {
		t.Fatalf("Play must sit between Setup and Help: play=%d help=%d", play, help)
	}
	for _, want := range []string{`id="feed"`, "<h2>Hints</h2>"} {
		at := strings.Index(body, want)
		if at < play || at > help {
			t.Fatalf("%s must sit on the Play tab, found at %d (play=%d help=%d)", want, at, play, help)
		}
	}
}

// TestPlayTabHintsPollAndStayTypingSafe pins the hint panel's split: the list
// polls, while the name inputs, their search results and the buttons sit outside
// the polled div, so a refresh never wipes what the player typed.
func TestPlayTabHintsPollAndStayTypingSafe(t *testing.T) {
	s := newTestServer(t)
	ten := 10.0
	s.feed.setHintCost(&ten)
	s.feed.setChecks(3, 238)

	rec := httptest.NewRecorder()
	s.handleRoot(rec, httptest.NewRequest("GET", "/", nil))
	body := rec.Body.String()

	if strings.Contains(body, "datalist") {
		t.Errorf("the hint form must not use datalists:\n%s", body)
	}
	hints, form := strings.Index(body, `id="hints"`), strings.Index(body, `id="hint-form"`)
	if hints < 0 || form < hints {
		t.Fatalf("the hint form must sit outside the polled div: hints=%d form=%d", hints, form)
	}
	for _, want := range []string{
		`hx-get="/hints"`, `hx-trigger="every 2s"`,
		`name="loc_name"`, `id="loc-results"`, `hx-target="#loc-results"`,
		`name="item_name"`, `id="item-results"`, `hx-target="#item-results"`,
		`hx-get="/hint/search"`, `hx-trigger="keyup changed delay:250ms, focus"`,
		`hx-include="this"`, `{"field":"location"}`, `{"field":"item"}`,
		`hx-post="/hint"`, `hx-target="#hints"`, `hx-include="#cfg"`,
		`{"kind":"location"}`, `{"kind":"item"}`,
		`hx-confirm="Spend 23 points on this hint?"`,
		"Hint location", "Hint item",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("page is missing %q", want)
		}
	}
	for _, want := range []string{`name="loc_name"`, `name="item_name"`, `id="loc-results"`, `id="item-results"`} {
		if at := strings.Index(body, want); at < form {
			t.Errorf("%s must follow the polled div (at %d, form at %d)", want, at, form)
		}
	}
}

// TestHintFragmentShowsPointsAndHints pins the polled panel: the balance line,
// the notice, and one line per hint with its found state.
func TestHintFragmentShowsPointsAndHints(t *testing.T) {
	s := testServer(t, Paths{ConfigDir: t.TempDir(), GameWin64: t.TempDir()})
	ten := 10.0
	s.feed.setHintCost(&ten)
	s.feed.setChecks(3, 238)
	s.feed.setPoints(12)
	s.feed.setStatus(true, "Connected as SRTPlayer.")
	s.feed.setHints([]feedHint{
		{ItemName: "Dragon", LocationName: "Artisans: Free Nestor",
			ReceiverName: "SRTPlayer", FinderName: "SRTPlayer", Progression: true},
		{ItemName: "1 Puzzle Piece", LocationName: "Merge 25 times",
			ReceiverName: "SRTPlayer", FinderName: "SpeedyLink", Found: true},
	})
	s.feed.SetNotice("Nothing found for that name.")

	rec := httptest.NewRecorder()
	s.handleHints(rec, httptest.NewRequest("GET", "/hints", nil))
	body := rec.Body.String()
	for _, want := range []string{
		"<b>12</b> points", "<b>23</b> per hint", "Nothing found for that name.",
		"Dragon", "Artisans: Free Nestor", "not found",
		"1 Puzzle Piece", "Merge 25 times (SpeedyLink)", "found", `class="prog"`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("hint fragment missing %q:\n%s", want, body)
		}
	}
}

// hintServer is a test server whose feed holds a live stub session, so a posted
// hint request really reaches a connection.
func hintServer(t *testing.T) (*server, <-chan map[string]any) {
	t.Helper()
	s := testServer(t, Paths{ConfigDir: t.TempDir(), GameWin64: t.TempDir()})
	sess, out := stubSession(s.feed, feedConn{Host: "127.0.0.1:38281", Slot: "SRTPlayer"})
	mustHandle(t, sess, hintConnectedJS)
	drain(out)
	serveStub(t, sess)
	return s, out
}

// TestHintPostNeedsToken pins the CSRF guard on the one endpoint that spends
// the slot's hint points.
func TestHintPostNeedsToken(t *testing.T) {
	s, out := hintServer(t)
	for _, tok := range []string{"", "wrong"} {
		req := httptest.NewRequest("POST", "/hint", strings.NewReader("kind=item&item_name=Dragon&csrf="+tok))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		rec := httptest.NewRecorder()
		s.handleHint(rec, req)
		if rec.Code != http.StatusForbidden {
			t.Fatalf("token %q: got %d, want 403", tok, rec.Code)
		}
	}
	if len(out) != 0 {
		t.Fatalf("a refused request reached the wire: %v", <-out)
	}
}

// TestHintPostWithoutNameNotices pins the empty request: it spends nothing and
// says why rather than asking the server for nothing.
func TestHintPostWithoutNameNotices(t *testing.T) {
	s, out := hintServer(t)
	rec := s.postForm(s.handleHint, "/hint", url.Values{"kind": {"location"}, "loc_name": {"  "}})
	body := rec.Body.String()
	if !strings.Contains(body, "pick a name") {
		t.Fatalf("expected the name notice:\n%s", body)
	}
	if strings.Contains(body, "<html") {
		t.Fatalf("the answer must be the fragment only:\n%s", body)
	}
	if len(out) != 0 {
		t.Fatalf("an unnamed request must not reach the wire: %v", <-out)
	}
}

// TestHintPostSendsChatCommand pins both hint kinds: the typed name becomes the
// chat command the server understands, and the answer is the refreshed panel.
func TestHintPostSendsChatCommand(t *testing.T) {
	s, out := hintServer(t)
	cases := []struct {
		form url.Values
		want string
	}{
		{url.Values{"kind": {"location"}, "loc_name": {" Artisans: Free Nestor "}},
			"!hint_location Artisans: Free Nestor"},
		{url.Values{"kind": {"item"}, "item_name": {"Dragon"}}, "!hint Dragon"},
	}
	for _, tc := range cases {
		rec := s.postForm(s.handleHint, "/hint", tc.form)
		if got := nextCmd(t, out); got["cmd"] != "Say" || got["text"] != tc.want {
			t.Errorf("wire = %v, want Say %q", got, tc.want)
		}
		if body := rec.Body.String(); !strings.Contains(body, "No hints yet") {
			t.Errorf("answer should be the refreshed panel:\n%s", body)
		}
	}
}

// hintSearch asks for one field's suggestions and returns the fragment body,
// HTML-unescaped so the assertions compare URLs as htmx would read them.
func hintSearch(t *testing.T, s *server, field, q string) string {
	t.Helper()
	param := "loc_name"
	if field == "item" {
		param = "item_name"
	}
	req := httptest.NewRequest("GET", "/hint/search?field="+field+"&"+param+"="+url.QueryEscape(q), nil)
	rec := httptest.NewRecorder()
	s.handleHintSearch(rec, req)
	return html.UnescapeString(rec.Body.String())
}

// hintSearchServer is a test server whose feed holds the given names, as a
// connected room would leave them.
func hintSearchServer(t *testing.T, missing, items []string) *server {
	t.Helper()
	s := newTestServer(t)
	s.feed.setStatus(true, "Connected as SRTPlayer.")
	s.feed.setLists(missing, items)
	return s
}

// TestHintSearchFindsLocationsAndItems pins what each field searches: the slot's
// unchecked locations for a location, its own game's items for an item, and a
// substring match that ignores case.
func TestHintSearchFindsLocationsAndItems(t *testing.T) {
	missing := []string{"Artisans: Free Nestor", "Stone Hill: Free Altar"}
	items := []string{"Dragon", "1 Puzzle Piece"}
	s := hintSearchServer(t, missing, items)

	if body := hintSearch(t, s, "location", "free nestor"); !strings.Contains(body, ">Artisans: Free Nestor<") ||
		strings.Contains(body, "Stone Hill") {
		t.Errorf("location search should offer only Artisans:\n%s", body)
	}
	if body := hintSearch(t, s, "item", "puzzle"); !strings.Contains(body, ">1 Puzzle Piece<") ||
		strings.Contains(body, "Dragon") {
		t.Errorf("item search should offer only 1 Puzzle Piece:\n%s", body)
	}
	body := hintSearch(t, s, "location", "nowhere")
	if !strings.Contains(body, `no match for "nowhere"`) || strings.Contains(body, "<button") {
		t.Errorf("a search with no match should say so and offer nothing:\n%s", body)
	}
}

// TestHintSearchCapsAndCounts pins the rendered cap: a search with more matches
// than the page holds shows the first 20 and names the total.
func TestHintSearchCapsAndCounts(t *testing.T) {
	missing := make([]string, 0, 25)
	for i := 1; i <= 25; i++ {
		missing = append(missing, fmt.Sprintf("Artisans: Gem %02d", i))
	}
	s := hintSearchServer(t, missing, nil)

	body := hintSearch(t, s, "location", "gem")
	if got := strings.Count(body, "<button"); got != hintResultCap {
		t.Errorf("got %d buttons, want %d:\n%s", got, hintResultCap, body)
	}
	if !strings.Contains(body, "Showing 20 of 25 matches") {
		t.Errorf("the capped list must name the total:\n%s", body)
	}
}

// TestHintSearchSpreadsGamesAndLevels pins the cap's fairness: 20 keys across
// two games must show both games, not the first game's 20 alphabetically.
func TestHintSearchSpreadsGamesAndLevels(t *testing.T) {
	var items []string
	for i := 1; i <= 30; i++ {
		items = append(items, fmt.Sprintf("Spyro 1: Level %02d Key", i))
	}
	for i := 1; i <= 10; i++ {
		items = append(items, fmt.Sprintf("Spyro 2: Level %02d Key", i))
	}
	s := hintSearchServer(t, nil, items)

	body := hintSearch(t, s, "item", "key")
	if got, want := strings.Count(body, "Spyro 2:"), 10; got != want {
		t.Errorf("capped list shows %d Spyro 2 matches, want %d:\n%s", got, want, body)
	}
	if got := strings.Count(body, "<button"); got != hintResultCap {
		t.Errorf("got %d buttons, want %d", got, hintResultCap)
	}
}

// TestHintSearchSpreadsLevelsWithinOneGame: gem searches should span levels, not
// spend the cap on the first level's four thresholds.
func TestHintSearchSpreadsLevelsWithinOneGame(t *testing.T) {
	var missing []string
	for lvl := 1; lvl <= 4; lvl++ {
		for _, pct := range []string{"25%", "50%", "75%", "100%"} {
			missing = append(missing, fmt.Sprintf("Spyro 1: Level %d: %s Gems", lvl, pct))
		}
	}
	s := hintSearchServer(t, missing, nil)

	body := hintSearch(t, s, "location", "gems")
	if got := strings.Count(body, "<button"); got != len(missing) {
		t.Errorf("got %d buttons, want %d", got, len(missing))
	}
	first := strings.Index(body, "Level 1: 25% Gems")
	second := strings.Index(body, "Level 2: 25% Gems")
	if first < 0 || second < 0 || second < first {
		t.Errorf("levels must interleave:\n%s", body)
	}
}

// TestHintSearchNeedsAConnection pins the idle state: before the feed connects the
// search waits rather than claiming the room holds nothing.
func TestHintSearchNeedsAConnection(t *testing.T) {
	s := newTestServer(t)

	body := hintSearch(t, s, "location", "nestor")
	if !strings.Contains(body, "Waiting for the server.") || strings.Contains(body, "<button") {
		t.Fatalf("a disconnected search must wait, not list:\n%s", body)
	}
}

// TestHintResultButtonCarriesTheCommand pins one result button: it posts the name
// it shows in the query string, and only asks for confirmation when a hint costs
// the slot points.
func TestHintResultButtonCarriesTheCommand(t *testing.T) {
	s := hintSearchServer(t, []string{"Artisans: Free Nestor"}, nil)
	ten := 10.0
	s.feed.setHintCost(&ten)
	s.feed.setChecks(3, 238)

	body := hintSearch(t, s, "location", "nestor")
	if !strings.Contains(body, `hx-post="/hint?kind=location&loc_name=Artisans%3A+Free+Nestor"`) {
		t.Errorf("the result button must carry the exact name:\n%s", body)
	}
	if !strings.Contains(body, `hx-confirm="Spend 23 points on this hint?"`) {
		t.Errorf("a priced hint needs its confirmation:\n%s", body)
	}

	free := hintSearchServer(t, []string{"Artisans: Free Nestor"}, nil)
	if body := hintSearch(t, free, "location", "nestor"); strings.Contains(body, "hx-confirm") {
		t.Errorf("a free hint must not ask for confirmation:\n%s", body)
	}

	live, out := hintServer(t)
	live.feed.setLists([]string{"Artisans: Free Nestor"}, nil)
	live.postForm(live.handleHint, "/hint?kind=location&loc_name=Artisans%3A+Free+Nestor",
		url.Values{"kind": {"location"}, "loc_name": {"Artis"}})
	if got := nextCmd(t, out); got["text"] != "!hint_location Artisans: Free Nestor" {
		t.Errorf("the button's exact name must win over partial text: %v", got)
	}
}

func TestSavePathsErrors(t *testing.T) {
	useStateFileBlocked(t)
	if err := savePaths(Paths{ConfigDir: "x"}, true, true); err == nil {
		t.Fatal("savePaths must fail when the state dir can't be created")
	}
	useStateFile(t, "")
	if err := savePaths(Paths{ConfigDir: "x"}, true, true); err == nil {
		t.Fatal("savePaths must fail with no state file path")
	}
}

// useStateFileBlocked points the state file inside a path that cannot be
// created, so savePaths fails.
func useStateFileBlocked(t *testing.T) {
	t.Helper()
	blocker := filepath.Join(t.TempDir(), "blocker")
	if err := os.WriteFile(blocker, []byte("x"), 0644); err != nil {
		t.Fatal(err)
	}
	useStateFile(t, filepath.Join(blocker, "sub", "paths.json"))
}

// TestLoadPathsOldStateFileInfersAuto pins the migration of a state file written
// before the auto flags existed: a value matching detection (or empty) is auto,
// anything else is an override.
func TestLoadPathsOldStateFileInfersAuto(t *testing.T) {
	state := filepath.Join(t.TempDir(), "paths.json")
	useStateFile(t, state)
	base, _, _ := loadPaths()
	cases := []struct {
		name       string
		saved      savedPaths
		wantAuto   bool
		wantConfig string
		wantGame   string
	}{
		{"matches detection", savedPaths{ConfigDir: base.ConfigDir, GameWin64: base.GameWin64},
			true, base.ConfigDir, base.GameWin64},
		{"differs", savedPaths{ConfigDir: "/custom/cfg", GameWin64: "/custom/win64"},
			false, "/custom/cfg", "/custom/win64"},
		{"empty", savedPaths{}, true, base.ConfigDir, base.GameWin64},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			writeState(t, state, tc.saved)
			p, autoConfig, autoGame := loadPaths()
			if autoConfig != tc.wantAuto || autoGame != tc.wantAuto {
				t.Fatalf("auto = %v/%v, want %v", autoConfig, autoGame, tc.wantAuto)
			}
			if p.ConfigDir != tc.wantConfig || p.GameWin64 != tc.wantGame {
				t.Fatalf("paths = %+v, want %s and %s", p, tc.wantConfig, tc.wantGame)
			}
		})
	}
}

// TestLoadPathsHonorsFlags pins the explicit flags: an auto field always takes
// the fresh detection, an override field always takes the saved value.
func TestLoadPathsHonorsFlags(t *testing.T) {
	state := filepath.Join(t.TempDir(), "paths.json")
	useStateFile(t, state)
	base, _, _ := loadPaths()
	yes, no := true, false
	cases := []struct {
		name                 string
		configAuto, gameAuto *bool
		wantConfig, wantGame bool
	}{
		{"both auto", &yes, &yes, true, true},
		{"both override", &no, &no, false, false},
		{"config override", &no, &yes, false, true},
		{"game override", &yes, &no, true, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			writeState(t, state, savedPaths{ConfigDir: "/saved/cfg", GameWin64: "/saved/win64",
				ConfigAuto: tc.configAuto, GameAuto: tc.gameAuto})
			p, autoConfig, autoGame := loadPaths()
			if autoConfig != tc.wantConfig || autoGame != tc.wantGame {
				t.Fatalf("auto = %v/%v, want %v/%v", autoConfig, autoGame, tc.wantConfig, tc.wantGame)
			}
			wantConfig, wantGame := "/saved/cfg", "/saved/win64"
			if tc.wantConfig {
				wantConfig = base.ConfigDir
			}
			if tc.wantGame {
				wantGame = base.GameWin64
			}
			if p.ConfigDir != wantConfig || p.GameWin64 != wantGame {
				t.Fatalf("paths = %+v, want %s and %s", p, wantConfig, wantGame)
			}
		})
	}
}

// TestApplyPathOverridesFlags pins that an unchanged posted field keeps its auto
// flag while a changed one becomes an explicit override.
func TestApplyPathOverridesFlags(t *testing.T) {
	state := filepath.Join(t.TempDir(), "paths.json")
	useStateFile(t, state)
	steamHome(t)
	s := autoServer(t, Paths{ConfigDir: "/current/cfg", GameWin64: "/current/win64"})

	req := postRequest(t, url.Values{"config_dir": {"/current/cfg"}, "game_win64": {"/changed/win64"}})
	paths, err := s.applyPathOverrides(req)
	if err != nil {
		t.Fatal(err)
	}
	assertFlags(t, s, true, false)
	if paths.GameWin64 != "/changed/win64" {
		t.Fatalf("game folder = %s", paths.GameWin64)
	}
}

// TestApplyPathOverridesBridgeFollowsGame pins the Linux coupling: a fixed Game
// folder in another library pulls the auto bridge folder to that library's
// prefix, even though the posted bridge folder was unchanged.
func TestApplyPathOverridesBridgeFollowsGame(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Proton prefix layout")
	}
	state := filepath.Join(t.TempDir(), "paths.json")
	useStateFile(t, state)
	_, _, libA, libB := libraryPair(t)
	mkfile(t, filepath.Join(libA, gameRel(), "Spyro-Win64-Shipping.exe"))
	mkfile(t, filepath.Join(libB, gameRel(), "Spyro-Win64-Shipping.exe"))
	_, bridgeA := seedPrefix(t, libA, 0, 0)
	_, bridgeB := seedPrefix(t, libB, 0, 0)

	s := autoServer(t, Paths{ConfigDir: bridgeA, GameWin64: filepath.Join(libA, gameRel())})
	req := postRequest(t, url.Values{
		"config_dir": {bridgeA},
		"game_win64": {filepath.Join(libB, gameRel())},
	})
	paths, err := s.applyPathOverrides(req)
	if err != nil {
		t.Fatal(err)
	}
	assertFlags(t, s, true, false)
	if paths.ConfigDir != bridgeB {
		t.Fatalf("bridge = %s, want %s (the fixed game folder's own prefix)", paths.ConfigDir, bridgeB)
	}
	if !paths.PrefixReady {
		t.Fatal("a library with a prefix must report PrefixReady")
	}
	assertSavedFlags(t, readSaved(t, state), true, false)
}

// TestLoadPathsReadsLegacySchema: a state file from the release before the
// flags used Paths' Go field names, so it must still be read and inferred.
func TestLoadPathsReadsLegacySchema(t *testing.T) {
	state := filepath.Join(t.TempDir(), "paths.json")
	useStateFile(t, state)
	base := defaultPaths()
	writeState(t, state, Paths{ConfigDir: base.ConfigDir, GameWin64: "/custom/win64"})

	p, autoConfig, autoGame := loadPaths()
	if !autoConfig || autoGame {
		t.Fatalf("flags = auto=%v game=%v, want true/false", autoConfig, autoGame)
	}
	if p.ConfigDir != base.ConfigDir || p.GameWin64 != "/custom/win64" {
		t.Fatalf("paths = %+v", p)
	}
}

// TestDetectReportListsDiscovery pins the -detect output: one line per Steam
// root, library, game and prefix, then the chosen folder and auto flags.
func TestDetectReportListsDiscovery(t *testing.T) {
	useStateFile(t, filepath.Join(t.TempDir(), "paths.json"))
	home, root := steamTree(t)
	lib := filepath.Join(home, "Library")
	listLibraries(t, root, lib)
	win64 := filepath.Join(lib, gameRel())
	mkfile(t, filepath.Join(win64, "Spyro-Win64-Shipping.exe"))
	driveC := prefixTree(t, lib)
	bridge := bridgeIn(t, driveC)

	report := detectReport()
	for _, want := range []string{
		"os: " + runtime.GOOS,
		"steam root: " + root,
		"library: " + lib,
		"game: " + win64,
		"prefix: " + filepath.Dir(driveC),
		"chosen prefix: " + filepath.Dir(driveC),
		"config dir: " + bridge + " (auto=true)",
	} {
		if !strings.Contains(report, want) {
			t.Errorf("report missing %q:\n%s", want, report)
		}
	}
}

// TestApplyConnectionDefersWithoutPrefix: on Linux with no Proton prefix the
// launcher must not write config.txt into a prefix tree the game has not
// created yet; it tells the player to launch once first.
func TestApplyConnectionDefersWithoutPrefix(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Proton prefix layout")
	}
	root := t.TempDir()
	dir := filepath.Join(root, "pfx", "drive_c", "users", "steamuser",
		"AppData", "Local", bridgeDirName)
	s := testServer(t, Paths{ConfigDir: dir})

	msg, next := s.applyConnection(postRequest(t, url.Values{"host": {"example.invalid"}, "slot": {"T"}}), false)
	if !strings.Contains(msg, "launch the game once") {
		t.Fatalf("expected the launch-once guidance, got %q", msg)
	}
	if next != "" {
		t.Fatalf("a deferred save must leave the player on Setup, got next tab %q", next)
	}
	if dirExists(filepath.Join(root, "pfx")) {
		t.Fatal("saving the config must not create the Proton prefix")
	}
}

// TestApplyConnectionRefusesEmptyBridge: with no resolved bridge folder the
// launcher must not write a config.txt into the process working directory.
func TestApplyConnectionRefusesEmptyBridge(t *testing.T) {
	s := testServer(t, Paths{})
	msg, next := s.applyConnection(postRequest(t, url.Values{}), false)
	if !strings.Contains(msg, "No bridge folder") {
		t.Fatalf("expected the missing-bridge message, got %q", msg)
	}
	if next != "" {
		t.Fatalf("a refused save must leave the player on Setup, got next tab %q", next)
	}
}

// TestApplySendsThePlayerToPlayOnlyWhenTheGameStarts pins the tab switch: a
// successful launch moves the page to the checks, while a failed one leaves the
// player on Setup where the error can be fixed.
func TestApplySendsThePlayerToPlayOnlyWhenTheGameStarts(t *testing.T) {
	useStateFile(t, filepath.Join(t.TempDir(), "paths.json"))
	s, _, _ := applyServer(t)
	stubLaunch(t, nil)

	ok := s.postForm(s.handleApply, "/apply", url.Values{"action": {"launch"}, "host": {"h"}, "slot": {"Me"}})
	if !strings.Contains(ok.Body.String(), `data-tab="play"`) {
		t.Fatalf("a launch should switch to Play:\n%s", ok.Body.String())
	}

	stubLaunch(t, errors.New("no steam"))
	failed := s.postForm(s.handleApply, "/apply", url.Values{"action": {"launch"}, "host": {"h"}, "slot": {"Me"}})
	if strings.Contains(failed.Body.String(), `data-tab="play"`) {
		t.Fatalf("a failed launch must stay on Setup:\n%s", failed.Body.String())
	}

	saved := s.postForm(s.handleApply, "/apply", url.Values{"action": {"save"}, "host": {"h"}, "slot": {"Me"}})
	if strings.Contains(saved.Body.String(), `data-tab="play"`) {
		t.Fatalf("a plain save must stay on Setup:\n%s", saved.Body.String())
	}
}

// stubLaunch replaces the game launcher for one test, so no suite starts Steam.
func stubLaunch(t *testing.T, err error) {
	t.Helper()
	prev := launchGame
	launchGame = func() error { return err }
	t.Cleanup(func() { launchGame = prev })
}

func applyServer(t *testing.T) (*server, string, string) {
	t.Helper()
	root := t.TempDir()
	s := testServer(t, Paths{ConfigDir: root, GameWin64: filepath.Join(root, "win64")})
	return s, root, filepath.Join(root, "config.txt")
}
