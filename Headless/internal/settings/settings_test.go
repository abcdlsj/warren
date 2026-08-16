package settings

import (
	"path/filepath"
	"testing"
)

func TestNormalizedDefaultsToGhostline(t *testing.T) {
	if (Settings{}).Normalized() != RuntimeGhostline {
		t.Fatalf("empty settings normalized = %q", (Settings{}).Normalized())
	}
	if (Settings{DefaultRuntime: RuntimeTmux}).Normalized() != RuntimeTmux {
		t.Fatal("tmux setting not preserved")
	}
	if (Settings{DefaultRuntime: "bogus"}).Normalized() != RuntimeGhostline {
		t.Fatal("invalid setting must fall back to ghostline")
	}
}

func TestSaveLoadRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	if err := Save(path, Settings{DefaultRuntime: RuntimeTmux}); err != nil {
		t.Fatalf("Save: %v", err)
	}
	loaded, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if loaded.DefaultRuntime != RuntimeTmux {
		t.Fatalf("loaded default = %q", loaded.DefaultRuntime)
	}
}

func TestLoadMissingFileYieldsDefaults(t *testing.T) {
	loaded, err := Load(filepath.Join(t.TempDir(), "missing.json"))
	if err != nil {
		t.Fatalf("Load missing: %v", err)
	}
	if loaded.Normalized() != RuntimeGhostline {
		t.Fatalf("missing file normalized = %q", loaded.Normalized())
	}
}
