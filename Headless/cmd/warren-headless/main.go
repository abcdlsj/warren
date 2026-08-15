package main

import (
	"context"
	"crypto/rand"
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

	"github.com/abcdlsj/warren/Headless/internal/runtime"
	"github.com/abcdlsj/warren/Headless/internal/server"
	"github.com/abcdlsj/warren/Headless/internal/store"
	"github.com/abcdlsj/warren/Headless/internal/tunnel"
)

var version = "dev"

const tokenRepairInterval = time.Second

func main() {
	configDir := defaultConfigDirectory()
	listen := flag.String("listen", env("WARREN_LISTEN", "127.0.0.1:8789"), "listen address (loopback is recommended)")
	statePath := flag.String("state", env("WARREN_STATE", filepath.Join(configDir, "state.json")), "state file")
	tokenPath := flag.String("token-file", env("WARREN_TOKEN_FILE", filepath.Join(configDir, "token")), "authentication token file")
	hostName := flag.String("name", env("WARREN_HOST_NAME", ""), "host display name")
	tmuxSocket := flag.String("tmux-socket", env("WARREN_TMUX_SOCKET", "warren-headless"), "tmux socket name")
	worktreeRoot := flag.String("worktree-root", env("WARREN_WORKTREE_ROOT", "~/.warren/worktrees"), "worktree root")
	outputDir := flag.String("output-dir", env("WARREN_OUTPUT_DIR", filepath.Join(configDir, "output")), "per-session tmux output spool directory")
	cloudflaredPath := flag.String("cloudflared-path", os.Getenv("WARREN_CLOUDFLARED_PATH"), "cloudflared binary path")
	tailscalePath := flag.String("tailscale-path", os.Getenv("WARREN_TAILSCALE_PATH"), "tailscale binary path")
	showVersion := flag.Bool("version", false, "print version")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
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
	runtimeAdapter := &runtime.Tmux{Socket: *tmuxSocket, OutputDir: *outputDir}
	if err := runtimeAdapter.Check(nil); err != nil {
		fatal(err)
	}
	service := &server.Service{Store: state, Runtime: runtimeAdapter, WorktreeRoot: *worktreeRoot}
	serviceContext, stopService := context.WithCancel(context.Background())
	service.Start(serviceContext)
	defer func() {
		stopService()
		service.Shutdown()
	}()
	httpHandler := server.NewHTTPServer(service, token, logger)
	httpServer := &http.Server{Addr: *listen, Handler: httpHandler.Handler(), ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 90 * time.Second}
	listener, err := net.Listen("tcp", *listen)
	if err != nil {
		fatal(err)
	}
	webBaseURL := "http://127.0.0.1:" + listenerPort(listener)
	tunnelManager := tunnel.NewManager(logger, webBaseURL, *cloudflaredPath, *tailscalePath)
	httpHandler.BuildVersion = version
	httpHandler.Tunnels = tunnelManager
	logger.Info("warren headless ready", "listen", listener.Addr().String(), "host", state.Snapshot().Host.Name, "version", version, "tokenFile", *tokenPath)
	go func() {
		if err := httpServer.Serve(listener); err != nil && err != http.ErrServerClosed {
			fatal(err)
		}
	}()
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	_ = httpServer.Close()
	stopService()
	service.Shutdown()
}

func listenerPort(listener net.Listener) string {
	if address, ok := listener.Addr().(*net.TCPAddr); ok {
		return strconv.Itoa(address.Port)
	}
	return "8789"
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
