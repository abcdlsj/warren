package output

import (
	"bytes"
	"testing"
)

func TestOutputEnvelopeRoundTrip(t *testing.T) {
	payload := []byte("\x1b[31mred\r\n")
	encoded, err := EncodeOutput("session-1", 3, 42, payload)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeOutput(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.SessionID != "session-1" || decoded.Epoch != 3 || decoded.Sequence != 42 {
		t.Fatalf("decoded header = %#v", decoded)
	}
	if !bytes.Equal(decoded.Payload, payload) {
		t.Fatalf("payload mismatch: %q", decoded.Payload)
	}
}

func TestOutputPreservesAnsiOscCjkAndEmoji(t *testing.T) {
	payload := []byte("\x1b]0;Warren 终端 🚀\x07\x1b[38;5;196m你好，世界 \xf0\x9f\x8e\x89\x1b[2J\x1b[H")
	encoded, err := EncodeOutput("session-1", 4, 128, payload)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeOutput(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(decoded.Payload, payload) {
		t.Fatalf("multibyte payload changed: %q", decoded.Payload)
	}
	if decoded.Sequence != 128 || decoded.Epoch != 4 {
		t.Fatalf("header = %#v", decoded)
	}
}

func TestInputEnvelopeRoundTrip(t *testing.T) {
	payload := []byte("ls\r")
	encoded, err := EncodeInput(InputMetadata{
		Version: "1.0", SessionID: "s", AttachmentID: "a", Sequence: 7,
	}, payload)
	if err != nil {
		t.Fatal(err)
	}
	metadata, decoded, err := DecodeInput(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if metadata.SessionID != "s" || metadata.AttachmentID != "a" || metadata.Sequence != 7 {
		t.Fatalf("metadata = %#v", metadata)
	}
	if !bytes.Equal(decoded, payload) {
		t.Fatalf("payload mismatch: %q", decoded)
	}
}

func TestWireRejectsCorruptFrames(t *testing.T) {
	if _, err := DecodeOutput([]byte{1, 2, 3}); err == nil {
		t.Fatal("truncated frame accepted")
	}
	payload := []byte("x")
	encoded, _ := EncodeOutput("s", 0, 0, payload)
	encoded = append(encoded, 0)
	if _, err := DecodeOutput(encoded); err == nil {
		t.Fatal("trailing byte accepted")
	}
	encoded, _ = EncodeOutput("s", 0, 0, payload)
	encoded[5] = DirectionClientToHost
	if _, err := DecodeOutput(encoded); err == nil {
		t.Fatal("wrong direction accepted")
	}
}

func TestSplitPayloadBoundsChunks(t *testing.T) {
	payload := make([]byte, MaxPayload+7)
	chunks := SplitPayload(payload)
	if len(chunks) != 2 {
		t.Fatalf("chunks = %d, want 2", len(chunks))
	}
	if len(chunks[0]) != MaxPayload || len(chunks[1]) != 7 {
		t.Fatalf("chunk sizes = %d, %d", len(chunks[0]), len(chunks[1]))
	}
}
