import Foundation

enum AppInfo {
    static let defaultAppGroup = "group.com.werx.aurora"

    /// The App Group really granted by the signing profile. Re-signing tools
    /// often rename it, so it is read from embedded.mobileprovision first.
    static let appGroup: String = {
        if let groups = Provision.current?.entitlements["com.apple.security.application-groups"] as? [String] {
            if let ours = groups.first(where: { $0.lowercased().contains("aurora") }) { return ours }
            if let first = groups.first { return first }
        }
        return defaultAppGroup
    }()

    /// Bundle id of the packet tunnel as it is in this install: re-signing can
    /// change bundle ids, so it is read from the extension itself.
    static var tunnelBundleID: String {
        if let plugins = Bundle.main.builtInPlugInsURL,
           let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) {
            for url in items where url.pathExtension == "appex" {
                guard let b = Bundle(url: url),
                      let ext = b.infoDictionary?["NSExtension"] as? [String: Any],
                      let point = ext["NSExtensionPointIdentifier"] as? String,
                      point.contains("packet-tunnel"), let id = b.bundleIdentifier else { continue }
                return id
            }
        }
        return (Bundle.main.bundleIdentifier ?? "com.werx.aurora") + ".tunnel"
    }

    static var tunnelPresent: Bool {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return false }
        return FileManager.default.fileExists(atPath: plugins.appendingPathComponent("Tunnel.appex").path)
            || ((try? FileManager.default.contentsOfDirectory(atPath: plugins.path))?.contains { $0.hasSuffix(".appex") } ?? false)
    }

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
}

/// What the signing profile allows (read from embedded.mobileprovision when
/// the signer kept it).
struct Provision {
    var name: String
    var team: String
    var expires: Date?
    var entitlements: [String: Any]
    var isEnterprise: Bool

    static let current: Provision? = load(Bundle.main)

    static func load(_ bundle: Bundle) -> Provision? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>") else { return nil }
        let xml = String(text[start.lowerBound..<end.upperBound])
        guard let d = xml.data(using: .utf8),
              let plist = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any] else { return nil }
        return Provision(name: plist["Name"] as? String ?? "—",
                         team: plist["TeamName"] as? String ?? "—",
                         expires: plist["ExpirationDate"] as? Date,
                         entitlements: plist["Entitlements"] as? [String: Any] ?? [:],
                         isEnterprise: plist["ProvisionsAllDevices"] as? Bool ?? false)
    }

    /// nil when unknown (no profile in the bundle).
    static func allowsPacketTunnel(_ p: Provision?) -> Bool? {
        guard let p else { return nil }
        let ne = p.entitlements["com.apple.developer.networking.networkextension"]
        if let list = ne as? [String] { return list.contains { $0.hasPrefix("packet-tunnel-provider") } }
        if let s = ne as? String { return s.hasPrefix("packet-tunnel-provider") }
        return false
    }

    static var tunnelProfile: Provision? {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil),
              let appex = items.first(where: { $0.pathExtension == "appex" }),
              let b = Bundle(url: appex) else { return nil }
        return load(b)
    }
}

/// Turns NetworkExtension failures into advice about the signature.
enum SigningAdvice {
    static func explain(_ error: Error) -> String {
        let ns = error as NSError
        let text = ns.localizedDescription
        let lower = text.lowercased()
        if ns.domain == "NEVPNErrorDomain" && (ns.code == 5 || ns.code == 1)
            || lower.contains("permission denied") || lower.contains("ipc failed") || lower.contains("entitlement") {
            return "iOS не дал создать VPN: сертификат или профиль подписи не разрешает Network Extension (Packet Tunnel). Нужен сертификат с этой возможностью — проверьте раздел «Подпись и VPN» в настройках. (\(text))"
        }
        return text
    }
}

// MARK: - Servers

