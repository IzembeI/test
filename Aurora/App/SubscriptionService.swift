import Foundation
import UIKit

/// Downloads a subscription and reads the headers that Happ-style panels
/// (Remnawave, Marzban, 3x-ui, …) send along with it.
struct SubscriptionResult {
    var nodes: [ServerNode] = []
    var title: String?
    var upload: Int64?
    var download: Int64?
    var total: Int64?
    var expire: Date?
    var updateIntervalHours: Int?
    var supportURL: String?
    var webPageURL: String?
    var announce: String?
    var routing: String?
    var errors: [String] = []
}

enum SubscriptionService {
    static func fetch(_ urlString: String, userAgent: String, sendHWID: Bool) async throws -> SubscriptionResult {
        guard let url = URL(string: urlString.trimmed) else { throw CoreError("Неверный адрес подписки") }
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        if sendHWID {
            let dev = await MainActor.run { () -> (String, String, String) in
                (UIDevice.current.identifierForVendor?.uuidString ?? "unknown", UIDevice.current.systemVersion, deviceModel())
            }
            req.setValue(dev.0, forHTTPHeaderField: "x-hwid")
            req.setValue("iOS", forHTTPHeaderField: "x-device-os")
            req.setValue(dev.1, forHTTPHeaderField: "x-ver-os")
            req.setValue(dev.2, forHTTPHeaderField: "x-device-model")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CoreError("Нет ответа") }
        guard (200..<300).contains(http.statusCode) else { throw CoreError("Сервер ответил \(http.statusCode)") }
        let body = String(data: data, encoding: .utf8) ?? ""
        var result = parse(body: body)
        apply(headers: http.allHeaderFields, to: &result)
        if result.title == nil, let cd = http.value(forHTTPHeaderField: "Content-Disposition"),
           let r = cd.range(of: "filename=") {
            result.title = String(cd[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ;"))
        }
        if result.nodes.isEmpty { throw CoreError(result.errors.first ?? "В подписке нет серверов") }
        return result
    }

    static func deviceModel() -> String {
        var sys = utsname()
        uname(&sys)
        let mirror = Mirror(reflecting: sys.machine)
        return mirror.children.reduce("") { acc, el in
            guard let v = el.value as? Int8, v != 0 else { return acc }
            return acc + String(UnicodeScalar(UInt8(v)))
        }
    }

    private static func header(_ headers: [AnyHashable: Any], _ name: String) -> String? {
        for (k, v) in headers {
            if let ks = k as? String, ks.lowercased() == name { return v as? String }
        }
        return nil
    }

    /// "base64:..." values are decoded, others are used as they are.
    static func maybeBase64(_ s: String) -> String {
        let t = s.trimmed
        if t.lowercased().hasPrefix("base64:") { return String(t.dropFirst(7)).base64Decoded() ?? t }
        return t
    }

    static func apply(headers: [AnyHashable: Any], to r: inout SubscriptionResult) {
        if let t = header(headers, "profile-title") { r.title = maybeBase64(t) }
        if let u = header(headers, "subscription-userinfo") { parseUserInfo(u, into: &r) }
        if let i = header(headers, "profile-update-interval"), let h = Int(i.trimmed) { r.updateIntervalHours = h }
        if let s = header(headers, "support-url") { r.supportURL = s }
        if let s = header(headers, "profile-web-page-url") { r.webPageURL = s }
        if let a = header(headers, "announce") { r.announce = maybeBase64(a) }
        if let ro = header(headers, "routing") { r.routing = ro }
    }

    static func parseUserInfo(_ s: String, into r: inout SubscriptionResult) {
        for part in s.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, let v = Int64(kv[1].split(separator: ".").first ?? "") else { continue }
            switch kv[0].lowercased() {
            case "upload": r.upload = v
            case "download": r.download = v
            case "total": r.total = v
            case "expire": if v > 0 { r.expire = Date(timeIntervalSince1970: TimeInterval(v)) }
            default: break
            }
        }
    }

    /// Body: base64 or plain links (with optional "#key: value" meta lines),
    /// a JSON array of full Xray configs, or a single Xray config.
    static func parse(body: String) -> SubscriptionResult {
        var r = SubscriptionResult()
        let text = body.trimmed
        if text.hasPrefix("[") || text.hasPrefix("{") {
            r.nodes = jsonNodes(text)
            if !r.nodes.isEmpty { return r }
        }
        let decoded = Core.decodeSubscription(text)
        for line in decoded.components(separatedBy: .newlines) {
            let l = line.trimmed
            guard l.hasPrefix("#") else { continue }
            let meta = l.dropFirst().split(separator: ":", maxSplits: 1).map { String($0).trimmed }
            guard meta.count == 2 else { continue }
            switch meta[0].lowercased() {
            case "profile-title": r.title = maybeBase64(meta[1])
            case "subscription-userinfo": parseUserInfo(meta[1], into: &r)
            case "profile-update-interval": r.updateIntervalHours = Int(meta[1])
            case "support-url": r.supportURL = meta[1]
            case "profile-web-page-url": r.webPageURL = meta[1]
            case "announce": r.announce = maybeBase64(meta[1])
            case "routing": r.routing = meta[1]
            default: break
            }
        }
        let parsed = Importer.nodes(fromLinks: decoded)
        r.nodes = parsed.nodes
        r.errors = parsed.errors
        return r
    }

    static func jsonNodes(_ text: String) -> [ServerNode] {
        guard let d = text.data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: d) else { return [] }
        let configs: [[String: Any]]
        if let arr = any as? [[String: Any]] { configs = arr }
        else if let one = any as? [String: Any] { configs = [one] }
        else { return [] }
        return configs.compactMap { Importer.node(fromConfig: $0) }
    }
}
