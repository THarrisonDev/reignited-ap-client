//go:build windows

package main

import (
	"path/filepath"

	"golang.org/x/sys/windows/registry"
)

// readSteamRegistryRoots returns the Steam roots recorded in the registry:
// the per-user install then the two machine-wide locations. Missing keys and
// values are skipped, and only absolute paths are returned. It is a variable
// so tests can substitute a fake.
var readSteamRegistryRoots = func() []string {
	sources := []struct {
		hive  registry.Key
		key   string
		value string
	}{
		{registry.CURRENT_USER, `Software\Valve\Steam`, "SteamPath"},
		{registry.LOCAL_MACHINE, `SOFTWARE\WOW6432Node\Valve\Steam`, "InstallPath"},
		{registry.LOCAL_MACHINE, `SOFTWARE\Valve\Steam`, "InstallPath"},
	}
	var roots []string
	for _, src := range sources {
		if root, ok := registryPath(src.hive, src.key, src.value); ok {
			roots = append(roots, root)
		}
	}
	return dedupePaths(roots)
}

// registryPath reads one string value from hive\key, ok=false when the key,
// the value or an absolute path is missing.
func registryPath(hive registry.Key, key, value string) (string, bool) {
	k, err := registry.OpenKey(hive, key, registry.QUERY_VALUE)
	if err != nil {
		return "", false
	}
	defer func() { _ = k.Close() }()
	v, _, err := k.GetStringValue(value)
	if err != nil || !filepath.IsAbs(v) {
		return "", false
	}
	return filepath.Clean(v), true
}
