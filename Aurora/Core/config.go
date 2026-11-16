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
	// Configs are full Xray JSON configs that join the auto group: the proxy
	// outbound of each and the outbounds it dials through are taken over.
	Configs   []string         `json:"configs"`
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
	// ProbeSec, when set, wins over ProbeMin: how often the balancer checks
	// its members. Short means a dead server is left within a minute.
	ProbeSec int `json:"probeSeconds"`
	// APNsViaProxy sends Apple push traffic through the proxy before any other
	// rule, so profiles that route Apple directly cannot break notifications.
	APNsViaProxy bool `json:"apnsViaProxy"`
	// ConnIdle is how long an idle connection is kept, in seconds. Push
	// connections stay idle for long, so whitelist setups want it high.
	ConnIdle int `json:"connIdle"`
	// UseConfigDNS keeps the "dns" section of a full JSON config.
	UseConfigDNS bool `json:"useConfigDNS"`
	// BufferKB is the per-connection buffer; Xray's arm64 default is 4 KB,
	// which caps download speed.
	BufferKB int `json:"bufferKB"`
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

var apnsDomains = []string{"domain:push.apple.com", "domain:push-apple.com.akadns.net", "domain:apple-pushnotifications.apple.com"}

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

func policyLevel(o buildOptions) map[string]any {
	idle := o.ConnIdle
	if idle <= 0 {
		idle = 300
	}
	buf := o.BufferKB
	if buf <= 0 {
		buf = 4
	}
	return map[string]any{"0": map[string]any{"handshake": 4, "connIdle": idle, "uplinkOnly": 1, "downlinkOnly": 1, "bufferSize": buf}}
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
	if len(o.Outbounds) == 0 && len(o.Configs) == 0 && o.Mode != "direct" {
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
			if _, set := sockoptOf(c)["dialerProxy"]; !set {
				sockoptOf(c)["dialerProxy"] = "fragment"
			}
		}
		outbounds = append(outbounds, c)
	}
	for j, raw := range o.Configs {
		main, deps, err := extractChain(raw, "dep"+itoa(j)+"-")
		if err != nil {
			continue
		}
		tag := "proxy-c" + itoa(j)
		main["tag"] = tag
		proxyTags = append(proxyTags, tag)
		outbounds = append(outbounds, main)
		for _, d := range deps {
			outbounds = append(outbounds, d)
		}
	}
	if len(o.Outbounds) == 1 && len(proxyTags) > 1 {
		// The single outbound was tagged "proxy" but now sits in a group.
		first := outbounds[0].(map[string]any)
		first["tag"] = "proxy-0"
		proxyTags[0] = "proxy-0"
	}
	if len(proxyTags) == 0 && o.Mode != "direct" {
		return nil, errString("no usable server in the group")
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
		if !strings.HasPrefix(tag, "proxy") && !strings.HasPrefix(tag, "chain-") && !strings.HasPrefix(tag, "dep") {
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
			if !isUDPOnly(m) {
				fastDeadLink(so)
			}
		}
	}

	mainTag := "proxy"
	if o.Mode == "direct" {
		mainTag = "direct"
	}
	useBalancer := len(proxyTags) > 1 && o.Mode != "direct"
	if len(proxyTags) == 1 && proxyTags[0] != "proxy" {
		// A single member left: address it as the plain proxy.
		for _, ob := range outbounds {
			if m := ob.(map[string]any); m["tag"] == proxyTags[0] {
				m["tag"] = "proxy"
			}
		}
		proxyTags[0] = "proxy"
	}

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
	if o.APNsViaProxy && o.Mode != "direct" {
		addRule(map[string]any{"domain": apnsDomains, "outboundTag": "proxy"})
		addRule(map[string]any{"ip": []string{"17.0.0.0/8"}, "port": "5223,2197", "outboundTag": "proxy"})
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
	// Resolving every unmatched domain only helps when some rule matches by
	// IP; otherwise it just adds a DNS round trip to each new connection.
	hasIPRules := len(o.Routing.DirectIPs)+len(o.Routing.ProxyIPs)+len(o.Routing.BlockIPs) > 0 ||
		(o.Routing.BypassRU && geoip && o.Mode == "rule") || (o.Routing.BypassLAN && geoip)
	if !hasIPRules {
		domainStrategy = "AsIs"
	}
	routing := map[string]any{"domainStrategy": domainStrategy, "rules": rules}
	cfg := map[string]any{"log": logSection(o)}
	if useBalancer {
		routing["balancers"] = []any{map[string]any{"tag": "auto", "selector": []string{"proxy-"}, "strategy": map[string]any{"type": "leastPing"}, "fallbackTag": proxyTags[0]}}
		probe := o.ProbeURL
		if probe == "" {
			probe = "https://www.gstatic.com/generate_204"
		}
		interval := ""
		switch {
		case o.ProbeSec > 0:
			// Below 15 s the probes themselves start to cost traffic and battery.
			interval = itoa(max(15, o.ProbeSec)) + "s"
		case o.ProbeMin > 0:
			interval = itoa(o.ProbeMin) + "m"
		default:
			interval = "3m"
		}
		cfg["observatory"] = map[string]any{"subjectSelector": []string{"proxy-"}, "probeURL": probe, "probeInterval": interval, "enableConcurrency": true}
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
			"levels": policyLevel(o)}
	} else {
		cfg["policy"] = map[string]any{"levels": policyLevel(o)}
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
	// Push and dead-link settings apply to a full config as well: Apple push
	// goes through the config's own proxy before its other rules.
	if key, target := rawProxyTarget(cfg); o.APNsViaProxy && key != "" {
		apns := []any{
			map[string]any{"type": "field", "domain": apnsDomains, key: target},
			map[string]any{"type": "field", "ip": []string{"17.0.0.0/8"}, "port": "5223,2197", key: target},
		}
		at := 0
		if o.TUN {
			at = 1 // after the DNS rule
		}
		rules = append(rules[:at], append(apns, rules[at:]...)...)
	}
	for _, ob := range outbounds {
		if m, ok := ob.(map[string]any); ok && !nonProxy[str(m["protocol"])] && !isUDPOnly(m) {
			fastDeadLink(sockoptOf(m))
		}
	}
	mergePolicyLevel(cfg, o)
	routing["rules"] = rules
	cfg["routing"] = routing
	if _, ok := cfg["dns"]; !ok || !o.UseConfigDNS {
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

// fastDeadLink makes a dead link to the server show in about two minutes
// instead of six. Xray probes an idle connection after 45 s and then every
// 45 s; probes 10 s apart close a dead one sooner, so apps and the iOS push
// service reconnect sooner. A healthy link sees no extra traffic: the
// interval only applies once a probe goes unanswered.
func fastDeadLink(so map[string]any) {
	_, idle := so["tcpKeepAliveIdle"]
	_, interval := so["tcpKeepAliveInterval"]
	if idle || interval {
		return
	}
	so["tcpKeepAliveIdle"] = 45
	so["tcpKeepAliveInterval"] = 10
}

// rawProxyTarget finds where a full config sends traffic by default: the
// outbound or balancer of its last catch-all rule, else its first proxy
// outbound. key is "outboundTag" or "balancerTag", empty when none.
func rawProxyTarget(cfg map[string]any) (key, target string) {
	outbounds, _ := cfg["outbounds"].([]any)
	proxyTag := map[string]bool{}
	first := ""
	for _, ob := range outbounds {
		m, _ := ob.(map[string]any)
		if m == nil || nonProxy[str(m["protocol"])] {
			continue
		}
		t := str(m["tag"])
		if t == "" && first == "" {
			// Untagged, so no rule could name it: give it a tag.
			t = "aurora-proxy"
			m["tag"] = t
		}
		if t != "" {
			proxyTag[t] = true
			if first == "" {
				first = t
			}
		}
	}
	if routing, ok := cfg["routing"].(map[string]any); ok {
		rules, _ := routing["rules"].([]any)
		for _, r := range rules {
			rm, _ := r.(map[string]any)
			if rm == nil || !isCatchAll(rm) {
				continue
			}
			if b := str(rm["balancerTag"]); b != "" {
				key, target = "balancerTag", b
			} else if t := str(rm["outboundTag"]); proxyTag[t] {
				key, target = "outboundTag", t
			}
		}
	}
	if key == "" && first != "" {
		key, target = "outboundTag", first
	}
	return key, target
}

// mergePolicyLevel brings the app's connection policy into a full config:
// the longer idle time (push connections stay idle for long) and the buffer
// size, without overriding what the config sets itself.
func mergePolicyLevel(cfg map[string]any, o buildOptions) {
	policy, _ := cfg["policy"].(map[string]any)
	if policy == nil {
		policy = map[string]any{}
	}
	levels, _ := policy["levels"].(map[string]any)
	if levels == nil {
		levels = map[string]any{}
	}
	l0, _ := levels["0"].(map[string]any)
	if l0 == nil {
		l0 = map[string]any{}
	}
	for k, v := range policyLevel(o)["0"].(map[string]any) {
		cur, set := l0[k]
		switch {
		case !set:
			l0[k] = v
		case k == "connIdle":
			if n, ok := cur.(float64); ok && float64(v.(int)) > n {
				l0[k] = v
			}
		}
	}
	levels["0"] = l0
	policy["levels"] = levels
	cfg["policy"] = policy
}

func itoa(i int) string { return strconv.Itoa(i) }

var nonProxy = map[string]bool{"freedom": true, "blackhole": true, "dns": true, "loopback": true}

// extractChain takes the proxy outbound of a full config (the one its
// routing sends traffic to by default, else the first proxy outbound) and
// every outbound it dials through, renaming the helpers with prefix.
func extractChain(raw string, prefix string) (map[string]any, []map[string]any, error) {
	var cfg map[string]any
	if err := json.Unmarshal([]byte(raw), &cfg); err != nil {
		return nil, nil, err
	}
	list, _ := cfg["outbounds"].([]any)
	byTag := map[string]map[string]any{}
	var ordered []map[string]any
	for _, x := range list {
		if m, ok := x.(map[string]any); ok {
			ordered = append(ordered, m)
			if t, _ := m["tag"].(string); t != "" {
				byTag[t] = m
			}
		}
	}
	var main map[string]any
	// Prefer the outbound of the last catch-all routing rule.
	if routing, ok := cfg["routing"].(map[string]any); ok {
		if rules, ok := routing["rules"].([]any); ok {
			for _, r := range rules {
				rm, _ := r.(map[string]any)
				if rm == nil {
					continue
				}
				if t, _ := rm["outboundTag"].(string); t != "" {
					if ob := byTag[t]; ob != nil && !nonProxy[str(ob["protocol"])] && isCatchAll(rm) {
						main = ob
					}
				}
			}
		}
	}
	if main == nil {
		for _, ob := range ordered {
			if !nonProxy[str(ob["protocol"])] {
				main = ob
				break
			}
		}
	}
	if main == nil {
		return nil, nil, errString("no proxy outbound")
	}
	main = clone(main)
	var deps []map[string]any
	seen := map[string]bool{}
	var follow func(ob map[string]any)
	follow = func(ob map[string]any) {
		refs := []*string{}
		var dp, pt string
		if ss, ok := ob["streamSettings"].(map[string]any); ok {
			if so, ok := ss["sockopt"].(map[string]any); ok {
				dp, _ = so["dialerProxy"].(string)
				if dp != "" {
					so["dialerProxy"] = prefix + dp
				}
			}
		}
		if ps, ok := ob["proxySettings"].(map[string]any); ok {
			pt, _ = ps["tag"].(string)
			if pt != "" {
				ps["tag"] = prefix + pt
			}
		}
		_ = refs
		for _, t := range []string{dp, pt} {
			if t == "" || seen[t] {
				continue
			}
			seen[t] = true
			if d := byTag[t]; d != nil {
				c := clone(d)
				c["tag"] = prefix + t
				follow(c)
				deps = append(deps, c)
			}
		}
	}
	follow(main)
	return main, deps, nil
}

func str(v any) string {
	s, _ := v.(string)
	return s
}

// isCatchAll reports whether a rule matches everything (no conditions).
func isCatchAll(r map[string]any) bool {
	for k := range r {
		switch k {
		case "type", "outboundTag", "balancerTag", "ruleTag":
		case "network":
			n := str(r[k])
			if n != "tcp,udp" && n != "udp,tcp" {
				return false
			}
		case "port":
			if p := str(r[k]); p != "0-65535" && p != "1-65535" {
				return false
			}
		default:
			return false
		}
	}
	return true
}
