package controlplane

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"time"

	relayassets "github.com/abcdlsj/den"
	"github.com/gorilla/websocket"
)

type Config struct {
	PublicURL     string
	AdminToken    string
	SigningKey    []byte
	DataURL       string
	PairingTTL    time.Duration
	AccessTTL     time.Duration
	AllowedOrigin string
	Logger        *slog.Logger
}

type Server struct {
	config   Config
	registry *registry
	signer   *tokenSigner
	web      fs.FS
	upgrader websocket.Upgrader
	mux      *http.ServeMux
}

func NewServer(config Config) (*Server, error) {
	if config.AdminToken == "" {
		return nil, errors.New("admin bootstrap token is required")
	}
	if config.PairingTTL == 0 {
		config.PairingTTL = 10 * time.Minute
	}
	if config.AccessTTL == 0 {
		config.AccessTTL = 30 * 24 * time.Hour
	}
	if config.Logger == nil {
		config.Logger = slog.Default()
	}
	signer, err := newTokenSigner(config.SigningKey)
	if err != nil {
		return nil, err
	}
	web, err := fs.Sub(relayassets.Web, "Packages/WebRelay/Sources/WebRelay/Resources")
	if err != nil {
		return nil, err
	}
	registry, err := newRegistry(config.DataURL)
	if err != nil {
		return nil, err
	}
	server := &Server{
		config:   config,
		registry: registry,
		signer:   signer,
		web:      web,
		upgrader: websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }},
		mux:      http.NewServeMux(),
	}
	server.routes()
	return server, nil
}

func (server *Server) ServeHTTP(response http.ResponseWriter, request *http.Request) {
	response.Header().Set("X-Content-Type-Options", "nosniff")
	response.Header().Set("Referrer-Policy", "no-referrer")
	server.mux.ServeHTTP(response, request)
}

func (server *Server) routes() {
	server.mux.HandleFunc("GET /healthz", server.health)
	server.mux.HandleFunc("POST /v1/hosts", server.provisionHost)
	server.mux.HandleFunc("GET /v1/host/connect", server.connectHost)
	server.mux.HandleFunc("POST /v1/hosts/{hostID}/pairing", server.beginPairing)
	server.mux.HandleFunc("DELETE /v1/hosts/{hostID}", server.revokeHost)
	server.mux.HandleFunc("GET /v1/hosts/{hostID}", server.getHost)
	server.mux.HandleFunc("POST /v1/pair", server.pair)
	server.mux.HandleFunc("GET /v1/client/connect", server.connectClient)
	server.mux.HandleFunc("GET /h/{hostID}/", server.webPage)
	server.mux.HandleFunc("GET /h/{hostID}/manifest.webmanifest", server.hostManifest)
	server.mux.HandleFunc("GET /h/{hostID}/service-worker.js", server.hostServiceWorker)
	server.mux.HandleFunc("GET /h/{hostID}/icon.svg", server.webResource("icon.svg", "image/svg+xml"))
	server.mux.HandleFunc("GET /manifest.webmanifest", server.webResource("manifest.webmanifest", "application/manifest+json"))
	server.mux.HandleFunc("GET /service-worker.js", server.webResource("service-worker.js", "text/javascript; charset=utf-8"))
	server.mux.HandleFunc("GET /icon.svg", server.webResource("icon.svg", "image/svg+xml"))
}

func (server *Server) health(response http.ResponseWriter, _ *http.Request) {
	writeJSON(response, http.StatusOK, map[string]any{"ok": true})
}

