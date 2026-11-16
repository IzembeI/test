package corebridge

import (
	"encoding/base64"
	"encoding/json"
	"net"
	"net/url"
	"strconv"
	"strings"

	"github.com/xtls/libxray/share"
)

type parsedLink struct {
	Link     string         `json:"link"`
	Name     string         `json:"name"`
	Protocol string         `json:"protocol"`
	Address  string         `json:"address"`
	Port     int            `json:"port"`
	Outbound map[string]any `json:"outbound,omitempty"`
	// OutboundJSON is Outbound as text, which is easier to keep on the Swift side.
	OutboundJSON string `json:"outboundJSON,omitempty"`
	Error        string `json:"error,omitempty"`
}

// DecodeSubscription turns a subscription body (plain, base64 or an Age
// encrypted one with secretKey) into newline separated share links. JSON
// bodies are returned as they are.
func DecodeSubscription(text string, secretKey string) string {
	t := strings.TrimSpace(text)
	if strings.HasPrefix(t, "{") || strings.HasPrefix(t, "[") {
		return t
	}
	out, err := share.DecodeSubscriptionText(t, secretKey)
	if err != nil || strings.TrimSpace(out) == "" {
		if d, ok := tryBase64(t); ok {
			return d
		}
		return t
	}
	return out
}

func tryBase64(s string) (string, bool) {
	s = strings.Join(strings.Fields(s), "")
	for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
		if b, err := enc.DecodeString(s); err == nil {
			return string(b), true
		}
	}
	return "", false
}

// ParseLinks converts newline separated share links into a JSON array of
// objects {link, name, protocol, address, port, outbound, error}.
func ParseLinks(text string) string {
	var out []parsedLink
	for _, raw := range strings.Split(strings.ReplaceAll(text, "\r", "\n"), "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, "//") {
			continue
		}
		if !strings.Contains(line, "://") {
			continue
		}
		out = append(out, parseOne(line))
	}
	if out == nil {
		out = []parsedLink{}
	}
	b, _ := json.Marshal(out)
	return string(b)
}

func parseOne(line string) parsedLink {
	p := parsedLink{Link: line}
	scheme := strings.ToLower(line[:strings.Index(line, "://")])
	p.Protocol = scheme
	p.Name = linkName(line)
	var ob map[string]any
	var err error
	switch scheme {
	case "wireguard", "wg":
		ob, err = wireguardOutbound(line)
	case "socks5":
		ob, err = convertWithLibXray("socks://" + line[len("socks5://"):])
	case "vmess":
		ob, err = vmessOutbound(line)
	case "hysteria2", "hy2":
		ob, err = hysteria2Outbound(line)
	default:
		ob, err = convertWithLibXray(line)
	}
	if err != nil {
		p.Error = err.Error()
		return p
	}
	delete(ob, "tag")
	p.Outbound = ob
	if b, err := json.Marshal(ob); err == nil {
		p.OutboundJSON = string(b)
	}
	if proto, ok := ob["protocol"].(string); ok {
		p.Protocol = proto
	}
	p.Address, p.Port = outboundEndpoint(ob)
	if p.Address == "" {
		if u, e := url.Parse(line); e == nil {
			p.Address = u.Hostname()
			p.Port, _ = strconv.Atoi(u.Port())
		}
	}
	return p
}

