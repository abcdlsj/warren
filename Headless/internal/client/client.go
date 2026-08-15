package client

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/output"
	"github.com/abcdlsj/warren/Headless/internal/store"
	"github.com/gorilla/websocket"
)

type Client struct {
	connection *websocket.Conn
	mu         sync.Mutex
}

func Dial(ctx context.Context, endpoint, token string) (*Client, error) {
	endpoint = strings.TrimRight(endpoint, "/")
	endpoint = strings.Replace(endpoint, "http://", "ws://", 1)
	endpoint = strings.Replace(endpoint, "https://", "wss://", 1)
	if !strings.HasSuffix(endpoint, "/v1/ws") {
		endpoint += "/v1/ws"
	}
	if _, err := url.Parse(endpoint); err != nil {
		return nil, err
	}
	connection, response, err := websocket.DefaultDialer.DialContext(ctx, endpoint, http.Header{})
	if err != nil {
		if response != nil {
			return nil, fmt.Errorf("connect %s: HTTP %d", endpoint, response.StatusCode)
		}
		return nil, fmt.Errorf("connect %s: %w", endpoint, err)
	}
	client := &Client{connection: connection}
	if err := connection.WriteJSON(api.Envelope{Type: "auth", Token: token, Version: api.Version}); err != nil {
		connection.Close()
		return nil, err
	}
	_ = connection.SetReadDeadline(time.Now().Add(10 * time.Second))
	var welcome map[string]any
	if err := connection.ReadJSON(&welcome); err != nil {
		connection.Close()
		return nil, err
	}
	_ = connection.SetReadDeadline(time.Time{})
	if welcome["t"] != "welcome" {
		connection.Close()
		return nil, errors.New("authentication failed")
	}
	return client, nil
}

func (c *Client) Close() error { return c.connection.Close() }

func (c *Client) Request(ctx context.Context, method string, params map[string]any, result any) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	id := store.NewID()
	if err := c.connection.WriteJSON(api.Envelope{Type: "request", ID: id, Method: method, Params: params}); err != nil {
		return err
	}
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		messageType, data, err := c.connection.ReadMessage()
		if err != nil {
			return err
		}
		if messageType != websocket.TextMessage {
			continue
		}
		var response api.Response
		if json.Unmarshal(data, &response) == nil && response.Type == "response" && response.ID == id {
			if !response.OK {
				return errors.New(response.Error)
			}
			if result != nil {
				raw, err := json.Marshal(response.Result)
				if err != nil {
					return err
				}
				return json.Unmarshal(raw, result)
			}
			return nil
		}
	}
}

func (c *Client) Roster(ctx context.Context) (api.State, error) {
	var value api.State
	err := c.Request(ctx, "roster", nil, &value)
	return value, err
}

func (c *Client) Attach(ctx context.Context, sessionID string) (api.Session, error) {
	var value api.Session
	err := c.Request(ctx, "session.attach", map[string]any{"id": sessionID}, &value)
	return value, err
}

func (c *Client) Input(ctx context.Context, data []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
		return c.connection.WriteMessage(websocket.BinaryMessage, data)
	}
}

func (c *Client) ReadOutput(ctx context.Context, onOutput func([]byte) bool) error {
	// ReadMessage blocks without a deadline, so a context timeout or
	// interrupt alone cannot wake it. Close the connection when the context
	// finishes; the read then returns and we translate the error back to the
	// context result.
	stopClose := context.AfterFunc(ctx, func() {
		_ = c.connection.Close()
	})
	defer stopClose()
	for {
		typeID, data, err := c.connection.ReadMessage()
		if err != nil {
			if ctxErr := ctx.Err(); ctxErr != nil {
				return ctxErr
			}
			return err
		}
		if typeID == websocket.BinaryMessage {
			payload := data
			if frame, err := output.DecodeOutput(data); err == nil {
				payload = frame.Payload
			}
			if onOutput(payload) {
				return nil
			}
		}
	}
}
