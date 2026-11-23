import Combine
import Corebridge
import Foundation
import Security
import UIKit

struct LicenseStatus: Decodable, Equatable {
    let valid: Bool
    let warn: Bool
    var reason: String
    let exp: Int64
    let graceUntil: Int64
    let daysLeft: Int
    let sub: String?
    let offline: Bool
    let required: Bool
}

@MainActor
final class LicenseCenter: ObservableObject {
    static let shared = LicenseCenter()

    @Published private(set) var status: LicenseStatus?
    @Published private(set) var profileRevision: Int = 0
    @Published private(set) var deviceCode = ""
    @Published private(set) var serverURL: URL?

    private struct Credential: Codable, Equatable {
        var token = ""
        var key: String?
        var issuer: URL?
        var denial: String?
    }

    private static let serverPreference = "aurora.license.serverURL"
    private var credential = Credential()
    private var kc = ""
    private var ifv = ""
    private var activationID: UUID?
    private var renewal: (id: UUID, task: Task<Void, Error>)?
    private var nextAutomaticRenewal = Date.distantPast
    private var pendingDenial: (previous: Credential, reason: String)?

    private init() {
        if let url = UserDefaults.standard.url(forKey: Self.serverPreference),
           Self.isServerURL(url) {
            serverURL = url
        }
    }

    func setServerURL(_ url: URL) throws {
        guard Self.isServerURL(url) else { throw CoreError("Введите HTTPS-адрес сервера лицензий.") }
        guard url != serverURL else { return }
        UserDefaults.standard.set(url, forKey: Self.serverPreference)
        activationID = nil
        serverURL = url
    }

