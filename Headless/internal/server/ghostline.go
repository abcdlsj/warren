package server

import (
	"context"
	"fmt"
	"sync"

	"github.com/abcdlsj/ghostline"
)

// GhostlineRuntime adapts ghostline's session-handle API to the name-based
// Runtime surface used by Service. Handles are cached by name and re-adopted
// from the server on demand, so a daemon restart keeps managing sessions
// owned by a detached ghostline serve process.
type GhostlineRuntime struct {
	client   *ghostline.Client
	mu       sync.Mutex
	sessions map[string]ghostline.Session
}

func NewGhostlineRuntime(client *ghostline.Client) *GhostlineRuntime {
	return &GhostlineRuntime{client: client, sessions: map[string]ghostline.Session{}}
}

func (r *GhostlineRuntime) Check(ctx context.Context) error {
	return r.client.Check(ctx)
}

func (r *GhostlineRuntime) Create(ctx context.Context, name, directory, command string) error {
	session, err := r.client.Start(ctx, ghostline.SessionOptions{
		Name:      name,
		Directory: directory,
		Command:   command,
	})
	if err != nil {
		return err
	}
	r.mu.Lock()
	r.sessions[name] = session
	r.mu.Unlock()
	return nil
}

func (r *GhostlineRuntime) session(ctx context.Context, name string) ghostline.Session {
	r.mu.Lock()
	session := r.sessions[name]
	r.mu.Unlock()
	if session != nil {
		return session
	}
	adopted, ok := r.client.Session(name)
	if !ok {
		return nil
	}
	r.mu.Lock()
	r.sessions[name] = adopted
	r.mu.Unlock()
	return adopted
}

func (r *GhostlineRuntime) Exists(ctx context.Context, name string) bool {
	session := r.session(ctx, name)
	return session != nil && session.Alive()
}

func (r *GhostlineRuntime) Capture(ctx context.Context, name string) ([]byte, error) {
	session := r.session(ctx, name)
	if session == nil {
		return nil, fmt.Errorf("ghostline session not found: %s", name)
	}
	return session.Snapshot(ctx)
}

func (r *GhostlineRuntime) Input(ctx context.Context, name string, data []byte) error {
	session := r.session(ctx, name)
	if session == nil {
		return fmt.Errorf("ghostline session not found: %s", name)
	}
	return session.Input(ctx, data)
}

func (r *GhostlineRuntime) Resize(ctx context.Context, name string, columns, rows int) error {
	session := r.session(ctx, name)
	if session == nil {
		return fmt.Errorf("ghostline session not found: %s", name)
	}
	return session.Resize(ctx, ghostline.Size{Columns: columns, Rows: rows})
}

func (r *GhostlineRuntime) Kill(ctx context.Context, name string) error {
	session := r.session(ctx, name)
	if session == nil {
		return nil
	}
	return session.Remove()
}

// EnsurePipe is a no-op: ghostline writes its own spool, there is no pipe to
// install on adoption.
func (r *GhostlineRuntime) EnsurePipe(context.Context, string) error { return nil }

func (r *GhostlineRuntime) SpoolPath(name string) string {
	session := r.session(context.Background(), name)
	if session == nil {
		return ""
	}
	return session.SpoolPath()
}

func (r *GhostlineRuntime) SpoolSize(ctx context.Context, name string) (int64, error) {
	session := r.session(ctx, name)
	if session == nil {
		return 0, fmt.Errorf("ghostline session not found: %s", name)
	}
	return session.SpoolSize(ctx)
}

func (r *GhostlineRuntime) TruncateSpool(ctx context.Context, name string) error {
	session := r.session(ctx, name)
	if session == nil {
		return fmt.Errorf("ghostline session not found: %s", name)
	}
	return session.TruncateSpool(ctx)
}

func (r *GhostlineRuntime) ArchiveSpool(ctx context.Context, name string) error {
	session := r.session(ctx, name)
	if session == nil {
		return fmt.Errorf("ghostline session not found: %s", name)
	}
	return session.ArchiveSpool(ctx)
}

func (r *GhostlineRuntime) RemoveSpool(name string) {
	if session := r.session(context.Background(), name); session != nil {
		session.RemoveSpool()
	}
}

func (r *GhostlineRuntime) List(ctx context.Context) (map[string]bool, error) {
	names, err := r.client.List(ctx)
	if err != nil {
		return nil, err
	}
	sessions := make(map[string]bool, len(names))
	for _, name := range names {
		sessions[name] = true
	}
	return sessions, nil
}

func (r *GhostlineRuntime) Recover(ctx context.Context, name string, offset, end int64) ([]byte, error) {
	session := r.session(ctx, name)
	if session == nil {
		return nil, fmt.Errorf("ghostline session not found: %s", name)
	}
	return session.Recover(ctx, offset, end)
}
