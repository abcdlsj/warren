package server

import (
	"path/filepath"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/settings"
	"github.com/abcdlsj/warren/Headless/internal/tunnel"
)

func TestUpdateTunnelEnabledPersistsIntent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	service := &Service{SettingsPath: path}

	if err := service.UpdateTunnelEnabled(tunnel.KindGnar, true); err != nil {
		t.Fatalf("enable gnar: %v", err)
	}
	loaded, err := settings.Load(path)
	if err != nil {
		t.Fatalf("load settings: %v", err)
	}
	if !loaded.TunnelEnabled[tunnel.KindGnar] {
		t.Fatalf("enabled tunnels = %#v, want gnar", loaded.TunnelEnabled)
	}

	if err := service.UpdateTunnelEnabled(tunnel.KindGnar, false); err != nil {
		t.Fatalf("disable gnar: %v", err)
	}
	loaded, err = settings.Load(path)
	if err != nil {
		t.Fatalf("reload settings: %v", err)
	}
	if loaded.TunnelEnabled[tunnel.KindGnar] {
		t.Fatalf("enabled tunnels = %#v, want gnar cleared", loaded.TunnelEnabled)
	}
}

func TestUpdateTunnelEnabledRejectsUnknownKind(t *testing.T) {
	service := &Service{SettingsPath: filepath.Join(t.TempDir(), "settings.json")}
	if err := service.UpdateTunnelEnabled("bogus", true); err == nil {
		t.Fatal("unknown tunnel kind must fail")
	}
}
