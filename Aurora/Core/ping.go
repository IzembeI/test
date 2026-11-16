package corebridge

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/xtls/xray-core/core"
)

var (
	testIfaceMu sync.RWMutex
	testIface   string
)

// SetTestInterface makes server tests leave through this network interface
// (en0 for Wi-Fi, pdp_ip0 for cellular) instead of the default route. While
// the VPN is on, the default route is the tunnel itself, so without this a
// test would measure "through the current server" and could call a server
// alive that is not reachable directly. An empty name restores the default.
func SetTestInterface(name string) {
	testIfaceMu.Lock()
	testIface = strings.TrimSpace(name)
	testIfaceMu.Unlock()
}

func currentTestInterface() string {
	testIfaceMu.RLock()
	defer testIfaceMu.RUnlock()
	return testIface
}

// bindToInterface sets sockopt.interface on an outbound that dials on its
// own. Outbounds that dial through another one (dialerProxy) are left alone:
// the one they dial through is bound instead.
func bindToInterface(ob map[string]any, iface string) {
	if iface == "" || ob == nil {
		return
	}
	switch str(ob["protocol"]) {
	case "blackhole", "dns", "loopback":
		return
	}
	so := sockoptOf(ob)
	if _, chained := so["dialerProxy"]; chained {
		return
	}
	if _, set := so["interface"]; !set {
		so["interface"] = iface
	}
}

// TCPPing measures the time to open a TCP connection, in milliseconds,
// or -1 when it fails.
func TCPPing(host string, port int, timeoutMs int) int {
	if timeoutMs <= 0 {
		timeoutMs = 3000
	}
	start := time.Now()
	d := net.Dialer{Timeout: time.Duration(timeoutMs) * time.Millisecond, Control: interfaceControl(currentTestInterface())}
	c, err := d.Dial("tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		return -1
	}
	_ = c.Close()
	ms := int(time.Since(start).Milliseconds())
	if ms < 1 {
		ms = 1
	}
	return ms
}

func freePorts(n int) ([]int, error) {
	ports := make([]int, 0, n)
	listeners := make([]net.Listener, 0, n)
	defer func() {
		for _, l := range listeners {
			_ = l.Close()
		}
	}()
	for i := 0; i < n; i++ {
		l, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			return nil, err
		}
		listeners = append(listeners, l)
		ports = append(ports, l.Addr().(*net.TCPAddr).Port)
	}
	return ports, nil
}

// URLTest measures the real delay through every outbound: one Xray instance
// is started with a local SOCKS inbound per outbound, and an HTTP request to
// testURL goes through each of them. outboundsJSON is a JSON array of Xray
// outbound objects (their own tags are replaced). The result is a JSON array
// of delays in milliseconds, -1 for a failure, in the same order.
func URLTest(outboundsJSON string, testURL string, timeoutMs int, concurrency int) string {
	var outbounds []map[string]any
	if err := json.Unmarshal([]byte(outboundsJSON), &outbounds); err != nil {
		return "[]"
	}
	results := make([]int, len(outbounds))
	for i := range results {
		results[i] = -1
	}
	if len(outbounds) == 0 {
		return "[]"
	}
	if testURL == "" {
		testURL = "https://www.gstatic.com/generate_204"
	}
	if timeoutMs <= 0 {
		timeoutMs = 6000
	}
	if concurrency <= 0 {
		concurrency = 8
	}
	ports, err := freePorts(len(outbounds))
	if err != nil {
		return encodeInts(results)
	}

	// Build one config, skipping outbounds Xray refuses, one by one if needed.
	usable := make([]bool, len(outbounds))
	for i := range usable {
		usable[i] = true
	}
	var inst *core.Instance
	for attempt := 0; attempt <= len(outbounds); attempt++ {
		cfgJSON := buildTestConfig(outbounds, ports, usable)
		cfg, err := core.LoadConfig("json", strings.NewReader(cfgJSON))
		if err == nil {
			inst, err = core.New(cfg)
		}
		if err == nil {
			if err = inst.Start(); err == nil {
				break
			}
			_ = inst.Close()
			inst = nil
		}
		// Find the outbound that breaks the config and drop it.
		bad := -1
		for i := range outbounds {
			if !usable[i] {
				continue
			}
			only := make([]bool, len(outbounds))
			only[i] = true
			if _, e := core.LoadConfig("json", strings.NewReader(buildTestConfig(outbounds, ports, only))); e != nil {
				bad = i
				break
			}
		}
		if bad < 0 {
			return encodeInts(results)
		}
		usable[bad] = false
	}
	if inst == nil {
		return encodeInts(results)
	}
	defer inst.Close()

	sem := make(chan struct{}, concurrency)
	var wg sync.WaitGroup
	for i := range outbounds {
		if !usable[i] {
			continue
		}
		wg.Add(1)
		sem <- struct{}{}
		go func(i int) {
			defer wg.Done()
			defer func() { <-sem }()
			results[i] = measure(testURL, ports[i], timeoutMs)
		}(i)
	}
	wg.Wait()
	return encodeInts(results)
}

