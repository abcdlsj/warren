package server

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/output"
	"github.com/abcdlsj/warren/Headless/internal/tunnel"
	"github.com/gorilla/websocket"
)

const (
	// High-throughput TUI output (codex, long-running builds) can fill a
	// small per-peer queue before a mobile or hidden browser drains it. The
	// queue is deliberately generous: memory is cheap and the only fallback
	// is closing the peer, which today means a visible reanchor.
	outboundQueueCapacity = 8192
	outboundWriteTimeout  = 30 * time.Second
)

type HTTPServer struct {
	Service      *Service
	Token        string
	Logger       *slog.Logger
	Tunnels      *tunnel.Manager
	BuildVersion string
	upgrader     websocket.Upgrader
}

type rosterMessage struct {
	Type  string    `json:"t"`
	State api.State `json:"state"`
}

func NewHTTPServer(service *Service, token string, logger *slog.Logger) *HTTPServer {
	return &HTTPServer{
		Service: service,
		Token:   token,
		Logger:  logger,
		upgrader: websocket.Upgrader{
			ReadBufferSize: 256 * 1024, WriteBufferSize: 256 * 1024,
			CheckOrigin: func(request *http.Request) bool {
				origin := request.Header.Get("Origin")
				return origin == "" || sameOrigin(request, origin)
			},
		},
	}
}

// sameOrigin allows the Web UI served from any host/IP to open the WebSocket
// (for example a phone reaching the daemon over LAN), while still rejecting
// cross-site browser connections. Loopback prefixes are kept as a compatibility
// fallback for local clients that connect through a proxy with a different Host.
func sameOrigin(request *http.Request, origin string) bool {
	if strings.HasPrefix(origin, "http://127.0.0.1") ||
		strings.HasPrefix(origin, "http://localhost") ||
		strings.HasPrefix(origin, "http://[::1]") {
		return true
	}
	parsed, err := url.Parse(origin)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		return false
	}
	scheme := effectiveScheme(request)
	if parsed.Scheme != scheme {
		return false
	}
	originHost := parsed.Hostname()
	originPort := parsed.Port()
	if originPort == "" {
		originPort = defaultPort(parsed.Scheme)
	}
	requestHost, requestPort := request.Host, ""
	if host, port, err := net.SplitHostPort(request.Host); err == nil {
		requestHost, requestPort = host, port
	}
	if requestPort == "" {
		requestPort = defaultPort(scheme)
	}
	return strings.EqualFold(requestHost, originHost) && requestPort == originPort
}

// effectiveScheme returns the scheme the browser actually used, honoring TLS
// termination by cloudflared or Tailscale Serve.
func effectiveScheme(request *http.Request) string {
	if forwarded := request.Header.Get("X-Forwarded-Proto"); forwarded != "" {
		if fields := strings.Fields(forwarded); len(fields) > 0 {
			if scheme := fields[0]; scheme == "http" || scheme == "https" {
				return scheme
			}
		}
	}
	if request.TLS != nil {
		return "https"
	}
	return "http"
}

func defaultPort(scheme string) string {
	if scheme == "https" {
		return "443"
	}
	return "80"
}

func (s *HTTPServer) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(writer).Encode(map[string]any{
			"ok":      true,
			"version": api.Version,
			"build":   s.BuildVersion,
		})
	})
	mux.HandleFunc("GET /v1/state", s.handleState)
	mux.HandleFunc("GET /v1/ws", s.handleWebSocket)
	mux.HandleFunc("GET /v1/tunnels", s.handleTunnels)
	mux.HandleFunc("POST /v1/tunnels/start", s.handleTunnelStart)
	mux.HandleFunc("POST /v1/tunnels/stop", s.handleTunnelStop)
	mux.HandleFunc("GET /", s.handleWebAsset)
	mux.HandleFunc("GET /service-worker.js", s.handleWebAsset)
	mux.HandleFunc("GET /manifest.webmanifest", s.handleWebAsset)
	mux.HandleFunc("GET /assets/", s.handleWebAsset)
	mux.HandleFunc("GET /preset-", s.handleWebAsset)
	mux.HandleFunc("GET /icon", s.handleWebAsset)
	mux.HandleFunc("GET /apple-touch-icon.png", s.handleWebAsset)
	return mux
}

