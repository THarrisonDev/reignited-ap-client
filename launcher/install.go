package main

import (
	"archive/zip"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// ue4ssURL is the pinned UE4SS release the mod is built against (v3.0.1).
// Installing any other version is unsupported; see INSTALL.md.
const ue4ssURL = "https://github.com/UE4SS-RE/RE-UE4SS/releases/download/v3.0.1/UE4SS_v3.0.1.zip"

// installResult is the outcome of one installer step, shown to the player and
// printed by the -install flag.
type installResult struct {
	Step   string
	OK     bool
	Detail string
}

// installOptions tunes one install run. The zero value is a full local install
// with the pinned UE4SS download enabled.
type installOptions struct {
	// HTTPClient fetches UE4SS when it is missing; nil uses a default client.
	HTTPClient *http.Client
	// UE4SSURL overrides the pinned download (tests).
	UE4SSURL string
	// NoDownload skips fetching UE4SS, reporting it missing instead.
	NoDownload bool
}

// sourceDir is the directory the launcher runs from — where the sibling release
// artifacts (srtap_checkd.exe, srt_bridge.zip) live.
func sourceDir() string {
	exe, err := os.Executable()
	if err != nil {
		return "."
	}
	return filepath.Dir(exe)
}

// Install copies the client artifacts into the resolved paths and enables the
// mod. Steps are best-effort: a failing step is reported and the rest still
// run, so a player always gets as far as possible. Callers re-run Verify for
// the authoritative checklist afterwards.
func Install(p Paths, src string, opts installOptions) []installResult {
	var out []installResult
	add := func(step string, ok bool, detail string) {
		out = append(out, installResult{step, ok, detail})
	}

	if err := os.MkdirAll(p.ConfigDir, 0755); err != nil {
		add("Bridge folder", false, err.Error())
	} else {
		add("Bridge folder", true, p.ConfigDir)
	}

	if src != "" {
		from := filepath.Join(src, "srtap_checkd.exe")
		if !fileExists(from) {
			add("Save scanner (srtap_checkd.exe)", false, "not found beside the launcher: "+from)
		} else if err := installCheckd(from, p.ConfigDir); err != nil {
			add("Save scanner (srtap_checkd.exe)", false, err.Error())
		} else {
			add("Save scanner (srtap_checkd.exe)", true, filepath.Join(p.ConfigDir, "srtap_checkd.exe"))
		}
	}

	if fileExists(filepath.Join(p.GameWin64, "UE4SS.dll")) &&
		fileExists(filepath.Join(p.GameWin64, "dwmapi.dll")) {
		add("UE4SS", true, "already installed")
	} else if opts.NoDownload {
		add("UE4SS", false, "missing — install UE4SS v3.0.1 manually (see INSTALL.md)")
	} else if err := installUE4SS(p.GameWin64, opts); err != nil {
		add("UE4SS", false, err.Error()+" — install v3.0.1 manually from "+
			"https://github.com/UE4SS-RE/RE-UE4SS/releases")
	} else {
		add("UE4SS", true, "v3.0.1 installed into Win64")
	}

	if src != "" {
		if err := installMod(src, p.GameWin64); err != nil {
			add("srt_bridge mod", false, err.Error())
		} else {
			add("srt_bridge mod", true, filepath.Join(p.GameWin64, "Mods", "srt_bridge"))
		}
	}

	modsTxt := filepath.Join(p.GameWin64, "Mods", "mods.txt")
	if err := enableMod(modsTxt); err != nil {
		add("Enable mod (mods.txt)", false, err.Error())
	} else {
		add("Enable mod (mods.txt)", true, modsTxt)
	}

	return out
}

// installMod unpacks the mod tree beside the launcher, preferring the packaged
// srt_bridge.zip and falling back to an unpacked srt_bridge/ directory.
func installMod(src, win64 string) error {
	if zipPath := filepath.Join(src, "srt_bridge.zip"); fileExists(zipPath) {
		return extractZip(zipPath, win64, keepModConfig)
	}
	tree := filepath.Join(src, "srt_bridge")
	if dirExists(tree) {
		return copyTree(tree, win64, keepModConfig)
	}
	return fmt.Errorf("srt_bridge.zip not found beside the launcher")
}

// installCheckd copies the daemon into the bridge folder, keeping one
// timestamped backup of any previous binary (mirrors `make deploy-checkd`).
func installCheckd(from, configDir string) error {
	to := filepath.Join(configDir, "srtap_checkd.exe")
	if fileExists(to) {
		if err := copyFile(to, to+".bak-"+time.Now().Format("20060102-150405")); err != nil {
			return err
		}
	}
	return copyFile(from, to)
}

// installUE4SS downloads the pinned release and unpacks the whole archive
// (dwmapi.dll proxy, UE4SS.dll, ue4ss/, Mods/) into the game's Win64 folder.
func installUE4SS(win64 string, opts installOptions) error {
	url := opts.UE4SSURL
	if url == "" {
		url = ue4ssURL
	}
	client := opts.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: 2 * time.Minute}
	}
	resp, err := client.Get(url)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("UE4SS download failed: %s", resp.Status)
	}
	tmp, err := os.CreateTemp("", "ue4ss-*.zip")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer func() { _ = os.Remove(tmpPath) }()
	if _, err := io.Copy(tmp, resp.Body); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return extractZip(tmpPath, win64, nil)
}

