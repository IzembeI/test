package corebridge

import (
	"encoding/json"
	"net"
	"strconv"
	"strings"
)

// analysis is what Analyze finds out about a server from its config alone.
type analysis struct {
	Cellular int      `json:"cellular"` // 0..100: chance to work on mobile internet with whitelists
	WiFi     int      `json:"wifi"`     // 0..100: expected quality on an open network
	DPI      int      `json:"dpi"`      // 0..100: resistance to DPI blocking
	Traits   []string `json:"traits"`   // short labels
	Notes    []string `json:"notes"`    // explanations in Russian
}

var ruSNI = []string{".ru", ".su", ".xn--p1ai", "vk.com", "vk.me", "userapi.com", "yandex", "ya.ru", "mail.ru", "ok.ru", "mycdn.me",
	"gosuslugi", "sber", "tbank", "tinkoff", "ozon", "wildberries", "wb.ru", "avito", "max.ru", "rutube", "kinopoisk", "mts",
	"beeline", "megafon", "tele2", "rzd", "x5", "dzen", "2gis", "vkvideo", "kaspersky"}

var bigForeignSNI = []string{"microsoft", "apple", "icloud", "google", "gstatic", "cloudflare", "amazon", "aws", "github",
	"yahoo", "samsung", "nvidia", "intel", "oracle", "speedtest", "dl.google", "addons.mozilla"}

func containsAny(s string, list []string) bool {
	for _, x := range list {
		if strings.Contains(s, x) {
			return true
		}
	}
	return false
}

func clamp(v int) int {
	if v < 0 {
		return 0
	}
	if v > 100 {
		return 100
	}
	return v
}

// Analyze inspects one server: itemJSON is {"outbound": {...}} or
// {"config": "<full Xray JSON>"}, with an optional "name". It returns the
// analysis as JSON.
func Analyze(itemJSON string) string {
	var it struct {
		testItem
		Name string `json:"name"`
	}
	if err := json.Unmarshal([]byte(itemJSON), &it); err != nil {
		return `{"cellular":0,"wifi":0,"dpi":0,"traits":[],"notes":["не удалось прочитать конфиг"]}`
	}
	ob := it.Outbound
	var deps []map[string]any
	if strings.TrimSpace(it.Config) != "" {
		m, d, err := extractChain(it.Config, "dep-")
		if err != nil {
			return `{"cellular":0,"wifi":0,"dpi":0,"traits":[],"notes":["в конфиге нет прокси-подключения"]}`
		}
		ob, deps = m, d
		if strings.Contains(it.Config, `"balancers"`) {
			// A provider-side balancer: several servers behind one entry.
		}
	}
	a := analyzeOutbound(ob, deps, it.Name, it.Config)
	b, _ := json.Marshal(a)
	return string(b)
}

