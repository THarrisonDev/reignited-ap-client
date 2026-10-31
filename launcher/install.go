// Author: Tim Harrison
// Created: 2026-10-11
// Updated: 2026-10-31

package main

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/hex"
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

// ue4ssSHA256 is the SHA-256 of the pinned UE4SS_v3.0.1.zip. The archive is
// unpacked into the game's Win64 folder, where its dwmapi.dll proxy is loaded
// and executed, so it is verified before a single byte is extracted.
const ue4ssSHA256 = "4b47d4bceddd2f561a4e395bfa00924ccfc945af576a2d0c613e6537846c57ec"

// maxUE4SSBytes bounds the download. The pinned zip is ~5.5 MB, so 64 MiB is
// far above it but still stops a hostile redirect from filling the disk.
const maxUE4SSBytes = 64 << 20

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
	// UE4SSSHA256 is the expected download hash; empty uses the pinned one.
	UE4SSSHA256 string
	// UE4SSMaxBytes caps the download; zero uses maxUE4SSBytes.
	UE4SSMaxBytes int64
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
// the authoritative checklist afterwards. A Game folder that does not exist is
// refused before any step touches it, so a typo'd override cannot grow a fake
// install tree that Verify would then report green.
func Install(p Paths, src string, opts installOptions) []installResult {
	if p.ConfigDir == "" || p.GameWin64 == "" {
		return []installResult{{"Folder locations", false,
			"both folders are required — set the Bridge folder and Game folder override in the launcher"}}
	}
	out := []installResult{resultOf("Bridge folder", p.ConfigDir, os.MkdirAll(p.ConfigDir, 0755))}
	if src != "" {
		out = append(out, installScanner(src, p.ConfigDir))
	}
	if !dirExists(p.GameWin64) {
		out = append(out, installResult{"Game folder", false,
			"not found: " + p.GameWin64 + " — set the Game folder override to your Spyro Reignited Trilogy install's Falcon\\Binaries\\Win64"})
		return out
	}
	out = append(out, installUE4SSStep(p.GameWin64, opts))
	if src != "" {
		modDir := filepath.Join(p.GameWin64, "Mods", "srt_bridge")
		out = append(out, resultOf("srt_bridge mod", modDir, installMod(src, p.GameWin64)))
	}
	modsTxt := filepath.Join(p.GameWin64, "Mods", "mods.txt")
	return append(out, resultOf("Enable mod (mods.txt)", modsTxt, enableMod(modsTxt)))
}

// resultOf is one step's outcome: detail when err is nil, else its message.
func resultOf(step, detail string, err error) installResult {
	if err != nil {
		return installResult{step, false, err.Error()}
	}
	return installResult{step, true, detail}
}

// installScanner copies the save scanner from beside the launcher.
func installScanner(src, configDir string) installResult {
	const step = "Save scanner (srtap_checkd.exe)"
	from := filepath.Join(src, "srtap_checkd.exe")
	if !fileExists(from) {
		return installResult{step, false, "not found beside the launcher: " + from}
	}
	return resultOf(step, filepath.Join(configDir, "srtap_checkd.exe"), installCheckd(from, configDir))
}

// installUE4SSStep reports the UE4SS step: an existing install passes without a
// download, and NoDownload never fetches one.
func installUE4SSStep(win64 string, opts installOptions) installResult {
	const step = "UE4SS"
	if fileExists(filepath.Join(win64, "UE4SS.dll")) && fileExists(filepath.Join(win64, "dwmapi.dll")) {
		return installResult{step, true, "already installed"}
	}
	if opts.NoDownload {
		return installResult{step, false, "missing — install UE4SS v3.0.1 manually (see INSTALL.md)"}
	}
	if err := installUE4SS(win64, opts); err != nil {
		return installResult{step, false, err.Error() + " — install v3.0.1 manually from " +
			"https://github.com/UE4SS-RE/RE-UE4SS/releases"}
	}
	return installResult{step, true, "v3.0.1 installed into Win64"}
}

// installMod unpacks the mod tree beside the launcher, preferring the packaged
// srt_bridge.zip and falling back to an unpacked srt_bridge/ directory.
func installMod(src, win64 string) error {
	if zipPath := filepath.Join(src, "srt_bridge.zip"); fileExists(zipPath) {
		return extractZip(zipPath, win64)
	}
	tree := filepath.Join(src, "srt_bridge")
	if dirExists(tree) {
		return copyTree(tree, win64)
	}
	return fmt.Errorf("srt_bridge.zip not found beside the launcher")
}

// backupStamp names one backup. Millisecond precision, so two installs in the
// same second cannot overwrite each other's backup.
func backupStamp() string {
	return time.Now().Format("20060102-150405.000")
}

// installCheckd copies the daemon into the bridge folder, keeping one
// timestamped backup of any previous binary (mirrors `make deploy-checkd`).
func installCheckd(from, configDir string) error {
	to := filepath.Join(configDir, "srtap_checkd.exe")
	if fileExists(to) {
		if err := copyFile(to, to+".bak-"+backupStamp()); err != nil {
			return err
		}
	}
	return copyFile(from, to)
}

// installUE4SS downloads the pinned release and unpacks the whole archive
// (dwmapi.dll proxy, UE4SS.dll, ue4ss/, Mods/) into the game's Win64 folder.
// The download is size-capped and hash-checked before extraction: the archive
// drops an executable DLL into the game process, so an unchecked body is code
// execution.
func installUE4SS(win64 string, opts installOptions) error {
	tmpPath, err := fetchUE4SS(opts)
	if err != nil {
		return err
	}
	defer func() { _ = os.Remove(tmpPath) }()
	return extractZip(tmpPath, win64)
}

