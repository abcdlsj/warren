package controlplane

import (
	"crypto/rand"
	"errors"
)

const (
	relayVersion byte = 1
	headerSize        = 22

	frameOpen   byte = 1
	frameClose  byte = 2
	frameText   byte = 3
	frameBinary byte = 4
)

var relayMagic = [4]byte{'B', 'R', 'L', 'Y'}

type relayFrame struct {
	Kind         byte
	ConnectionID connectionID
	Payload      []byte
}

type connectionID [16]byte

func newConnectionID() (connectionID, error) {
	var id connectionID
	_, err := rand.Read(id[:])
	return id, err
}

func encodeRelayFrame(frame relayFrame) []byte {
	encoded := make([]byte, headerSize+len(frame.Payload))
	copy(encoded[:4], relayMagic[:])
	encoded[4] = relayVersion
	encoded[5] = frame.Kind
	copy(encoded[6:22], frame.ConnectionID[:])
	copy(encoded[22:], frame.Payload)
	return encoded
}

func decodeRelayFrame(data []byte) (relayFrame, error) {
	if len(data) < headerSize || string(data[:4]) != string(relayMagic[:]) {
		return relayFrame{}, errors.New("invalid relay frame header")
	}
	if data[4] != relayVersion {
		return relayFrame{}, errors.New("unsupported relay frame version")
	}
	if data[5] < frameOpen || data[5] > frameBinary {
		return relayFrame{}, errors.New("invalid relay frame kind")
	}
	var id connectionID
	copy(id[:], data[6:22])
	return relayFrame{
		Kind:         data[5],
		ConnectionID: id,
		Payload:      append([]byte(nil), data[22:]...),
	}, nil
}
