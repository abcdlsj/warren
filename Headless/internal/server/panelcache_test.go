package server

import (
	"context"
	"sync/atomic"
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

func TestPanelCacheSetIfVersionRejectsStaleWrites(t *testing.T) {
	cache := newPanelCache(2, time.Minute)
	cache.Set("a", api.GitPanel{WorkspaceID: "a"})
	version := cache.Version("a")
	cache.Remove("a")
	if cache.SetIfVersion("a", api.GitPanel{WorkspaceID: "a", Branch: "stale"}, version) {
		t.Fatal("expected stale write to be rejected after removal")
	}
	if _, ok := cache.Get("a"); ok {
		t.Fatal("expected removed entry to stay absent")
	}
}

func TestPanelCacheShouldRevalidateCoalesces(t *testing.T) {
	cache := newPanelCache(2, time.Minute)
	cache.Set("a", api.GitPanel{WorkspaceID: "a"})
	if !cache.ShouldRevalidate("a", 0) {
		t.Fatal("expected first check to trigger revalidation")
	}
	if cache.ShouldRevalidate("a", 0) {
		t.Fatal("expected concurrent check to be coalesced while revalidating")
	}
	cache.FinishRevalidate("a")
	if !cache.ShouldRevalidate("a", 0) {
		t.Fatal("expected revalidation to be allowed again after finishing")
	}
}

func TestPanelLoadMergesConcurrentLoads(t *testing.T) {
	loads := newPanelLoad()
	var calls atomic.Int32
	start := make(chan struct{})
	const workers = 8
	results := make(chan string, workers)
	for i := 0; i < workers; i++ {
		go func() {
			<-start
			panel, err := loads.Do("a", func() (api.GitPanel, error) {
				calls.Add(1)
				time.Sleep(50 * time.Millisecond)
				return api.GitPanel{WorkspaceID: "a", Branch: "main"}, nil
			})
			if err != nil {
				results <- "error"
				return
			}
			results <- panel.Branch
		}()
	}
	close(start)
	for i := 0; i < workers; i++ {
		if branch := <-results; branch != "main" {
			t.Fatalf("worker got branch %q, want main", branch)
		}
	}
	if calls.Load() != 1 {
		t.Fatalf("load executed %d times, want 1", calls.Load())
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
