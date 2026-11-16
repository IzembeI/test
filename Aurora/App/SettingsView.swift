import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var exportURL: URL?
    @State private var importing = false
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { NotificationSettingsView() } label: {
                        Label("Уведомления", systemImage: "bell.badge")
                    }
                    NavigationLink { ConnectionSettingsView() } label: {
                        Label("Подключение и туннель", systemImage: "network.badge.shield.half.filled")
                    }
                    NavigationLink { ProxySettingsView() } label: {
                        Label("Обход блокировок", systemImage: "wand.and.stars")
                    }
                    NavigationLink { PingSubsSettingsView() } label: {
                        Label("Пинг и подписки", systemImage: "speedometer")
                    }
                    NavigationLink { AppearanceView() } label: {
                        Label("Оформление", systemImage: "paintpalette")
                    }
                }
                Section {
                    NavigationLink { StatsView() } label: { Label("Статистика", systemImage: "chart.bar") }
                    NavigationLink { LogsView() } label: { Label("Журнал", systemImage: "doc.text.magnifyingglass") }
                    NavigationLink { ConfigPreviewView() } label: { Label("Итоговый конфиг Xray", systemImage: "curlybraces") }
                    NavigationLink { SigningView() } label: { Label("Подпись и VPN", systemImage: "checkmark.shield") }
                }
                Section("Резервная копия") {
                    Button { exportBackup() } label: { Label("Экспорт в файл", systemImage: "square.and.arrow.up") }
                    Button { importing = true } label: { Label("Импорт из файла", systemImage: "square.and.arrow.down") }
                    Button { UIPasteboard.general.string = String(data: model.backup(), encoding: .utf8) } label: {
                        Label("Скопировать как текст", systemImage: "doc.on.doc")
                    }
                }
                Section {
                    LabeledContent("Версия", value: "\(AppInfo.version) (\(AppInfo.build))")
                    LabeledContent("Ядро", value: "Xray \(Core.version)")
                    LabeledContent("App Group", value: Storage.hasAppGroup ? "доступна" : "нет (работает без неё)")
                    Button("Удалить VPN-профиль и сбросить", role: .destructive) { confirmReset = true }
                }
            }
            .navigationTitle("Настройки")
            .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
                if let u = exportURL { ShareSheet(items: [u]) }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .data]) { result in
                guard case .success(let url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let d = try? Data(contentsOf: url) {
                    if let s = String(data: d, encoding: .utf8), !s.contains("auroraBackup") { model.handle(text: s) } else { model.restore(d) }
                }
            }
            .confirmationDialog("Удалить все серверы, подписки и VPN-профиль?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Удалить всё", role: .destructive) {
                    Task {
                        await model.vpn.removeProfile()
                        model.servers = []
                        model.subscriptions = []
                        model.routings = [.russia, .global]
                        model.settings = AppSettings()
                    }
                }
            }
        }
    }

    private func exportBackup() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Aurora-\(f.string(from: Date())).json")
        try? model.backup().write(to: url)
        exportURL = url
    }
}

// MARK: - Notifications

