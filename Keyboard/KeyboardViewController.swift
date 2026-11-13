import UIKit

final class RootInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

final class KeyboardViewController: UIInputViewController {
    private let store = Store.shared
    private let kb = KeyboardView()
    private let panel = UIStackView()
    private let info = UILabel()
    private let suggest = UIStackView()
    private let checker = UITextChecker()
    private var suggestWord = ""
    private let playButton = UIButton(type: .system)

    private var settings = TyperSettings()
    private var status = TyperStatus()
    private var engine: TypingEngine?
    private var pendingStep: TypeStep?
    private var work: DispatchWorkItem?
    private var poll: Timer?
    private var appearedAt = Date()
    private var stepCount = 0
    private var heightConstraint: NSLayoutConstraint?
    private var panelVisible = false
    private var skinKey = -1
    private let link = LinkClient()
    private var ticks = 0
    private var clipCount = -1
    private var notice = ""
    private var noticeUntil = Date.distantPast
    private var run: RunStat?
    private var pendingLayout: (KBLang, KBPage, Int)?
    private var runStart = 0
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    /// How long after its fire time a pending start is still honoured, in seconds.
    private static let startWindow = 120.0

    // MARK: Lifecycle

    override func loadView() {
        let v = RootInputView(frame: .zero, inputViewStyle: .keyboard)
        v.allowsSelfSizing = true
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        settings = store.settings
        status = store.status
        if status.state == "running" { status.state = "paused" }

        kb.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(kb)
        NSLayoutConstraint.activate([
            kb.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            kb.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            kb.topAnchor.constraint(equalTo: view.topAnchor),
            kb.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let h = view.heightAnchor.constraint(equalToConstant: 260)
        h.priority = UILayoutPriority(999)
        h.isActive = true
        heightConstraint = h

        kb.onKey = { [weak self] spec in self?.manualKey(spec) }
        kb.onLongPress = { [weak self] id in self?.longPress(id) }
        kb.onTouchDown = { [weak self] in
            guard let s = self, s.status.state == "running", s.settings.pauseOnTouch else { return false }
            s.pause()
            return true
        }
        buildPanel()
        buildSuggestions()
        updateAutoShift()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        appearedAt = Date()
        settings = store.settings
        applySkin()
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        tick()
        saveStatus()        // lets the app see that the keyboard is reachable
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if status.state == "running" { pause() }
        poll?.invalidate()
        poll = nil
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let b = UIScreen.main.bounds
        let landscape = b.width > b.height
        kb.topInset = landscape ? 32 : 44
        heightConstraint?.constant = landscape ? 192 : 260
        panel.frame = CGRect(x: 8, y: 2, width: view.bounds.width - 16, height: kb.topInset - 4)
        suggest.frame = panel.frame
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        applySkin()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        applySkin()
        if status.state != "running" { updateAutoShift() }
        updateSuggestions()
    }

    private func applySkin() {
        let dark = textDocumentProxy.keyboardAppearance == .dark || traitCollection.userInterfaceStyle == .dark
        let key = settings.skin * 2 + (dark ? 1 : 0)
        guard key != skinKey else { return }
        skinKey = key
        kb.skin = Skin.make(settings.skin, systemDark: dark)
        let c = kb.skin.text
        info.textColor = c
        panel.arrangedSubviews.forEach { $0.tintColor = c }
    }

    // MARK: Hidden control panel

    private func button(_ icon: String, _ action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: icon), for: .normal)
        b.addTarget(self, action: action, for: .touchUpInside)
        b.widthAnchor.constraint(equalToConstant: 40).isActive = true
        return b
    }

