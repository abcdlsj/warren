// Package tlscert manages a local CA and server certificate for the LAN HTTPS
// listener. The CA is generated once so a phone only has to trust it once;
// the server certificate is renewed whenever the machine's LAN addresses
// change or it approaches expiry.
package tlscert

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"time"
)

const (
	caLifetime   = 10 * 365 * 24 * time.Hour
	leafLifetime = 365 * 24 * time.Hour
	renewBefore  = 30 * 24 * time.Hour
)

// Store owns the CA and server certificate files in one directory.
type Store struct {
	dir string
}

func NewStore(dir string) *Store {
	return &Store{dir: dir}
}

// CAPEMPath returns the path of the CA certificate that devices need to
// install and trust.
func (s *Store) CAPEMPath() string {
	return filepath.Join(s.dir, "ca.crt")
}

// ServerCertificate returns the TLS certificate for the LAN HTTPS listener,
// generating or renewing the local CA and leaf certificate as needed.
func (s *Store) ServerCertificate() (tls.Certificate, error) {
	ips, err := LANIPs()
	if err != nil {
		return tls.Certificate{}, err
	}
	return s.Certificate(ips)
}

// Certificate returns a server certificate covering the given IPs. It is
// exported for tests and for callers that already know the desired SANs.
func (s *Store) Certificate(ips []net.IP) (tls.Certificate, error) {
	if err := os.MkdirAll(s.dir, 0o700); err != nil {
		return tls.Certificate{}, err
	}
	caCert, caKey, err := s.loadOrCreateCA()
	if err != nil {
		return tls.Certificate{}, err
	}
	if _, err := s.loadOrCreateLeaf(caCert, caKey, ips); err != nil {
		return tls.Certificate{}, err
	}
	return tls.LoadX509KeyPair(
		filepath.Join(s.dir, "server.crt"),
		filepath.Join(s.dir, "server.key"),
	)
}

func (s *Store) loadOrCreateCA() (*x509.Certificate, *ecdsa.PrivateKey, error) {
	certPath := filepath.Join(s.dir, "ca.crt")
	keyPath := filepath.Join(s.dir, "ca.key")
	cert, key, err := loadCertificateAndKey(certPath, keyPath)
	if err == nil && cert.IsCA && time.Now().Before(cert.NotAfter) {
		return cert, key, nil
	}

	key, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, fmt.Errorf("generate CA key: %w", err)
	}
	serial, err := randomSerial()
	if err != nil {
		return nil, nil, err
	}
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "Warren Local CA", Organization: []string{"Warren"}},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(caLifetime),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLen:            1,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return nil, nil, fmt.Errorf("create CA certificate: %w", err)
	}
	if err := writePEM(certPath, "CERTIFICATE", der); err != nil {
		return nil, nil, err
	}
	if err := writeECKey(keyPath, key); err != nil {
		return nil, nil, err
	}
	cert, err = x509.ParseCertificate(der)
	return cert, key, err
}

func (s *Store) loadOrCreateLeaf(caCert *x509.Certificate, caKey *ecdsa.PrivateKey, ips []net.IP) (*x509.Certificate, error) {
	leafPath := filepath.Join(s.dir, "server.crt")
	leaf, err := loadCertificate(leafPath)
	if err == nil && coversIPs(leaf, ips) && time.Now().Add(renewBefore).Before(leaf.NotAfter) {
		return leaf, nil
	}

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("generate server key: %w", err)
	}
	serial, err := randomSerial()
	if err != nil {
		return nil, err
	}
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: "Warren Local", Organization: []string{"Warren"}},
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.Add(leafLifetime),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{"localhost"},
		IPAddresses:  uniqueIPs(append([]net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")}, ips...)),
	}
	der, err := x509.CreateCertificate(rand.Reader, template, caCert, &key.PublicKey, caKey)
	if err != nil {
		return nil, fmt.Errorf("create server certificate: %w", err)
	}
	if err := writePEM(leafPath, "CERTIFICATE", der); err != nil {
		return nil, err
	}
	if err := writeECKey(filepath.Join(s.dir, "server.key"), key); err != nil {
		return nil, err
	}
	return x509.ParseCertificate(der)
}

// LANIPs returns the machine's usable unicast LAN addresses, excluding
// loopback, link-local and multicast. The slice may be empty on a host with
// only loopback interfaces; the certificate then covers localhost only.
func LANIPs() ([]net.IP, error) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, fmt.Errorf("list network interfaces: %w", err)
	}
	var ips []net.IP
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			var ip net.IP
			switch value := addr.(type) {
			case *net.IPNet:
				ip = value.IP
			case *net.IPAddr:
				ip = value.IP
			}
			if ip == nil || ip.IsLoopback() || ip.IsUnspecified() ||
				ip.IsMulticast() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() {
				continue
			}
			ips = append(ips, append(net.IP(nil), ip...))
		}
	}
	return uniqueIPs(ips), nil
}

func uniqueIPs(ips []net.IP) []net.IP {
	seen := make(map[string]bool, len(ips))
	result := make([]net.IP, 0, len(ips))
	for _, ip := range ips {
		key := ip.String()
		if seen[key] {
			continue
		}
		seen[key] = true
		result = append(result, ip)
	}
	return result
}

func coversIPs(cert *x509.Certificate, ips []net.IP) bool {
	for _, want := range ips {
		found := false
		for _, have := range cert.IPAddresses {
			if have.Equal(want) {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}

func loadCertificate(path string) (*x509.Certificate, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(data)
	if block == nil || block.Type != "CERTIFICATE" {
		return nil, errors.New("invalid certificate PEM")
	}
	return x509.ParseCertificate(block.Bytes)
}

func loadCertificateAndKey(certPath, keyPath string) (*x509.Certificate, *ecdsa.PrivateKey, error) {
	cert, err := loadCertificate(certPath)
	if err != nil {
		return nil, nil, err
	}
	data, err := os.ReadFile(keyPath)
	if err != nil {
		return nil, nil, err
	}
	block, _ := pem.Decode(data)
	if block == nil || block.Type != "EC PRIVATE KEY" {
		return nil, nil, errors.New("invalid EC private key PEM")
	}
	key, err := x509.ParseECPrivateKey(block.Bytes)
	if err != nil {
		return nil, nil, err
	}
	return cert, key, nil
}

func randomSerial() (*big.Int, error) {
	limit := new(big.Int).Lsh(big.NewInt(1), 128)
	return rand.Int(rand.Reader, limit)
}

func writePEM(path, blockType string, der []byte) error {
	data := pem.EncodeToMemory(&pem.Block{Type: blockType, Bytes: der})
	return os.WriteFile(path, data, 0o644)
}

func writeECKey(path string, key *ecdsa.PrivateKey) error {
	der, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return fmt.Errorf("marshal EC private key: %w", err)
	}
	data := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der})
	return os.WriteFile(path, data, 0o600)
}
