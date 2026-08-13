package server

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/gorilla/websocket"
)

type HTTPServer struct {
	Service  *Service
	Token    string
	Logger   *slog.Logger
	upgrader websocket.Upgrader
}

func NewHTTPServer(service *Service, token string, logger *slog.Logger) *HTTPServer {
	return &HTTPServer{
		Service: service,
		Token:   token,
		Logger:  logger,
		upgrader: websocket.Upgrader{
			ReadBufferSize: 64 * 1024, WriteBufferSize: 64 * 1024,
			CheckOrigin: func(request *http.Request) bool {
				origin := request.Header.Get("Origin")
				return origin == "" || strings.HasPrefix(origin, "http://127.0.0.1") || strings.HasPrefix(origin, "http://localhost")
			},
		},
	}
}

func (s *HTTPServer) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(writer).Encode(map[string]any{"ok": true, "version": api.Version})
	})
	mux.HandleFunc("GET /v1/state", s.handleState)
	mux.HandleFunc("GET /v1/ws", s.handleWebSocket)
	return mux
}

func (s *HTTPServer) handleState(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	writer.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(writer).Encode(s.Service.Roster(request.Context()))
}

func (s *HTTPServer) handleWebSocket(writer http.ResponseWriter, request *http.Request) {
	connection, err := s.upgrader.Upgrade(writer, request, nil)
	if err != nil {
		return
	}
	peer := &wsPeer{
		connection: connection,
		server:     s,
		closed:     make(chan struct{}),
		outputWake: make(chan struct{}, 1),
	}
	defer peer.close()
	_ = connection.SetReadDeadline(time.Now().Add(10 * time.Second))
	var envelope api.Envelope
	if err := connection.ReadJSON(&envelope); err != nil || envelope.Type != "auth" || !s.authorized(envelope.Token) {
		_ = peer.writeJSON(api.Response{Type: "error", OK: false, Error: "unauthorized"})
		return
	}
	_ = connection.SetReadDeadline(time.Time{})
	state, revision := s.Service.RosterVersion(request.Context())
	if err := peer.writeJSON(map[string]any{"t": "welcome", "version": api.Version, "host": state.Host}); err != nil {
		return
	}
	peer.startRoster(request.Context(), state, revision)
	for {
		messageType, data, err := connection.ReadMessage()
		if err != nil {
			return
		}
		if messageType == websocket.BinaryMessage {
			if err := peer.input(request.Context(), data); err != nil {
				_ = peer.writeError("", err)
			}
			continue
		}
		var command api.Envelope
		if err := json.Unmarshal(data, &command); err != nil {
			_ = peer.writeError("", fmt.Errorf("invalid request: %w", err))
			continue
		}
		if err := peer.handle(request.Context(), command); err != nil {
			_ = peer.writeError(command.ID, err)
		}
	}
}

func (s *HTTPServer) authorized(value string) bool {
	return value != "" && subtle.ConstantTimeCompare([]byte(value), []byte(s.Token)) == 1
}

type wsPeer struct {
	connection   *websocket.Conn
	server       *HTTPServer
	writeMu      sync.Mutex
	attached     *api.Session
	streamCancel context.CancelFunc
	rosterCancel context.CancelFunc
	closed       chan struct{}
	outputWake   chan struct{}
	closeOnce    sync.Once
}

func (p *wsPeer) close() {
	p.closeOnce.Do(func() {
		if p.streamCancel != nil {
			p.streamCancel()
		}
		if p.rosterCancel != nil {
			p.rosterCancel()
		}
		close(p.closed)
		_ = p.connection.Close()
	})
}

func (p *wsPeer) writeJSON(value any) error {
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	_ = p.connection.SetWriteDeadline(time.Now().Add(10 * time.Second))
	return p.connection.WriteJSON(value)
}

func (p *wsPeer) writeBinary(value []byte) error {
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	_ = p.connection.SetWriteDeadline(time.Now().Add(10 * time.Second))
	return p.connection.WriteMessage(websocket.BinaryMessage, value)
}

func (p *wsPeer) writeText(value []byte) error {
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	_ = p.connection.SetWriteDeadline(time.Now().Add(10 * time.Second))
	return p.connection.WriteMessage(websocket.TextMessage, value)
}

func (p *wsPeer) writeResult(id string, result any) error {
	return p.writeJSON(api.Response{Type: "response", ID: id, OK: true, Result: result})
}
func (p *wsPeer) writeError(id string, err error) error {
	return p.writeJSON(api.Response{Type: "response", ID: id, OK: false, Error: err.Error()})
}

func (p *wsPeer) startRoster(parent context.Context, initial api.State, initialRevision uint64) {
	ctx, cancel := context.WithCancel(parent)
	p.rosterCancel = cancel
	go func() {
		ticker := time.NewTicker(750 * time.Millisecond)
		defer ticker.Stop()
		state := initial
		revision := initialRevision
		var last []byte
		for {
			data, _ := json.Marshal(struct {
				Type  string    `json:"t"`
				State api.State `json:"state"`
			}{Type: "roster", State: state})
			if !bytes.Equal(data, last) {
				last = append(last[:0], data...)
				if p.writeText(data) != nil {
					p.close()
					return
				}
			}
			select {
			case <-ctx.Done():
				return
			case <-p.server.Service.Store.ChangesSince(revision):
				state, revision = p.server.Service.RosterVersion(ctx)
			case <-ticker.C:
				state, revision = p.server.Service.RosterVersion(ctx)
			}
		}
	}()
}

