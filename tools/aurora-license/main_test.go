package main

import (
	"crypto/ed25519"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/werx/aurora/corebridge/lease"
)

func TestSignOffline(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(nil)
	now := time.Unix(1_800_000_000, 0)
	tok, err := signOffline(priv, "KC", "", 30, now)
	if err != nil {
		t.Fatal(err)
	}
	c, err := lease.Verify(tok, map[string]ed25519.PublicKey{lease.KidAdmin: pub})
	if err != nil {
		t.Fatal(err)
	}
	if c.Sub != lease.SubOffline || c.Exp != now.Unix()+30*86400 || !c.Matches("KC", "x") {
		t.Fatalf("%+v", c)
	}
}

func TestKeygenRefusesRepo(t *testing.T) {
	repo := t.TempDir()
	os.Mkdir(filepath.Join(repo, ".git"), 0o755)
	t.Setenv("AURORA_KEYS_DIR", filepath.Join(repo, "keys"))
	if err := cmdKeygen(nil); err == nil {
		t.Fatal("keygen wrote keys inside a git repo")
	}
}

func TestKeygenFiles(t *testing.T) {
	dir := t.TempDir()
	if insideGitRepo(dir) {
		t.Skip("temp dir is inside a git repo")
	}
	t.Setenv("AURORA_KEYS_DIR", dir)
	if err := cmdKeygen(nil); err != nil {
		t.Fatal(err)
	}
	for _, kid := range []string{"admin", "server"} {
		priv, err := readKeyFile(kid + ".key")
		if err != nil {
			t.Fatal(err)
		}
		k, err := lease.DecodePrivate(priv)
		if err != nil {
			t.Fatal(err)
		}
		pubText, _ := readKeyFile(kid + ".pub")
		pub, err := lease.DecodePublic(pubText)
		if err != nil || !pub.Equal(k.Public()) {
			t.Fatal("public key does not match", kid)
		}
	}
	if err := cmdKeygen(nil); err == nil {
		t.Fatal("keygen overwrote keys without -force")
	}
}

func TestKeyRef(t *testing.T) {
	k, _ := lease.NewKey(nil)
	if m, err := keyRef(k); err != nil || m["key"] != k {
		t.Fatal(m, err)
	}
	if m, err := keyRef("ABCD1234"); err != nil || m["sub"] != "abcd1234" {
		t.Fatal(m, err)
	}
	if _, err := keyRef("nope"); err == nil {
		t.Fatal("accepted garbage")
	}
}
