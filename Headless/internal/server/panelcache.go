package server

import (
	"container/list"
	"sync"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

const (
	panelCacheCapacity = 16
	panelCacheTTL      = 5 * time.Minute
)

type panelCacheEntry struct {
	key       string
	panel     api.GitPanel
	expiresAt time.Time
}

// panelCache is a small LRU cache of git panel snapshots keyed by workspace
// ID. Entries expire after panelCacheTTL so the panel refreshes in place
// instead of serving stale data forever. Only workspaces that were actually
// requested are ever cached; nothing is loaded eagerly.
type panelCache struct {
	mu    sync.Mutex
	ttl   time.Duration
	cap   int
	list  *list.List
	index map[string]*list.Element
}

func newPanelCache(capacity int, ttl time.Duration) *panelCache {
	return &panelCache{
		ttl:   ttl,
		cap:   capacity,
		list:  list.New(),
		index: make(map[string]*list.Element),
	}
}

func (c *panelCache) Get(key string) (api.GitPanel, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	element, ok := c.index[key]
	if !ok {
		return api.GitPanel{}, false
	}
	entry := element.Value.(*panelCacheEntry)
	if time.Now().After(entry.expiresAt) {
		c.remove(element)
		return api.GitPanel{}, false
	}
	c.list.MoveToFront(element)
	return entry.panel, true
}

func (c *panelCache) Set(key string, panel api.GitPanel) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if element, ok := c.index[key]; ok {
		entry := element.Value.(*panelCacheEntry)
		entry.panel = panel
		entry.expiresAt = time.Now().Add(c.ttl)
		c.list.MoveToFront(element)
		return
	}
	entry := &panelCacheEntry{key: key, panel: panel, expiresAt: time.Now().Add(c.ttl)}
	element := c.list.PushFront(entry)
	c.index[key] = element
	if c.list.Len() > c.cap {
		c.remove(c.list.Back())
	}
}

func (c *panelCache) Remove(key string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if element, ok := c.index[key]; ok {
		c.remove(element)
	}
}

func (c *panelCache) remove(element *list.Element) {
	delete(c.index, element.Value.(*panelCacheEntry).key)
	c.list.Remove(element)
}