// downloadSettings fills in the pinned defaults for the archive download.
func downloadSettings(opts installOptions) (url, want string, limit int64, client *http.Client) {
	url, want, limit, client = opts.UE4SSURL, opts.UE4SSSHA256, opts.UE4SSMaxBytes, opts.HTTPClient
	if url == "" {
		url = ue4ssURL
	}
	if want == "" {
		want = ue4ssSHA256
	}
	if limit <= 0 {
		limit = maxUE4SSBytes
	}
	if client == nil {
		client = &http.Client{Timeout: 2 * time.Minute}
	}
	return url, want, limit, client
}

// fetchUE4SS downloads the archive into a temporary file, verifies it, and
// returns the file's path; the caller removes it.
func fetchUE4SS(opts installOptions) (string, error) {
	url, want, limit, client := downloadSettings(opts)
	resp, err := client.Get(url)
	if err != nil {
		return "", err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("UE4SS download failed: %s", resp.Status)
	}
	path, sum, n, err := saveDownload(resp.Body, limit)
	if err != nil {
		_ = os.Remove(path)
		return "", err
	}
	if err := verifyDownload(sum, n, want, limit); err != nil {
		_ = os.Remove(path)
		return "", err
	}
	return path, nil
}

// saveDownload streams body into a temporary file, returning the file's path,
// its SHA-256 and its size.
func saveDownload(body io.Reader, limit int64) (path, sum string, n int64, err error) {
	f, err := os.CreateTemp("", "ue4ss-*.zip")
	if err != nil {
		return "", "", 0, err
	}
	path = f.Name()
	digest := sha256.New()
	// +1 so a body exactly at the cap is still detected as too large.
	n, err = io.Copy(io.MultiWriter(f, digest), io.LimitReader(body, limit+1))
	if err != nil {
		_ = f.Close()
		return path, "", 0, err
	}
	if err := f.Close(); err != nil {
		return path, "", 0, err
	}
	return path, hex.EncodeToString(digest.Sum(nil)), n, nil
}

// verifyDownload refuses a body over limit or one that does not match the pin.
func verifyDownload(sum string, n int64, want string, limit int64) error {
	if n > limit {
		return fmt.Errorf("UE4SS download is larger than %d bytes", limit)
	}
	if !strings.EqualFold(sum, want) {
		return fmt.Errorf("UE4SS download failed its SHA-256 check (got %s, want %s)", sum, want)
	}
	return nil
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
		return createModsTxt(path, line+"\n")
	}

	lines, changed := enabledLines(string(data), line)
	if !changed {
		return nil
	}
	if err := copyFile(path, path+".bak-"+backupStamp()); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(strings.Join(lines, "\n")), 0644)
}

// createModsTxt writes a fresh mods.txt holding content verbatim.
func createModsTxt(path, content string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(content), 0644)
}

// enabledLines rewrites every srt_bridge line of text to line, appending one
// when the file names the mod nowhere, and reports whether anything changed.
func enabledLines(text, line string) (lines []string, changed bool) {
	lines = strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	found := false
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
	return lines, changed
}

// extractZip unpacks zipPath into dest, overwriting anything already there.
// Entries that would escape dest are rejected (zip-slip).
func extractZip(zipPath, dest string) error {
	r, err := zip.OpenReader(zipPath)
	if err != nil {
		return err
	}
	defer func() { _ = r.Close() }()
	for _, f := range r.File {
		if err := extractEntry(f, dest); err != nil {
			return err
		}
	}
	return nil
}

// extractEntry unpacks one archive member into dest.
func extractEntry(f *zip.File, dest string) error {
	rel, err := memberPath(f.Name)
	if err != nil {
		return err
	}
	target := filepath.Join(dest, rel)
	if f.FileInfo().IsDir() {
		return os.MkdirAll(target, 0755)
	}
	if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
		return err
	}
	return writeZipEntry(f, target)
}

// memberPath is an archive member's path relative to the destination, or an
// error when the name would escape it.
func memberPath(name string) (string, error) {
	rel := filepath.Clean(filepath.FromSlash(name))
	if rel == "." || rel == ".." ||
		strings.HasPrefix(rel, ".."+string(os.PathSeparator)) || filepath.IsAbs(rel) {
		return "", fmt.Errorf("unsafe path in archive: %s", name)
	}
	return rel, nil
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
	if err := refuseSymlinkTarget(target); err != nil {
		return err
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

// refuseSymlinkTarget errors when path already exists as a symlink. Creating or
// truncating through one would write to wherever it points, outside the
// destination tree the installer is confined to.
func refuseSymlinkTarget(path string) error {
	fi, err := os.Lstat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	if fi.Mode()&fs.ModeSymlink != 0 {
		return fmt.Errorf("refusing to write through a symlink: %s", path)
	}
	return nil
}

// copyTree mirrors src into dest, overwriting existing files. Symlinks in the
// source tree are skipped, never followed: following one could copy a file from
// outside the tree, or overwrite a symlink target in dest.
func copyTree(src, dest string) error {
	return filepath.WalkDir(src, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dest, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0755)
		}
		return copyFile(path, target)
	})
}

// copyFile copies from to to, creating parent directories.
func copyFile(from, to string) error {
	if err := os.MkdirAll(filepath.Dir(to), 0755); err != nil {
		return err
	}
	if err := refuseSymlinkTarget(to); err != nil {
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