func (s *HTTPServer) handleWebAsset(writer http.ResponseWriter, request *http.Request) {
	root := os.Getenv("WARREN_WEB_ROOT")
	if root == "" {
		root = filepath.Join(filepath.Dir(os.Args[0]), "..", "Resources")
	}
	name := strings.TrimPrefix(request.URL.Path, "/")
	if name == "" {
		name = "index.html"
	}
	if name == "index.html" {
		data, err := os.ReadFile(filepath.Join(root, name))
		if err != nil {
			http.Error(writer, "Warren Web unavailable", http.StatusNotFound)
			return
		}
		writer.Header().Set("Content-Type", "text/html; charset=utf-8")
		writer.Header().Set("Cache-Control", "no-store")
		_, _ = writer.Write(data)
		return
	}
	clean := filepath.Clean(name)
	if clean == "." || strings.HasPrefix(clean, "..") || filepath.IsAbs(clean) {
		http.Error(writer, "not found", http.StatusNotFound)
		return
	}
	data, err := os.ReadFile(filepath.Join(root, clean))
	if err != nil {
		http.Error(writer, "not found", http.StatusNotFound)
		return
	}
	writer.Header().Set("Content-Type", webContentType(clean))
	// Assets use fixed filenames (assets/app.js, assets/app.css), so a rebuilt
	// bundle must never be masked by a browser or service-worker cache. Force
	// revalidation; the payloads are small enough that the extra request is
	// cheaper than serving a stale client that renders DENB frames as text.
	writer.Header().Set("Cache-Control", "no-cache")
	_, _ = writer.Write(data)
}

func webContentType(path string) string {
	switch filepath.Ext(path) {
	case ".css":
		return "text/css; charset=utf-8"
	case ".js":
		return "text/javascript; charset=utf-8"
	case ".json", ".webmanifest":
		return "application/json"
	case ".svg":
		return "image/svg+xml"
	case ".png":
		return "image/png"
	default:
		return "application/octet-stream"
	}
}

func (s *HTTPServer) handleState(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	writer.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(writer).Encode(s.Service.Roster(request.Context()))
}

func (s *HTTPServer) handleTunnels(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	if s.Tunnels == nil {
		http.Error(writer, "tunnel manager unavailable", http.StatusServiceUnavailable)
		return
	}
	writer.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(writer).Encode(tunnelResponse(s.Tunnels.Status(), s.Token))
}

func (s *HTTPServer) handleTunnelStart(writer http.ResponseWriter, request *http.Request) {
	s.handleTunnelControl(writer, request, true)
}

func (s *HTTPServer) handleTunnelStop(writer http.ResponseWriter, request *http.Request) {
	s.handleTunnelControl(writer, request, false)
}

func (s *HTTPServer) handleTunnelControl(writer http.ResponseWriter, request *http.Request, start bool) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	if s.Tunnels == nil {
		http.Error(writer, "tunnel manager unavailable", http.StatusServiceUnavailable)
		return
	}
	var body struct {
		Kind string `json:"kind"`
	}
	if json.NewDecoder(http.MaxBytesReader(writer, request.Body, 16*1024)).Decode(&body) != nil {
		http.Error(writer, "invalid request", http.StatusBadRequest)
		return
	}
	var err error
	if start {
		_, err = s.Tunnels.Start(body.Kind)
	} else {
		err = s.Tunnels.Stop(body.Kind)
	}
	if err != nil {
		http.Error(writer, err.Error(), http.StatusBadRequest)
		return
	}
	writer.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(writer).Encode(tunnelResponse(s.Tunnels.Status(), s.Token))
}

