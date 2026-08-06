package main

import (
	"os"
	"syscall"
	"unsafe"
)

// Minimal termios handling. Raw mode is a hard requirement here — in cooked
// mode the kernel buffers until Enter and eats the control characters we
// decode, so Alt+Tab would never arrive keystroke-by-keystroke. Doing it with
// ioctl directly keeps the package dependency-free (vendorHash = null), at the
// cost of the two tiny per-platform constant files beside this one.

type termState struct {
	fd  uintptr
	old syscall.Termios
}

func ioctlTermios(fd, req uintptr, t *syscall.Termios) error {
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, req, uintptr(unsafe.Pointer(t))); errno != 0 {
		return errno
	}
	return nil
}

func makeRaw(f *os.File) (*termState, error) {
	fd := f.Fd()

	var old syscall.Termios
	if err := ioctlTermios(fd, ioctlReadTermios, &old); err != nil {
		return nil, err
	}

	raw := old
	raw.Iflag &^= syscall.IGNBRK | syscall.BRKINT | syscall.PARMRK | syscall.ISTRIP |
		syscall.INLCR | syscall.IGNCR | syscall.ICRNL | syscall.IXON
	raw.Oflag &^= syscall.OPOST
	raw.Lflag &^= syscall.ECHO | syscall.ECHONL | syscall.ICANON | syscall.ISIG | syscall.IEXTEN
	raw.Cflag &^= syscall.CSIZE | syscall.PARENB
	raw.Cflag |= syscall.CS8
	raw.Cc[syscall.VMIN] = 1
	raw.Cc[syscall.VTIME] = 0

	if err := ioctlTermios(fd, ioctlWriteTermios, &raw); err != nil {
		return nil, err
	}
	return &termState{fd: fd, old: old}, nil
}

func (t *termState) restore() {
	if t == nil {
		return
	}
	old := t.old
	_ = ioctlTermios(t.fd, ioctlWriteTermios, &old)
}

type winsize struct {
	rows, cols, xpixel, ypixel uint16
}

// size reports the popup's dimensions, falling back to a usable default when
// the ioctl fails (as it does when stdout is not a terminal).
func size(f *os.File) (rows, cols int) {
	var ws winsize
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(),
		uintptr(syscall.TIOCGWINSZ), uintptr(unsafe.Pointer(&ws)))
	if errno != 0 || ws.rows == 0 || ws.cols == 0 {
		return 24, 80
	}
	return int(ws.rows), int(ws.cols)
}
