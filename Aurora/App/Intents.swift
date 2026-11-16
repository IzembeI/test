import AppIntents
import NetworkExtension

private func tunnelManager() async throws -> NETunnelProviderManager {
    guard let m = try await NETunnelProviderManager.loadAllFromPreferences().first else {
        throw CoreError("Сначала подключитесь один раз из приложения")
    }
    return m
}

struct ConnectVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "Включить Aurora VPN"
    static var description = IntentDescription("Подключает VPN с последним выбранным сервером.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let m = try await tunnelManager()
        if !m.isEnabled {
            m.isEnabled = true
            try await m.saveToPreferences()
        }
        try m.connection.startVPNTunnel(options: ["source": "shortcut" as NSString])
        return .result(dialog: "VPN включается")
    }
}

struct DisconnectVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "Выключить Aurora VPN"

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let m = try await tunnelManager()
        if m.isOnDemandEnabled {
            m.isOnDemandEnabled = false
            try await m.saveToPreferences()
        }
        m.connection.stopVPNTunnel()
        return .result(dialog: "VPN выключен")
    }
}

struct ToggleVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "Переключить Aurora VPN"

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let m = try await tunnelManager()
        switch m.connection.status {
        case .connected, .connecting, .reasserting:
            m.connection.stopVPNTunnel()
            return .result(dialog: "VPN выключен")
        default:
            try m.connection.startVPNTunnel(options: ["source": "shortcut" as NSString])
            return .result(dialog: "VPN включается")
        }
    }
}

struct VPNStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Статус Aurora VPN"

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let m = try await tunnelManager()
        let on = m.connection.status == .connected
        return .result(value: on, dialog: IntentDialog(stringLiteral: on ? "VPN подключён" : "VPN не подключён"))
    }
}

struct AuroraShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleVPNIntent(), phrases: ["Переключить VPN в \(.applicationName)", "Toggle \(.applicationName)"])
        AppShortcut(intent: ConnectVPNIntent(), phrases: ["Включить VPN в \(.applicationName)", "Connect \(.applicationName)"])
        AppShortcut(intent: DisconnectVPNIntent(), phrases: ["Выключить VPN в \(.applicationName)", "Disconnect \(.applicationName)"])
    }
}
