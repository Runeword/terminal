//go:build !linux

package main

// confine does nothing outside Linux, which alone has Landlock: there Claude
// Code's own sandbox keeps shell commands out of the config folders.
func confine([]string) error { return nil }
