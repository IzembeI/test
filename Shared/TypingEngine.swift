import Foundation

enum KBLang: Int, Codable { case en, ru }
enum KBPage: Int, Codable { case letters, numbers, symbols }

// MARK: - Keyboard geometry (iOS layouts)

enum KeyGeo {
    static let enRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    static let ruRows = ["йцукенгшщзх", "фывапролджэ", "ячсмитьбю"]

    static func letterRows(_ l: KBLang) -> [String] { l == .ru ? ruRows : enRows }
    static func numberRows(_ l: KBLang) -> [String] {
        ["1234567890", l == .ru ? "-/:;()₽&@\"" : "-/:;()$&@\"", ".,?!'"]
    }
    static func symbolRows(_ l: KBLang) -> [String] {
        ["[]{}#%^*+=", l == .ru ? "_\\|~<>$€£•" : "_\\|~<>€£¥•", ".,?!'"]
    }
    static func rows(_ l: KBLang, _ p: KBPage) -> [String] {
        switch p {
        case .letters: return letterRows(l)
        case .numbers: return numberRows(l)
        case .symbols: return symbolRows(l)
        }
    }

    /// Characters typed with a long press on another key.
    static let longPress: [Character: Character] = [
        "ё": "е", "ъ": "ь",
        "—": "-", "–": "-", "«": "\"", "»": "\"", "“": "\"", "”": "\"", "„": "\"",
        "…": ".", "’": "'", "‘": "'", "№": "#", "°": "0", "¿": "?", "¡": "!"
    ]

    typealias Pt = (x: Double, y: Double)
    static let spacePos: Pt = (0.5, 3)

    /// Normalised key centres: x in 0...1, y = row index.
    static let positions: [Character: Pt] = {
        var m: [Character: Pt] = [:]
        for rows in [enRows, ruRows] {
            let n = Double(rows[0].count)
            for (r, row) in rows.enumerated() {
                let off = (n - Double(row.count)) / 2
                for (i, c) in row.enumerated() {
                    m[c] = ((off + Double(i) + 0.5) / n, Double(r))
                }
            }
        }
        for l in [KBLang.en, KBLang.ru] {
            for rows in [numberRows(l), symbolRows(l)] {
                for (r, row) in rows.enumerated() {
                    for (i, c) in row.enumerated() {
                        let x = r < 2 ? (Double(i) + 0.5) / 10 : (1.5 + Double(i) * 1.4 + 0.7) / 10
                        m[c] = (x, Double(r))
                    }
                }
            }
        }
        return m
    }()

    static func neighbors(_ c: Character) -> [Character] {
        guard let p = positions[c] else { return [] }
        let rows = ruRows.joined().contains(c) ? ruRows : enRows
        let unit = 1.0 / Double(rows[0].count)
        var out: [Character] = []
        for ch in rows.joined() where ch != c {
            guard let q = positions[ch] else { continue }
            let dx = abs(q.x - p.x), dy = abs(q.y - p.y)
            if dy == 0 && dx < unit * 1.2 {
                out.append(ch); out.append(ch)          // same-row slips are more common
            } else if dy == 1 && dx < unit * 0.8 {
                out.append(ch)
            }
        }
        return out
    }

    struct Loc {
        var lang: KBLang?
        var page: KBPage
        var key: Character
        var long: Bool
    }

    static func locate(_ c: Character, lang: KBLang) -> Loc? {
        let lower = c.lowercased().first ?? c
        if let b = longPress[lower] {
            if b == "е" || b == "ь" { return Loc(lang: .ru, page: .letters, key: b, long: true) }
            if var l = locate(b, lang: lang) { l.long = true; return l }
            return nil
        }
        if enRows.joined().contains(lower) { return Loc(lang: .en, page: .letters, key: lower, long: false) }
        if ruRows.joined().contains(lower) { return Loc(lang: .ru, page: .letters, key: lower, long: false) }
        if numberRows(lang).joined().contains(c) { return Loc(lang: nil, page: .numbers, key: c, long: false) }
        if symbolRows(lang).joined().contains(c) { return Loc(lang: nil, page: .symbols, key: c, long: false) }
        // Currency signs that live on the other language's layout.
        let other: KBLang = lang == .ru ? .en : .ru
        if numberRows(other).joined().contains(c) || symbolRows(other).joined().contains(c) {
            return Loc(lang: nil, page: .symbols, key: c, long: false)
        }
        return nil
    }
}

// MARK: - Steps

struct TypeStep {
    enum Action { case insert(String), backspace, dotShortcut, replace(Int, String), none }
    var delay: Double
    var action: Action
    var hl: String?          // key to highlight: a character, or space/return/shift/delete/mode/alt/globe
    var lang: KBLang         // keyboard state after the step
    var page: KBPage
    var shift: Int           // 0 off, 1 on, 2 caps
    var pos: Int             // source characters committed so far
}

