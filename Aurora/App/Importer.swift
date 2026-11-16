import Foundation

/// What a piece of text (clipboard, QR, deep link, file) turned out to be.
enum ImportItem {
    case servers([ServerNode])
    case subscription(url: String, name: String?)
    case routing(RoutingProfile)
    case backup(Data)
    case nothing(String)
}

enum Importer {
    static let linkSchemes = ["vless", "vmess", "trojan", "ss", "socks", "socks5", "hysteria2", "hy2", "wireguard", "wg"]

    static func nodes(fromLinks text: String) -> (nodes: [ServerNode], errors: [String]) {
        var nodes: [ServerNode] = []
        var errors: [String] = []
        for p in Core.parseLinks(text) {
            if let ob = p.outboundJSON {
                nodes.append(ServerNode(name: p.name.isEmpty ? "\(p.address):\(p.port)" : p.name, proto: p.protocol,
                                        address: p.address, port: p.port, link: p.link, outbound: ob))
            } else if let e = p.error {
                errors.append("\(p.name.isEmpty ? String(p.link.prefix(30)) : p.name): \(e)")
            }
        }
        return (nodes, errors)
    }

    /// A full Xray config as one server: its first proxy outbound is used for
    /// tests, the whole config for connecting.
    static func node(fromConfig cfg: [String: Any]) -> ServerNode? {
        guard let outbounds = cfg["outbounds"] as? [[String: Any]] else { return nil }
        let proxy = outbounds.first { ob in
            let p = ob["protocol"] as? String ?? ""
            return !["freedom", "blackhole", "dns", "loopback"].contains(p)
        }
        guard let proxy else { return nil }
        var ob = proxy
        ob.removeValue(forKey: "tag")
        let name = (cfg["remarks"] as? String) ?? (cfg["remark"] as? String) ?? (proxy["tag"] as? String) ?? "Xray JSON"
        let ep = endpoint(ob)
        return ServerNode(name: name, proto: "json", address: ep.0, port: ep.1, link: "",
                          outbound: JSON.string(ob), rawConfig: JSON.string(cfg, pretty: true))
    }

    static func endpoint(_ ob: [String: Any]) -> (String, Int) {
        guard let s = ob["settings"] as? [String: Any] else { return ("", 0) }
        if let a = s["address"] as? String { return (a, s["port"] as? Int ?? 0) }
        for key in ["vnext", "servers"] {
            if let list = s[key] as? [[String: Any]], let first = list.first {
                return (first["address"] as? String ?? "", first["port"] as? Int ?? 0)
            }
        }
        if let peers = s["peers"] as? [[String: Any]], let ep = peers.first?["endpoint"] as? String {
            let parts = ep.split(separator: ":")
            return (parts.dropLast().joined(separator: ":"), Int(parts.last ?? "") ?? 0)
        }
        return ("", 0)
    }