    private func buildPanel() {
        panel.axis = .horizontal
        panel.alignment = .center
        panel.spacing = 4
        panel.isHidden = true
        info.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        info.adjustsFontSizeToFitWidth = true
        info.minimumScaleFactor = 0.7
        playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        playButton.addTarget(self, action: #selector(toggleRun), for: .touchUpInside)
        playButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        panel.addArrangedSubview(info)
        panel.addArrangedSubview(playButton)
        panel.addArrangedSubview(button("stop.fill", #selector(stopTapped)))
        panel.addArrangedSubview(button("doc.on.clipboard", #selector(pasteTapped)))
        panel.addArrangedSubview(button("minus", #selector(slower)))
        panel.addArrangedSubview(button("plus", #selector(faster)))
        panel.addArrangedSubview(button("chevron.down", #selector(hidePanel)))
        view.addSubview(panel)
        refreshPanel()
    }

    /// Opens the panel with a message, so a failed start never looks like nothing happened.
    private func fail(_ message: String) {
        notice = message
        noticeUntil = Date().addingTimeInterval(6)
        panelVisible = true
        panel.isHidden = false
        suggest.isHidden = true
        info.text = message
    }

    private func applyPayload(_ p: LinkPayload) {
        store.settings = p.settings
        if p.text != store.text { store.text = p.text }
        if let c = p.command { store.command = c }
        settings = p.settings
        engine?.settings = p.settings
        applySkin()
        refreshPanel()
    }

    /// Last-resort channel: the app leaves its payload on the system clipboard at start.
    private func checkClipboard() {
        let pb = UIPasteboard.general
        guard pb.changeCount != clipCount else { return }
        clipCount = pb.changeCount
        guard pb.contains(pasteboardTypes: [LocalLink.clipType]),
              let d = pb.data(forPasteboardType: LocalLink.clipType),
              let p = try? JSONDecoder().decode(LinkPayload.self, from: d) else { return }
        Store.linkSeen = true
        applyPayload(p)
    }

    private func refreshPanel() {
        guard panelVisible else { return }
        if Date() < noticeUntil {
            info.text = notice
            return
        }
        let names = ["idle": "Готов", "armed": "Отсчёт", "running": "Печать", "paused": "Пауза", "done": "Готово"]
        let total = engine?.total ?? store.text.count
        let speed = settings.wpmMode == 0
            ? "\(Int(settings.wpm))"
            : "\(Int(settings.wpmMin))–\(Int(settings.wpmMax))"
        info.text = "\(names[status.state] ?? "") \(status.pos)/\(total) · \(speed) впм · сб. \(Store.build)"
        let running = status.state == "running" || status.state == "armed"
        playButton.setImage(UIImage(systemName: running ? "pause.fill" : "play.fill"), for: .normal)
    }

    @objc private func hidePanel() {
        panelVisible = false
        panel.isHidden = true
        suggest.isHidden = false
        updateSuggestions()
    }

    @objc private func toggleRun() {
        switch status.state {
        case "running", "armed": pause()
        case "paused": resume(after: 0.3)
        default: start(at: Date().timeIntervalSince1970 + 0.4, reset: true)
        }
    }

    @objc private func stopTapped() { stopAll() }

    @objc private func pasteTapped() {
        guard hasFullAccess, let s = UIPasteboard.general.string, !s.isEmpty else {
            info.text = hasFullAccess ? "Буфер пуст" : "Нужен «Полный доступ»"
            return
        }
        stopAll()
        store.text = s
        refreshPanel()
    }

    @objc private func slower() { bump(-5) }
    @objc private func faster() { bump(5) }

    private func bump(_ d: Double) {
        if settings.wpmMode == 0 {
            settings.wpm = max(1, min(100000, settings.wpm + d))
        } else {
            settings.wpmMin = max(1, min(100000, settings.wpmMin + d))
            settings.wpmMax = max(1, min(100000, settings.wpmMax + d))
        }
        store.settings = settings
        engine?.settings = settings
        refreshPanel()
    }

    // MARK: Commands from the app

    private func tick() {
        ticks += 1
        if !store.isShared && hasFullAccess && ticks % 4 == 1 {
            link.sync(LinkReport(status: status, stats: store.stats)) { [weak self] p in self?.applyPayload(p) }
            checkClipboard()
        }
        if let cmd = store.command, cmd.id != status.lastCmd {
            status.lastCmd = cmd.id
            if Date().timeIntervalSince1970 - cmd.fireAt < KeyboardViewController.startWindow {
                switch cmd.action {
                case "start": start(at: cmd.fireAt, reset: true)
                case "resume": start(at: cmd.fireAt, reset: false)
                case "pause": pause()
                default: stopAll()
                }
            }
            saveStatus()
        }
        if status.state == "armed" {
            let now = Date()
            if now.timeIntervalSince1970 - status.fireAt > KeyboardViewController.startWindow {
                // The start was requested long ago and never happened: drop it instead of
                // typing into whatever field the keyboard is opened in next.
                status.state = status.pos > 0 ? "paused" : "idle"
                saveStatus()
                return
            }
            // If the keyboard was opened after the timer ran out, give it a moment to settle.
            if now.timeIntervalSince1970 >= status.fireAt && now.timeIntervalSince(appearedAt) > 0.7 {
                begin()
            }
        }
    }

    private func saveStatus() {
        status.updated = Date().timeIntervalSince1970
        status.build = Store.build
        store.status = status
        refreshPanel()
    }

    // MARK: Run control

    private func start(at fireAt: Double, reset: Bool) {
        work?.cancel()
        if reset {
            saveRun()
            run = nil
            engine = nil
            pendingStep = nil
            status.pos = 0
        }
        status.fireAt = fireAt
        status.state = "armed"
        saveStatus()
    }

    private func resume(after delay: Double) {
        start(at: Date().timeIntervalSince1970 + delay, reset: false)
    }

    private func begin() {
        settings = store.settings
        if engine == nil {
            if store.text.isEmpty && !store.isShared && hasFullAccess {
                checkClipboard()
                if store.text.isEmpty, let clip = UIPasteboard.general.string, !clip.isEmpty { store.text = clip }
            }
            let text = store.text
            if status.pos >= text.count { status.pos = 0 }
            guard !text.isEmpty else {
                status.state = "idle"
                saveStatus()
                fail(hasFullAccess
                     ? "Нет текста: скопируйте его и нажмите кнопку буфера"
                     : "Включите «Полный доступ» для Mercury")
                return
            }
            pendingStep = nil
            engine = TypingEngine(text: text, start: status.pos, settings: settings, lang: kb.lang)
        } else {
            engine?.settings = settings
        }
        if run == nil {
            run = RunStat()
            runStart = status.pos
        }
        if settings.startHaptic && hasFullAccess {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        status.total = engine?.total ?? 0
        status.state = "running"
        saveStatus()
        runNext()
    }

    private func pause() {
        work?.cancel()
        guard status.state == "running" || status.state == "armed" else { return }
        status.state = "paused"
        saveRun()
        saveStatus()
        updateAutoShift()
    }

    private func saveRun() {
        if let r = run { store.record(r) }
    }

    private func stopAll() {
        work?.cancel()
        saveRun()
        run = nil
        engine = nil
        pendingStep = nil
        status.pos = 0
        status.state = "idle"
        saveStatus()
        updateAutoShift()
    }

    private func runNext() {
        guard status.state == "running", let eng = engine else { return }
        let step: TypeStep
        if let p = pendingStep {
            step = p
        } else if let n = eng.next() {
            step = n
            pendingStep = n
        } else {
            saveRun()
            run = nil
            engine = nil
            status.pos = status.total
            status.state = "done"
            saveStatus()
            updateAutoShift()
            return
        }
        let item = DispatchWorkItem { [weak self] in self?.exec(step) }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + step.delay, execute: item)
    }

    private func exec(_ step: TypeStep) {
        guard status.state == "running" else { return }
        pendingStep = nil
        if let (l, p, s) = pendingLayout {
            // The previous step's layout change must be in place before this key is shown.
            pendingLayout = nil
            kb.set(lang: l, page: p, shift: s)
        }
        let proxy = textDocumentProxy
        switch step.action {
        case .insert(let s): proxy.insertText(s)
        case .backspace: proxy.deleteBackward()
        case .dotShortcut:
            proxy.deleteBackward()
            proxy.insertText(". ")
        case .replace(let n, let s):
            for _ in 0..<n { proxy.deleteBackward() }
            proxy.insertText(s)
        case .none: break
        }
        if var r = run {
            r.seconds += step.delay
            r.chars = max(0, step.pos - runStart)
            r.typos = engine?.typoCount ?? r.typos
            run = r
        }
        if settings.showTaps, let id = step.hl {
            kb.flash(id, duration: Double.random(in: 0.06...0.11))
        }
        if settings.clickSound { UIDevice.current.playInputClick() }
        if settings.haptics && hasFullAccess { haptic.impactOccurred(intensity: 0.6) }
        if settings.showTaps {
            // Let the pressed key stay visible for a moment before the layout changes.
            let (l, p, s) = (step.lang, step.page, step.shift)
            if l != kb.lang || p != kb.page {
                pendingLayout = (l, p, s)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self = self, let (l, p, s) = self.pendingLayout else { return }
                    self.pendingLayout = nil
                    self.kb.set(lang: l, page: p, shift: s)
                }
            } else {
                kb.set(lang: l, page: p, shift: s)
            }
        }
        // Spell-checking every keystroke would delay the next one; refresh at word ends and
        // every few keys instead.
        if case .insert(let s) = step.action, s == " " || stepCount % 4 == 0 { updateSuggestions() }
        status.pos = step.pos
        stepCount += 1
        if stepCount % 8 == 0 { saveStatus() }
        runNext()
    }

    // MARK: Suggestions bar

    private func buildSuggestions() {
        suggest.axis = .horizontal
        suggest.distribution = .fillEqually
        for i in 0..<3 {
            let b = UIButton(type: .system)
            b.tag = i
            b.titleLabel?.font = .systemFont(ofSize: 17)
            b.titleLabel?.lineBreakMode = .byTruncatingTail
            b.addTarget(self, action: #selector(suggestionTapped(_:)), for: .touchUpInside)
            suggest.addArrangedSubview(b)
        }
        view.addSubview(suggest)
    }

    /// Fills the bar above the keys the way the stock keyboard does: the word as typed,
    /// then corrections and completions for it.
    private func updateSuggestions() {
        guard !panelVisible else { return }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let word = String(before.reversed().prefix(while: { $0.isLetter }).reversed())
        suggestWord = word
        var slots: [String] = []
        if !word.isEmpty {
            let lang = word.unicodeScalars.contains(where: { $0.value >= 0x400 && $0.value < 0x500 }) ? "ru_RU" : "en_US"
            let ns = word as NSString
            let range = NSRange(location: 0, length: ns.length)
            var found: [String] = []
            let miss = checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: lang)
            if miss.location != NSNotFound {
                found += checker.guesses(forWordRange: range, in: word, language: lang) ?? []
            }
            found += checker.completions(forPartialWordRange: range, in: word, language: lang) ?? []
            slots.append("«" + word + "»")
            for f in found where f != word && !slots.contains(f) {
                slots.append(f)
                if slots.count == 3 { break }
            }
        }
        for (i, v) in suggest.arrangedSubviews.enumerated() {
            guard let b = v as? UIButton else { continue }
            b.setTitle(i < slots.count ? slots[i] : "", for: .normal)
            b.setTitleColor(kb.skin.text, for: .normal)
            b.isEnabled = i < slots.count
        }
    }

    @objc private func suggestionTapped(_ sender: UIButton) {
        guard let title = sender.title(for: .normal), !title.isEmpty else { return }
        if status.state == "running" {
            pause()
            return
        }
        let proxy = textDocumentProxy
        if sender.tag == 0 {
            proxy.insertText(" ")
        } else {
            for _ in 0..<suggestWord.count { proxy.deleteBackward() }
            proxy.insertText(title + " ")
        }
        updateAutoShift()
        updateSuggestions()
    }

    // MARK: Manual typing

    private func longPress(_ id: String) {
        switch id {
        case "space": toggleRun()
        case "mode":
            panelVisible.toggle()
            panel.isHidden = !panelVisible
            suggest.isHidden = panelVisible
            refreshPanel()
        case "emoji": advanceToNextInputMode()
        default: break
        }
    }

    private func manualKey(_ spec: KeySpec) {
        let proxy = textDocumentProxy
        var lang = kb.lang, page = kb.page, shift = kb.shift
        var typed = false
        switch spec.id {
        case "shift": shift = shift == 0 ? 1 : (shift == 1 ? 2 : 0)
        case "delete": proxy.deleteBackward(); typed = true
        case "mode": page = page == .letters ? .numbers : .letters
        case "alt": page = page == .numbers ? .symbols : .numbers
        case "emoji": lang = lang == .ru ? .en : .ru
        case "space":
            proxy.insertText(" ")
            page = .letters
            typed = true
        case "return": proxy.insertText("\n"); typed = true
        default:
            proxy.insertText(spec.label)
            if spec.id == "'" { page = .letters }
            typed = true
        }
        if settings.clickSound { UIDevice.current.playInputClick() }
        kb.set(lang: lang, page: page, shift: shift)
        if typed && shift != 2 { updateAutoShift() }
        updateSuggestions()
    }

    private func updateAutoShift() {
        guard kb.page == .letters, kb.shift != 2 else { return }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        let auto = before.isEmpty || before.hasSuffix("\n")
            || (before.hasSuffix(" ") && (trimmed.isEmpty || ".!?".contains(trimmed.last!)))
        kb.set(lang: kb.lang, page: kb.page, shift: auto ? 1 : 0)
    }
}
