// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-31

package main

import (
	"encoding/json"
	"html/template"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
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

// TestApplyRejectsGet pins the method guard: /apply installs and launches, so a
// GET (which any <img src> can trigger) must not reach it.
func TestApplyRejectsGet(t *testing.T) {
	useStateFile(t, filepath.Join(t.TempDir(), "paths.json"))
	s := testServer(t, Paths{ConfigDir: t.TempDir(), GameWin64: t.TempDir()})

	rec := httptest.NewRecorder()
	s.handleApply(rec, httptest.NewRequest("GET", "/apply?action=install", nil))
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET /apply: got %d, want 405", rec.Code)
	}
}

// TestApplyAndResetRejectBadToken pins the CSRF guard on both POST endpoints.
func TestApplyAndResetRejectBadToken(t *testing.T) {
	useStateFile(t, filepath.Join(t.TempDir(), "paths.json"))
	s := testServer(t, Paths{ConfigDir: t.TempDir(), GameWin64: t.TempDir()})

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
	s := testServer(t, Paths{ConfigDir: filepath.Join(root, "bridge"), GameWin64: win64})

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

	rec := s.postForm(s.handleReset, "/reset", url.Values{"config_dir": {"/posted/ignored"}, "game_win64": {"/posted/ignored"}})
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("POST /reset: got %d, want 303", rec.Code)
	}
	if loc := rec.Header().Get("Location"); loc != "/?flash=reset" {
		t.Fatalf("redirect Location: %q", loc)
	}
	if s.paths != defaultPaths() {
		t.Fatalf("paths not reset: %+v", s.paths)
	}
	b, err := os.ReadFile(state)
	if err != nil {
		t.Fatalf("reset must persist: %v", err)
	}
	var saved Paths
	if err := json.Unmarshal(b, &saved); err != nil || saved != defaultPaths() {
		t.Fatalf("persisted paths: %+v err=%v", saved, err)
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

func TestSavePathsErrors(t *testing.T) {
	useStateFileBlocked(t)
	if err := savePaths(Paths{ConfigDir: "x"}); err == nil {
		t.Fatal("savePaths must fail when the state dir can't be created")
	}
	useStateFile(t, "")
	if err := savePaths(Paths{ConfigDir: "x"}); err == nil {
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

// applyServer is a test server whose config and Win64 folders sit in one temp
// root, returned with the root and the config path.
func applyServer(t *testing.T) (*server, string, string) {
	t.Helper()
	root := t.TempDir()
	s := testServer(t, Paths{ConfigDir: root, GameWin64: filepath.Join(root, "win64")})
	return s, root, filepath.Join(root, "config.txt")
}
