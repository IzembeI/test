package corebridge

import (
	"bytes"
	"crypto/ed25519"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/werx/aurora/corebridge/lease"
)

const day = int64(86400)

var (
	testServerKey = ed25519.NewKeyFromSeed(bytes.Repeat([]byte{11}, ed25519.SeedSize))
	testAdminKey  = ed25519.NewKeyFromSeed(bytes.Repeat([]byte{22}, ed25519.SeedSize))
	testOtherKey  = ed25519.NewKeyFromSeed(bytes.Repeat([]byte{33}, ed25519.SeedSize))
)

// withLicenseEnv resets the license globals around a test, with test keys
// and a fake clock at *now.
func withLicenseEnv(t *testing.T, now *int64) {
	t.Helper()
	licMu.Lock()
	saved := struct {
		token, kc, ifv, dir    string
		seen, trusted, sv, svT int64
		passed, required       bool
		keys                   map[string]ed25519.PublicKey
		clock                  func() time.Time
	}{licToken, licKC, licIFV, licDir, licLastSeen, licTrustedT, licSaved, licSavedT, licPassed, licRequired, licKeys, licNow}
	licToken, licKC, licIFV, licDir = "", "", "", ""
	licLastSeen, licTrustedT, licSaved, licSavedT = 0, 0, 0, 0
	licPassed, licRequired = false, false
	licKeys = map[string]ed25519.PublicKey{
		lease.KidServer: testServerKey.Public().(ed25519.PublicKey),
		lease.KidAdmin:  testAdminKey.Public().(ed25519.PublicKey),
	}
	licNow = func() time.Time { return time.Unix(*now, 0) }
	licMu.Unlock()
	t.Cleanup(func() {
		licMu.Lock()
		licToken, licKC, licIFV, licDir = saved.token, saved.kc, saved.ifv, saved.dir
		licLastSeen, licTrustedT, licSaved, licSavedT = saved.seen, saved.trusted, saved.sv, saved.svT
		licPassed, licRequired, licKeys, licNow = saved.passed, saved.required, saved.keys, saved.clock
		licMu.Unlock()
	})
}

func mkLease(t *testing.T, key ed25519.PrivateKey, kid string, iat, exp int64, kc, ifv string) string {
	t.Helper()
	tok, err := lease.Sign(lease.Claims{Kid: kid, Sub: "abcd1234", KC: kc, IFV: ifv, Iat: iat, Exp: exp, St: iat}, key)
	if err != nil {
		t.Fatal(err)
	}
	return tok
}

func status(t *testing.T) licenseState {
	t.Helper()
	var st licenseState
	if err := json.Unmarshal([]byte(LicenseStatus()), &st); err != nil {
		t.Fatal(err)
	}
	return st
}

func TestLicenseValidAndWarn(t *testing.T) {
	now := int64(1_800_000_000)
	withLicenseEnv(t, &now)
	tok := mkLease(t, testServerKey, lease.KidServer, now, now+30*day, "KC", "IFV")
	if r := SetLicense(tok, "KC", "IFV"); r != "" {
		t.Fatal(r)
	}
	st := status(t)
	if !st.Valid || st.Warn || st.DaysLeft != 30 || st.Exp != now+30*day || st.GraceUntil != now+44*day || st.Reason != "" {
		t.Fatalf("%+v", st)
	}
	// Last 5 days before expiry: still valid, with a warning.
	now += 26 * day
	st = status(t)
	if !st.Valid || !st.Warn || st.DaysLeft != 4 || !strings.Contains(st.Reason, "истекает через 4") {
		t.Fatalf("%+v", st)
	}
}

func TestLicenseGrace(t *testing.T) {
	now := int64(1_800_000_000)
	withLicenseEnv(t, &now)
	tok := mkLease(t, testServerKey, lease.KidServer, now, now+30*day, "KC", "IFV")
	SetLicense(tok, "KC", "IFV")
	// Expired 3 days ago: inside the 14-day grace period.
	now += 33 * day
	st := status(t)
	if !st.Valid || !st.Warn || st.DaysLeft != -3 || !strings.Contains(st.Reason, "ещё 11 дн.") {
		t.Fatalf("%+v", st)
	}
	if r := SetLicense(tok, "KC", "IFV"); r != "" {
		t.Fatal("grace must still be valid:", r)
	}
	// Beyond the grace period.
	now += 12 * day
	st = status(t)
	if st.Valid || st.Reason != "срок лицензии истёк" {
		t.Fatalf("%+v", st)
	}
	if r := SetLicense(tok, "KC", "IFV"); r != "срок лицензии истёк" {
		t.Fatal(r)
	}
}

func TestLicenseDevice(t *testing.T) {
	now := int64(1_800_000_000)
	withLicenseEnv(t, &now)
	tok := mkLease(t, testServerKey, lease.KidServer, now, now+30*day, "KC", "IFV")
	if r := SetLicense(tok, "other", "other"); r != "лицензия выдана для другого устройства" {
		t.Fatal(r)
	}
	// One of the two ids is enough.
	if r := SetLicense(tok, "KC", "new-ifv-after-reinstall"); r != "" {
		t.Fatal(r)
	}
	if r := SetLicense(tok, "new-keychain", "ifv"); r != "" {
		t.Fatal("ifv is case-insensitive:", r)
	}
}

