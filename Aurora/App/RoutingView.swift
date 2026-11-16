import SwiftUI

struct RoutingView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: RoutingProfile?
    @State private var shareText: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Режим", selection: Binding(get: { model.settings.mode }, set: { model.settings.mode = $0; model.applyIfConnected() })) {
                        ForEach(RouteMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(modeHint)
                }
                Section("Профили") {
                    ForEach(model.routings) { p in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name)
                                Text(summary(p)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            if model.settings.routingID == p.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.settings.routingID = p.id; model.applyIfConnected() }
                        .swipeActions {
                            if model.routings.count > 1 {
                                Button(role: .destructive) { model.routings.removeAll { $0.id == p.id } } label: { Label("Удалить", systemImage: "trash") }
                            }
                            Button { editing = p } label: { Label("Изменить", systemImage: "pencil") }.tint(.blue)
                        }
                        .contextMenu {
                            Button { editing = p } label: { Label("Изменить", systemImage: "pencil") }
                            Button {
                                var copy = p
                                copy.id = UUID()
                                copy.name += " (копия)"
                                model.routings.append(copy)
                            } label: { Label("Дублировать", systemImage: "plus.square.on.square") }
                            Button {
                                let json = JSON.string(Importer.happRouting(p))
                                shareText = "happ://routing/add/" + json.base64Encoded
                            } label: { Label("Поделиться (формат Happ)", systemImage: "square.and.arrow.up") }
                        }
                    }
                    Button {
                        let p = RoutingProfile(name: "Новый профиль", bypassRU: false)
                        model.routings.append(p)
                        editing = p
                    } label: { Label("Новый профиль", systemImage: "plus") }
                    Button { model.handle(text: UIPasteboard.general.string ?? "") } label: {
                        Label("Импорт из буфера (Happ / JSON)", systemImage: "doc.on.clipboard")
                    }
                }
            }
            .navigationTitle("Маршруты")
            .sheet(item: $editing) { p in RoutingEditView(profile: p) }
            .sheet(isPresented: Binding(get: { shareText != nil }, set: { if !$0 { shareText = nil } })) { ShareSheet(items: [shareText ?? ""]) }
        }
    }

    private var modeHint: String {
        switch model.settings.mode {
        case .rule: return "Трафик идёт по правилам выбранного профиля: российские и локальные адреса — напрямую, остальное — через сервер."
        case .global: return "Весь трафик через сервер (кроме локальной сети, если она исключена)."
        case .direct: return "Туннель включён, но трафик идёт напрямую — удобно для проверки и блокировки рекламы."
        }
    }

    private func summary(_ p: RoutingProfile) -> String {
        var parts: [String] = []
        if p.bypassRU { parts.append("РФ напрямую") }
        if p.blockAds { parts.append("без рекламы") }
        if p.useGeoFiles { parts.append("geo-базы") }
        let n = p.directDomains.count + p.directIPs.count + p.proxyDomains.count + p.proxyIPs.count + p.blockDomains.count + p.blockIPs.count
        if n > 0 { parts.append("правил: \(n)") }
        parts.append("DNS \(URL(string: p.remoteDNS)?.host ?? p.remoteDNS)")
        return parts.joined(separator: " · ")
    }
}

