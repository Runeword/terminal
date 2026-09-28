package main

import (
	"encoding/binary"
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

// sockFilter mirrors the kernel's struct sock_filter, the unit of a classic-BPF
// program as seccomp_export_bpf writes it.
type sockFilter struct {
	code uint16
	jt   uint8
	jf   uint8
	k    uint32
}

// seccomp_data field offsets, the arch/syscall/request values the filter
// dispatches on, and the two seccomp return actions.
const (
	offArch  = 4  // seccomp_data.arch
	offArgs1 = 24 // seccomp_data.args[1] low word (high word at +4)

	auditAmd64 = 0xC000003E // AUDIT_ARCH_X86_64
	auditI386  = 0x40000003 // AUDIT_ARCH_I386 (x86_64's 32-bit compat)
	auditArm64 = 0xC00000B7 // AUDIT_ARCH_AARCH64: an arch the amd64 filter omits

	sysIoctlAmd64 = 16
	sysIoctlI386  = 54
	sysRead       = 0

	tcgets = 0x5401

	allowAction = 0x7fff0000 // SECCOMP_RET_ALLOW
	blockAction = 0x00050001 // SECCOMP_RET_ERRNO | EPERM
	killAction  = 0x00000000 // SECCOMP_RET_KILL_THREAD (libseccomp's action for an unconfigured arch)
)

// parseBPF splits the exported filter into sock_filter structs. seccomp_export_bpf
// writes them in the host's native byte order; the arches this filter targets
// (and the build host) are little-endian.
func parseBPF(t *testing.T, b []byte) []sockFilter {
	t.Helper()
	if len(b) == 0 || len(b)%8 != 0 {
		t.Fatalf("filter length %d is not a positive multiple of 8", len(b))
	}
	prog := make([]sockFilter, 0, len(b)/8)
	for i := 0; i < len(b); i += 8 {
		prog = append(prog, sockFilter{
			code: binary.LittleEndian.Uint16(b[i:]),
			jt:   b[i+2],
			jf:   b[i+3],
			k:    binary.LittleEndian.Uint32(b[i+4:]),
		})
	}
	return prog
}

// seccompData builds a 64-byte seccomp_data buffer with the fields the filter
// reads: nr, arch and args[1] (64-bit, so the high word is exercised too).
func seccompData(nr int32, arch uint32, arg1 uint64) []byte {
	d := make([]byte, 64)
	binary.LittleEndian.PutUint32(d[0:], uint32(nr))
	binary.LittleEndian.PutUint32(d[offArch:], arch)
	binary.LittleEndian.PutUint64(d[offArgs1:], arg1)
	return d
}

// evalBPF interprets the classic-BPF subset libseccomp emits over data and
// returns the seccomp action (a BPF_RET k). It is deliberately tiny: an opcode
// the filter uses but this does not handle is a test failure, not a silent pass.
func evalBPF(t *testing.T, prog []sockFilter, data []byte) uint32 {
	t.Helper()
	var a uint32
	for pc := 0; pc < len(prog); {
		in := prog[pc]
		switch in.code {
		case 0x20: // BPF_LD|BPF_W|BPF_ABS: A = data[k]
			if int(in.k)+4 > len(data) {
				t.Fatalf("load past seccomp_data at pc %d (offset %d)", pc, in.k)
			}
			a = binary.LittleEndian.Uint32(data[in.k:])
			pc++
		case 0x15: // BPF_JMP|BPF_JEQ|BPF_K
			if a == in.k {
				pc += 1 + int(in.jt)
			} else {
				pc += 1 + int(in.jf)
			}
		case 0x25: // BPF_JMP|BPF_JGT|BPF_K
			if a > in.k {
				pc += 1 + int(in.jt)
			} else {
				pc += 1 + int(in.jf)
			}
		case 0x35: // BPF_JMP|BPF_JGE|BPF_K
			if a >= in.k {
				pc += 1 + int(in.jt)
			} else {
				pc += 1 + int(in.jf)
			}
		case 0x45: // BPF_JMP|BPF_JSET|BPF_K
			if a&in.k != 0 {
				pc += 1 + int(in.jt)
			} else {
				pc += 1 + int(in.jf)
			}
		case 0x54: // BPF_ALU|BPF_AND|BPF_K: A &= k
			a &= in.k
			pc++
		case 0x05: // BPF_JMP|BPF_JA: pc += k
			pc += 1 + int(in.k)
		case 0x06: // BPF_RET|BPF_K
			return in.k
		default:
			t.Fatalf("unhandled BPF opcode 0x%02x at pc %d", in.code, pc)
		}
	}
	t.Fatal("BPF program fell through without a RET")
	return 0
}

// TestFilterProgramSemantics verifies the emitted filter's behaviour by
// interpreting it — no seccomp load, so it runs deterministically everywhere
// (unlike TestFilterBlocksTIOCSTI, which skips where the build sandbox blocks
// seccomp(2)). It pins the security-relevant properties: TIOCSTI and TIOCLINUX
// are blocked on both the native and the 32-bit compat arch, the ioctl request
// is matched on its low 32 bits only (the CVE-2017-5226 high-word bypass the
// masked rule closes), unrelated ioctls and syscalls are allowed, and an arch
// the filter does not cover is killed (libseccomp's default — stricter than the
// old hand-rolled filter, which allowed unknown arches).
func TestFilterProgramSemantics(t *testing.T) {
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
	raw, err := os.ReadFile(f.Name())
	if err != nil {
		t.Fatalf("read filter: %v", err)
	}
	prog := parseBPF(t, raw)

	// The seccomp convention (and the old hand-rolled filter) loads the arch
	// first; this also confirms the little-endian decode is correct.
	if prog[0].code != 0x20 || prog[0].k != offArch {
		t.Fatalf("first instruction = %+v, want load of seccomp_data.arch (offset %d)", prog[0], offArch)
	}

	tests := []struct {
		name string
		nr   int32
		arch uint32
		arg1 uint64
		want uint32
	}{
		{"TIOCSTI native blocked", sysIoctlAmd64, auditAmd64, tiocsti, blockAction},
		{"TIOCLINUX native blocked", sysIoctlAmd64, auditAmd64, tioclinux, blockAction},
		{"TIOCSTI high-word alias blocked", sysIoctlAmd64, auditAmd64, tiocsti | (1 << 32), blockAction},
		{"TIOCSTI compat blocked", sysIoctlI386, auditI386, tiocsti, blockAction},
		{"TIOCLINUX compat blocked", sysIoctlI386, auditI386, tioclinux, blockAction},
		{"TIOCSTI compat high-word alias blocked", sysIoctlI386, auditI386, tiocsti | (1 << 32), blockAction},
		{"TCGETS allowed", sysIoctlAmd64, auditAmd64, tcgets, allowAction},
		{"non-ioctl syscall allowed", sysRead, auditAmd64, tiocsti, allowAction},
		{"uncovered arch killed", sysIoctlAmd64, auditArm64, tiocsti, killAction},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := evalBPF(t, prog, seccompData(tt.nr, tt.arch, tt.arg1)); got != tt.want {
				t.Errorf("action = %#08x, want %#08x", got, tt.want)
			}
		})
	}
}
