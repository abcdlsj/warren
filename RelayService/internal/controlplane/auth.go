package controlplane

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

type tokenClaims struct {
	HostID     string `json:"host_id"`
	Scope      string `json:"scope"`
	Generation uint64 `json:"generation"`
	Expiry     int64  `json:"exp"`
}

type tokenSigner struct {
	key []byte
	now func() time.Time
}

func newTokenSigner(key []byte) (*tokenSigner, error) {
	if len(key) < 32 {
		return nil, errors.New("BURROW_RELAY_SIGNING_KEY must contain at least 32 bytes")
	}
	return &tokenSigner{key: append([]byte(nil), key...), now: time.Now}, nil
}

func randomToken(byteCount int) (string, error) {
	bytes := make([]byte, byteCount)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(bytes), nil
}

func (signer *tokenSigner) issue(hostID, scope string, generation uint64, ttl time.Duration) (string, error) {
	payload, err := json.Marshal(tokenClaims{
		HostID: hostID, Scope: scope, Generation: generation,
		Expiry: signer.now().Add(ttl).Unix(),
	})
	if err != nil {
		return "", err
	}
	encoded := base64.RawURLEncoding.EncodeToString(payload)
	return encoded + "." + base64.RawURLEncoding.EncodeToString(signer.signature(encoded)), nil
}

func (signer *tokenSigner) verify(token, hostID, scope string) (tokenClaims, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 2 {
		return tokenClaims{}, errors.New("invalid token")
	}
	provided, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || !hmac.Equal(provided, signer.signature(parts[0])) {
		return tokenClaims{}, errors.New("invalid token signature")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return tokenClaims{}, errors.New("invalid token payload")
	}
	var claims tokenClaims
	if json.Unmarshal(payload, &claims) != nil || claims.HostID != hostID || claims.Scope != scope {
		return tokenClaims{}, errors.New("invalid token claims")
	}
	if signer.now().Unix() >= claims.Expiry {
		return tokenClaims{}, errors.New("token expired")
	}
	return claims, nil
}

func (signer *tokenSigner) signature(encodedPayload string) []byte {
	mac := hmac.New(sha256.New, signer.key)
	_, _ = mac.Write([]byte(encodedPayload))
	return mac.Sum(nil)
}