// enableMod ensures mods.txt has an uncommented `srt_bridge : 1`, preserving
// every other line and taking one timestamped backup before a rewrite. A
// missing file is created; an existing disabled line is rewritten in place.
func enableMod(path string) error {
	const line = "srt_bridge : 1"
	data, err := os.ReadFile(path)
	if err != nil {
		if !os.IsNotExist(err) {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			return err
		}
		return os.WriteFile(path, []byte(line+"\n"), 0644)
	}

	lines := strings.Split(strings.ReplaceAll(string(data), "\r\n", "\n"), "\n")
	changed, found := false, false
	for i, raw := range lines {
		trimmed := strings.TrimSpace(raw)
		if trimmed == "" || strings.HasPrefix(trimmed, ";") {
			continue
		}
		name, _, ok := strings.Cut(trimmed, ":")
		if !ok || strings.TrimSpace(name) != "srt_bridge" {
			continue
		}
		found = true
		if trimmed != line {
			lines[i] = line
			changed = true
		}
	}
	if !found {
		if n := len(lines); n > 0 && lines[n-1] == "" {
			lines[n-1] = line
			lines = append(lines, "")
		} else {
			lines = append(lines, line)
		}
		changed = true
	}
	if !changed {
		return nil
	}
	if err := copyFile(path, path+".bak-"+time.Now().Format("20060102-150405")); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(strings.Join(lines, "\n")), 0644)
}

// keepModConfig protects the player's debug toggle from being reset by a mod
// re-install. It only preserves files that already exist.
func keepModConfig(rel string, exists bool) bool {
	return exists && filepath.ToSlash(rel) == "Mods/srt_bridge/Scripts/config.txt"
}

// extractZip unpacks zipPath into dest. Entries that would escape dest are
// rejected (zip-slip). When keep returns true for an entry already present at
// the destination, that file is left untouched.
func extractZip(zipPath, dest string, keep func(rel string, exists bool) bool) error {
	r, err := zip.OpenReader(zipPath)
	if err != nil {
		return err
	}
	defer func() { _ = r.Close() }()
	for _, f := range r.File {
		rel := filepath.Clean(filepath.FromSlash(f.Name))
		if rel == "." || rel == ".." ||
			strings.HasPrefix(rel, ".."+string(os.PathSeparator)) || filepath.IsAbs(rel) {
			return fmt.Errorf("unsafe path in archive: %s", f.Name)
		}
		target := filepath.Join(dest, rel)
		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(target, 0755); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
			return err
		}
		if _, err := os.Stat(target); err == nil && keep != nil && keep(rel, true) {
			continue
		}
		if err := writeZipEntry(f, target); err != nil {
			return err
		}
	}
	return nil
}

// writeZipEntry streams one archive member into target, using its stored mode
// when present.
func writeZipEntry(f *zip.File, target string) error {
	rc, err := f.Open()
	if err != nil {
		return err
	}
	defer func() { _ = rc.Close() }()
	mode := f.Mode()
	if mode == 0 {
		mode = 0644
	}
	out, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode.Perm())
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, rc); err != nil {
		_ = out.Close()
		return err
	}
	return out.Close()
}

// copyTree mirrors src into dest. keep lets callers preserve existing files.
func copyTree(src, dest string, keep func(rel string, exists bool) bool) error {
	return filepath.WalkDir(src, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dest, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0755)
		}
		if _, err := os.Stat(target); err == nil && keep != nil && keep(filepath.ToSlash(rel), true) {
			return nil
		}
		return copyFile(path, target)
	})
}

// copyFile copies from to to, creating parent directories.
func copyFile(from, to string) error {
	if err := os.MkdirAll(filepath.Dir(to), 0755); err != nil {
		return err
	}
	in, err := os.Open(from)
	if err != nil {
		return err
	}
	defer func() { _ = in.Close() }()
	out, err := os.Create(to)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		_ = out.Close()
		return err
	}
	return out.Close()
}
