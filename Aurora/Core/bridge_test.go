package corebridge

import (
	"encoding/json"
	"strconv"
	"strings"
	"testing"
)

const cfg = `{"log":{"loglevel":"warning"},"stats":{},"policy":{"system":{"statsOutboundUplink":true,"statsOutboundDownlink":true}},
"inbounds":[{"tag":"socks","listen":"127.0.0.1","port":10999,"protocol":"socks","settings":{"udp":true}}],
"outbounds":[{"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"1.2.3.4","port":443,"users":[{"id":"b831381d-6324-4d53-ad4f-8cda48b30811","encryption":"none","flow":"xtls-rprx-vision"}]}]},
"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"serverName":"www.microsoft.com","fingerprint":"chrome","publicKey":"Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw","shortId":"6ba85179e30d4fc2"}}},
{"tag":"direct","protocol":"freedom"}]}`

func TestStartStop(t *testing.T) {
	if e := Validate(cfg); e != "" {
		t.Fatal(e)
	}
	if e := Start(cfg, -1, ""); e != "" {
		t.Fatal(e)
	}
	if !IsRunning() {
		t.Fatal("not running")
	}
	s := Stats()
	if !strings.Contains(s, `"up"`) {
		t.Fatal(s)
	}
	t.Log(s, Version())
	if e := Stop(); e != "" {
		t.Fatal(e)
	}
}

func TestURLTestBad(t *testing.T) {
	r := URLTest(`[{"protocol":"vless","settings":{"vnext":[{"address":"127.0.0.1","port":1,"users":[{"id":"b831381d-6324-4d53-ad4f-8cda48b30811","encryption":"none"}]}]}},{"protocol":"bogus"}]`, "http://example.com", 1500, 2)
	t.Log(r)
	if r != "[-1,-1]" {
		t.Fatal(r)
	}
}

func TestParseLinks(t *testing.T) {
	text := "vless://b831381d-6324-4d53-ad4f-8cda48b30811@1.2.3.4:443?type=tcp&security=reality&pbk=Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw&fp=chrome&sni=www.microsoft.com&sid=6ba85179e30d4fc2&flow=xtls-rprx-vision&encryption=none#%F0%9F%87%A9%F0%9F%87%AA%20Germany\n" +
		"hysteria2://pass@5.6.7.8:8443?sni=example.com&obfs=salamander&obfs-password=xyz&insecure=1#HY2\n" +
		"trojan://pw@t.example.com:443?security=tls&sni=t.example.com&type=ws&path=%2Fws&host=t.example.com#Trojan WS\n" +
		"ss://YWVzLTI1Ni1nY206cGFzcw@9.9.9.9:8388#SS\n" +
		"vless://b831381d-6324-4d53-ad4f-8cda48b30811@x.example.com:443?type=xhttp&security=tls&sni=x.example.com&path=%2Fx&mode=auto&encryption=none#XHTTP\n" +
		"wireguard://cGFzc3dvcmRwYXNzd29yZHBhc3N3b3JkcGFzc3dvcmQ%3D@wg.example.com:51820?publickey=cGFzc3dvcmRwYXNzd29yZHBhc3N3b3JkcGFzc3dvcmQ%3D&address=10.0.0.2/32#WG\n" +
		"vmess://eyJ2IjoiMiIsInBzIjoiVk1lc3MiLCJhZGQiOiIxLjEuMS4xIiwicG9ydCI6IjQ0MyIsImlkIjoiYjgzMTM4MWQtNjMyNC00ZDUzLWFkNGYtOGNkYTQ4YjMwODExIiwiYWlkIjoiMCIsIm5ldCI6IndzIiwidHlwZSI6Im5vbmUiLCJob3N0IjoiIiwicGF0aCI6Ii8iLCJ0bHMiOiJ0bHMifQ==\n"
	out := ParseLinks(text)
	t.Log(out)
	for _, bad := range []string{`"error"`} {
		if strings.Contains(out, bad) {
			t.Error("has error")
		}
	}
	// whole config with these outbounds must validate
	full := `{"outbounds":[` + extractOutbound(t, out) + `]}`
	if e := Validate(full); e != "" {
		t.Fatal(e, full)
	}
}

func extractOutbound(t *testing.T, s string) string {
	var arr []parsedLink
	if err := json.Unmarshal([]byte(s), &arr); err != nil {
		t.Fatal(err)
	}
	parts := []string{}
	for i, p := range arr {
		if p.Outbound == nil {
			t.Fatal(p.Link, p.Error)
		}
		p.Outbound["tag"] = "o" + strconv.Itoa(i)
		b, _ := json.Marshal(p.Outbound)
		parts = append(parts, string(b))
	}
	return strings.Join(parts, ",")
}