struct NotificationSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var auth: UNAuthorizationStatus = .notDetermined

    private var n: Binding<NotificationSettings> {
        Binding(get: { model.settings.notifications }, set: {
            model.settings.notifications = $0
            Notifier.scheduleExpiry(model.subscriptions, settings: $0)
            Notifier.scheduleDailyReport($0, body: "Откройте Aurora, чтобы посмотреть трафик за сегодня.")
        })
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Label(authText, systemImage: auth == .authorized || auth == .provisional ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(auth == .authorized || auth == .provisional ? .green : .orange)
                    Spacer()
                    if auth == .notDetermined {
                        Button("Разрешить") { Notifier.requestAuthorization { _ in refresh() } }
                    } else if auth == .denied {
                        Button("Настройки iOS") {
                            if let u = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(u) }
                        }
                    }
                }
                Toggle("Уведомления Aurora", isOn: n.enabled)
            } footer: {
                Text("Уведомления отправляются локально: из приложения и прямо из VPN-расширения, даже когда приложение закрыто. Никаких push-серверов.")
            }

            if model.settings.notifications.enabled {
                Section {
                    Toggle("Звук", isOn: n.sound)
                    Toggle("Значок на иконке", isOn: n.badge)
                    Toggle("Показывать имя сервера", isOn: n.showServerName)
                    Picker("Важность", selection: n.level) {
                        ForEach(NotificationLevel.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Как показывать")
                } footer: {
                    Text("«Тихо» — без баннера, только в Центре уведомлений. «Важно» — срочные (разрыв, конец подписки) проходят сквозь режим фокусировки, если iOS это разрешит.")
                }

                Section {
                    Toggle("Push-уведомления через VPN", isOn: Binding(get: { !model.settings.excludeAPNs }, set: { model.settings.excludeAPNs = !$0 }))
                    Toggle("Сервис push Apple всегда через прокси", isOn: $model.settings.apnsViaProxy)
                    Button { model.applyWhitelistPreset() } label: {
                        Label("Режим белых списков", systemImage: "checklist")
                    }
                } header: {
                    Text("Push при мобильных ограничениях")
                } footer: {
                    Text("Когда мобильный интернет работает только по «белым спискам», push-уведомления надёжнее всего приходят, если: сервис APNs не исключён из VPN, подключён сервер в РФ, а DNS берётся из JSON-конфига. «Режим белых списков» включает всё это разом и выбирает самый быстрый сервер РФ.")
                }

                Section("Подключение") {
                    Toggle("VPN подключён", isOn: n.onConnect)
                    Toggle("VPN отключён", isOn: n.onDisconnect)
                    Toggle("Обрыв соединения / ошибка", isOn: n.onConnectionLost)
                    Toggle("Автоматическое переподключение", isOn: n.onReconnect)
                    Toggle("Смена сети (Wi‑Fi ↔ сотовая)", isOn: n.onNetworkChange)
                    Toggle("Смена сервера", isOn: n.onServerSwitch)
                }

                Section("Подписка") {
                    Toggle("Скорое окончание", isOn: n.expiryWarning)
                    if model.settings.notifications.expiryWarning {
                        Stepper("За \(model.settings.notifications.expiryDays) \(Notifier.plural(model.settings.notifications.expiryDays, "день", "дня", "дней"))", value: n.expiryDays, in: 1...30)
                    }
                    Toggle("Заканчивается трафик", isOn: n.quotaWarning)
                    if model.settings.notifications.quotaWarning {
                        Stepper("При \(model.settings.notifications.quotaPercent)% использования", value: n.quotaPercent, in: 50...100, step: 5)
                    }
                    Toggle("Подписка обновилась", isOn: n.onSubscriptionUpdated)
                    Toggle("Ошибка обновления", isOn: n.onSubscriptionError)
                    Toggle("Объявления провайдера", isOn: n.announcements)
                }

                Section("Трафик") {
                    Toggle("Итоги сессии при отключении", isOn: n.sessionSummary)
                    Toggle("Ежедневная сводка", isOn: n.dailyReport)
                    if model.settings.notifications.dailyReport {
                        Stepper("В \(model.settings.notifications.dailyReportHour):00", value: n.dailyReportHour, in: 0...23)
                    }
                    Toggle("Лимит трафика за сессию", isOn: n.trafficCap)
                    if model.settings.notifications.trafficCap {
                        Stepper("\(model.settings.notifications.trafficCapMB) МБ", value: n.trafficCapMB, in: 100...51200, step: 100)
                    }
                }

                Section {
                    Toggle("Тихие часы", isOn: n.quietHours)
                    if model.settings.notifications.quietHours {
                        Stepper("С \(model.settings.notifications.quietFrom):00", value: n.quietFrom, in: 0...23)
                        Stepper("До \(model.settings.notifications.quietTo):00", value: n.quietTo, in: 0...23)
                    }
                } header: {
                    Text("Не беспокоить")
                } footer: {
                    Text("В тихие часы приходят только важные: обрыв соединения, конец подписки и трафика.")
                }

                Section {
                    Button { Notifier.post(.test, title: "Aurora", body: "Так будут выглядеть уведомления.", settings: model.settings.notifications) } label: {
                        Label("Отправить тестовое", systemImage: "paperplane")
                    }
                    if model.vpn.isConnected {
                        Button { Task { _ = await model.vpn.send(.notifyTest) } } label: {
                            Label("Тест из VPN-расширения", systemImage: "network")
                        }
                    }
                }
            }
        }
        .navigationTitle("Уведомления")
        .onAppear(perform: refresh)
        .onChange(of: model.settings.notifications) { _ in model.applyIfConnected() }
    }

    private var authText: String {
        switch auth {
        case .authorized: return "Разрешены"
        case .provisional: return "Разрешены тихо"
        case .ephemeral: return "Временно разрешены"
        case .denied: return "Запрещены в iOS"
        default: return "Не запрошены"
        }
    }

    private func refresh() { Notifier.status { auth = $0 } }
}

