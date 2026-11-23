import Foundation
import Corebridge

struct LicenseAdminRecord: Decodable, Identifiable {
    enum Status: String, Decodable {
        case new, active, revoked

        var title: String {
            switch self {
            case .new: return "Свободен"
            case .active: return "Активирован"
            case .revoked: return "Отозван"
            }
        }
    }

    let sub: String
    var status: Status
    var id: String { sub }
}

enum LicenseAdminChange: String {
    case revoke, reset

    var title: String { self == .revoke ? "Отозвать" : "Сбросить привязку" }
}

private final class LicenseAdminNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct LicenseAdminServer {
    let origin: URL

    init?(_ text: String) {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only a literal ASCII HTTPS origin. Show international DNS names in their ASCII (xn--) form.
        let pattern = #"\Ahttps://(?:[a-z0-9.-]+|\[[0-9a-f:.]+\])(?::[0-9]{1,5})?/?\z"#
        guard input.utf8.allSatisfy({ $0 < 128 }),
              input.lowercased().range(of: pattern, options: .regularExpression) != nil,
              var parts = URLComponents(string: input.lowercased()), let host = parts.host, !host.isEmpty,
              (1...65535).contains(parts.port ?? 443) else { return nil }
        parts.path = ""
        if parts.port == 443 { parts.port = nil }
        guard let url = parts.url else { return nil }
        origin = url
    }

    func issue(days: Int) async throws -> String {
        struct Issued: Decodable { let keys: [String] }
        let reply: Issued = try await call("issue", body: ["n": 1, "days": days], reason: "Выпустить ключ активации")
        guard reply.keys.count == 1, let key = reply.keys.first, !key.isEmpty,
              CorebridgeNormalizeLicenseKey(key) == key else { throw uncertainResult }
        return key
    }

    func list() async throws -> [LicenseAdminRecord] {
        struct Inventory: Decodable { let keys: [LicenseAdminRecord] }
        let reply: Inventory = try await call("list", reason: "Открыть список лицензий")
        let ids = reply.keys.map(\.sub)
        guard Set(ids).count == ids.count, ids.allSatisfy({
            $0.range(of: #"\A[0-9a-f]{8}\z"#, options: .regularExpression) != nil
        }) else {
            throw CoreError("В списке есть некорректные или повторяющиеся ID. Управление по ID недоступно.")
        }
        return reply.keys
    }

    func change(_ action: LicenseAdminChange, sub: String) async throws -> LicenseAdminRecord {
        let reply: LicenseAdminRecord = try await call(action.rawValue, body: ["sub": sub], reason: "\(action.title) · \(sub)")
        guard reply.sub == sub, reply.status == (action == .reset ? .new : .revoked) else { throw uncertainResult }
        return reply
    }

    private var uncertainResult: CoreError {
        CoreError("Не удалось подтвердить результат. Перед повтором обновите список ключей.")
    }

    private func call<Reply: Decodable>(_ action: String, body: [String: Any]? = nil, reason: String) async throws -> Reply {
        let token = try await LicenseAdminVault.shared.token(for: origin, reason: reason)
        try Task.checkCancellation()
        let endpoint = origin.appendingPathComponent("admin").appendingPathComponent(action)
        var request = URLRequest(url: endpoint)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config, delegate: LicenseAdminNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            try Task.checkCancellation()
            throw body == nil ? CoreError("Нет ответа от сервера лицензий.") : uncertainResult
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.url == endpoint else { throw uncertainResult }
        switch http.statusCode {
        case 200:
            guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
                throw body == nil ? CoreError("Сервер вернул некорректный список лицензий.") : uncertainResult
            }
            return reply
        case 300..<400: throw CoreError("Сервер предложил перенаправление. Проверьте адрес сервера лицензий.")
        case 401, 403: throw CoreError("Доступ отклонён. Проверьте выбранный сервер и admin.token.")
        case 404: throw CoreError("Адрес API или ключ не найден. Проверьте сервер и обновите список.")
        case 429: throw CoreError("Слишком много запросов. Повторите позже.")
        default: throw body == nil ? CoreError("Не удалось загрузить список лицензий.") : uncertainResult
        }
    }
}
