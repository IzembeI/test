import SwiftUI
import CoreImage.CIFilterBuiltins

struct ServersView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var showAdd = false
    @State private var editing: ServerNode?
    @State private var editingSub: Subscription?
    @State private var qr: String?

    struct GroupRef: Identifiable {
        var groupID: UUID?
        var title: String
        var id: String { groupID?.uuidString ?? "manual" }
    }

    private var groups: [GroupRef] {
        var g = model.subscriptions.map { GroupRef(groupID: $0.id, title: $0.name) }
        if model.servers.contains(where: { $0.groupID == nil }) { g.append(GroupRef(groupID: nil, title: "Мои серверы")) }
        return g
    }

    var body: some View {
        NavigationStack {
            List {
                if model.servers.isEmpty && model.subscriptions.isEmpty {
                    emptyState
                }
                ForEach(groups) { group in
                    Section {
                        if !(subscription(group.groupID)?.collapsed ?? false) {
                            ForEach(filtered(group.groupID)) { node in
                                ServerRow(node: node)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.select(node) }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) { model.delete(server: node.id) } label: { Label("Удалить", systemImage: "trash") }
                                        Button { editing = node } label: { Label("Изменить", systemImage: "pencil") }.tint(.blue)
                                    }
                                    .swipeActions(edge: .leading) {
                                        Button { model.test([node]) } label: { Label("Пинг", systemImage: "speedometer") }.tint(.orange)
                                        Button { qr = model.shareLink(node) } label: { Label("QR", systemImage: "qrcode") }.tint(.purple)
                                    }
                                    .contextMenu { menu(for: node) }
                            }
                        }
                    } header: {
                        header(group.groupID, group.title)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: "Поиск серверов")
            .refreshable { await model.updateAll() }
            .navigationTitle("Серверы")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Picker("Сортировка", selection: $model.settings.sort) {
                            ForEach(ServerSort.allCases) { Text($0.title).tag($0) }
                        }
                        Button { model.testAll() } label: { Label("Проверить все", systemImage: "speedometer") }
                        Button { model.connectBest(in: nil) } label: { Label("Подключить лучший", systemImage: "bolt") }
                        Button {
                            let ru = model.servers.filter(AppModel.isRussian)
                            if let best = ru.filter({ ($0.latency ?? -1) > 0 }).min(by: { $0.latency! < $1.latency! }) {
                                model.select(best)
                                if !model.vpn.isConnected { model.connect() }
                            } else if ru.isEmpty {
                                model.toast = "Серверов РФ не найдено"
                            } else {
                                model.toast = "Проверяю пинг серверов РФ…"
                                model.test(ru)
                            }
                        } label: { Label("Лучший сервер РФ", systemImage: "flag") }
                        Button(role: .destructive) { model.servers.removeAll { ($0.latency ?? 0) < 0 } } label: { Label("Удалить недоступные", systemImage: "trash.slash") }
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) { AddSheet() }
            .sheet(item: $editing) { node in ServerEditView(node: node) }
            .sheet(item: $editingSub) { sub in SubscriptionEditView(sub: sub) }
            .sheet(isPresented: Binding(get: { qr != nil }, set: { if !$0 { qr = nil } })) {
                QRShareView(text: qr ?? "")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Пока нет серверов").font(.headline)
            Text("Добавьте ссылку на подписку, отсканируйте QR-код или вставьте vless://, vmess://, trojan://, ss://, hy2://, wireguard:// из буфера обмена.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Добавить") { showAdd = true }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowBackground(Color.clear)
    }

    private func subscription(_ id: UUID?) -> Subscription? { model.subscriptions.first { $0.id == id } }

    private func filtered(_ group: UUID?) -> [ServerNode] {
        let list = model.servers(in: group)
        guard !search.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.address.localizedCaseInsensitiveContains(search) || $0.protoLabel.localizedCaseInsensitiveContains(search) }
    }

    @ViewBuilder
    private func header(_ id: UUID?, _ title: String) -> some View {
        HStack {
            if let sub = subscription(id) {
                Button {
                    if let i = model.subscriptions.firstIndex(where: { $0.id == sub.id }) { model.subscriptions[i].collapsed.toggle() }
                } label: {
                    Image(systemName: sub.collapsed ? "chevron.right" : "chevron.down").font(.caption.weight(.bold))
                }
            }
            Text(title)
            if let sub = subscription(id), sub.total > 0 {
                Text("· \(Fmt.bytes(sub.used))/\(Fmt.bytes(sub.total))").foregroundStyle(.secondary)
            }
            Spacer()
            if let sub = subscription(id), model.updatingSubs.contains(sub.id) { ProgressView().controlSize(.small) }
            Menu {
                Button { model.testAll(.some(id)) } label: { Label("Проверить пинг", systemImage: "speedometer") }
                Button { model.connectBest(in: id) } label: { Label("Подключить лучший", systemImage: "bolt") }
                if let sub = subscription(id) {
                    Button { Task { await model.update(sub.id) } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                    Button { editingSub = sub } label: { Label("Настроить", systemImage: "slider.horizontal.3") }
                    Button { UIPasteboard.general.string = sub.url } label: { Label("Скопировать ссылку", systemImage: "doc.on.doc") }
                    Button { qr = sub.url } label: { Label("QR-код подписки", systemImage: "qrcode") }
                    Button(role: .destructive) { model.delete(subscription: sub.id) } label: { Label("Удалить подписку", systemImage: "trash") }
                } else {
                    Button(role: .destructive) { model.servers.removeAll { $0.groupID == nil } } label: { Label("Удалить все", systemImage: "trash") }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .textCase(nil)
    }

    @ViewBuilder
    private func menu(for node: ServerNode) -> some View {
        Button { model.select(node); if !model.vpn.isConnected { model.connect() } } label: { Label("Подключить", systemImage: "power") }
        Button { model.test([node]) } label: { Label("Проверить пинг", systemImage: "speedometer") }
        Button { UIPasteboard.general.string = model.shareLink(node) } label: { Label("Скопировать ссылку", systemImage: "doc.on.doc") }
        Button { qr = model.shareLink(node) } label: { Label("Показать QR", systemImage: "qrcode") }
        Button {
            if let i = model.servers.firstIndex(where: { $0.id == node.id }) { model.servers[i].favorite.toggle() }
        } label: { Label(node.favorite ? "Убрать из избранного" : "В избранное", systemImage: node.favorite ? "star.slash" : "star") }
        Button {
            model.settings.chainServerID = model.settings.chainServerID == node.id ? nil : node.id
            model.toast = model.settings.chainServerID == nil ? "Цепочка выключена" : "«\(node.displayName)» — первый узел цепочки"
        } label: { Label(model.settings.chainServerID == node.id ? "Убрать из цепочки" : "Сделать входным узлом цепочки", systemImage: "link") }
        Button { editing = node } label: { Label("Изменить", systemImage: "pencil") }
        Button(role: .destructive) { model.delete(server: node.id) } label: { Label("Удалить", systemImage: "trash") }
    }
}

struct ServerRow: View {
    @EnvironmentObject var model: AppModel
    var node: ServerNode

    var body: some View {
        HStack(spacing: 12) {
            Text(node.flag.isEmpty ? "🌐" : node.flag).font(.title2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(node.displayName).font(.body).lineLimit(1)
                    if node.favorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                    if model.settings.chainServerID == node.id { Image(systemName: "link").font(.caption2).foregroundStyle(.purple) }
                }
                HStack(spacing: 6) {
                    ProtoBadge(text: node.protoLabel)
                    if !node.transportLabel.isEmpty { Text(node.transportLabel).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            Spacer()
            if model.testing.contains(node.id) {
                ProgressView()
            } else {
                Text(Theme.latencyText(node.latency))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.latencyColor(node.latency))
            }
            if model.selected?.id == node.id {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Add

struct AddSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var text = ""
    @State private var subName = ""
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { model.handle(text: UIPasteboard.general.string ?? ""); dismiss() } label: {
                        Label("Вставить из буфера обмена", systemImage: "doc.on.clipboard")
                    }
                    Button { scanning = true } label: { Label("Сканировать QR-код", systemImage: "qrcode.viewfinder") }
                }
                Section {
                    TextField("https://… или vless://…", text: $text, axis: .vertical)
                        .lineLimit(1...6)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                    TextField("Название (необязательно)", text: $subName)
                    Button("Добавить") {
                        let item = Importer.classify(text)
                        if case .subscription(let url, _) = item {
                            Task { await model.addSubscription(url: url, name: subName.isEmpty ? nil : subName) }
                        } else {
                            model.process(item)
                        }
                        dismiss()
                    }
                    .disabled(text.trimmed.isEmpty)
                } header: {
                    Text("Ссылка, подписка или JSON")
                } footer: {
                    Text("Поддерживаются подписки (base64, списки ссылок, JSON-конфиги Xray), ссылки VLESS (Reality, XHTTP, Vision), VMess, Trojan, Shadowsocks, SOCKS, Hysteria2, WireGuard, а также диплинки happ://, v2raytun://, aurora:// и профили маршрутизации Happ.")
                }
            }
            .navigationTitle("Добавить")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
            .sheet(isPresented: $scanning) {
                QRScannerView { code in
                    scanning = false
                    model.handle(text: code)
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Edit

struct ServerEditView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var node: ServerNode
    @State private var jsonText = ""
    @State private var jsonError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Название") { TextField("Название", text: $node.name) }
                Section("Сервер") {
                    LabeledContent("Протокол", value: node.protoLabel)
                    LabeledContent("Адрес", value: node.address)
                    LabeledContent("Порт", value: "\(node.port)")
                    if !node.transportLabel.isEmpty { LabeledContent("Транспорт", value: node.transportLabel) }
                    if let l = node.latency { LabeledContent("Пинг", value: Theme.latencyText(l)) }
                }
                if !node.link.isEmpty {
                    Section("Ссылка") {
                        Text(node.link).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(6)
                        Button("Скопировать") { UIPasteboard.general.string = node.link }
                    }
                }
                Section {
                    TextEditor(text: $jsonText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 220)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: jsonText) { _ in validate() }
                    if let e = jsonError { Text(e).font(.caption).foregroundStyle(.red) }
                } header: {
                    Text(node.rawConfig != nil ? "Полный конфиг Xray" : "Outbound Xray (JSON)")
                } footer: {
                    Text("Проверяется ядром Xray прямо при вводе.")
                }
            }
            .navigationTitle("Сервер")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        if node.rawConfig != nil { node.rawConfig = jsonText } else if let o = JSON.object(jsonText) { node.outbound = JSON.string(o) }
                        if let i = model.servers.firstIndex(where: { $0.id == node.id }) { model.servers[i] = node }
                        if model.selected?.id == node.id { model.applyIfConnected() }
                        dismiss()
                    }
                    .disabled(jsonError != nil)
                }
            }
            .onAppear {
                jsonText = node.rawConfig ?? JSON.string(JSON.object(node.outbound) ?? [:], pretty: true)
            }
        }
    }

    private func validate() {
        guard let obj = JSON.object(jsonText) else { jsonError = "Неверный JSON"; return }
        let cfg: [String: Any]
        if node.rawConfig != nil { cfg = obj } else {
            var ob = obj
            ob["tag"] = "proxy"
            cfg = ["outbounds": [ob]]
        }
        jsonError = Core.validate(JSON.string(cfg))
    }
}

