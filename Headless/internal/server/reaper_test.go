package server

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

type reaperRuntime struct {
	memoryRuntime
	created map[string]time.Time
	killed  []string
}

func (runtime *reaperRuntime) ListCreated(context.Context) (map[string]time.Time, error) {
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	result := make(map[string]time.Time, len(runtime.created))
	for name, createdAt := range runtime.created {
		result[name] = createdAt
	}
	return result, nil
}

func (runtime *reaperRuntime) Kill(_ context.Context, name string) error {
	runtime.mu.Lock()
	runtime.killed = append(runtime.killed, name)
	runtime.mu.Unlock()
	return runtime.memoryRuntime.Kill(context.Background(), name)
}

func TestReapOrphansReclaimsUnmanagedWarrenSessions(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	endedAt := now.Add(-time.Minute)
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{
			{ID: "managed", Runtime: "warren_managed", Lifecycle: "running"},
			{ID: "ended", Runtime: "warren_ended", Lifecycle: "ended", EndedAt: &endedAt},
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	runtime := &reaperRuntime{
		memoryRuntime: memoryRuntime{sessions: map[string][]byte{
			"warren_managed":    []byte("ok"),
			"warren_ended":      []byte("ok"),
			"warren_orphan_old": []byte("ok"),
			"warren_orphan_new": []byte("ok"),
			"warren-legacy-old": []byte("ok"),
			"probe2_old":        []byte("ok"),
		}},
		created: map[string]time.Time{
			"warren_managed":    now,
			"warren_ended":      endedAt,
			"warren_orphan_old": endedAt,
			"warren_orphan_new": now.Add(-5 * time.Second),
			"warren-legacy-old": endedAt,
			"probe2_old":        endedAt,
		},
	}
	service := &Service{Store: state, Runtime: runtime}

	service.reapOrphans(context.Background())

	runtime.mu.Lock()
	killed := append([]string(nil), runtime.killed...)
	runtime.mu.Unlock()
	want := map[string]bool{
		"warren_ended":      true,
		"warren_orphan_old": true,
		"warren-legacy-old": true,
	}
	if len(killed) != len(want) {
		t.Fatalf("killed %v, want %v", killed, want)
	}
	for _, name := range killed {
		if !want[name] {
			t.Fatalf("unexpected kill: %s", name)
		}
	}
}