struct RoutingEditView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var profile: RoutingProfile
    @State private var geoBusy = false
    @State private var geoState = ""

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Название", text: $profile.name) }
                Section("Основное") {
                    Toggle("Российские сайты напрямую", isOn: $profile.bypassRU)
                    Toggle("Локальная сеть напрямую", isOn: $profile.bypassLAN)
                    Toggle("Блокировать рекламу и трекеры", isOn: $profile.blockAds)
                    Toggle("Блокировать QUIC (UDP 443)", isOn: $profile.blockQUIC)
                    Picker("Стратегия доменов", selection: $profile.domainStrategy) {
                        Text("AsIs").tag("AsIs")
                        Text("IPIfNonMatch").tag("IPIfNonMatch")
                        Text("IPOnDemand").tag("IPOnDemand")
                    }
                }
                Section {
                    ListEditor(title: "Напрямую — домены", items: $profile.directDomains, placeholder: "domain:example.ru")
                    ListEditor(title: "Напрямую — IP", items: $profile.directIPs, placeholder: "1.2.3.0/24")
                    ListEditor(title: "Через прокси — домены", items: $profile.proxyDomains, placeholder: "domain:youtube.com")
                    ListEditor(title: "Через прокси — IP", items: $profile.proxyIPs, placeholder: "91.108.0.0/16")
                    ListEditor(title: "Блокировать — домены", items: $profile.blockDomains, placeholder: "domain:ads.example")
                    ListEditor(title: "Блокировать — IP", items: $profile.blockIPs, placeholder: "10.10.10.10")
                } header: {
                    Text("Правила")
                } footer: {
                    Text("Синтаксис Xray: domain:, full:, keyword:, regexp:, geosite:…, geoip:…, CIDR. Правила geosite/geoip работают при включённых geo-базах.")
                }
                Section("DNS") {
                    TextField("Удалённый DNS (через прокси)", text: $profile.remoteDNS).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Прямой DNS", text: $profile.directDNS).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("FakeDNS", isOn: $profile.fakeDNS)
                    HostsEditor(hosts: $profile.hosts)
                }
                Section {
                    Toggle("Использовать geoip/geosite", isOn: $profile.useGeoFiles)
                    if profile.useGeoFiles {
                        TextField("geoip.dat URL", text: $profile.geoipURL).font(.caption).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("geosite.dat URL", text: $profile.geositeURL).font(.caption).textInputAutocapitalization(.never).autocorrectionDisabled()
                        HStack {
                            Button(geoBusy ? "Загрузка…" : "Обновить базы сейчас") { updateGeo() }.disabled(geoBusy)
                            Spacer()
                            Text(geoState).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Geo-базы")
                } footer: {
                    Text(Storage.hasAppGroup
                         ? "Базы скачиваются один раз и обновляются раз в неделю."
                         : "Подпись без App Group: VPN-расширение скачает базы само при следующем подключении.")
                }
            }
            .navigationTitle("Профиль")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { geoState = Storage.geoDate().map { "от " + Fmt.relative($0) } ?? "не загружены" }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        if let i = model.routings.firstIndex(where: { $0.id == profile.id }) { model.routings[i] = profile }
                        if model.settings.routingID == profile.id { model.applyIfConnected() }
                        dismiss()
                    }
                }
            }
        }
    }

    private func updateGeo() {
        geoBusy = true
        if model.vpn.isConnected && !Storage.hasAppGroup {
            Task {
                _ = await model.vpn.send(.updateGeo)
                geoBusy = false
                geoState = "обновлено"
            }
            return
        }
        let group = DispatchGroup()
        var ok = true
        for (u, name) in [(profile.geoipURL, "geoip.dat"), (profile.geositeURL, "geosite.dat")] {
            guard let url = URL(string: u) else { continue }
            group.enter()
            GeoDownloader.download(url, to: Storage.geoDir.appendingPathComponent(name)) { r in
                if !r { ok = false }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            geoBusy = false
            geoState = ok ? "обновлено" : "ошибка загрузки"
        }
    }
}

struct ListEditor: View {
    var title: String
    @Binding var items: [String]
    var placeholder: String

    var body: some View {
        NavigationLink {
            ListEditorPage(title: title, items: $items, placeholder: placeholder)
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text("\(items.count)").foregroundStyle(.secondary)
            }
        }
    }
}

struct ListEditorPage: View {
    var title: String
    @Binding var items: [String]
    var placeholder: String
    @State private var text = ""
    @State private var bulk = false

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField(placeholder, text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(add)
                    Button("Добавить", action: add).disabled(text.trimmed.isEmpty)
                }
            }
            Section {
                ForEach(items, id: \.self) { Text($0).font(.system(.footnote, design: .monospaced)) }
                    .onDelete { items.remove(atOffsets: $0) }
            }
            Section {
                Button("Вставить списком из буфера") {
                    let lines = (UIPasteboard.general.string ?? "").split(whereSeparator: { $0 == "\n" || $0 == "," }).map { String($0).trimmed }.filter { !$0.isEmpty }
                    for l in lines where !items.contains(l) { items.append(l) }
                }
                Button("Очистить", role: .destructive) { items.removeAll() }
            }
        }
        .navigationTitle(title)
        .toolbar { EditButton() }
    }

    private func add() {
        let t = text.trimmed
        guard !t.isEmpty, !items.contains(t) else { return }
        items.append(t)
        text = ""
    }
}

struct HostsEditor: View {
    @Binding var hosts: [String: String]
    @State private var domain = ""
    @State private var ip = ""

    var body: some View {
        NavigationLink {
            Form {
                Section("Новая запись") {
                    TextField("домен", text: $domain).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("IP", text: $ip).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Добавить") {
                        hosts[domain.trimmed] = ip.trimmed
                        domain = ""; ip = ""
                    }.disabled(domain.trimmed.isEmpty || ip.trimmed.isEmpty)
                }
                Section {
                    ForEach(hosts.keys.sorted(), id: \.self) { k in
                        LabeledContent(k, value: hosts[k] ?? "")
                    }
                    .onDelete { idx in
                        let keys = hosts.keys.sorted()
                        for i in idx { hosts.removeValue(forKey: keys[i]) }
                    }
                }
            }
            .navigationTitle("Hosts")
        } label: {
            HStack { Text("Hosts"); Spacer(); Text("\(hosts.count)").foregroundStyle(.secondary) }
        }
    }
}
