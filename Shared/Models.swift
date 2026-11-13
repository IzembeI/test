import Foundation
import Security
import UIKit

// MARK: - Settings shared between the app and the keyboard

struct TyperSettings: Codable, Equatable {
    var wpmMode = 0              // 0 — ровный, 1 — плавающий
    var wpm = 140.0
    var wpmMin = 125.0
    var wpmMax = 132.0
    var errorsEnabled = true
    var errorRate = 3.0          // % символов
    var micropauses = true
    var pauseStrength = 1.0      // 0...2
    var ergonomics = true
    var startDelay = 4.0
    var newlineMode = 0          // 0 — return, 1 — пробел, 2 — пропуск
    var showTaps = true
    var clickSound = false
    var haptics = false
    var pauseOnTouch = true
    var skin = 0                 // 0 iOS авто, 1 iOS тёмная, 2 iOS светлая, 3 Material, 4 классическая iOS
    var warmup = true            // разгон в начале и усталость на длинном тексте
    var autocorrect = true       // часть опечаток исправляется «автозаменой» целого слова
    var startHaptic = true       // вибрация в момент старта печати
}

struct SavedText: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var title = ""
    var text = ""
}

struct TypingProfile: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name = ""
    var settings = TyperSettings()
}

struct RunStat: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var date = Date().timeIntervalSince1970
    var chars = 0
    var seconds = 0.0
    var typos = 0

    var wpm: Double { seconds > 0 ? Double(chars) / 5 / (seconds / 60) : 0 }
}

struct TyperCommand: Codable {
    var id = UUID().uuidString
    var action = "start"         // start, resume, pause, stop
    var fireAt = 0.0
    var created = Date().timeIntervalSince1970
}

struct TyperStatus: Codable, Equatable {
    var state = "idle"           // idle, armed, running, paused, done
    var pos = 0
    var total = 0
    var updated = 0.0
    var lastCmd = ""
    var fireAt = 0.0
    var build = ""            // build number of the keyboard that wrote this status
}

// MARK: - File store (App Group container, with a local fallback)

final class Store {
    static let shared = Store()
    static let groupBase = "group.com.werx.autotyper"

    let base: URL
    let isShared: Bool

