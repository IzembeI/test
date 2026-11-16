package corebridge

import (
	"encoding/json"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// buildOptions is what the app sends to BuildConfig.
type buildOptions struct {
	Outbounds []map[string]any `json:"outbounds"` // one = single server, several = auto (least ping) group
	Chain     []map[string]any `json:"chain"`     // optional front hops, the first dials directly
	RawConfig string           `json:"rawConfig"` // a full Xray JSON from the user, used as is with a TUN added
	Mode      string           `json:"mode"`      // rule | global | direct
	TUN       bool             `json:"tun"`
	MTU       int              `json:"mtu"`
	SocksPort int              `json:"socksPort"` // 0 = no local SOCKS/HTTP inbound
	HTTPPort  int              `json:"httpPort"`
	LANShare  bool             `json:"lanShare"` // listen on 0.0.0.0
	Sniffing  bool             `json:"sniffing"`
	RouteOnly bool             `json:"routeOnly"`
	IPv6      bool             `json:"ipv6"`
	LogLevel  string           `json:"logLevel"`
	LogDir    string           `json:"logDir"`
	AssetDir  string           `json:"assetDir"`
	ProbeURL  string           `json:"probeURL"`
	ProbeMin  int              `json:"probeMinutes"`
	DNS       dNSOptions       `json:"dns"`
	Routing   routingOptions   `json:"routing"`
	Fragment  fragmentOptions  `json:"fragment"`
	Mux       muxOptions       `json:"mux"`
	Stats     bool             `json:"stats"`
}

type dNSOptions struct {
	Remote   string            `json:"remote"`   // through the proxy
	Direct   string            `json:"direct"`   // for direct domains
	Strategy string            `json:"strategy"` // UseIP | UseIPv4 | UseIPv6
	FakeDNS  bool              `json:"fakeDNS"`
	Hosts    map[string]string `json:"hosts"`
}

type routingOptions struct {
	DomainStrategy string   `json:"domainStrategy"`
	BypassLAN      bool     `json:"bypassLAN"`
	BypassRU       bool     `json:"bypassRU"`
	BlockAds       bool     `json:"blockAds"`
	BlockQUIC      bool     `json:"blockQUIC"`
	DirectDomains  []string `json:"directDomains"`
	DirectIPs      []string `json:"directIPs"`
	ProxyDomains   []string `json:"proxyDomains"`
	ProxyIPs       []string `json:"proxyIPs"`
	BlockDomains   []string `json:"blockDomains"`
	BlockIPs       []string `json:"blockIPs"`
}

type fragmentOptions struct {
	Enabled  bool   `json:"enabled"`
	Packets  string `json:"packets"`
	Length   string `json:"length"`
	Interval string `json:"interval"`
}

type muxOptions struct {
	Enabled     bool `json:"enabled"`
	Concurrency int  `json:"concurrency"`
	XUDP        int  `json:"xudpConcurrency"`
}

var lanCIDRs = []string{"10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/4", "255.255.255.255/32", "::1/128", "fc00::/7", "fe80::/10", "ff00::/8"}

var ruDomains = []string{"domain:ru", "domain:su", "domain:xn--p1ai", "domain:xn--d1acj3b", "domain:yandex.net", "domain:yandex.com", "domain:vk.com", "domain:vk.me", "domain:userapi.com", "domain:mail.ru", "domain:gosuslugi.ru", "domain:sberbank.ru", "domain:tinkoff.ru", "domain:tbank.ru", "domain:ozon.ru", "domain:wildberries.ru", "domain:avito.ru", "domain:kinopoisk.ru", "domain:yastatic.net", "domain:mycdn.me", "domain:ok.ru", "domain:mts.ru", "domain:beeline.ru", "domain:megafon.ru", "domain:max.ru"}

var adDomains = []string{"domain:doubleclick.net", "domain:googlesyndication.com", "domain:googleadservices.com", "domain:adservice.google.com", "domain:app-measurement.com", "domain:an.yandex.ru", "domain:adfox.ru", "domain:yandexadexchange.net", "domain:adriver.ru", "domain:mc.yandex.ru", "domain:appsflyer.com", "domain:adjust.com", "domain:unityads.unity3d.com", "domain:ads.vk.com", "domain:top-fwz1.mail.ru"}

func hasAsset(dir, name string) bool {
	if dir == "" {
		return false
	}
	st, err := os.Stat(filepath.Join(dir, name))
	return err == nil && st.Size() > 0
}

// BuildConfig turns buildOptions JSON into a complete Xray JSON config.
// On failure the result starts with "error:".
func BuildConfig(optionsJSON string) string {
	var o buildOptions
	if err := json.Unmarshal([]byte(optionsJSON), &o); err != nil {
		return "error:" + err.Error()
	}
	cfg, err := buildConfig(o)
	if err != nil {
		return "error:" + err.Error()
	}
	b, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return "error:" + err.Error()
	}
	return string(b)
}

