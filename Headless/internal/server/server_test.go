package server

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
	"github.com/gorilla/websocket"
)

type memoryRuntime struct {
	mu       sync.Mutex
	sessions map[string][]byte
}

type listingRuntime struct {
	memoryRuntime
	lists  int
	exists int
}

type cancellationSensitiveRuntime struct {
	memoryRuntime
}

type recordedResize struct {
	columns int
	rows    int
}

type recordingRuntime struct {
	memoryRuntime
	events      []string
	resizes     []recordedResize
	captureSeen chan struct{}
	captureOnce sync.Once
}

func (runtime *recordingRuntime) Resize(_ context.Context, _ string, columns, rows int) error {
	runtime.mu.Lock()
	runtime.events = append(runtime.events, "resize")
	runtime.resizes = append(runtime.resizes, recordedResize{columns: columns, rows: rows})
	runtime.mu.Unlock()
	return nil
}

func (runtime *recordingRuntime) Capture(ctx context.Context, name string) ([]byte, error) {
	runtime.mu.Lock()
	runtime.events = append(runtime.events, "capture")
	runtime.mu.Unlock()
	runtime.captureOnce.Do(func() { close(runtime.captureSeen) })
	return runtime.memoryRuntime.Capture(ctx, name)
}

func (runtime *recordingRuntime) snapshotOrder() ([]string, []recordedResize) {
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	return append([]string(nil), runtime.events...), append([]recordedResize(nil), runtime.resizes...)
}

func (runtime *listingRuntime) List(context.Context) (map[string]bool, error) {
	runtime.lists++
	result := make(map[string]bool, len(runtime.sessions))
	for name := range runtime.sessions {
		result[name] = true
	}
	return result, nil
}

func (runtime *listingRuntime) Exists(ctx context.Context, name string) bool {
	runtime.exists++
	return runtime.memoryRuntime.Exists(ctx, name)
}

func (runtime *cancellationSensitiveRuntime) List(ctx context.Context) (map[string]bool, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	result := make(map[string]bool, len(runtime.sessions))
	for name := range runtime.sessions {
		result[name] = true
	}
	return result, nil
}

