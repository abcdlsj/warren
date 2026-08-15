package tunnel

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/url"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"
)

const (
	KindCloudflared = "cloudflared"
	KindTailscale   = "tailscale"
	KindFunnel      = "funnel"
)

// Status is the runtime projection of one tunnel. URL is empty until the
// reachability adapter reports a public address.
type Status struct {
	Running bool   `json:"running"`
	URL     string `json:"url,omitempty"`
	Error   string `json:"error,omitempty"`
}

// Manager owns the reachability adapters (cloudflared, Tailscale Serve/Funnel)
// that expose the loopback Web server. Each kind maps to at most one adapter;
// start is idempotent and stop tears down the running adapter.
type Manager struct {
	logger          *slog.Logger
	target          string
	cloudflaredPath string
	tailscalePath   string
	pollInterval    time.Duration
	pollAttempts    int

	mu     sync.Mutex
	states map[string]*state
}

type state struct {
	kind    string
	cmd     *exec.Cmd
	url     string
	stopped bool
}

func NewManager(
	logger *slog.Logger,
	target string,
	cloudflaredPath string,
	tailscalePath string,
) *Manager {
	return &Manager{
		logger:          logger,
		target:          target,
		cloudflaredPath: cloudflaredPath,
		tailscalePath:   tailscalePath,
		pollInterval:    250 * time.Millisecond,
		pollAttempts:    40,
		states:          make(map[string]*state),
	}
}

func (m *Manager) Start(kind string) (Status, error) {
	switch kind {
	case KindCloudflared:
		return m.startCloudflared()
	case KindTailscale:
		return m.startTailscale(false)
	case KindFunnel:
		return m.startTailscale(true)
	default:
		return Status{}, fmt.Errorf("unknown tunnel kind %q", kind)
	}
}

func (m *Manager) Stop(kind string) error {
	switch kind {
	case KindCloudflared:
		return m.stopCloudflared()
	case KindTailscale:
		return m.stopTailscale(false)
	case KindFunnel:
		return m.stopTailscale(true)
	default:
		return fmt.Errorf("unknown tunnel kind %q", kind)
	}
}

func (m *Manager) Status() map[string]Status {
	m.mu.Lock()
	defer m.mu.Unlock()
	result := make(map[string]Status, len(m.states))
	for _, kind := range []string{KindCloudflared, KindTailscale, KindFunnel} {
		if st := m.states[kind]; st != nil {
			result[kind] = Status{Running: !st.stopped, URL: st.url}
		}
	}
	return result
}

func (m *Manager) startCloudflared() (Status, error) {
	m.mu.Lock()
	if st := m.states[KindCloudflared]; st != nil && !st.stopped {
		status := Status{Running: true, URL: st.url}
		m.mu.Unlock()
		return status, nil
	}
	path := m.cloudflaredPath
	if path == "" {
		path = findExecutable(cloudflaredCandidates)
	}
	if path == "" {
		m.mu.Unlock()
		return Status{}, errors.New("cloudflared binary not found; install it or set WARREN_CLOUDFLARED_PATH")
	}
	command := exec.Command(path, "tunnel", "--url", m.target, "--no-autoupdate")
	stdout, err := command.StdoutPipe()
	if err != nil {
		m.mu.Unlock()
		return Status{}, err
	}
	stderr, err := command.StderrPipe()
	if err != nil {
		m.mu.Unlock()
		return Status{}, err
	}
	if err := command.Start(); err != nil {
		m.mu.Unlock()
		return Status{}, err
	}
	st := &state{kind: KindCloudflared, cmd: command}
	m.states[KindCloudflared] = st
	m.mu.Unlock()

	go m.scanCloudflared(st, io.MultiReader(stdout, stderr))
	go m.wait(st)
	return m.Status()[KindCloudflared], nil
}

func (m *Manager) scanCloudflared(st *state, reader io.Reader) {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		if found := parseCloudflaredURL(scanner.Text()); found != "" {
			m.mu.Lock()
			if st == m.states[st.kind] {
				st.url = found
			}
			m.mu.Unlock()
			m.logger.Info("tunnel ready", "kind", st.kind, "url", found)
			return
		}
	}
}

func (m *Manager) stopCloudflared() error {
	m.mu.Lock()
	st := m.states[KindCloudflared]
	if st != nil {
		st.stopped = true
	}
	m.mu.Unlock()
	if st == nil {
		return nil
	}
	if st.cmd != nil && st.cmd.Process != nil {
		_ = st.cmd.Process.Kill()
	}
	m.waitForStop(KindCloudflared, 2*time.Second)
	return nil
}

func (m *Manager) wait(st *state) {
	_ = st.cmd.Wait()
	m.mu.Lock()
	if m.states[st.kind] == st {
		delete(m.states, st.kind)
	}
	m.mu.Unlock()
}

