package client

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestReadOutputHonorsContextDeadline(t *testing.T) {
	release := make(chan struct{})
	upgrader := websocket.Upgrader{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		connection, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer connection.Close()
		var envelope map[string]any
		if err := connection.ReadJSON(&envelope); err != nil {
			return
		}
		if err := connection.WriteJSON(map[string]any{"t": "welcome"}); err != nil {
			return
		}
		// Hold the connection open without sending terminal output.
		select {
		case <-release:
		case <-time.After(10 * time.Second):
		}
	}))
	defer server.Close()
	defer close(release)

	dialContext, cancelDial := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancelDial()
	value, err := Dial(dialContext, server.URL, "secret")
	if err != nil {
		t.Fatal(err)
	}
	defer value.Close()

	readContext, cancelRead := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancelRead()
	started := time.Now()
	err = value.ReadOutput(readContext, func([]byte) bool { return false })
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("ReadOutput error = %v, want context.DeadlineExceeded", err)
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("ReadOutput took %s, want it to return shortly after the deadline", elapsed)
	}
}
