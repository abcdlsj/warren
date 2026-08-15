package server

import (
	"bytes"
	"fmt"
	"sync"
)

// queryResponder answers terminal capability queries while a session has no
// attached terminal client. TUIs such as Codex send DA/DSR/OSC/kitty
// keyboard queries at startup; tmux answers them through its own emulator,
// but a raw PTY has nobody to answer until a client attaches, so the
// application would downgrade itself (for example disabling colors). Replies
// are written back into the PTY as input, never into the output spool.
type queryResponder struct {
	mu      sync.Mutex
	pending []byte
	rows    int
	cols    int
}

func newQueryResponder() *queryResponder {
	return &queryResponder{rows: 36, cols: 120}
}

func (r *queryResponder) Resize(columns, rows int) {
	if columns <= 0 || rows <= 0 {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.cols = columns
	r.rows = rows
}

// Feed scans output bytes for complete terminal queries and returns the
// replies to write back into the PTY. Queries split across chunks are
// buffered until complete or until they prove not to be queries.
func (r *queryResponder) Feed(data []byte) [][]byte {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.pending = append(r.pending, data...)
	var replies [][]byte
	for {
		index := bytes.IndexByte(r.pending, 0x1b)
		if index < 0 {
			r.pending = r.pending[:0]
			return replies
		}
		if index > 0 {
			r.pending = r.pending[index:]
		}
		if len(r.pending) < 2 {
			return replies
		}
		switch r.pending[1] {
		case '[':
			final, complete := csiFinal(r.pending[2:])
			if !complete {
				if final >= 0 {
					// A byte that cannot belong to a CSI sequence; drop the
					// leading escape and keep scanning the rest.
					r.pending = r.pending[1:]
					continue
				}
				if len(r.pending) > 256 {
					r.pending = r.pending[:0]
				}
				return replies
			}
			sequence := r.pending[2 : 2+final+1]
			r.pending = r.pending[2+final+1:]
			if reply := r.csiReply(sequence); len(reply) > 0 {
				replies = append(replies, reply)
			}
		case ']':
			end, complete := oscEnd(r.pending[2:])
			if !complete {
				if end >= 0 {
					r.pending = r.pending[1:]
					continue
				}
				if len(r.pending) > 4096 {
					r.pending = r.pending[:0]
				}
				return replies
			}
			sequence := r.pending[2 : 2+end]
			r.pending = r.pending[2+end:]
			if reply := r.oscReply(sequence); len(reply) > 0 {
				replies = append(replies, reply)
			}
		default:
			r.pending = r.pending[1:]
		}
	}
}

// csiFinal finds the final byte of a CSI sequence in body (the bytes after
// ESC [). A negative index with complete=false means the buffer is still
// incomplete; an index with complete=false means the byte at that index
// cannot be part of a CSI sequence.
func csiFinal(body []byte) (index int, complete bool) {
	for i := 0; i < len(body); i++ {
		if body[i] >= 0x40 && body[i] <= 0x7e {
			return i, true
		}
		if body[i] < 0x20 || body[i] == 0x7f {
			return i, false
		}
	}
	return -1, false
}

// oscEnd finds the end of an OSC sequence in body (the bytes after ESC ]).
// Returns the index of the terminating BEL or ST start; the terminator
// itself is not part of the returned range.
func oscEnd(body []byte) (index int, complete bool) {
	for i := 0; i < len(body); i++ {
		if body[i] == 0x07 {
			return i, true
		}
		if body[i] == 0x1b {
			if i+1 < len(body) && body[i+1] == '\\' {
				return i, true
			}
			return i, false
		}
		if body[i] < 0x20 {
			return i, false
		}
	}
	return -1, false
}

func (r *queryResponder) csiReply(sequence []byte) []byte {
	final := sequence[len(sequence)-1]
	params := sequence[:len(sequence)-1]
	switch final {
	case 'c':
		// Primary DA. xterm-256color identifiers; the exact feature list is
		// less important than answering, otherwise TUIs assume a dumb
		// terminal and suppress colors.
		if len(params) > 0 && params[0] == '>' {
			return []byte("\x1b[>0;0;0c")
		}
		return []byte("\x1b[?62;c")
	case 'n':
		switch string(params) {
		case "5":
			return []byte("\x1b[0n")
		case "6":
			return []byte("\x1b[1;1R")
		}
	case 'u':
		// kitty keyboard protocol query: CSI ? u. Answering with the query
		// itself means "supported".
		if string(params) == "?" {
			return []byte("\x1b[?u")
		}
	case 'p':
		// DECRQM: CSI ? Ps $ p. Report the mode as set; this covers the
		// queries TUIs actually send (2004 bracketed paste, 2026
		// synchronized output, focus/mouse modes).
		if len(params) >= 2 && params[0] == '?' && params[len(params)-1] == '$' {
			mode := params[1 : len(params)-1]
			reply := make([]byte, 0, len(mode)+6)
			reply = append(reply, "\x1b[?"...)
			reply = append(reply, mode...)
			reply = append(reply, ";1$y"...)
			return reply
		}
	case 't':
		switch string(params) {
		case "14":
			return []byte(fmt.Sprintf("\x1b[4;%d;%dt", r.rows, r.cols))
		case "16":
			return []byte(fmt.Sprintf("\x1b[4;%d;%dt", r.rows*24, r.cols*8))
		case "18":
			return []byte(fmt.Sprintf("\x1b[8;%d;%dt", r.rows, r.cols))
		}
	}
	return nil
}

func (r *queryResponder) oscReply(sequence []byte) []byte {
	switch string(sequence) {
	case "10;?":
		return []byte("\x1b]10;rgb:ffff/ffff/ffff\x1b\\")
	case "11;?":
		return []byte("\x1b]11;rgb:0000/0000/0000\x1b\\")
	}
	return nil
}
