package update

import (
	"crypto/sha256"
	"encoding/hex"
	"hash"
)

type sha256Hasher struct {
	h hash.Hash
}

func newSHA256() *sha256Hasher {
	return &sha256Hasher{h: sha256.New()}
}

func (s *sha256Hasher) Write(p []byte) (int, error) { return s.h.Write(p) }

func (s *sha256Hasher) sum() string { return hex.EncodeToString(s.h.Sum(nil)) }
