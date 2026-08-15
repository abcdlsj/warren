package runtime

/*
#cgo CFLAGS: -I/Users/lisongjian/Workspace/gh/ghostty/zig-out/include
#cgo LDFLAGS: -L/Users/lisongjian/Workspace/gh/ghostty/zig-out/lib -lghostty-vt -Wl,-rpath,/Users/lisongjian/Workspace/gh/ghostty/zig-out/lib
#include <stdlib.h>
#include <ghostty/vt.h>
*/
import "C"

import (
	"fmt"
	"sync"
	"unsafe"
)

// VTTerminal is a libghostty-vt terminal emulator that renders raw PTY bytes
// into a complete screen snapshot (visible grid + scrollback) with SGR styles
// preserved. It is the server-side counterpart of the Ghostty client, so a
// replayed snapshot matches exactly what the client would have rendered.
type VTTerminal struct {
	mu       sync.Mutex
	terminal C.GhosttyTerminal
}

func NewVTTerminal(cols, rows int) (*VTTerminal, error) {
	if cols <= 0 || rows <= 0 {
		return nil, fmt.Errorf("invalid terminal size %dx%d", cols, rows)
	}
	opts := C.GhosttyTerminalOptions{
		cols:           C.uint16_t(cols),
		rows:           C.uint16_t(rows),
		max_scrollback: 10000,
	}
	var terminal C.GhosttyTerminal
	if result := C.ghostty_terminal_new(nil, &terminal, opts); result != C.GHOSTTY_SUCCESS {
		return nil, fmt.Errorf("ghostty terminal new failed: %d", result)
	}
	return &VTTerminal{terminal: terminal}, nil
}

// Feed parses raw PTY bytes into the emulated terminal state.
func (v *VTTerminal) Feed(data []byte) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.terminal == nil || len(data) == 0 {
		return
	}
	C.ghostty_terminal_vt_write(
		v.terminal,
		(*C.uint8_t)(unsafe.Pointer(&data[0])),
		C.size_t(len(data)),
	)
}

// Resize reflows the emulated terminal. The caller keeps the real PTY size
// in sync so snapshots are rendered at the client's dimensions.
func (v *VTTerminal) Resize(cols, rows int) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.terminal == nil || cols <= 0 || rows <= 0 {
		return
	}
	C.ghostty_terminal_resize(v.terminal, C.uint16_t(cols), C.uint16_t(rows), 8, 16)
}

// Snapshot renders the current emulated screen (visible grid + scrollback)
// as VT sequences that preserve colors and styles.
func (v *VTTerminal) Snapshot() ([]byte, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.terminal == nil {
		return nil, fmt.Errorf("ghostty terminal is closed")
	}
	var formatter C.GhosttyFormatter
	opts := C.GhosttyFormatterTerminalOptions{
		size: C.size_t(unsafe.Sizeof(C.GhosttyFormatterTerminalOptions{})),
		emit: C.GHOSTTY_FORMATTER_FORMAT_VT,
		trim: true,
	}
	if result := C.ghostty_formatter_terminal_new(nil, &formatter, v.terminal, opts); result != C.GHOSTTY_SUCCESS {
		return nil, fmt.Errorf("ghostty formatter new failed: %d", result)
	}
	defer C.ghostty_formatter_free(formatter)

	var buffer *C.uint8_t
	var length C.size_t
	if result := C.ghostty_formatter_format_alloc(formatter, nil, &buffer, &length); result != C.GHOSTTY_SUCCESS {
		return nil, fmt.Errorf("ghostty formatter format failed: %d", result)
	}
	defer C.ghostty_free(nil, buffer, length)
	return C.GoBytes(unsafe.Pointer(buffer), C.int(length)), nil
}

func (v *VTTerminal) Close() {
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.terminal != nil {
		C.ghostty_terminal_free(v.terminal)
		v.terminal = nil
	}
}
