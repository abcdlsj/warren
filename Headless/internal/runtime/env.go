package runtime

import (
	"os"
	"strings"
)

// DefaultTerm is the terminal type Warren uses when the daemon is launched
// without a usable TERM (agent/CI shells often inherit TERM=dumb).
const DefaultTerm = "xterm-256color"

// SanitizeEnvironment removes launcher-only environment semantics that would
// make Warren terminal sessions behave like non-interactive pipelines:
// PAGER/GIT_PAGER/GH_PAGER set to cat or empty suppress pagers, and a dumb
// TERM makes TUIs and pagers degrade. It mutates the current process
// environment so ghostline/tmux children inherit a real terminal environment;
// user-specified pager values such as less are preserved.
func SanitizeEnvironment() {
	for _, key := range []string{"GIT_PAGER", "PAGER", "GH_PAGER"} {
		if pagerDisabled(os.Getenv(key)) {
			_ = os.Unsetenv(key)
		}
	}
	if term := os.Getenv("TERM"); strings.TrimSpace(term) == "" || term == "dumb" {
		_ = os.Setenv("TERM", DefaultTerm)
	}
}

func pagerDisabled(value string) bool {
	value = strings.TrimSpace(value)
	return value == "" || strings.EqualFold(value, "cat")
}
