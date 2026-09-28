// Command claude-seccomp-bpf writes to stdout a classic-BPF seccomp filter, in
// the seccomp_export_bpf format bubblewrap's --seccomp expects, that fails
// ioctl(TIOCSTI) and ioctl(TIOCLINUX) with EPERM and allows every other syscall.
//
// It replaces the cBPF that claude-sandbox.bash used to hand-assemble byte by
// byte: a process inside the bubblewrap namespace must not be able to push
// characters into the launching terminal's input queue (CVE-2017-5226), which
// the host shell would then run once claude exits. libseccomp compiles the arch
// dispatch and the native/compat syscall-number checks, so the compat-ABI bypass
// the hand-rolled filter had to reason about explicitly is handled by the library.
// The one width detail libseccomp does NOT infer is that ioctl's request arg is
// 32-bit in the kernel: the request comparison is masked to the low word (see
// requestMask) so a high-bit alias of TIOCSTI cannot slip past it.
//
// See sources/.config/shell/scripts/claude-sandbox.bash, which runs this and
// passes the result to bwrap on a numeric fd.
package main

import (
	"fmt"
	"os"
	"runtime"
	"syscall"

	seccomp "github.com/seccomp/libseccomp-golang"
)

// TIOCSTI and TIOCLINUX both let a process write into a controlling terminal, so
// both are blocked. The request numbers are identical across the architectures
// this filter targets (asm-generic).
const (
	tiocsti   = 0x5412
	tioclinux = 0x541C

	// requestMask restricts the ioctl-request comparison to its low 32 bits. The
	// kernel declares ioctl's cmd as a 32-bit unsigned int and truncates the
	// argument (SYSCALL_DEFINE3(ioctl, unsigned int fd, unsigned int cmd, ...)),
	// but seccomp compares the full 64-bit register. Without this mask, a plain
	// equality rule additionally requires the high word to be zero, so a request
	// like 0x1_0000_5412 misses the rule and falls through to the default ALLOW,
	// yet still reaches the kernel as TIOCSTI — the CVE-2017-5226 bypass. Masking
	// mirrors the kernel's truncation and closes it.
	requestMask = 0xffff_ffff
)

// archsFor maps a GOARCH to the seccomp architectures the filter must cover: the
// native architecture and its 32-bit compat ABI. Both are required — a 32-bit
// process reports the compat arch in seccomp_data.arch, so a filter naming only
// the native arch would let it through, which is the exact TIOCSTI bypass this
// filter exists to close.
func archsFor(goarch string) ([]seccomp.ScmpArch, error) {
	switch goarch {
	case "amd64":
		return []seccomp.ScmpArch{seccomp.ArchAMD64, seccomp.ArchX86}, nil
	case "arm64":
		return []seccomp.ScmpArch{seccomp.ArchARM64, seccomp.ArchARM}, nil
	default:
		return nil, fmt.Errorf("no TIOCSTI seccomp filter defined for GOARCH %q", goarch)
	}
}

// buildFilter returns an allow-by-default seccomp filter that fails TIOCSTI and
// TIOCLINUX ioctls with EPERM, compiled for every architecture in archs. The
// caller owns the returned filter and must call Release on it.
func buildFilter(archs []seccomp.ScmpArch) (*seccomp.ScmpFilter, error) {
	if len(archs) == 0 {
		return nil, fmt.Errorf("buildFilter: no architectures given")
	}

	filter, err := seccomp.NewFilter(seccomp.ActAllow)
	if err != nil {
		return nil, fmt.Errorf("new filter: %w", err)
	}

	// NewFilter seeds the native arch; add the rest. Guard with IsArchPresent so
	// re-adding the native arch (when it is already in the list) is not an error.
	for _, arch := range archs {
		present, archErr := filter.IsArchPresent(arch)
		if archErr != nil {
			filter.Release()
			return nil, fmt.Errorf("check arch %v: %w", arch, archErr)
		}
		if present {
			continue
		}
		if addErr := filter.AddArch(arch); addErr != nil {
			filter.Release()
			return nil, fmt.Errorf("add arch %v: %w", arch, addErr)
		}
	}

	ioctl, err := seccomp.GetSyscallFromName("ioctl")
	if err != nil {
		filter.Release()
		return nil, fmt.Errorf("resolve ioctl: %w", err)
	}

	block := seccomp.ActErrno.SetReturnCode(int16(syscall.EPERM))
	// One rule per request value; libseccomp emits the masked arg[1] comparison
	// ((arg & requestMask) == req, i.e. the low 32 bits only) and applies each
	// rule across every configured architecture.
	for _, req := range []uint64{tiocsti, tioclinux} {
		cond, condErr := seccomp.MakeCondition(1, seccomp.CompareMaskedEqual, requestMask, req)
		if condErr != nil {
			filter.Release()
			return nil, fmt.Errorf("condition for request %#x: %w", req, condErr)
		}
		if ruleErr := filter.AddRuleConditional(ioctl, block, []seccomp.ScmpCondition{cond}); ruleErr != nil {
			filter.Release()
			return nil, fmt.Errorf("add rule for request %#x: %w", req, ruleErr)
		}
	}

	return filter, nil
}

// run builds the filter for goarch and writes it to out in seccomp_export_bpf
// format.
func run(out *os.File, goarch string) error {
	archs, err := archsFor(goarch)
	if err != nil {
		return err
	}
	filter, err := buildFilter(archs)
	if err != nil {
		return err
	}
	defer filter.Release()
	if err := filter.ExportBPF(out); err != nil {
		return fmt.Errorf("export bpf: %w", err)
	}
	return nil
}

func main() {
	if err := run(os.Stdout, runtime.GOARCH); err != nil {
		fmt.Fprintf(os.Stderr, "claude-seccomp-bpf: %v\n", err)
		os.Exit(1)
	}
}
