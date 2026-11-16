package lease

import (
	"bytes"
	"crypto/ed25519"
	"strings"
	"testing"
)

func testKey(t *testing.T, seed byte) (ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	priv := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{seed}, ed25519.SeedSize))
	return priv.Public().(ed25519.PublicKey), priv
}

func TestSignVerifyRoundtrip(t *testing.T) {
	pub, priv := testKey(t, 1)
	keys := map[string]ed25519.PublicKey{KidServer: pub}
	c := Claims{Kid: KidServer, Sub: "abcd1234", KC: "KC-1", IFV: "IFV-1", Iat: 100, Exp: 200, St: 100}
	tok, err := Sign(c, priv)
	if err != nil {
		t.Fatal(err)
	}
	got, err := Verify(tok, keys)
	if err != nil {
		t.Fatal(err)
	}
	c.V = Version
	if got != c {
		t.Fatalf("got %+v want %+v", got, c)
	}
	if strings.ContainsAny(tok, "+/=") {
		t.Fatal("token must be base64url without padding: " + tok)
	}
}

func TestVerifyRejects(t *testing.T) {
	pub, priv := testKey(t, 1)
	_, other := testKey(t, 2)
	keys := map[string]ed25519.PublicKey{KidServer: pub}
	tok, _ := Sign(Claims{Kid: KidServer, Sub: "x", KC: "a", Exp: 10}, priv)

	// Tampered payload: same signature, different claims.
	forged, _ := Sign(Claims{Kid: KidServer, Sub: "x", KC: "b", Exp: 99999}, priv)
	head, _, _ := strings.Cut(forged, ".")
	_, sig, _ := strings.Cut(tok, ".")
	if _, err := Verify(head+"."+sig, keys); err != ErrSignature {
		t.Fatalf("tampered: %v", err)
	}
	// Signed by a key that is not trusted under that kid.
	bad, _ := Sign(Claims{Kid: KidServer, Exp: 10}, other)
	if _, err := Verify(bad, keys); err != ErrSignature {
		t.Fatalf("wrong key: %v", err)
	}
	// Unknown kid.
	unk, _ := Sign(Claims{Kid: "someone", Exp: 10}, priv)
	if _, err := Verify(unk, keys); err != ErrUnknownKid {
		t.Fatalf("unknown kid: %v", err)
	}
	for _, s := range []string{"", "abc", "abc.", ".abc", "a.b.c", "!!!.???", head + ".AAAA"} {
		if _, err := Verify(s, keys); err == nil {
			t.Fatalf("accepted %q", s)
		}
	}
}

func TestMatches(t *testing.T) {
	c := Claims{KC: "kc-1", IFV: "IFV-1"}
	cases := []struct {
		kc, ifv string
		want    bool
	}{
		{"kc-1", "IFV-1", true},
		{"KC-1", "other", true},  // Keychain id alone
		{"other", "ifv-1", true}, // identifierForVendor alone
		{"other", "other", false},
		{"", "", false},
	}
	for _, x := range cases {
		if got := c.Matches(x.kc, x.ifv); got != x.want {
			t.Errorf("Matches(%q,%q)=%v", x.kc, x.ifv, got)
		}
	}
	if (Claims{}).Matches("", "") {
		t.Fatal("empty claims matched empty ids")
	}
}

func TestKeyFormat(t *testing.T) {
	for i := 0; i < 200; i++ {
		k, err := NewKey(nil)
		if err != nil {
			t.Fatal(err)
		}
		if len(k) != len("AUR-XXXXX-XXXXX-XXXXX-XXXXX") || !strings.HasPrefix(k, "AUR-") {
			t.Fatal(k)
		}
		n, ok := NormalizeKey(k)
		if !ok || n != k {
			t.Fatalf("normalize %q -> %q %v", k, n, ok)
		}
		// Lower case, no dashes, no prefix, spaces.
		loose := strings.ToLower(strings.ReplaceAll(strings.TrimPrefix(k, "AUR-"), "-", " "))
		if n, ok := NormalizeKey(loose); !ok || n != k {
			t.Fatalf("loose %q -> %q %v", loose, n, ok)
		}
	}
}

func TestKeyChecksum(t *testing.T) {
	k, _ := NewKey(bytes.NewReader(bytes.Repeat([]byte{7}, 32)))
	if !ValidKey(k) {
		t.Fatal(k)
	}
	// Any single-character change in the data part must be caught, or at
	// least almost always: check every substitution and allow 1/1024 luck.
	raw := []byte(k)
	misses, total := 0, 0
	for i, c := range raw {
		if c == '-' || i < 4 {
			continue
		}
		for _, r := range []byte(Alphabet) {
			if r == c {
				continue
			}
			mod := append([]byte(nil), raw...)
			mod[i] = r
			total++
			if ValidKey(string(mod)) {
				misses++
			}
		}
	}
	if misses*100 > total {
		t.Fatalf("checksum too weak: %d/%d", misses, total)
	}
	// Look-alikes are read as digits.
	alike := strings.ReplaceAll(strings.ReplaceAll(k, "0", "O"), "1", "I")
	if n, ok := NormalizeKey(alike); !ok || n != k {
		t.Fatalf("look-alikes: %q", alike)
	}
	for _, bad := range []string{"", "AUR-", "AUR-AAAAA-AAAAA-AAAAA-AAAA", k + "0", "AUR-UUUUU-UUUUU-UUUUU-UUUUU"} {
		if ValidKey(bad) {
			t.Fatalf("accepted %q", bad)
		}
	}
	if KeySub(k) != KeyHash(k)[:8] || KeyHash(strings.ToLower(k)) != KeyHash(k) {
		t.Fatal("hash of normalized key")
	}
}

func TestKeyEncoding(t *testing.T) {
	pub, priv := testKey(t, 3)
	s, err := EncodePrivate(priv)
	if err != nil {
		t.Fatal(err)
	}
	back, err := DecodePrivate(s)
	if err != nil || !back.Equal(priv) {
		t.Fatal("private roundtrip", err)
	}
	p, err := DecodePublic(EncodePublic(pub))
	if err != nil || !p.Equal(pub) {
		t.Fatal("public roundtrip", err)
	}
	if _, err := DecodePublic("short"); err == nil {
		t.Fatal("bad public accepted")
	}
}

// Known answer: the checksum algorithm is repeated in the Worker (JS) and the
// app (Swift); this pins it so a change here is noticed.
func TestKeyChecksumKnownAnswer(t *testing.T) {
	k, _ := NewKey(bytes.NewReader(make([]byte, 32)))
	if k != "AUR-00000-00000-00000-0003F" {
		t.Fatal(k)
	}
	if KeyHash(k)[:8] != KeySub(k) {
		t.Fatal("sub")
	}
}
