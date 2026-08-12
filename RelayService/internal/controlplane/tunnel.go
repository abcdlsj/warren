package controlplane

import (
	"errors"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const maxRelayMessageBytes = 8 * 1024 * 1024

type hostTunnel struct {
	connection *websocket.Conn
	writes     sync.Mutex
	clientsMu  sync.RWMutex
	clients    map[connectionID]*clientRoute
	closed     chan struct{}
	closeOnce  sync.Once
}

type clientRoute struct {
	frames chan relayFrame
	done   chan struct{}
	once   sync.Once
}

func newClientRoute() *clientRoute {
	return &clientRoute{frames: make(chan relayFrame, 64), done: make(chan struct{})}
}

func (route *clientRoute) close() { route.once.Do(func() { close(route.done) }) }

func newHostTunnel(connection *websocket.Conn) *hostTunnel {
	connection.SetReadLimit(maxRelayMessageBytes + headerSize)
	return &hostTunnel{
		connection: connection,
		clients:    make(map[connectionID]*clientRoute),
		closed:     make(chan struct{}),
	}
}

func (tunnel *hostTunnel) openClient() (connectionID, *clientRoute, error) {
	id, err := newConnectionID()
	if err != nil {
		return connectionID{}, nil, err
	}
	route := newClientRoute()
	tunnel.clientsMu.Lock()
	select {
	case <-tunnel.closed:
		tunnel.clientsMu.Unlock()
		return connectionID{}, nil, errors.New("host tunnel closed")
	default:
		tunnel.clients[id] = route
	}
	tunnel.clientsMu.Unlock()
	if err := tunnel.send(relayFrame{Kind: frameOpen, ConnectionID: id}); err != nil {
		tunnel.removeClient(id)
		return connectionID{}, nil, err
	}
	return id, route, nil
}

func (tunnel *hostTunnel) send(frame relayFrame) error {
	select {
	case <-tunnel.closed:
		return errors.New("host tunnel closed")
	default:
	}
	tunnel.writes.Lock()
	defer tunnel.writes.Unlock()
	_ = tunnel.connection.SetWriteDeadline(time.Now().Add(10 * time.Second))
	return tunnel.connection.WriteMessage(websocket.BinaryMessage, encodeRelayFrame(frame))
}

func (tunnel *hostTunnel) readLoop(touch func()) error {
	defer tunnel.close()
	_ = tunnel.connection.SetReadDeadline(time.Now().Add(75 * time.Second))
	tunnel.connection.SetPongHandler(func(string) error {
		touch()
		return tunnel.connection.SetReadDeadline(time.Now().Add(75 * time.Second))
	})
	go tunnel.heartbeat()
	for {
		messageType, data, err := tunnel.connection.ReadMessage()
		if err != nil {
			return err
		}
		if messageType != websocket.BinaryMessage || len(data) > maxRelayMessageBytes+headerSize {
			return errors.New("invalid host relay message")
		}
		frame, err := decodeRelayFrame(data)
		if err != nil {
			return err
		}
		touch()
		tunnel.clientsMu.RLock()
		route := tunnel.clients[frame.ConnectionID]
		tunnel.clientsMu.RUnlock()
		if route == nil {
			continue
		}
		select {
		case route.frames <- frame:
		case <-route.done:
		default:
			tunnel.removeClient(frame.ConnectionID)
			_ = tunnel.send(relayFrame{Kind: frameClose, ConnectionID: frame.ConnectionID})
		}
	}
}

func (tunnel *hostTunnel) heartbeat() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-tunnel.closed:
			return
		case <-ticker.C:
			tunnel.writes.Lock()
			err := tunnel.connection.WriteControl(
				websocket.PingMessage,
				nil,
				time.Now().Add(10*time.Second),
			)
			tunnel.writes.Unlock()
			if err != nil {
				tunnel.close()
				return
			}
		}
	}
}

func (tunnel *hostTunnel) removeClient(id connectionID) {
	tunnel.clientsMu.Lock()
	route := tunnel.clients[id]
	delete(tunnel.clients, id)
	tunnel.clientsMu.Unlock()
	if route != nil {
		route.close()
	}
}

func (tunnel *hostTunnel) close() {
	tunnel.closeOnce.Do(func() {
		close(tunnel.closed)
		_ = tunnel.connection.Close()
		tunnel.clientsMu.Lock()
		clients := tunnel.clients
		tunnel.clients = make(map[connectionID]*clientRoute)
		tunnel.clientsMu.Unlock()
		for _, route := range clients {
			route.close()
		}
	})
}