// MARK: - Connection

struct ConnectionSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var ssid = ""

    var body: some View {
        Form {
            Section {
                Toggle("Kill Switch (весь трафик только через VPN)", isOn: $model.settings.killSwitch)
                Toggle("Исключить локальную сеть", isOn: $model.settings.excludeLocal)
                Toggle("Исключить сервис push (APNs)", isOn: $model.settings.excludeAPNs)
                Toggle("Исключить звонки/SMS оператора", isOn: $model.settings.excludeCellularServices)
                Toggle("IPv6", isOn: $model.settings.ipv6)
            } header: { Text("Туннель") } footer: {
                Text("Kill Switch не даёт трафику уйти мимо VPN, даже во время переподключения.")
            }
            Section {
                Button { model.applyWhitelistPreset() } label: { Label("Режим белых списков", systemImage: "checklist") }
                Toggle("Использовать DNS из JSON", isOn: $model.settings.useConfigDNS)
                Stepper("Простой соединения: \(model.settings.connIdle / 60) мин", value: $model.settings.connIdle, in: 60...7200, step: 60)
            } header: {
                Text("Мобильный интернет с ограничениями")
            } footer: {
                Text("«DNS из JSON» — для серверов с полным JSON-конфигом используется его собственный раздел dns. Долгий простой (30 мин и больше) не даёт обрываться push-соединению.")
            }
            Section("Автоподключение (On Demand)") {
                Toggle("Подключаться автоматически", isOn: $model.settings.onDemand)
                if model.settings.onDemand {
                    Toggle("В сетях Wi‑Fi", isOn: $model.settings.onDemandWiFi)
                    Toggle("В сотовой сети", isOn: $model.settings.onDemandCellular)
                    ForEach(model.settings.onDemandTrustedSSIDs, id: \.self) { Text("Доверенная: \($0)") }
                        .onDelete { model.settings.onDemandTrustedSSIDs.remove(atOffsets: $0) }
                    HStack {
                        TextField("Доверенная Wi‑Fi (SSID)", text: $ssid)
                        Button("Добавить") {
                            model.settings.onDemandTrustedSSIDs.append(ssid.trimmed)
                            ssid = ""
                        }.disabled(ssid.trimmed.isEmpty)
                    }
                }
            }
            Section("Надёжность") {
                Toggle("Переподключать при смене сети", isOn: $model.settings.reconnectOnNetworkChange)
                Toggle("Авто: лучший сервер группы", isOn: $model.settings.autoSelect)
                if model.settings.autoSelect {
                    Picker("Группа", selection: $model.settings.autoSelectGroupID) {
                        Text("Группа выбранного сервера").tag(UUID?.none)
                        ForEach(model.subscriptions) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    Text("Ядро само проверяет до 12 серверов каждые 3 минуты и переключается на самый быстрый без разрыва туннеля.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Ядро") {
                Stepper("MTU: \(model.settings.mtu)", value: $model.settings.mtu, in: 1280...9000, step: 20)
                Toggle("Sniffing (определение доменов)", isOn: $model.settings.sniffing)
                Toggle("Sniffing только для маршрутизации", isOn: $model.settings.routeOnly)
                Stepper("Лимит памяти ядра: \(model.settings.memoryLimitMB) МБ", value: $model.settings.memoryLimitMB, in: 20...45, step: 5)
                Picker("Уровень журнала", selection: $model.settings.logLevel) {
                    ForEach(["none", "error", "warning", "info", "debug"], id: \.self) { Text($0).tag($0) }
                }
            }
            Section {
                Stepper("SOCKS5: \(model.settings.localSocksPort == 0 ? "выкл" : String(model.settings.localSocksPort))", value: $model.settings.localSocksPort, in: 0...65535, step: model.settings.localSocksPort == 0 ? 10808 : 1)
                Stepper("HTTP: \(model.settings.localHTTPPort == 0 ? "выкл" : String(model.settings.localHTTPPort))", value: $model.settings.localHTTPPort, in: 0...65535, step: model.settings.localHTTPPort == 0 ? 10809 : 1)
                Toggle("Доступ из локальной сети", isOn: $model.settings.lanShare)
            } header: { Text("Локальный прокси") } footer: {
                Text("Позволяет раздать прокси другим устройствам в вашей Wi‑Fi сети (укажите IP iPhone и порт).")
            }
        }
        .navigationTitle("Подключение")
        .onDisappear { model.applyIfConnected() }
    }
}

// MARK: - Anti-censorship

struct ProxySettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Фрагментация TLS", isOn: $model.settings.fragmentEnabled)
                if model.settings.fragmentEnabled {
                    Picker("Пакеты", selection: $model.settings.fragmentPackets) {
                        Text("tlshello").tag("tlshello")
                        Text("1-3").tag("1-3")
                        Text("1-5").tag("1-5")
                    }
                    TextField("Длина", text: $model.settings.fragmentLength)
                    TextField("Интервал, мс", text: $model.settings.fragmentInterval)
                }
            } header: { Text("Фрагментация") } footer: {
                Text("Делит TLS ClientHello на части — помогает против DPI, если сервер блокируют по SNI.")
            }
            Section {
                Toggle("Mux (мультиплексирование)", isOn: $model.settings.muxEnabled)
                if model.settings.muxEnabled {
                    Stepper("Потоков: \(model.settings.muxConcurrency)", value: $model.settings.muxConcurrency, in: 1...128)
                }
            } footer: { Text("Не применяется к VLESS Vision, Hysteria2 и WireGuard.") }
            Section {
                if let id = model.settings.chainServerID, let hop = model.servers.first(where: { $0.id == id }) {
                    LabeledContent("Входной узел", value: hop.displayName)
                    Button("Выключить цепочку", role: .destructive) { model.settings.chainServerID = nil }
                } else {
                    Text("Выключена").foregroundStyle(.secondary)
                }
            } header: { Text("Цепочка прокси") } footer: {
                Text("Трафик сначала идёт на входной узел, затем на выбранный сервер. Назначить узел: долгое нажатие на сервер → «Сделать входным узлом цепочки».")
            }
        }
        .navigationTitle("Обход блокировок")
        .onDisappear { model.applyIfConnected() }
    }
}