struct ServerNode: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var proto: String
    var address: String
    var port: Int
    var link: String
    /// Xray outbound object as JSON text (already converted from the link).
    var outbound: String
    /// A complete Xray config supplied by a subscription or the user.
    var rawConfig: String?
    var groupID: UUID?
    var latency: Int?
    var testedAt: Date?
    var testError: String?
    var favorite = false
    var addedAt = Date()

    var flag: String {
        let scalars = name.unicodeScalars.filter { (0x1F1E6...0x1F1FF).contains($0.value) }
        if scalars.count >= 2 {
            var s = String.UnicodeScalarView()
            s.append(contentsOf: scalars.prefix(2))
            return String(s)
        }
        return ""
    }

    var displayName: String {
        var n = name
        let f = flag
        if !f.isEmpty { n = n.replacingOccurrences(of: f, with: "") }
        n = n.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "\(address):\(port)" : n
    }

    var protoLabel: String {
        switch proto {
        case "vless": return "VLESS"
        case "vmess": return "VMess"
        case "trojan": return "Trojan"
        case "shadowsocks": return "Shadowsocks"
        case "socks": return "SOCKS"
        case "hysteria": return "Hysteria2"
        case "wireguard": return "WireGuard"
        case "json": return "JSON"
        default: return proto.uppercased()
        }
    }

    var transportLabel: String {
        guard let d = outbound.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let ss = o["streamSettings"] as? [String: Any] else { return "" }
        var parts: [String] = []
        if let n = ss["network"] as? String, n != "raw", n != "tcp", n != "hysteria" { parts.append(n.uppercased()) }
        if let s = ss["security"] as? String, s != "none", !s.isEmpty { parts.append(s == "reality" ? "Reality" : s.uppercased()) }
        return parts.joined(separator: " · ")
    }
}

struct Subscription: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var url: String
    var autoUpdate = true
    var updateIntervalHours: Int = 12
    var lastUpdated: Date?
    var lastError: String?
    var upload: Int64 = 0
    var download: Int64 = 0
    var total: Int64 = 0
    var expire: Date?
    var supportURL: String?
    var webPageURL: String?
    var announce: String?
    var collapsed = false
    var userAgent: String?
    var serverCount = 0

    var used: Int64 { upload + download }
    var usedFraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }
    var daysLeft: Int? {
        guard let e = expire else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: e).day
    }
}

// MARK: - Routing

enum RouteMode: String, Codable, CaseIterable, Identifiable {
    case rule, global, direct
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rule: return "Правила"
        case .global: return "Глобально"
        case .direct: return "Напрямую"
        }
    }
}

struct RoutingProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var domainStrategy = "IPIfNonMatch"
    var bypassLAN = true
    var bypassRU = true
    var blockAds = false
    var blockQUIC = false
    var directDomains: [String] = []
    var directIPs: [String] = []
    var proxyDomains: [String] = []
    var proxyIPs: [String] = []
    var blockDomains: [String] = []
    var blockIPs: [String] = []
    var remoteDNS = "https://1.1.1.1/dns-query"
    var directDNS = "77.88.8.8"
    var fakeDNS = false
    var hosts: [String: String] = [:]
    var geoipURL = "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat"
    var geositeURL = "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat"
    var useGeoFiles = false

    static let russia = RoutingProfile(name: "Россия: напрямую РФ")
    static let global = RoutingProfile(name: "Всё через прокси", bypassRU: false)
}

// MARK: - Notifications (iOS)

enum NotificationLevel: String, Codable, CaseIterable, Identifiable {
    case passive, active, timeSensitive
    var id: String { rawValue }
    var title: String {
        switch self {
        case .passive: return "Тихо"
        case .active: return "Обычно"
        case .timeSensitive: return "Важно"
        }
    }
}

struct NotificationSettings: Codable, Hashable {
    var enabled = true
    var sound = true
    var level: NotificationLevel = .active
    var showServerName = true
    var badge = true
    // Connection
    var onConnect = false
    var onDisconnect = false
    var onConnectionLost = true
    var onReconnect = true
    var onNetworkChange = false
    var onServerSwitch = true
    // Subscription
    var expiryWarning = true
    var expiryDays = 3
    var quotaWarning = true
    var quotaPercent = 90
    var onSubscriptionUpdated = false
    var onSubscriptionError = true
    var announcements = true
    // Reports
    var sessionSummary = false
    var dailyReport = false
    var dailyReportHour = 21
    var trafficCap = false
    var trafficCapMB = 1024
    // Quiet hours
    var quietHours = false
    var quietFrom = 23
    var quietTo = 8

    func isQuiet(at date: Date = Date()) -> Bool {
        guard quietHours else { return false }
        let h = Calendar.current.component(.hour, from: date)
        if quietFrom == quietTo { return false }
        if quietFrom < quietTo { return h >= quietFrom && h < quietTo }
        return h >= quietFrom || h < quietTo
    }
}

// MARK: - Settings

enum PingMethod: String, Codable, CaseIterable, Identifiable {
    case url, tcp
    var id: String { rawValue }
    var title: String { self == .url ? "Реальная задержка (URL)" : "TCP-подключение" }
}

enum ServerSort: String, Codable, CaseIterable, Identifiable {
    case manual, name, latency
    var id: String { rawValue }
    var title: String {
        switch self {
        case .manual: return "Как в подписке"
        case .name: return "По имени"
        case .latency: return "По пингу"
        }
    }
}

enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Как в системе"
        case .light: return "Светлая"
        case .dark: return "Тёмная"
        }
    }
}

struct AppSettings: Codable, Hashable {
    var mode: RouteMode = .rule
    var routingID: UUID?
    var autoSelect = false
    var autoSelectGroupID: UUID?
    var autopilotAllGroups = true
    var autopilotNetworkAware = true
    var autopilotPoolSize = 6
    var autopilotScanOnOpen = true
    // Tunnel
    var mtu = 9000
    var bufferKB = 64
    var ipv6 = false
    var killSwitch = false
    var excludeLocal = true
    // Push notifications go through the VPN by default: under mobile
    // whitelists they only arrive reliably that way.
    var excludeAPNs = false
    var apnsViaProxy = true
    var useConfigDNS = true
    var connIdle = 300
    var excludeCellularServices = true
    var onDemand = false
    var onDemandWiFi = true
    var onDemandCellular = true
    var onDemandTrustedSSIDs: [String] = []
    var reconnectOnNetworkChange = true
    var sniffing = true
    var routeOnly = true
    var memoryLimitMB = 40
    var logLevel = "warning"
    // Proxy
    var muxEnabled = false
    var muxConcurrency = 8
    var fragmentEnabled = false
    var fragmentPackets = "tlshello"
    var fragmentLength = "100-200"
    var fragmentInterval = "10-20"
    var localSocksPort = 0
    var localHTTPPort = 0
    /// Password of the local SOCKS/HTTP ports (user "aurora"), made on first use.
    var localProxyPassword = ""
    var lanShare = false
    var chainServerID: UUID?
    // Ping
    var pingMethod: PingMethod = .url
    var pingURL = "https://www.gstatic.com/generate_204"
    var pingTimeoutMs = 5000
    var autoPingOnOpen = false
    var sort: ServerSort = .manual
    // Subscriptions
    var subscriptionUA = "Happ/3.2.0"
    var sendHWID = true
    var updateSubsOnLaunch = true
    // Look
    var theme: AppTheme = .system
    var accent = 0
    var haptics = true
    var showSpeedOnHome = true

    var notifications = NotificationSettings()
}

// MARK: - Messages between app and tunnel

struct TunnelStats: Codable {
    var up: Int64 = 0
    var down: Int64 = 0
    var directUp: Int64 = 0
    var directDown: Int64 = 0
    var uptime: Int64 = 0
    var memory: UInt64 = 0
    var best: String?
    var bestName: String?
    var network: String?
    /// Balancer members as the core's observatory last saw them.
    var members: [Member]?

    struct Member: Codable {
        var tag: String
        var alive: Bool
        var delay: Int64
    }

    /// Alive and total members of the autopilot pool; nil without a balancer.
    var aliveCount: (alive: Int, total: Int)? {
        guard let m = members, !m.isEmpty else { return nil }
        return (m.filter(\.alive).count, m.count)
    }
}

/// Everything the tunnel needs to start, saved in the VPN configuration.
struct TunnelPayload: Codable {
    var licenseToken: String?
    var options: String            // BuildOptions JSON for corebridge.BuildConfig
    var serverName: String
    var serverAddresses: [String]
    var mtu: Int
    var ipv6: Bool
    var excludeLocal: Bool
    var memoryLimitMB: Int
    var reconnectOnNetworkChange: Bool
    var notifications: NotificationSettings
    var geoipURL: String?
    var geositeURL: String?
    var groupNames: [String: String] = [:]   // outbound tag -> server name, for switch notifications
    var subscriptionTotal: Int64 = 0
    var subscriptionUsed: Int64 = 0
    var subscriptionExpire: Date?
    // Autopilot: options and member names for each kind of network.
    var optionsWifi: String?
    var optionsCellular: String?
    var namesWifi: [String: String]?
    var namesCellular: [String: String]?
}

enum TunnelCommand: String, Codable {
    case stats, logs, clearLogs, reload, updateGeo, status, notifyTest, license
}

struct TunnelRequest: Codable {
    var command: TunnelCommand
    var payload: Data?
}

// MARK: - Formatting

enum Fmt {
    static func bytes(_ v: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: v)
    }

    static func speed(_ v: Double) -> String {
        bytes(Int64(max(0, v))) + "/с"
    }

    static func duration(_ s: Int64) -> String {
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: d)
    }

    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

extension String {
    /// Decodes standard or URL-safe base64, with or without padding.
    func base64Decoded() -> String? {
        var s = trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    var base64Encoded: String { Data(utf8).base64EncodedString() }

    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
