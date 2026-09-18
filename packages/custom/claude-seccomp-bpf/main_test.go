package main

import (
	"fmt"
	"os"
	"os/exec"
	"reflect"
	"runtime"
	"testing"

	seccomp "github.com/seccomp/libseccomp-golang"
	"golang.org/x/sys/unix"
)

// Exit codes the re-exec'd helper reports to TestFilterBlocksTIOCSTI.
const (
	helperPass        = 0
	helperSkip        = 3
	helperFailTIOCSTI = 5
	helperFailOther   = 6
)

// TestMain lets the process re-exec itself as the seccomp helper so the
// irreversible seccomp load runs in a throwaway child, never tainting the test
// binary's own threads.
func TestMain(m *testing.M) {
	if os.Getenv("CLAUDE_SECCOMP_TEST_HELPER") == "1" {
		os.Exit(seccompHelper())
	}
	os.Exit(m.Run())
}

func TestArchsFor(t *testing.T) {
	tests := []struct {
		name    string
		goarch  string
		want    []seccomp.ScmpArch
		wantErr bool
	}{
		{"amd64 adds i386 compat", "amd64", []seccomp.ScmpArch{seccomp.ArchAMD64, seccomp.ArchX86}, false},
		{"arm64 adds arm compat", "arm64", []seccomp.ScmpArch{seccomp.ArchARM64, seccomp.ArchARM}, false},
		{"unsupported arch errors", "riscv64", nil, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := archsFor(tt.goarch)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("archsFor(%q) = %v, want error", tt.goarch, got)
				}
				return
			}
			if err != nil {
				t.Fatalf("archsFor(%q) unexpected error: %v", tt.goarch, err)
			}
			if !reflect.DeepEqual(got, tt.want) {
				t.Errorf("archsFor(%q) = %v, want %v", tt.goarch, got, tt.want)
			}
		})
	}
}

// TestExportWellFormed checks that the exported filter is a non-empty run of
// whole 8-byte sock_filter structs, the shape bwrap's --seccomp loader requires.
// It builds for a fixed arch list so the result is independent of the test host:
// ExportBPF cross-compiles and does not require the arch to be native.
func TestExportWellFormed(t *testing.T) {
	filter, err := buildFilter([]seccomp.ScmpArch{seccomp.ArchAMD64, seccomp.ArchX86})
	if err != nil {
		t.Fatalf("buildFilter: %v", err)
	}
	defer filter.Release()

	f, err := os.CreateTemp(t.TempDir(), "seccomp-*.bpf")
	if err != nil {
		t.Fatalf("temp file: %v", err)
	}
	defer func() { _ = f.Close() }()

	if err := filter.ExportBPF(f); err != nil {
		t.Fatalf("ExportBPF: %v", err)
	}
	info, err := f.Stat()
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if info.Size() == 0 {
		t.Fatal("ExportBPF wrote no bytes")
	}
	if info.Size()%8 != 0 {
		t.Errorf("ExportBPF wrote %d bytes, not a multiple of the 8-byte sock_filter size", info.Size())
	}
}

// TestFilterBlocksTIOCSTI verifies behaviourally, in a child process, that the
// filter fails ioctl(TIOCSTI) with EPERM while leaving an unrelated ioctl alone.
// It skips where the environment cannot load a seccomp filter (e.g. a build
// sandbox that blocks seccomp(2)) rather than failing the build.
func TestFilterBlocksTIOCSTI(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("seccomp is Linux-only")
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatalf("os.Executable: %v", err)
	}
	cmd := exec.Command(exe)
	cmd.Env = append(os.Environ(), "CLAUDE_SECCOMP_TEST_HELPER=1")
	out, _ := cmd.CombinedOutput()
	switch code := cmd.ProcessState.ExitCode(); code {
	case helperPass:
		// filter behaved correctly
	case helperSkip:
		t.Skipf("environment cannot load a seccomp filter: %s", out)
	default:
		t.Fatalf("seccomp helper exit %d: %s", code, out)
	}
}

// seccompHelper runs in the re-exec'd child: it loads the filter for the native
// arch, then checks the two ioctls. Its return value becomes the child's exit
// code, read back by TestFilterBlocksTIOCSTI.
func seccompHelper() int {
	archs, err := archsFor(runtime.GOARCH)
	if err != nil {
		return helperSkip
	}
	filter, err := buildFilter(archs)
	if err != nil {
		return helperSkip
	}
	defer filter.Release()
	if err := filter.Load(); err != nil {
		return helperSkip
	}

	f, err := os.Open(os.DevNull)
	if err != nil {
		return helperSkip
	}
	defer func() { _ = f.Close() }()
	fd := int(f.Fd())

	// Blocked by the filter before the kernel's ioctl handler runs → EPERM.
	if _, err := unix.IoctlGetInt(fd, tiocsti); err != unix.EPERM {
		fmt.Fprintf(os.Stderr, "TIOCSTI: got %v, want EPERM\n", err)
		return helperFailTIOCSTI
	}
	// Regression for the argument-width bypass (CVE-2017-5226): the kernel
	// truncates ioctl's cmd to 32 bits, so TIOCSTI with a non-zero high word still
	// acts as TIOCSTI. The masked rule must block it too; a full-width equality
	// rule would let it fall through to the default ALLOW and reach the terminal.
	if _, err := unix.IoctlGetInt(fd, tiocsti|(1<<32)); err != unix.EPERM {
		fmt.Fprintf(os.Stderr, "TIOCSTI high-bits alias: got %v, want EPERM\n", err)
		return helperFailTIOCSTI
	}
	// Not in the block list, so the filter allows it; the kernel then rejects it
	// on a non-tty with ENOTTY. The point is only that it is NOT EPERM.
	if _, err := unix.IoctlGetInt(fd, unix.TCGETS); err == unix.EPERM {
		fmt.Fprintln(os.Stderr, "TCGETS unexpectedly blocked with EPERM")
		return helperFailOther
	}
	return helperPass
}