func (p *wsPeer) handle(ctx context.Context, command api.Envelope) error {
	if command.Type != "request" {
		return fmt.Errorf("unsupported message type: %s", command.Type)
	}
	params := command.Params
	switch command.Method {
	case "roster":
		return p.writeResult(command.ID, p.server.Service.Roster(ctx))
	case "project.add":
		value, err := p.server.Service.AddProject(stringParam(params, "path"), stringParam(params, "name"))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "project.remove":
		if err := p.server.Service.RemoveProject(stringParam(params, "id"), boolParam(params, "force")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"removed": true})
	case "workspace.create":
		value, err := p.server.Service.CreateWorkspace(stringParam(params, "project"), stringParam(params, "branch"), stringParam(params, "name"), stringParam(params, "path"))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "workspace.remove":
		if err := p.server.Service.RemoveWorkspace(ctx, stringParam(params, "id"), boolParam(params, "force")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"removed": true})
	case "session.create":
		value, err := p.server.Service.CreateSession(ctx, stringParam(params, "workspace"), stringParam(params, "command"), stringParam(params, "kind"), stringParam(params, "title"))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "session.delete":
		id := stringParam(params, "id")
		if err := p.server.Service.DeleteSession(ctx, id); err != nil {
			return err
		}
		if p.attached != nil && p.attached.ID == id {
			p.detach()
		}
		return p.writeResult(command.ID, map[string]bool{"deleted": true})
	case "session.attach":
		id := stringParam(params, "id")
		session, ok := p.server.Service.Session(id)
		if !ok {
			return fmt.Errorf("session not found: %s", id)
		}
		if session.Lifecycle != "running" {
			return fmt.Errorf("session is not running: %s", id)
		}
		p.attach(ctx, session)
		return p.writeResult(command.ID, session)
	case "session.detach":
		p.detach()
		return p.writeResult(command.ID, map[string]bool{"detached": true})
	case "session.input":
		encoded := stringParam(params, "data")
		value, err := base64.StdEncoding.DecodeString(encoded)
		if err != nil {
			return err
		}
		if err := p.input(ctx, value); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"sent": true})
	case "session.resize":
		if p.attached == nil {
			return fmt.Errorf("no attached session")
		}
		columns := intParam(params, "cols")
		rows := intParam(params, "rows")
		if columns <= 0 || rows <= 0 {
			return fmt.Errorf("invalid terminal size")
		}
		if err := p.server.Service.Runtime.Resize(ctx, p.attached.Runtime, columns, rows); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"resized": true})
	default:
		return fmt.Errorf("unknown method: %s", command.Method)
	}
}

func (p *wsPeer) input(ctx context.Context, data []byte) error {
	if p.attached == nil {
		return fmt.Errorf("no attached session")
	}
	if err := p.server.Service.Runtime.Input(ctx, p.attached.Runtime, data); err != nil {
		return err
	}
	select {
	case p.outputWake <- struct{}{}:
	default:
	}
	return nil
}

func (p *wsPeer) attach(parent context.Context, session api.Session) {
	p.detach()
	p.attached = &session
	ctx, cancel := context.WithCancel(parent)
	p.streamCancel = cancel
	go func() {
		const activeInterval = 50 * time.Millisecond
		const idleInterval = 500 * time.Millisecond
		timer := time.NewTimer(0)
		defer timer.Stop()
		last := ""
		interval := activeInterval
		for {
			select {
			case <-ctx.Done():
				return
			case <-p.outputWake:
				resetTimer(timer, 0)
				continue
			case <-timer.C:
			}
			output, err := p.server.Service.Runtime.Capture(ctx, session.Runtime)
			if err != nil {
				_ = p.writeJSON(map[string]any{"t": "exited", "session": session.ID})
				return
			}
			current := string(output)
			if current != last {
				last = current
				interval = activeInterval
				if p.writeBinary(output) != nil {
					p.close()
					return
				}
			} else {
				interval = min(interval*2, idleInterval)
			}
			resetTimer(timer, interval)
		}
	}()
}

func resetTimer(timer *time.Timer, delay time.Duration) {
	if !timer.Stop() {
		select {
		case <-timer.C:
		default:
		}
	}
	timer.Reset(delay)
}

func (p *wsPeer) detach() {
	if p.streamCancel != nil {
		p.streamCancel()
		p.streamCancel = nil
	}
	p.attached = nil
}

func stringParam(values map[string]any, key string) string {
	value, _ := values[key].(string)
	return strings.TrimSpace(value)
}
func boolParam(values map[string]any, key string) bool { value, _ := values[key].(bool); return value }
func intParam(values map[string]any, key string) int {
	switch value := values[key].(type) {
	case float64:
		return int(value)
	case string:
		result, _ := strconv.Atoi(value)
		return result
	}
	return 0
}
