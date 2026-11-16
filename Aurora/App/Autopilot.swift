import Foundation
import Network

enum NetKind: String, Codable {
    case wifi, cellular, other

    var title: String {
        switch self {
        case .wifi: return "Wi‑Fi"
        case .cellular: return "сотовая"
        case .other: return "сеть"
        }
    }
}

/// Reads the hints providers put into server names.
enum ServerHints {
    static let cellularWords = ["sim", "глушилк", "lte", "4g", "5g", "моб", "mobile", "белы", "whitelist", "white list",
                                "мтс", "mts", "билайн", "beeline", "мегафон", "megafon", "tele2", "теле2", "t2 ", "yota", "йота", "cell"]
    static let wifiWords = ["wi-fi", "wifi", "wi fi", "вайфай", "вай-фай", "home", "домаш", "провод", "broadband"]

    static func cellular(_ n: ServerNode) -> Bool {
        let s = n.name.lowercased()
        return cellularWords.contains { s.contains($0) }
    }

    static func wifi(_ n: ServerNode) -> Bool {
        let s = n.name.lowercased()
        return wifiWords.contains { s.contains($0) }
    }

    static func russian(_ n: ServerNode) -> Bool { AppModel.isRussian(n) }
}

struct HealthRecord: Codable {
    var latency: Double?
    var ok = 0
    var fail = 0
    var lastOK: Date?
    var lastTest: Date?

    var failRate: Double {
        let total = ok + fail
        return total == 0 ? 0 : Double(fail) / Double(total)
    }
}

/// Chooses servers for the current network from what the subscription
/// offers: name hints, a whitelist probe and each server's track record.
@MainActor
final class Autopilot: ObservableObject {
    @Published private(set) var network: NetKind = .other
    /// The physical interface under the current path (en0, pdp_ip0), so
    /// server tests can go around the tunnel while the VPN is on.
    private(set) var physicalInterface: String?
    @Published private(set) var whitelist: Bool?
    @Published private(set) var lastProbe: Date?
    private(set) var health: [String: HealthRecord]
    private var analyses: [String: Core.Analysis] = [:]

    /// What the config itself says about the server (cached per config).
    func analysis(_ n: ServerNode) -> Core.Analysis? {
        let k = n.id.uuidString + "#" + String((n.rawConfig ?? n.outbound).hashValue) + n.name
        if let a = analyses[k] { return a }
        let a = Core.analyze(n)
        analyses[k] = a
        return a
    }

    /// 0..100 fitness of a server for a network, from its config.
    func fitness(_ n: ServerNode, kind: NetKind) -> Int {
        guard let a = analysis(n) else { return 50 }
        switch kind {
        case .cellular: return a.cellular
        case .wifi: return a.wifi
        case .other: return (a.wifi + a.cellular) / 2
        }
    }
    private let monitor = NWPathMonitor()
    var onNetworkChange: ((NetKind) -> Void)?

