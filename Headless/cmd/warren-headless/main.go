package main

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/abcdlsj/ghostline"
	"github.com/abcdlsj/warren/Headless/internal/runtime"
	"github.com/abcdlsj/warren/Headless/internal/server"
	"github.com/abcdlsj/warren/Headless/internal/settings"
	"github.com/abcdlsj/warren/Headless/internal/store"
	"github.com/abcdlsj/warren/Headless/internal/tlscert"
	"github.com/abcdlsj/warren/Headless/internal/tunnel"
)

var version = "dev"

const tokenRepairInterval = time.Second

func main() {
	configDir := defaultConfigDirectory()
	listen := flag.String("listen", env("WARREN_LISTEN", "0.0.0.0:8789"), "listen address (all interfaces by default for LAN access; token-protected, do not expose to the public internet)")
	lanHTTPS := flag.String("lan-https", env("WARREN_LAN_HTTPS", "0.0.0.0:8788"), "LAN HTTPS listen address (empty disables; local CA generated on first start)")
	tlsDir := flag.String("tls-dir", env("WARREN_TLS_DIR", filepath.Join(configDir, "tls")), "directory for the local CA and server certificate")
	statePath := flag.String("state", env("WARREN_STATE", filepath.Join(configDir, "state.json")), "state file")
	tokenPath := flag.String("token-file", env("WARREN_TOKEN_FILE", filepath.Join(configDir, "token")), "authentication token file")
	hostName := flag.String("name", env("WARREN_HOST_NAME", ""), "host display name")
	// tmux-socket is only consulted by the tmux runtime.
	tmuxSocket := flag.String("tmux-socket", env("WARREN_TMUX_SOCKET", "warren-headless"), "tmux socket name")
	runtimeMode := flag.String("runtime", env("WARREN_RUNTIME", ""), "default runtime kind: ghostline or tmux (overrides settings.json)")
	ghostlineSocket := flag.String("ghostline-socket", env("WARREN_GHOSTLINE_SOCKET", filepath.Join(configDir, "ghostline.sock")), "ghostline server socket path")
	ghostlineServe := flag.Bool("ghostline-serve", false, "internal: run the ghostline session server (spawned by the daemon)")
	ghostlineAdoptFrom := flag.String("adopt-from", "", "internal: adopt sessions from this old server admin socket")
	settingsFile := flag.String("settings-file", env("WARREN_SETTINGS_FILE", filepath.Join(configDir, "settings.json")), "headless settings file")
	worktreeRoot := flag.String("worktree-root", env("WARREN_WORKTREE_ROOT", "~/.warren/worktrees"), "worktree root")
	outputDir := flag.String("output-dir", env("WARREN_OUTPUT_DIR", filepath.Join(configDir, "output")), "per-session tmux output spool directory")
	cloudflaredPath := flag.String("cloudflared-path", os.Getenv("WARREN_CLOUDFLARED_PATH"), "cloudflared binary path")
	tailscalePath := flag.String("tailscale-path", os.Getenv("WARREN_TAILSCALE_PATH"), "tailscale binary path")
	gnarPath := flag.String("gnar-path", os.Getenv("WARREN_GNAR_PATH"), "gnar binary path")
	showVersion := flag.Bool("version", false, "print version")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}

	// Internal subprocess mode: the daemon spawns this binary with
	// --ghostline-serve so PTY sessions are owned by an independent process
	// that survives daemon upgrades and restarts.
	if *ghostlineServe {
		runGhostlineServe(*ghostlineSocket, *outputDir, *ghostlineAdoptFrom)
		return
	}

	logger := slog.New(slog.NewTextHandler(os.Stderr, nil))
	token, err := loadOrCreateToken(*tokenPath)
	if err != nil {
		fatal(err)
	}
	tokenContext, stopTokenRepair := context.WithCancel(context.Background())
	defer stopTokenRepair()
	go maintainTokenFile(tokenContext, *tokenPath, token, logger)

	state, err := store.Open(*statePath, *hostName)
	if err != nil {
		fatal(err)
	}
	// Runtime selection is a headless-side decision. Both engines are always
	// registered so existing sessions keep working no matter which engine
	// created them; DefaultRuntime only picks the engine for new sessions.
	loadedSettings, err := settings.Load(*settingsFile)
	if err != nil {
		fatal(err)
	}
	defaultKind := loadedSettings.Normalized()
	runtimeSet := false
	flag.Visit(func(entry *flag.Flag) {
		if entry.Name == "runtime" {
			runtimeSet = true
		}
	})
	if runtimeSet {
		switch *runtimeMode {
		case settings.RuntimeGhostline, "pty": // "pty" is the historical alias.
			defaultKind = settings.RuntimeGhostline
		case settings.RuntimeTmux:
			defaultKind = settings.RuntimeTmux
		default:
			fatal(fmt.Errorf("unknown runtime %q (supported: ghostline, tmux)", *runtimeMode))
		}
	}
	ghostlineClient, err := ensureGhostlineClient(*ghostlineSocket, *outputDir, logger)
	if err != nil {
		fatal(err)
	}
	runtimes := map[string]server.Runtime{
		settings.RuntimeGhostline: server.NewGhostlineRuntime(ghostlineClient),
	}
	tmuxAdapter := &runtime.Tmux{Socket: *tmuxSocket, OutputDir: *outputDir}
	if err := tmuxAdapter.Check(nil); err != nil {
		logger.Warn("tmux runtime unavailable", "error", err)
	} else {
		runtimes[settings.RuntimeTmux] = tmuxAdapter
	}
	runtimeAdapter := runtimes[defaultKind]
	if runtimeAdapter == nil {
		fatal(fmt.Errorf("default runtime %q is not available", defaultKind))
	}
	service := &server.Service{
		Store:          state,
		Runtime:        runtimeAdapter,
		Runtimes:       runtimes,
		DefaultRuntime: defaultKind,
		SettingsPath:   *settingsFile,
		WorktreeRoot:   *worktreeRoot,
	}
	serviceContext, stopService := context.WithCancel(context.Background())
	service.Start(serviceContext)
	defer func() {
		stopService()
		service.Shutdown()
	}()
	httpHandler := server.NewHTTPServer(service, token, logger)
	httpHandler.BuildVersion = version
	var lanHTTPServer *http.Server
	if *lanHTTPS != "" {
		certStore := tlscert.NewStore(*tlsDir)
		cert, err := certStore.ServerCertificate()
		if err != nil {
			fatal(err)
		}
		httpHandler.CACertPath = certStore.CAPEMPath()
		lanHTTPServer = &http.Server{
			Addr:              *lanHTTPS,
			Handler:           httpHandler.Handler(),
			TLSConfig:         &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{cert}},
			ReadHeaderTimeout: 10 * time.Second,
			IdleTimeout:       90 * time.Second,
		}
	}
	httpServer := &http.Server{Addr: *listen, Handler: httpHandler.Handler(), ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 90 * time.Second}
	listener, err := net.Listen("tcp", *listen)
	if err != nil {
		fatal(err)
	}
	webBaseURL := "http://127.0.0.1:" + listenerPort(listener)
	tunnelManager := tunnel.NewManager(logger, webBaseURL, *cloudflaredPath, *tailscalePath, *gnarPath)
	httpHandler.Tunnels = tunnelManager
	logger.Info("warren headless ready", "listen", listener.Addr().String(), "host", state.Snapshot().Host.Name, "version", version, "tokenFile", *tokenPath)
	go func() {
		if err := httpServer.Serve(listener); err != nil && err != http.ErrServerClosed {
			fatal(err)
		}
	}()
	if lanHTTPServer != nil {
		lanListener, err := net.Listen("tcp", *lanHTTPS)
		if err != nil {
			fatal(err)
		}
		tlsListener := tls.NewListener(lanListener, lanHTTPServer.TLSConfig)
		logger.Info(
			"warren LAN HTTPS ready",
			"listen", lanListener.Addr().String(),
			"ca", httpHandler.CACertPath,
			"ca_url", "http://127.0.0.1:"+listenerPort(listener)+"/tls/ca.pem",
		)
		go func() {
			if err := lanHTTPServer.Serve(tlsListener); err != nil && err != http.ErrServerClosed {
				fatal(err)
			}
		}()
	}
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	_ = httpServer.Close()
	if lanHTTPServer != nil {
		_ = lanHTTPServer.Close()
	}
	stopService()
	service.Shutdown()
}