func buildTestConfig(outbounds []map[string]any, ports []int, usable []bool) string {
	inbounds := []map[string]any{}
	outs := []map[string]any{}
	rules := []map[string]any{}
	iface := currentTestInterface()
	for i, ob := range outbounds {
		if !usable[i] {
			continue
		}
		tag := "t" + strconv.Itoa(i)
		// A deep copy, so the caller's outbound stays as it was.
		copyOb := clone(ob)
		copyOb["tag"] = tag
		// Chained outbounds (dialerProxy) are not supported in a test.
		if ss, ok := copyOb["streamSettings"].(map[string]any); ok {
			if so, ok := ss["sockopt"].(map[string]any); ok {
				delete(so, "dialerProxy")
			}
		}
		bindToInterface(copyOb, iface)
		outs = append(outs, copyOb)
		inbounds = append(inbounds, map[string]any{
			"tag": "in" + strconv.Itoa(i), "listen": "127.0.0.1", "port": ports[i], "protocol": "socks",
			"settings": map[string]any{"udp": false, "auth": "noauth"},
		})
		rules = append(rules, map[string]any{"type": "field", "inboundTag": []string{"in" + strconv.Itoa(i)}, "outboundTag": tag})
	}
	direct := map[string]any{"tag": "direct", "protocol": "freedom"}
	bindToInterface(direct, iface)
	outs = append(outs, direct)
	cfg := map[string]any{
		"log":       map[string]any{"loglevel": "none"},
		"inbounds":  inbounds,
		"outbounds": outs,
		"routing":   map[string]any{"rules": rules},
	}
	b, _ := json.Marshal(cfg)
	return string(b)
}

func measure(testURL string, port int, timeoutMs int) int {
	proxy, _ := url.Parse("socks5://127.0.0.1:" + strconv.Itoa(port))
	tr := &http.Transport{Proxy: http.ProxyURL(proxy), DisableKeepAlives: true}
	defer tr.CloseIdleConnections()
	client := &http.Client{Transport: tr, Timeout: time.Duration(timeoutMs) * time.Millisecond}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, testURL, nil)
	if err != nil {
		return -1
	}
	start := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		return -1
	}
	_ = resp.Body.Close()
	ms := int(time.Since(start).Milliseconds())
	if ms < 1 {
		ms = 1
	}
	return ms
}

func encodeInts(v []int) string {
	b, _ := json.Marshal(v)
	return string(b)
}

type testItem struct {
	Outbound map[string]any `json:"outbound"`
	Config   string         `json:"config"`
}

type testResult struct {
	Delay int    `json:"delay"`
	Error string `json:"error,omitempty"`
}

// URLTestDetailed tests a JSON array of items: {"outbound": {...}} for a
// single outbound, or {"config": "<full Xray JSON>"} which is run as a whole
// (its own routing, balancers and chains). The result is a JSON array of
// {"delay": ms or -1, "error": "..."} in the same order.
func URLTestDetailed(itemsJSON string, testURL string, timeoutMs int, concurrency int) string {
	var items []testItem
	if err := json.Unmarshal([]byte(itemsJSON), &items); err != nil {
		return "[]"
	}
	if testURL == "" {
		testURL = "https://www.gstatic.com/generate_204"
	}
	if timeoutMs <= 0 {
		timeoutMs = 6000
	}
	if concurrency <= 0 {
		concurrency = 6
	}
	results := make([]testResult, len(items))
	sem := make(chan struct{}, concurrency)
	var wg sync.WaitGroup
	for i, it := range items {
		wg.Add(1)
		sem <- struct{}{}
		go func(i int, it testItem) {
			defer wg.Done()
			defer func() { <-sem }()
			results[i] = testOne(it, testURL, timeoutMs)
		}(i, it)
	}
	wg.Wait()
	b, _ := json.Marshal(results)
	return string(b)
}

