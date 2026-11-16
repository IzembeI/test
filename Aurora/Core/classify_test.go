package corebridge

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"math/big"
	"net"
	"testing"
	"time"
)

func selfSigned(t *testing.T) tls.Certificate {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour)}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
}

// tlsServer answers TLS, but drops the connection without a word when the
// SNI is in cut, the way a censor's DPI does.
func tlsServer(t *testing.T, cut map[string]bool) string {
	cert := selfSigned(t)
	cfg := &tls.Config{Certificates: []tls.Certificate{cert}, GetConfigForClient: func(h *tls.ClientHelloInfo) (*tls.Config, error) {
		if cut[h.ServerName] {
			_ = h.Conn.Close()
		}
		return nil, nil
	}}
	l, err := tls.Listen("tcp", "127.0.0.1:0", cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func() { _ = c.(*tls.Conn).Handshake(); c.Close() }()
		}
	}()
	return l.Addr().String()
}

func tcpServer(t *testing.T) string {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			c.Close()
		}
	}()
	return l.Addr().String()
}

// closedAddr is an address where nothing listens.
func closedAddr(t *testing.T) string {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	a := l.Addr().String()
	l.Close()
	return a
}

func TestClassify(t *testing.T) {
	ru, dead := tcpServer(t), closedAddr(t)
	open := tlsServer(t, nil)
	sniCut := tlsServer(t, map[string]bool{"www.google.com": true})
	allCut := tlsServer(t, map[string]bool{"www.google.com": true, "ya.ru": true})
	for _, c := range []struct {
		name string
		t    probeTargets
		want string
	}{
		{"open", probeTargets{ru: []string{ru}, foreign: []string{open}, tlsAddr: []string{open}}, netOpen},
		{"whitelist by IP", probeTargets{ru: []string{ru}, foreign: []string{dead}, tlsAddr: []string{dead}}, netWhitelistIP},
		{"whitelist by SNI", probeTargets{ru: []string{ru}, foreign: []string{sniCut}, tlsAddr: []string{sniCut}}, netWhitelistSNI},
		{"DPI", probeTargets{ru: []string{ru}, foreign: []string{allCut}, tlsAddr: []string{allCut}}, netDPI},
		{"offline", probeTargets{ru: []string{dead}, foreign: []string{dead}, tlsAddr: []string{dead}}, netOffline},
		{"one of two answers", probeTargets{ru: []string{dead, ru}, foreign: []string{dead, open}, tlsAddr: []string{dead, open}}, netOpen},
	} {
		c.t.ruSNI, c.t.otherSNI = "ya.ru", "www.google.com"
		if got := classify(c.t, 2*time.Second, ""); got.Class != c.want || got.Detail == "" {
			t.Errorf("%s: got %+v, want %s", c.name, got, c.want)
		}
	}
}

func TestReachableServers(t *testing.T) {
	up, down := tcpServer(t), closedAddr(t)
	uh, upPort, _ := net.SplitHostPort(up)
	dh, downPort, _ := net.SplitHostPort(down)
	ob := func(tag, host, port, via string) string {
		so := ""
		if via != "" {
			so = `,"streamSettings":{"security":"tls","sockopt":{"dialerProxy":"` + via + `"}}`
		} else {
			so = `,"streamSettings":{"security":"tls"}`
		}
		return `{"tag":"` + tag + `","protocol":"trojan","settings":{"address":"` + host + `","port":` + port + `,"password":"p"}` + so + `}`
	}
	// The second config dials its server through a fragment hop: its own address counts.
	cfg := `{"outbounds":[` + ob("main", dh, downPort, "frag") + `,{"tag":"frag","protocol":"freedom"}]}`
	cfgQ, _ := json.Marshal(cfg)
	opts := `{"outbounds":[` + ob("a", uh, upPort, "") + `,` + ob("b", dh, downPort, "") + `],"configs":[` + string(cfgQ) + `]}`
	if n := ReachableServers(opts, 1000); n != 1 {
		t.Fatal("want 1 reachable of 2 distinct entries, got", n)
	}
	// A chain: only the front hop is an entry.
	chain := `{"outbounds":[` + ob("main", dh, downPort, "front") + `,` + ob("front", uh, upPort, "") + `]}`
	chainQ, _ := json.Marshal(chain)
	if n := ReachableServers(`{"configs":[`+string(chainQ)+`]}`, 1000); n != 1 {
		t.Fatal("chain:", n)
	}
	if n := ReachableServers(`{"outbounds":[{"protocol":"hysteria","settings":{"address":"1.2.3.4","port":443}}]}`, 1000); n != -1 {
		t.Fatal("UDP-only should be unknown:", n)
	}
}
