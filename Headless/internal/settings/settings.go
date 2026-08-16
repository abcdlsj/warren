package settings

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

// Runtime kinds supported by the headless daemon.
const (
	RuntimeGhostline = "ghostline"
	RuntimeTmux      = "tmux"
)

// DefaultRuntimeKind is used when neither the settings file nor --runtime
// selects one.
const DefaultRuntimeKind = RuntimeGhostline

// Settings is the headless daemon configuration. Runtime selection is a
// headless-side decision: it controls which engine owns newly created
// sessions, not what clients render.
type Settings struct {
	// DefaultRuntime is the engine used for sessions created without an
	// explicit runtimeKind. Supported: ghostline, tmux.
	DefaultRuntime string `json:"defaultRuntime"`
}

// Normalized returns the effective default runtime kind.
func (s Settings) Normalized() string {
	switch s.DefaultRuntime {
	case RuntimeGhostline, RuntimeTmux:
		return s.DefaultRuntime
	default:
		return DefaultRuntimeKind
	}
}

// DefaultPath returns the conventional settings file location.
func DefaultPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".warren", "settings.json")
}

// Load reads settings from path. A missing file yields defaults.
func Load(path string) (Settings, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return Settings{}, nil
	}
	if err != nil {
		return Settings{}, err
	}
	var value Settings
	if err := json.Unmarshal(data, &value); err != nil {
		return Settings{}, err
	}
	return value, nil
}

// Save persists settings atomically.
func Save(path string, value Settings) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, append(data, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(temporary, path)
}