    private static func isServerURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme?.lowercased() == "https" && !(parts.host ?? "").isEmpty &&
            parts.user == nil && parts.password == nil && parts.query == nil && parts.fragment == nil
    }

    func reload() throws {
        try load(replacingDamagedRecord: false)
    }

    private func load(replacingDamagedRecord: Bool) throws {
        do {
            // The extension maintains its own Go clock in its asset directory.
            CorebridgeSetLicenseDir(Storage.dataDir.path)
            kc = try LicenseKeychain.deviceID()
            ifv = UIDevice.current.identifierForVendor?.uuidString ?? ""
            let code = kc + ":" + ifv
            if deviceCode != code { deviceCode = code }

            if let data = try LicenseKeychain.read("credential") {
                do {
                    credential = try JSONDecoder().decode(Credential.self, from: data)
                } catch {
                    // An explicit replacement may repair a malformed item. A failed
                    // Keychain read never reaches this path or authorizes a write.
                    credential = Credential()
                    _ = CorebridgeSetLicense("", kc, ifv)
                    publish(nil)
                    if replacingDamagedRecord { return }
                    throw CoreError("Сохранённая лицензия не читается. Введите ключ или импортируйте офлайн-лицензию.")
                }
            } else {
                credential = Credential()
            }
            if let pendingDenial, pendingDenial.previous == credential {
                try commitDenial(pendingDenial.reason)
                return
            }
            pendingDenial = nil
            _ = CorebridgeSetLicense(credential.token, kc, ifv)
            var current = try coreStatus()
            if let reason = credential.denial, !current.valid { current.reason = reason }
            publish(current)
        } catch {
            publish(nil)
            throw error
        }
    }

    /// The tunnel receives the stored token and both current IDs, including an
    /// empty token after a denial. Its Go build decides whether to enforce it.
    func checkout() throws -> (token: String, kc: String, ifv: String) {
        try reload()
        return (credential.token, kc, ifv)
    }

    func activate(key: String) async throws {
        let canonical = CorebridgeNormalizeLicenseKey(key)
        guard !canonical.isEmpty else { throw CoreError("Проверьте символы и контрольную сумму ключа.") }
        guard let serverURL else { throw CoreError("Укажите HTTPS-адрес сервера лицензий.") }
        try load(replacingDamagedRecord: true)
        cancelRenewal()
        let id = UUID()
        activationID = id
        defer { if activationID == id { activationID = nil } }
        let token = try await requestLease(at: serverURL, path: "activate", key: canonical)
        try Task.checkCancellation()
        guard activationID == id else { throw CancellationError() }
        try install(Credential(token: token, key: canonical, issuer: serverURL))
    }

    func importOffline(token: String) throws {
        try load(replacingDamagedRecord: true)
        try install(Credential(token: token.trimmingCharacters(in: .whitespacesAndNewlines)))
        activationID = nil
        cancelRenewal()
    }

    func renewIfNeeded(force: Bool = false) async throws {
        try reload()
        guard activationID == nil, let key = credential.key, let issuer = credential.issuer else { return }
        if let renewal {
            try await renewal.task.value
            return
        }
        guard force || ((status?.warn == true || status?.valid == false) && Date() >= nextAutomaticRenewal) else { return }
        let previous = credential
        let id = UUID()
        let task = Task { @MainActor in
            defer { if self.renewal?.id == id { self.renewal = nil } }
            try Task.checkCancellation()
            self.nextAutomaticRenewal = Date().addingTimeInterval(3600)
            do {
                let token = try await self.requestLease(at: issuer, path: "refresh", key: key)
                try Task.checkCancellation()
                guard self.credential == previous else { throw CancellationError() }
                try self.install(Credential(token: token, key: key, issuer: issuer))
            } catch let denial as WorkerFailure where denial.invalidatesLease {
                try Task.checkCancellation()
                guard self.credential == previous else { throw CancellationError() }
                self.pendingDenial = (previous, denial.message)
                try self.commitDenial(denial.message)
                throw denial
            }
        }
        renewal = (id, task)
        try await task.value
    }

    private func cancelRenewal() {
        renewal?.task.cancel()
        renewal = nil
    }

    private func coreStatus() throws -> LicenseStatus {
        let json = CorebridgeLicenseStatus()
        guard let result = try? JSONDecoder().decode(LicenseStatus.self, from: Data(json.utf8)) else {
            throw CoreError("Не удалось прочитать статус лицензии. Повторите проверку.")
        }
        return result
    }

    private func publish(_ value: LicenseStatus?) {
        if status != value { status = value }
    }

    private func install(_ candidate: Credential) throws {
        // SetLicense mutates the Go process before returning its verdict. Keep
        // this entire verification, persistence and rollback on the main actor.
        let reason = CorebridgeSetLicense(candidate.token, kc, ifv)
        do {
            guard reason.isEmpty else { throw CoreError(reason) }
            let checked = try coreStatus()
            guard checked.valid else { throw CoreError(checked.reason) }
            if let key = candidate.key {
                let subject = String(CorebridgeLicenseKeyHash(key).prefix(8))
                guard !checked.offline, checked.sub == subject else {
                    throw CoreError("Сервер вернул лицензию для другого ключа.")
                }
            } else if !checked.offline {
                throw CoreError("Для импорта нужна офлайн-лицензия администратора.")
            }
            try persist(candidate, status: checked)
            nextAutomaticRenewal = Date().addingTimeInterval(3600)
        } catch {
            _ = CorebridgeSetLicense(credential.token, kc, ifv)
            throw error
        }
    }

    private func commitDenial(_ reason: String) throws {
        _ = CorebridgeSetLicense("", kc, ifv)
        do {
            var denied = try coreStatus()
            denied.reason = reason
            try persist(Credential(denial: reason), status: denied)
        } catch {
            // Keep the denial pending so reload/checkout must retry the write
            // before handing the previous token to the profile.
            publish(nil)
            throw error
        }
    }

    private func persist(_ new: Credential, status: LicenseStatus) throws {
        let profileChanged = credential.token != new.token || credential.denial != new.denial
        try LicenseKeychain.write(JSONEncoder().encode(new), account: "credential")
        credential = new
        pendingDenial = nil
        publish(status)
        if profileChanged { profileRevision += 1 }
    }

    private struct WorkerFailure: LocalizedError {
        let code: Int
        let message: String
        var errorDescription: String? { message }
        var invalidatesLease: Bool {
            switch (code, message) {
            case (403, "Ключ отозван"), (403, "Срок действия ключа истёк"),
                 (409, "Ключ уже активирован на другом устройстве"):
                return true
            default: return false
            }
        }
    }

    private func requestLease(at issuer: URL, path: String, key: String) async throws -> String {
        guard Self.isServerURL(issuer) else { throw CoreError("Некорректный HTTPS-адрес сервера лицензий.") }
        let url = issuer.appendingPathComponent(path)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["key": key, "kc": kc, "ifv": ifv])
        let session = URLSession(configuration: .ephemeral, delegate: LicenseRedirectDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url == url else {
            throw CoreError("Не удалось проверить ответ сервера лицензий.")
        }
        guard http.statusCode == 200 else {
            struct Failure: Decodable { let error: String }
            if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
                throw WorkerFailure(code: http.statusCode, message: failure.error)
            }
            throw CoreError("Сервер лицензий вернул HTTP \(http.statusCode).")
        }
        struct Success: Decodable { let lease: String }
        guard let reply = try? JSONDecoder().decode(Success.self, from: data), !reply.lease.isEmpty else {
            throw CoreError("В ответе сервера нет подписанной лицензии.")
        }
        return reply.lease
    }
}

private final class LicenseRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum LicenseKeychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.werx.aurora.license.client",
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    static func read(_ account: String) throws -> Data? {
        var lookup = query(account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(lookup as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess else { throw failure(code) }
        guard let data = result as? Data else { throw failure(errSecDecode) }
        return data
    }

    private static func add(_ data: Data, account: String) -> OSStatus {
        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil)
    }

    static func write(_ data: Data, account: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var code = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if code == errSecItemNotFound { code = add(data, account: account) }
        guard code == errSecSuccess else { throw failure(code) }
    }

    static func deviceID() throws -> String {
        if let data = try read("kc") {
            guard let id = String(data: data, encoding: .utf8), UUID(uuidString: id) != nil else {
                throw CoreError("Код устройства повреждён в связке ключей.")
            }
            return id
        }
        let id = UUID().uuidString
        let code = add(Data(id.utf8), account: "kc")
        if code == errSecDuplicateItem, let data = try read("kc"),
           let existing = String(data: data, encoding: .utf8), UUID(uuidString: existing) != nil {
            return existing
        }
        guard code == errSecSuccess else { throw failure(code) }
        return id
    }

    private static func failure(_ code: OSStatus) -> CoreError {
        if code == errSecInteractionNotAllowed || code == errSecNotAvailable {
            return CoreError("Связка ключей недоступна. Разблокируйте устройство и повторите проверку.")
        }
        return CoreError("Ошибка связки ключей (\(code)). Повторите проверку.")
    }
}
