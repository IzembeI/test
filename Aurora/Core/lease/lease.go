// Package lease holds the license token format shared by the Aurora core
// (which verifies leases on the phone) and the aurora-license admin tool
// (which signs offline leases and issues activation keys).
//
// A lease is base64url(JSON claims) + "." + base64url(Ed25519 signature over
// the first part, as ASCII). Activation keys look like
// AUR-XXXXX-XXXXX-XXXXX-XXXXX in Crockford base32; the last two characters
// are a checksum, so a mistyped key is caught without the network.
package lease

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
)

// Version is the claims format version.
const Version = 1

// Key ids of the trusted signers.
const (
	KidServer = "server" // online leases, signed by the license Worker
	KidAdmin  = "admin"  // offline per-device leases, signed by the CLI
)

// SubOffline marks a lease that is not tied to an activation key.
const SubOffline = "offline"

// Claims is the signed content of a lease. Times are Unix seconds.
type Claims struct {
	V   int    `json:"v"`
	Kid string `json:"kid"`
	Sub string `json:"sub"`
	KC  string `json:"kc,omitempty"`
	IFV string `json:"ifv,omitempty"`
	Iat int64  `json:"iat"`
	Exp int64  `json:"exp"`
	St  int64  `json:"st"`
}

var (
	ErrMalformed  = errors.New("lease: malformed token")
	ErrUnknownKid = errors.New("lease: unknown signing key")
	ErrSignature  = errors.New("lease: bad signature")
	ErrVersion    = errors.New("lease: unsupported version")
)

var b64 = base64.RawURLEncoding

// Sign encodes the claims and signs them. Claims.V is set to Version.
func Sign(c Claims, priv ed25519.PrivateKey) (string, error) {
	if len(priv) != ed25519.PrivateKeySize {
		return "", errors.New("lease: bad private key")
	}
	c.V = Version
	body, err := json.Marshal(c)
	if err != nil {
		return "", err
	}
	head := b64.EncodeToString(body)
	sig := ed25519.Sign(priv, []byte(head))
	return head + "." + b64.EncodeToString(sig), nil
}

// Parse decodes the claims without checking the signature.
func Parse(token string) (Claims, error) {
	var c Claims
	head, _, ok := strings.Cut(strings.TrimSpace(token), ".")
	if !ok || head == "" {
		return c, ErrMalformed
	}
	body, err := b64.DecodeString(head)
	if err != nil {
		return c, ErrMalformed
	}
	if err := json.Unmarshal(body, &c); err != nil {
		return c, ErrMalformed
	}
	return c, nil
}

// Verify checks the token's signature against the trusted keys (kid ->
// public key) and returns its claims. Expiry and device are not checked
// here: the caller decides with its own clock and device ids.
func Verify(token string, keys map[string]ed25519.PublicKey) (Claims, error) {
	token = strings.TrimSpace(token)
	head, sigText, ok := strings.Cut(token, ".")
	if !ok || head == "" || sigText == "" || strings.Contains(sigText, ".") {
		return Claims{}, ErrMalformed
	}
	c, err := Parse(token)
	if err != nil {
		return c, err
	}
	if c.V != Version {
		return c, ErrVersion
	}
	pub, ok := keys[c.Kid]
	if !ok || len(pub) != ed25519.PublicKeySize {
		return c, ErrUnknownKid
	}
	sig, err := b64.DecodeString(sigText)
	if err != nil || len(sig) != ed25519.SignatureSize {
		return c, ErrMalformed
	}
	if !ed25519.Verify(pub, []byte(head), sig) {
		return c, ErrSignature
	}
	return c, nil
}

// Matches reports whether the lease belongs to this device: the Keychain id
// or the identifierForVendor must match (either one is enough, so a
// reinstall that changes one of them keeps the license).
func (c Claims) Matches(kc, ifv string) bool {
	kc, ifv = strings.TrimSpace(kc), strings.TrimSpace(ifv)
	if c.KC != "" && kc != "" && strings.EqualFold(c.KC, kc) {
		return true
	}
	return c.IFV != "" && ifv != "" && strings.EqualFold(c.IFV, ifv)
}

// MARK: - Keys

// EncodePublic returns the text form of a public key (base64url, raw 32 bytes).
func EncodePublic(pub ed25519.PublicKey) string { return b64.EncodeToString(pub) }

