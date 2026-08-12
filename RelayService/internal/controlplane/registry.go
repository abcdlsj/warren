package controlplane

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"sync"
	"time"
)

var hostIDPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
var errHostNotFound = errors.New("host not found")

type hostRecord struct {
	ID             string      `json:"id"`
	Name           string      `json:"name"`
	Online         bool        `json:"online"`
	ConnectedAt    time.Time   `json:"connected_at,omitempty"`
	LastSeenAt     time.Time   `json:"last_seen_at,omitempty"`
	CredentialHash string      `json:"credential_hash,omitempty"`
	Generation     uint64      `json:"generation"`
	PairingToken   string      `json:"-"`
	PairingUntil   time.Time   `json:"-"`
	Tunnel         *hostTunnel `json:"-"`
}

type persistedRegistry struct {
	Hosts []*hostRecord `json:"hosts"`
}

type registry struct {
	mu      sync.RWMutex
	hosts   map[string]*hostRecord
	now     func() time.Time
	dataURL string
}

func newRegistry(dataURL string) (*registry, error) {
	registry := &registry{hosts: make(map[string]*hostRecord), now: time.Now, dataURL: dataURL}
	if dataURL == "" {
		return registry, nil
	}
	data, err := os.ReadFile(dataURL)
	if errors.Is(err, os.ErrNotExist) {
		return registry, nil
	}
	if err != nil {
		return nil, err
	}
	var stored persistedRegistry
	if err := json.Unmarshal(data, &stored); err != nil {
		return nil, err
	}
	for _, record := range stored.Hosts {
		record.Online = false
		record.Tunnel = nil
		record.PairingToken = ""
		record.PairingUntil = time.Time{}
		registry.hosts[record.ID] = record
	}
	return registry, nil
}

func (registry *registry) provisionHost(id, name string) (string, error) {
	if !validHostID(id) {
		return "", errors.New("invalid host ID")
	}
	registry.mu.Lock()
	defer registry.mu.Unlock()
	credential, err := randomToken(32)
	if err != nil {
		return "", err
	}
	previous := registry.hosts[id]
	record := &hostRecord{ID: id}
	if previous != nil {
		copy := *previous
		record = &copy
	}
	previousTunnel := record.Tunnel
	record.Name = name
	record.Online = false
	record.Tunnel = nil
	record.Generation++
	record.CredentialHash = hashCredential(credential)
	record.PairingToken = ""
	record.PairingUntil = time.Time{}
	registry.hosts[id] = record
	if err := registry.persistLocked(); err != nil {
		if previous == nil {
			delete(registry.hosts, id)
		} else {
			registry.hosts[id] = previous
		}
		return "", err
	}
	if previousTunnel != nil {
		previousTunnel.close()
	}
	return credential, nil
}

func validHostID(id string) bool { return hostIDPattern.MatchString(id) }

func (registry *registry) authenticateHost(id, credential string) bool {
	registry.mu.RLock()
	defer registry.mu.RUnlock()
	return authenticateHostRecord(registry.hosts[id], credential)
}

func authenticateHostRecord(record *hostRecord, credential string) bool {
	if record == nil || record.CredentialHash == "" {
		return false
	}
	provided, err := base64.RawURLEncoding.DecodeString(record.CredentialHash)
	if err != nil {
		return false
	}
	actual := sha256.Sum256([]byte(credential))
	return subtle.ConstantTimeCompare(provided, actual[:]) == 1
}

func (registry *registry) revokeHost(id string) error {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	record := registry.hosts[id]
	if record == nil {
		return errHostNotFound
	}
	previous := record
	copy := *record
	record = &copy
	previousTunnel := record.Tunnel
	record.Tunnel = nil
	record.Online = false
	record.Generation++
	record.CredentialHash = ""
	record.PairingToken = ""
	record.PairingUntil = time.Time{}
	registry.hosts[id] = record
	if err := registry.persistLocked(); err != nil {
		registry.hosts[id] = previous
		return err
	}
	if previousTunnel != nil {
		previousTunnel.close()
	}
	return nil
}

