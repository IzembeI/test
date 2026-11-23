import SwiftUI
import UIKit

@MainActor
struct LicenseView: View {
    @ObservedObject private var center = LicenseCenter.shared
    @State private var server = ""
    @State private var key = ""
    @State private var offlineToken = ""
    @State private var working = false
    @State private var errorMessage: String?
    @State private var copiedCode = ""

    var body: some View {
        Form {
            Section("Лицензия") {
                if let status = center.status {
                    Label(status.valid ? "Лицензия активна" : "Требуется активация",
                          systemImage: status.valid ? "checkmark.seal" : "key")
                    if !status.reason.isEmpty {
                        Text(status.reason).foregroundStyle(.secondary)
                    }
                    if status.exp > 0 {
                        LabeledContent("Действует до", value: date(status.exp))
                    }
                    if status.valid && status.warn && status.graceUntil > 0 {
                        LabeledContent("Льготный период до", value: date(status.graceUntil))
                    }
                    if status.offline {
                        Text("Офлайн-лицензия").foregroundStyle(.secondary)
                    }
                } else {
                    Text("Не удалось загрузить лицензию. Проверьте доступ к связке ключей.")
                    Button("Повторить проверку", action: reload)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
                }
                if working { ProgressView("Запрос к серверу…") }
            }

            Section("Сервер лицензий") {
                TextField("https://", text: $server)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityLabel("HTTPS-адрес сервера")
                Button("Сохранить адрес") {
                    do {
                        try saveServer()
                        errorMessage = nil
                    } catch { errorMessage = error.localizedDescription }
                }
                .disabled(server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          server == center.serverURL?.absoluteString || working)
            }

            Section("Активация ключом") {
                SecureField("AUR-XXXXX-XXXXX-XXXXX-XXXXX", text: $key)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Ключ активации")
                Button("Активировать") {
                    request {
                        try saveServer()
                        try await center.activate(key: key)
                        key = ""
                    }
                }
                .disabled(key.isEmpty || working)
                if let status = center.status, !status.offline, status.sub != nil {
                    Button("Продлить лицензию") {
                        request { try await center.renewIfNeeded(force: true) }
                    }
                    .disabled(working)
                }
            }

            Section {
                if !center.deviceCode.isEmpty {
                    Text(center.deviceCode)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = center.deviceCode
                        copiedCode = center.deviceCode
                    } label: {
                        Label(copiedCode == center.deviceCode ? "Скопировано" : "Скопировать код",
                              systemImage: "doc.on.doc")
                    }
                } else {
                    Button("Загрузить код устройства", action: reload)
                }
            } header: {
                Text("Код устройства")
            } footer: {
                Text("Передайте этот код администратору, чтобы получить офлайн-лицензию.")
            }

            Section("Офлайн-активация") {
                SecureField("Подписанная офлайн-лицензия", text: $offlineToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Импортировать лицензию") {
                    do {
                        try center.importOffline(token: offlineToken)
                        offlineToken = ""
                        errorMessage = nil
                    } catch { errorMessage = error.localizedDescription }
                }
                .disabled(offlineToken.isEmpty)
            }

            Section {
                NavigationLink {
                    LicenseAdminView()
                } label: {
                    Label("Администратор", systemImage: "person.badge.key")
                }
            }
        }
        .navigationTitle("Лицензия")
        .onAppear {
            if server.isEmpty { server = center.serverURL?.absoluteString ?? "" }
            reload()
        }
    }

    private func date(_ seconds: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(date: .abbreviated, time: .omitted)
    }

    private func reload() {
        do {
            try center.reload()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func saveServer() throws {
        let text = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text) else { throw CoreError("Введите HTTPS-адрес сервера лицензий.") }
        try center.setServerURL(url)
        server = url.absoluteString
    }

    private func request(_ action: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true
        errorMessage = nil
        Task { @MainActor in
            defer { working = false }
            do { try await action() }
            catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