func tunnelResponse(status map[string]tunnel.Status, token string) map[string]any {
	result := make(map[string]any, len(status))
	for kind, value := range status {
		item := map[string]any{"running": value.Running}
		if value.URL != "" {
			item["url"] = value.URL
			item["web_url"] = value.URL + "#t=" + token
		}
		if value.Error != "" {
			item["error"] = value.Error
		}
		result[kind] = item
	}
	return map[string]any{"tunnels": result}
}

func (s *HTTPServer) handleWebSocket(writer http.ResponseWriter, request *http.Request) {
	connection, err := s.upgrader.Upgrade(writer, request, nil)
	if err != nil {
		return
	}
	peer := newWSPeer(s, connection)
	defer peer.close()
	_ = connection.SetReadDeadline(time.Now().Add(10 * time.Second))
	var envelope api.Envelope
	if err := connection.ReadJSON(&envelope); err != nil || envelope.Type != "auth" || !s.authorized(envelope.Token) {
		_ = peer.writeJSON(api.Response{Type: "error", OK: false, Error: "unauthorized"})
		return
	}
	if envelope.Version != "" && !compatibleProtocolVersion(envelope.Version, api.Version) {
		_ = peer.writeJSON(api.Response{Type: "error", OK: false, Error: fmt.Sprintf(
			"incompatible protocol version: client=%s server=%s", envelope.Version, api.Version,
		)})
		return
	}
	_ = connection.SetReadDeadline(time.Time{})
	state, revision := s.Service.RosterVersion(request.Context())
	if err := peer.writeJSON(map[string]any{"t": "welcome", "version": api.Version, "host": state.Host}); err != nil {
		return
	}
	_ = peer.writeJSON(makeRoster(state))
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

func compatibleProtocolVersion(client, server string) bool {
	clientMajor := strings.SplitN(client, ".", 2)[0]
	serverMajor := strings.SplitN(server, ".", 2)[0]
	return clientMajor != "" && clientMajor == serverMajor
}

func (s *HTTPServer) authorized(value string) bool {
	return value != "" && subtle.ConstantTimeCompare([]byte(value), []byte(s.Token)) == 1
}

type outboundMessage struct {
	kind int
	data []byte
}

// wsPeer owns an independent outbound queue and writer goroutine. A slow
// client only fills its own queue; overflow or a write timeout closes exactly
// this peer, and the client reconnects from its last Recovery Anchor.
type wsPeer struct {
	server     *HTTPServer
	connection *websocket.Conn
	outbound   chan outboundMessage

	enqueueMu      sync.Mutex
	closed         chan struct{}
	closeFlag      bool
	attached       *api.Session
	controlSession string
	rosterCancel   context.CancelFunc
}

func newWSPeer(server *HTTPServer, connection *websocket.Conn) *wsPeer {
	peer := &wsPeer{
		server:     server,
		connection: connection,
		outbound:   make(chan outboundMessage, outboundQueueCapacity),
		closed:     make(chan struct{}),
	}
	go peer.writeLoop()
	return peer
}

func (p *wsPeer) close() {
	p.enqueueMu.Lock()
	sessionID := p.closeLocked()
	p.enqueueMu.Unlock()
	if sessionID != "" {
		p.server.Service.detachPeer(p, sessionID)
	}
}

func (p *wsPeer) writeLoop() {
	for item := range p.outbound {
		_ = p.connection.SetWriteDeadline(time.Now().Add(outboundWriteTimeout))
		if err := p.connection.WriteMessage(item.kind, item.data); err != nil {
			p.close()
			return
		}
	}
	// The channel closed after a peer teardown; let the writer flush the
	// already-queued final messages (for example the auth error) before
	// releasing the socket.
	_ = p.connection.Close()
}

func (p *wsPeer) enqueue(item outboundMessage) bool {
	p.enqueueMu.Lock()
	select {
	case <-p.closed:
		p.enqueueMu.Unlock()
		return false
	default:
	}
	select {
	case p.outbound <- item:
		p.enqueueMu.Unlock()
		return true
	default:
		// Queue overflow is a per-client failure: close only this peer. The
		// client reconnects with its Recovery Anchor and Host re-serves the
		// retained tail from the ring.
		sessionID := p.closeLocked()
		p.enqueueMu.Unlock()
		if sessionID != "" {
			p.server.Service.detachPeer(p, sessionID)
		}
		return false
	}
}

// closeLocked must be called with enqueueMu held. It is idempotent so both
// the writer's error path and queue overflow can tear down the same peer
// exactly once.
// closeLocked must be called with enqueueMu held. It returns the attached
// session ID so the caller can unregister after releasing the lock, keeping
// lock ordering between the outbound queue and the service registry acyclic.
func (p *wsPeer) closeLocked() string {
	if p.closeFlag {
		if p.attached != nil {
			return p.attached.ID
		}
		return ""
	}
	p.closeFlag = true
	if p.rosterCancel != nil {
		p.rosterCancel()
		p.rosterCancel = nil
	}
	sessionID := ""
	if p.attached != nil {
		sessionID = p.attached.ID
	}
	close(p.closed)
	close(p.outbound)
	return sessionID
}

func (p *wsPeer) writeJSON(value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return p.writeText(data)
}

func (p *wsPeer) writeText(data []byte) error {
	if !p.enqueue(outboundMessage{kind: websocket.TextMessage, data: data}) {
		return errors.New("outbound queue overflow")
	}
	return nil
}

func (p *wsPeer) writeBinary(data []byte) error {
	if !p.enqueue(outboundMessage{kind: websocket.BinaryMessage, data: data}) {
		return errors.New("outbound queue overflow")
	}
	return nil
}

func (p *wsPeer) enqueueBinary(data []byte) bool {
	return p.enqueue(outboundMessage{kind: websocket.BinaryMessage, data: data})
}

func (p *wsPeer) enqueueAttached(sessionID string, epoch, sequence uint64, reanchor bool) error {
	return p.writeJSON(map[string]any{
		"t": "attached", "session": sessionID,
		"epoch": epoch, "sequence": sequence,
		"reanchor": reanchor,
	})
}

func (p *wsPeer) enqueueSynced(sessionID string, epoch, sequence uint64) error {
	return p.writeJSON(map[string]any{
		"t": "synced", "session": sessionID, "epoch": epoch, "sequence": sequence,
	})
}

func (p *wsPeer) enqueueExited(sessionID string) error {
	return p.writeJSON(map[string]any{"t": "exited", "session": sessionID})
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
			data, _ := json.Marshal(makeRoster(state))
			if !bytes.Equal(data, last) {
				last = append(last[:0], data...)
				if !p.enqueue(outboundMessage{kind: websocket.TextMessage, data: data}) {
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

func makeRoster(state api.State) rosterMessage {
	return rosterMessage{Type: "roster", State: state}
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
		columns, rows, specified, err := attachSizeFromParams(params)
		if err != nil {
			return err
		}
		focused, focusSpecified, err := optionalBoolParam(params, "focused")
		if err != nil {
			return err
		}
		p.attach(session)
		lock, resume, err := p.server.Service.prepareAttach(ctx, session)
		if err != nil {
			p.detach()
			return err
		}
		// Register before claiming focus so a disconnect cannot leave a stale
		// focus owner behind while the initial snapshot is being prepared.
		p.server.Service.registerPeer(session.ID, p)
		// Older clients did not send a focus flag. Let the first such attach
		// claim the empty focus slot for compatibility, while every updated
		// client explicitly sends focused=false until its terminal is focused.
		if !focusSpecified {
			focused = !p.server.Service.hasFocusedPeer(session.ID)
		}
		if focused || focusSpecified {
			_, err := p.server.Service.focusPeerLocked(ctx, p, session, focused, columns, rows, specified && focused)
			if err != nil {
				lock.Unlock()
				resume()
				p.detach()
				return err
			}
		}
		if err := p.writeResult(command.ID, session); err != nil {
			lock.Unlock()
			resume()
			p.detach()
			return err
		}
		anchor := anchorFromParams(params)
		if err := p.server.Service.attachOutputLocked(ctx, p, session, anchor); err != nil {
			lock.Unlock()
			resume()
			p.detach()
			return err
		}
		lock.Unlock()
		resume()
		return nil
	case "session.detach":
		p.detach()
		return p.writeResult(command.ID, map[string]bool{"detached": true})
	case "session.focus":
		if p.attached == nil {
			return fmt.Errorf("no attached session")
		}
		focused, specified, err := optionalBoolParam(params, "focused")
		if err != nil {
			return err
		}
		if !specified {
			focused = true
		}
		columns, rows, resizeSpecified, err := attachSizeFromParams(params)
		if err != nil {
			return err
		}
		isFocused, resized, err := p.server.Service.focusPeer(
			ctx,
			p,
			*p.attached,
			focused,
			columns,
			rows,
			resizeSpecified && focused,
		)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{
			"focused": isFocused,
			"resized": resized,
		})
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
		resized, err := p.server.Service.resizeFocused(ctx, p, *p.attached, columns, rows)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"resized": resized})
	default:
		return fmt.Errorf("unknown method: %s", command.Method)
	}
}