func clone(m map[string]any) map[string]any {
	b, _ := json.Marshal(m)
	var c map[string]any
	_ = json.Unmarshal(b, &c)
	return c
}

func streamOf(ob map[string]any) map[string]any {
	ss, _ := ob["streamSettings"].(map[string]any)
	if ss == nil {
		ss = map[string]any{}
		ob["streamSettings"] = ss
	}
	return ss
}

func sockoptOf(ob map[string]any) map[string]any {
	ss := streamOf(ob)
	so, _ := ss["sockopt"].(map[string]any)
	if so == nil {
		so = map[string]any{}
		ss["sockopt"] = so
	}
	return so
}

func isUDPOnly(ob map[string]any) bool {
	p, _ := ob["protocol"].(string)
	if p == "wireguard" || p == "hysteria" {
		return true
	}
	if ss, ok := ob["streamSettings"].(map[string]any); ok {
		if n, _ := ss["network"].(string); n == "kcp" || n == "mkcp" || n == "hysteria" {
			return true
		}
	}
	return false
}

func tunInbound(o buildOptions) map[string]any {
	mtu := o.MTU
	if mtu <= 0 {
		mtu = 1500
	}
	in := map[string]any{
		"tag": "tun", "port": 0, "protocol": "tun",
		"settings": map[string]any{"name": "utun", "mtu": mtu},
	}
	if o.Sniffing {
		in["sniffing"] = map[string]any{"enabled": true, "destOverride": []string{"http", "tls", "quic"}, "routeOnly": o.RouteOnly}
	}
	return in
}

func localInbounds(o buildOptions) []any {
	listen := "127.0.0.1"
	if o.LANShare {
		listen = "0.0.0.0"
	}
	var res []any
	sniff := map[string]any{"enabled": o.Sniffing, "destOverride": []string{"http", "tls", "quic"}, "routeOnly": o.RouteOnly}
	if o.SocksPort > 0 {
		res = append(res, map[string]any{"tag": "socks", "listen": listen, "port": o.SocksPort, "protocol": "socks",
			"settings": map[string]any{"udp": true, "auth": "noauth"}, "sniffing": sniff})
	}
	if o.HTTPPort > 0 {
		res = append(res, map[string]any{"tag": "http", "listen": listen, "port": o.HTTPPort, "protocol": "http", "sniffing": sniff})
	}
	return res
}

func logSection(o buildOptions) map[string]any {
	lvl := o.LogLevel
	if lvl == "" {
		lvl = "warning"
	}
	l := map[string]any{"loglevel": lvl, "dnsLog": false}
	if o.LogDir != "" && lvl != "none" {
		l["error"] = filepath.Join(o.LogDir, "xray-error.log")
		if lvl == "debug" || lvl == "info" {
			l["access"] = filepath.Join(o.LogDir, "xray-access.log")
		}
	}
	return l
}

