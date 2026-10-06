package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReadConfigMissingFileIsEmpty(t *testing.T) {
	c, err := ReadConfig(filepath.Join(t.TempDir(), "nope.txt"))
	if err != nil {
		t.Fatalf("missing file must not error: %v", err)
	}
	if len(c.values) != 0 {
		t.Fatalf("missing file must yield empty config, got %v", c.values)
	}
	if got := c.Get("host", "default"); got != "default" {
		t.Fatalf("Get default: got %q", got)
	}
}

func TestConfigRoundTripPreservesUnknownKeys(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.txt")
	orig := "host=ws://old:38281\n" +
		"slot=OldName\n" +
		"password=secret\n" +
		"spawn_checkd=1\n" +
		"experimental_flag=42\n" // a key the launcher doesn't manage
	if err := os.WriteFile(path, []byte(orig), 0644); err != nil {
		t.Fatal(err)
	}

	c, err := ReadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	// launcher edits the fields it owns
	c.Set("host", "wss://archipelago.gg:443")
	c.Set("slot", "NewName")

	if err := c.Write(path); err != nil {
		t.Fatal(err)
	}
	got, err := ReadConfig(path)
	if err != nil {
		t.Fatal(err)
	}

	want := map[string]string{
		"host":              "wss://archipelago.gg:443",
		"slot":              "NewName",
		"password":          "secret",
		"spawn_checkd":      "1",
		"experimental_flag": "42", // preserved, not dropped
	}
	for k, v := range want {
		if got.Get(k, "<absent>") != v {
			t.Errorf("key %q: got %q, want %q", k, got.Get(k, "<absent>"), v)
		}
	}

	// canonical keys come first, extras after
	raw, _ := os.ReadFile(path)
	body := string(raw)
	if !strings.HasPrefix(body, "host=") {
		t.Fatalf("expected host= first, got:\n%s", body)
	}
	if strings.Index(body, "spawn_checkd=") > strings.Index(body, "experimental_flag=") {
		t.Fatalf("canonical spawn_checkd should precede the extra key:\n%s", body)
	}
}

func TestNormalizeHost(t *testing.T) {
	cases := []struct{ in, want string }{
		{"archipelago.gg:38281", "archipelago.gg:38281"}, // schemeless kept (library negotiates)
		{"127.0.0.1:38281", "127.0.0.1:38281"},
		{"  archipelago.gg:38281  ", "archipelago.gg:38281"}, // trimmed
		{"archipelago.gg:38281/", "archipelago.gg:38281"},    // trailing slash stripped
		{"ws://127.0.0.1:38281", "ws://127.0.0.1:38281"},     // explicit ws respected
		{"wss://archipelago.gg:38281", "wss://archipelago.gg:38281"},
		{"https://archipelago.gg:38281", "wss://archipelago.gg:38281"}, // web scheme translated
		{"http://127.0.0.1:38281", "ws://127.0.0.1:38281"},
		{"archipelago.gg", "archipelago.gg"}, // no port; library defaults 38281
	}
	for _, c := range cases {
		if got := normalizeHost(c.in); got != c.want {
			t.Errorf("normalizeHost(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestRenderExtrasFollowCanonicalKeys(t *testing.T) {
	c := &Config{values: map[string]string{}}
	c.Set("experimental_flag", "42")
	c.Set("game", "Spyro Reignited Trilogy")
	c.Set("spawn_checkd", "1")
	c.Set("host", "archipelago.gg")
	want := "host=archipelago.gg\nspawn_checkd=1\nexperimental_flag=42\ngame=Spyro Reignited Trilogy\n"
	if got := c.render(); got != want {
		t.Fatalf("render:\n%s\nwant:\n%s", got, want)
	}
}
