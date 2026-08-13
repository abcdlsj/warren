package server

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
	"github.com/gorilla/websocket"
)

type memoryRuntime struct {
	mu       sync.Mutex
	sessions map[string][]byte
}

func (m *memoryRuntime) Create(_ context.Context, name, _, _ string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sessions[name] = []byte("ready\n")
	return nil
}
func (m *memoryRuntime) Exists(_ context.Context, name string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	_, ok := m.sessions[name]
	return ok
}
func (m *memoryRuntime) Capture(_ context.Context, name string) ([]byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]byte(nil), m.sessions[name]...), nil
}
func (m *memoryRuntime) Input(_ context.Context, name string, data []byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sessions[name] = append(m.sessions[name], data...)
	return nil
}
func (m *memoryRuntime) Resize(context.Context, string, int, int) error { return nil }
func (m *memoryRuntime) Kill(_ context.Context, name string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.sessions, name)
	return nil
}

func TestWebSocketAuthenticationAndResourceLifecycle(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	repository := filepath.Join(directory, "repository")
	if err := os.MkdirAll(repository, 0o755); err != nil {
		t.Fatal(err)
	}
	if output, err := exec.Command("git", "-C", repository, "init", "--quiet").CombinedOutput(); err != nil {
		t.Fatalf("git init: %s: %v", output, err)
	}
	state, err := store.Open(filepath.Join(directory, "state.json"), "test-vps")
	if err != nil {
		t.Fatal(err)
	}
	runtime := &memoryRuntime{sessions: map[string][]byte{}}
	service := &Service{Store: state, Runtime: runtime, WorktreeRoot: filepath.Join(directory, "worktrees")}
	server := httptest.NewServer(NewHTTPServer(service, "secret", slog.Default()).Handler())
	defer server.Close()

	endpoint := "ws" + strings.TrimPrefix(server.URL, "http") + "/v1/ws"
	connection, _, err := websocket.DefaultDialer.Dial(endpoint, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	if err := connection.WriteJSON(api.Envelope{Type: "auth", Token: "secret"}); err != nil {
		t.Fatal(err)
	}
	var welcome map[string]any
	if err := connection.ReadJSON(&welcome); err != nil {
		t.Fatal(err)
	}
	if welcome["t"] != "welcome" {
		t.Fatalf("unexpected welcome: %#v", welcome)
	}

	project := requestResult[api.Project](t, connection, "project.add", map[string]any{"path": repository})
	if project.Name != "repository" {
		t.Fatalf("unexpected project: %#v", project)
	}
	roster := requestResult[api.State](t, connection, "roster", nil)
	if len(roster.Workspaces) != 1 {
		t.Fatalf("expected root workspace, got %#v", roster.Workspaces)
	}
	session := requestResult[api.Session](t, connection, "session.create", map[string]any{"workspace": roster.Workspaces[0].ID, "kind": "shell"})
	if !runtime.Exists(context.Background(), session.Runtime) {
		t.Fatal("runtime was not created")
	}
	_ = requestResult[map[string]bool](t, connection, "session.delete", map[string]any{"id": session.ID})
	if runtime.Exists(context.Background(), session.Runtime) {
		t.Fatal("runtime was not deleted")
	}
}

func TestRejectsInvalidToken(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	state, _ := store.Open(filepath.Join(directory, "state.json"), "test")
	httpServer := httptest.NewServer(NewHTTPServer(&Service{Store: state, Runtime: &memoryRuntime{sessions: map[string][]byte{}}}, "secret", slog.Default()).Handler())
	defer httpServer.Close()
	endpoint := "ws" + strings.TrimPrefix(httpServer.URL, "http") + "/v1/ws"
	connection, _, err := websocket.DefaultDialer.Dial(endpoint, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	_ = connection.WriteJSON(api.Envelope{Type: "auth", Token: "wrong"})
	var response api.Response
	if err := connection.ReadJSON(&response); err != nil {
		t.Fatal(err)
	}
	if response.Error != "unauthorized" {
		t.Fatalf("unexpected response: %#v", response)
	}
}

func requestResult[T any](t *testing.T, connection *websocket.Conn, method string, params map[string]any) T {
	t.Helper()
	id := store.NewID()
	if err := connection.WriteJSON(api.Envelope{Type: "request", ID: id, Method: method, Params: params}); err != nil {
		t.Fatal(err)
	}
	for {
		_, data, err := connection.ReadMessage()
		if err != nil {
			t.Fatal(err)
		}
		var response api.Response
		if json.Unmarshal(data, &response) != nil || response.Type != "response" || response.ID != id {
			continue
		}
		if !response.OK {
			t.Fatal(response.Error)
		}
		raw, _ := json.Marshal(response.Result)
		var result T
		if err := json.Unmarshal(raw, &result); err != nil {
			t.Fatal(err)
		}
		return result
	}
}

func TestHealthEndpoint(t *testing.T) {
	t.Parallel()
	request := httptest.NewRequest("GET", "http://localhost/healthz", nil)
	response := httptest.NewRecorder()
	directory := t.TempDir()
	state, _ := store.Open(filepath.Join(directory, "state.json"), "test")
	NewHTTPServer(&Service{Store: state, Runtime: &memoryRuntime{sessions: map[string][]byte{}}}, "secret", slog.Default()).Handler().ServeHTTP(response, request)
	if response.Code != 200 {
		t.Fatalf("health returned %d", response.Code)
	}
	if _, err := url.Parse(response.Body.String()); err == nil {
		t.Fatal("health body unexpectedly parsed as URL")
	}
}