// MARK: - Engine

/// Turns a text into a stream of human-looking key presses.
final class TypingEngine {
    private let chars: [Character]
    private(set) var i: Int
    var settings: TyperSettings

    private var queue: [TypeStep] = []
    private var lang: KBLang
    private var page: KBPage = .letters
    private var caps = false
    private var shiftDisp = 0
    private var lastPos: KeyGeo.Pt?
    private var wpmCur: Double
    private var wpmGoal: Double
    private var driftLeft = 0
    private var lag = 0.0                 // seconds behind (+) or ahead (−) of the target pace
    private var pendingPause = 0.0
    private var noErrUntil = 0
    private var wordFactor = 1.0
    private let startIndex: Int
    private(set) var typoCount = 0

    var total: Int { chars.count }

    init(text: String, start: Int, settings: TyperSettings, lang: KBLang) {
        chars = Array(text)
        i = max(0, min(start, chars.count))
        startIndex = i
        self.settings = settings
        self.lang = lang
        let w = settings.wpmMode == 0 ? settings.wpm : (settings.wpmMin + settings.wpmMax) / 2
        wpmCur = max(1, w)
        wpmGoal = wpmCur
    }

    func next() -> TypeStep? {
        while queue.isEmpty {
            if i >= chars.count { return nil }
            produce()
        }
        return queue.removeFirst()
    }

    // MARK: Randomness

    private func rnd() -> Double { Double.random(in: 0..<1) }
    private func uni(_ a: Double, _ b: Double) -> Double { Double.random(in: a...b) }
    private func gauss() -> Double {
        let u = max(1e-9, rnd()), v = rnd()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }

    // MARK: Pace

    private func updateDrift() {
        if settings.wpmMode == 0 {
            wpmCur = max(1, settings.wpm)
            return
        }
        let lo = max(1, min(settings.wpmMin, settings.wpmMax))
        let hi = max(lo, max(settings.wpmMin, settings.wpmMax))
        if driftLeft <= 0 {
            wpmGoal = uni(lo, hi)
            driftLeft = Int.random(in: 12...40)
        }
        driftLeft -= 1
        wpmCur += (wpmGoal - wpmCur) * 0.07
        wpmCur = min(hi, max(lo, wpmCur))
    }

    private var base: Double { 12.0 / (wpmCur * paceK) }      // 1 word = 5 characters

    /// Warm-up at the start of a run and slight fatigue on long texts.
    private var paceK: Double {
        guard settings.warmup else { return 1 }
        let n = Double(i - startIndex)
        let warm = n < 30 ? 0.82 + 0.18 * n / 30 : 1
        let tired = n > 400 ? max(0.92, 1 - (n - 400) / 1600 * 0.08) : 1
        return warm * tired
    }
    private var pauseK: Double { settings.micropauses ? settings.pauseStrength : 0 }

    private func commit(_ n: Int) {
        lag -= Double(n) * base
        lag = max(-3, min(3, lag))
    }

    private func push(_ action: TypeStep.Action, hl: String?, delay: Double) {
        lag += delay
        queue.append(TypeStep(delay: delay, action: action, hl: hl,
                              lang: lang, page: page, shift: page == .letters ? shiftDisp : 0, pos: i))
    }

    /// How comfortable the jump between two keys is for two thumbs (1 = neutral).
    private func ergo(_ a: KeyGeo.Pt, _ b: KeyGeo.Pt) -> Double {
        let dx = abs(a.x - b.x), dy = abs(a.y - b.y)
        if dx < 0.001 && dy < 0.001 { return 0.86 }
        if a.y == 3 || b.y == 3 { return 0.92 }
        var f: Double
        if (a.x < 0.5) != (b.x < 0.5) {
            f = 0.80 + 0.03 * dy                    // alternating thumbs — fast
        } else {
            f = 0.98 + dx * 0.6 + dy * 0.07         // same thumb has to travel
        }
        if b.x < 0.07 || b.x > 0.93 { f += 0.05 }
        return f
    }

    private func keyDelay(to p: KeyGeo.Pt?) -> Double {
        var f = 1.0
        var extra = 0.0
        if settings.ergonomics, let a = lastPos, let b = p {
            let e = ergo(a, b)
            f = e * wordFactor
            if e > 1.14 && rnd() < 0.45 { extra = uni(0.04, 0.11) * pauseK }
        }
        let control = max(0.7, min(1.3, 1 - lag / 2.0))
        let d = base * f * exp(gauss() * 0.16) * control + extra + pendingPause
        pendingPause = 0
        if let p = p { lastPos = p }
        return max(0.004, d)
    }

    private var modeDelay: Double { base * uni(1.0, 1.6) + 0.04 }