func buildConfig(o buildOptions) (map[string]any, error) {
	if strings.TrimSpace(o.RawConfig) != "" {
		return buildFromRaw(o)
	}
	if len(o.Outbounds) == 0 && o.Mode != "direct" {
		return nil, errString("no server selected")
	}
	geoip := hasAsset(o.AssetDir, "geoip.dat")
	geosite := hasAsset(o.AssetDir, "geosite.dat")
	// Rules that need a database that is not there are left out instead of
	// failing the whole start.
	r := &o.Routing
	for _, l := range []*[]string{&r.DirectDomains, &r.ProxyDomains, &r.BlockDomains} {
		*l = usable(*l, geosite, "geosite:")
	}
	for _, l := range []*[]string{&r.DirectIPs, &r.ProxyIPs, &r.BlockIPs} {
		*l = usable(*l, geoip, "geoip:")
	}

	outbounds := []any{}
	proxyTags := []string{}
	for i, ob := range o.Outbounds {
		c := clone(ob)
		tag := "proxy"
		if len(o.Outbounds) > 1 {
			tag = "proxy-" + itoa(i)
		}
		c["tag"] = tag
		proxyTags = append(proxyTags, tag)
		if o.Mux.Enabled && !isUDPOnly(c) && !hasFlow(c) {
			conc := o.Mux.Concurrency
			if conc == 0 {
				conc = 8
			}
			x := o.Mux.XUDP
			if x == 0 {
				x = 16
			}
			c["mux"] = map[string]any{"enabled": true, "concurrency": conc, "xudpConcurrency": x, "xudpProxyUDP443": "reject"}
		}
		if len(o.Chain) > 0 {
			sockoptOf(c)["dialerProxy"] = "chain-0"
		} else if o.Fragment.Enabled && !isUDPOnly(c) {
			sockoptOf(c)["dialerProxy"] = "fragment"
		}
		outbounds = append(outbounds, c)
	}
	for i, hop := range o.Chain {
		c := clone(hop)
		c["tag"] = "chain-" + itoa(i)
		if i+1 < len(o.Chain) {
			sockoptOf(c)["dialerProxy"] = "chain-" + itoa(i+1)
		} else if o.Fragment.Enabled && !isUDPOnly(c) {
			sockoptOf(c)["dialerProxy"] = "fragment"
		}
		outbounds = append(outbounds, c)
	}
	strategy := o.DNS.Strategy
	if strategy == "" {
		if o.IPv6 {
			strategy = "UseIP"
		} else {
			strategy = "UseIPv4"
		}
	}
	outbounds = append(outbounds,
		map[string]any{"tag": "direct", "protocol": "freedom", "settings": map[string]any{"domainStrategy": strategy}},
		map[string]any{"tag": "block", "protocol": "blackhole", "settings": map[string]any{"response": map[string]any{"type": "http"}}},
		map[string]any{"tag": "dns-out", "protocol": "dns"},
	)
	if o.Fragment.Enabled {
		packets := o.Fragment.Packets
		if packets == "" {
			packets = "tlshello"
		}
		length := o.Fragment.Length
		if length == "" {
			length = "100-200"
		}
		interval := o.Fragment.Interval
		if interval == "" {
			interval = "10-20"
		}
		outbounds = append(outbounds, map[string]any{"tag": "fragment", "protocol": "freedom",
			"settings":       map[string]any{"domainStrategy": strategy, "fragment": map[string]any{"packets": packets, "length": length, "interval": interval}},
			"streamSettings": map[string]any{"sockopt": map[string]any{"tcpNoDelay": true}}})
	}

	// Server names are resolved by Xray's own DNS over the direct link, so the
	// tunnel never waits on itself for the address of its own server.
	serverHosts := []string{}
	for _, ob := range outbounds {
		m := ob.(map[string]any)
		tag, _ := m["tag"].(string)
		if !strings.HasPrefix(tag, "proxy") && !strings.HasPrefix(tag, "chain-") {
			continue
		}
		host, _ := outboundEndpoint(m)
		if host != "" && net.ParseIP(strings.Trim(host, "[]")) == nil {
			serverHosts = append(serverHosts, "full:"+host)
		}
		resolve := "UseIPv4"
		if o.IPv6 {
			resolve = "UseIP"
		}
		if p, _ := m["protocol"].(string); p == "wireguard" {
			if st, ok := m["settings"].(map[string]any); ok {
				if o.IPv6 {
					st["domainStrategy"] = "ForceIP"
				} else {
					st["domainStrategy"] = "ForceIPv4"
				}
			}
		} else {
			so := sockoptOf(m)
			if _, set := so["domainStrategy"]; !set {
				so["domainStrategy"] = resolve
			}
		}
	}

	mainTag := "proxy"
	if o.Mode == "direct" {
		mainTag = "direct"
	}
	useBalancer := len(proxyTags) > 1 && o.Mode != "direct"

	// Routing
	rules := []any{}
	addRule := func(rule map[string]any) {
		if useBalancer && rule["outboundTag"] == "proxy" {
			delete(rule, "outboundTag")
			rule["balancerTag"] = "auto"
		}
		rule["type"] = "field"
		rules = append(rules, rule)
	}
	if o.TUN {
		addRule(map[string]any{"inboundTag": []string{"tun"}, "port": "53", "outboundTag": "dns-out"})
	}
	if o.Routing.BlockQUIC {
		addRule(map[string]any{"network": "udp", "port": "443", "outboundTag": "block"})
	}
	// Server addresses of the hops always go direct (needed with a dialer chain).
	if len(o.Routing.BlockDomains) > 0 {
		addRule(map[string]any{"domain": o.Routing.BlockDomains, "outboundTag": "block"})
	}
	if len(o.Routing.BlockIPs) > 0 {
		addRule(map[string]any{"ip": o.Routing.BlockIPs, "outboundTag": "block"})
	}
	if o.Routing.BlockAds {
		if geosite {
			addRule(map[string]any{"domain": []string{"geosite:category-ads-all"}, "outboundTag": "block"})
		} else {
			addRule(map[string]any{"domain": adDomains, "outboundTag": "block"})
		}
	}
	if o.Mode != "direct" {
		if len(o.Routing.ProxyDomains) > 0 {
			addRule(map[string]any{"domain": o.Routing.ProxyDomains, "outboundTag": "proxy"})
		}
		if len(o.Routing.ProxyIPs) > 0 {
			addRule(map[string]any{"ip": o.Routing.ProxyIPs, "outboundTag": "proxy"})
		}
	}
	if o.Routing.BypassLAN {
		if geoip {
			addRule(map[string]any{"ip": []string{"geoip:private"}, "outboundTag": "direct"})
		} else {
			addRule(map[string]any{"ip": lanCIDRs, "outboundTag": "direct"})
		}
	}
	if o.Mode == "rule" {
		if len(o.Routing.DirectDomains) > 0 {
			addRule(map[string]any{"domain": o.Routing.DirectDomains, "outboundTag": "direct"})
		}
		if len(o.Routing.DirectIPs) > 0 {
			addRule(map[string]any{"ip": o.Routing.DirectIPs, "outboundTag": "direct"})
		}
		if o.Routing.BypassRU {
			doms := append([]string{}, ruDomains...)
			if geosite {
				doms = append(doms, "geosite:category-ru")
			}
			addRule(map[string]any{"domain": doms, "outboundTag": "direct"})
			if geoip {
				addRule(map[string]any{"ip": []string{"geoip:ru"}, "outboundTag": "direct"})
			}
		}
	}
	if ip := dnsHostIP(o.DNS.Direct); ip != "" {
		addRule(map[string]any{"inboundTag": []string{"dns-internal"}, "ip": []string{ip}, "outboundTag": "direct"})
	}
	// Everything else
	final := map[string]any{"network": "tcp,udp", "outboundTag": mainTag}
	addRule(final)

	domainStrategy := o.Routing.DomainStrategy
	if domainStrategy == "" {
		domainStrategy = "IPIfNonMatch"
	}
	routing := map[string]any{"domainStrategy": domainStrategy, "rules": rules}
	cfg := map[string]any{"log": logSection(o)}
	if useBalancer {
		routing["balancers"] = []any{map[string]any{"tag": "auto", "selector": []string{"proxy-"}, "strategy": map[string]any{"type": "leastPing"}, "fallbackTag": proxyTags[0]}}
		probe := o.ProbeURL
		if probe == "" {
			probe = "https://www.gstatic.com/generate_204"
		}
		mins := o.ProbeMin
		if mins <= 0 {
			mins = 3
		}
		cfg["observatory"] = map[string]any{"subjectSelector": []string{"proxy-"}, "probeURL": probe, "probeInterval": itoa(mins) + "m", "enableConcurrency": true}
	}
	cfg["routing"] = routing
	dns := dnsSection(o, geosite)
	if len(serverHosts) > 0 {
		direct := o.DNS.Direct
		if direct == "" {
			direct = "77.88.8.8"
		}
		servers := dns["servers"].([]any)
		dns["servers"] = append([]any{map[string]any{"address": direct, "domains": serverHosts, "skipFallback": true}}, servers...)
	}
	cfg["dns"] = dns

	inbounds := []any{}
	if o.TUN {
		inbounds = append(inbounds, tunInbound(o))
	}
	inbounds = append(inbounds, localInbounds(o)...)
	cfg["inbounds"] = inbounds
	cfg["outbounds"] = outbounds
	if o.Stats {
		cfg["stats"] = map[string]any{}
		cfg["policy"] = map[string]any{"system": map[string]any{"statsOutboundUplink": true, "statsOutboundDownlink": true},
			"levels": map[string]any{"0": map[string]any{"handshake": 4, "connIdle": 300, "uplinkOnly": 1, "downlinkOnly": 1, "bufferSize": 4}}}
	} else {
		cfg["policy"] = map[string]any{"levels": map[string]any{"0": map[string]any{"handshake": 4, "connIdle": 300, "uplinkOnly": 1, "downlinkOnly": 1, "bufferSize": 4}}}
	}
	if o.DNS.FakeDNS {
		cfg["fakedns"] = []any{map[string]any{"ipPool": "198.18.0.0/16", "poolSize": 4096}}
	}
	return cfg, nil
}