func (p *wsPeer) requireControl() error {
	if p.attached == nil {
		return fmt.Errorf("no attached session")
	}
	if p.controlSession != p.attached.ID {
		return fmt.Errorf("control lease required")
	}
	return nil
}

func (p *wsPeer) input(ctx context.Context, data []byte) error {
	if err := p.requireControl(); err != nil {
		return err
	}
	payload := data
	if len(data) >= len(output.BinaryMagic) && bytes.Equal(data[:len(output.BinaryMagic)], output.BinaryMagic) {
		metadata, decoded, err := output.DecodeInput(data)
		if err != nil {
			return err
		}
		if metadata.SessionID != "" && metadata.SessionID != p.attached.ID {
			return fmt.Errorf("input session mismatch")
		}
		payload = decoded
	}
	if err := p.server.Service.Runtime.Input(ctx, p.attached.Runtime, payload); err != nil {
		return err
	}
	p.server.Service.PingOutput(p.attached.ID)
	return nil
}

// attach only changes the peer's local projection and takes the Control
// Lease for the session. It never touches the tmux session lifetime; detach
// later only unsubscribes output.
func (p *wsPeer) attach(session api.Session) {
	p.detach()
	p.attached = &session
	p.controlSession = session.ID
}

func (p *wsPeer) detach() {
	if p.attached != nil {
		p.server.Service.detachPeer(p, p.attached.ID)
	}
	p.attached = nil
	p.controlSession = ""
}

