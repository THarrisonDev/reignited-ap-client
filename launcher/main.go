// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-31

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
	mu         sync.Mutex
	paths      Paths
	tmpl       *template.Template
	feed       *Feed
	token      string // per-run CSRF token; see checkCSRF
	installing bool   // an install run is in flight; see handleApply
}

type view struct {
	Paths    Paths
	Token    string
	Host     string
	Slot     string
	Password string
	Checks   []Check
	AllOK    bool
	Flash    string
	Feed     feedView
	Install  []installResult
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
// path overrides are held in s.paths. install carries the step log of a just-
// run install (nil for a plain page load).
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
		Paths:    s.paths,
		Token:    s.token,
		Host:     conn.Host,
		Slot:     slot,
		Password: conn.Password,
		Checks:   checks,
		AllOK:    AllOK(checks),
		Flash:    strings.TrimSpace(flash),
		Feed:     s.feed.View(),
		Install:  install,
	}
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

// handleReset re-detects folders and forgets any saved overrides. POST only;
// any posted fields are ignored. It redirects to the full page so the path
// fields re-render with the defaults.
func (s *server) handleReset(w http.ResponseWriter, r *http.Request) {
	if !s.requirePost(w, r) {
		return
	}
	s.mu.Lock()
	s.paths = defaultPaths()
	err := savePaths(s.paths)
	s.mu.Unlock()
	target := "/?flash=reset"
	if err != nil {
		target += "&err=" + url.QueryEscape(err.Error())
	}
	http.Redirect(w, r, target, http.StatusSeeOther)
}

// handleApply is the single HTMX endpoint: it applies path overrides + config
// edits (and optionally launches), then returns the "panel" fragment (flash +
// refreshed setup checks) for HTMX to swap into #panel.
func (s *server) handleApply(w http.ResponseWriter, r *http.Request) {
	if !s.requirePost(w, r) {
		return
	}
	action := r.FormValue("action")

	paths, saveErr := s.applyPathOverrides(r)

	var flash string
	var install []installResult
	switch action {
	case "recheck":
		flash = "Setup re-checked."
	case "install":
		// Install runs WITHOUT the lock: the UE4SS download takes minutes and
		// the feed goroutine must keep answering the page while it does.
		if !s.tryStartInstall() {
			flash = "An install is already running — wait for it to finish."
			break
		}
		install = Install(paths, sourceDir(), installOptions{})
		s.finishInstall()
		flash = summarizeInstall(install)
	case "save", "launch":
		flash = s.applyConnection(r, action == "launch")
	default:
		flash = "Unknown action."
	}
	if saveErr != nil {
		flash += " (couldn't remember folder overrides: " + saveErr.Error() + ")"
	}

	s.mu.Lock()
	panel := s.buildView(flash, install)
	s.mu.Unlock()
	if err := s.tmpl.ExecuteTemplate(w, "panel", panel); err != nil {
		log.Printf("panel execute: %v", err)
	}
}

// applyPathOverrides merges the posted folder overrides into the launcher's own
// state, persists them so they survive a restart, and returns the paths the
// action should use.
func (s *server) applyPathOverrides(r *http.Request) (Paths, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if v := strings.TrimSpace(r.FormValue("config_dir")); v != "" {
		s.paths.ConfigDir = v
	}
	if v := strings.TrimSpace(r.FormValue("game_win64")); v != "" {
		s.paths.GameWin64 = v
	}
	return s.paths, savePaths(s.paths)
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
// returns the flash text. It never rewrites a config.txt it could not read, so
// keys the launcher does not manage are preserved. When launch is set it also
// starts the game through Steam.
func (s *server) applyConnection(r *http.Request, launch bool) string {
	cfg, err := ReadConfig(s.configPath())
	if err != nil {
		return "Could not read config.txt, so it was left unchanged: " + err.Error()
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
		return "Could not write config.txt: " + err.Error()
	}
	if !launch {
		return "Config saved to " + s.configPath()
	}
	if err := launchGame(); err != nil {
		return "Config saved, but launching the game failed: " + err.Error()
	}
	return "Config saved. Launching Spyro… keep this tab open to follow your checks."
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

// currentConn reads the saved connection under the lock, for the feed goroutine.
func (s *server) currentConn() feedConn {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, _ := s.readConn()
	return c
}

// launchGame asks Steam to run the game via the steam:// protocol handler,
// which works the same on Linux and Windows.
func launchGame() error {
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

func loadPaths() Paths {
	p := defaultPaths()
	f := launcherStateFile()
	if f == "" {
		return p
	}
	b, err := os.ReadFile(f)
	if err != nil {
		return p
	}
	var saved Paths
	if json.Unmarshal(b, &saved) == nil {
		if saved.ConfigDir != "" {
			p.ConfigDir = saved.ConfigDir
		}
		if saved.GameWin64 != "" {
			p.GameWin64 = saved.GameWin64
		}
	}
	return p
}

func savePaths(p Paths) error {
	f := launcherStateFile()
	if f == "" {
		return errors.New("no user config dir")
	}
	if err := os.MkdirAll(filepath.Dir(f), 0755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(f, b, 0644)
}

// runInstall performs a headless install using the resolved paths and prints
// one line per step. It returns a process exit code.
func runInstall(noDownload bool) int {
	p := loadPaths()
	results := Install(p, sourceDir(), installOptions{NoDownload: noDownload})
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

func main() {
	addr := flag.String("addr", "127.0.0.1:0", "listen address (default: random localhost port)")
	noBrowser := flag.Bool("no-browser", false, "do not open a browser automatically")
	install := flag.Bool("install", false, "copy the client files into place, then exit")
	noDownload := flag.Bool("no-download", false, "with -install, do not fetch UE4SS; report it missing")
	flag.Parse()

	if *install {
		os.Exit(runInstall(*noDownload))
	}

	tmpl, err := template.New("index").Parse(indexHTML)
	if err != nil {
		log.Fatalf("parse template: %v", err)
	}

	s := &server{paths: loadPaths(), tmpl: tmpl, feed: NewFeed(), token: newToken()}
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