struct SubscriptionEditView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var sub: Subscription

    var body: some View {
        NavigationStack {
            Form {
                Section("Подписка") {
                    TextField("Название", text: $sub.name)
                    TextField("URL", text: $sub.url).textInputAutocapitalization(.never).autocorrectionDisabled().font(.footnote)
                }
                Section("Обновление") {
                    Toggle("Автообновление", isOn: $sub.autoUpdate)
                    Stepper("Каждые \(sub.updateIntervalHours) ч", value: $sub.updateIntervalHours, in: 1...168)
                    if let d = sub.lastUpdated { LabeledContent("Обновлена", value: Fmt.relative(d)) }
                    if let e = sub.lastError { Text(e).font(.caption).foregroundStyle(.red) }
                }
                Section {
                    TextField("Как в общих настройках", text: Binding(get: { sub.userAgent ?? "" }, set: { sub.userAgent = $0.isEmpty ? nil : $0 }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("User-Agent") } footer: { Text("Некоторые панели отдают разный формат в зависимости от клиента.") }
                if sub.total > 0 || sub.expire != nil {
                    Section("Тариф") {
                        if sub.total > 0 { LabeledContent("Трафик", value: "\(Fmt.bytes(sub.used)) / \(Fmt.bytes(sub.total))") }
                        if let e = sub.expire { LabeledContent("Действует до", value: Fmt.date(e)) }
                    }
                }
            }
            .navigationTitle("Подписка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        if let i = model.subscriptions.firstIndex(where: { $0.id == sub.id }) { model.subscriptions[i] = sub }
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - QR

enum QR {
    static func image(_ text: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct QRShareView: View {
    var text: String
    @Environment(\.dismiss) var dismiss
    @State private var share = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let img = QR.image(text) {
                    Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                        .padding(16).background(.white, in: RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 32)
                } else {
                    Text("Слишком длинно для QR-кода").foregroundStyle(.secondary)
                }
                Text(text).font(.system(.caption2, design: .monospaced)).lineLimit(4).foregroundStyle(.secondary).padding(.horizontal)
                HStack {
                    Button { UIPasteboard.general.string = text } label: { Label("Копировать", systemImage: "doc.on.doc") }
                        .buttonStyle(.bordered)
                    Button { share = true } label: { Label("Поделиться", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.vertical)
            .navigationTitle("QR-код")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .sheet(isPresented: $share) { ShareSheet(items: [text]) }
        }
    }
}