    /// Recognises any supported input.
    static func classify(_ raw: String) -> ImportItem {
        let text = raw.trimmed
        guard !text.isEmpty else { return .nothing("Пусто") }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["aurora", "happ", "v2raytun", "incy", "v2rayng", "streisand", "sing-box", "hiddify"].contains(scheme) {
            return deepLink(url, raw: text)
        }
        if text.hasPrefix("{") || text.hasPrefix("[") {
            if let d = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) {
                if let dict = obj as? [String: Any] {
                    if dict["auroraBackup"] != nil { return .backup(d) }
                    if dict["DirectSites"] != nil || dict["GlobalProxy"] != nil || dict["Name"] != nil && dict["outbounds"] == nil {
                        if let p = routingProfile(fromHapp: dict) { return .routing(p) }
                    }
                }
                let nodes = SubscriptionService.jsonNodes(text)
                if !nodes.isEmpty { return .servers(nodes) }
            }
            return .nothing("Не похоже на конфиг Xray")
        }
        let lower = text.lowercased()
        if (lower.hasPrefix("http://") || lower.hasPrefix("https://")) && !text.contains("\n") {
            return .subscription(url: text, name: nil)
        }
        let decoded = Core.decodeSubscription(text)
        let parsed = nodes(fromLinks: decoded)
        if !parsed.nodes.isEmpty { return .servers(parsed.nodes) }
        return .nothing(parsed.errors.first ?? "Ссылки не распознаны")
    }

    /// aurora://add/<url>, happ://add/<url>, v2raytun://import/<url>,
    /// aurora://routing/add/<base64>, happ://routing/onadd/<base64>,
    /// aurora://import/<base64 links>, sing-box://import-remote-profile?url=…
    static func deepLink(_ url: URL, raw: String) -> ImportItem {
        let scheme = url.scheme ?? ""
        var rest = String(raw.dropFirst(scheme.count + 3))
        if let q = URLComponents(string: raw)?.queryItems?.first(where: { $0.name == "url" })?.value, rest.hasPrefix("import-remote-profile") {
            return .subscription(url: q, name: URLComponents(string: raw)?.fragment)
        }
        if rest.hasPrefix("routing/") {
            rest = String(rest.dropFirst("routing/".count))
            for prefix in ["onadd/", "add/"] where rest.hasPrefix(prefix) { rest = String(rest.dropFirst(prefix.count)) }
            let b64 = rest.removingPercentEncoding ?? rest
            if let json = b64.base64Decoded() ?? Optional(b64),
               let d = json.data(using: .utf8),
               let dict = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
               let p = routingProfile(fromHapp: dict) {
                return .routing(p)
            }
            return .nothing("Профиль маршрутизации не распознан")
        }
        if rest.hasPrefix("crypt") {
            return .nothing("Зашифрованные ссылки Happ (happ://crypt) расшифровывает только Happ. Попросите у провайдера обычную ссылку на подписку.")
        }
        for prefix in ["add/", "import/", "install-config?url=", "install-sub?url=", "subscription/"] where rest.hasPrefix(prefix) {
            let value = String(rest.dropFirst(prefix.count))
            let decodedValue = value.removingPercentEncoding ?? value
            let lower = decodedValue.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                let parts = decodedValue.split(separator: "#", maxSplits: 1)
                return .subscription(url: String(parts[0]), name: parts.count > 1 ? String(parts[1]) : nil)
            }
            if linkSchemes.contains(where: { lower.hasPrefix($0 + "://") }) {
                return classify(decodedValue)
            }
            if let b = decodedValue.base64Decoded() { return classify(b) }
        }
        return .nothing("Ссылка \(scheme):// не распознана")
    }

    private static func flag(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let s = v as? String { return ["true", "1", "yes"].contains(s.lowercased()) }
        if let n = v as? Int { return n != 0 }
        return nil
    }

    private static func list(_ v: Any?) -> [String] {
        if let a = v as? [String] { return a.map(\.trimmed).filter { !$0.isEmpty } }
        if let s = v as? String { return s.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { String($0).trimmed }.filter { !$0.isEmpty } }
        return []
    }

    /// Reads a Happ routing profile (also accepts our own field names).
    static func routingProfile(fromHapp d: [String: Any]) -> RoutingProfile? {
        var p = RoutingProfile(name: (d["Name"] as? String) ?? (d["name"] as? String) ?? "Импортированный профиль")
        p.bypassRU = false
        p.directDomains = list(d["DirectSites"] ?? d["directDomains"])
        p.directIPs = list(d["DirectIp"] ?? d["directIPs"])
        p.proxyDomains = list(d["ProxySites"] ?? d["proxyDomains"])
        p.proxyIPs = list(d["ProxyIp"] ?? d["proxyIPs"])
        p.blockDomains = list(d["BlockSites"] ?? d["blockDomains"])
        p.blockIPs = list(d["BlockIp"] ?? d["blockIPs"])
        if let s = d["DomainStrategy"] as? String ?? d["domainStrategy"] as? String { p.domainStrategy = s }
        if let f = flag(d["FakeDNS"] ?? d["fakeDNS"]) { p.fakeDNS = f }
        let remoteType = (d["RemoteDNSType"] as? String ?? "DoH").lowercased()
        if let dom = d["RemoteDNSDomain"] as? String, !dom.isEmpty, remoteType == "doh" { p.remoteDNS = dom }
        else if let ip = d["RemoteDNSIP"] as? String, !ip.isEmpty { p.remoteDNS = remoteType == "doh" ? "https://\(ip)/dns-query" : ip }
        if let ip = d["DomesticDNSIP"] as? String, !ip.isEmpty { p.directDNS = ip }
        if let u = d["Geoipurl"] as? String ?? d["geoipURL"] as? String, !u.isEmpty { p.geoipURL = u; p.useGeoFiles = true }
        if let u = d["Geositeurl"] as? String ?? d["geositeURL"] as? String, !u.isEmpty { p.geositeURL = u; p.useGeoFiles = true }
        if let hosts = d["DnsHosts"] as? [String: String] ?? d["hosts"] as? [String: String] { p.hosts = hosts }
        if p.directDomains.contains(where: { $0.contains("geosite:ru") || $0.contains("category-ru") }) || p.directIPs.contains("geoip:ru") {
            p.useGeoFiles = true
        }
        p.bypassLAN = true
        return p
    }

    /// Our routing profile in Happ's format, for sharing.
    static func happRouting(_ p: RoutingProfile) -> [String: Any] {
        [
            "Name": p.name, "GlobalProxy": "true", "DomainStrategy": p.domainStrategy, "FakeDNS": p.fakeDNS ? "true" : "false",
            "RemoteDNSType": p.remoteDNS.hasPrefix("https") ? "DoH" : "DoU", "RemoteDNSDomain": p.remoteDNS.hasPrefix("https") ? p.remoteDNS : "",
            "RemoteDNSIP": p.remoteDNS.hasPrefix("https") ? "" : p.remoteDNS, "DomesticDNSType": "DoU", "DomesticDNSIP": p.directDNS,
            "Geoipurl": p.useGeoFiles ? p.geoipURL : "", "Geositeurl": p.useGeoFiles ? p.geositeURL : "",
            "DirectSites": p.directDomains, "DirectIp": p.directIPs, "ProxySites": p.proxyDomains, "ProxyIp": p.proxyIPs,
            "BlockSites": p.blockDomains, "BlockIp": p.blockIPs, "DnsHosts": p.hosts,
        ]
    }
}