func listenerPort(listener net.Listener) string {
	if address, ok := listener.Addr().(*net.TCPAddr); ok {
		return strconv.Itoa(address.Port)
	}
	return "8789"
}

// runGhostlineServe owns PTY sessions in a child process. The daemon spawns
// it detached with --ghostline-serve; it listens on the Unix socket until
// terminated, so daemon upgrades and restarts never end sessions.
func runGhostlineServe(socketPath, outputDir, adoptFrom string) {
	pidPath := socketPath + ".pid"
	if err := os.WriteFile(pidPath, []byte(strconv.Itoa(os.Getpid())+"\n"), 0o600); err != nil {
		fmt.Fprintln(os.Stderr, "ghostline serve: write pid:", err)
	}
	defer os.Remove(pidPath)
	server, err := ghostline.NewServer(ghostline.Options{OutputDir: outputDir})
	if err != nil {
		fmt.Fprintln(os.Stderr, "ghostline serve:", err)
		os.Exit(1)
	}
	if adoptFrom != "" {
		adoptContext, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		adopted, adoptErr := server.Adopt(adoptContext, adoptFrom)
		cancel()
		if adoptErr != nil {
			fmt.Fprintf(os.Stderr, "ghostline serve: adopt from %s: %v\n", adoptFrom, adoptErr)
			os.Exit(1)
		}
		if adopted > 0 {
			fmt.Fprintf(os.Stderr, "ghostline serve: adopted %d session(s)\n", adopted)
		}
	}
	if err := server.Serve(context.Background(), socketPath); err != nil {
		fmt.Fprintln(os.Stderr, "ghostline serve:", err)
		os.Exit(1)
	}
}

