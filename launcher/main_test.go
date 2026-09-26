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
	return &server{paths: p, tmpl: template.Must(template.New("index").Parse(indexHTML)), feed: NewFeed()}
}

func postForm(h http.HandlerFunc, path string, form url.Values) *httptest.ResponseRecorder {
	req := httptest.NewRequest("POST", path, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	h(rec, req)
	return rec
}

func TestApplyUnreadableConfigLeftUnchanged(t *testing.T) {
	useStateFile(t, filepath.Join(t.TempDir(), "paths.json"))
	root := t.TempDir()
	cfgPath := filepath.Join(root, "config.txt")
	// a directory where config.txt should be: opens fine, reads fail
	if err := os.MkdirAll(filepath.Join(cfgPath, "keep"), 0755); err != nil {
		t.Fatal(err)
	}
	s := testServer(t, Paths{ConfigDir: root, GameWin64: filepath.Join(root, "win64")})

	rec := postForm(s.handleApply, "/apply", url.Values{"action": {"save"}, "host": {"archipelago.gg"}, "slot": {"Me"}})
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

func TestApplySavesConfigAndDropsGame(t *testing.T) {
	useStateFile(t, filepath.Join(t.TempDir(), "paths.json"))
	root := t.TempDir()
	cfgPath := filepath.Join(root, "config.txt")
	if err := os.WriteFile(cfgPath, []byte("game=Spyro Reignited Trilogy\nexperimental_flag=42\n"), 0644); err != nil {
		t.Fatal(err)
	}
	s := testServer(t, Paths{ConfigDir: root, GameWin64: filepath.Join(root, "win64")})

	rec := postForm(s.handleApply, "/apply", url.Values{"action": {"save"}, "host": {"http://h:1"}, "slot": {"Me"}})
	if !strings.Contains(rec.Body.String(), "Config saved to") {
		t.Fatalf("expected save flash:\n%s", rec.Body.String())
	}
	raw, _ := os.ReadFile(cfgPath)
	want := "host=ws://h:1\nslot=Me\npassword=\nspawn_checkd=1\nexperimental_flag=42\n"
	if string(raw) != want {
		t.Fatalf("config.txt:\n%s\nwant:\n%s", raw, want)
	}
}

func TestApplyFlashesStateSaveError(t *testing.T) {
	blocker := filepath.Join(t.TempDir(), "blocker")
	if err := os.WriteFile(blocker, []byte("x"), 0644); err != nil {
		t.Fatal(err)
	}
	useStateFile(t, filepath.Join(blocker, "sub", "paths.json"))
	root := t.TempDir()
	s := testServer(t, Paths{ConfigDir: root, GameWin64: filepath.Join(root, "win64")})

	rec := postForm(s.handleApply, "/apply", url.Values{"action": {"save"}, "slot": {"Me"}})
	body := rec.Body.String()
	if !strings.Contains(body, "Config saved to") || !strings.Contains(body, "couldn&#39;t remember folder overrides") {
		t.Fatalf("expected config saved + state error in flash:\n%s", body)
	}
	if _, err := os.Stat(filepath.Join(root, "config.txt")); err != nil {
		t.Fatalf("config save must not abort on a state error: %v", err)
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

	rec := postForm(s.handleReset, "/reset", url.Values{"config_dir": {"/posted/ignored"}, "game_win64": {"/posted/ignored"}})
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
	blocker := filepath.Join(t.TempDir(), "blocker")
	if err := os.WriteFile(blocker, []byte("x"), 0644); err != nil {
		t.Fatal(err)
	}
	useStateFile(t, filepath.Join(blocker, "sub", "paths.json"))
	s := testServer(t, Paths{ConfigDir: "/custom/cfg", GameWin64: "/custom/win64"})

	rec := postForm(s.handleReset, "/reset", nil)
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
	blocker := filepath.Join(t.TempDir(), "blocker")
	if err := os.WriteFile(blocker, []byte("x"), 0644); err != nil {
		t.Fatal(err)
	}
	useStateFile(t, filepath.Join(blocker, "sub", "paths.json"))
	if err := savePaths(Paths{ConfigDir: "x"}); err == nil {
		t.Fatal("savePaths must fail when the state dir can't be created")
	}
	useStateFile(t, "")
	if err := savePaths(Paths{ConfigDir: "x"}); err == nil {
		t.Fatal("savePaths must fail with no state file path")
	}
}

func TestLoadPathsIgnoresLegacySaveDir(t *testing.T) {
	state := filepath.Join(t.TempDir(), "paths.json")
	useStateFile(t, state)
	legacy := `{"ConfigDir":"/old/cfg","SaveDir":"/old/saves","GameWin64":"/old/win64"}`
	if err := os.WriteFile(state, []byte(legacy), 0644); err != nil {
		t.Fatal(err)
	}
	if got := loadPaths(); got.ConfigDir != "/old/cfg" || got.GameWin64 != "/old/win64" {
		t.Fatalf("legacy paths.json not loaded: %+v", got)
	}
}
