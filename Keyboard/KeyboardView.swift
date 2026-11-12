import UIKit

struct KeySpec {
    let id: String
    let label: String
    let icon: String?
    let x: CGFloat       // fraction of the keyboard width
    let w: CGFloat
    let row: Int
    let special: Bool
}

struct Skin {
    var key: UIColor
    var special: UIColor
    var text: UIColor
    var pressed: UIColor
    var popup: UIColor
    var shadow: UIColor
    var backdrop: UIColor
    var radius: CGFloat

    static func make(_ id: Int, systemDark: Bool) -> Skin {
        let dark = id == 1 || (id != 2 && systemDark)
        let touchable = UIColor(white: 0.5, alpha: 0.01)   // keeps gaps between keys tappable
        if id == 3 {
            return dark
                ? Skin(key: UIColor(white: 0.24, alpha: 1), special: UIColor(white: 0.18, alpha: 1), text: .white,
                       pressed: UIColor(white: 0.36, alpha: 1), popup: UIColor(white: 0.36, alpha: 1),
                       shadow: .clear, backdrop: UIColor(white: 0.12, alpha: 1), radius: 7)
                : Skin(key: .white, special: UIColor(red: 0.84, green: 0.86, blue: 0.88, alpha: 1), text: .black,
                       pressed: UIColor(white: 0.82, alpha: 1), popup: .white,
                       shadow: .clear, backdrop: UIColor(red: 0.93, green: 0.94, blue: 0.95, alpha: 1), radius: 7)
        }
        return dark
            ? Skin(key: UIColor(white: 0.42, alpha: 1), special: UIColor(white: 0.27, alpha: 1), text: .white,
                   pressed: UIColor(white: 0.27, alpha: 1), popup: UIColor(white: 0.42, alpha: 1),
                   shadow: UIColor(white: 0, alpha: 0.5), backdrop: touchable, radius: 5)
            : Skin(key: .white, special: UIColor(red: 0.67, green: 0.70, blue: 0.74, alpha: 1), text: .black,
                   pressed: UIColor(red: 0.67, green: 0.70, blue: 0.74, alpha: 1), popup: .white,
                   shadow: UIColor(red: 0.53, green: 0.54, blue: 0.56, alpha: 1), backdrop: touchable, radius: 5)
    }
}

private final class KeyCap: UIView {
    let spec: KeySpec
    private let label = UILabel()
    private let image = UIImageView()
    private var skin: Skin

    init(spec: KeySpec, skin: Skin) {
        self.spec = spec
        self.skin = skin
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.cornerRadius = skin.radius
        layer.shadowColor = skin.shadow.cgColor
        layer.shadowOpacity = 1
        layer.shadowRadius = 0
        layer.shadowOffset = CGSize(width: 0, height: 1)
        label.textAlignment = .center
        label.textColor = skin.text
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        image.contentMode = .center
        image.tintColor = skin.text
        addSubview(label)
        addSubview(image)
        if let icon = spec.icon {
            let cfg = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)
            image.image = UIImage(systemName: icon, withConfiguration: cfg)
        } else {
            label.text = spec.label
            if spec.special || spec.id == "space" {
                label.font = .systemFont(ofSize: 16)
            } else {
                let lower = spec.label.lowercased() == spec.label && spec.label.uppercased() != spec.label
                label.font = .systemFont(ofSize: lower ? 24 : 22.5, weight: .light)
            }
        }
        setPressed(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 2, dy: 0)
        if spec.icon == nil && !spec.special && spec.id != "space" {
            label.frame.origin.y -= 1.5
        }
        image.frame = bounds
    }

    func setPressed(_ on: Bool) {
        if spec.special {
            backgroundColor = on ? skin.key : skin.special
        } else {
            backgroundColor = on ? skin.pressed : skin.key
        }
    }
}