func analyzeOutbound(ob map[string]any, deps []map[string]any, name string, rawConfig string) analysis {
	a := analysis{Traits: []string{}, Notes: []string{}}
	if ob == nil {
		a.Notes = append(a.Notes, "нет данных о сервере")
		return a
	}
	proto := str(ob["protocol"])
	ss, _ := ob["streamSettings"].(map[string]any)
	network := strings.ToLower(str(ss["network"]))
	if network == "" || network == "tcp" {
		network = "raw"
	}
	security := strings.ToLower(str(ss["security"]))
	host, port := outboundEndpoint(ob)
	sni := ""
	if t, ok := ss["tlsSettings"].(map[string]any); ok {
		sni = strings.ToLower(str(t["serverName"]))
	}
	if r, ok := ss["realitySettings"].(map[string]any); ok {
		sni = strings.ToLower(str(r["serverName"]))
	}
	if sni == "" && net.ParseIP(host) == nil {
		sni = strings.ToLower(host)
	}
	flow := ""
	if s, ok := ob["settings"].(map[string]any); ok {
		flow = str(s["flow"])
		if flow == "" && hasFlow(ob) {
			flow = "xtls-rprx-vision"
		}
		if m := str(s["method"]); m != "" {
			proto += ":" + m
		}
	}
	lowName := strings.ToLower(name)
	ruServer := strings.Contains(name, "🇷🇺") || containsAny(lowName, []string{"россия", "russia", "moscow", "москва", "сибирь", "спб", "[ru]"})
	if strings.HasSuffix(host, ".ru") {
		ruServer = true
	}

	dpi, cell, wifi := 50, 0, 0
	note := func(s string) { a.Notes = append(a.Notes, s) }
	trait := func(s string) { a.Traits = append(a.Traits, s) }

	// Protocol
	switch {
	case proto == "vless":
		dpi += 5
		trait("VLESS")
	case proto == "trojan":
		trait("Trojan")
	case proto == "vmess":
		dpi -= 5
		trait("VMess")
	case strings.HasPrefix(proto, "shadowsocks"):
		if strings.Contains(proto, "2022") {
			dpi -= 5
			trait("SS-2022")
		} else {
			dpi -= 20
			trait("Shadowsocks")
			note("Классический Shadowsocks легко распознаётся DPI.")
		}
	case proto == "hysteria":
		trait("Hysteria2 (UDP)")
		wifi += 15
		cell -= 25
		note("Hysteria2 очень быстрый на открытых сетях, но работает по UDP — на мобильном интернете с ограничениями UDP часто режут.")
	case proto == "wireguard":
		dpi -= 30
		cell -= 20
		trait("WireGuard")
		note("WireGuard в России блокируется по сигнатуре протокола.")
	case proto == "socks" || proto == "http":
		dpi -= 40
		trait(strings.ToUpper(proto))
		note("Прокси без шифрования — виден провайдеру.")
	}

	// Security
	switch security {
	case "reality":
		dpi += 35
		cell += 10
		trait("Reality")
		note("Reality маскируется под настоящий сайт — самый устойчивый к блокировкам вариант.")
	case "tls":
		dpi += 15
		trait("TLS")
	default:
		if proto != "hysteria" && proto != "wireguard" && !strings.HasPrefix(proto, "shadowsocks") {
			dpi -= 25
			trait("без шифрования транспорта")
		}
	}

	// Transport
	switch network {
	case "xhttp", "splithttp":
		dpi += 15
		wifi += 5
		trait("XHTTP")
		note("XHTTP — современный транспорт, хорошо проходит через DPI и CDN.")
	case "grpc":
		dpi += 5
		wifi -= 5
		trait("gRPC")
	case "ws", "websocket":
		trait("WebSocket")
		wifi -= 5
	case "httpupgrade":
		trait("HTTPUpgrade")
	case "kcp", "mkcp":
		dpi -= 10
		cell -= 15
		trait("mKCP (UDP)")
	case "raw":
		if security == "reality" && strings.Contains(flow, "vision") {
			dpi += 10
			wifi += 10
			trait("Vision")
			note("Reality + Vision: минимум накладных расходов — обычно самая высокая скорость.")
		}
	}

	// Port
	switch port {
	case 443:
		dpi += 10
		cell += 5
	case 80, 8443, 2053, 2083, 2087, 2096, 8080:
	default:
		if port > 0 {
			dpi -= 5
			cell -= 15
			trait("порт " + strconv.Itoa(port))
			note("Нестандартный порт " + strconv.Itoa(port) + " — на мобильных сетях с ограничениями часто закрыт.")
		}
	}

	// Camouflage domain
	if sni != "" {
		switch {
		case containsAny(sni, ruSNI):
			cell += 35
			trait("SNI " + sni)
			note("Маскировка под российский сайт " + sni + " — такие обычно в «белых списках» мобильных операторов.")
		case containsAny(sni, bigForeignSNI):
			wifi += 5
			cell -= 10
			trait("SNI " + sni)
			note("Маскировка под зарубежный сайт " + sni + ": на открытом интернете отлично, при белых списках — может не пройти.")
		default:
			trait("SNI " + sni)
		}
	}

	// Server location from the name
	if ruServer {
		cell += 20
		wifi -= 5
		trait("сервер в РФ")
		note("Сервер в России: его адрес скорее всего разрешён при белых списках; для зарубежных сайтов — лишний переход.")
	}

	// Hints in the name
	if containsAny(lowName, []string{"sim", "глушилк", "lte", "моб", "белы"}) {
		cell += 25
		trait("для мобильной сети")
	}
	if containsAny(lowName, []string{"wi-fi", "wifi", "вайфай"}) {
		wifi += 15
		cell -= 10
		trait("для Wi‑Fi")
	}

	// Helpers in the chain
	for _, d := range deps {
		if s, ok := d["settings"].(map[string]any); ok {
			if _, frag := s["fragment"]; frag {
				dpi += 10
				cell += 5
				trait("фрагментация")
				note("В конфиге включена фрагментация TLS — помогает против DPI.")
			}
		}
	}
	if strings.Contains(rawConfig, `"balancers"`) {
		trait("балансировщик провайдера")
		note("Внутри — несколько серверов провайдера с автовыбором.")
	}
	if _, ok := ob["mux"].(map[string]any); ok {
		trait("Mux")
	}

	a.DPI = clamp(dpi)
	a.Cellular = clamp(a.DPI/2 + 25 + cell)
	a.WiFi = clamp(a.DPI/2 + 40 + wifi)
	return a
}
