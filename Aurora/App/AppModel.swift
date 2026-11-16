import Foundation
import SwiftUI
import NetworkExtension
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published var servers: [ServerNode] = [] { didSet { Storage.save(servers, "servers") } }
    @Published var subscriptions: [Subscription] = [] { didSet { Storage.save(subscriptions, "subscriptions") } }
    @Published var routings: [RoutingProfile] = [] { didSet { Storage.save(routings, "routings") } }
    @Published var settings = AppSettings() { didSet { Storage.save(settings, "settings") } }
    @Published var selectedID: UUID? { didSet { Storage.defaults.set(selectedID?.uuidString, forKey: "selected") } }

    @Published var stats = TunnelStats()
    @Published var upSpeed: Double = 0
    @Published var downSpeed: Double = 0
    @Published var speedHistory: [Double] = Array(repeating: 0, count: 60)
    @Published var testing: Set<UUID> = []
    @Published var updatingSubs: Set<UUID> = []
    @Published var toast: String?
    @Published var pendingImport: ImportItem?
    @Published var announcement: (title: String, text: String)?

    let vpn = VPNController()
    let autopilot = Autopilot()
    @Published var autopilotBusy = false
    private var pollTask: Task<Void, Never>?
    private var lastStats: TunnelStats?
    private var lastStatsAt = Date()

    init() {
        servers = Storage.load([ServerNode].self, "servers") ?? []
        subscriptions = Storage.load([Subscription].self, "subscriptions") ?? []
        routings = Storage.load([RoutingProfile].self, "routings") ?? [.russia, .global]
        if routings.isEmpty { routings = [.russia, .global] }
        settings = Storage.loadMerged(AppSettings.self, "settings", defaults: AppSettings())
        if let s = Storage.defaults.string(forKey: "selected") { selectedID = UUID(uuidString: s) }
        if settings.routingID == nil { settings.routingID = routings.first?.id }
        migrate()
        autopilot.onNetworkChange = { [weak self] _ in
            guard let self else { return }
            Task { await self.classifyNetwork() }
        }
    }

    /// One-time updates of saved settings when defaults change.
    private func migrate() {
        let v = Storage.defaults.integer(forKey: "settingsVersion")
        if v < 2 {
            // Larger packets and buffers: much faster with the userspace TCP stack.
            if settings.mtu == 1500 { settings.mtu = 9000 }
            for i in routings.indices where routings[i].domainStrategy == "IPIfNonMatch" && !routings[i].useGeoFiles {
                routings[i].domainStrategy = "AsIs"
            }
        }
        Storage.defaults.set(2, forKey: "settingsVersion")
    }

    // MARK: Derived

    var selected: ServerNode? { servers.first { $0.id == selectedID } ?? servers.first }
    var routing: RoutingProfile { routings.first { $0.id == settings.routingID } ?? routings.first ?? .russia }

    func servers(in groupID: UUID?) -> [ServerNode] {
        let list = servers.filter { $0.groupID == groupID }
        switch settings.sort {
        case .manual: return list
        case .name: return list.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
        case .latency:
            return list.sorted { a, b in
                let la = (a.latency ?? -1) < 0 ? Int.max : a.latency!
                let lb = (b.latency ?? -1) < 0 ? Int.max : b.latency!
                return la < lb
            }
        }
    }

    func subscription(for node: ServerNode?) -> Subscription? {
        guard let g = node?.groupID else { return nil }
        return subscriptions.first { $0.id == g }
    }

    var totalUp: Double { Storage.defaults.double(forKey: "total.up") }
    var totalDown: Double { Storage.defaults.double(forKey: "total.down") }

    func dailyTraffic(days: Int = 7) -> [(String, Double)] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let label = DateFormatter()
        label.locale = Locale(identifier: "ru_RU")
        label.dateFormat = "EE"
        return (0..<days).reversed().map { i in
            let d = Calendar.current.date(byAdding: .day, value: -i, to: Date())!
            return (label.string(from: d), Storage.defaults.double(forKey: "day." + f.string(from: d)))
        }
    }

    // MARK: Connection

    func toggle() {
        if vpn.isConnected || vpn.status == .connecting || vpn.status == .reasserting { vpn.stop() } else { connect() }
    }

    /// Servers the autopilot may use: every subscription (and manual
    /// servers), or only one group.
    var autopilotScope: [ServerNode] {
        if settings.autopilotAllGroups { return servers }
        let g = settings.autoSelectGroupID ?? selected?.groupID
        return servers.filter { $0.groupID == g }
    }

    func autopilotPool(_ kind: NetKind) -> [ServerNode] {
        autopilot.pool(from: autopilotScope, kind: kind, size: settings.autopilotPoolSize, useHints: settings.autopilotNetworkAware)
    }

    /// Outbound tag -> server name, in the order BuildConfig tags members.
    func groupNames(_ pool: [ServerNode]) -> [String: String] {
        let links = pool.filter { $0.rawConfig == nil }
        let configs = pool.filter { $0.rawConfig != nil }
        var names: [String: String] = [:]
        func label(_ n: ServerNode) -> String { (n.flag.isEmpty ? "" : n.flag + " ") + n.displayName }
        if pool.count == 1, let only = pool.first { return ["proxy": label(only)] }
        for (i, n) in links.enumerated() { names["proxy-\(i)"] = label(n) }
        for (j, n) in configs.enumerated() { names["proxy-c\(j)"] = label(n) }
        return names
    }

    func buildOptions(for node: ServerNode?, kind: NetKind? = nil) -> [String: Any] {
        let r = routing
        let s = settings
        var o: [String: Any] = [
            "mode": s.mode.rawValue, "tun": true, "mtu": s.mtu, "sniffing": s.sniffing, "routeOnly": s.routeOnly,
            "ipv6": s.ipv6, "logLevel": s.logLevel, "stats": true, "socksPort": s.localSocksPort, "httpPort": s.localHTTPPort,
            // Balancer probes cost traffic: every minute on Wi‑Fi, every 3 min on cellular.
            "lanShare": s.lanShare, "probeURL": s.pingURL, "probeMinutes": 3,
            "probeSeconds": (kind ?? autopilot.network) == .wifi ? 60 : 180,
            "apnsViaProxy": s.apnsViaProxy, "connIdle": s.connIdle, "useConfigDNS": s.useConfigDNS, "bufferKB": s.bufferKB,
            "dns": ["remote": r.remoteDNS, "direct": r.directDNS, "fakeDNS": r.fakeDNS, "hosts": r.hosts,
                    "strategy": s.ipv6 ? "UseIP" : "UseIPv4"] as [String: Any],
            "routing": ["domainStrategy": r.domainStrategy, "bypassLAN": r.bypassLAN, "bypassRU": r.bypassRU, "blockAds": r.blockAds,
                        "blockQUIC": r.blockQUIC, "directDomains": r.directDomains, "directIPs": r.directIPs,
                        "proxyDomains": r.proxyDomains, "proxyIPs": r.proxyIPs, "blockDomains": r.blockDomains,
                        "blockIPs": r.blockIPs] as [String: Any],
            "fragment": ["enabled": s.fragmentEnabled, "packets": s.fragmentPackets, "length": s.fragmentLength, "interval": s.fragmentInterval] as [String: Any],
            "mux": ["enabled": s.muxEnabled, "concurrency": s.muxConcurrency, "xudpConcurrency": 16] as [String: Any],
        ]
        if s.autoSelect {
            let pick = autopilotPool(kind ?? autopilot.network)
            o["outbounds"] = pick.filter { $0.rawConfig == nil }.compactMap { JSON.object($0.outbound) }
            o["configs"] = pick.compactMap(\.rawConfig)
        } else if let node {
            if let raw = node.rawConfig {
                o["rawConfig"] = raw
            } else if let ob = JSON.object(node.outbound) {
                o["outbounds"] = [ob]
            }
        }
        if let chainID = s.chainServerID, chainID != node?.id, let hop = servers.first(where: { $0.id == chainID }),
           let ob = JSON.object(hop.outbound) {
            o["chain"] = [ob]
        }
        return o
    }

    func makePayload(for node: ServerNode?, directTest: Bool = false) -> TunnelPayload? {
        var opts = buildOptions(for: node)
        if directTest {
            opts["mode"] = "direct"
            opts.removeValue(forKey: "outbounds")
            opts.removeValue(forKey: "rawConfig")
            opts.removeValue(forKey: "chain")
        }
        // Check the config right here, so mistakes show up before iOS starts the tunnel.
        var check = opts
        check["assetDir"] = ""
        switch Core.buildConfig(JSON.string(check)) {
        case .failure(let e):
            toast = e.message == "no server selected" ? "Сначала добавьте сервер или подписку (вкладка «Серверы»)" : "Ошибка конфигурации: \(e.message)"
            return nil
        case .success(let cfg):
            if let e = Core.validate(cfg) {
                toast = "Xray не принял конфиг: \(e)"
                return nil
            }
        }
        let r = routing
        let sub = subscription(for: node)
        var name = directTest ? "Проверка подписи" : settings.autoSelect ? "Автопилот" : (node?.displayName ?? "Напрямую")
        if let f = node?.flag, !f.isEmpty, !settings.autoSelect { name = f + " " + name }
        var addresses: [String] = []
        if let a = node?.address { addresses.append(a) }
        var payload = TunnelPayload(
            options: JSON.string(opts), serverName: name, serverAddresses: addresses, mtu: settings.mtu, ipv6: settings.ipv6,
            excludeLocal: settings.excludeLocal, memoryLimitMB: settings.memoryLimitMB,
            reconnectOnNetworkChange: settings.reconnectOnNetworkChange, notifications: settings.notifications,
            geoipURL: r.useGeoFiles ? r.geoipURL : nil, geositeURL: r.useGeoFiles ? r.geositeURL : nil,
            subscriptionTotal: sub?.total ?? 0, subscriptionUsed: sub?.used ?? 0, subscriptionExpire: sub?.expire)
        if settings.autoSelect && !directTest {
            // The tunnel switches between these by itself when the network changes.
            let wifiPool = autopilotPool(.wifi), cellPool = autopilotPool(.cellular)
            payload.optionsWifi = JSON.string(buildOptions(for: node, kind: .wifi))
            payload.optionsCellular = JSON.string(buildOptions(for: node, kind: .cellular))
            payload.namesWifi = groupNames(wifiPool)
            payload.namesCellular = groupNames(cellPool)
            payload.groupNames = groupNames(autopilotPool(autopilot.network))
        }
        return payload
    }

    func connect() {
        guard settings.mode == .direct || selected != nil || settings.autoSelect else {
            toast = "Сначала добавьте сервер или подписку"
            return
        }
        guard let payload = makePayload(for: selected) else { return }
        Task {
            do {
                try await vpn.save(payload: payload, settings: settings)
                try vpn.start()
                haptic()
            } catch {
                toast = "Не удалось включить VPN: \(SigningAdvice.explain(error))"
            }
        }
    }

    /// Applies changed settings or a new server to a running tunnel.
    func applyIfConnected() {
        guard vpn.isConnected, let payload = makePayload(for: selected) else { return }
        Task {
            try? await vpn.save(payload: payload, settings: settings)
            _ = await vpn.send(.reload, payload: try? JSONEncoder().encode(payload))
        }
    }

    func select(_ node: ServerNode) {
        selectedID = node.id
        haptic()
        applyIfConnected()
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stopPolling() { pollTask?.cancel(); pollTask = nil }

    private func pollOnce() async {
        guard vpn.isConnected, let d = await vpn.send(.stats), let st = try? JSONDecoder().decode(TunnelStats.self, from: d) else {
            if !vpn.isConnected { upSpeed = 0; downSpeed = 0; lastStats = nil }
            return
        }
        let now = Date()
        if let last = lastStats {
            let dt = max(0.5, now.timeIntervalSince(lastStatsAt))
            upSpeed = Double(max(0, st.up - last.up)) / dt
            downSpeed = Double(max(0, st.down - last.down)) / dt
        }
        lastStats = st
        lastStatsAt = now
        stats = st
        speedHistory.append(downSpeed + upSpeed)
        if speedHistory.count > 60 { speedHistory.removeFirst(speedHistory.count - 60) }
    }

    // MARK: Ping

    func testAll(_ group: UUID?? = nil) {
        let list: [ServerNode]
        if let g = group { list = servers.filter { $0.groupID == g } } else { list = servers }
        test(list)
    }

    /// While the VPN is on, server tests go around the tunnel through the
    /// physical interface; otherwise they would measure the path through the
    /// current server. Not with Kill Switch: then nothing may bypass the tunnel.
    private func routeTestsAroundTunnel() {
        let bypass = vpn.isConnected && !settings.killSwitch
        Core.setTestInterface(bypass ? autopilot.physicalInterface : nil)
    }

    /// Finds out what the operator lets through, around the tunnel when the
    /// VPN is on. Skipped under Kill Switch with the VPN on: nothing may
    /// bypass the tunnel then.
    func classifyNetwork() async {
        if vpn.isConnected && settings.killSwitch { return }
        routeTestsAroundTunnel()
        await autopilot.probeWhitelist()
    }

    func test(_ list: [ServerNode]) {
        let ids = list.map(\.id)
        guard !ids.isEmpty else { return }
        routeTestsAroundTunnel()
        testing.formUnion(ids)
        let method = settings.pingMethod
        let url = settings.pingURL
        let timeout = settings.pingTimeoutMs
        let items = list.map { n -> (UUID, String, String, Int) in
            // A full JSON config is tested as a whole: its routing, chains and balancers included.
            let item: String
            if let raw = n.rawConfig {
                item = JSON.string(["config": raw])
            } else {
                item = "{\"outbound\":" + n.outbound + "}"
            }
            return (n.id, item, n.address, n.port)
        }
        Task.detached(priority: .userInitiated) {
            if method == .url {
                for chunk in stride(from: 0, to: items.count, by: 12) {
                    let part = Array(items[chunk..<min(chunk + 12, items.count)])
                    let r = Core.urlTestDetailed(items: part.map(\.1), url: url, timeoutMs: timeout)
                    var res: [UUID: (Int, String?)] = [:]
                    for (i, it) in part.enumerated() { res[it.0] = i < r.count ? r[i] : (-1, "нет результата") }
                    let snapshot = res
                    await MainActor.run { self.applyLatency(snapshot) }
                }
            } else {
                var res: [UUID: (Int, String?)] = [:]
                await withTaskGroup(of: (UUID, Int).self) { g in
                    for it in items {
                        g.addTask { (it.0, Core.tcpPing(host: it.2, port: it.3, timeoutMs: timeout)) }
                    }
                    for await (id, ms) in g { res[id] = (ms, ms < 0 ? "TCP-подключение к серверу не удалось" : nil) }
                }
                let snapshot = res
                await MainActor.run { self.applyLatency(snapshot) }
            }
            await MainActor.run { self.testing.subtract(ids) }
        }
    }

    private func applyLatency(_ r: [UUID: (Int, String?)], recordHealth: Bool = true) {
        guard !r.isEmpty else { return }
        // Without any network a failed test says nothing about the server.
        if recordHealth && !autopilot.offline { autopilot.record(r) }
        var copy = servers
        for i in copy.indices {
            if let v = r[copy[i].id] {
                copy[i].latency = v.0
                copy[i].testError = v.1
                copy[i].testedAt = Date()
                testing.remove(copy[i].id)
            }
        }
        servers = copy
    }

    /// Fast scan of every server: a parallel pass with a short timeout,
    /// results shown as they arrive, then the best few are measured again
    /// with the normal timeout. Ends by applying the new pool.
    func autopilotScan() {
        guard !autopilotBusy else { return }
        let all = autopilotScope
        guard !all.isEmpty else { toast = "Добавьте подписку — автопилоту не из чего выбирать"; return }
        autopilotBusy = true
        routeTestsAroundTunnel()
        testing.formUnion(all.map(\.id))
        let url = settings.pingURL
        let timeout = settings.pingTimeoutMs
        func item(_ n: ServerNode) -> String {
            n.rawConfig.map { JSON.string(["config": $0]) } ?? ("{\"outbound\":" + n.outbound + "}")
        }
        let quick = all.map { ($0.id, item($0)) }
        Task.detached(priority: .userInitiated) {
            // Pass 1: everything in parallel, short timeout.
            var pass1: [UUID: (Int, String?)] = [:]
            for chunk in stride(from: 0, to: quick.count, by: 32) {
                let part = Array(quick[chunk..<min(chunk + 32, quick.count)])
                let r = Core.urlTestDetailed(items: part.map(\.1), url: url, timeoutMs: 2500, concurrency: 16)
                var res: [UUID: (Int, String?)] = [:]
                for (i, it) in part.enumerated() { res[it.0] = i < r.count ? r[i] : (-1, nil) }
                pass1.merge(res) { $1 }
                let snapshot = res
                await MainActor.run { self.applyLatency(snapshot, recordHealth: false) }
            }
            // Pass 2: the best 8 again, with the normal timeout, for accuracy.
            let best = pass1.filter { $0.value.0 > 0 }.sorted { $0.value.0 < $1.value.0 }.prefix(8).map(\.key)
            let again = quick.filter { best.contains($0.0) }
            let r2 = Core.urlTestDetailed(items: again.map(\.1), url: url, timeoutMs: timeout, concurrency: 8)
            var final = pass1
            for (i, it) in again.enumerated() where i < r2.count {
                let a = pass1[it.0]?.0 ?? -1, b = r2[i].0
                final[it.0] = b > 0 ? ((a > 0 ? min(a, b) : b), nil) : r2[i]
            }
            let snapshot = final
            await MainActor.run {
                self.applyLatency(snapshot)
                self.testing.subtract(quick.map(\.0))
                self.autopilotBusy = false
                let ok = snapshot.values.filter { $0.0 > 0 }.count
                let pool = self.autopilotPool(self.autopilot.network)
                if let top = pool.first, let ms = top.latency, ms > 0 {
                    self.toast = "Проверено \(snapshot.count), отвечают \(ok). Лучший для \(self.autopilot.network.title): \(top.displayName) · \(ms) мс"
                } else {
                    self.toast = "Проверено \(snapshot.count), отвечают \(ok)"
                }
                if self.settings.autoSelect { self.applyIfConnected() }
            }
        }
    }

    /// Turns the autopilot on: scan, then connect with the chosen pool.
    func startAutopilot() {
        settings.autoSelect = true
        if autopilot.network != .other { Task { await classifyNetwork() } }
        autopilotScan()
        if !vpn.isConnected { connect() }
    }

    nonisolated static func isRussian(_ n: ServerNode) -> Bool {
        if n.flag == "🇷🇺" { return true }
        let name = n.name.lowercased()
        return ["russia", "россия", "moscow", "москва", "спб", "petersburg", "[ru]", " ru ", "ru-", "-ru"].contains { name.contains($0) }
            || name.hasPrefix("ru ") || name.hasSuffix(" ru")
    }

    /// Whitelist preset: push through the VPN and a Russian server.
    func applyWhitelistPreset() {
        settings.excludeAPNs = false
        settings.apnsViaProxy = true
        settings.useConfigDNS = true
        settings.connIdle = max(settings.connIdle, 1800)
        settings.reconnectOnNetworkChange = true
        // Push only arrives while the VPN is up: if iOS unloads the tunnel or
        // the phone restarts, On Demand brings it back without the app.
        settings.onDemand = true
        settings.onDemandWiFi = true
        settings.onDemandCellular = true
        let ru = servers.filter(Self.isRussian)
        if ru.isEmpty {
            toast = "Режим белых списков включён. Серверов РФ в списке не найдено — выберите сервер в РФ вручную."
        } else if let best = ru.filter({ ($0.latency ?? -1) > 0 }).min(by: { $0.latency! < $1.latency! }) ?? ru.first {
            selectedID = best.id
            toast = "Режим белых списков: выбран \(best.displayName)"
            if ru.allSatisfy({ $0.latency == nil }) { test(ru) }
        }
        if vpn.isConnected, let payload = makePayload(for: selected) {
            // Protocol-level flags (APNs exclusion) need a reconnect to apply.
            Task {
                try? await vpn.save(payload: payload, settings: settings)
                vpn.stop()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                try? vpn.start()
            }
        }
    }

    struct PushCheck: Identifiable {
        let id = UUID()
        var title: String
        var ok: Bool
        var detail: String
    }

    /// What decides whether push notifications of other apps reach the
    /// phone through the VPN, checked one by one.
    func checkPush() async -> [PushCheck] {
        var r: [PushCheck] = []
        let s = settings
        r.append(PushCheck(title: "VPN включён", ok: vpn.isConnected,
                           detail: vpn.isConnected ? "Push идут через туннель." : "При белых списках без VPN push от зарубежных сервисов не доходят."))
        r.append(PushCheck(title: "Автоподключение", ok: s.onDemand && s.onDemandWiFi && s.onDemandCellular,
                           detail: s.onDemand ? "Если iOS выгрузит VPN или телефон перезагрузится, VPN вернётся сам." : "Выключено: если VPN упадёт, push перестанут приходить, пока вы не включите его вручную."))
        let apnsIn = !(s.killSwitch && s.excludeAPNs)
        r.append(PushCheck(title: "Push Apple через прокси", ok: apnsIn && s.apnsViaProxy,
                           detail: !apnsIn ? "APNs исключён из VPN при Kill Switch — при белых списках не пройдёт." : (s.apnsViaProxy ? "Трафик push.apple.com идёт через сервер раньше остальных правил." : "Push могут уйти напрямую и упереться в белые списки.")))
        r.append(PushCheck(title: "Долгий простой соединений", ok: s.connIdle >= 1800,
                           detail: s.connIdle >= 1800 ? "Соединение push не рвётся ядром \(s.connIdle / 60) мин." : "Сейчас \(s.connIdle) с: соединение push рвётся раньше, push могут задерживаться."))
        if vpn.isConnected, let c = stats.aliveCount {
            r.append(PushCheck(title: "Серверы отвечают", ok: c.alive > 0, detail: "Отвечают \(c.alive) из \(c.total) в наборе автопилота."))
        }
        // The real route: Apple's push service through whatever path the
        // phone uses right now (the tunnel when the VPN is on).
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 10
        let session = URLSession(configuration: cfg)
        var req = URLRequest(url: URL(string: "https://api.push.apple.com/")!)
        req.httpMethod = "HEAD"
        let start = Date()
        do {
            let (_, resp) = try await session.data(for: req)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            r.append(PushCheck(title: "Связь с серверами push Apple", ok: resp is HTTPURLResponse,
                               detail: "Ответили за \(ms) мс\(vpn.isConnected ? " через VPN" : " напрямую")."))
        } catch {
            r.append(PushCheck(title: "Связь с серверами push Apple", ok: false,
                               detail: "Нет ответа\(vpn.isConnected ? " через VPN" : " напрямую"): \(error.localizedDescription)"))
        }
        session.invalidateAndCancel()
        return r
    }

    /// Full check of the signature: saves the VPN profile, starts the tunnel
    /// in direct mode (no server needed) and reports whether it came up.
    func runSigningCheck() async -> String {
        guard let payload = makePayload(for: nil, directTest: true) else { return toast ?? "Не удалось собрать конфиг" }
        do {
            try await vpn.save(payload: payload, settings: settings)
        } catch {
            return "Шаг 1 из 2 не пройден. " + SigningAdvice.explain(error)
        }
        if vpn.isConnected { return "VPN-профиль создан, туннель уже работает — подпись в порядке." }
        do {
            try vpn.start()
        } catch {
            return "Профиль создан, но запуск не удался: " + SigningAdvice.explain(error)
        }
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if vpn.status == .connected {
                vpn.stop()
                return "Всё работает: iOS разрешила VPN и расширение запустилось. Добавьте сервер и подключайтесь."
            }
            if vpn.status == .disconnected || vpn.status == .invalid { break }
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        let reason = vpn.lastError ?? "расширение не запустилось"
        vpn.stop()
        return "Профиль создан, но туннель не поднялся: \(reason). Скорее всего, сертификат не разрешает Packet Tunnel для VPN-расширения."
    }

    /// Picks the server with the lowest delay and connects to it.
    func connectBest(in group: UUID?) {
        let list = servers.filter { group == nil || $0.groupID == group }
        if let best = list.filter({ ($0.latency ?? -1) > 0 }).min(by: { $0.latency! < $1.latency! }) {
            select(best)
            if !vpn.isConnected { connect() }
            toast = "Выбран \(best.displayName) · \(best.latency!) мс"
        } else {
            toast = "Сначала проверьте пинг"
            test(list)
        }
    }

    // MARK: Import

    func handle(text: String) {
        let item = Importer.classify(text)
        process(item)
    }

    func process(_ item: ImportItem) {
        switch item {
        case .servers(let nodes):
            add(nodes: nodes)
        case .subscription(let url, let name):
            Task { await addSubscription(url: url, name: name) }
        case .routing(let p):
            routings.append(p)
            settings.routingID = p.id
            toast = "Профиль «\(p.name)» добавлен и включён"
            applyIfConnected()
        case .backup(let d):
            restore(d)
        case .nothing(let reason):
            toast = reason
        }
    }

    func add(nodes: [ServerNode], group: UUID? = nil) {
        var list = nodes
        for i in list.indices { list[i].groupID = group }
        let existing = Set(servers.filter { $0.groupID == group }.map(\.link))
        let fresh = list.filter { $0.link.isEmpty || !existing.contains($0.link) }
        servers.append(contentsOf: fresh)
        if selectedID == nil { selectedID = fresh.first?.id }
        toast = fresh.isEmpty ? "Такие серверы уже есть" : "Добавлено серверов: \(fresh.count)"
        haptic()
    }

    func addSubscription(url: String, name: String?) async {
        if subscriptions.contains(where: { $0.url == url }) {
            toast = "Эта подписка уже добавлена"
            return
        }
        let sub = Subscription(name: name ?? URL(string: url)?.host ?? "Подписка", url: url)
        subscriptions.append(sub)
        await update(sub.id, firstTime: true)
    }

    func updateAll(onlyDue: Bool = false) async {
        for sub in subscriptions {
            if onlyDue {
                guard sub.autoUpdate else { continue }
                if let last = sub.lastUpdated, Date().timeIntervalSince(last) < Double(sub.updateIntervalHours) * 3600 { continue }
            }
            await update(sub.id)
        }
        Notifier.scheduleExpiry(subscriptions, settings: settings.notifications)
    }

    func update(_ id: UUID, firstTime: Bool = false) async {
        guard let sub = subscriptions.first(where: { $0.id == id }) else { return }
        updatingSubs.insert(id)
        defer { updatingSubs.remove(id) }
        do {
            let r = try await SubscriptionService.fetch(sub.url, userAgent: sub.userAgent ?? settings.subscriptionUA, sendHWID: settings.sendHWID)
            guard let idx = subscriptions.firstIndex(where: { $0.id == id }) else { return }
            var s = subscriptions[idx]
            if let t = r.title, !t.isEmpty { s.name = t }
            s.upload = r.upload ?? s.upload
            s.download = r.download ?? s.download
            s.total = r.total ?? s.total
            s.expire = r.expire ?? s.expire
            if let h = r.updateIntervalHours, h > 0 { s.updateIntervalHours = h }
            s.supportURL = r.supportURL ?? s.supportURL
            s.webPageURL = r.webPageURL ?? s.webPageURL
            let newAnnounce = r.announce?.trimmed
            if let a = newAnnounce, !a.isEmpty, a != s.announce {
                Notifier.post(.announcement, title: s.name, body: a, settings: settings.notifications, id: "announce-\(id)")
                announcement = (s.name, a)
            }
            s.announce = newAnnounce
            s.lastUpdated = Date()
            s.lastError = nil
            // Merge: keep ids (and the selection) of servers that are still there.
            let old = servers.filter { $0.groupID == id }
            var byLink: [String: ServerNode] = [:]
            for o in old { byLink[o.link.isEmpty ? o.name : o.link] = o }
            var merged: [ServerNode] = []
            for var n in r.nodes {
                n.groupID = id
                if let prev = byLink[n.link.isEmpty ? n.name : n.link] {
                    n.id = prev.id
                    n.latency = prev.latency
                    n.testedAt = prev.testedAt
                    n.favorite = prev.favorite
                }
                merged.append(n)
            }
            let added = merged.count - Set(merged.map(\.id)).intersection(old.map(\.id)).count
            s.serverCount = merged.count
            subscriptions[idx] = s
            var rest = servers.filter { $0.groupID != id }
            if let firstIndex = servers.firstIndex(where: { $0.groupID == id }) {
                rest.insert(contentsOf: merged, at: min(firstIndex, rest.count))
            } else {
                rest.append(contentsOf: merged)
            }
            servers = rest
            if selectedID == nil || !servers.contains(where: { $0.id == selectedID }) { selectedID = merged.first?.id }
            if let routing = r.routing, firstTime || routing.contains("onadd") {
                if case .routing(let p) = Importer.classify(routing) {
                    if !routings.contains(where: { $0.name == p.name }) {
                        routings.append(p)
                        settings.routingID = p.id
                    }
                }
            }
            if !firstTime {
                Notifier.post(.subscriptionUpdated, title: "Подписка обновлена", body: "\(s.name): \(merged.count) серверов\(added > 0 ? ", новых \(added)" : "")", settings: settings.notifications)
            } else {
                toast = "Подписка «\(s.name)»: \(merged.count) серверов"
            }
            if let total = r.total, total > 0, settings.notifications.quotaWarning {
                let pct = Int(s.usedFraction * 100)
                if pct >= settings.notifications.quotaPercent {
                    Notifier.post(.quota, title: "Трафик подписки на исходе", body: "\(s.name): использовано \(pct)%", settings: settings.notifications, id: "quota-\(id)")
                }
            }
        } catch {
            if let idx = subscriptions.firstIndex(where: { $0.id == id }) {
                subscriptions[idx].lastError = error.localizedDescription
            }
            if firstTime { toast = "Подписка: \(error.localizedDescription)" }
            Notifier.post(.subscriptionError, title: "Подписка не обновилась", body: "\(sub.name): \(error.localizedDescription)", settings: settings.notifications, id: "suberr-\(id)")
        }
    }

    func delete(subscription id: UUID) {
        subscriptions.removeAll { $0.id == id }
        servers.removeAll { $0.groupID == id }
    }

    func delete(server id: UUID) {
        servers.removeAll { $0.id == id }
        if selectedID == id { selectedID = servers.first?.id }
    }

    // MARK: Backup

    func backup() -> Data {
        struct Backup: Encodable {
            var auroraBackup = 1
            var servers: [ServerNode]
            var subscriptions: [Subscription]
            var routings: [RoutingProfile]
            var settings: AppSettings
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        enc.dateEncodingStrategy = .secondsSince1970
        return (try? enc.encode(Backup(servers: servers, subscriptions: subscriptions, routings: routings, settings: settings))) ?? Data()
    }

    func restore(_ d: Data) {
        struct Backup: Decodable {
            var servers: [ServerNode]
            var subscriptions: [Subscription]
            var routings: [RoutingProfile]
            var settings: AppSettings
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        guard let b = try? dec.decode(Backup.self, from: d) else { toast = "Файл резервной копии повреждён"; return }
        servers = b.servers
        subscriptions = b.subscriptions
        routings = b.routings.isEmpty ? [.russia, .global] : b.routings
        settings = b.settings
        selectedID = servers.first?.id
        toast = "Восстановлено: \(servers.count) серверов, \(subscriptions.count) подписок"
    }

    func shareLink(_ node: ServerNode) -> String { node.link.isEmpty ? (node.rawConfig ?? node.outbound) : node.link }

    func haptic() {
        guard settings.haptics else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
