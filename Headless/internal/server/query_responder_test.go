package server

import (
	"testing"
)

func replyStrings(replies [][]byte) []string {
	result := make([]string, 0, len(replies))
	for _, reply := range replies {
		result = append(result, string(reply))
	}
	return result
}

func assertReplies(t *testing.T, responder *queryResponder, data []byte, want ...string) {
	t.Helper()
	got := replyStrings(responder.Feed(data))
	if len(got) != len(want) {
		t.Fatalf("Feed(%q) replies = %q, want %q", data, got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("Feed(%q) reply[%d] = %q, want %q", data, i, got[i], want[i])
		}
	}
}

func TestQueryResponderAnswersCapabilityQueries(t *testing.T) {
	responder := newQueryResponder()
	assertReplies(t, responder, []byte("\x1b[c"), "\x1b[?62;c")
	assertReplies(t, responder, []byte("\x1b[0c"), "\x1b[?62;c")
	assertReplies(t, responder, []byte("\x1b[>c"), "\x1b[>0;0;0c")
	assertReplies(t, responder, []byte("\x1b[6n"), "\x1b[1;1R")
	assertReplies(t, responder, []byte("\x1b[5n"), "\x1b[0n")
	assertReplies(t, responder, []byte("\x1b[?u"), "\x1b[?u")
	assertReplies(t, responder, []byte("\x1b[?2026$p"), "\x1b[?2026;1$y")
	assertReplies(t, responder, []byte("\x1b[?2004$p"), "\x1b[?2004;1$y")
	assertReplies(t, responder, []byte("\x1b]10;?\x1b\\"), "\x1b]10;rgb:ffff/ffff/ffff\x1b\\")
	assertReplies(t, responder, []byte("\x1b]11;?\x07"), "\x1b]11;rgb:0000/0000/0000\x1b\\")
}

func TestQueryResponderReportsWindowSize(t *testing.T) {
	responder := newQueryResponder()
	responder.Resize(100, 40)
	assertReplies(t, responder, []byte("\x1b[14t"), "\x1b[4;40;100t")
	assertReplies(t, responder, []byte("\x1b[18t"), "\x1b[8;40;100t")
}

func TestQueryResponderHandlesSplitQueries(t *testing.T) {
	responder := newQueryResponder()
	if replies := responder.Feed([]byte("hello ")); len(replies) != 0 {
		t.Fatalf("plain text must not reply, got %q", replyStrings(replies))
	}
	if replies := responder.Feed([]byte("\x1b")); len(replies) != 0 {
		t.Fatalf("partial escape must not reply, got %q", replyStrings(replies))
	}
	assertReplies(t, responder, []byte("[6n"), "\x1b[1;1R")
	assertReplies(t, responder, []byte("\x1b]1"))
	assertReplies(t, responder, []byte("0;?\x1b\\"), "\x1b]10;rgb:ffff/ffff/ffff\x1b\\")
}

func TestQueryResponderIgnoresNonQueries(t *testing.T) {
	responder := newQueryResponder()
	assertReplies(t, responder, []byte("\x1b[31m"))
	assertReplies(t, responder, []byte("\x1b[2J\x1b[H"))
	assertReplies(t, responder, []byte("\x1b]0;title\x1b\\"))
	assertReplies(t, responder, []byte("\x1b[?25l"))
	assertReplies(t, responder, []byte("\x1b]52;c;AAAA\x1b\\"))
	if len(responder.pending) != 0 {
		t.Fatalf("pending buffer not drained: %q", responder.pending)
	}
}

func TestQueryResponderBuffersAcrossPlainText(t *testing.T) {
	responder := newQueryResponder()
	assertReplies(t, responder, []byte("a"))
	assertReplies(t, responder, []byte("\x1b"))
	assertReplies(t, responder, []byte("[6n"), "\x1b[1;1R")
	if len(responder.pending) != 0 {
		t.Fatalf("plain text should have been dropped, pending = %q", responder.pending)
	}
}
