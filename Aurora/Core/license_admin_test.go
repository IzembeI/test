package corebridge

import (
	"crypto/ed25519"
	"crypto/rand"
	"strings"
	"testing"

	"github.com/werx/aurora/corebridge/lease"
)

func TestSignOfflineLeaseOnPhone(t *testing.T) {
	// A real admin key cannot be used in a test: trust a test key instead.
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	privText, _ := lease.EncodePrivate(priv)
	if AdminKeyMatches(privText) {
		t.Fatal("a random key must not pass as the built-in admin key")
	}
	if r := SignOfflineLease(privText, "kc1:ifv1", 30); !strings.HasPrefix(r, "error:") {
		t.Fatal("a foreign key must be refused:", r)
	}
	if r := SignOfflineLease("garbage", "kc1:ifv1", 30); !strings.HasPrefix(r, "error:") {
		t.Fatal(r)
	}
	// Sign as the CLI would, then check the phone accepts it with this test key trusted.
	tok, err := lease.Sign(lease.Claims{Kid: lease.KidAdmin, Sub: lease.SubOffline, KC: "kc1", IFV: "ifv1", Iat: 1, Exp: 1 << 40, St: 1}, priv)
	if err != nil {
		t.Fatal(err)
	}
	c, err := lease.Verify(tok, map[string]ed25519.PublicKey{lease.KidAdmin: pub})
	if err != nil || !c.Matches("", "ifv1") || c.Matches("other", "other") {
		t.Fatal(c, err)
	}
}

func TestNormalizeLicenseKey(t *testing.T) {
	k, err := lease.NewKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if NormalizeLicenseKey(strings.ToLower(strings.ReplaceAll(k, "-", " "))) != k {
		t.Fatal("typed in lower case with spaces should normalize to", k)
	}
	if NormalizeLicenseKey(k[:len(k)-1]+"Z") == k && !strings.HasSuffix(k, "Z") {
		t.Fatal("a bad checksum must fail")
	}
	if LicenseKeyHash(k) != lease.KeyHash(k) || LicenseKeyHash("nope") != "" {
		t.Fatal("hash")
	}
}
