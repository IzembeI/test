package corebridge

import (
	"encoding/json"
	"strconv"
	"strings"
	"testing"
)

func outboundsFrom(t *testing.T, links string) []map[string]any {
	var arr []parsedLink
	if err := json.Unmarshal([]byte(ParseLinks(links)), &arr); err != nil {
		t.Fatal(err)
	}
	var res []map[string]any
	for _, p := range arr {
		if p.Outbound == nil {
			t.Fatal(p.Error)
		}
		res = append(res, p.Outbound)
	}
	return res
}

func TestBuildVariants(t *testing.T) {
	obs := outboundsFrom(t, "vless://b831381d-6324-4d53-ad4f-8cda48b30811@1.2.3.4:443?type=tcp&security=reality&pbk=Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw&fp=chrome&sni=www.microsoft.com&sid=6ba85179e30d4fc2&flow=xtls-rprx-vision&encryption=none#DE\n"+
		"trojan://pw@t.example.com:443?security=tls&sni=t.example.com&type=ws&path=%2Fws#T\n"+
		"hysteria2://pass@5.6.7.8:8443?sni=example.com&obfs=salamander&obfs-password=xyz#HY2")
	cases := []buildOptions{
		{Outbounds: obs[:1], Mode: "rule", TUN: true, Sniffing: true, Stats: true, Routing: routingOptions{BypassLAN: true, BypassRU: true, BlockAds: true, DirectDomains: []string{"domain:example.org"}}, DNS: dNSOptions{FakeDNS: true}},
		{Outbounds: obs[:1], Mode: "global", TUN: true, Fragment: fragmentOptions{Enabled: true}, Mux: muxOptions{Enabled: true}},
		{Outbounds: obs[1:2], Mode: "global", TUN: true, Mux: muxOptions{Enabled: true}, SocksPort: 10808, HTTPPort: 10809},
		{Outbounds: obs, Mode: "rule", TUN: true, Stats: true, Routing: routingOptions{BypassRU: true, BlockQUIC: true}},
		{Outbounds: obs[2:], Chain: obs[1:2], Mode: "global", TUN: true},
		{Mode: "direct", TUN: true},
		{Outbounds: obs[:1], Mode: "rule", TUN: true, APNsViaProxy: true, ConnIdle: 1800, Routing: routingOptions{BypassRU: true, DirectDomains: []string{"domain:apple.com"}}},
		{RawConfig: `{"dns":{"servers":["8.8.8.8"]},"outbounds":[{"tag":"proxy","protocol":"freedom"}]}`, TUN: true, UseConfigDNS: true},
		{Outbounds: obs[:1], Mode: "rule", TUN: true, Routing: routingOptions{DirectDomains: []string{"geosite:ru", "domain:ya.ru"}, DirectIPs: []string{"geoip:ru", "1.1.1.0/24"}}},
		{RawConfig: `{"outbounds":[{"tag":"proxy","protocol":"freedom"}]}`, TUN: true, Stats: true},
	}
	for i, c := range cases {
		b, _ := json.Marshal(c)
		out := BuildConfig(string(b))
		if strings.HasPrefix(out, "error:") {
			t.Fatalf("case %d: %s", i, out)
		}
		if e := Validate(out); e != "" {
			t.Fatalf("case %d invalid: %s\n%s", i, e, out)
		}
	}
}

func TestURLTestDetailedErrors(t *testing.T) {
	r := URLTestDetailed(`[{"config":"{\"outbounds\":[{\"protocol\":\"vless\",\"settings\":{\"address\":\"127.0.0.1\",\"port\":1,\"id\":\"b831381d-6324-4d53-ad4f-8cda48b30811\",\"encryption\":\"none\"}}],\"routing\":{\"rules\":[{\"inboundTag\":[\"x\"],\"outboundTag\":\"y\"}]}}"},{"outbound":{"protocol":"bogus"}}]`, "http://example.com", 1500, 2)
	t.Log(r)
	if !strings.Contains(r, `"delay":-1`) || !strings.Contains(r, "error") {
		t.Fatal(r)
	}
}

func TestAutoGroupWithConfigs(t *testing.T) {
	cfgA := `{"outbounds":[{"tag":"proxy","protocol":"vless","settings":{"address":"a.example.com","port":443,"id":"b831381d-6324-4d53-ad4f-8cda48b30811","encryption":"none"},"streamSettings":{"network":"grpc","security":"tls","tlsSettings":{"serverName":"a.example.com"},"grpcSettings":{"serviceName":"x"},"sockopt":{"dialerProxy":"frag"}}},{"tag":"frag","protocol":"freedom","settings":{"fragment":{"packets":"tlshello","length":"10-20","interval":"10-20"}}},{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[{"type":"field","outboundTag":"proxy","network":"tcp,udp"}]}}`
	cfgB := `{"outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"main","protocol":"trojan","settings":{"address":"1.2.3.4","port":443,"password":"p"},"streamSettings":{"security":"tls"}}]}`
	obs := outboundsFrom(t, "vless://b831381d-6324-4d53-ad4f-8cda48b30811@1.2.3.4:443?type=tcp&security=reality&pbk=Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw&fp=chrome&sni=www.microsoft.com&sid=6ba85179e30d4fc2&encryption=none#DE")
	for i, c := range []buildOptions{
		{Outbounds: obs, Configs: []string{cfgA, cfgB}, Mode: "rule", TUN: true, Stats: true, Fragment: fragmentOptions{Enabled: true}},
		{Configs: []string{cfgA, cfgB}, Mode: "global", TUN: true},
		{Configs: []string{cfgA}, Mode: "global", TUN: true},
	} {
		b, _ := json.Marshal(c)
		out := BuildConfig(string(b))
		if strings.HasPrefix(out, "error:") {
			t.Fatal(i, out)
		}
		if e := Validate(out); e != "" {
			t.Fatal(i, e, out)
		}
		if i == 0 && (!strings.Contains(out, `"dialerProxy": "dep0-frag"`) || !strings.Contains(out, `"proxy-c1"`) || !strings.Contains(out, "balancerTag")) {
			t.Fatal(out)
		}
	}
	if e := Start(BuildConfig(`{"configs":[`+strconv.Quote(cfgA)+`,`+strconv.Quote(cfgB)+`],"mode":"global","stats":true}`), -1, ""); e != "" {
		t.Fatal(e)
	}
	t.Log(Stats())
	Stop()
}

func TestAnalyze(t *testing.T) {
	sim := `{"name":"[SIM|Глушилки] – Москва 🇷🇺","outbound":{"protocol":"vless","settings":{"address":"1.2.3.4","port":443,"id":"x","flow":"xtls-rprx-vision"},"streamSettings":{"network":"raw","security":"reality","realitySettings":{"serverName":"vk.com"}}}}`
	hy := `{"name":"[WI-FI] Нидерланды","outbound":{"protocol":"hysteria","settings":{"address":"5.6.7.8","port":8443},"streamSettings":{"network":"hysteria","security":"tls","tlsSettings":{"serverName":"www.microsoft.com"}}}}`
	var a, b analysis
	json.Unmarshal([]byte(Analyze(sim)), &a)
	json.Unmarshal([]byte(Analyze(hy)), &b)
	t.Log(a, b)
	if a.Cellular <= b.Cellular || b.WiFi < 50 || a.DPI < 80 {
		t.Fatal(a, b)
	}
}
