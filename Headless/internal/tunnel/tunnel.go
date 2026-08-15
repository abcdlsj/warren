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
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

const (
	KindCloudflared = "cloudflared"
	KindTailscale   = "tailscale"
	KindGnar        = "gnar"
)

// Status is the runtime projection of one tunnel. URL is empty until the
// reachability adapter reports a public address.
type Status struct {
	Running bool   `json:"running"`
	URL     string `json:"url,omitempty"`
	Error   string `json:"error,omitempty"`
}

// Manager owns the reachability adapters (cloudflared, Tailscale Serve, gnar)
// that expose the loopback Web server. Each kind maps to at most one adapter;
// start is idempotent and stop tears down the running adapter.
type Manager struct {
	logger          *slog.Logger
	target          string
	cloudflaredPath string
	tailscalePath   string
	gnarPath        string
	pollInterval    time.Duration
	pollAttempts    int

	mu     sync.Mutex
	states map[string]*state
}

type state struct {
	kind     string
	cmd      *exec.Cmd
	url      string
	err      string
	stopped  bool
	scanDone chan struct{}
}

func NewManager(
	logger *slog.Logger,
	target string,
	cloudflaredPath string,
	tailscalePath string,
	gnarPath string,
) *Manager {
	return &Manager{
		logger:          logger,
		target:          target,
		cloudflaredPath: cloudflaredPath,
		tailscalePath:   tailscalePath,
		gnarPath:        gnarPath,
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
		return m.startTailscale()
	case KindGnar:
		return m.startGnar()
	default:
		return Status{}, fmt.Errorf("unknown tunnel kind %q", kind)
	}
}

func (m *Manager) Stop(kind string) error {
	switch kind {
	case KindCloudflared:
		return m.stopCloudflared()
	case KindTailscale:
		return m.stopTailscale()
	case KindGnar:
		return m.stopGnar()
	default:
		return fmt.Errorf("unknown tunnel kind %q", kind)
	}
}

func (m *Manager) Status() map[string]Status {
	m.mu.Lock()
	defer m.mu.Unlock()
	result := make(map[string]Status, len(m.states))
	for _, kind := range []string{KindCloudflared, KindTailscale, KindGnar} {
		if st := m.states[kind]; st != nil {
			result[kind] = Status{Running: !st.stopped, URL: st.url, Error: st.err}
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
	if st.scanDone != nil {
		<-st.scanDone
	}
	m.mu.Lock()
	if m.states[st.kind] == st {
		if st.err == "" {
			delete(m.states, st.kind)
		} else {
			// Keep the failed state so callers can see why the adapter exited.
			st.stopped = true
			st.url = ""
		}
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

func (m *Manager) startTailscale() (Status, error) {
	kind := KindTailscale
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
	command := exec.Command(path, "serve", "--bg", port)
	output, err := command.CombinedOutput()
	if err != nil {
		m.mu.Unlock()
		return Status{}, fmt.Errorf("start tailscale: %w: %s", err, strings.TrimSpace(string(output)))
	}
	st := &state{kind: kind}
	m.states[kind] = st
	m.mu.Unlock()

	for attempt := 0; attempt < m.pollAttempts; attempt++ {
		statusCommand := exec.Command(path, "serve", "status", "--json")
		statusOutput, err := statusCommand.Output()
		if err == nil {
			if candidate := parseTailscaleURL(statusOutput); candidate != "" {
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

func (m *Manager) stopTailscale() error {
	kind := KindTailscale
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
		command := exec.Command(path, "serve", "--https=443", "off")
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

func (m *Manager) startGnar() (Status, error) {
	m.mu.Lock()
	if st := m.states[KindGnar]; st != nil && !st.stopped {
		status := Status{Running: true, URL: st.url, Error: st.err}
		m.mu.Unlock()
		return status, nil
	}
	path := m.gnarPath
	if path == "" {
		path = findExecutable(gnarCandidates())
	}
	if path == "" {
		m.mu.Unlock()
		return Status{}, errors.New("gnar binary not found; install it or set WARREN_GNAR_PATH")
	}
	args := append([]string{m.target, "--no-tui", "--json"}, gnarNameArgs()...)
	command := exec.Command(path, args...)
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
	st := &state{kind: KindGnar, cmd: command, scanDone: make(chan struct{})}
	m.states[KindGnar] = st
	m.mu.Unlock()

	go m.scanGnar(st, io.MultiReader(stdout, stderr))
	go m.wait(st)
	return m.Status()[KindGnar], nil
}

func (m *Manager) scanGnar(st *state, reader io.Reader) {
	defer close(st.scanDone)
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		var event struct {
			Type      string `json:"type"`
			PublicURL string `json:"public_url"`
			Message   string `json:"message"`
		}
		if json.Unmarshal(scanner.Bytes(), &event) != nil {
			continue
		}
		m.mu.Lock()
		if m.states[st.kind] == st {
			switch event.Type {
			case "tunnel_ready":
				if event.PublicURL != "" {
					st.url = event.PublicURL
				}
			case "error":
				st.err = event.Message
			}
		}
		m.mu.Unlock()
		switch event.Type {
		case "tunnel_ready":
			if event.PublicURL != "" {
				m.logger.Info("tunnel ready", "kind", st.kind, "url", event.PublicURL)
			}
		case "error":
			m.logger.Warn("gnar tunnel error", "kind", st.kind, "error", event.Message)
		}
	}
}

func (m *Manager) stopGnar() error {
	m.mu.Lock()
	st := m.states[KindGnar]
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
	m.mu.Lock()
	if m.states[KindGnar] == st {
		delete(m.states, KindGnar)
	}
	m.mu.Unlock()
	m.waitForStop(KindGnar, 2*time.Second)
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

func gnarCandidates() []string {
	candidates := []string{"/opt/homebrew/bin/gnar", "/usr/local/bin/gnar", "/usr/bin/gnar"}
	if home, err := os.UserHomeDir(); err == nil {
		candidates = append([]string{filepath.Join(home, ".local", "bin", "gnar")}, candidates...)
	}
	return candidates
}

func gnarNameArgs() []string {
	hostname, err := os.Hostname()
	if err != nil {
		return nil
	}
	var name strings.Builder
	for _, character := range strings.ToLower(hostname) {
		if (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9') {
			name.WriteRune(character)
		} else if name.Len() > 0 && !strings.HasSuffix(name.String(), "-") {
			name.WriteByte('-')
		}
	}
	normalized := strings.Trim(name.String(), "-")
	if normalized == "" {
		return nil
	}
	if len(normalized) > 32 {
		normalized = strings.TrimRight(normalized[:32], "-")
	}
	return []string{"--name", "warren-" + normalized}
}

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

func parseCloudflaredURL(line string) string {
	return cloudflaredURLPattern.FindString(line)
}

func parseTailscaleURL(data []byte) string {
	var object map[string]any
	if json.Unmarshal(data, &object) != nil {
		return ""
	}
	section, ok := object["Web"].(map[string]any)
	if !ok {
		return ""
	}
	for host := range section {
		return "https://" + strings.SplitN(host, ":", 2)[0] + "/"
	}
	return ""
}
