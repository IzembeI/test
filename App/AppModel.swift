import SwiftUI
import UIKit
import CoreText

// MARK: - Theme

struct Theme: Codable, Equatable {
    var preset = "mono"
    var accent = "FFFFFF"
    var bg = ["050505", "3A3A3F", "0E0E10"]      // gradient stops
    var text = "F5F5F7"
    var angle = 160.0                             // gradient angle, degrees
    var animated = true
    var speed = 1.0
    var useImage = false
    var blur = 12.0
    var dim = 0.35
    var fontRegular = ""
    var fontBold = ""

    static let presets: [(id: String, name: String, theme: Theme)] = [
        ("mono", "Моно", Theme()),
        ("graphite", "Графит", Theme(preset: "graphite", accent: "C8D0DA", bg: ["15171B", "2B3038", "0C0D10"], text: "F1F3F6", angle: 200)),
        ("aurora", "Аврора", Theme(preset: "aurora", accent: "8EE6E0", bg: ["0A0F24", "3B2A6E", "0F5A63"], text: "F2F6FF", angle: 150)),
        ("dusk", "Закат", Theme(preset: "dusk", accent: "FFB38A", bg: ["190D1C", "7A2F45", "C4603F"], text: "FFF5EF", angle: 170)),
        ("deep", "Глубина", Theme(preset: "deep", accent: "5FD4FF", bg: ["03121F", "0B3A57", "06202F"], text: "EEF8FF", angle: 180)),
        ("pearl", "Жемчуг", Theme(preset: "pearl", accent: "16161A", bg: ["F4F4F6", "D9DCE3", "ECEEF2"], text: "16161A", angle: 150))
    ]

    var name: String { Theme.presets.first(where: { $0.id == preset })?.name ?? "Своё" }

    var gradient: LinearGradient {
        let a = angle * .pi / 180
        let dx = sin(a) / 2, dy = -cos(a) / 2
        return LinearGradient(colors: bg.map { Color(hex: $0) },
                              startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy),
                              endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy))
    }
}

extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ x: CGFloat) -> Int { Int((max(0, min(1, x)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", c(r), c(g), c(b))
    }
}

// MARK: - Fonts

struct FontInfo: Identifiable, Equatable {
    var id: String { file }
    let file: String
    let name: String        // PostScript name
}

// MARK: - Model

final class AppModel: ObservableObject {
    let store = Store.shared

    @Published var settings: TyperSettings { didSet { if settings != oldValue { store.settings = settings } } }
    @Published var text: String { didSet { if text != oldValue { store.text = text } } }
    @Published var theme: Theme { didSet { if theme != oldValue { store.save(theme, "theme.json") } } }
    @Published var status = TyperStatus()
    @Published var lastCommand: TyperCommand?
    @Published var bgImage: UIImage?
    @Published var fonts: [FontInfo] = []
    @Published var library: [SavedText] = [] { didSet { if library != oldValue { store.save(library, "library.json") } } }
    @Published var profiles: [TypingProfile] = [] { didSet { if profiles != oldValue { store.save(profiles, "profiles.json") } } }
    @Published var stats: [RunStat] = []

    private var timer: Timer?
    private let server = LinkServer()
    private var background = UIBackgroundTaskIdentifier.invalid

    init() {
        let st = Store.shared
        settings = st.settings
        text = st.text
        theme = st.loadMerged(Theme(), "theme.json")
        status = st.status
        bgImage = UIImage(contentsOfFile: st.url("bg.jpg").path)
        reloadFonts()
        if !st.isShared {
            // Without a shared container the keyboard fetches everything from the app directly.
            server.start()
            let nc = NotificationCenter.default
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                guard let s = self, s.background == .invalid else { return }
                s.background = UIApplication.shared.beginBackgroundTask {
                    UIApplication.shared.endBackgroundTask(s.background)
                    s.background = .invalid
                }
            }
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                guard let s = self else { return }
                s.server.start()
                if s.background != .invalid {
                    UIApplication.shared.endBackgroundTask(s.background)
                    s.background = .invalid
                }
            }
        }
        library = st.load([SavedText].self, "library.json") ?? []
        profiles = st.load([TypingProfile].self, "profiles.json") ?? AppModel.defaultProfiles
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let s = self else { return }
            let st = s.store.status
            if st != s.status { s.status = st }
        }
    }

    // MARK: Library, profiles, statistics

    static var defaultProfiles: [TypingProfile] {
        var fast = TyperSettings(); fast.wpm = 160; fast.errorRate = 2
        var neat = TyperSettings(); neat.wpm = 110; neat.errorsEnabled = false
        var loose = TyperSettings(); loose.wpmMode = 1; loose.wpmMin = 120; loose.wpmMax = 140; loose.errorRate = 6
        return [TypingProfile(name: "Быстрый", settings: fast),
                TypingProfile(name: "Аккуратный", settings: neat),
                TypingProfile(name: "Небрежный", settings: loose)]
    }

    func saveCurrentText() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !library.contains(where: { $0.text == text }) else { return }
        let line = t.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? t
        library.insert(SavedText(title: String(line.prefix(40)), text: text), at: 0)
    }

    func importText(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        if let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251) {
            text = s
        }
    }

    func saveProfile(named name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        if let i = profiles.firstIndex(where: { $0.name == n }) {
            profiles[i].settings = settings
        } else {
            profiles.append(TypingProfile(name: n, settings: settings))
        }
    }

    /// A profile carries the typing style only; keyboard and launch options stay as they are.
    func apply(_ p: TypingProfile) {
        var s = settings
        let v = p.settings
        s.wpmMode = v.wpmMode; s.wpm = v.wpm; s.wpmMin = v.wpmMin; s.wpmMax = v.wpmMax
        s.errorsEnabled = v.errorsEnabled; s.errorRate = v.errorRate; s.autocorrect = v.autocorrect
        s.micropauses = v.micropauses; s.pauseStrength = v.pauseStrength
        s.ergonomics = v.ergonomics; s.warmup = v.warmup
        settings = s
    }

    private func style(_ v: TyperSettings) -> [Double] {
        [Double(v.wpmMode), v.wpm, v.wpmMin, v.wpmMax, v.errorsEnabled ? 1 : 0, v.errorRate, v.autocorrect ? 1 : 0,
         v.micropauses ? 1 : 0, v.pauseStrength, v.ergonomics ? 1 : 0, v.warmup ? 1 : 0]
    }

    func matches(_ p: TypingProfile) -> Bool { style(p.settings) == style(settings) }

    func loadStats() { stats = store.stats.reversed() }

    func clearStats() {
        store.stats = []
        stats = []
    }

    // MARK: Commands

    func send(_ action: String, delay: Double = 0) {
        let cmd = TyperCommand(action: action, fireAt: Date().timeIntervalSince1970 + delay)
        store.command = cmd
        lastCommand = cmd
    }

    /// The keyboard has not picked up the last command yet.
    var waitingForKeyboard: Bool {
        guard let c = lastCommand else { return false }
        return status.lastCmd != c.id && (c.action == "start" || c.action == "resume")
    }

    var estimatedSeconds: Double {
        let wpm = settings.wpmMode == 0 ? settings.wpm : (settings.wpmMin + settings.wpmMax) / 2
        return Double(text.count) * 12 / max(5, wpm)
    }

    // MARK: Theme helpers

    var accent: Color { Color(hex: theme.accent) }
    var onAccent: Color { accent.isLight ? Color(hex: "0B0B0D") : .white }
    var textColor: Color { Color(hex: theme.text) }
    var isLight: Bool {
        if theme.useImage && bgImage != nil { return false }
        return Color(hex: theme.bg.first ?? "000000").isLight
    }
    var stroke: Color { isLight ? .black.opacity(0.10) : .white.opacity(0.14) }
    var field: Color { isLight ? .black.opacity(0.05) : .white.opacity(0.07) }

    func font(_ size: CGFloat, bold: Bool = false) -> Font {
        let name = bold ? theme.fontBold : theme.fontRegular
        if !name.isEmpty, UIFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: bold ? .bold : .regular, design: .rounded)
    }

    func apply(preset id: String) {
        guard let p = Theme.presets.first(where: { $0.id == id }) else { return }
        var t = p.theme
        t.fontRegular = theme.fontRegular
        t.fontBold = theme.fontBold
        t.useImage = false
        t.blur = theme.blur
        t.dim = theme.dim
        t.animated = theme.animated
        t.speed = theme.speed
        theme = t
    }

    func setBackground(_ image: UIImage?) {
        let url = store.url("bg.jpg")
        if let img = image, let data = img.jpegData(compressionQuality: 0.85) {
            try? data.write(to: url, options: .atomic)
            bgImage = img
            theme.useImage = true
        } else {
            try? FileManager.default.removeItem(at: url)
            bgImage = nil
            theme.useImage = false
        }
    }

    // MARK: Fonts

    func reloadFonts() {
        let files = (try? FileManager.default.contentsOfDirectory(at: store.fontsDir, includingPropertiesForKeys: nil)) ?? []
        var list: [FontInfo] = []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            guard let provider = CGDataProvider(url: url as CFURL),
                  let cg = CGFont(provider),
                  let ps = cg.postScriptName as String? else { continue }
            list.append(FontInfo(file: url.lastPathComponent, name: ps))
        }
        fonts = list
        // Samsung fonts become the default as soon as they are imported.
        if theme.fontRegular.isEmpty,
           let f = list.first(where: { $0.name.lowercased().contains("samsung") && !$0.name.lowercased().contains("bold") }) {
            theme.fontRegular = f.name
        }
        if theme.fontBold.isEmpty,
           let f = list.first(where: { $0.name.lowercased().contains("samsung") && $0.name.lowercased().contains("bold") }) {
            theme.fontBold = f.name
        }
    }

    func importFonts(_ urls: [URL]) {
        for url in urls {
            let ok = url.startAccessingSecurityScopedResource()
            let dst = store.fontsDir.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: url, to: dst)
            if ok { url.stopAccessingSecurityScopedResource() }
        }
        reloadFonts()
    }

    func deleteFont(_ f: FontInfo) {
        let url = store.fontsDir.appendingPathComponent(f.file)
        CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
        try? FileManager.default.removeItem(at: url)
        if theme.fontRegular == f.name { theme.fontRegular = "" }
        if theme.fontBold == f.name { theme.fontBold = "" }
        reloadFonts()
    }
}