private final class PopupView: UIView {
    private let shape = CAShapeLayer()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(shape)
        shape.shadowColor = UIColor.black.cgColor
        shape.shadowOpacity = 0.25
        shape.shadowRadius = 3
        shape.shadowOffset = CGSize(width: 0, height: 1)
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 38, weight: .light)
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(over key: CGRect, text: String, skin: Skin, in bounds: CGRect) {
        let headW = key.width + 26
        let headH: CGFloat = 54
        var headX = key.midX - headW / 2
        headX = max(2, min(bounds.width - headW - 2, headX))
        let top = key.minY - headH + 4
        frame = CGRect(x: headX, y: top, width: headW, height: key.maxY - top)
        let path = UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: headW, height: headH), cornerRadius: 10)
        let neck = CGRect(x: key.minX - headX, y: headH - 12, width: key.width, height: bounds.height > 0 ? frame.height - headH + 12 : 0)
        path.append(UIBezierPath(roundedRect: neck, cornerRadius: skin.radius))
        shape.path = path.cgPath
        shape.fillColor = skin.popup.cgColor
        label.frame = CGRect(x: 0, y: 0, width: headW, height: headH)
        label.text = text
        label.textColor = skin.text
        isHidden = false
    }
}

final class KeyboardView: UIView {
    private(set) var lang: KBLang = .ru
    private(set) var page: KBPage = .letters
    private(set) var shift = 0
    var skin = Skin.make(0, systemDark: false) { didSet { rebuild() } }
    var topInset: CGFloat = 44 { didSet { setNeedsLayout() } }

    var onKey: ((KeySpec) -> Void)?
    var onLongPress: ((String) -> Void)?
    var onTouchDown: (() -> Bool)?      // return true to swallow the touch

    private var caps: [KeyCap] = []
    private let popup = PopupView()
    private var touches: [UITouch: Int] = [:]
    private var longTimer: Timer?
    private var repeatTimer: Timer?
    private var longFired = false
    private var flashToken = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        addSubview(popup)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(lang: KBLang, page: KBPage, shift: Int) {
        guard lang != self.lang || page != self.page || shift != self.shift else { return }
        self.lang = lang
        self.page = page
        self.shift = shift
        rebuild()
    }

    // MARK: Layout

    private func specs() -> [KeySpec] {
        var out: [KeySpec] = []
        let rows = KeyGeo.rows(lang, page)
        if page == .letters {
            let n = CGFloat(rows[0].count)
            for (r, row) in rows.enumerated() {
                let off = (n - CGFloat(row.count)) / 2
                for (i, c) in row.enumerated() {
                    let s = shift > 0 ? String(c).uppercased() : String(c)
                    out.append(KeySpec(id: String(c), label: s, icon: nil,
                                       x: (off + CGFloat(i)) / n, w: 1 / n, row: r, special: false))
                }
            }
            let side = (n - CGFloat(rows[2].count)) / 2 / n - 0.012
            let icon = shift == 2 ? "capslock.fill" : (shift == 1 ? "shift.fill" : "shift")
            out.append(KeySpec(id: "shift", label: "", icon: icon, x: 0, w: side, row: 2, special: true))
            out.append(KeySpec(id: "delete", label: "", icon: "delete.left", x: 1 - side, w: side, row: 2, special: true))
        } else {
            for r in 0..<2 {
                for (i, c) in rows[r].enumerated() {
                    out.append(KeySpec(id: String(c), label: String(c), icon: nil,
                                       x: CGFloat(i) / 10, w: 0.1, row: r, special: false))
                }
            }
            for (i, c) in rows[2].enumerated() {
                out.append(KeySpec(id: String(c), label: String(c), icon: nil,
                                   x: 0.15 + CGFloat(i) * 0.14, w: 0.14, row: 2, special: false))
            }
            out.append(KeySpec(id: "alt", label: page == .numbers ? "#+=" : "123", icon: nil, x: 0, w: 0.13, row: 2, special: true))
            out.append(KeySpec(id: "delete", label: "", icon: "delete.left", x: 0.87, w: 0.13, row: 2, special: true))
        }
        let abc = lang == .ru ? "АБВ" : "ABC"
        out.append(KeySpec(id: "mode", label: page == .letters ? "123" : abc, icon: nil, x: 0, w: 0.125, row: 3, special: true))
        out.append(KeySpec(id: "globe", label: "", icon: "globe", x: 0.125, w: 0.125, row: 3, special: true))
        out.append(KeySpec(id: "space", label: lang == .ru ? "Пробел" : "space", icon: nil, x: 0.25, w: 0.5, row: 3, special: false))
        out.append(KeySpec(id: "return", label: lang == .ru ? "Ввод" : "return", icon: nil, x: 0.75, w: 0.25, row: 3, special: true))
        return out
    }

