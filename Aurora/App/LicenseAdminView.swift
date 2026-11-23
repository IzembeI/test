import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum AdminImport {
    case signer
    case token(LicenseAdminServer)
}

private enum AdminConfirmation: Identifiable {
    case bind(URL, LicenseAdminServer)
    case change(LicenseAdminChange, LicenseAdminRecord, LicenseAdminServer)

    var id: String {
        switch self {
        case let .bind(_, server): return server.origin.absoluteString
        case let .change(action, record, _): return action.rawValue + record.sub
        }
    }
}

@MainActor
struct LicenseAdminView: View {
    @Environment(\.scenePhase) private var phase
    // Display preference only. The authoritative origin is inside the protected token record.
    @AppStorage("aurora.license.owner.origin") private var boundOrigin = ""
    @State private var online = false
    @State private var device = ""
    @State private var offlineDays = "30"
    @State private var onlineDays = "365"
    @State private var originDraft = ""
    @State private var records: [LicenseAdminRecord]?
    @State private var issued: String?
    @State private var revealed = false
    @State private var notice: String?
    @State private var pickingFile = false
    @State private var importing: AdminImport = .signer
    @State private var confirmation: AdminConfirmation?
    @State private var work: Task<Void, Never>?
    @State private var pendingMutation = false

    var body: some View {
        ZStack {
            Form {
                Picker("Способ выдачи", selection: $online) {
                    Text("Офлайн").tag(false)
                    Text("На сервере").tag(true)
                }
                .pickerStyle(.segmented)

                if work != nil { ProgressView("Выполняется…") }
                if let notice { Text(notice).font(.callout) }
                if let issued { resultSection(issued) }
                if online {
                    serverSettings
                    if let server = LicenseAdminServer(originDraft), server.origin.absoluteString == boundOrigin {
                        onlineSections(server)
                    }
                } else {
                    offlineSections
                }
            }
            .disabled(work != nil)
            .scrollDismissesKeyboard(.interactively)
            .opacity(phase == .active ? 1 : 0)
            .accessibilityHidden(phase != .active)
            if phase != .active {
                Color(uiColor: .systemBackground).ignoresSafeArea()
                Image(systemName: "lock.fill").accessibilityLabel("Экран закрыт")
            }
        }
        .navigationTitle("Администратор")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { originDraft = boundOrigin }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.data], onCompletion: pickedFile)
        .alert(item: $confirmation, content: alert)
        .onChange(of: phase) { next in
            if next != .active { revealed = false }
            if next == .background { clearSession() }
        }
        .onDisappear { clearSession() }
    }

    private var deviceCode: String? {
        let value = device.trimmingCharacters(in: .whitespacesAndNewlines)
        let ids = value.components(separatedBy: ":")
        guard ids.count <= 2, ids.contains(where: { !$0.isEmpty }),
              ids.allSatisfy({ $0.isEmpty || UUID(uuidString: $0) != nil }) else { return nil }
        return value
    }

    @ViewBuilder private var offlineSections: some View {
        Section {
            Button("Импортировать admin.key из Файлов…") { pick(.signer) }
        } footer: {
            Text("Импорт нужен один раз. При выдаче лицензии iOS запросит подтверждение личности.")
        }
        Section {
            SecureField("Код устройства", text: $device)
                .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
            daysField($offlineDays)
            Button("Выпустить офлайн-лицензию") {
                guard let deviceCode, let days = Int(offlineDays), (1...3650).contains(days) else { return }
                perform {
                    try await LicenseAdminVault.shared.sign(device: deviceCode, days: days)
                } then: { lease in
                    issued = lease
                    device = ""
                }
            }
            .disabled(deviceCode == nil || !(1...3650).contains(Int(offlineDays) ?? -1) || issued != nil)
        } header: {
            Text("Выдача для устройства")
        } footer: {
            Text("Вставьте код из экрана «Лицензия» нужного устройства, в том числе этого iPhone. Срок — от 1 до 3650 дней. Удалённый отзыв офлайн-лицензии недоступен.")
        }
    }

    private var serverSettings: some View {
        Section {
            if !boundOrigin.isEmpty {
                LabeledContent("Привязан к", value: boundOrigin)
            }
            TextField("https://имя-сервера", text: $originDraft)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Выбрать admin.token из Файлов…") {
                if let server = LicenseAdminServer(originDraft) { pick(.token(server)) }
            }
            .disabled(LicenseAdminServer(originDraft) == nil)
        } header: {
            Text("Сервер лицензий")
        } footer: {
            Text("Укажите HTTPS-адрес без пути. Чтобы сменить адрес, выберите токен и подтвердите новый сервер.")
        }
    }

    @ViewBuilder private func onlineSections(_ server: LicenseAdminServer) -> some View {
        Section {
            daysField($onlineDays)
            Button("Выпустить ключ активации") {
                guard let days = Int(onlineDays), (0...3650).contains(days) else { return }
                perform(mutation: true) {
                    try await server.issue(days: days)
                } then: { key in
                    issued = key
                    records = nil
                }
            }
            .disabled(!(0...3650).contains(Int(onlineDays) ?? -1) || issued != nil)
        } header: {
            Text("Выдача ключа")
        } footer: {
            Text("Срок отсчитывается с активации. Введите от 1 до 3650 дней или 0 для бессрочного ключа.")
        }
        Section("Ключи на сервере") {
            Button(records == nil ? "Загрузить список" : "Обновить список") {
                records = nil
                perform { try await server.list() } then: { records = $0 }
            }
            if let records {
                if records.isEmpty { Text("Ключей пока нет").foregroundStyle(.secondary) }
                ForEach(records) { record in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(verbatim: record.sub).font(.body.monospaced())
                            Text(record.status.title).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            if record.status != .revoked {
                                Button("Отозвать", role: .destructive) {
                                    confirmation = .change(.revoke, record, server)
                                }
                            }
                            if record.status != .new {
                                Button("Сбросить привязку", role: .destructive) {
                                    confirmation = .change(.reset, record, server)
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle").padding(6)
                        }
                        .accessibilityLabel("Действия с ключом \(record.sub)")
                    }
                }
            }
        }
    }

    private func daysField(_ value: Binding<String>) -> some View {
        LabeledContent("Срок, дней") {
            TextField("Дни", text: value).keyboardType(.numberPad).multilineTextAlignment(.trailing)
        }
    }

    private func resultSection(_ value: String) -> some View {
        Section {
            Button(revealed ? "Скрыть" : "Показать") { revealed.toggle() }
            if revealed { Text(verbatim: value).font(.footnote.monospaced()).privacySensitive() }
            Button("Скопировать") {
                UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: value]],
                                              options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                notice = "Скопировано на 2 минуты."
            }
            ShareLink(item: value, preview: SharePreview("Лицензия Aurora")) {
                Label("Поделиться…", systemImage: "square.and.arrow.up")
            }
            Button("Закрыть результат") {
                issued = nil
                revealed = false
                notice = nil
            }
        } header: {
            Text("Лицензия готова")
        } footer: {
            Text("Скопируйте результат или передайте получателю перед выходом. Полный ключ нельзя получить из списка.")
        }
    }

    private func pick(_ kind: AdminImport) {
        importing = kind
        pickingFile = true
    }

    private func pickedFile(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError { notice = "Не удалось выбрать файл." }
        case .success(let file):
            switch importing {
            case .signer:
                perform { try await LicenseAdminVault.shared.importSigner(from: file) } then: {
                    notice = "Ключ офлайн-подписи сохранён."
                }
            case .token(let server):
                confirmation = .bind(file, server)
            }
        }
    }

    private func alert(_ prompt: AdminConfirmation) -> Alert {
        switch prompt {
        case let .bind(file, server):
            return Alert(title: Text("Привязать токен к серверу?"),
                         message: Text("Проверьте адрес целиком.\n\n\(server.origin.absoluteString)\n\nПри запросах этот сервер получит выбранный admin.token. Прежняя привязка будет заменена."),
                         primaryButton: .default(Text("Подтвердить адрес")) {
                perform { try await LicenseAdminVault.shared.bindToken(from: file, to: server.origin) } then: {
                    boundOrigin = server.origin.absoluteString
                    originDraft = boundOrigin
                    records = nil
                    notice = "Токен привязан к серверу."
                }
            }, secondaryButton: .cancel(Text("Отмена")))
        case let .change(action, record, server):
            let effect = action == .revoke
                ? "Сервер прекратит активацию и продление."
                : "Ключ снова станет свободным, даже после отзыва. При новой активации срок начнётся заново."
            return Alert(title: Text("\(action.title) · \(record.sub)?"),
                         message: Text("\(server.origin.absoluteString)\n\n\(effect) Уже выданная аренда может действовать до конца срока и ещё 14 дней."),
                         primaryButton: .destructive(Text(action.title)) {
                perform(mutation: true) { try await server.change(action, sub: record.sub) } then: { updated in
                    if let index = records?.firstIndex(where: { $0.sub == updated.sub }) {
                        records?[index] = updated
                    }
                    notice = "Ключ \(updated.sub) · \(updated.status.title)"
                }
            }, secondaryButton: .cancel(Text("Отмена")))
        }
    }

    private func perform<T>(mutation: Bool = false, _ operation: @escaping @MainActor () async throws -> T,
                            then apply: @escaping @MainActor (T) -> Void) {
        guard work == nil else { return }
        notice = nil
        pendingMutation = mutation
        work = Task { @MainActor in
            do {
                let result = try await operation()
                try Task.checkCancellation()
                apply(result)
            } catch {
                guard !Task.isCancelled else { return }
                notice = (error as? CoreError)?.message ?? "Не удалось выполнить действие."
                if mutation { records = nil }
            }
            work = nil
            pendingMutation = false
        }
    }

    private func clearSession() {
        work?.cancel()
        work = nil
        notice = pendingMutation ? "Запрос был прерван. Перед повтором проверьте список ключей." : nil
        pendingMutation = false
        confirmation = nil
        records = nil
        issued = nil
        revealed = false
        device = ""
    }
}
