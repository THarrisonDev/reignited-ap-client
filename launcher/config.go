package main

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
)

// canonicalKeys is the stable order the launcher writes known keys in. Any
// other keys already in the file are preserved and appended after these.
var canonicalKeys = []string{"host", "slot", "password", "spawn_checkd"}

// normalizeHost cleans the host field so the player never has to type a scheme.
// apclientpp auto-negotiates the WebSocket scheme when none is given (tries
// wss:// then ws://) and defaults the port to 38281, so a bare "archipelago.gg"
// or "127.0.0.1:38281" just works. An explicit ws://‑ or wss:// is respected;
// a pasted http(s):// (muscle memory) is translated to the ws(s):// equivalent.
func normalizeHost(raw string) string {
	h := strings.TrimSpace(raw)
	h = strings.TrimRight(h, "/")
	if rest, ok := strings.CutPrefix(h, "https://"); ok {
		return "wss://" + rest
	}
	if rest, ok := strings.CutPrefix(h, "http://"); ok {
		return "ws://" + rest
	}
	return h
}

// Config is the mod's config.txt as key=value pairs. It round-trips unknown
// keys so the launcher never drops settings it doesn't manage (e.g.
// spawn_checkd) when it rewrites host/slot/password.
type Config struct {
	Values map[string]string
	order  []string // keys in first-seen order, for stable rewrite of extras
}

// ReadConfig parses config.txt. A missing file yields an empty Config (not an
// error) — the launcher's whole job is to create it the first time.
func ReadConfig(path string) (*Config, error) {
	c := &Config{Values: map[string]string{}}
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return c, nil
		}
		return nil, err
	}
	defer func() { _ = f.Close() }()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		c.Set(strings.TrimSpace(k), strings.TrimSpace(v))
	}
	return c, sc.Err()
}

// Get returns the value for key, or def when absent.
func (c *Config) Get(key, def string) string {
	if v, ok := c.Values[key]; ok {
		return v
	}
	return def
}

// Set assigns a key, remembering first-seen order for stable rewrites.
func (c *Config) Set(key, val string) {
	if _, ok := c.Values[key]; !ok {
		c.order = append(c.order, key)
	}
	c.Values[key] = val
}

// Delete removes a key, e.g. one an older launcher wrote that nothing reads.
func (c *Config) Delete(key string) {
	delete(c.Values, key)
}

// render serializes the config: canonical keys first, then preserved extras.
func (c *Config) render() string {
	seen := map[string]bool{}
	var b strings.Builder
	emit := func(k string) {
		if v, ok := c.Values[k]; ok && !seen[k] {
			seen[k] = true
			b.WriteString(k + "=" + v + "\n")
		}
	}
	for _, k := range canonicalKeys {
		emit(k)
	}
	for _, k := range c.order {
		emit(k)
	}
	return b.String()
}

// Write persists the config to path (creating the dir), temp-file + rename so
// a reader never sees a half-written file.
func (c *Config) Write(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(c.render()), 0644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