func testOne(it testItem, testURL string, timeoutMs int) testResult {
	ports, err := freePorts(1)
	if err != nil {
		return testResult{Delay: -1, Error: err.Error()}
	}
	var cfgJSON string
	if strings.TrimSpace(it.Config) != "" {
		cfgJSON, err = wrapFullConfig(it.Config, ports[0])
		if err != nil {
			return testResult{Delay: -1, Error: err.Error()}
		}
	} else if it.Outbound != nil {
		cfgJSON = buildTestConfig([]map[string]any{it.Outbound}, ports, []bool{true})
	} else {
		return testResult{Delay: -1, Error: "empty item"}
	}
	cfg, err := core.LoadConfig("json", strings.NewReader(cfgJSON))
	if err != nil {
		return testResult{Delay: -1, Error: "config: " + err.Error()}
	}
	inst, err := core.New(cfg)
	if err != nil {
		return testResult{Delay: -1, Error: "init: " + err.Error()}
	}
	if err := inst.Start(); err != nil {
		_ = inst.Close()
		return testResult{Delay: -1, Error: "start: " + err.Error()}
	}
	defer inst.Close()
	ms, err := measureErr(testURL, ports[0], timeoutMs)
	if err != nil {
		return testResult{Delay: -1, Error: err.Error()}
	}
	return testResult{Delay: ms}
}

// wrapFullConfig replaces the inbounds of a full config with one local SOCKS
// inbound and keeps everything else, so traffic follows the config's own
// routing. Logs, stats and APIs are dropped.
func wrapFullConfig(raw string, port int) (string, error) {
	var cfg map[string]any
	if err := json.Unmarshal([]byte(raw), &cfg); err != nil {
		return "", err
	}
	cfg["inbounds"] = []any{map[string]any{"tag": "test-in", "listen": "127.0.0.1", "port": port, "protocol": "socks",
		"settings": map[string]any{"udp": false, "auth": "noauth"},
		"sniffing": map[string]any{"enabled": true, "destOverride": []string{"http", "tls"}, "routeOnly": true}}}
	cfg["log"] = map[string]any{"loglevel": "none"}
	for _, k := range []string{"api", "stats", "metrics", "reverse"} {
		delete(cfg, k)
	}
	if iface := currentTestInterface(); iface != "" {
		if obs, ok := cfg["outbounds"].([]any); ok {
			for _, o := range obs {
				if m, ok := o.(map[string]any); ok {
					bindToInterface(m, iface)
				}
			}
		}
	}
	// Rules bound to inbound tags of the original config would never match
	// the test inbound; keep them, they are harmless.
	b, err := json.Marshal(cfg)
	return string(b), err
}

func measureErr(testURL string, port int, timeoutMs int) (int, error) {
	proxy, _ := url.Parse("socks5://127.0.0.1:" + strconv.Itoa(port))
	tr := &http.Transport{Proxy: http.ProxyURL(proxy), DisableKeepAlives: true}
	defer tr.CloseIdleConnections()
	client := &http.Client{Transport: tr, Timeout: time.Duration(timeoutMs) * time.Millisecond}
	req, err := http.NewRequest(http.MethodGet, testURL, nil)
	if err != nil {
		return -1, err
	}
	start := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		msg := err.Error()
		if i := strings.LastIndex(msg, ": "); i >= 0 && len(msg) > 160 {
			msg = msg[i+2:]
		}
		return -1, errString(msg)
	}
	_ = resp.Body.Close()
	ms := int(time.Since(start).Milliseconds())
	if ms < 1 {
		ms = 1
	}
	return ms, nil
}