// ensureGhostlineClient connects to the session server, spawning it detached
// when the socket is not yet accepting. Sessions survive daemon restarts
// because the server process owns them; the returned client is intentionally
// never closed by the daemon so the server keeps running.
func ensureGhostlineClient(socketPath, outputDir string, logger *slog.Logger) (*ghostline.Client, error) {
	client, err := connectGhostlineClient(socketPath, outputDir)
	if err != nil {
		return nil, err
	}
	version, err := client.Version(context.Background())
	if err == nil && version == ghostline.ProtocolVersion {
		return client, nil
	}
	// The server process predates this daemon's protocol (or reports an older
	// version). Prefer a rolling upgrade (RFC 0002): a fresh server adopts
	// every session and the old process exits, so children keep running. If
	// that fails, fall back to a plain restart, which ends sessions.
	logger.Warn("ghostline server protocol mismatch; upgrading server",
		"reported", version, "want", ghostline.ProtocolVersion, "error", err)
	if upgraded, upgradeErr := rollingUpgradeGhostlineClient(socketPath, outputDir, logger); upgradeErr == nil {
		return upgraded, nil
	} else {
		logger.Warn("ghostline rolling upgrade failed; restarting server", "error", upgradeErr)
	}
	if stopErr := stopGhostlineServer(socketPath); stopErr != nil {
		return nil, stopErr
	}
	return connectGhostlineClient(socketPath, outputDir)
}

