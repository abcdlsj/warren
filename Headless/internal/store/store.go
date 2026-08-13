package store

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"runtime"
	"sync"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

type Store struct {
	mu    sync.RWMutex
	path  string
	state api.State
}

func Open(path, hostName string) (*Store, error) {
	s := &Store{path: path}
	data, err := os.ReadFile(path)
	if err == nil {
		if err := json.Unmarshal(data, &s.state); err != nil {
			return nil, fmt.Errorf("decode state: %w", err)
		}
		if s.state.Schema != 1 {
			return nil, fmt.Errorf("unsupported state schema %d", s.state.Schema)
		}
		return s, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("read state: %w", err)
	}
	if hostName == "" {
		hostName, _ = os.Hostname()
	}
	current, _ := user.Current()
	s.state = api.State{
		Schema: 1,
		Host:   api.Host{ID: NewID(), Name: hostName, User: userName(current), OS: runtime.GOOS + "/" + runtime.GOARCH, Version: api.Version},
	}
	if err := s.saveLocked(); err != nil {
		return nil, err
	}
	return s, nil
}

func userName(value *user.User) string {
	if value == nil {
		return ""
	}
	return value.Username
}

func (s *Store) Snapshot() api.State {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return clone(s.state)
}

func (s *Store) Update(fn func(*api.State) error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	next := clone(s.state)
	if err := fn(&next); err != nil {
		return err
	}
	old := s.state
	s.state = next
	if err := s.saveLocked(); err != nil {
		s.state = old
		return err
	}
	return nil
}

func (s *Store) saveLocked() error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return fmt.Errorf("create state directory: %w", err)
	}
	data, err := json.MarshalIndent(s.state, "", "  ")
	if err != nil {
		return err
	}
	temporary := s.path + ".tmp"
	if err := os.WriteFile(temporary, append(data, '\n'), 0o600); err != nil {
		return fmt.Errorf("write state: %w", err)
	}
	if err := os.Rename(temporary, s.path); err != nil {
		return fmt.Errorf("commit state: %w", err)
	}
	return nil
}

func NewID() string {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		panic(err)
	}
	raw[6] = (raw[6] & 0x0f) | 0x40
	raw[8] = (raw[8] & 0x3f) | 0x80
	value := hex.EncodeToString(raw[:])
	return value[0:8] + "-" + value[8:12] + "-" + value[12:16] + "-" + value[16:20] + "-" + value[20:32]
}

func clone(value api.State) api.State {
	data, _ := json.Marshal(value)
	var result api.State
	_ = json.Unmarshal(data, &result)
	return result
}
