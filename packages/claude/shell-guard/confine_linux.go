package main

import (
	"errors"
	"fmt"
	"syscall"
	"unsafe"
)

// Landlock's system calls (the same numbers on every architecture), and the
// flags and structures they take, from linux/landlock.h; Go's syscall package
// has none of them, nor O_PATH.
const (
	sysLandlockCreateRuleset = 444
	sysLandlockAddRule       = 445
	sysLandlockRestrictSelf  = 446

	landlockCreateRulesetVersion = 1 << 0
	landlockRulePathBeneath      = 1

	accessWriteFile  = 1 << 1
	accessRemoveDir  = 1 << 4
	accessRemoveFile = 1 << 5
	accessMakeChar   = 1 << 6
	accessMakeDir    = 1 << 7
	accessMakeReg    = 1 << 8
	accessMakeSock   = 1 << 9
	accessMakeFifo   = 1 << 10
	accessMakeBlock  = 1 << 11
	accessMakeSym    = 1 << 12
	accessRefer      = 1 << 13 // ABI 2
	accessTruncate   = 1 << 14 // ABI 3

	oPath           = 0x200000
	prSetNoNewPrivs = 38
)

// errUnavailable is the error confine wraps when the kernel has no Landlock.
var errUnavailable = errors.New("the kernel has no Landlock")

// rulesetAttr is struct landlock_ruleset_attr up to handled_access_fs, the
// part every ABI version reads.
type rulesetAttr struct {
	handledAccessFS uint64
}

// pathBeneathAttr is struct landlock_path_beneath_attr. That struct is packed:
// the kernel reads its first 12 bytes, which this layout matches.
type pathBeneathAttr struct {
	allowedAccess uint64
	parentFd      int32
}

// confine keeps the calling thread, and what it execs, from writing under the
// protected folders. Only writes are handled, so reads and execs go on as
// before. Renaming across folders (refer), which Landlock denies from ABI 2 on
// unless it is granted, and truncating (ABI 3) are handled when the kernel has
// them.
func confine(protected []string) error {
	abi, _, errno := syscall.Syscall(sysLandlockCreateRuleset, 0, 0, landlockCreateRulesetVersion)
	if errno != 0 {
		return fmt.Errorf("%w: %v", errUnavailable, errno)
	}
	dirAccess := uint64(accessWriteFile | accessRemoveDir | accessRemoveFile | accessMakeChar |
		accessMakeDir | accessMakeReg | accessMakeSock | accessMakeFifo | accessMakeBlock | accessMakeSym)
	fileAccess := uint64(accessWriteFile)
	if abi >= 2 {
		dirAccess |= accessRefer
	}
	if abi >= 3 {
		dirAccess |= accessTruncate
		fileAccess |= accessTruncate
	}
	attr := rulesetAttr{handledAccessFS: dirAccess}
	ruleset, _, errno := syscall.Syscall(sysLandlockCreateRuleset, uintptr(unsafe.Pointer(&attr)), unsafe.Sizeof(attr), 0)
	if errno != 0 {
		return fmt.Errorf("creating a Landlock ruleset: %w", errno)
	}
	defer func() { _ = syscall.Close(int(ruleset)) }()
	for _, g := range plan(protected) {
		access := fileAccess
		if g.dir {
			access = dirAccess
		}
		allow(int(ruleset), g.path, access)
	}
	if _, _, errno := syscall.RawSyscall(syscall.SYS_PRCTL, prSetNoNewPrivs, 1, 0); errno != 0 {
		return fmt.Errorf("setting no_new_privs: %w", errno)
	}
	if _, _, errno := syscall.Syscall(sysLandlockRestrictSelf, ruleset, 0, 0); errno != 0 {
		return fmt.Errorf("enforcing the Landlock ruleset: %w", errno)
	}
	return nil
}

// allow grants access beneath path. An entry it can't open or add a rule for
// (one that went away meanwhile, say) stays unwritable, so its errors are
// dropped.
func allow(ruleset int, path string, access uint64) {
	fd, err := syscall.Open(path, oPath|syscall.O_CLOEXEC|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return
	}
	defer func() { _ = syscall.Close(fd) }()
	attr := pathBeneathAttr{allowedAccess: access, parentFd: int32(fd)}
	_, _, _ = syscall.Syscall6(sysLandlockAddRule, uintptr(ruleset), landlockRulePathBeneath, uintptr(unsafe.Pointer(&attr)), 0, 0, 0)
}
