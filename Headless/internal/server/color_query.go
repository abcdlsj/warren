package server

import "github.com/abcdlsj/ghostline"

const (
	warrenTerminalForeground = "#eae8e6"
	warrenTerminalBackground = "#151110"
)

// WarrenColorQuery supplies Warren's Ember terminal colors to ghostline.
func WarrenColorQuery(kind ghostline.ColorQueryKind) (string, bool) {
	switch kind {
	case ghostline.ColorQueryForeground:
		return warrenTerminalForeground, true
	case ghostline.ColorQueryBackground:
		return warrenTerminalBackground, true
	default:
		return "", false
	}
}
