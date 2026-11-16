package corebridge

import (
	"crypto/ed25519"
	"strings"
	"time"

	"github.com/werx/aurora/corebridge/lease"
)

// NormalizeLicenseKey returns the key in its canonical AUR-XXXXX-... form,
// or "" when it is not a key (bad length, letters or checksum). Typos are
// caught on the phone, without the network.
func NormalizeLicenseKey(s string) string {
	k, ok := lease.NormalizeKey(s)
	if !ok {
		return ""
	}
	return k
}

// LicenseKeyHash is the id the license server stores for a key (SHA-256 hex).
func LicenseKeyHash(key string) string {
	k, ok := lease.NormalizeKey(key)
	if !ok {
		return ""
	}
	return lease.KeyHash(k)
}

// AdminKeyMatches reports whether a pasted admin private key is the one the
// app trusts, so the admin screen can refuse a wrong key at once.
func AdminKeyMatches(adminPrivateKey string) bool {
	priv, err := lease.DecodePrivate(adminPrivateKey)
	if err != nil {
		return false
	}
	pub, ok := priv.Public().(ed25519.PublicKey)
	return ok && lease.EncodePublic(pub) == lease.AdminPublicKey
}

// SignOfflineLease makes a per-device lease on the admin's own phone, the
// same way `aurora-license sign` does on a PC. deviceCode is what the user's
// app shows ("kc:ifv", either part may be empty). The result is the token,
// or "error: <reason in Russian>".
func SignOfflineLease(adminPrivateKey, deviceCode string, days int) string {
	priv, err := lease.DecodePrivate(adminPrivateKey)
	if err != nil {
		return "error: ключ администратора не читается"
	}
	if !AdminKeyMatches(adminPrivateKey) {
		return "error: это не ключ администратора Aurora"
	}
	kc, ifv, _ := strings.Cut(strings.TrimSpace(deviceCode), ":")
	kc, ifv = strings.TrimSpace(kc), strings.TrimSpace(ifv)
	if kc == "" && ifv == "" {
		return "error: пустой код устройства"
	}
	if days <= 0 || days > 3650 {
		return "error: срок от 1 до 3650 дней"
	}
	t := time.Now().Unix()
	tok, err := lease.Sign(lease.Claims{Kid: lease.KidAdmin, Sub: lease.SubOffline, KC: kc, IFV: ifv,
		Iat: t, Exp: t + int64(days)*86400, St: t}, priv)
	if err != nil {
		return "error: " + err.Error()
	}
	return tok
}