struct PingSubsSettingsView: View {
    @EnvironmentObject var model: AppModel
    private let agents = ["Happ/3.2.0", "Aurora/1.0", "v2rayN/7.10", "v2rayNG/1.10", "Streisand", "sing-box", "ClashMeta"]

    var body: some View {
        Form {
            Section("Пинг") {
                Picker("Метод", selection: $model.settings.pingMethod) {
                    ForEach(PingMethod.allCases) { Text($0.title).tag($0) }
                }
                TextField("URL проверки", text: $model.settings.pingURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Stepper("Таймаут: \(model.settings.pingTimeoutMs) мс", value: $model.settings.pingTimeoutMs, in: 1000...15000, step: 500)
                Toggle("Проверять при запуске", isOn: $model.settings.autoPingOnOpen)
            }
            Section {
                Picker("User-Agent", selection: $model.settings.subscriptionUA) {
                    ForEach(agents, id: \.self) { Text($0).tag($0) }
                    if !agents.contains(model.settings.subscriptionUA) { Text(model.settings.subscriptionUA).tag(model.settings.subscriptionUA) }
                }
                TextField("Свой User-Agent", text: $model.settings.subscriptionUA).textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Отправлять HWID устройства", isOn: $model.settings.sendHWID)
                Toggle("Обновлять при запуске", isOn: $model.settings.updateSubsOnLaunch)
                Button("Обновить все подписки") { Task { await model.updateAll() } }
            } header: { Text("Подписки") } footer: {
                Text("HWID (x-hwid, модель и версия iOS) нужен панелям с лимитом устройств, например Remnawave.")
            }
        }
        .navigationTitle("Пинг и подписки")
    }
}

struct AppearanceView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Picker("Тема", selection: $model.settings.theme) {
                ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
            }
            Section("Акцент") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6)) {
                    ForEach(Theme.accents.indices, id: \.self) { i in
                        Circle().fill(Theme.accents[i].1)
                            .frame(width: 36, height: 36)
                            .overlay(Circle().strokeBorder(.primary, lineWidth: model.settings.accent == i ? 3 : 0))
                            .onTapGesture { model.settings.accent = i }
                    }
                }
                .padding(.vertical, 6)
            }
            Toggle("Скорость на главном экране", isOn: $model.settings.showSpeedOnHome)
            Toggle("Виброотклик", isOn: $model.settings.haptics)
        }
        .navigationTitle("Оформление")
    }
}