func stringParam(values map[string]any, key string) string {
	value, _ := values[key].(string)
	return strings.TrimSpace(value)
}
func boolParam(values map[string]any, key string) bool { value, _ := values[key].(bool); return value }

func optionalBoolParam(values map[string]any, key string) (value, specified bool, err error) {
	raw, specified := values[key]
	if !specified {
		return false, false, nil
	}
	switch value := raw.(type) {
	case bool:
		return value, true, nil
	case string:
		parsed, parseErr := strconv.ParseBool(strings.TrimSpace(value))
		if parseErr != nil {
			return false, true, fmt.Errorf("invalid boolean parameter %q", key)
		}
		return parsed, true, nil
	default:
		return false, true, fmt.Errorf("invalid boolean parameter %q", key)
	}
}

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

func anchorFromParams(values map[string]any) *output.Anchor {
	epoch, hasEpoch := values["epoch"].(float64)
	sequence, hasSequence := values["sequence"].(float64)
	if !hasEpoch || !hasSequence {
		return nil
	}
	return &output.Anchor{Epoch: uint64(epoch), Sequence: uint64(sequence)}
}

func attachSizeFromParams(values map[string]any) (columns, rows int, specified bool, err error) {
	_, hasColumns := values["cols"]
	_, hasRows := values["rows"]
	if !hasColumns && !hasRows {
		return 0, 0, false, nil
	}
	columns = intParam(values, "cols")
	rows = intParam(values, "rows")
	if columns <= 0 || rows <= 0 {
		return 0, 0, false, fmt.Errorf("invalid terminal size")
	}
	return columns, rows, true, nil
}