func (runtime *cancellationSensitiveRuntime) Exists(ctx context.Context, name string) bool {
	if ctx.Err() != nil {
		return false
	}
	return runtime.memoryRuntime.Exists(ctx, name)
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
	_ = requestResultBeforeBinary[api.Session](t, connection, "session.attach", map[string]any{"id": session.ID})
	if err := connection.WriteMessage(websocket.BinaryMessage, []byte("binary-input")); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(time.Second)
	for {
		runtime.mu.Lock()
		received := strings.Contains(string(runtime.sessions[session.Runtime]), "binary-input")
		runtime.mu.Unlock()
		if received {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("binary terminal input was not delivered")
		}
		time.Sleep(time.Millisecond)
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

func TestAttachSizeFromParamsRequiresCompletePositiveViewport(t *testing.T) {
	tests := []struct {
		name      string
		params    map[string]any
		columns   int
		rows      int
		specified bool
		wantError bool
	}{
		{name: "omitted for compatibility", params: nil},
		{name: "numbers", params: map[string]any{"cols": float64(101), "rows": float64(33)}, columns: 101, rows: 33, specified: true},
		{name: "desktop strings", params: map[string]any{"cols": "88", "rows": "27"}, columns: 88, rows: 27, specified: true},
		{name: "missing rows", params: map[string]any{"cols": 88}, wantError: true},
		{name: "zero columns", params: map[string]any{"cols": 0, "rows": 27}, wantError: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			columns, rows, specified, err := attachSizeFromParams(test.params)
			if test.wantError {
				if err == nil {
					t.Fatal("expected invalid terminal size")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if columns != test.columns || rows != test.rows || specified != test.specified {
				t.Fatalf("size = (%d, %d, %t), want (%d, %d, %t)", columns, rows, specified, test.columns, test.rows, test.specified)
			}
		})
	}
}

func TestBrowserAttachResizesBeforeFirstSnapshot(t *testing.T) {
	state, session := testSession(t)
	runtime := &recordingRuntime{
		memoryRuntime: memoryRuntime{sessions: map[string][]byte{session.Runtime: []byte("prompt")}},
		captureSeen:   make(chan struct{}),
	}
	httpServer := httptest.NewServer(NewHTTPServer(&Service{Store: state, Runtime: runtime}, "secret", slog.Default()).Handler())
	defer httpServer.Close()
	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	attachBrowserWithSize(t, connection, session.ID, nil, 101, 33)
	readBrowserMessage(t, connection, "attached")
	waitForCapture(t, runtime.captureSeen)
	assertResizePrecedesCapture(t, runtime, 101, 33)
}

func TestDesktopAttachResizesBeforeFirstSnapshot(t *testing.T) {
	state, session := testSession(t)
	runtime := &recordingRuntime{
		memoryRuntime: memoryRuntime{sessions: map[string][]byte{session.Runtime: []byte("prompt")}},
		captureSeen:   make(chan struct{}),
	}
	httpServer := httptest.NewServer(NewHTTPServer(&Service{Store: state, Runtime: runtime}, "secret", slog.Default()).Handler())
	defer httpServer.Close()
	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	_ = requestResultBeforeBinary[api.Session](t, connection, "session.attach", map[string]any{
		"id": session.ID, "cols": "88", "rows": "27",
	})
	waitForCapture(t, runtime.captureSeen)
	assertResizePrecedesCapture(t, runtime, 88, 27)
}

func TestOnlyFocusedPeerCanResizeSharedRuntime(t *testing.T) {
	state, session := testSession(t)
	runtime := &recordingRuntime{
		memoryRuntime: memoryRuntime{sessions: map[string][]byte{session.Runtime: []byte("prompt")}},
		captureSeen:   make(chan struct{}),
	}
	httpServer := httptest.NewServer(NewHTTPServer(&Service{Store: state, Runtime: runtime}, "secret", slog.Default()).Handler())
	defer httpServer.Close()

	first := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer first.Close()
	second := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer second.Close()

	_ = requestResultBeforeBinary[api.Session](t, first, "session.attach", map[string]any{
		"id": session.ID, "focused": true, "cols": 101, "rows": 33,
	})
	readBrowserMessage(t, first, "attached")
	readBinaryFrame(t, first)
	readBrowserMessage(t, first, "synced")

	_ = requestResultBeforeBinary[api.Session](t, second, "session.attach", map[string]any{
		"id": session.ID, "focused": false, "cols": 77, "rows": 27,
	})
	readBrowserMessage(t, second, "attached")
	readBinaryFrame(t, second)
	readBrowserMessage(t, second, "synced")

	_, resizes := runtime.snapshotOrder()
	if len(resizes) != 1 || resizes[0] != (recordedResize{columns: 101, rows: 33}) {
		t.Fatalf("passive attach changed runtime size: %#v", resizes)
	}

	background := requestResult[map[string]bool](t, second, "session.resize", map[string]any{
		"cols": 77, "rows": 27,
	})
	if background["resized"] {
		t.Fatal("background resize unexpectedly changed the runtime")
	}

	focused := requestResult[map[string]bool](t, second, "session.focus", map[string]any{
		"focused": true, "cols": 77, "rows": 27,
	})
	if !focused["focused"] || !focused["resized"] {
		t.Fatalf("focus handoff result = %#v", focused)
	}

	oldOwner := requestResult[map[string]bool](t, first, "session.resize", map[string]any{
		"cols": 101, "rows": 33,
	})
	if oldOwner["resized"] {
		t.Fatal("previous focus owner resized after handoff")
	}
	newOwner := requestResult[map[string]bool](t, second, "session.resize", map[string]any{
		"cols": 78, "rows": 28,
	})
	if !newOwner["resized"] {
		t.Fatal("current focus owner resize was ignored")
	}

	_, resizes = runtime.snapshotOrder()
	want := []recordedResize{{columns: 101, rows: 33}, {columns: 77, rows: 27}, {columns: 78, rows: 28}}
	if len(resizes) != len(want) {
		t.Fatalf("runtime resize calls = %#v, want %#v", resizes, want)
	}
	for index := range want {
		if resizes[index] != want[index] {
			t.Fatalf("runtime resize calls = %#v, want %#v", resizes, want)
		}
	}
}

func testSession(t *testing.T) (*store.Store, api.Session) {
	t.Helper()
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID := store.NewID()
	workspaceID := store.NewID()
	session := api.Session{
		ID: sessionIDForTest(), WorkspaceID: workspaceID, Title: "Shell", Kind: "shell",
		Runtime: "runtime-test", Lifecycle: "running", CreatedAt: time.Now().UTC(),
	}
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Name: "Project", Path: t.TempDir(), CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: "/tmp", Kind: "root", CreatedAt: time.Now().UTC()}}
		value.Sessions = []api.Session{session}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	return state, session
}

func sessionIDForTest() string { return store.NewID() }

func openAuthenticatedConnection(t *testing.T, serverURL, path string) *websocket.Conn {
	t.Helper()
	endpoint := "ws" + strings.TrimPrefix(serverURL, "http") + path
	connection, _, err := websocket.DefaultDialer.Dial(endpoint, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := connection.WriteJSON(api.Envelope{Type: "auth", Token: "secret"}); err != nil {
		connection.Close()
		t.Fatal(err)
	}
	var welcome map[string]any
	if err := connection.ReadJSON(&welcome); err != nil {
		connection.Close()
		t.Fatal(err)
	}
	if welcome["t"] != "welcome" {
		connection.Close()
		t.Fatalf("unexpected welcome: %#v", welcome)
	}
	return connection
}

func readBrowserMessage(t *testing.T, connection *websocket.Conn, messageType string) map[string]any {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	_ = connection.SetReadDeadline(deadline)
	defer connection.SetReadDeadline(time.Time{})
	for {
		kind, data, err := connection.ReadMessage()
		if err != nil {
			t.Fatal(err)
		}
		if kind != websocket.TextMessage {
			continue
		}
		var value map[string]any
		if json.Unmarshal(data, &value) == nil && value["t"] == messageType {
			return value
		}
	}
}

func waitForCapture(t *testing.T, captureSeen <-chan struct{}) {
	t.Helper()
	select {
	case <-captureSeen:
	case <-time.After(time.Second):
		t.Fatal("first terminal snapshot was not captured")
	}
}

func assertResizePrecedesCapture(t *testing.T, runtime *recordingRuntime, columns, rows int) {
	t.Helper()
	events, resizes := runtime.snapshotOrder()
	if len(events) < 2 || events[0] != "resize" || events[1] != "capture" {
		t.Fatalf("runtime events = %v, want [resize capture]", events)
	}
	if len(resizes) != 1 || resizes[0] != (recordedResize{columns: columns, rows: rows}) {
		t.Fatalf("resize calls = %#v", resizes)
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

func requestResultBeforeBinary[T any](t *testing.T, connection *websocket.Conn, method string, params map[string]any) T {
	t.Helper()
	id := store.NewID()
	if err := connection.WriteJSON(api.Envelope{Type: "request", ID: id, Method: method, Params: params}); err != nil {
		t.Fatal(err)
	}
	for {
		messageType, data, err := connection.ReadMessage()
		if err != nil {
			t.Fatal(err)
		}
		if messageType == websocket.BinaryMessage {
			t.Fatal("terminal output arrived before the attach response")
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
	handler := NewHTTPServer(&Service{Store: state, Runtime: &memoryRuntime{sessions: map[string][]byte{}}}, "secret", slog.Default())
	handler.BuildVersion = "abc1234"
	handler.Handler().ServeHTTP(response, request)
	if response.Code != 200 {
		t.Fatalf("health returned %d", response.Code)
	}
	var body struct {
		OK      bool   `json:"ok"`
		Version string `json:"version"`
		Build   string `json:"build"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode health body: %v", err)
	}
	if !body.OK || body.Version != api.Version || body.Build != "abc1234" {
		t.Fatalf("health body = %+v", body)
	}
}

func TestCACertDownload(t *testing.T) {
	t.Parallel()
	caPath := filepath.Join(t.TempDir(), "ca.crt")
	if err := os.WriteFile(caPath, []byte("-----BEGIN CERTIFICATE-----\nZmFrZQ==\n-----END CERTIFICATE-----\n"), 0o600); err != nil {
		t.Fatalf("write CA certificate: %v", err)
	}
	handler := NewHTTPServer(&Service{}, "secret", slog.Default())
	handler.CACertPath = caPath
	request := httptest.NewRequest("GET", "http://localhost/tls/ca.pem", nil)
	response := httptest.NewRecorder()
	handler.Handler().ServeHTTP(response, request)
	if response.Code != 200 {
		t.Fatalf("CA download returned %d", response.Code)
	}
	if contentType := response.Header().Get("Content-Type"); contentType != "application/x-x509-ca-cert" {
		t.Fatalf("Content-Type = %q", contentType)
	}
	if body := response.Body.String(); !strings.Contains(body, "BEGIN CERTIFICATE") {
		t.Fatalf("CA body = %q", body)
	}
}

func TestSameOriginAllowsLANAndForwardedHTTPS(t *testing.T) {
	t.Parallel()
	server := NewHTTPServer(&Service{}, "secret", slog.Default())
	cases := []struct {
		name   string
		host   string
		origin string
		proto  string
		want   bool
	}{
		{name: "LAN direct", host: "192.168.1.117:8789", origin: "http://192.168.1.117:8789", want: true},
		{name: "LAN hostname", host: "mac-mini.local:8789", origin: "http://mac-mini.local:8789", want: true},
		{name: "loopback", host: "127.0.0.1:8789", origin: "http://127.0.0.1:8789", want: true},
		{name: "localhost", host: "localhost:8789", origin: "http://localhost:8789", want: true},
		{name: "tailscale serve", host: "host.tail3d6e0.ts.net", origin: "https://host.tail3d6e0.ts.net", proto: "https", want: true},
		{name: "cloudflared", host: "warren.example.com", origin: "https://warren.example.com", proto: "https", want: true},
		{name: "cross-site origin", host: "192.168.1.117:8789", origin: "http://evil.example", want: false},
		{name: "wrong scheme", host: "192.168.1.117:8789", origin: "https://192.168.1.117:8789", want: false},
		{name: "different LAN host", host: "192.168.1.117:8789", origin: "http://192.168.1.118:8789", want: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			request := httptest.NewRequest("GET", "http://"+tc.host+"/v1/ws", nil)
			request.Header.Set("Origin", tc.origin)
			if tc.proto != "" {
				request.Header.Set("X-Forwarded-Proto", tc.proto)
			}
			if got := server.upgrader.CheckOrigin(request); got != tc.want {
				t.Fatalf("CheckOrigin(host=%q origin=%q proto=%q) = %v, want %v", tc.host, tc.origin, tc.proto, got, tc.want)
			}
		})
	}
}

func TestRosterUsesOneRuntimeListing(t *testing.T) {
	state, _ := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	runtime := &listingRuntime{memoryRuntime: memoryRuntime{sessions: map[string][]byte{"running": {}}}}
	service := &Service{Store: state, Runtime: runtime}
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{ID: "one", Runtime: "running", Lifecycle: "running"}, {ID: "two", Runtime: "missing", Lifecycle: "running"}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	roster := service.Roster(context.Background())
	if runtime.lists != 1 || runtime.exists != 0 {
		t.Fatalf("runtime probes: lists=%d exists=%d", runtime.lists, runtime.exists)
	}
	if roster.Sessions[0].Lifecycle != "running" || roster.Sessions[1].Lifecycle != "ended" {
		t.Fatalf("unexpected lifecycle reconciliation: %#v", roster.Sessions)
	}
}

func TestRosterDoesNotEndSessionWhenObserverContextIsCanceled(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	runtime := &cancellationSensitiveRuntime{
		memoryRuntime: memoryRuntime{sessions: map[string][]byte{"runtime-live": {}}},
	}
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{
			ID: "session", Runtime: "runtime-live", Lifecycle: "running", CreatedAt: time.Now().UTC(),
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	roster := (&Service{Store: state, Runtime: runtime}).Roster(ctx)
	if roster.Sessions[0].Lifecycle != "running" {
		t.Fatalf("canceled observer context ended a live session: %#v", roster.Sessions[0])
	}
}
