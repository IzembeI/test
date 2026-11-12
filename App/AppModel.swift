import SwiftUI
import UIKit
import CoreText

// MARK: - Theme

struct Theme: Codable, Equatable {
    var preset = "mono"
    var accent = "FFFFFF"
    var bg = ["000000", "FFFFFF", "7A7A80"]
    var text = "FFFFFF"
    var animated = true
    var speed = 1.0
    var useImage = false
    var blur = 12.0
    var dim = 0.35
    var fontRegular = ""
    var fontBold = ""

    static let presets: [(id: String, name: String, theme: Theme)] = [
        ("mono", "Моно", Theme()),
        ("aurora", "Аврора", Theme(preset: "aurora", accent: "7DF9FF", bg: ["0B1026", "5B2A86", "1FA2A6"])),
        ("sunset", "Закат", Theme(preset: "sunset", accent: "FFD27D", bg: ["1A0B1E", "FF5E62", "FF9966"])),
        ("ocean", "Океан", Theme(preset: "ocean", accent: "00FFCA", bg: ["021B2B", "0A4D68", "05BFDB"]))
    ]
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

    private var timer: Timer?

    init() {
        let st = Store.shared
        settings = st.settings
        text = st.text
        theme = st.load(Theme.self, "theme.json") ?? Theme()
        status = st.status
        bgImage = UIImage(contentsOfFile: st.url("bg.jpg").path)
        reloadFonts()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let s = self else { return }
            let st = s.store.status
            if st != s.status { s.status = st }
        }
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
    var textColor: Color { Color(hex: theme.text) }

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
        t.useImage = theme.useImage
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
