import Foundation
import Corebridge

/// Thin Swift layer over the Go bridge (Xray-core).
enum Core {
    struct ParsedLink: Decodable {
        var link: String
        var name: String
        var `protocol`: String
        var address: String
        var port: Int
        var error: String?
        var outboundJSON: String?
    }

    static var version: String { CorebridgeVersion() }

    static func decodeSubscription(_ text: String) -> String {
        CorebridgeDecodeSubscription(text, "")
    }

    static func parseLinks(_ text: String) -> [ParsedLink] {
        let json = CorebridgeParseLinks(text)
        guard let d = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ParsedLink].self, from: d)) ?? []
    }

    static func buildConfig(_ optionsJSON: String) -> Result<String, CoreError> {
        let out = CorebridgeBuildConfig(optionsJSON)
        if out.hasPrefix("error:") { return .failure(CoreError(String(out.dropFirst(6)))) }
        return .success(out)
    }

    static func validate(_ config: String) -> String? {
        let e = CorebridgeValidate(config)
        return e.isEmpty ? nil : e
    }

    static func start(config: String, tunFd: Int32, assetDir: String) -> String? {
        let e = CorebridgeStart(config, Int(tunFd), assetDir)
        return e.isEmpty ? nil : e
    }

    static func stop() { _ = CorebridgeStop() }

    static var isRunning: Bool { CorebridgeIsRunning() }

    static func setMemoryLimit(_ mb: Int) { CorebridgeSetMemoryLimit(mb) }

    static func stats() -> TunnelStats {
        let s = CorebridgeStats()
        guard let d = s.data(using: .utf8) else { return TunnelStats() }
        return (try? JSONDecoder().decode(TunnelStats.self, from: d)) ?? TunnelStats()
    }

    static func freeMemory() { CorebridgeFreeMemory() }

    /// Real delay of each outbound in milliseconds (-1 failed), in order.
    static func urlTest(outbounds: [String], url: String, timeoutMs: Int, concurrency: Int = 8) -> [Int] {
        let array = "[" + outbounds.joined(separator: ",") + "]"
        let out = CorebridgeURLTest(array, url, timeoutMs, concurrency)
        guard let d = out.data(using: .utf8), let v = try? JSONDecoder().decode([Int].self, from: d) else {
            return Array(repeating: -1, count: outbounds.count)
        }
        return v
    }

    /// items: JSON objects {"outbound": {...}} or {"config": "..."}.
    static func urlTestDetailed(items: [String], url: String, timeoutMs: Int, concurrency: Int = 6) -> [(Int, String?)] {
        struct R: Decodable { var delay: Int; var error: String? }
        let out = CorebridgeURLTestDetailed("[" + items.joined(separator: ",") + "]", url, timeoutMs, concurrency)
        guard let d = out.data(using: .utf8), let v = try? JSONDecoder().decode([R].self, from: d) else {
            return Array(repeating: (-1, "ядро не вернуло результат"), count: items.count)
        }
        return v.map { ($0.delay, $0.error) }
    }

    static func tcpPing(host: String, port: Int, timeoutMs: Int) -> Int {
        CorebridgeTCPPing(host, port, timeoutMs)
    }
}

struct CoreError: Error, LocalizedError {
    var message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

enum JSON {
    static func object(_ text: String) -> [String: Any]? {
        guard let d = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func string(_ value: Any, pretty: Bool = false) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let d = try? JSONSerialization.data(withJSONObject: value, options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    static func encode<T: Encodable>(_ v: T) -> String {
        guard let d = try? JSONEncoder().encode(v) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }
}