    private func autoShift(at idx: Int) -> Bool {
        if idx <= 0 { return true }
        let p = chars[idx - 1]
        if p.isNewline { return true }
        if p == " " && idx >= 2 && ".!?".contains(chars[idx - 2]) { return true }
        return false
    }

    private func refreshShift(at idx: Int) {
        shiftDisp = caps ? 2 : (autoShift(at: idx) ? 1 : 0)
    }

    private func isLetter(_ c: Character) -> Bool {
        guard let l = KeyGeo.locate(c, lang: lang) else { return false }
        return l.page == .letters
    }

    private func startWord() {
        var j = i
        var sum = 0.0, cnt = 0.0
        var prev: KeyGeo.Pt?
        while j < chars.count, isLetter(chars[j]) {
            let k = chars[j].lowercased().first ?? chars[j]
            if let p = KeyGeo.positions[KeyGeo.longPress[k] ?? k] {
                if let a = prev { sum += ergo(a, p); cnt += 1 }
                prev = p
            }
            j += 1
        }
        let len = j - i
        var f = 1.0
        if cnt > 0 {
            let avg = sum / cnt
            if len >= 6 && avg < 0.93 { f = 0.90 }      // long comfortable word — burst
            else if avg > 1.05 { f = 1.07 }             // awkward word — slower
        }
        wordFactor = f * exp(gauss() * 0.06)
    }

    private func afterPause(_ c: Character) {
        let k = pauseK
        guard k > 0 else { return }
        if c == " " {
            pendingPause += rnd() < 0.05 ? uni(0.15, 0.40) * k : uni(0, 0.03) * k
        } else if ",;:".contains(c) {
            pendingPause += uni(0.10, 0.24) * k
        } else if ".!?…".contains(c) {
            pendingPause += uni(0.22, 0.55) * k
        } else if c.isNewline {
            pendingPause += uni(0.35, 0.80) * k
        }
        let r = rnd()
        if r < 0.003 { pendingPause += uni(0.6, 1.3) * k }
        else if r < 0.013 { pendingPause += uni(0.08, 0.22) * k }
    }

    // MARK: Production

    private func produce() {
        let c = chars[i]
        updateDrift()
        refreshShift(at: i)

        if c.isNewline {
            if settings.newlineMode == 2 { i += 1; return }
            let d = keyDelay(to: (0.88, 3))
            i += 1; commit(1)
            refreshShift(at: i)
            if settings.newlineMode == 1 {
                push(.insert(" "), hl: "space", delay: d)
            } else {
                page = .letters
                push(.insert("\n"), hl: "return", delay: d)
            }
            afterPause(c)
            return
        }

        if c == " " {
            let d = keyDelay(to: KeyGeo.spacePos)
            i += 1; commit(1)
            page = .letters                         // iOS returns to letters after a space
            refreshShift(at: i)
            push(.insert(" "), hl: "space", delay: d)
            afterPause(c)
            return
        }

        guard let loc = KeyGeo.locate(c, lang: lang) else {
            // Emoji and other characters that are not on the keyboard.
            i += 1; commit(1)
            push(.insert(String(c)), hl: nil, delay: base * uni(1.2, 2.0))
            return
        }

        // "." after a letter and before a space: the double-space shortcut.
        if c == ".", page == .letters, i > 0, i + 1 < chars.count,
           chars[i + 1] == " ", isLetter(chars[i - 1]), rnd() < 0.7 {
            let d1 = keyDelay(to: KeyGeo.spacePos)
            push(.insert(" "), hl: "space", delay: d1)
            i += 2; commit(2)
            refreshShift(at: i)
            push(.dotShortcut, hl: "space", delay: max(0.05, base * uni(0.45, 0.7)))
            afterPause(".")
            return
        }

        if loc.page == .letters {
            if i == 0 || !isLetter(chars[i - 1]) { startWord() }
            if page != .letters {
                page = .letters
                push(.none, hl: "mode", delay: modeDelay)
            }
            if let l = loc.lang, l != lang {
                lang = l
                push(.none, hl: "globe", delay: uni(0.28, 0.5))
                lastPos = nil
            }
            let upper = c.isUppercase
            if upper != (caps || autoShift(at: i)) {
                if upper {
                    caps = i + 1 < chars.count && chars[i + 1].isUppercase
                    shiftDisp = caps ? 2 : 1
                } else {
                    caps = false
                    shiftDisp = 0
                }
                push(.none, hl: "shift", delay: base * uni(0.8, 1.3))
            }
            if !upper && tryError() { return }

            var d = keyDelay(to: KeyGeo.positions[loc.key])
            if loc.long { d += uni(0.38, 0.55) }
            i += 1; commit(1)
            refreshShift(at: i)
            push(.insert(String(c)), hl: String(loc.key), delay: d)
            afterPause(c)
            return
        }

        // Digits and punctuation.
        if page == .letters {
            page = .numbers
            push(.none, hl: "mode", delay: modeDelay)
        }
        if page != loc.page {
            page = loc.page
            push(.none, hl: "alt", delay: modeDelay)
        }
        var d = keyDelay(to: KeyGeo.positions[loc.key])
        if loc.long { d += uni(0.38, 0.55) }
        i += 1; commit(1)
        if c == "'" { page = .letters }
        refreshShift(at: i)
        push(.insert(String(c)), hl: String(loc.key), delay: d)
        afterPause(c)
    }

