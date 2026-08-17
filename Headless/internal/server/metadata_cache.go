package server

import (
	"sync"

	"github.com/abcdlsj/warren/Headless/internal/runtime"
)

// metadataCache holds the latest foreground metadata per session. It is
// written by the background refresher and read by roster snapshots, so a slow
// probe can never block a broadcast.
type metadataCache struct {
	mu     sync.RWMutex
	values map[string]runtime.RuntimeMetadata
}

func (c *metadataCache) get(sessionID string) (runtime.RuntimeMetadata, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	value, ok := c.values[sessionID]
	return value, ok
}

func (c *metadataCache) set(sessionID string, value runtime.RuntimeMetadata) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.values == nil {
		c.values = make(map[string]runtime.RuntimeMetadata)
	}
	c.values[sessionID] = value
}

func (c *metadataCache) remove(sessionID string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.values, sessionID)
}

func (c *metadataCache) prune(running map[string]bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for sessionID := range c.values {
		if !running[sessionID] {
			delete(c.values, sessionID)
		}
	}
}