func TestLicenseBadTokens(t *testing.T) {
	now := int64(1_800_000_000)
	withLicenseEnv(t, &now)
	if r := SetLicense("", "KC", "IFV"); r != "лицензия не активирована" {
		t.Fatal(r)
	}
	if r := SetLicense("garbage", "KC", "IFV"); r != "лицензия повреждена" {
		t.Fatal(r)
	}
	// Offline lease signed with the admin key is accepted.
	adm := mkLease(t, testAdminKey, lease.KidAdmin, now, now+30*day, "KC", "")
	if r := SetLicense(adm, "KC", ""); r != "" {
		t.Fatal(r)
	}
	// Admin key claiming to be the server: bad signature.
	fake := mkLease(t, testAdminKey, lease.KidServer, now, now+30*day, "KC", "IFV")
	if r := SetLicense(fake, "KC", "IFV"); r != "подпись лицензии неверна" {
		t.Fatal(r)
	}
	unk := mkLease(t, testOtherKey, "someone", now, now+30*day, "KC", "IFV")
	if r := SetLicense(unk, "KC", "IFV"); r != "лицензия подписана неизвестным ключом" {
		t.Fatal(r)
	}
	// Tampered payload keeps the old signature.
	tok := mkLease(t, testServerKey, lease.KidServer, now, now+1*day, "KC", "IFV")
	longer := mkLease(t, testServerKey, lease.KidServer, now, now+999*day, "KC", "IFV")
	head, _, _ := strings.Cut(longer, ".")
	_, sig, _ := strings.Cut(tok, ".")
	if r := SetLicense(head+"."+sig, "KC", "IFV"); r != "подпись лицензии неверна" {
		t.Fatal(r)
	}
}

func TestLicenseClockRollback(t *testing.T) {
	now := int64(1_800_000_000)
	withLicenseEnv(t, &now)
	dir := t.TempDir()
	SetLicenseDir(dir)
	issued := now
	tok := mkLease(t, testServerKey, lease.KidServer, issued, issued+30*day, "KC", "IFV")
	SetLicense(tok, "KC", "IFV")
	// Time passes beyond the grace period...
	now = issued + 50*day
	if st := status(t); st.Valid {
		t.Fatalf("%+v", st)
	}
	// ...then the clock is turned back to the day of issue.
	now = issued + 1*day
	if st := status(t); st.Valid || st.DaysLeft != -20 {
		t.Fatalf("rollback revived the lease: %+v", st)
	}
	// A new process (fresh memory) reads the saved clock.
	b, err := os.ReadFile(filepath.Join(dir, licenseClockFile))
	if err != nil || !strings.HasPrefix(string(b), "1804320000 ") {
		t.Fatalf("clock file %q %v", b, err)
	}
	licMu.Lock()
	licLastSeen, licTrustedT, licSaved, licSavedT, licDir = 0, 0, 0, 0, ""
	licMu.Unlock()
	SetLicenseDir(dir)
	if r := SetLicense(tok, "KC", "IFV"); r != "срок лицензии истёк" {
		t.Fatal("after restart:", r)
	}
	// A fresh lease with a newer server time is trusted and works.
	fresh := mkLease(t, testServerKey, lease.KidServer, issued+50*day, issued+80*day, "KC", "IFV")
	if r := SetLicense(fresh, "KC", "IFV"); r != "" {
		t.Fatal(r)
	}
	// The server time inside a lease also moves a clock that lags behind.
	if st := status(t); st.DaysLeft != 30 {
		t.Fatalf("%+v", st)
	}
}

func TestLicenseStatusJSON(t *testing.T) {
	now := int64(1_800_000_000)
	withLicenseEnv(t, &now)
	SetLicense("", "", "")
	var m map[string]any
	if err := json.Unmarshal([]byte(LicenseStatus()), &m); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"valid", "reason", "exp", "graceUntil", "daysLeft", "warn", "required"} {
		if _, ok := m[k]; !ok {
			t.Errorf("missing %q in %v", k, m)
		}
	}
	if m["valid"] != false || m["reason"] != "лицензия не активирована" {
		t.Fatal(m)
	}
}

func TestStartLicenseGate(t *testing.T) {
	now := time.Now().Unix()
	withLicenseEnv(t, &now)
	SetLicense("", "KC", "IFV")

	// Not enforced: Start runs with an invalid lease.
	if e := Start(cfg, -1, ""); e != "" {
		t.Fatal(e)
	}
	Stop()

	// Enforced: Start refuses.
	licMu.Lock()
	licRequired = true
	licMu.Unlock()
	if !LicenseRequired() {
		t.Fatal("LicenseRequired")
	}
	if e := Start(cfg, -1, ""); e != "license: лицензия не активирована" {
		t.Fatal(e)
	}
	if IsRunning() {
		t.Fatal("running without a license")
	}

	// Enforced with a valid lease: runs; a restart after expiry keeps going.
	SetLicense(mkLease(t, testServerKey, lease.KidServer, now, now+30*day, "KC", "IFV"), "KC", "IFV")
	if e := Start(cfg, -1, ""); e != "" {
		t.Fatal(e)
	}
	now += 100 * day
	if e := Start(cfg, -1, ""); e != "" {
		t.Fatal("restart of a running tunnel must not check again:", e)
	}
	Stop()
	// A new session (SetLicense again) is checked.
	SetLicense(licToken, "KC", "IFV")
	if e := Start(cfg, -1, ""); !strings.HasPrefix(e, "license: ") {
		t.Fatal(e)
	}
}
