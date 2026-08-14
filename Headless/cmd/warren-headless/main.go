package main

import (
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
	"strings"
	"syscall"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/runtime"
	"github.com/abcdlsj/warren/Headless/internal/server"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

var version = "dev"

func main() {
	configDir := defaultConfigDirectory()
	listen := flag.String("listen", env("WARREN_LISTEN", "127.0.0.1:8789"), "listen address (loopback is recommended)")
	statePath := flag.String("state", env("WARREN_STATE", filepath.Join(configDir, "state.json")), "state file")
	tokenPath := flag.String("token-file", env("WARREN_TOKEN_FILE", filepath.Join(configDir, "token")), "authentication token file")
	hostName := flag.String("name", env("WARREN_HOST_NAME", ""), "host display name")
	tmuxSocket := flag.String("tmux-socket", env("WARREN_TMUX_SOCKET", "warren-headless"), "tmux socket name")
	worktreeRoot := flag.String("worktree-root", env("WARREN_WORKTREE_ROOT", "~/.warren/worktrees"), "worktree root")
	showVersion := flag.Bool("version", false, "print version")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}

	token, err := loadOrCreateToken(*tokenPath)
	if err != nil {
		fatal(err)
	}
	state, err := store.Open(*statePath, *hostName)
	if err != nil {
		fatal(err)
	}
	runtimeAdapter := runtime.Tmux{Socket: *tmuxSocket}
	if err := runtimeAdapter.Check(nil); err != nil {
		fatal(err)
	}
	service := &server.Service{Store: state, Runtime: runtimeAdapter, WorktreeRoot: *worktreeRoot}
	logger := slog.New(slog.NewTextHandler(os.Stderr, nil))
	handler := server.NewHTTPServer(service, token, logger).Handler()
	httpServer := &http.Server{Addr: *listen, Handler: handler, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 90 * time.Second}
	listener, err := net.Listen("tcp", *listen)
	if err != nil {
		fatal(err)
	}
	logger.Info("warren headless ready", "listen", listener.Addr().String(), "host", state.Snapshot().Host.Name, "version", version, "tokenFile", *tokenPath)
	go func() {
		if err := httpServer.Serve(listener); err != nil && err != http.ErrServerClosed {
			fatal(err)
		}
	}()
	// The loopback Web Relay is part of the same daemon lifecycle. It shares
	// the authenticated WebSocket protocol and tmux authority with /v1/ws.
	webRelayServer := &http.Server{Addr: "127.0.0.1:8788", Handler: handler, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 90 * time.Second}
	go func() {
		if err := webRelayServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Error("web relay stopped", "error", err)
		}
	}()
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	_ = httpServer.Close()
	_ = webRelayServer.Close()
}

func loadOrCreateToken(path string) (string, error) {
	if data, err := os.ReadFile(path); err == nil {
		value := strings.TrimSpace(string(data))
		if value != "" {
			return value, nil
		}
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", err
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	value := base64.RawURLEncoding.EncodeToString(raw)
	if err := os.WriteFile(path, []byte(value+"\n"), 0o600); err != nil {
		return "", err
	}
	return value, nil
}
func defaultConfigDirectory() string {
	if value := os.Getenv("XDG_STATE_HOME"); value != "" {
		return filepath.Join(value, "warren")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "state", "warren")
}
func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
func fatal(err error) { fmt.Fprintln(os.Stderr, "warren-headless:", err); os.Exit(1) }
