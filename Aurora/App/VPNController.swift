import Foundation
import NetworkExtension
import Combine

/// Owns the single NETunnelProviderManager of the app.
@MainActor
final class VPNController: ObservableObject {
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var connectedSince: Date?
    @Published var lastError: String?

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] note in
            guard let conn = note.object as? NEVPNConnection else { return }
            Task { @MainActor in self?.update(conn) }
        }
        Task { await load() }
    }

    var isConnected: Bool { status == .connected }
    var isBusy: Bool { status == .connecting || status == .disconnecting || status == .reasserting }

    /// The saved profile is broken (other tunnel id after re-signing, an
    /// unreadable payload, disabled by iOS after an update): it is replaced
    /// on the next connect, once per launch so iOS does not ask in a loop.
    @Published private(set) var needsRepair = false
    private var repairTried = false

    func load() async {
        do {
            let all = try await NETunnelProviderManager.loadAllFromPreferences()
            // Ours first: a leftover profile of an older build must not win.
            manager = all.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == AppInfo.tunnelBundleID } ?? all.first
            if let m = manager {
                let proto = m.protocolConfiguration as? NETunnelProviderProtocol
                let payloadOK = (proto?.providerConfiguration?["payload"] as? Data).flatMap { try? JSONDecoder().decode(TunnelPayload.self, from: $0) } != nil
                needsRepair = proto?.providerBundleIdentifier != AppInfo.tunnelBundleID || !payloadOK
                if needsRepair {
                    lastError = "Профиль VPN устарел или повреждён (например, после обновления iOS или переподписи). Он будет пересоздан при следующем подключении."
                }
                update(m.connection)
            }
        } catch {
            lastError = SigningAdvice.explain(error)
        }
    }

    private func update(_ conn: NEVPNConnection) {
        status = conn.status
        connectedSince = conn.connectedDate
        if conn.status == .disconnected, #available(iOS 16.0, *) {
            conn.fetchLastDisconnectError { [weak self] err in
                guard let err else { return }
                Task { @MainActor in self?.lastError = SigningAdvice.explain(err) }
            }
        }
    }

    /// Saves the configuration (creating the VPN profile on first use).
    func save(payload: TunnelPayload, settings: AppSettings) async throws {
        if needsRepair, !repairTried, let old = manager {
            repairTried = true
            try? await old.removeFromPreferences()
            manager = nil
        }
        let m = manager ?? NETunnelProviderManager()
        let proto = (m.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppInfo.tunnelBundleID
        proto.serverAddress = payload.serverName.isEmpty ? "Aurora" : payload.serverName
        proto.providerConfiguration = ["payload": try JSONEncoder().encode(payload)]
        proto.disconnectOnSleep = false
        proto.includeAllNetworks = settings.killSwitch
        proto.excludeLocalNetworks = settings.excludeLocal
        if #available(iOS 16.4, *) {
            proto.excludeAPNs = settings.excludeAPNs
            proto.excludeCellularServices = settings.excludeCellularServices
        }
        proto.enforceRoutes = settings.killSwitch
        m.protocolConfiguration = proto
        m.localizedDescription = "Aurora"
        m.isEnabled = true
        m.onDemandRules = onDemandRules(settings)
        m.isOnDemandEnabled = settings.onDemand
        try await m.saveToPreferences()
        try await m.loadFromPreferences()
        manager = m
        if needsRepair {
            needsRepair = false
            lastError = nil
        }
    }

    private func onDemandRules(_ s: AppSettings) -> [NEOnDemandRule] {
        var rules: [NEOnDemandRule] = []
        if !s.onDemandTrustedSSIDs.isEmpty {
            let r = NEOnDemandRuleDisconnect()
            r.interfaceTypeMatch = .wiFi
            r.ssidMatch = s.onDemandTrustedSSIDs
            rules.append(r)
        }
        let wifi: NEOnDemandRule = s.onDemandWiFi ? NEOnDemandRuleConnect() : NEOnDemandRuleDisconnect()
        wifi.interfaceTypeMatch = .wiFi
        rules.append(wifi)
        let cell: NEOnDemandRule = s.onDemandCellular ? NEOnDemandRuleConnect() : NEOnDemandRuleDisconnect()
        cell.interfaceTypeMatch = .cellular
        rules.append(cell)
        return rules
    }

    func start() throws {
        guard let m = manager else { throw CoreError("VPN-профиль не создан") }
        lastError = nil
        try m.connection.startVPNTunnel(options: ["source": "app" as NSString])
    }

    func stop() {
        guard let m = manager else { return }
        if m.isOnDemandEnabled {
            m.isOnDemandEnabled = false
            m.saveToPreferences { _ in m.connection.stopVPNTunnel() }
        } else {
            m.connection.stopVPNTunnel()
        }
    }

    func send(_ command: TunnelCommand, payload: Data? = nil) async -> Data? {
        guard let session = manager?.connection as? NETunnelProviderSession, status == .connected || command == .logs else { return nil }
        guard let data = try? JSONEncoder().encode(TunnelRequest(command: command, payload: payload)) else { return nil }
        return await withCheckedContinuation { cont in
            do {
                try session.sendProviderMessage(data) { resp in cont.resume(returning: resp) }
            } catch {
                cont.resume(returning: nil)
            }
        }
    }

    func removeProfile() async {
        try? await manager?.removeFromPreferences()
        manager = nil
        status = .invalid
    }
}