func usable(list []string, have bool, prefix string) []string {
	out := []string{}
	for _, v := range list {
		v = strings.TrimSpace(v)
		if v == "" {
			continue
		}
		if strings.HasPrefix(v, "ext:") {
			continue
		}
		if !have && strings.HasPrefix(v, prefix) {
			continue
		}
		out = append(out, v)
	}
	return out
}

func dnsHostIP(server string) string {
	if server == "" {
		server = "77.88.8.8"
	}
	h := server
	if u, err := url.Parse(server); err == nil && u.Host != "" {
		h = u.Hostname()
	} else if hh, _, err := net.SplitHostPort(server); err == nil {
		h = hh
	}
	if net.ParseIP(h) != nil {
		return h
	}
	return ""
}

func hasFlow(ob map[string]any) bool {
	s, _ := ob["settings"].(map[string]any)
	if s == nil {
		return false
	}
	if f, _ := s["flow"].(string); f != "" {
		return true
	}
	if vn, ok := s["vnext"].([]any); ok {
		for _, v := range vn {
			if vm, ok := v.(map[string]any); ok {
				if us, ok := vm["users"].([]any); ok {
					for _, u := range us {
						if um, ok := u.(map[string]any); ok {
							if f, _ := um["flow"].(string); f != "" {
								return true
							}
						}
					}
				}
			}
		}
	}
	return false
}

