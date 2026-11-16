import Foundation

/// Where files live. The App Group container is used when the signing kept
/// it; otherwise every process falls back to its own container.
enum Storage {
    static var groupURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppInfo.appGroup)
    }

    static var hasAppGroup: Bool { groupURL != nil }

    static var baseURL: URL {
        if let g = groupURL { return g }
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return lib
    }

    static func directory(_ name: String) -> URL {
        let url = baseURL.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var geoDir: URL { directory("geo") }
    static var logDir: URL { directory("logs") }
    static var dataDir: URL { directory("data") }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        let url = dataDir.appendingPathComponent(name + ".json")
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(T.self, from: d)
    }

    /// Loads a value whose type may have gained fields since it was saved:
    /// the saved JSON is laid over the defaults, so nothing is lost.
    static func loadMerged<T: Codable>(_ type: T.Type, _ name: String, defaults: T) -> T {
        let url = dataDir.appendingPathComponent(name + ".json")
        guard let saved = try? Data(contentsOf: url),
              let savedObj = try? JSONSerialization.jsonObject(with: saved) as? [String: Any] else { return defaults }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        guard let base = try? enc.encode(defaults),
              let baseObj = try? JSONSerialization.jsonObject(with: base) as? [String: Any] else { return defaults }
        let merged = merge(baseObj, savedObj)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              let v = try? dec.decode(T.self, from: data) else { return defaults }
        return v
    }

    private static func merge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in over {
            if let b = base[k] as? [String: Any], let o = v as? [String: Any] {
                out[k] = merge(b, o)
            } else {
                out[k] = v
            }
        }
        return out
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        let url = dataDir.appendingPathComponent(name + ".json")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(value) { try? d.write(to: url, options: .atomic) }
    }

    static var defaults: UserDefaults {
        UserDefaults(suiteName: AppInfo.appGroup) ?? .standard
    }

    static func geoFilesPresent() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: geoDir.appendingPathComponent("geoip.dat").path)
            && fm.fileExists(atPath: geoDir.appendingPathComponent("geosite.dat").path)
    }

    static func geoDate() -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: geoDir.appendingPathComponent("geosite.dat").path)
        return attrs?[.modificationDate] as? Date
    }

    static func tailLog(maxBytes: Int = 64 * 1024) -> String {
        var out = ""
        for name in ["tunnel.log", "xray-error.log", "xray-access.log"] {
            let url = logDir.appendingPathComponent(name)
            guard let h = try? FileHandle(forReadingFrom: url) else { continue }
            let size = (try? h.seekToEnd()) ?? 0
            let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
            try? h.seek(toOffset: start)
            let d = (try? h.readToEnd()) ?? Data()
            try? h.close()
            if let s = String(data: d, encoding: .utf8), !s.isEmpty {
                out += "── \(name) ──\n" + s + "\n"
            }
        }
        return out
    }

    static func clearLogs() {
        for name in ["tunnel.log", "xray-error.log", "xray-access.log"] {
            try? Data().write(to: logDir.appendingPathComponent(name))
        }
    }
}

/// Small append-only log shared by the app and the tunnel.
enum Log {
    private static let queue = DispatchQueue(label: "aurora.log")

    static func write(_ message: String, file: String = "tunnel.log") {
        let line = "[\(stamp())] \(message)\n"
        queue.async {
            let url = Storage.logDir.appendingPathComponent(file)
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd()
                h.write(line.data(using: .utf8)!)
                try? h.close()
                trim(url)
            } else {
                try? line.data(using: .utf8)?.write(to: url)
            }
        }
    }

    private static func trim(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > 512 * 1024, let d = try? Data(contentsOf: url) else { return }
        try? d.suffix(256 * 1024).write(to: url)
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "dd.MM HH:mm:ss"
        return f.string(from: Date())
    }
}
