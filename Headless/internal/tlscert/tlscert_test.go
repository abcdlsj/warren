package tlscert

import (
	"crypto/x509"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestCertificateGeneratedOnceAndReused(t *testing.T) {
	t.Parallel()
	store := NewStore(t.TempDir())
	first, err := store.Certificate([]net.IP{net.ParseIP("192.168.1.117")})
	if err != nil {
		t.Fatalf("generate certificate: %v", err)
	}
	second, err := store.Certificate([]net.IP{net.ParseIP("192.168.1.117")})
	if err != nil {
		t.Fatalf("reuse certificate: %v", err)
	}
	if len(first.Certificate) == 0 || len(second.Certificate) == 0 {
		t.Fatal("certificate chain is empty")
	}
	if string(first.Certificate[0]) != string(second.Certificate[0]) {
		t.Fatal("certificate changed for identical IPs")
	}

	leaf, err := x509.ParseCertificate(first.Certificate[0])
	if err != nil {
		t.Fatalf("parse leaf certificate: %v", err)
	}
	if !containsIP(leaf.IPAddresses, net.ParseIP("192.168.1.117")) {
		t.Fatalf("leaf certificate does not cover 192.168.1.117: %v", leaf.IPAddresses)
	}
	if len(leaf.DNSNames) != 1 || leaf.DNSNames[0] != "localhost" {
		t.Fatalf("leaf DNS names = %v, want [localhost]", leaf.DNSNames)
	}
	if time.Now().After(leaf.NotAfter) {
		t.Fatal("leaf certificate is already expired")
	}

	caData, err := os.ReadFile(store.CAPEMPath())
	if err != nil {
		t.Fatalf("read CA certificate: %v", err)
	}
	if len(caData) == 0 {
		t.Fatal("CA certificate is empty")
	}
	keyPath := filepath.Join(store.dir, "server.key")
	if info, err := os.Stat(keyPath); err != nil {
		t.Fatalf("stat server key: %v", err)
	} else if info.Mode().Perm() != 0o600 {
		t.Fatalf("server key mode = %v, want 0600", info.Mode().Perm())
	}
}

func TestCertificateRegeneratesLeafForNewLANIP(t *testing.T) {
	t.Parallel()
	store := NewStore(t.TempDir())
	before, err := store.Certificate([]net.IP{net.ParseIP("127.0.0.1")})
	if err != nil {
		t.Fatalf("generate initial certificate: %v", err)
	}
	caBefore, err := os.ReadFile(store.CAPEMPath())
	if err != nil {
		t.Fatalf("read initial CA: %v", err)
	}

	after, err := store.Certificate([]net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("192.168.1.117")})
	if err != nil {
		t.Fatalf("renew certificate: %v", err)
	}
	if string(before.Certificate[0]) == string(after.Certificate[0]) {
		t.Fatal("leaf certificate was not renewed for the new LAN IP")
	}
	caAfter, err := os.ReadFile(store.CAPEMPath())
	if err != nil {
		t.Fatalf("read renewed CA: %v", err)
	}
	if string(caBefore) != string(caAfter) {
		t.Fatal("CA changed while renewing the leaf certificate")
	}

	leaf, err := x509.ParseCertificate(after.Certificate[0])
	if err != nil {
		t.Fatalf("parse renewed leaf: %v", err)
	}
	if !containsIP(leaf.IPAddresses, net.ParseIP("192.168.1.117")) {
		t.Fatalf("renewed leaf does not cover 192.168.1.117: %v", leaf.IPAddresses)
	}
}

func containsIP(ips []net.IP, want net.IP) bool {
	for _, ip := range ips {
		if ip.Equal(want) {
			return true
		}
	}
	return false
}
