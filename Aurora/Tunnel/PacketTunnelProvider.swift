import Foundation
import NetworkExtension
import Network
import UserNotifications

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var payload: TunnelPayload?
    private var config = ""
    private var pathMonitor: NWPathMonitor?
    private var lastPath: String?
    private var timer: DispatchSourceTimer?
    private var startedAt = Date()
    private var quotaWarned = false
    private var capWarned = false
    private var restarting = false
    private let queue = DispatchQueue(label: "aurora.tunnel")
    private var stoppingByUser = false
    private var netKind = "other"
    private var lastBest: String?
    private var lastSwitchNotice = Date.distantPast
    /// Called once the first network path is known (or after a short wait).
    private var onFirstPath: (() -> Void)?
    /// True between a successful start and stop; path changes during the
    /// start are not acted on.
    private var live = false

    // MARK: Start

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        Log.write("start requested (\(options?["source"] as? String ?? "system"))")
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let data = proto.providerConfiguration?["payload"] as? Data,
              let p = try? JSONDecoder().decode(TunnelPayload.self, from: data) else {
            completionHandler(fail("Нет конфигурации. Откройте приложение и выберите сервер."))
            return
        }
        payload = p
        Core.setMemoryLimit(p.memoryLimitMB)

        // The network comes first: with the autopilot, Wi‑Fi and cellular get
        // different server sets, and a start by the system (On Demand, a
        // network change) must pick the set for the network it starts on.
        waitForNetwork { [weak self] in
            self?.prepareGeo(p) { [weak self] in
                guard let self else { return }
                switch self.makeConfig(p) {
                case .failure(let e):
                    completionHandler(self.fail(e.message))
                case .success(let cfg):
                    self.config = cfg
                    self.setTunnelNetworkSettings(self.networkSettings(p)) { error in
                        if let error {
                            completionHandler(self.fail("Сеть туннеля: \(error.localizedDescription)"))
                            return
                        }
                        guard let fd = self.tunnelFD else {
                            completionHandler(self.fail("Не найден дескриптор utun"))
                            return
                        }
                        if let e = Core.start(config: cfg, tunFd: fd, assetDir: Storage.geoDir.path) {
                            completionHandler(self.fail("Xray: \(e)"))
                            return
                        }
                        self.startedAt = Date()
                        Log.write("connected: \(p.serverName), network \(self.netKind), Xray \(Core.version)")
                        completionHandler(nil)
                        self.queue.async {
                            self.live = true
                            self.afterStart(p)
                        }
                    }
                }
            }
        }
    }

    private func waitForNetwork(_ done: @escaping () -> Void) {
        queue.async {
            self.onFirstPath = done
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in self?.pathChanged(path) }
            monitor.start(queue: self.queue)
            self.pathMonitor = monitor
            // Never hold the start for long if the path is slow to come.
            self.queue.asyncAfter(deadline: .now() + 1) { self.firstPathReady() }
        }
    }

    private func firstPathReady() {
        let f = onFirstPath
        onFirstPath = nil
        f?()
    }

    private func fail(_ message: String) -> NSError {
        Log.write("error: \(message)")
        if let p = payload {
            Notifier.post(.connectionLost, title: "Не удалось подключиться", body: message, settings: p.notifications)
        }
        return NSError(domain: "Aurora", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Autopilot payloads carry a server set per network kind.
    private func options(_ p: TunnelPayload) -> String {
        switch netKind {
        case "wifi": return p.optionsWifi ?? p.options
        case "cellular": return p.optionsCellular ?? p.options
        default: return p.options
        }
    }

    private func names(_ p: TunnelPayload) -> [String: String] {
        switch netKind {
        case "wifi": return p.namesWifi ?? p.groupNames
        case "cellular": return p.namesCellular ?? p.groupNames
        default: return p.groupNames
        }
    }

    private func makeConfig(_ p: TunnelPayload) -> Result<String, CoreError> {
        guard var opts = JSON.object(options(p)) else { return .failure(CoreError("Повреждённые настройки")) }
        opts["assetDir"] = Storage.geoDir.path
        opts["logDir"] = Storage.logDir.path
        opts["tun"] = true
        return Core.buildConfig(JSON.string(opts))
    }

    private func afterStart(_ p: TunnelPayload) {
        let name = p.notifications.showServerName ? p.serverName : "VPN"
        Notifier.post(.connected, title: "Подключено", body: "\(name) · режим защищён", settings: p.notifications, id: "conn-state")
        startMonitoring()
        if p.subscriptionTotal > 0, p.notifications.quotaWarning {
            let pct = Int(Double(p.subscriptionUsed) / Double(p.subscriptionTotal) * 100)
            if pct >= p.notifications.quotaPercent {
                quotaWarned = true
                Notifier.post(.quota, title: "Трафик подписки на исходе", body: "Использовано \(pct)% — \(Fmt.bytes(p.subscriptionUsed)) из \(Fmt.bytes(p.subscriptionTotal)).", settings: p.notifications, id: "quota")
            }
        }
        if let exp = p.subscriptionExpire, p.notifications.expiryWarning {
            let days = Calendar.current.dateComponents([.day], from: Date(), to: exp).day ?? 99
            if days <= p.notifications.expiryDays {
                Notifier.post(.expiry, title: "Подписка заканчивается", body: days < 0 ? "Срок подписки истёк." : "Осталось \(max(0, days)) \(Notifier.plural(max(0, days), "день", "дня", "дней")).", settings: p.notifications, id: "expiry-now")
            }
        }
    }

    // MARK: Network settings

    private func networkSettings(_ p: TunnelPayload) -> NEPacketTunnelNetworkSettings {
        let s = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "254.1.1.1")
        s.mtu = NSNumber(value: p.mtu)
        let v4 = NEIPv4Settings(addresses: ["198.19.0.1"], subnetMasks: ["255.255.255.252"])
        v4.includedRoutes = [NEIPv4Route.default()]
        var excluded: [NEIPv4Route] = []
        if p.excludeLocal {
            for (net, mask) in [("10.0.0.0", "255.0.0.0"), ("172.16.0.0", "255.240.0.0"), ("192.168.0.0", "255.255.0.0"),
                                ("169.254.0.0", "255.255.0.0"), ("224.0.0.0", "240.0.0.0")] {
                excluded.append(NEIPv4Route(destinationAddress: net, subnetMask: mask))
            }
        }
        for addr in p.serverAddresses where IPv4Address(addr) != nil {
            excluded.append(NEIPv4Route(destinationAddress: addr, subnetMask: "255.255.255.255"))
        }
        v4.excludedRoutes = excluded
        s.ipv4Settings = v4
        // IPv6 always goes into the tunnel, even when it is off, so it cannot leak past it.
        do {
            let v6 = NEIPv6Settings(addresses: ["fd66:6172:6f72::1"], networkPrefixLengths: [126])
            v6.includedRoutes = [NEIPv6Route.default()]
            var ex6: [NEIPv6Route] = []
            if p.excludeLocal {
                ex6.append(NEIPv6Route(destinationAddress: "fe80::", networkPrefixLength: 10))
                ex6.append(NEIPv6Route(destinationAddress: "fc00::", networkPrefixLength: 7))
            }
            for addr in p.serverAddresses where IPv6Address(addr) != nil {
                ex6.append(NEIPv6Route(destinationAddress: addr, networkPrefixLength: 128))
            }
            v6.excludedRoutes = ex6
            s.ipv6Settings = v6
        }
        let dns = NEDNSSettings(servers: p.ipv6 ? ["198.19.0.2", "fd66:6172:6f72::2"] : ["198.19.0.2"])
        dns.matchDomains = [""]
        s.dnsSettings = dns
        return s
    }

    /// The utun socket that NetworkExtension created for this tunnel.
    private var tunnelFD: Int32? {
        var buf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        for fd: Int32 in 0...1024 {
            var len = socklen_t(buf.count)
            if getsockopt(fd, 2 /* SYSPROTO_CONTROL */, 2 /* UTUN_OPT_IFNAME */, &buf, &len) == 0 {
                let name = String(cString: buf)
                if name.hasPrefix("utun") { return fd }
            }
        }
        return nil
    }

    // MARK: Geo files

    private func prepareGeo(_ p: TunnelPayload, _ done: @escaping () -> Void) {
        guard let ipURL = p.geoipURL.flatMap(URL.init(string:)), let siteURL = p.geositeURL.flatMap(URL.init(string:)) else {
            done(); return
        }
        let fresh = Storage.geoDate().map { Date().timeIntervalSince($0) < 7 * 86400 } ?? false
        if Storage.geoFilesPresent() && fresh { done(); return }
        Log.write("downloading geo files")
        let group = DispatchGroup()
        for (url, name) in [(ipURL, "geoip.dat"), (siteURL, "geosite.dat")] {
            group.enter()
            GeoDownloader.download(url, to: Storage.geoDir.appendingPathComponent(name)) { ok in
                Log.write("geo \(name): \(ok ? "ok" : "failed")")
                group.leave()
            }
        }
        group.notify(queue: queue) { done() }
    }

    // MARK: Monitoring

    private func startMonitoring() {
        if pathMonitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in self?.pathChanged(path) }
            monitor.start(queue: queue)
            pathMonitor = monitor
        }
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func describe(_ path: Network.NWPath) -> String {
        var kind = "none"
        if path.usesInterfaceType(.wifi) { kind = "wifi" }
        else if path.usesInterfaceType(.cellular) { kind = "cellular" }
        else if path.usesInterfaceType(.wiredEthernet) { kind = "ethernet" }
        return "\(path.status == .satisfied ? "up" : "down")-\(kind)"
    }

    private func pathChanged(_ path: Network.NWPath) {
        let d = describe(path)
        if lastPath == nil {
            netKind = path.usesInterfaceType(.wifi) ? "wifi" : (path.usesInterfaceType(.cellular) ? "cellular" : "other")
            lastPath = d
            firstPathReady()
            return
        }
        // Changes while the tunnel is still starting are compared against
        // the first path once it is up.
        guard live else { return }
        defer { lastPath = d }
        guard let last = lastPath, last != d, let p = payload else { return }
        Log.write("network: \(last) -> \(d)")
        if path.status != .satisfied {
            Notifier.post(.connectionLost, title: "Нет сети", body: "Соединение будет восстановлено автоматически.", settings: p.notifications, id: "conn-state")
            return
        }
        if p.notifications.onNetworkChange {
            let label = path.usesInterfaceType(.wifi) ? "Wi‑Fi" : (path.usesInterfaceType(.cellular) ? "сотовая сеть" : "сеть")
            Notifier.post(.networkChanged, title: "Сеть сменилась", body: "Теперь: \(label)", settings: p.notifications, id: "net-change")
        }
        let kind = path.usesInterfaceType(.wifi) ? "wifi" : (path.usesInterfaceType(.cellular) ? "cellular" : "other")
        let kindChanged = kind != netKind
        netKind = kind
        if kindChanged, p.optionsWifi != nil, case .success(let cfg) = makeConfig(p) {
            // Autopilot: the server set for the new network.
            config = cfg
            lastBest = nil
            restartCore(reason: kind == "cellular" ? "сотовая сеть — серверы для мобильного интернета" : "Wi‑Fi — серверы для Wi‑Fi")
            return
        }
        if p.reconnectOnNetworkChange { restartCore(reason: "смена сети") }
    }

    private func restartCore(reason: String) {
        guard !restarting, !config.isEmpty, let fd = tunnelFD else { return }
        restarting = true
        Core.stop()
        let err = Core.start(config: config, tunFd: fd, assetDir: Storage.geoDir.path)
        restarting = false
        if let p = payload {
            if let err {
                Log.write("restart failed: \(err)")
                Notifier.post(.connectionLost, title: "Соединение потеряно", body: err, settings: p.notifications, id: "conn-state")
            } else {
                Log.write("restarted: \(reason)")
                Notifier.post(.reconnected, title: "Переподключено", body: "Причина: \(reason)", settings: p.notifications, id: "conn-state")
            }
        }
    }

    private func tick() {
        guard let p = payload else { return }
        let st = Core.stats()
        if let best = st.best, best != lastBest {
            if let previous = lastBest, p.notifications.onServerSwitch {
                // Close servers trade first place often; that is worth a notice
                // only every 10 minutes. A server that went down always is.
                let previousDown = st.members?.first { $0.tag == previous }?.alive == false
                if previousDown || Date().timeIntervalSince(lastSwitchNotice) > 600 {
                    lastSwitchNotice = Date()
                    let name = names(p)[best] ?? best
                    Notifier.post(.serverSwitched, title: previousDown ? "Сервер перестал отвечать" : "Автопилот сменил сервер",
                                  body: p.notifications.showServerName ? "Теперь: \(name)" : "Переключено на работающий сервер",
                                  settings: p.notifications, id: "autopilot")
                }
            }
            Log.write("autopilot: best = \(names(p)[best] ?? best)")
            lastBest = best
        }
        if p.memoryLimitMB > 0, st.memory > UInt64(p.memoryLimitMB) * 1024 * 1024 * 9 / 10 { Core.freeMemory() }
        if p.notifications.trafficCap, !capWarned {
            let used = st.up + st.down
            if used >= Int64(p.notifications.trafficCapMB) * 1024 * 1024 {
                capWarned = true
                Notifier.post(.trafficCap, title: "Лимит трафика сессии", body: "За эту сессию прошло \(Fmt.bytes(used)) через прокси.", settings: p.notifications, id: "cap")
            }
        }
        if p.subscriptionTotal > 0, !quotaWarned, p.notifications.quotaWarning {
            let used = p.subscriptionUsed + st.up + st.down
            let pct = Int(Double(used) / Double(p.subscriptionTotal) * 100)
            if pct >= p.notifications.quotaPercent {
                quotaWarned = true
                Notifier.post(.quota, title: "Трафик подписки на исходе", body: "Примерно \(min(pct, 100))% от \(Fmt.bytes(p.subscriptionTotal)).", settings: p.notifications, id: "quota")
            }
        }
        if !Core.isRunning, !restarting {
            restartCore(reason: "ядро остановилось")
        }
    }

    // MARK: Stop

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.sync { live = false; onFirstPath = nil }
        timer?.cancel(); timer = nil
        pathMonitor?.cancel(); pathMonitor = nil
        let st = Core.stats()
        Core.stop()
        Log.write("stopped, reason \(reason.rawValue)")
        if let p = payload {
            let dur = Int64(Date().timeIntervalSince(startedAt))
            switch reason {
            case .userInitiated, .providerDisabled, .configurationDisabled, .configurationRemoved, .superceded, .userLogout, .userSwitch:
                Notifier.post(.disconnected, title: "Отключено", body: "Сессия \(Fmt.duration(dur))", settings: p.notifications, id: "conn-state")
            case .noNetworkAvailable, .connectionFailed, .unrecoverableNetworkChange, .providerFailed, .idleTimeout, .authenticationCanceled:
                Notifier.post(.connectionLost, title: "VPN отключился", body: "Причина: \(reasonText(reason))", settings: p.notifications, id: "conn-state")
            default:
                break
            }
            if p.notifications.sessionSummary && dur > 60 {
                Notifier.post(.sessionSummary, title: "Итоги сессии", body: "\(Fmt.duration(dur)) · ↑ \(Fmt.bytes(st.up)) ↓ \(Fmt.bytes(st.down))", settings: p.notifications)
            }
            saveTotals(st)
        }
        completionHandler()
    }

    private func saveTotals(_ st: TunnelStats) {
        let d = Storage.defaults
        d.set(d.double(forKey: "total.up") + Double(st.up), forKey: "total.up")
        d.set(d.double(forKey: "total.down") + Double(st.down), forKey: "total.down")
        let key = "day." + Self.dayKey()
        d.set(d.double(forKey: key) + Double(st.up + st.down), forKey: key)
    }

    static func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func reasonText(_ r: NEProviderStopReason) -> String {
        switch r {
        case .noNetworkAvailable: return "нет сети"
        case .connectionFailed: return "ошибка подключения"
        case .unrecoverableNetworkChange: return "смена сети"
        case .providerFailed: return "сбой расширения"
        case .idleTimeout: return "простой"
        default: return "код \(r.rawValue)"
        }
    }

    // MARK: Messages from the app

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let req = try? JSONDecoder().decode(TunnelRequest.self, from: messageData) else {
            completionHandler?(nil); return
        }
        switch req.command {
        case .stats:
            var st = Core.stats()
            if let p = payload, let best = st.best { st.bestName = names(p)[best] }
            st.network = netKind
            completionHandler?(try? JSONEncoder().encode(st))
        case .status:
            completionHandler?("\(Core.isRunning ? "running" : "stopped")|\(payload?.serverName ?? "")".data(using: .utf8))
        case .logs:
            completionHandler?(Storage.tailLog().data(using: .utf8))
        case .clearLogs:
            Storage.clearLogs()
            completionHandler?(nil)
        case .reload:
            if let d = req.payload, let p = try? JSONDecoder().decode(TunnelPayload.self, from: d) {
                queue.async {
                    self.payload = p
                    if case .success(let cfg) = self.makeConfig(p) {
                        self.config = cfg
                        self.restartCore(reason: "смена сервера: \(p.serverName)")
                        if p.notifications.onServerSwitch {
                            Notifier.post(.serverSwitched, title: "Сервер изменён", body: p.notifications.showServerName ? p.serverName : "Новый сервер", settings: p.notifications, id: "conn-state")
                        }
                    }
                    completionHandler?("ok".data(using: .utf8))
                }
            } else { completionHandler?(nil) }
        case .updateGeo:
            if let p = payload {
                try? FileManager.default.removeItem(at: Storage.geoDir.appendingPathComponent("geosite.dat"))
                prepareGeo(p) { completionHandler?("ok".data(using: .utf8)) }
            } else { completionHandler?(nil) }
        case .notifyTest:
            var s = payload?.notifications ?? NotificationSettings()
            s.enabled = true
            Notifier.post(.test, title: "Проверка из VPN-расширения", body: "Уведомления из туннеля работают.", settings: s)
            completionHandler?("ok".data(using: .utf8))
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) { completionHandler() }

    override func wake() {
        queue.async { if !Core.isRunning { self.restartCore(reason: "выход из сна") } }
    }
}
