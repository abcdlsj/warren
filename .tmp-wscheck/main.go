package main

import (
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/gorilla/websocket"
)

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: wscheck TOKEN SESSION_ID [SECONDS]")
		os.Exit(2)
	}
	token, sessionID := os.Args[1], os.Args[2]
	seconds := 8
	if len(os.Args) > 3 {
		fmt.Sscan(os.Args[3], &seconds)
	}
	conn, _, err := websocket.DefaultDialer.Dial("ws://127.0.0.1:8891/v1/ws", nil)
	if err != nil {
		panic(err)
	}
	defer conn.Close()
	_ = conn.WriteJSON(map[string]any{"t": "auth", "token": token})
	conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	var welcome map[string]any
	if err := conn.ReadJSON(&welcome); err != nil {
		panic(err)
	}
	fmt.Println("welcome:", welcome["t"])
	_ = conn.WriteJSON(map[string]any{
		"t": "request", "id": "1", "method": "session.attach",
		"params": map[string]any{"id": sessionID},
	})
	deadline := time.Now().Add(time.Duration(seconds) * time.Second)
	for time.Now().Before(deadline) {
		_ = conn.SetReadDeadline(deadline)
		messageType, data, err := conn.ReadMessage()
		if err != nil {
			fmt.Println("read error:", err)
			return
		}
		if messageType != websocket.TextMessage {
			fmt.Printf("binary frame %d bytes (ignored)\n", len(data))
			continue
		}
		var message map[string]any
		if err := json.Unmarshal(data, &message); err != nil {
			fmt.Println("decode error:", err)
			continue
		}
		kind, _ := message["t"].(string)
		summary := ""
		if kind == "agent" {
			events, _ := message["events"].([]any)
			summary = fmt.Sprintf(" events=%d", len(events))
		}
		fmt.Printf("%s %s%s\n", kind, message["session"], summary)
		if kind == "response" && message["id"] == "1" {
			if ok, _ := message["ok"].(bool); !ok {
				fmt.Println("attach failed:", message["error"])
				return
			}
		}
	}
}
