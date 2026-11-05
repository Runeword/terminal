package main

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
)

const (
	childHomeVar = "CLAUDE_SHELL_GUARD_TEST_HOME"
	// noLandlock is the child's exit status when the kernel has no Landlock.
	noLandlock = 3
)

// TestConfine runs this test binary again as a child that confines itself and
// tries writes in and beside a protected folder.
func TestConfine(t *testing.T) {
	if home := os.Getenv(childHomeVar); home != "" {
		os.Exit(child(home))
	}
	home := tempDir(t)
	mkdirs(t, home, ".claude-1/projects/p/memory", "repo")
	touch(t, home, ".claude-1/projects/p/memory/MEMORY.md", ".claude-1/settings.json", "repo/main.go")
	cmd := exec.Command(os.Args[0], "-test.run=^TestConfine$")
	cmd.Env = append(os.Environ(), childHomeVar+"="+home)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	var exit *exec.ExitError
	if errors.As(err, &exit) && exit.ExitCode() == noLandlock {
		t.Skipf("no Landlock here: %s", stderr.String())
	}
	if err != nil {
		t.Fatalf("child: %v\n%s%s", err, out, stderr.String())
	}
	got := make(map[string]string)
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		if name, verdict, ok := strings.Cut(scanner.Text(), ": "); ok {
			got[name] = verdict
		}
	}
	want := []struct{ op, verdict string }{
		{"read a memory file", "allowed"},
		{"write a memory file", "denied"},
		{"create a memory file", "denied"},
		{"remove a memory file", "denied"},
		{"create a project", "denied"},
		{"move a file into memory", "denied"},
		{"write a repo file", "allowed"},
		{"create a repo file", "allowed"},
		{"write a file in the profile", "allowed"},
		{"create a file in the profile", "denied"},
	}
	for _, w := range want {
		if got[w.op] != w.verdict {
			t.Errorf("%s: %q, want %q", w.op, got[w.op], w.verdict)
		}
	}
}

// child confines itself as the guard does, with home's .claude-1 as the
// profile, then tries each operation and prints whether it was allowed.
func child(home string) int {
	runtime.LockOSThread()
	err := confine(protectedDirs(home, filepath.Join(home, ".claude-1")))
	if errors.Is(err, errUnavailable) {
		fmt.Fprintln(os.Stderr, err)
		return noLandlock
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	memory := filepath.Join(home, ".claude-1/projects/p/memory")
	write := func(path string) func() error {
		return func() error { return os.WriteFile(path, []byte("y\n"), 0o600) }
	}
	ops := []struct {
		name string
		do   func() error
	}{
		{"read a memory file", func() error { _, err := os.ReadFile(filepath.Join(memory, "MEMORY.md")); return err }},
		{"write a memory file", write(filepath.Join(memory, "MEMORY.md"))},
		{"create a memory file", write(filepath.Join(memory, "new.md"))},
		{"remove a memory file", func() error { return os.Remove(filepath.Join(memory, "MEMORY.md")) }},
		{"create a project", func() error { return os.Mkdir(filepath.Join(home, ".claude-1/projects/q"), 0o700) }},
		{"move a file into memory", func() error {
			return os.Rename(filepath.Join(home, "repo/main.go"), filepath.Join(memory, "main.go"))
		}},
		{"write a repo file", write(filepath.Join(home, "repo/main.go"))},
		{"create a repo file", write(filepath.Join(home, "repo/new.go"))},
		{"write a file in the profile", write(filepath.Join(home, ".claude-1/settings.json"))},
		{"create a file in the profile", write(filepath.Join(home, ".claude-1/new.json"))},
	}
	for _, op := range ops {
		fmt.Printf("%s: %s\n", op.name, verdict(op.do()))
	}
	return 0
}

func verdict(err error) string {
	switch {
	case err == nil:
		return "allowed"
	case errors.Is(err, fs.ErrPermission), errors.Is(err, syscall.EXDEV):
		return "denied"
	}
	return "failed: " + err.Error()
}