    init() {
        health = Storage.load([String: HealthRecord].self, "health") ?? [:]
        monitor.pathUpdateHandler = { [weak self] path in
            let kind: NetKind = path.usesInterfaceType(.wifi) ? .wifi : (path.usesInterfaceType(.cellular) ? .cellular : .other)
            let physical = path.availableInterfaces.first { $0.type == .wifi || $0.type == .cellular || $0.type == .wiredEthernet }?.name
            Task { @MainActor in
                guard let self else { return }
                let changed = self.network != kind
                self.network = kind
                // With the VPN up the path may list only the tunnel; the usual
                // names of the Wi‑Fi and cellular interfaces stand in then.
                self.physicalInterface = physical ?? (kind == .wifi ? "en0" : (kind == .cellular ? "pdp_ip0" : nil))
                if changed {
                    self.whitelist = nil
                    self.onNetworkChange?(kind)
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "aurora.autopilot"))
    }

    private func key(_ id: UUID, _ kind: NetKind) -> String { "\(id.uuidString)|\(kind.rawValue)" }

    func record(_ results: [UUID: (Int, String?)], kind: NetKind? = nil) {
        let k = kind ?? network
        for (id, r) in results {
            var h = health[key(id, k)] ?? HealthRecord()
            h.lastTest = Date()
            if r.0 > 0 {
                h.ok += 1
                h.lastOK = Date()
                // Exponential average: recent results weigh more.
                h.latency = h.latency.map { $0 * 0.6 + Double(r.0) * 0.4 } ?? Double(r.0)
            } else {
                h.fail += 1
            }
            // Old history fades so a server can recover.
            if h.ok + h.fail > 20 { h.ok = h.ok * 3 / 4; h.fail = h.fail * 3 / 4 }
            health[key(id, k)] = h
        }
        Storage.save(health, "health")
    }

    func record(for id: UUID, kind: NetKind? = nil) -> HealthRecord? { health[key(id, kind ?? network)] }

    /// Lower is better.
    func score(_ n: ServerNode, kind: NetKind) -> Double {
        // The config's own fitness for this network: 100 -> x0.6, 0 -> x1.6.
        // Under detected whitelists on cellular it counts twice as much.
        let fit = Double(fitness(n, kind: kind))
        var weight = 1.6 - fit / 100
        if kind == .cellular && whitelist == true { weight = weight * weight * 1.2 }
        guard let h = health[key(n.id, kind)] else {
            // Untested: the last plain test if any, else judged by the config alone.
            if let l = n.latency { return (l > 0 ? Double(l) : 50_000) * weight }
            return 1500 * weight
        }
        let base = h.latency ?? 5000
        var s = base * (1 + 3 * h.failRate) * weight
        if let last = h.lastOK, Date().timeIntervalSince(last) > 6 * 3600 { s *= 1.3 }
        if h.ok == 0 && h.fail >= 2 { s += 50_000 }
        return s
    }

    /// The servers that suit a network best, fastest and most reliable first.
    func pool(from nodes: [ServerNode], kind: NetKind, size: Int, useHints: Bool) -> [ServerNode] {
        var base = nodes
        if useHints {
            let preferred: [ServerNode]
            switch kind {
            case .cellular:
                preferred = nodes.filter { ServerHints.cellular($0) || (whitelist == true && ServerHints.russian($0)) || fitness($0, kind: .cellular) >= 75 }
            case .wifi:
                preferred = nodes.filter { ServerHints.wifi($0) || (!ServerHints.cellular($0) && !nodes.contains(where: ServerHints.wifi)) }
            case .other:
                preferred = []
            }
            if !preferred.isEmpty { base = preferred }
        }
        let sorted = base.sorted { score($0, kind: kind) < score($1, kind: kind) }
        return Array(sorted.prefix(max(1, size)))
    }

    /// With the VPN off: is only the Russian internet reachable?
    func probeWhitelist() async {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4
        cfg.timeoutIntervalForResource = 5
        let session = URLSession(configuration: cfg)
        func reachable(_ s: String) async -> Bool {
            guard let url = URL(string: s) else { return false }
            var req = URLRequest(url: url)
            req.httpMethod = "HEAD"
            return (try? await session.data(for: req)) != nil
        }
        async let foreign1 = reachable("https://www.google.com/generate_204")
        async let foreign2 = reachable("https://www.cloudflare.com/cdn-cgi/trace")
        async let local = reachable("https://ya.ru")
        let (f1, f2, l) = await (foreign1, foreign2, local)
        session.invalidateAndCancel()
        lastProbe = Date()
        if !l && !f1 && !f2 { whitelist = nil; return }
        whitelist = l && !f1 && !f2
    }

    var summary: String {
        var s = "Сеть: \(network.title)"
        switch whitelist {
        case true?: s += " · белые списки"
        case false?: s += " · интернет открыт"
        case nil: break
        }
        return s
    }
}