func dnsSection(o buildOptions, geosite bool) map[string]any {
	remote := o.DNS.Remote
	if remote == "" {
		remote = "https://1.1.1.1/dns-query"
	}
	direct := o.DNS.Direct
	if direct == "" {
		direct = "77.88.8.8"
	}
	servers := []any{}
	if o.DNS.FakeDNS && o.Mode != "direct" {
		servers = append(servers, "fakedns")
	}
	servers = append(servers, remote)
	directDomains := append([]string{}, o.Routing.DirectDomains...)
	if o.Routing.BypassRU && o.Mode == "rule" {
		directDomains = append(directDomains, ruDomains...)
		if geosite {
			directDomains = append(directDomains, "geosite:category-ru")
		}
	}
	if o.Mode == "direct" {
		servers = []any{direct}
	} else if len(directDomains) > 0 {
		servers = append(servers, map[string]any{"address": direct, "domains": directDomains, "skipFallback": true})
	}
	strategy := o.DNS.Strategy
	if strategy == "" {
		if o.IPv6 {
			strategy = "UseIP"
		} else {
			strategy = "UseIPv4"
		}
	}
	d := map[string]any{"servers": servers, "queryStrategy": strategy, "tag": "dns-internal"}
	if len(o.DNS.Hosts) > 0 {
		d["hosts"] = o.DNS.Hosts
	}
	return d
}

// buildFromRaw keeps a user's full config and adds the TUN and DNS hijack.
func buildFromRaw(o buildOptions) (map[string]any, error) {
	var cfg map[string]any
	if err := json.Unmarshal([]byte(o.RawConfig), &cfg); err != nil {
		return nil, errString("custom config: " + err.Error())
	}
	inbounds, _ := cfg["inbounds"].([]any)
	kept := []any{}
	for _, in := range inbounds {
		if m, ok := in.(map[string]any); ok {
			if p, _ := m["protocol"].(string); p == "tun" {
				continue
			}
			kept = append(kept, m)
		}
	}
	if o.TUN {
		kept = append([]any{tunInbound(o)}, kept...)
	}
	cfg["inbounds"] = kept
	outbounds, _ := cfg["outbounds"].([]any)
	hasDNS := false
	for _, ob := range outbounds {
		if m, ok := ob.(map[string]any); ok && m["tag"] == "dns-out" {
			hasDNS = true
		}
	}
	if !hasDNS {
		outbounds = append(outbounds, map[string]any{"tag": "dns-out", "protocol": "dns"})
	}
	cfg["outbounds"] = outbounds
	routing, _ := cfg["routing"].(map[string]any)
	if routing == nil {
		routing = map[string]any{}
	}
	rules, _ := routing["rules"].([]any)
	if o.TUN {
		rules = append([]any{map[string]any{"type": "field", "inboundTag": []string{"tun"}, "port": "53", "outboundTag": "dns-out"}}, rules...)
	}
	routing["rules"] = rules
	cfg["routing"] = routing
	if _, ok := cfg["dns"]; !ok {
		cfg["dns"] = dnsSection(o, false)
	}
	if o.LogDir != "" {
		cfg["log"] = logSection(o)
	}
	if o.Stats {
		cfg["stats"] = map[string]any{}
		policy, _ := cfg["policy"].(map[string]any)
		if policy == nil {
			policy = map[string]any{}
		}
		policy["system"] = map[string]any{"statsOutboundUplink": true, "statsOutboundDownlink": true}
		cfg["policy"] = policy
	}
	return cfg, nil
}

func itoa(i int) string { return strconv.Itoa(i) }