// MARK: - Logs, stats, config

struct LogsView: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "Журнал пуст" : text)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Журнал")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                Button { UIPasteboard.general.string = text } label: { Image(systemName: "doc.on.doc") }
                Button(role: .destructive) {
                    Storage.clearLogs()
                    Task { _ = await model.vpn.send(.clearLogs); text = "" }
                } label: { Image(systemName: "trash") }
            }
        }
        .task { await load() }
    }

    private func load() async {
        if let d = await model.vpn.send(.logs), let s = String(data: d, encoding: .utf8), !s.isEmpty {
            text = s
        } else {
            text = Storage.tailLog()
        }
    }
}

struct StatsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let days = model.dailyTraffic()
        let maxV = max(days.map(\.1).max() ?? 1, 1)
        Form {
            Section("За 7 дней") {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(days.indices, id: \.self) { i in
                        let d = days[i]
                        VStack {
                            RoundedRectangle(cornerRadius: 4).fill(Color.accentColor)
                                .frame(height: max(4, 120 * d.1 / maxV))
                            Text(d.0).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 150)
            }
            Section("Всего через прокси") {
                LabeledContent("Отправлено", value: Fmt.bytes(Int64(model.totalUp)))
                LabeledContent("Получено", value: Fmt.bytes(Int64(model.totalDown)))
            }
            if model.vpn.isConnected {
                Section("Текущая сессия") {
                    LabeledContent("↑ через прокси", value: Fmt.bytes(model.stats.up))
                    LabeledContent("↓ через прокси", value: Fmt.bytes(model.stats.down))
                    LabeledContent("Напрямую", value: Fmt.bytes(model.stats.directUp + model.stats.directDown))
                    LabeledContent("Память ядра", value: Fmt.bytes(Int64(model.stats.memory)))
                }
            }
        }
        .navigationTitle("Статистика")
    }
}

