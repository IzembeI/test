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

// TCPPing measures the time to open a TCP connection, in milliseconds,
// or -1 when it fails.
func TCPPing(host string, port int, timeoutMs int) int {
	if timeoutMs <= 0 {
		timeoutMs = 3000
	}
	start := time.Now()
	c, err := net.DialTimeout("tcp", net.JoinHostPort(host, strconv.Itoa(port)), time.Duration(timeoutMs)*time.Millisecond)
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
	for i, ob := range outbounds {
		if !usable[i] {
			continue
		}
		tag := "t" + strconv.Itoa(i)
		copyOb := map[string]any{}
		for k, v := range ob {
			copyOb[k] = v
		}
		copyOb["tag"] = tag
		// Chained outbounds (dialerProxy) are not supported in a test.
		if ss, ok := copyOb["streamSettings"].(map[string]any); ok {
			if so, ok := ss["sockopt"].(map[string]any); ok {
				delete(so, "dialerProxy")
			}
		}
		outs = append(outs, copyOb)
		inbounds = append(inbounds, map[string]any{
			"tag": "in" + strconv.Itoa(i), "listen": "127.0.0.1", "port": ports[i], "protocol": "socks",
			"settings": map[string]any{"udp": false, "auth": "noauth"},
		})
		rules = append(rules, map[string]any{"type": "field", "inboundTag": []string{"in" + strconv.Itoa(i)}, "outboundTag": tag})
	}
	outs = append(outs, map[string]any{"tag": "direct", "protocol": "freedom"})
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
