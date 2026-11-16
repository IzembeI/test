package corebridge

import (
	"encoding/json"
	"errors"
	"log"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/werx/aurora/corebridge/lease"
)

// licenseRequired turns enforcement on. While false an invalid lease is only
// logged; the owner flips it once the license Worker is deployed or offline
// leases are issued.
const licenseRequired = false

const (
	// licenseGrace keeps the VPN working after a lease expires, for phones
	// that could not refresh (no network, server down).
	licenseGrace = 14 * 24 * time.Hour
	// licenseWarn is how long before expiry the app starts warning.
	licenseWarn = 5 * 24 * time.Hour
	// licenseClockFile keeps the largest time seen, against clock rollback.
	licenseClockFile = "license-clock"
)

var (
	licMu       sync.Mutex
	licToken    string
	licKC       string
	licIFV      string
	licDir      string
	licLastSeen int64 // Unix seconds; only a newer signed server time lowers it
	licTrustedT int64 // newest server time ("st") seen in a valid lease
	licSaved    int64 // licLastSeen as last written to the clock file
	licSavedT   int64 // licTrustedT as last written to the clock file
	// licPassed is set once Start accepted the lease in this process, so
	// restarts after network changes never stop a running VPN. SetLicense
	// clears it: the next Start of a new session checks again.
	licPassed bool

	// Overridden by tests.
	licRequired = licenseRequired
	licKeys     = lease.Trusted()
	licNow      = time.Now
)

type licenseState struct {
	Valid  bool   `json:"valid"`
	Warn   bool   `json:"warn"`
	Reason string `json:"reason"`
	// Exp and GraceUntil are Unix seconds (0 without a readable lease).
	Exp        int64 `json:"exp"`
	GraceUntil int64 `json:"graceUntil"`
	// DaysLeft counts to Exp; negative during the grace period.
	DaysLeft int    `json:"daysLeft"`
	Sub      string `json:"sub,omitempty"`
	Offline  bool   `json:"offline"`
	Required bool   `json:"required"`
}

// LicenseRequired reports whether Start refuses to run without a valid lease.
func LicenseRequired() bool { return licRequired }

// SetLicenseDir sets the folder for the small anti-rollback clock file.
func SetLicenseDir(dir string) {
	licMu.Lock()
	defer licMu.Unlock()
	setLicenseDirLocked(dir)
}

func setLicenseDirLocked(dir string) {
	if dir == "" || dir == licDir {
		return
	}
	licDir = dir
	b, err := os.ReadFile(filepath.Join(dir, licenseClockFile))
	if err != nil {
		return
	}
	// "lastSeen trustedServerTime"
	f := strings.Fields(string(b))
	if len(f) > 0 {
		if v, err := strconv.ParseInt(f[0], 10, 64); err == nil && v > licLastSeen {
			licLastSeen, licSaved = v, v
		}
	}
	if len(f) > 1 {
		if v, err := strconv.ParseInt(f[1], 10, 64); err == nil && v > licTrustedT {
			licTrustedT, licSavedT = v, v
		}
	}
}

// SetLicense stores the lease and the device ids (Keychain id and
// identifierForVendor). It returns "" when the lease is valid, otherwise the
// reason in Russian.
func SetLicense(token, kc, ifv string) string {
	licMu.Lock()
	defer licMu.Unlock()
	licToken = strings.TrimSpace(token)
	licKC = strings.TrimSpace(kc)
	licIFV = strings.TrimSpace(ifv)
	licPassed = false
	st := evaluateLicenseLocked()
	if st.Valid {
		return ""
	}
	return st.Reason
}

// LicenseStatus returns the state of the stored lease as JSON:
// {valid, warn, reason, exp, graceUntil, daysLeft, sub, offline, required}.
func LicenseStatus() string {
	licMu.Lock()
	defer licMu.Unlock()
	b, _ := json.Marshal(evaluateLicenseLocked())
	return string(b)
}

// licenseGate is called by Start. It returns "" to go on, or the reason to
// refuse.
func licenseGate(assetDir string) string {
	licMu.Lock()
	defer licMu.Unlock()
	if licDir == "" {
		setLicenseDirLocked(assetDir)
	}
	if licPassed {
		return ""
	}
	st := evaluateLicenseLocked()
	if st.Valid {
		licPassed = true
		return ""
	}
	if !licRequired {
		log.Printf("aurora: license not valid (not enforced): %s", st.Reason)
		return ""
	}
	return st.Reason
}

// licenseNowLocked is the current time, never earlier than a time already
// seen, so turning the clock back does not revive an expired lease.
// serverTime is the signed "st" of a valid lease: a newer one is trusted
// outright, which also undoes a clock that was once set far ahead.
func licenseNowLocked(serverTime int64) int64 {
	now := licNow().Unix()
	if serverTime > licTrustedT {
		licTrustedT = serverTime
		licLastSeen = serverTime
	}
	if now > licLastSeen {
		licLastSeen = now
	}
	// Write at most about once a minute of progress.
	if licDir != "" && (licLastSeen-licSaved >= 60 || licLastSeen < licSaved || licTrustedT != licSavedT) {
		text := strconv.FormatInt(licLastSeen, 10) + " " + strconv.FormatInt(licTrustedT, 10)
		if err := os.WriteFile(filepath.Join(licDir, licenseClockFile), []byte(text), 0o600); err == nil {
			licSaved, licSavedT = licLastSeen, licTrustedT
		}
	}
	return licLastSeen
}

func evaluateLicenseLocked() licenseState {
	st := licenseState{Required: licRequired}
	if licToken == "" {
		licenseNowLocked(0)
		st.Reason = "лицензия не активирована"
		return st
	}
	c, err := lease.Verify(licToken, licKeys)
	if err != nil {
		licenseNowLocked(0)
		switch {
		case errors.Is(err, lease.ErrUnknownKid):
			st.Reason = "лицензия подписана неизвестным ключом"
		case errors.Is(err, lease.ErrSignature):
			st.Reason = "подпись лицензии неверна"
		default:
			st.Reason = "лицензия повреждена"
		}
		return st
	}
	now := licenseNowLocked(c.St)
	st.Sub = c.Sub
	st.Offline = c.Sub == lease.SubOffline
	st.Exp = c.Exp
	st.GraceUntil = c.Exp + int64(licenseGrace/time.Second)
	st.DaysLeft = int(math.Ceil(float64(c.Exp-now) / 86400))
	if !c.Matches(licKC, licIFV) {
		st.Reason = "лицензия выдана для другого устройства"
		return st
	}
	switch {
	case now > st.GraceUntil:
		st.Reason = "срок лицензии истёк"
	case now > c.Exp:
		st.Valid = true
		st.Warn = true
		left := int(math.Ceil(float64(st.GraceUntil-now) / 86400))
		st.Reason = "срок лицензии истёк, VPN работает ещё " + strconv.Itoa(left) + " дн. — обновите лицензию"
	case c.Exp-now <= int64(licenseWarn/time.Second):
		st.Valid = true
		st.Warn = true
		st.Reason = "лицензия истекает через " + strconv.Itoa(st.DaysLeft) + " дн."
	default:
		st.Valid = true
	}
	return st
}
