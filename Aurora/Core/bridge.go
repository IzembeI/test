// Package corebridge is the small surface the iOS app and its packet tunnel
// use to drive Xray-core. Every function returns plain strings or numbers so
// the gomobile binding stays simple: an empty error string means success.
package corebridge

import (
	"encoding/json"
	"os"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/stats"
	_ "github.com/xtls/xray-core/main/distro/all"
)

var (
	mu       sync.Mutex
	instance *core.Instance
	freeStop chan struct{}
	started  time.Time
)

// SetAssetDir points Xray at the folder holding geoip.dat / geosite.dat.
func SetAssetDir(dir string) {
	if dir == "" {
		return
	}
	os.Setenv("xray.location.asset", dir)
	os.Setenv("XRAY_LOCATION_ASSET", dir)
}

// SetMemoryLimit caps the Go heap (in MB) and makes the GC aggressive, which
// keeps the tunnel under the Network Extension memory ceiling.
func SetMemoryLimit(megabytes int) {
	if megabytes <= 0 {
		return
	}
	debug.SetGCPercent(10)
	debug.SetMemoryLimit(int64(megabytes) * 1024 * 1024)
}

// Start launches Xray with the given JSON config. tunFd is the utun file
// descriptor of the packet tunnel, or a negative number for no TUN.
func Start(configJSON string, tunFd int, assetDir string) string {
	mu.Lock()
	defer mu.Unlock()
	if instance != nil {
		_ = instance.Close()
		instance = nil
	}
	SetAssetDir(assetDir)
	if tunFd >= 0 {
		v := strconv.Itoa(tunFd)
		os.Setenv("xray.tun.fd", v)
		os.Setenv("XRAY_TUN_FD", v)
	} else {
		os.Unsetenv("xray.tun.fd")
		os.Unsetenv("XRAY_TUN_FD")
	}
	cfg, err := core.LoadConfig("json", strings.NewReader(configJSON))
	if err != nil {
		return "config: " + err.Error()
	}
	inst, err := core.New(cfg)
	if err != nil {
		return "init: " + err.Error()
	}
	if err := inst.Start(); err != nil {
		_ = inst.Close()
		return "start: " + err.Error()
	}
	instance = inst
	started = time.Now()
	startFreeLoop()
	debug.FreeOSMemory()
	return ""
}

func startFreeLoop() {
	if freeStop != nil {
		return
	}
	stop := make(chan struct{})
	freeStop = stop
	go func() {
		t := time.NewTicker(2 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-stop:
				return
			case <-t.C:
				debug.FreeOSMemory()
			}
		}
	}()
}

// Stop shuts Xray down.
func Stop() string {
	mu.Lock()
	defer mu.Unlock()
	if freeStop != nil {
		close(freeStop)
		freeStop = nil
	}
	if instance == nil {
		return ""
	}
	err := instance.Close()
	instance = nil
	debug.FreeOSMemory()
	if err != nil {
		return err.Error()
	}
	return ""
}

// IsRunning reports whether an instance is up.
func IsRunning() bool {
	mu.Lock()
	defer mu.Unlock()
	return instance != nil && instance.IsRunning()
}

// Version returns the Xray-core version.
func Version() string { return core.Version() }

// Validate checks that a config parses and builds, without starting it.
func Validate(configJSON string) string {
	cfg, err := core.LoadConfig("json", strings.NewReader(configJSON))
	if err != nil {
		return err.Error()
	}
	inst, err := core.New(cfg)
	if err != nil {
		return err.Error()
	}
	_ = inst.Close()
	return ""
}

type trafficSnapshot struct {
	Up       int64            `json:"up"`
	Down     int64            `json:"down"`
	DirectUp int64            `json:"directUp"`
	DirectDn int64            `json:"directDown"`
	Uptime   int64            `json:"uptime"`
	Memory   uint64           `json:"memory"`
	Tags     map[string]int64 `json:"tags"`
}

// Stats returns cumulative traffic as JSON. Traffic of outbounds tagged
// "direct" and "block" is reported apart from the proxied traffic.
func Stats() string {
	mu.Lock()
	inst := instance
	start := started
	mu.Unlock()
	snap := trafficSnapshot{Tags: map[string]int64{}}
	if inst != nil {
		if m, ok := inst.GetFeature(stats.ManagerType()).(stats.Manager); ok && m != nil {
			m.VisitCounters(func(name string, c stats.Counter) bool {
				// outbound>>>TAG>>>traffic>>>uplink
				parts := strings.Split(name, ">>>")
				if len(parts) != 4 || parts[0] != "outbound" {
					return true
				}
				v := c.Value()
				snap.Tags[parts[1]+":"+parts[3]] = v
				direct := parts[1] == "direct" || parts[1] == "block" || parts[1] == "dns-out"
				switch {
				case parts[3] == "uplink" && direct:
					snap.DirectUp += v
				case parts[3] == "downlink" && direct:
					snap.DirectDn += v
				case parts[3] == "uplink":
					snap.Up += v
				case parts[3] == "downlink":
					snap.Down += v
				}
				return true
			})
		}
		snap.Uptime = int64(time.Since(start).Seconds())
	}
	snap.Memory = residentMemory()
	b, _ := json.Marshal(snap)
	return string(b)
}

// FreeMemory returns unused memory to the system right away.
func FreeMemory() { debug.FreeOSMemory() }
