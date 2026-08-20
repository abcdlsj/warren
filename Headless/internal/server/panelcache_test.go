package server

import (
	"context"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func TestPanelCacheServesFreshEntries(t *testing.T) {
	cache := newPanelCache(2, time.Minute)
	cache.Set("a", api.GitPanel{WorkspaceID: "a"})
	if _, ok := cache.Get("a"); !ok {
		t.Fatal("expected cache hit for fresh entry")
	}
	if _, ok := cache.Get("b"); ok {
		t.Fatal("expected cache miss for unknown entry")
	}
}

func TestPanelCacheEvictsLeastRecentlyUsed(t *testing.T) {
	cache := newPanelCache(2, time.Minute)
	cache.Set("a", api.GitPanel{WorkspaceID: "a"})
	cache.Set("b", api.GitPanel{WorkspaceID: "b"})
	if _, ok := cache.Get("a"); !ok {
		t.Fatal("expected a to be cached")
	}
	cache.Set("c", api.GitPanel{WorkspaceID: "c"})
	if _, ok := cache.Get("b"); ok {
		t.Fatal("expected b to be evicted as least recently used")
	}
	if _, ok := cache.Get("a"); !ok {
		t.Fatal("expected a to survive after being touched")
	}
}

func TestPanelCacheExpiresEntries(t *testing.T) {
	cache := newPanelCache(2, 10*time.Millisecond)
	cache.Set("a", api.GitPanel{WorkspaceID: "a"})
	time.Sleep(20 * time.Millisecond)
	if _, ok := cache.Get("a"); ok {
		t.Fatal("expected expired entry to miss")
	}
}

func TestGitPanelServesCachedSnapshot(t *testing.T) {
	repository := newRepositoryForServiceTest(t)
	service, workspaceID := gitPanelService(t, repository)
	ctx := context.Background()

	first, err := service.GitPanel(ctx, workspaceID, false)
	if err != nil {
		t.Fatal(err)
	}
	gitForServiceTest(t, repository, "commit", "--allow-empty", "-m", "second")

	second, err := service.GitPanel(ctx, workspaceID, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(second.Commits) != len(first.Commits) {
		t.Fatalf("second call returned %d commits, want cached %d", len(second.Commits), len(first.Commits))
	}

	service.invalidatePanelCache(workspaceID)
	third, err := service.GitPanel(ctx, workspaceID, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(third.Commits) != len(first.Commits)+1 {
		t.Fatalf("after invalidation got %d commits, want %d", len(third.Commits), len(first.Commits)+1)
	}
}

func TestGitPanelCacheIsLazyPerWorkspace(t *testing.T) {
	repository := newRepositoryForServiceTest(t)
	service, workspaceID := gitPanelService(t, repository)
	otherWorkspaceID := workspaceID + "-other"

	if _, ok := service.panelCacheFor().Get(otherWorkspaceID); ok {
		t.Fatal("expected unrequested workspace to be absent from the cache")
	}
	if _, err := service.GitPanel(context.Background(), workspaceID, false); err != nil {
		t.Fatal(err)
	}
	if _, ok := service.panelCacheFor().Get(otherWorkspaceID); ok {
		t.Fatal("expected unrequested workspace to stay uncached after another request")
	}
}