func (server *Server) connectHost(response http.ResponseWriter, request *http.Request) {
	hostID := strings.TrimSpace(request.URL.Query().Get("host_id"))
	if !validHostID(hostID) {
		http.Error(response, "invalid host_id", http.StatusBadRequest)
		return
	}
	credential := bearerToken(request)
	if !server.registry.authenticateHost(hostID, credential) {
		http.Error(response, "unauthorized", http.StatusUnauthorized)
		return
	}
	connection, err := server.upgrader.Upgrade(response, request, nil)
	if err != nil {
		return
	}
	tunnel := newHostTunnel(connection)
	if !server.registry.connectHost(hostID, strings.TrimSpace(request.URL.Query().Get("name")), credential, tunnel) {
		tunnel.close()
		return
	}
	server.config.Logger.Info("host connected", "host_id", hostID)
	defer func() {
		server.registry.disconnectHost(hostID, tunnel)
		server.config.Logger.Info("host disconnected", "host_id", hostID)
	}()
	_ = tunnel.readLoop(func() { server.registry.touchHost(hostID, tunnel) })
}

func (server *Server) provisionHost(response http.ResponseWriter, request *http.Request) {
	if !secureEqual(bearerToken(request), server.config.AdminToken) {
		http.Error(response, "unauthorized", http.StatusUnauthorized)
		return
	}
	var body struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}
	if json.NewDecoder(http.MaxBytesReader(response, request.Body, 16*1024)).Decode(&body) != nil || !validHostID(strings.TrimSpace(body.ID)) {
		http.Error(response, "invalid request", http.StatusBadRequest)
		return
	}
	credential, err := server.registry.provisionHost(strings.TrimSpace(body.ID), strings.TrimSpace(body.Name))
	if err != nil {
		http.Error(response, "provision failed", http.StatusInternalServerError)
		return
	}
	writeJSON(response, http.StatusCreated, map[string]any{"host_id": body.ID, "host_credential": credential})
}

func (server *Server) revokeHost(response http.ResponseWriter, request *http.Request) {
	if !secureEqual(bearerToken(request), server.config.AdminToken) {
		http.Error(response, "unauthorized", http.StatusUnauthorized)
		return
	}
	if err := server.registry.revokeHost(request.PathValue("hostID")); err != nil {
		if errors.Is(err, errHostNotFound) {
			http.Error(response, "not found", http.StatusNotFound)
		} else {
			http.Error(response, "revoke failed", http.StatusInternalServerError)
		}
		return
	}
	response.WriteHeader(http.StatusNoContent)
}

func (server *Server) beginPairing(response http.ResponseWriter, request *http.Request) {
	hostID := request.PathValue("hostID")
	credential := bearerToken(request)
	if !secureEqual(credential, server.config.AdminToken) && !server.registry.authenticateHost(hostID, credential) {
		http.Error(response, "unauthorized", http.StatusUnauthorized)
		return
	}
	code, err := server.registry.beginPairing(hostID, server.config.PairingTTL)
	if err != nil {
		http.Error(response, err.Error(), http.StatusConflict)
		return
	}
	writeJSON(response, http.StatusCreated, map[string]any{
		"host_id":      hostID,
		"pairing_code": code,
		"expires_in":   int(server.config.PairingTTL.Seconds()),
	})
}

func (server *Server) pair(response http.ResponseWriter, request *http.Request) {
	var body struct {
		HostID string `json:"host_id"`
		Code   string `json:"pairing_code"`
	}
	if json.NewDecoder(http.MaxBytesReader(response, request.Body, 16*1024)).Decode(&body) != nil {
		http.Error(response, "invalid request", http.StatusBadRequest)
		return
	}
	generation, err := server.registry.consumePairing(body.HostID, body.Code)
	if err != nil {
		http.Error(response, err.Error(), http.StatusUnauthorized)
		return
	}
	token, err := server.signer.issue(body.HostID, "control", generation, server.config.AccessTTL)
	if err != nil {
		http.Error(response, "token issue failed", http.StatusInternalServerError)
		return
	}
	base := strings.TrimSuffix(server.config.PublicURL, "/")
	writeJSON(response, http.StatusCreated, map[string]any{
		"host_id":      body.HostID,
		"access_token": token,
		"web_url":      fmt.Sprintf("%s/h/%s/#t=%s", base, url.PathEscape(body.HostID), url.QueryEscape(token)),
		"expires_in":   int(server.config.AccessTTL.Seconds()),
	})
}

