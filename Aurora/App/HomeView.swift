import SwiftUI
import NetworkExtension

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var vpn: VPNController
    @EnvironmentObject var autopilot: Autopilot
    @Binding var tab: Int
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    connectionCard
                    Picker("Режим", selection: Binding(get: { model.settings.mode }, set: { model.settings.mode = $0; model.applyIfConnected() })) {
                        ForEach(RouteMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    autopilotCard
                    if !model.settings.autoSelect { serverCard }
                    if vpn.isConnected && model.settings.showSpeedOnHome { speedCard }
                    if let sub = model.subscription(for: model.selected) { SubscriptionCard(sub: sub) }
                    if let err = vpn.lastError, vpn.status == .disconnected {
                        Card {
                            Label(err, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.subheadline)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Aurora")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { model.handle(text: UIPasteboard.general.string ?? "") } label: { Label("Из буфера обмена", systemImage: "doc.on.clipboard") }
                        Button { model.connectBest(in: model.selected?.groupID) } label: { Label("Лучший сервер", systemImage: "bolt") }
                        Button { model.testAll() } label: { Label("Проверить все", systemImage: "speedometer") }
                    } label: { Image(systemName: "plus.circle") }
                    .accessibilityLabel("Действия с серверами")
                }
            }
            .onReceive(clock) { now = $0 }
            .onChange(of: vpn.status) { st in
                if st == .connected { model.startPolling() }
            }
        }
    }

    private var connectionCard: some View {
        let on = vpn.isConnected
        let cancelling = vpn.status == .connecting || vpn.status == .reasserting
        let action = on ? "Отключить VPN" : (cancelling ? "Отменить подключение" : "Подключить VPN")
        return Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: on ? "checkmark.shield.fill" : "shield")
                    .font(.title2)
                    .foregroundStyle(Color.primary)
                    .padding(12)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(vpn.status.title).font(.title2.weight(.semibold))
                    if on, let since = vpn.connectedSince {
                        Text(Fmt.duration(Int64(now.timeIntervalSince(since))))
                            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if vpn.isBusy { ProgressView().accessibilityHidden(true) }
            }
            Button { model.toggle() } label: {
                Label(action, systemImage: "power")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            .foregroundStyle(Color(.systemBackground))
            .disabled(vpn.status == .disconnecting)
        }
    }

    private var serverCard: some View {
        Button { tab = 1 } label: {
            Card {
                HStack(spacing: 12) {
                    Text(model.settings.autoSelect ? "⚡️" : (model.selected?.flag.isEmpty == false ? model.selected!.flag : "🌐"))
                        .font(.system(size: 34))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.settings.autoSelect ? "Авто · лучший сервер" : (model.selected?.displayName ?? "Сервер не выбран"))
                            .font(.headline)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            if let s = model.selected {
                                ProtoBadge(text: s.protoLabel)
                                if !s.transportLabel.isEmpty { Text(s.transportLabel).font(.caption).foregroundStyle(.secondary) }
                            } else {
                                Text("Добавьте подписку или ссылку").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    if let s = model.selected {
                        VStack(alignment: .trailing) {
                            if model.testing.contains(s.id) { ProgressView() } else {
                                Text(Theme.latencyText(s.latency)).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.latencyColor(s.latency))
                            }
                        }
                    }
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let s = model.selected {
                Button { model.test([s]) } label: { Label("Проверить пинг", systemImage: "speedometer") }
                Button { UIPasteboard.general.string = model.shareLink(s) } label: { Label("Скопировать ссылку", systemImage: "doc.on.doc") }
            }
        }
    }

    private var autopilotCard: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(model.settings.autoSelect ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Автопилот").font(.headline)
                    Text(autopilot.summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { model.settings.autoSelect }, set: { on in
                    if on { model.startAutopilot() } else { model.settings.autoSelect = false; model.applyIfConnected() }
                }))
                .labelsHidden()
                .accessibilityLabel("Автопилот")
            }
            if model.settings.autoSelect {
                let pool = model.autopilotPool(autopilot.network)
                if vpn.isConnected, let best = model.stats.bestName {
                    Label("Сейчас: \(best)", systemImage: "bolt.horizontal.circle").font(.subheadline)
                } else if let top = pool.first {
                    Label("Лучший: \(top.flag.isEmpty ? "" : top.flag + " ")\(top.displayName)", systemImage: "star").font(.subheadline)
                }
                if vpn.isConnected, let c = model.stats.aliveCount {
                    Text("В наборе \(c.total) из \(model.autopilotScope.count), отвечают \(c.alive). Ядро само уходит с упавшего.")
                        .font(.caption).foregroundStyle(c.alive == 0 ? Color.red : .secondary)
                } else {
                    Text("В наборе \(pool.count) из \(model.autopilotScope.count): ядро само переключается на живой и быстрый.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        model.autopilotScan()
                    } label: {
                        if model.autopilotBusy {
                            HStack { ProgressView().controlSize(.small); Text("Проверяю \(model.testing.count)…") }
                        } else {
                            Label("Проверить все серверы", systemImage: "waveform.path.ecg")
                        }
                    }
                    .disabled(model.autopilotBusy)
                    Spacer()
                    Button { Task { await model.classifyNetwork() } } label: {
                        Image(systemName: "antenna.radiowaves.left.and.right").frame(minWidth: 44, minHeight: 44)
                    }
                        .accessibilityLabel("Проверить сеть")
                }
                .font(.subheadline)
                if let c = autopilot.netClass {
                    Text(c.detail).font(.caption).foregroundStyle(c.isWhitelist || c.kind == "offline" ? Color.orange : .secondary)
                }
            } else {
                Text("Сам изучает конфиги всех подписок, проверяет серверы и держит подключение к лучшему для текущей сети.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var speedCard: some View {
        Card {
            HStack {
                VStack(alignment: .leading) {
                    Label(Fmt.speed(model.downSpeed), systemImage: "arrow.down").font(.headline.monospacedDigit())
                    Text("↓ \(Fmt.bytes(model.stats.down))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Label(Fmt.speed(model.upSpeed), systemImage: "arrow.up").font(.headline.monospacedDigit())
                    Text("↑ \(Fmt.bytes(model.stats.up))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Sparkline(values: model.speedHistory).frame(height: 56)
            HStack {
                Text("Напрямую: \(Fmt.bytes(model.stats.directUp + model.stats.directDown))")
                Spacer()
                Text("Память ядра: \(Fmt.bytes(Int64(model.stats.memory)))")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct SubscriptionCard: View {
    @EnvironmentObject var model: AppModel
    var sub: Subscription

    var body: some View {
        Card {
            HStack {
                Text(sub.name).font(.headline).lineLimit(1)
                Spacer()
                if model.updatingSubs.contains(sub.id) { ProgressView() } else {
                    Button { Task { await model.update(sub.id) } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            if sub.total > 0 {
                ProgressView(value: sub.usedFraction)
                    .tint(sub.usedFraction > 0.9 ? .red : .accentColor)
                Text("\(Fmt.bytes(sub.used)) из \(Fmt.bytes(sub.total))").font(.caption).foregroundStyle(.secondary)
            } else if sub.used > 0 {
                Text("Использовано \(Fmt.bytes(sub.used)) · безлимит").font(.caption).foregroundStyle(.secondary)
            }
            if let exp = sub.expire {
                let days = sub.daysLeft ?? 0
                Label(days < 0 ? "Истекла \(Fmt.date(exp))" : "До \(Fmt.date(exp)) · \(days) \(Notifier.plural(days, "день", "дня", "дней"))",
                      systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(days <= model.settings.notifications.expiryDays ? .orange : .secondary)
            }
            if let a = sub.announce, !a.isEmpty {
                Label(a, systemImage: "megaphone").font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack {
                if let s = sub.supportURL, let u = URL(string: s) { Link(destination: u) { Label("Поддержка", systemImage: "questionmark.bubble") }.font(.caption) }
                if let s = sub.webPageURL, let u = URL(string: s) { Link(destination: u) { Label("Кабинет", systemImage: "person.crop.circle") }.font(.caption) }
            }
        }
    }
}