    private init() {
        var found: URL?
        var ids = [Store.groupBase]
        if let team = Store.teamID() {
            // Sideload tools (AltStore / Sideloadly) rename groups with the team id.
            ids.append("\(Store.groupBase).\(team)")
            ids.append("group.\(team).com.werx.autotyper")
        }
        for id in ids {
            if let u = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
                found = u
                break
            }
        }
        if let u = found {
            base = u.appendingPathComponent("AutoTyper", isDirectory: true)
            isShared = true
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            base = dir.appendingPathComponent("AutoTyper", isDirectory: true)
            isShared = false
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: fontsDir, withIntermediateDirectories: true)
    }

    private static func teamID() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "autotyper.probe",
            kSecAttrService as String: "autotyper",
            kSecReturnAttributes as String: true
        ]
        var r: CFTypeRef?
        var st = SecItemCopyMatching(q as CFDictionary, &r)
        if st == errSecItemNotFound { st = SecItemAdd(q as CFDictionary, &r) }
        guard st == errSecSuccess,
              let d = r as? [String: Any],
              let g = d[kSecAttrAccessGroup as String] as? String else { return nil }
        return g.components(separatedBy: ".").first
    }

    // MARK: Bridge
    //
    // When the signing tool strips the App Group, the app and the keyboard cannot see each
    // other's files. They then talk through two named pasteboards (one per direction), which
    // iOS shares between an app and its extensions once the keyboard has Full Access.

    static let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
    static let isKeyboard = Bundle.main.bundlePath.hasSuffix(".appex")
    private static let appFiles: Set<String> = ["settings.json", "text.txt", "command.json"]
    private static let keyboardFiles: Set<String> = ["status.json", "stats.json"]
    private var mine: Set<String> { Store.isKeyboard ? Store.keyboardFiles : Store.appFiles }
    private var theirs: Set<String> { Store.isKeyboard ? Store.appFiles : Store.keyboardFiles }

    private lazy var outBoard = UIPasteboard(
        name: UIPasteboard.Name("com.werx.autotyper.bridge." + (Store.isKeyboard ? "kb" : "app")), create: true)
    private lazy var inBoard = UIPasteboard(
        name: UIPasteboard.Name("com.werx.autotyper.bridge." + (Store.isKeyboard ? "app" : "kb")), create: true)
    private var outItems: [String: Any] = [:]
    private var inCache: [String: Data] = [:]
    private var inCount = -1
    private var localCount: [String: Int] = [:]

    private func boardType(_ name: String) -> String {
        "com.werx.autotyper." + name.replacingOccurrences(of: ".", with: "-")
    }

    /// True when the other side is reachable: shared container, or data arriving over the bridge.
    static var linkSeen = false
    private static let launched = Date().timeIntervalSince1970
    /// The pasteboard outlives launches and reinstalls, so only a status written since this
    /// launch counts as a sign of life.
    var linked: Bool { isShared || Store.linkSeen || status.updated >= Store.launched }

    func readData(_ name: String) -> Data? {
        if !isShared, theirs.contains(name), let pb = inBoard {
            let count = pb.changeCount
            if count != inCount {
                inCount = count
                inCache.removeAll()
            }
            // A local edit of the other side's file wins until that side writes again.
            if localCount[name] != count {
                if let d = inCache[name] { return d }
                if let d = pb.data(forPasteboardType: boardType(name)) {
                    inCache[name] = d
                    return d
                }
            }
        }
        return try? Data(contentsOf: url(name))
    }

    func writeData(_ name: String, _ data: Data) {
        try? data.write(to: url(name), options: .atomic)
        guard !isShared else { return }
        if mine.contains(name) {
            if outItems.isEmpty {
                for n in mine where n != name {
                    if let d = try? Data(contentsOf: url(n)) { outItems[boardType(n)] = d }
                }
            }
            outItems[boardType(name)] = data
            outBoard?.setItems([outItems], options: [:])
        } else if theirs.contains(name) {
            localCount[name] = inBoard?.changeCount
        }
    }

    var fontsDir: URL { base.appendingPathComponent("Fonts", isDirectory: true) }
    func url(_ name: String) -> URL { base.appendingPathComponent(name) }

    func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let d = readData(name) else { return nil }
        return try? JSONDecoder().decode(type, from: d)
    }

    /// Decodes a file saved by an older version: missing keys take their default values.
    func loadMerged<T: Codable>(_ defaults: T, _ name: String) -> T {
        guard let file = readData(name),
              let saved = (try? JSONSerialization.jsonObject(with: file)) as? [String: Any],
              let base = try? JSONEncoder().encode(defaults),
              var dict = (try? JSONSerialization.jsonObject(with: base)) as? [String: Any] else { return defaults }
        for (k, v) in saved { dict[k] = v }
        guard let merged = try? JSONSerialization.data(withJSONObject: dict),
              let value = try? JSONDecoder().decode(T.self, from: merged) else { return defaults }
        return value
    }

    func save<T: Encodable>(_ value: T, _ name: String) {
        guard let d = try? JSONEncoder().encode(value) else { return }
        writeData(name, d)
    }

    var settings: TyperSettings {
        get { loadMerged(TyperSettings(), "settings.json") }
        set { save(newValue, "settings.json") }
    }

    var text: String {
        get { readData("text.txt").flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        set { writeData("text.txt", Data(newValue.utf8)) }
    }

    var status: TyperStatus {
        get { load(TyperStatus.self, "status.json") ?? TyperStatus() }
        set { save(newValue, "status.json") }
    }

    var stats: [RunStat] {
        get { load([RunStat].self, "stats.json") ?? [] }
        set { save(Array(newValue.suffix(60)), "stats.json") }
    }

    func record(_ run: RunStat) {
        guard run.chars > 0 else { return }
        var list = stats
        if let i = list.firstIndex(where: { $0.id == run.id }) { list[i] = run } else { list.append(run) }
        stats = list
    }

    var command: TyperCommand? {
        get { load(TyperCommand.self, "command.json") }
        set { if let v = newValue { save(v, "command.json") } }
    }
}
