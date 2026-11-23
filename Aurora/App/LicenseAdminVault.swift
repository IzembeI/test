import Foundation
import Security
import LocalAuthentication
import Corebridge

/// Owner credentials are private to the app. Neither the tunnel nor the activation UI needs them.
actor LicenseAdminVault {
    static let shared = LicenseAdminVault()

    private enum Item: String {
        case signer, worker
    }

    private struct WorkerCredential: Codable {
        let origin: String
        let token: String
    }

    func importSigner(from file: URL) async throws {
        let key = try readFile(file)
        guard CorebridgeAdminKeyMatches(key) else {
            throw CoreError("Выберите admin.key, соответствующий ключу подписи Aurora.")
        }
        try await store(Data(key.utf8), as: .signer, reason: "Сохранить ключ офлайн-подписи Aurora")
    }

    func bindToken(from file: URL, to origin: URL) async throws {
        guard file.pathExtension.lowercased() == "token" else {
            throw CoreError("Выберите файл admin.token для этого сервера.")
        }
        let token = try readFile(file)
        guard !token.isEmpty, token.utf8.allSatisfy({ (33...126).contains($0) }),
              !CorebridgeAdminKeyMatches(token) else {
            throw CoreError("Файл не содержит токен администратора.")
        }
        let credential = WorkerCredential(origin: origin.absoluteString, token: token)
        try await store(JSONEncoder().encode(credential), as: .worker, reason: "Привязать токен к серверу лицензий")
    }

    func sign(device: String, days: Int) throws -> String {
        let bytes = try read(.signer, reason: "Выпустить офлайн-лицензию для устройства")
        guard let key = String(data: bytes, encoding: .utf8) else {
            throw CoreError("Импортируйте admin.key заново.")
        }
        let lease = CorebridgeSignOfflineLease(key, device, days)
        guard !lease.isEmpty, !lease.hasPrefix("error:") else {
            throw CoreError("Не удалось подписать лицензию. Проверьте ключ, код устройства и срок.")
        }
        return lease
    }

    func token(for origin: URL, reason: String) throws -> String {
        let data = try read(.worker, reason: reason)
        let credential = try JSONDecoder().decode(WorkerCredential.self, from: data)
        guard credential.origin == origin.absoluteString else {
            throw CoreError("Для этого адреса нужно заново выбрать admin.token и подтвердить сервер.")
        }
        return credential.token
    }

    private func readFile(_ url: URL) throws -> String {
        guard url.startAccessingSecurityScopedResource() else {
            throw CoreError("Нет доступа к файлу. Откройте его через «Файлы» ещё раз.")
        }
        defer { url.stopAccessingSecurityScopedResource() }
        var coordinatedError: NSError?
        var contents: String?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatedError) { file in
            guard let handle = try? FileHandle(forReadingFrom: file) else { return }
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd(), (1...4096).contains(size),
                  (try? handle.seek(toOffset: 0)) != nil,
                  let bytes = try? handle.read(upToCount: 4097), bytes.count == Int(size) else { return }
            contents = String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard coordinatedError == nil, let contents else {
            throw CoreError("Не удалось прочитать файл ключа. Проверьте, что он доступен в «Файлах».")
        }
        return contents
    }

    private func query(_ item: Item) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.werx.aurora.license.owner",
         kSecAttrAccount as String: item.rawValue,
         kSecAttrSynchronizable as String: false]
    }

    private func store(_ data: Data, as item: Item, reason: String) async throws {
        let context = LAContext()
        defer { context.invalidate() }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
                throw CoreError("Подтвердите личность для сохранения ключа.")
            }
        } catch {
            throw CoreError("Ключ не сохранён. Для подтверждения нужен код-пароль устройства или биометрия.")
        }
        try Task.checkCancellation()
        guard let acl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                        .userPresence, nil) else {
            throw CoreError("Не удалось настроить защиту связки ключей.")
        }
        var lookup = query(item)
        lookup[kSecUseAuthenticationContext as String] = context
        var entry = lookup
        entry[kSecAttrAccessControl as String] = acl
        entry[kSecValueData as String] = data
        var status = SecItemAdd(entry as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Replace atomically and preserve the existing access-control policy.
            status = SecItemUpdate(lookup as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else {
            throw CoreError("Не удалось сохранить ключ. Проверьте код-пароль и доступ к связке ключей.")
        }
    }

    private func read(_ item: Item, reason: String) throws -> Data {
        try Task.checkCancellation()
        let context = LAContext()
        context.localizedReason = reason
        defer { context.invalidate() }
        var lookup = query(item)
        lookup[kSecUseAuthenticationContext as String] = context
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &value)
        if status == errSecItemNotFound {
            throw CoreError(item == .signer ? "Сначала импортируйте admin.key." : "Сначала привяжите admin.token к серверу.")
        }
        guard status == errSecSuccess, let bytes = value as? Data else {
            throw CoreError("Для доступа к ключу подтвердите личность на устройстве.")
        }
        try Task.checkCancellation()
        return bytes
    }
}