func (m *Manager) waitForStop(kind string, timeout time.Duration) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		m.mu.Lock()
		_, exists := m.states[kind]
		m.mu.Unlock()
		if !exists {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func (m *Manager) startTailscale(funnel bool) (Status, error) {
	kind := KindTailscale
	if funnel {
		kind = KindFunnel
	}
	m.mu.Lock()
	if st := m.states[kind]; st != nil && !st.stopped {
		status := Status{Running: true, URL: st.url}
		m.mu.Unlock()
		return status, nil
	}
	path := m.tailscalePath
	if path == "" {
		path = findExecutable(tailscaleCandidates)
	}
	if path == "" {
		m.mu.Unlock()
		return Status{}, errors.New("tailscale binary not found; install it or set WARREN_TAILSCALE_PATH")
	}
	port, err := targetPort(m.target)
	if err != nil {
		m.mu.Unlock()
		return Status{}, err
	}
	command := exec.Command(path, serveArguments(funnel, port)...)
	output, err := command.CombinedOutput()
	if err != nil {
		m.mu.Unlock()
		return Status{}, fmt.Errorf("start tailscale: %w: %s", err, strings.TrimSpace(string(output)))
	}
	st := &state{kind: kind}
	m.states[kind] = st
	m.mu.Unlock()

	for attempt := 0; attempt < m.pollAttempts; attempt++ {
		statusCommand := exec.Command(path, statusArguments(funnel)...)
		statusOutput, err := statusCommand.Output()
		if err == nil {
			var candidate string
			if funnel {
				candidate = parseTailscaleURL(statusOutput, "Funnel")
			} else {
				candidate = parseTailscaleURL(statusOutput, "Web")
			}
			if candidate != "" {
				m.mu.Lock()
				st.url = candidate
				m.mu.Unlock()
				m.logger.Info("tunnel ready", "kind", kind, "url", candidate)
				return m.Status()[kind], nil
			}
		}
		time.Sleep(m.pollInterval)
	}
	return m.Status()[kind], nil
}

func (m *Manager) stopTailscale(funnel bool) error {
	kind := KindTailscale
	if funnel {
		kind = KindFunnel
	}
	m.mu.Lock()
	st := m.states[kind]
	if st != nil {
		st.stopped = true
	}
	m.mu.Unlock()
	if st == nil {
		return nil
	}
	path := m.tailscalePath
	if path == "" {
		path = findExecutable(tailscaleCandidates)
	}
	if path != "" {
		command := exec.Command(path, stopArguments(funnel)...)
		if output, err := command.CombinedOutput(); err != nil {
			m.logger.Warn("stop tailscale", "kind", kind, "error", err, "output", strings.TrimSpace(string(output)))
		}
	}
	m.mu.Lock()
	if m.states[kind] == st {
		delete(m.states, kind)
	}
	m.mu.Unlock()
	return nil
}

var (
	cloudflaredCandidates = []string{
		"/opt/homebrew/bin/cloudflared",
		"/usr/local/bin/cloudflared",
		"/usr/bin/cloudflared",
	}
	tailscaleCandidates = []string{
		"/usr/local/bin/tailscale",
		"/Applications/Tailscale.app/Contents/MacOS/Tailscale",
	}
	cloudflaredURLPattern = regexp.MustCompile(`https://[a-zA-Z0-9-]+\.trycloudflare\.com`)
)

func findExecutable(candidates []string) string {
	for _, candidate := range candidates {
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return candidate
		}
	}
	return ""
}

func targetPort(target string) (string, error) {
	parsed, err := url.Parse(target)
	if err != nil || parsed.Port() == "" {
		return "", fmt.Errorf("tunnel target %q must include a port", target)
	}
	return parsed.Port(), nil
}

func serveArguments(funnel bool, port string) []string {
	if funnel {
		return []string{"funnel", "--bg", "--yes", port}
	}
	return []string{"serve", "--bg", port}
}

func statusArguments(funnel bool) []string {
	if funnel {
		return []string{"funnel", "status", "--json"}
	}
	return []string{"serve", "status", "--json"}
}

func stopArguments(funnel bool) []string {
	if funnel {
		return []string{"funnel", "reset"}
	}
	return []string{"serve", "--https=443", "off"}
}

func parseCloudflaredURL(line string) string {
	return cloudflaredURLPattern.FindString(line)
}

func parseTailscaleURL(data []byte, key string) string {
	var object map[string]any
	if json.Unmarshal(data, &object) != nil {
		return ""
	}
	section, ok := object[key].(map[string]any)
	if !ok {
		return ""
	}
	for host := range section {
		return "https://" + strings.SplitN(host, ":", 2)[0] + "/"
	}
	return ""
}
