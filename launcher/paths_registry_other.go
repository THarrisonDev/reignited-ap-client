//go:build !windows

package main

// readSteamRegistryRoots is the no-op registry lookup for non-Windows hosts.
var readSteamRegistryRoots = func() []string { return nil }
