package runtime

import (
	"bytes"
	"testing"
)

func TestNormalizeCaptureOutput(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{name: "lf only", input: "first\nsecond\n", want: "first\r\nsecond\r\n"},
		{name: "existing crlf", input: "first\r\nsecond\r\n", want: "first\r\nsecond\r\n"},
		{name: "mixed endings", input: "first\nsecond\r\nthird", want: "first\r\nsecond\r\nthird"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := normalizeCaptureOutput([]byte(test.input))
			if !bytes.Equal(got, []byte(test.want)) {
				t.Fatalf("normalizeCaptureOutput(%q) = %q, want %q", test.input, got, test.want)
			}
		})
	}
}
