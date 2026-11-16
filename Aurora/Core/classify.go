package corebridge

import (
	"crypto/tls"
	"encoding/json"
	"errors"
	"net"
	"strings"
	"sync"
	"time"
)

// Network classes, from what passes the operator directly.
const (
	netOpen         = "open"          // foreign sites reachable
	netWhitelistIP  = "whitelist-ip"  // only Russian addresses answer
	netWhitelistSNI = "whitelist-sni" // foreign addresses answer, but TLS only with a Russian SNI
	netDPI          = "dpi"           // TCP passes, TLS is cut whatever the SNI
	netOffline      = "offline"       // nothing answers
)

type probeTargets struct {
	ru       []string // Russian addresses (host:port)
	foreign  []string // foreign addresses
	tlsAddr  []string // foreign TLS servers that answer any SNI with a handshake or an alert
	ruSNI    string
	otherSNI string
}

var defaultTargets = probeTargets{
	ru:       []string{"77.88.8.8:443", "87.250.250.242:443"},
	foreign:  []string{"1.1.1.1:443", "8.8.8.8:443"},
	tlsAddr:  []string{"1.1.1.1:443", "8.8.8.8:443"},
	ruSNI:    "ya.ru",
	otherSNI: "www.google.com",
}

type netClass struct {
	Class    string `json:"class"`
	RU       bool   `json:"ru"`
	Foreign  bool   `json:"foreign"`
	SNIRU    bool   `json:"sniRU"`
	SNIOther bool   `json:"sniOther"`
	Detail   string `json:"detail"` // in Russian, for the UI
}

// ClassifyNetwork probes the network directly (through the interface set by
// SetTestInterface, so it works with the VPN on) and returns netClass JSON.
// It only touches a fixed list of public hosts: Yandex, Cloudflare and
// Google DNS addresses; nothing of the user's is sent.
func ClassifyNetwork(timeoutMs int) string {
	if timeoutMs <= 0 {
		timeoutMs = 3000
	}
	c := classify(defaultTargets, time.Duration(timeoutMs)*time.Millisecond, currentTestInterface())
	b, _ := json.Marshal(c)
	return string(b)
}

func classify(t probeTargets, timeout time.Duration, iface string) netClass {
	var c netClass
	var wg sync.WaitGroup
	wg.Add(4)
	go func() { defer wg.Done(); c.RU = anyTCP(t.ru, timeout, iface) }()
	go func() { defer wg.Done(); c.Foreign = anyTCP(t.foreign, timeout, iface) }()
	go func() { defer wg.Done(); c.SNIRU = anyTLS(t.tlsAddr, t.ruSNI, timeout, iface) }()
	go func() { defer wg.Done(); c.SNIOther = anyTLS(t.tlsAddr, t.otherSNI, timeout, iface) }()
	wg.Wait()
	switch {
	case !c.RU && !c.Foreign:
		c.Class, c.Detail = netOffline, "Нет ответа ни от российских, ни от зарубежных адресов: сети нет или связь глушат."
	case !c.Foreign:
		c.Class, c.Detail = netWhitelistIP, "Белые списки по IP: отвечают только российские адреса. Нужен сервер с адресом в РФ."
	case c.SNIOther:
		c.Class, c.Detail = netOpen, "Интернет открыт: зарубежные сайты доступны напрямую."
	case c.SNIRU:
		c.Class, c.Detail = netWhitelistSNI, "Белые списки по SNI: зарубежные адреса отвечают, но TLS проходит только с российским доменом. Нужен Reality с SNI российского сайта."
	default:
		c.Class, c.Detail = netDPI, "TCP проходит, но TLS обрывается при любом домене: работает DPI. Помогают Reality, XHTTP и фрагментация."
	}
	return c
}