struct ConfigPreviewView: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .navigationTitle("Конфиг Xray")
        .toolbar { Button { UIPasteboard.general.string = text } label: { Image(systemName: "doc.on.doc") } }
        .onAppear {
            var o = model.buildOptions(for: model.selected)
            o["assetDir"] = Storage.geoDir.path
            switch Core.buildConfig(JSON.string(o)) {
            case .success(let c): text = c
            case .failure(let e): text = "Ошибка: \(e.message)"
            }
        }
    }
}

// MARK: - Signing diagnostics

struct SigningView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let app = Provision.current
        let tunnel = Provision.tunnelProfile
        Form {
            Section {
                row("VPN-расширение в приложении", ok: AppInfo.tunnelPresent)
                row("Право на VPN у приложения", ok: Provision.allowsPacketTunnel(app))
                row("Право на VPN у расширения", ok: Provision.allowsPacketTunnel(tunnel))
                row("App Group", ok: Storage.hasAppGroup, unknownText: nil)
            } header: {
                Text("Проверка")
            } footer: {
                Text(verdict(app: app, tunnel: tunnel))
            }
            Section("Профиль подписи") {
                if let p = app ?? tunnel {
                    LabeledContent("Профиль", value: p.name)
                    LabeledContent("Команда", value: p.team)
                    if let e = p.expires { LabeledContent("Действует до", value: Fmt.date(e)) }
                    LabeledContent("Тип", value: p.isEnterprise ? "Enterprise (все устройства)" : "Ad Hoc / Development")
                } else {
                    Text("Файл embedded.mobileprovision удалён при подписи — права можно проверить только подключением.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Идентификаторы") {
                LabeledContent("Приложение", value: Bundle.main.bundleIdentifier ?? "—")
                LabeledContent("VPN-расширение", value: AppInfo.tunnelBundleID)
                LabeledContent("App Group", value: AppInfo.appGroup)
            }
            Section {
                Button("Проверить: создать VPN-профиль") {
                    guard let payload = model.makePayload(for: model.selected) else { return }
                    Task {
                        do {
                            try await model.vpn.save(payload: payload, settings: model.settings)
                            model.toast = "VPN-профиль создан — iOS разрешила Network Extension"
                        } catch {
                            model.toast = SigningAdvice.explain(error)
                        }
                    }
                }
            } footer: {
                Text("Для подписи в ESign/Feather и подобных: сертификат должен поддерживать Network Extensions; не включайте «Удаление URL схемы», иначе перестанут открываться ссылки happ:// и vless://.")
            }
        }
        .navigationTitle("Подпись и VPN")
    }

    private func verdict(app: Provision?, tunnel: Provision?) -> String {
        switch (Provision.allowsPacketTunnel(app), Provision.allowsPacketTunnel(tunnel)) {
        case (true?, true?), (nil, true?): return "Профиль разрешает Packet Tunnel — VPN должен включаться."
        case (false?, _), (_, false?): return "Профиль подписи НЕ разрешает Network Extension. Приложение работает, но iOS не даст включить VPN. Нужен другой сертификат (с поддержкой Network Extensions) или TrollStore."
        default: return "Профиль не найден в приложении. Нажмите «Проверить» ниже — iOS сама скажет, разрешён ли VPN."
        }
    }

    @ViewBuilder
    private func row(_ title: String, ok: Bool?, unknownText: String? = "неизвестно") -> some View {
        HStack {
            Text(title)
            Spacer()
            switch ok {
            case true?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case false?: Image(systemName: "xmark.circle.fill").foregroundStyle(unknownText == nil ? .orange : .red)
            case nil: Text(unknownText ?? "—").foregroundStyle(.secondary)
            }
        }
    }
}