// rollingUpgradeGhostlineClient starts a fresh server on a temporary socket,
// lets it adopt every session from the old server, and then points the stable
// socket path at the new server with a symlink. The old server exits itself
// after adoption, so its children survive the upgrade.
func rollingUpgradeGhostlineClient(socketPath, outputDir string, logger *slog.Logger) (*ghostline.Client, error) {
	adminSocket := socketPath + ".admin"
	if !ghostline.Ping(adminSocket) {
		return nil, fmt.Errorf("old server has no admin socket at %s", adminSocket)
	}
	nextSocket := filepath.Join(
		filepath.Dir(socketPath),
		fmt.Sprintf("ghostline-%d.sock", time.Now().UnixNano()),
	)
	logFile, err := os.OpenFile(
		filepath.Join(filepath.Dir(socketPath), "ghostline.log"),
		os.O_CREATE|os.O_APPEND|os.O_WRONLY,
		0o600,
	)
	if err != nil {
		return nil, fmt.Errorf("open ghostline log: %w", err)
	}
	defer logFile.Close()
	executable, err := os.Executable()
	if err != nil {
		return nil, fmt.Errorf("resolve daemon executable: %w", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	client, err := ghostline.Connect(ctx, ghostline.ConnectOptions{
		Socket: nextSocket,
		Spawn: []string{
			executable,
			"--ghostline-serve",
			"--ghostline-socket", nextSocket,
			"--output-dir", outputDir,
			"--adopt-from", adminSocket,
		},
		Log:          logFile,
		ReadyTimeout: 15 * time.Second,
	})
	if err != nil {
		return nil, fmt.Errorf("start upgraded server: %w", err)
	}
	// The new server only binds its socket after adoption finishes, so a
	// successful Connect means every session moved over. Wait for the old
	// server to exit before replacing the stable path, otherwise its cleanup
	// would unlink the new symlink.
	if err := waitForGhostlineExit(adminSocket, 5*time.Second); err != nil {
		// Adoption already committed; the old server has no sessions left, so
		// stopping it via its pid file is safe even if the exit handshake was
		// lost.
		logger.Warn("old ghostline server did not exit after adoption; stopping it", "error", err)
		if stopErr := stopGhostlineServer(socketPath); stopErr != nil {
			_ = client.Close()
			return nil, fmt.Errorf("old server did not exit after adoption: %v (stop: %w)", err, stopErr)
		}
	}
	if err := replaceWithSymlink(socketPath, nextSocket); err != nil {
		_ = client.Close()
		return nil, fmt.Errorf("point stable socket at upgraded server: %w", err)
	}
	if pid := client.PID(); pid > 0 {
		pidPath := socketPath + ".pid"
		if err := os.WriteFile(pidPath, []byte(strconv.Itoa(pid)+"\n"), 0o600); err != nil {
			logger.Warn("unable to record upgraded server pid", "path", pidPath, "error", err)
		}
	}
	logger.Info("ghostline server upgraded in place", "socket", socketPath, "server", nextSocket)
	return client, nil
}

// waitForGhostlineExit waits for the old server's admin socket to disappear.
func waitForGhostlineExit(adminSocket string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for ghostline.Ping(adminSocket) && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	if ghostline.Ping(adminSocket) {
		return fmt.Errorf("admin socket %s still accepting", adminSocket)
	}
	return nil
}

// replaceWithSymlink atomically points stable at target by creating a
// temporary symlink and renaming it over the old socket path.
func replaceWithSymlink(stable, target string) error {
	if err := os.Remove(stable); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("remove old socket: %w", err)
	}
	temp := stable + ".tmp"
	_ = os.Remove(temp)
	if err := os.Symlink(filepath.Base(target), temp); err != nil {
		return fmt.Errorf("create socket symlink: %w", err)
	}
	if err := os.Rename(temp, stable); err != nil {
		_ = os.Remove(temp)
		return fmt.Errorf("install socket symlink: %w", err)
	}
	return nil
}

func connectGhostlineClient(socketPath, outputDir string) (*ghostline.Client, error) {
	logFile, err := os.OpenFile(
		filepath.Join(filepath.Dir(socketPath), "ghostline.log"),
		os.O_CREATE|os.O_APPEND|os.O_WRONLY,
		0o600,
	)
	if err != nil {
		return nil, fmt.Errorf("open ghostline log: %w", err)
	}
	defer logFile.Close()
	executable, err := os.Executable()
	if err != nil {
		return nil, fmt.Errorf("resolve daemon executable: %w", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	client, err := ghostline.Connect(ctx, ghostline.ConnectOptions{
		Socket: socketPath,
		Spawn: []string{
			executable,
			"--ghostline-serve",
			"--ghostline-socket", socketPath,
			"--output-dir", outputDir,
		},
		Log:          logFile,
		ReadyTimeout: 5 * time.Second,
	})
	if err != nil {
		return nil, fmt.Errorf("connect ghostline server: %w", err)
	}
	return client, nil
}

// stopGhostlineServer terminates the running server via its pid file and
// waits for the socket to disappear.
func stopGhostlineServer(socketPath string) error {
	pidPath := socketPath + ".pid"
	data, err := os.ReadFile(pidPath)
	if err != nil {
		// Servers started before per-socket pid files wrote the shared
		// ghostline.pid; keep that path as a compatibility fallback.
		data, err = os.ReadFile(filepath.Join(filepath.Dir(socketPath), "ghostline.pid"))
	}
	if err == nil {
		if pid, parseErr := strconv.Atoi(strings.TrimSpace(string(data))); parseErr == nil && pid > 0 {
			_ = syscall.Kill(pid, syscall.SIGTERM)
		}
	}
	deadline := time.Now().Add(5 * time.Second)
	for ghostline.Ping(socketPath) && time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
	}
	if ghostline.Ping(socketPath) {
		return fmt.Errorf("ghostline server did not stop after restart request")
	}
	return nil
}

func loadOrCreateToken(path string) (string, error) {
	if data, err := os.ReadFile(path); err == nil {
		value := strings.TrimSpace(string(data))
		if value != "" {
			return value, nil
		}
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	value := base64.RawURLEncoding.EncodeToString(raw)
	if err := writeTokenFile(path, value); err != nil {
		return "", err
	}
	return value, nil
}

// maintainTokenFile keeps the token that an already-running daemon owns
// available to new desktop and CLI clients. The daemon keeps the token in
// memory, so restoring a deleted or replaced file is safe and prevents a
// second daemon from publishing a different token for the same port.
func maintainTokenFile(ctx context.Context, path, token string, logger *slog.Logger) {
	repair := func() {
		if err := ensureTokenFile(path, token); err != nil {
			logger.Warn("unable to repair token file", "path", path, "error", err)
		}
	}
	repair()
	ticker := time.NewTicker(tokenRepairInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			repair()
		}
	}
}

func ensureTokenFile(path, token string) error {
	data, err := os.ReadFile(path)
	if err == nil && strings.TrimSpace(string(data)) == token {
		return nil
	}
	return writeTokenFile(path, token)
}

func writeTokenFile(path, token string) error {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return fmt.Errorf("create token directory: %w", err)
	}
	temporary, err := os.CreateTemp(directory, ".warren-token-*")
	if err != nil {
		return fmt.Errorf("create temporary token file: %w", err)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("set token permissions: %w", err)
	}
	if _, err := temporary.WriteString(token + "\n"); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("write token: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close temporary token file: %w", err)
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return fmt.Errorf("commit token: %w", err)
	}
	return nil
}

func defaultConfigDirectory() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".warren")
}
func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
func fatal(err error) { fmt.Fprintln(os.Stderr, "warren-headless:", err); os.Exit(1) }