// MARK: - In-app demo of the typing engine

final class DemoRunner: ObservableObject {
    @Published var output = ""
    @Published var running = false
    @Published var wpm = 0.0

    private var engine: TypingEngine?
    private var work: DispatchWorkItem?
    private var started = Date()

    func start(text: String, settings: TyperSettings) {
        stop()
        guard !text.isEmpty else { return }
        output = ""
        wpm = 0
        engine = TypingEngine(text: text, start: 0, settings: settings, lang: .ru)
        started = Date()
        running = true
        step()
    }

    func stop() {
        work?.cancel()
        engine = nil
        running = false
    }

    private func step() {
        guard let e = engine, let s = e.next() else {
            running = false
            return
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.running else { return }
            switch s.action {
            case .insert(let t): self.output += t
            case .backspace: if !self.output.isEmpty { self.output.removeLast() }
            case .dotShortcut:
                if !self.output.isEmpty { self.output.removeLast() }
                self.output += ". "
            case .replace(let n, let t):
                self.output.removeLast(min(n, self.output.count))
                self.output += t
            case .none: break
            }
            let dt = Date().timeIntervalSince(self.started)
            if dt > 1 { self.wpm = Double(s.pos) / 5 / (dt / 60) }
            self.step()
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + s.delay, execute: item)
    }
}