func (server *Server) getHost(response http.ResponseWriter, request *http.Request) {
	hostID := request.PathValue("hostID")
	credential := bearerToken(request)
	if !secureEqual(credential, server.config.AdminToken) &&
		!server.registry.authenticateHost(hostID, credential) &&
		!server.authorizeAccess(credential, hostID) {
		http.Error(response, "unauthorized", http.StatusUnauthorized)
		return
	}
	host, ok := server.registry.host(hostID)
	if !ok {
		http.Error(response, "not found", http.StatusNotFound)
		return
	}
	writeJSON(response, http.StatusOK, host)
}

func (server *Server) connectClient(response http.ResponseWriter, request *http.Request) {
	if server.config.AllowedOrigin != "" && request.Header.Get("Origin") != server.config.AllowedOrigin {
		http.Error(response, "origin not allowed", http.StatusForbidden)
		return
	}
	hostID := request.URL.Query().Get("host_id")
	client, err := server.upgrader.Upgrade(response, request, nil)
	if err != nil {
		return
	}
	defer client.Close()
	client.SetReadLimit(maxRelayMessageBytes)
	_ = client.SetReadDeadline(time.Now().Add(10 * time.Second))
	messageType, authPayload, err := client.ReadMessage()
	var auth struct {
		Type  string `json:"t"`
		Token string `json:"token"`
	}
	if err != nil || messageType != websocket.TextMessage || json.Unmarshal(authPayload, &auth) != nil || auth.Type != "auth" {
		_ = client.WriteJSON(map[string]string{"t": "error", "message": "unauthorized"})
		return
	}
	claims, err := server.verifyAccess(auth.Token, hostID)
	if err != nil {
		_ = client.WriteJSON(map[string]string{"t": "error", "message": "unauthorized"})
		return
	}
	tunnel := server.registry.authorizedTunnel(hostID, claims.Generation)
	if tunnel == nil {
		_ = client.WriteJSON(map[string]string{"t": "error", "message": "host offline"})
		return
	}
	_ = client.SetReadDeadline(time.Now().Add(75 * time.Second))
	client.SetPongHandler(func(string) error {
		return client.SetReadDeadline(time.Now().Add(75 * time.Second))
	})
	connectionID, route, err := tunnel.openClient()
	if err != nil {
		return
	}
	if err := tunnel.send(relayFrame{Kind: frameText, ConnectionID: connectionID, Payload: authPayload}); err != nil {
		tunnel.removeClient(connectionID)
		return
	}
	defer func() {
		tunnel.removeClient(connectionID)
		_ = tunnel.send(relayFrame{Kind: frameClose, ConnectionID: connectionID})
	}()
	clientFrames := make(chan relayFrame, 64)
	clientErrors := make(chan error, 1)
	clientDone := make(chan struct{})
	defer close(clientDone)
	go func() {
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-clientDone:
				return
			case <-ticker.C:
				if client.WriteControl(websocket.PingMessage, nil, time.Now().Add(10*time.Second)) != nil {
					return
				}
			}
		}
	}()
	go func() {
		for {
			messageType, data, err := client.ReadMessage()
			if err != nil {
				clientErrors <- err
				return
			}
			kind := frameText
			if messageType == websocket.BinaryMessage {
				kind = frameBinary
			} else if messageType != websocket.TextMessage {
				continue
			}
			select {
			case clientFrames <- relayFrame{Kind: byte(kind), ConnectionID: connectionID, Payload: data}:
			case <-clientDone:
				return
			}
		}
	}()
	for {
		select {
		case frame := <-route.frames:
			if frame.Kind == frameClose {
				return
			}
			messageType := websocket.TextMessage
			if frame.Kind == frameBinary {
				messageType = websocket.BinaryMessage
			}
			_ = client.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if client.WriteMessage(messageType, frame.Payload) != nil {
				return
			}
		case <-route.done:
			return
		case frame := <-clientFrames:
			if tunnel.send(frame) != nil {
				return
			}
		case <-clientErrors:
			return
		}
	}
}

