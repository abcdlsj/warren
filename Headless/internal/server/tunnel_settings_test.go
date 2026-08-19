package server

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
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

func TestSetAutoStartAIIsOptInAndPersists(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	service := &Service{SettingsPath: path}
	if service.Settings.AutoStartAI {
		t.Fatal("auto-start AI must default to disabled")
	}

	if err := service.SetAutoStartAI(true); err != nil {
		t.Fatalf("enable auto-start AI: %v", err)
	}
	loaded, err := settings.Load(path)
	if err != nil {
		t.Fatalf("load enabled settings: %v", err)
	}
	if !loaded.AutoStartAI {
		t.Fatal("enabled autoStartAI was not persisted")
	}

	if err := service.SetAutoStartAI(false); err != nil {
		t.Fatalf("disable auto-start AI: %v", err)
	}
	loaded, err = settings.Load(path)
	if err != nil {
		t.Fatalf("load disabled settings: %v", err)
	}
	if loaded.AutoStartAI {
		t.Fatal("disabled autoStartAI remained enabled")
	}
}

func TestSetAutoOpenShellIsOptInAndPersists(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	service := &Service{SettingsPath: path}
	if service.Settings.AutoOpenShell {
		t.Fatal("auto-open shell must default to disabled")
	}

	if err := service.SetAutoOpenShell(true); err != nil {
		t.Fatalf("enable auto-open shell: %v", err)
	}
	loaded, err := settings.Load(path)
	if err != nil {
		t.Fatalf("load enabled settings: %v", err)
	}
	if !loaded.AutoOpenShell {
		t.Fatal("enabled autoOpenShell was not persisted")
	}

	if err := service.SetAutoOpenShell(false); err != nil {
		t.Fatalf("disable auto-open shell: %v", err)
	}
	loaded, err = settings.Load(path)
	if err != nil {
		t.Fatalf("load disabled settings: %v", err)
	}
	if loaded.AutoOpenShell {
		t.Fatal("disabled autoOpenShell remained enabled")
	}
}

func TestHTTPSettingsExposeWorkspaceDefaults(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	service := &Service{
		Runtime:        &memoryRuntime{sessions: map[string][]byte{}},
		DefaultRuntime: settings.RuntimeGhostline,
		SettingsPath:   path,
	}
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()

	request, err := http.NewRequest(http.MethodGet, httpServer.URL+"/v1/settings", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer secret")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("get settings: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("get settings status = %d", response.StatusCode)
	}
	var initial map[string]any
	if err := json.NewDecoder(response.Body).Decode(&initial); err != nil {
		t.Fatalf("decode initial settings: %v", err)
	}
	if initial["autoOpenShell"] != false || initial["autoStartAI"] != false {
		t.Fatalf("initial workspace defaults = %#v", initial)
	}

	body, err := json.Marshal(map[string]bool{
		"autoOpenShell": true,
		"autoStartAI":   true,
	})
	if err != nil {
		t.Fatal(err)
	}
	request, err = http.NewRequest(http.MethodPut, httpServer.URL+"/v1/settings", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer secret")
	request.Header.Set("Content-Type", "application/json")
	response, err = http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("put settings: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("put settings status = %d", response.StatusCode)
	}
	var updated map[string]any
	if err := json.NewDecoder(response.Body).Decode(&updated); err != nil {
		t.Fatalf("decode updated settings: %v", err)
	}
	if updated["autoStartAI"] != true || updated["autoOpenShell"] != true {
		t.Fatalf("updated workspace defaults = %#v", updated)
	}
	loaded, err := settings.Load(path)
	if err != nil {
		t.Fatalf("load persisted settings: %v", err)
	}
	if !loaded.AutoStartAI || !loaded.AutoOpenShell {
		t.Fatalf("persisted workspace defaults = %#v", loaded)
	}
}
