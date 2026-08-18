package server

import "context"

// sessionLock is a context-aware mutex used for per-session output ordering.
// A channel-backed lock lets attach abort instead of waiting forever behind a
// stalled output broadcaster.
type sessionLock struct {
	token chan struct{}
}

func newSessionLock() *sessionLock {
	token := make(chan struct{}, 1)
	token <- struct{}{}
	return &sessionLock{token: token}
}

func (lock *sessionLock) Lock() {
	<-lock.token
}

func (lock *sessionLock) LockContext(ctx context.Context) error {
	select {
	case <-lock.token:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (lock *sessionLock) TryLock() bool {
	select {
	case <-lock.token:
		return true
	default:
		return false
	}
}

func (lock *sessionLock) Unlock() {
	select {
	case lock.token <- struct{}{}:
	default:
		panic("unlock of unlocked session lock")
	}
}