    // MARK: Typos

    /// Keeps typing the word with the wrong letter in it; the space then swaps the whole
    /// word for the right one, the way iOS autocorrection does.
    private func autocorrected(wrong: Character) -> Bool {
        let n = chars.count
        func plain(_ ch: Character) -> Bool {
            guard !ch.isUppercase, let l = KeyGeo.locate(ch, lang: lang) else { return false }
            return l.page == .letters && l.lang == lang && !l.long
        }
        var start = i
        while start > 0, isLetter(chars[start - 1]) { start -= 1 }
        var end = i + 1
        while end < n, plain(chars[end]) { end += 1 }
        guard end < n, chars[end] == " ", end - start >= 4 else { return false }
        shiftDisp = 0
        push(.insert(String(wrong)), hl: String(wrong), delay: keyDelay(to: KeyGeo.positions[wrong]))
        for j in (i + 1)..<end {
            let ch = chars[j]
            push(.insert(String(ch)), hl: String(ch), delay: keyDelay(to: KeyGeo.positions[ch]))
        }
        let d = keyDelay(to: KeyGeo.spacePos)
        let consumed = end + 1 - i
        i = end + 1
        commit(consumed)
        refreshShift(at: i)
        push(.replace(end - start, String(chars[start..<end]) + " "), hl: "space", delay: d)
        typoCount += 1
        noErrUntil = i + 2
        afterPause(" ")
        return true
    }

    /// Types a mistake, notices it (sometimes a few characters later), deletes back and
    /// leaves the cursor so that normal typing continues from the right place.
    private func tryError() -> Bool {
        guard settings.errorsEnabled, settings.errorRate > 0, i >= noErrUntil,
              rnd() < min(1, settings.errorRate / 100) else { return false }
        let n = chars.count
        func plain(_ ch: Character) -> Bool {
            guard !ch.isUppercase, let l = KeyGeo.locate(ch, lang: lang) else { return false }
            return l.page == .letters && l.lang == lang && !l.long
        }
        let c = chars[i]
        guard plain(c) else { return false }
        let nx: Character? = i + 1 < n ? chars[i + 1] : nil

        var typed: [Character]
        var consumed = 1
        let r = rnd()
        if r < 0.20, let x = nx, plain(x), x != c {
            typed = [x, c]; consumed = 2                    // swapped letters
        } else if r < 0.32 {
            typed = [c, c]                                  // doubled letter
        } else if r < 0.45, let x = nx, plain(x), x != c {
            typed = [x]; consumed = 2                       // skipped letter
        } else {
            guard let w = KeyGeo.neighbors(c).randomElement() else { return false }
            typed = [w]                                     // neighbouring key
            if settings.autocorrect, rnd() < 0.45, autocorrected(wrong: w) { return true }
        }
        typoCount += 1

        let kr = rnd()
        var k = kr < 0.45 ? 0 : (kr < 0.72 ? 1 : (kr < 0.90 ? 2 : 3))
        let noticedLate = k > 0
        var j = i + consumed
        while k > 0, j < n, plain(chars[j]) || chars[j] == " " {
            typed.append(chars[j]); j += 1; k -= 1
        }

        var prefix = 0
        while prefix < typed.count, i + prefix < n, typed[prefix] == chars[i + prefix] { prefix += 1 }

        shiftDisp = 0
        for ch in typed {
            if ch == " " {
                push(.insert(" "), hl: "space", delay: keyDelay(to: KeyGeo.spacePos))
            } else {
                push(.insert(String(ch)), hl: String(ch), delay: keyDelay(to: KeyGeo.positions[ch]))
            }
        }
        let dels = typed.count - prefix
        for d in 0..<dels {
            let delay = d == 0 ? (noticedLate ? uni(0.22, 0.5) : uni(0.13, 0.32)) : uni(0.085, 0.14)
            push(.backspace, hl: "delete", delay: delay)
        }
        lastPos = (0.93, 2)
        pendingPause += uni(0.06, 0.18)
        if prefix > 0 {
            i += prefix
            commit(prefix)
        }
        noErrUntil = i + consumed + 2
        return true
    }
}
