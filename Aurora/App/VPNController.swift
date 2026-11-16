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

    func load() async {
        do {
            let all = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = all.first
            if let m = manager { update(m.connection) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func update(_ conn: NEVPNConnection) {
        status = conn.status
        connectedSince = conn.connectedDate
        if conn.status == .disconnected, #available(iOS 16.0, *) {
            conn.fetchLastDisconnectError { [weak self] err in
                guard let err else { return }
                Task { @MainActor in self?.lastError = err.localizedDescription }
            }
        }
    }

    /// Saves the configuration (creating the VPN profile on first use).
    func save(payload: TunnelPayload, settings: AppSettings) async throws {
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