func (registry *registry) connectHost(id, name, credential string, tunnel *hostTunnel) bool {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	now := registry.now().UTC()
	record := registry.hosts[id]
	// Authentication is repeated under the same lock that publishes the
	// tunnel. A credential can be rotated while the HTTP upgrade is in flight;
	// an earlier preflight check must not let that old socket replace the new
	// Host connection.
	if !authenticateHostRecord(record, credential) {
		return false
	}
	if record.Tunnel != nil && record.Tunnel != tunnel {
		record.Tunnel.close()
	}
	if name != "" {
		record.Name = name
	}
	record.Online = true
	record.ConnectedAt = now
	record.LastSeenAt = now
	record.Tunnel = tunnel
	_ = registry.persistLocked()
	return true
}

func (registry *registry) touchHost(id string, tunnel *hostTunnel) {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	if record := registry.hosts[id]; record != nil && record.Tunnel == tunnel {
		record.LastSeenAt = registry.now().UTC()
	}
}

func (registry *registry) disconnectHost(id string, tunnel *hostTunnel) {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	if record := registry.hosts[id]; record != nil && record.Tunnel == tunnel {
		record.Online = false
		record.LastSeenAt = registry.now().UTC()
		record.Tunnel = nil
		_ = registry.persistLocked()
	}
}

func (registry *registry) beginPairing(id string, ttl time.Duration) (string, error) {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	record := registry.hosts[id]
	if record == nil || !record.Online || record.Tunnel == nil {
		return "", errors.New("host offline")
	}
	code, err := randomToken(9)
	if err != nil {
		return "", err
	}
	record.PairingToken = code
	record.PairingUntil = registry.now().Add(ttl)
	return code, nil
}

func (registry *registry) consumePairing(id, code string) (uint64, error) {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	record := registry.hosts[id]
	if record == nil || !record.Online || record.Tunnel == nil {
		return 0, errors.New("host offline")
	}
	if registry.now().After(record.PairingUntil) || record.PairingToken == "" || !secureEqual(record.PairingToken, code) {
		return 0, errors.New("invalid pairing code")
	}
	record.PairingToken = ""
	record.PairingUntil = time.Time{}
	return record.Generation, nil
}

func (registry *registry) authorizedTunnel(id string, generation uint64) *hostTunnel {
	registry.mu.RLock()
	defer registry.mu.RUnlock()
	record := registry.hosts[id]
	if record == nil || !record.Online || record.Generation != generation {
		return nil
	}
	return record.Tunnel
}

func (registry *registry) generation(id string) (uint64, bool) {
	registry.mu.RLock()
	defer registry.mu.RUnlock()
	record := registry.hosts[id]
	if record == nil {
		return 0, false
	}
	return record.Generation, true
}

func (registry *registry) host(id string) (hostRecord, bool) {
	registry.mu.RLock()
	defer registry.mu.RUnlock()
	record := registry.hosts[id]
	if record == nil {
		return hostRecord{}, false
	}
	copy := *record
	copy.Tunnel = nil
	copy.PairingToken = ""
	copy.PairingUntil = time.Time{}
	copy.CredentialHash = ""
	return copy, true
}

func (registry *registry) persistLocked() error {
	if registry.dataURL == "" {
		return nil
	}
	stored := persistedRegistry{Hosts: make([]*hostRecord, 0, len(registry.hosts))}
	for _, record := range registry.hosts {
		copy := *record
		copy.Online = false
		copy.Tunnel = nil
		copy.PairingToken = ""
		copy.PairingUntil = time.Time{}
		stored.Hosts = append(stored.Hosts, &copy)
	}
	data, err := json.MarshalIndent(stored, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(registry.dataURL), 0o700); err != nil {
		return err
	}
	temporary := registry.dataURL + ".tmp"
	if err := os.WriteFile(temporary, data, 0o600); err != nil {
		return err
	}
	if err := os.Chmod(temporary, 0o600); err != nil {
		return err
	}
	return os.Rename(temporary, registry.dataURL)
}

func hashCredential(credential string) string {
	digest := sha256.Sum256([]byte(credential))
	return base64.RawURLEncoding.EncodeToString(digest[:])
}
