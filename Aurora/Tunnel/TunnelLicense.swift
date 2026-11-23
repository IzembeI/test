import Foundation
import Security
import Corebridge

// Only a verified start from the app can register this iPhone. A restored
// VPN profile may carry a lease, but cannot restore this Keychain item.
enum TunnelLicense {
    private struct Identity: Codable {
        let kc: String
        let ifv: String
    }

    private static let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "aurora.tunnel.license",
        kSecAttrAccount as String: "device"
    ]

    static func apply(token: String?, options: [String: NSObject]? = nil) throws {
        let token = options?["lease"] as? String ?? token ?? ""
        CorebridgeSetLicenseDir(Storage.directory("tunnel-license").path)
        let identity: Identity
        let registering = options?["licenseKC"] != nil
        if registering, let kc = options?["licenseKC"] as? String, !kc.isEmpty {
            identity = Identity(kc: kc, ifv: options?["licenseIFV"] as? String ?? "")
        } else {
            var query = item
            query[kSecReturnData as String] = true
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let bytes = result as? Data else {
                throw CoreError("Разблокируйте iPhone и один раз подключите VPN из Aurora.")
            }
            identity = try JSONDecoder().decode(Identity.self, from: bytes)
        }
        let reason = CorebridgeSetLicense(token, identity.kc, identity.ifv)
        guard reason.isEmpty else { throw CoreError(reason) }
        if registering {
            let attrs: [String: Any] = [
                kSecValueData as String: try JSONEncoder().encode(identity),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            var status = SecItemUpdate(item as CFDictionary, attrs as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(item.merging(attrs) { _, new in new } as CFDictionary, nil)
            }
            guard status == errSecSuccess else {
                throw CoreError("Не удалось сохранить привязку VPN в связке ключей iPhone (\(status)).")
            }
        }
    }

    static func currentError() -> String? {
        struct Status: Decodable { let valid: Bool; let reason: String }
        guard let st = try? JSONDecoder().decode(Status.self, from: Data(CorebridgeLicenseStatus().utf8)) else {
            return "Не удалось проверить лицензию"
        }
        return st.valid ? nil : st.reason
    }
}