func (server *Server) authorizeAccess(token, hostID string) bool {
	claims, err := server.verifyAccess(token, hostID)
	if err != nil {
		return false
	}
	generation, ok := server.registry.generation(hostID)
	return ok && claims.Generation == generation
}

func (server *Server) verifyAccess(token, hostID string) (tokenClaims, error) {
	return server.signer.verify(token, hostID, "control")
}

func (server *Server) webPage(response http.ResponseWriter, request *http.Request) {
	data, err := fs.ReadFile(server.web, "web.html")
	if err != nil {
		http.Error(response, "web unavailable", http.StatusInternalServerError)
		return
	}
	host := request.PathValue("hostID")
	hostID, _ := json.Marshal(host)
	page := strings.Replace(string(data), "\"__BURROW_RELAY_HOST_ID__\"", string(hostID), 1)
	page = strings.ReplaceAll(page, "href=\"/manifest.webmanifest\"", fmt.Sprintf("href=\"/h/%s/manifest.webmanifest\"", url.PathEscape(host)))
	page = strings.ReplaceAll(page, "href=\"/icon.svg\"", fmt.Sprintf("href=\"/h/%s/icon.svg\"", url.PathEscape(host)))
	response.Header().Set("Cache-Control", "no-store")
	response.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = response.Write([]byte(page))
}

func (server *Server) hostManifest(response http.ResponseWriter, request *http.Request) {
	data, err := fs.ReadFile(server.web, "manifest.webmanifest")
	if err != nil {
		http.NotFound(response, request)
		return
	}
	host := url.PathEscape(request.PathValue("hostID"))
	var manifest map[string]any
	if json.Unmarshal(data, &manifest) != nil {
		http.Error(response, "invalid manifest", http.StatusInternalServerError)
		return
	}
	manifest["start_url"] = "/h/" + host + "/"
	manifest["scope"] = "/h/" + host + "/"
	manifest["icons"] = []map[string]any{{"src": "/h/" + host + "/icon.svg", "sizes": "any", "type": "image/svg+xml", "purpose": "any maskable"}}
	writeJSON(response, http.StatusOK, manifest)
}

func (server *Server) hostServiceWorker(response http.ResponseWriter, request *http.Request) {
	host := url.PathEscape(request.PathValue("hostID"))
	script := fmt.Sprintf(`const CACHE="burrow-relay-%s-v1";
const SHELL=["/h/%s/","/h/%s/manifest.webmanifest","/h/%s/icon.svg"];
self.addEventListener("install",e=>{e.waitUntil(caches.open(CACHE).then(c=>c.addAll(SHELL)));self.skipWaiting()});
self.addEventListener("activate",e=>{e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x.startsWith("burrow-relay-")&&x!==CACHE).map(x=>caches.delete(x)))));self.clients.claim()});
self.addEventListener("fetch",e=>{if(e.request.method!=="GET"||new URL(e.request.url).pathname==="/v1/client/connect")return;e.respondWith(fetch(e.request).catch(()=>caches.match(e.request)))})`, host, host, host, host)
	response.Header().Set("Content-Type", "text/javascript; charset=utf-8")
	response.Header().Set("Service-Worker-Allowed", "/h/"+host+"/")
	response.Header().Set("Cache-Control", "no-cache")
	_, _ = response.Write([]byte(script))
}

func (server *Server) webResource(name, contentType string) http.HandlerFunc {
	return func(response http.ResponseWriter, _ *http.Request) {
		data, err := fs.ReadFile(server.web, name)
		if err != nil {
			http.NotFound(response, nil)
			return
		}
		response.Header().Set("Content-Type", contentType)
		response.Header().Set("Cache-Control", "public, max-age=300")
		_, _ = response.Write(data)
	}
}

func bearerToken(request *http.Request) string {
	return strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")
}

func secureEqual(left, right string) bool {
	return len(left) == len(right) && subtle.ConstantTimeCompare([]byte(left), []byte(right)) == 1
}

func writeJSON(response http.ResponseWriter, status int, value any) {
	response.Header().Set("Content-Type", "application/json")
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(value)
}
