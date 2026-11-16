package corebridge

import (
	"encoding/json"
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