// DecodePublic parses the text form of a public key.
func DecodePublic(s string) (ed25519.PublicKey, error) {
	b, err := b64.DecodeString(strings.TrimSpace(s))
	if err != nil || len(b) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("lease: bad public key")
	}
	return ed25519.PublicKey(b), nil
}

// EncodePrivate returns the private key as standard base64 of PKCS#8 DER:
// the form WebCrypto imports with importKey("pkcs8", ..., {name: "Ed25519"}).
func EncodePrivate(priv ed25519.PrivateKey) (string, error) {
	der, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(der), nil
}

// DecodePrivate parses the form written by EncodePrivate.
func DecodePrivate(s string) (ed25519.PrivateKey, error) {
	der, err := base64.StdEncoding.DecodeString(strings.TrimSpace(s))
	if err != nil {
		return nil, fmt.Errorf("lease: bad private key encoding")
	}
	k, err := x509.ParsePKCS8PrivateKey(der)
	if err != nil {
		return nil, err
	}
	priv, ok := k.(ed25519.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("lease: not an Ed25519 key")
	}
	return priv, nil
}

// Trusted returns the built-in signers the app accepts.
func Trusted() map[string]ed25519.PublicKey {
	out := map[string]ed25519.PublicKey{}
	for kid, text := range map[string]string{KidServer: ServerPublicKey, KidAdmin: AdminPublicKey} {
		if pub, err := DecodePublic(text); err == nil {
			out[kid] = pub
		}
	}
	return out
}

// MARK: - Activation keys

// Alphabet is Crockford base32 (no I, L, O, U).
const Alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

const (
	keyPrefix   = "AUR"
	keyDataLen  = 18 // random characters, 90 bits
	keyTotalLen = 20 // plus 2 checksum characters
)

// keyChecksum returns the two check characters for the data part: the top 10
// bits of sha256(data) as two base32 digits.
func keyChecksum(data string) string {
	h := sha256.Sum256([]byte(data))
	v := (int(h[0])<<8 | int(h[1])) >> 6
	return string([]byte{Alphabet[v>>5], Alphabet[v&31]})
}

// NormalizeKey returns the canonical AUR-XXXXX-XXXXX-XXXXX-XXXXX form of a
// key typed in any case, with or without dashes and spaces, and with the
// Crockford look-alikes (O -> 0, I/L -> 1). ok is false when the length,
// characters or checksum are wrong.
func NormalizeKey(s string) (string, bool) {
	s = strings.ToUpper(strings.TrimSpace(s))
	var b strings.Builder
	for _, r := range s {
		switch r {
		case '-', ' ', '_', '\t':
			continue
		}
		b.WriteRune(r)
	}
	s = strings.TrimPrefix(b.String(), keyPrefix)
	if len(s) != keyTotalLen {
		return "", false
	}
	raw := []byte(s)
	for i, c := range raw {
		switch c {
		case 'O':
			raw[i] = '0'
		case 'I', 'L':
			raw[i] = '1'
		}
		if strings.IndexByte(Alphabet, raw[i]) < 0 {
			return "", false
		}
	}
	data := string(raw[:keyDataLen])
	if keyChecksum(data) != string(raw[keyDataLen:]) {
		return "", false
	}
	return formatKey(string(raw)), true
}

func formatKey(chars string) string {
	parts := []string{keyPrefix}
	for i := 0; i < len(chars); i += 5 {
		parts = append(parts, chars[i:i+5])
	}
	return strings.Join(parts, "-")
}

// ValidKey reports whether s is a well-formed key with a correct checksum.
func ValidKey(s string) bool {
	_, ok := NormalizeKey(s)
	return ok
}

// NewKey generates a random activation key (nil reader = crypto/rand).
func NewKey(r io.Reader) (string, error) {
	if r == nil {
		r = rand.Reader
	}
	buf := make([]byte, keyDataLen)
	if _, err := io.ReadFull(r, buf); err != nil {
		return "", err
	}
	data := make([]byte, keyDataLen)
	for i, v := range buf {
		data[i] = Alphabet[v&31] // 256 is a multiple of 32: no bias
	}
	return formatKey(string(data) + keyChecksum(string(data))), nil
}

// KeyHash is the hex sha256 of the canonical key: the only form the license
// server stores.
func KeyHash(key string) string {
	if k, ok := NormalizeKey(key); ok {
		key = k
	}
	h := sha256.Sum256([]byte(key))
	return hex.EncodeToString(h[:])
}

// KeySub is the lease subject for a key: the first 8 hex digits of KeyHash.
func KeySub(key string) string { return KeyHash(key)[:8] }
