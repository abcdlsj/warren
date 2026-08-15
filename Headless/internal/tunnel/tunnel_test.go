package tunnel

import (
	"log/slog"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestParseCloudflaredURL(t *testing.T) {
	line := "2026-08-15T10:00:00Z INF +--------------------------------------------------------------------------------------------+"
	line += "\n https://warren-abc.trycloudflare.com"
	if got := parseCloudflaredURL(line); got != "https://warren-abc.trycloudflare.com" {
		t.Fatalf("parseCloudflaredURL = %q", got)
	}
	if got := parseCloudflaredURL("no url here"); got != "" {
		t.Fatalf("unexpected match %q", got)
	}
}

func TestParseTailscaleURL(t *testing.T) {
	serveJSON := []byte(`{"TCP":{"443":{"HTTPS":true}},"Web":{"host.tail3d6e0.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8789"}}}}}`)
	if got := parseTailscaleURL(serveJSON, "Web"); got != "https://host.tail3d6e0.ts.net/" {
		t.Fatalf("parseTailscaleURL = %q", got)
	}
	funnelJSON := []byte(`{"TCP":{"443":{"HTTPS":true}},"Funnel":{"host.tail3d6e0.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8789"}}}}}`)
	if got := parseTailscaleURL(funnelJSON, "Funnel"); got != "https://host.tail3d6e0.ts.net/" {
		t.Fatalf("parseFunnelURL = %q", got)
	}
}

func TestManagerStartAndStopCloudflaredWithFakeBinary(t *testing.T) {
	binary := writeScript(t, `#!/bin/sh
printf 'https://fake-%s.trycloudflare.com\n' "$(date +%s)"
sleep 30
`)
	manager := NewManager(slog.New(slog.NewTextHandler(os.Stderr, nil)), "http://127.0.0.1:8789", binary, "")
	manager.pollInterval = 10 * time.Millisecond
	manager.pollAttempts = 10

	status, err := manager.Start(KindCloudflared)
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	if !status.Running {
		t.Fatal("cloudflared is not running after start")
	}

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		current := manager.Status()[KindCloudflared]
		if current.URL != "" {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	current := manager.Status()[KindCloudflared]
	if current.URL == "" {
		t.Fatal("cloudflared URL was never discovered")
	}
	if err := manager.Stop(KindCloudflared); err != nil {
		t.Fatalf("stop: %v", err)
	}
	if _, ok := manager.Status()[KindCloudflared]; ok {
		t.Fatal("cloudflared state remained after stop")
	}
}

func TestManagerStartAndStopTailscaleWithFakeBinary(t *testing.T) {
	binary := writeScript(t, `#!/bin/sh
case "$1" in
  serve)
    if [ "$2" = "status" ]; then
      printf '%s\n' '{"Web":{"host.tail3d6e0.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8789"}}}}}'
      exit 0
    fi
    exit 0
    ;;
  funnel)
    if [ "$2" = "status" ]; then
      printf '%s\n' '{"Funnel":{"host.tail3d6e0.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8789"}}}}}'
      exit 0
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
`)
	manager := NewManager(slog.New(slog.NewTextHandler(os.Stderr, nil)), "http://127.0.0.1:8789", "", binary)
	manager.pollInterval = 10 * time.Millisecond
	manager.pollAttempts = 10

	status, err := manager.Start(KindTailscale)
	if err != nil {
		t.Fatalf("start tailscale: %v", err)
	}
	if status.URL != "https://host.tail3d6e0.ts.net/" {
		t.Fatalf("tailscale URL = %q", status.URL)
	}
	if err := manager.Stop(KindTailscale); err != nil {
		t.Fatalf("stop tailscale: %v", err)
	}
	if _, ok := manager.Status()[KindTailscale]; ok {
		t.Fatal("tailscale state remained after stop")
	}

	status, err = manager.Start(KindFunnel)
	if err != nil {
		t.Fatalf("start funnel: %v", err)
	}
	if status.URL != "https://host.tail3d6e0.ts.net/" {
		t.Fatalf("funnel URL = %q", status.URL)
	}
	if err := manager.Stop(KindFunnel); err != nil {
		t.Fatalf("stop funnel: %v", err)
	}
}

func writeScript(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "tunnel-adapter")
	if err := os.WriteFile(path, []byte(content), 0o700); err != nil {
		t.Fatalf("write script: %v", err)
	}
	return path
}