// ReachableServers opens a TCP connection to the entry server of every
// member of a server set (BuildConfig options JSON) and returns how many
// answer, or -1 when there is nothing it can check (UDP-only servers). A
// cheap "is this set alive again" check before going back to it.
func ReachableServers(optionsJSON string, timeoutMs int) int {
	var o buildOptions
	if err := json.Unmarshal([]byte(optionsJSON), &o); err != nil {
		return -1
	}
	if timeoutMs <= 0 {
		timeoutMs = 3000
	}
	var all []map[string]any
	all = append(all, o.Outbounds...)
	for j, raw := range o.Configs {
		if main, deps, err := extractChain(raw, "dep"+itoa(j)+"-"); err == nil {
			all = append(all, main)
			all = append(all, deps...)
		}
	}
	entries := serverEntries(all)
	if len(entries) == 0 {
		return -1
	}
	timeout := time.Duration(timeoutMs) * time.Millisecond
	iface := currentTestInterface()
	var n int
	var mu sync.Mutex
	var wg sync.WaitGroup
	for _, e := range entries {
		wg.Add(1)
		go func(a string) {
			defer wg.Done()
			if anyTCP([]string{a}, timeout, iface) {
				mu.Lock()
				n++
				mu.Unlock()
			}
		}(e)
	}
	wg.Wait()
	return n
}

// serverEntries lists host:port of the servers the phone itself connects
// to: proxies that dial directly or through a freedom hop (fragment), not
// those that dial through another proxy.
func serverEntries(obs []map[string]any) []string {
	byTag := map[string]map[string]any{}
	for _, ob := range obs {
		if t := str(ob["tag"]); t != "" {
			byTag[t] = ob
		}
	}
	seen := map[string]bool{}
	var out []string
	for _, ob := range obs {
		if nonProxy[str(ob["protocol"])] || isUDPOnly(ob) {
			continue
		}
		if ss, ok := ob["streamSettings"].(map[string]any); ok {
			if so, ok := ss["sockopt"].(map[string]any); ok {
				if via := byTag[str(so["dialerProxy"])]; via != nil && !nonProxy[str(via["protocol"])] {
					continue
				}
			}
		}
		host, port := outboundEndpoint(ob)
		if host == "" || port <= 0 {
			continue
		}
		a := net.JoinHostPort(strings.Trim(host, "[]"), itoa(port))
		if !seen[a] {
			seen[a] = true
			out = append(out, a)
		}
	}
	return out
}

func dialer(timeout time.Duration, iface string) *net.Dialer {
	return &net.Dialer{Timeout: timeout, Control: interfaceControl(iface)}
}

// anyTCP reports whether a TCP connection opens to any of the addresses.
func anyTCP(addrs []string, timeout time.Duration, iface string) bool {
	return anyOf(addrs, func(a string) bool {
		c, err := dialer(timeout, iface).Dial("tcp", a)
		if err != nil {
			return false
		}
		_ = c.Close()
		return true
	})
}

// anyTLS reports whether a TLS ClientHello with this SNI gets any answer
// from a server: a full handshake or a TLS alert both mean the path let it
// through. A reset, a closed connection or silence mean it was cut.
func anyTLS(addrs []string, sni string, timeout time.Duration, iface string) bool {
	return anyOf(addrs, func(a string) bool {
		raw, err := dialer(timeout, iface).Dial("tcp", a)
		if err != nil {
			return false
		}
		defer raw.Close()
		_ = raw.SetDeadline(time.Now().Add(timeout))
		conn := tls.Client(raw, &tls.Config{ServerName: sni, InsecureSkipVerify: true}) // reachability only, nothing is sent
		err = conn.Handshake()
		return err == nil || isTLSAlert(err)
	})
}

func isTLSAlert(err error) bool {
	var alert tls.AlertError
	if errors.As(err, &alert) {
		return true
	}
	return strings.Contains(err.Error(), "remote error: tls:")
}

func anyOf(addrs []string, try func(string) bool) bool {
	res := make(chan bool, len(addrs))
	for _, a := range addrs {
		go func(a string) { res <- try(a) }(a)
	}
	for range addrs {
		if <-res {
			return true
		}
	}
	return false
}