func convertWithLibXray(line string) (map[string]any, error) {
	raw, err := share.ConvertShareLinksToXrayJson(line, "")
	if err != nil {
		return nil, err
	}
	var doc struct {
		Outbounds []map[string]any `json:"outbounds"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, err
	}
	if len(doc.Outbounds) == 0 {
		return nil, errString("no outbound")
	}
	return doc.Outbounds[0], nil
}

type errString string

func (e errString) Error() string { return string(e) }

func linkName(line string) string {
	if strings.HasPrefix(line, "vmess://") {
		if d, ok := tryBase64(line[len("vmess://"):]); ok {
			var m map[string]any
			if json.Unmarshal([]byte(d), &m) == nil {
				if ps, ok := m["ps"].(string); ok {
					return ps
				}
			}
		}
	}
	if i := strings.LastIndex(line, "#"); i >= 0 {
		if n, err := url.PathUnescape(line[i+1:]); err == nil {
			return strings.TrimSpace(n)
		}
		return line[i+1:]
	}
	return ""
}

func outboundEndpoint(ob map[string]any) (string, int) {
	settings, _ := ob["settings"].(map[string]any)
	if settings == nil {
		return "", 0
	}
	num := func(v any) int {
		switch n := v.(type) {
		case float64:
			return int(n)
		case int:
			return n
		case string:
			i, _ := strconv.Atoi(n)
			return i
		}
		return 0
	}
	if a, ok := settings["address"].(string); ok {
		return a, num(settings["port"])
	}
	for _, key := range []string{"vnext", "servers"} {
		if list, ok := settings[key].([]any); ok && len(list) > 0 {
			if s, ok := list[0].(map[string]any); ok {
				a, _ := s["address"].(string)
				return a, num(s["port"])
			}
		}
	}
	if peers, ok := settings["peers"].([]any); ok && len(peers) > 0 {
		if pm, ok := peers[0].(map[string]any); ok {
			if ep, ok := pm["endpoint"].(string); ok {
				h, port, err := net.SplitHostPort(ep)
				if err == nil {
					return h, num(port)
				}
			}
		}
	}
	return "", 0
}

// wireguard://PRIVATEKEY@host:port?publickey=..&address=10.0.0.2/32,fd00::2/128&presharedkey=..&mtu=1420&reserved=1,2,3#name
func wireguardOutbound(line string) (map[string]any, error) {
	u, err := url.Parse(line)
	if err != nil {
		return nil, err
	}
	q := u.Query()
	secret := u.User.Username()
	if secret == "" {
		secret = q.Get("privatekey")
	}
	if s, err := url.PathUnescape(secret); err == nil {
		secret = s
	}
	pub := firstNonEmpty(q.Get("publickey"), q.Get("public_key"), q.Get("peer_public_key"))
	if secret == "" || pub == "" || u.Hostname() == "" {
		return nil, errString("wireguard link needs private key, public key and endpoint")
	}
	addrs := []string{}
	for _, a := range strings.Split(firstNonEmpty(q.Get("address"), q.Get("ip"), "10.0.0.2/32"), ",") {
		a = strings.TrimSpace(a)
		if a == "" {
			continue
		}
		if !strings.Contains(a, "/") {
			if strings.Contains(a, ":") {
				a += "/128"
			} else {
				a += "/32"
			}
		}
		addrs = append(addrs, a)
	}
	port := u.Port()
	if port == "" {
		port = "51820"
	}
	peer := map[string]any{
		"publicKey":  pub,
		"endpoint":   net.JoinHostPort(u.Hostname(), port),
		"allowedIPs": []string{"0.0.0.0/0", "::/0"},
	}
	if psk := firstNonEmpty(q.Get("presharedkey"), q.Get("psk")); psk != "" {
		peer["preSharedKey"] = psk
	}
	if ka := q.Get("keepalive"); ka != "" {
		if n, err := strconv.Atoi(ka); err == nil {
			peer["keepAlive"] = n
		}
	}
	settings := map[string]any{
		"secretKey":   secret,
		"address":     addrs,
		"peers":       []any{peer},
		"noKernelTun": true,
	}
	if mtu, err := strconv.Atoi(q.Get("mtu")); err == nil && mtu > 0 {
		settings["mtu"] = mtu
	}
	if r := q.Get("reserved"); r != "" {
		var res []int
		for _, part := range strings.Split(r, ",") {
			if n, err := strconv.Atoi(strings.TrimSpace(part)); err == nil {
				res = append(res, n)
			}
		}
		if len(res) == 3 {
			settings["reserved"] = res
		}
	}
	return map[string]any{"protocol": "wireguard", "settings": settings}, nil
}

func firstNonEmpty(v ...string) string {
	for _, s := range v {
		if s != "" {
			return s
		}
	}
	return ""
}

// vmessOutbound accepts both the v2rayN base64 JSON form and the URL form.
func vmessOutbound(line string) (map[string]any, error) {
	body := line[len("vmess://"):]
	if i := strings.Index(body, "#"); i >= 0 && !strings.Contains(body[:i], "@") {
		body = body[:i]
	}
	if strings.Contains(body, "@") {
		return convertWithLibXray(line)
	}
	d, ok := tryBase64(body)
	if !ok {
		return nil, errString("bad vmess link")
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(d), &m); err != nil {
		return nil, errString("bad vmess json")
	}
	str := func(k string) string {
		switch v := m[k].(type) {
		case string:
			return v
		case float64:
			return strconv.Itoa(int(v))
		}
		return ""
	}
	q := url.Values{}
	net := firstNonEmpty(str("net"), "tcp")
	q.Set("type", net)
	if tls := str("tls"); tls != "" && tls != "none" {
		q.Set("security", tls)
	}
	set := func(key, v string) {
		if v != "" {
			q.Set(key, v)
		}
	}
	set("sni", str("sni"))
	set("fp", str("fp"))
	set("alpn", str("alpn"))
	set("encryption", str("scy"))
	host, path := str("host"), str("path")
	switch net {
	case "grpc":
		set("serviceName", path)
		if str("type") == "multi" {
			q.Set("mode", "multi")
		}
	case "kcp", "mkcp":
		set("seed", path)
		set("headerType", str("type"))
	default:
		set("host", host)
		set("path", path)
		if t := str("type"); t != "" && t != "none" {
			q.Set("headerType", t)
		}
	}
	if q.Get("security") == "tls" && q.Get("sni") == "" && host != "" {
		q.Set("sni", host)
	}
	u := url.URL{Scheme: "vmess", User: url.User(str("id")), Host: net2host(str("add"), str("port")), RawQuery: q.Encode(), Fragment: str("ps")}
	ob, err := convertWithLibXray(u.String())
	if err != nil {
		return nil, err
	}
	return ob, nil
}

func net2host(h, p string) string {
	if strings.Contains(h, ":") && !strings.HasPrefix(h, "[") {
		h = "[" + h + "]"
	}
	return h + ":" + p
}

// hysteria2Outbound converts hy2 links, including obfs=salamander which it
// adds as a UDP final mask. "insecure" is dropped: Xray no longer supports it,
// pinSHA256 is used instead when the link has it.
func hysteria2Outbound(line string) (map[string]any, error) {
	u, err := url.Parse(line)
	if err != nil {
		return nil, err
	}
	q := u.Query()
	obfs, obfsPass := q.Get("obfs"), q.Get("obfs-password")
	pin := firstNonEmpty(q.Get("pinSHA256"), q.Get("pcs"))
	for _, k := range []string{"obfs", "obfs-password", "insecure", "allowInsecure", "pinSHA256"} {
		q.Del(k)
	}
	u.RawQuery = q.Encode()
	ob, err := convertWithLibXray(u.String())
	if err != nil {
		return nil, err
	}
	ss, _ := ob["streamSettings"].(map[string]any)
	if ss == nil {
		ss = map[string]any{}
		ob["streamSettings"] = ss
	}
	if obfs == "salamander" && obfsPass != "" {
		ss["finalmask"] = map[string]any{"udp": []any{map[string]any{"type": "salamander", "settings": map[string]any{"password": obfsPass}}}}
	}
	if pin != "" {
		tls, _ := ss["tlsSettings"].(map[string]any)
		if tls == nil {
			tls = map[string]any{}
			ss["tlsSettings"] = tls
		}
		tls["pinnedPeerCertSha256"] = strings.ReplaceAll(strings.ToLower(pin), ":", "")
	}
	return ob, nil
}