    private func rebuild() {
        caps.forEach { $0.removeFromSuperview() }
        touches.removeAll()
        popup.isHidden = true
        backgroundColor = skin.backdrop
        caps = specs().map { KeyCap(spec: $0, skin: skin) }
        caps.forEach { insertSubview($0, belowSubview: popup) }
        setNeedsLayout()
    }

    private func cell(_ s: KeySpec) -> CGRect {
        let rowH = (bounds.height - topInset) / 4
        return CGRect(x: s.x * bounds.width, y: topInset + CGFloat(s.row) * rowH, width: s.w * bounds.width, height: rowH)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rowH = (bounds.height - topInset) / 4
        let dy = min(6, rowH * 0.11)
        for c in caps { c.frame = cell(c.spec).insetBy(dx: 3, dy: dy) }
    }

    private func index(at p: CGPoint) -> Int? {
        if p.y < topInset { return nil }
        var best: Int?
        var bestD = CGFloat.greatestFiniteMagnitude
        for (i, c) in caps.enumerated() {
            let r = cell(c.spec)
            if r.contains(p) { return i }
            let d = hypot(r.midX - p.x, r.midY - p.y)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    private func press(_ i: Int, _ on: Bool) {
        guard i < caps.count else { return }
        let c = caps[i]
        c.setPressed(on)
        if on, !c.spec.special, c.spec.id != "space" {
            popup.show(over: c.frame, text: c.spec.label, skin: skin, in: bounds)
            bringSubviewToFront(popup)
        } else {
            popup.isHidden = true
        }
    }

    // MARK: Automation

    /// Shows a key press exactly like a finger tap would.
    func flash(_ id: String, duration: Double) {
        guard let i = caps.firstIndex(where: { $0.spec.id == id }) else { return }
        flashToken += 1
        let token = flashToken
        let cap = caps[i]
        press(i, true)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak cap] in
            cap?.setPressed(false)
            if let s = self, s.flashToken == token { s.popup.isHidden = true }
        }
    }

    // MARK: Touches

    override func touchesBegan(_ ts: Set<UITouch>, with event: UIEvent?) {
        if onTouchDown?() == true { return }
        for t in ts {
            guard let i = index(at: t.location(in: self)) else { continue }
            touches[t] = i
            press(i, true)
            let id = caps[i].spec.id
            longFired = false
            longTimer?.invalidate()
            repeatTimer?.invalidate()
            if id == "delete" {
                onKey?(caps[i].spec)
                longFired = true
                let spec = caps[i].spec
                longTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                    self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                        self?.onKey?(spec)
                    }
                }
            } else if id == "space" || id == "mode" || id == "globe" {
                longTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                    self?.longFired = true
                    self?.onLongPress?(id)
                }
            }
        }
    }

    override func touchesEnded(_ ts: Set<UITouch>, with event: UIEvent?) {
        finish(ts, fire: true)
    }

    override func touchesCancelled(_ ts: Set<UITouch>, with event: UIEvent?) {
        finish(ts, fire: false)
    }

    private func finish(_ ts: Set<UITouch>, fire: Bool) {
        longTimer?.invalidate()
        repeatTimer?.invalidate()
        for t in ts {
            guard let i = touches.removeValue(forKey: t), i < caps.count else { continue }
            let spec = caps[i].spec
            press(i, false)
            if fire && !longFired { onKey?(spec) }
        }
        longFired = false
    }
}
