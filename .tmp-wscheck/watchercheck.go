//go:build ignore

package main

import (
	"fmt"
	"os"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
)

func main() {
	watcher := agent.Start("probe", "codex", os.Args[1], func([]api.AgentEvent) {})
	time.Sleep(2 * time.Second)
	events := watcher.Snapshot()
	fmt.Println("events:", len(events))
	for index, event := range events {
		if index >= 5 {
			fmt.Println("...")
			break
		}
		fmt.Printf("%d %s %s %q\n", event.Sequence, event.Type, event.Role, event.Content)
	}
	watcher.Close()
}
