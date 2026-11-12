import SwiftUI

extension Color {
    var isLight: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.299 * r + 0.587 * g + 0.114 * b > 0.6
    }
}

// MARK: - Animated background

struct BackgroundView: View {
    @EnvironmentObject var m: AppModel

    private func color(_ i: Int) -> Color {
        let bg = m.theme.bg
        return Color(hex: bg.isEmpty ? "000000" : bg[i % bg.count])
    }

    var body: some View {
        ZStack {
            color(0)
            if m.theme.useImage, let img = m.bgImage {
                GeometryReader { g in
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: g.size.width, height: g.size.height)
                        .clipped()
                        .blur(radius: m.theme.blur, opaque: true)
                }
                Color.black.opacity(m.theme.dim)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !m.theme.animated)) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate * m.theme.speed
                    ZStack {
                        Canvas { ctx, size in
                            ctx.addFilter(.blur(radius: 70))
                            for k in 0..<6 {
                                let f = Double(k)
                                let x = size.width * (0.5 + 0.42 * sin(t * (0.11 + f * 0.023) + f * 1.7))
                                let y = size.height * (0.5 + 0.42 * cos(t * (0.09 + f * 0.031) + f * 2.3))
                                let r = size.width * (0.32 + 0.08 * sin(t * 0.2 + f))
                                let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                                ctx.fill(Path(ellipseIn: rect), with: .color(color(1 + k % 2).opacity(0.5)))
                            }
                        }
                        AngularGradient(colors: [color(1), color(0), m.accent, color(2), color(1)], center: .center,
                                        angle: .degrees(t * 14))
                            .opacity(0.16)
                            .blur(radius: 50)
                            .blendMode(.screen)
                    }
                }
                Color.black.opacity(0.28)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Glass

struct Glass: ViewModifier {
    var radius: CGFloat = 24
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(padding)
            .background(.ultraThinMaterial, in: shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.06), .white.opacity(0.22)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }
}

extension View {
    func glass(radius: CGFloat = 24, padding: CGFloat = 16) -> some View {
        modifier(Glass(radius: radius, padding: padding))
    }

    func appear(_ index: Int) -> some View { modifier(Appear(index: index)) }
    func shimmer() -> some View { modifier(Shimmer()) }
}

struct Appear: ViewModifier {
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 22)
            .scaleEffect(shown ? 1 : 0.97)
            .onAppear {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.8).delay(Double(index) * 0.07)) {
                    shown = true
                }
            }
    }
}

struct Shimmer: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
                let p = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.6) / 2.6
                LinearGradient(colors: [.clear, .white.opacity(0.95), .clear],
                               startPoint: UnitPoint(x: -0.6 + p * 2.2, y: 0),
                               endPoint: UnitPoint(x: -0.2 + p * 2.2, y: 1))
                    .blendMode(.overlay)
            }
            .mask(content)
            .allowsHitTesting(false)
        )
    }
}

// MARK: - Controls

struct GlassButton: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, prominent: prominent)
    }
}

struct GlassButtonBody: View {
    @EnvironmentObject var m: AppModel
    let configuration: ButtonStyleConfiguration
    let prominent: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        configuration.label
            .font(m.font(16, bold: true))
            .foregroundColor(prominent ? (m.accent.isLight ? .black : .white) : m.textColor)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .background(
                ZStack {
                    if prominent {
                        shape.fill(LinearGradient(colors: [m.accent, m.accent.opacity(0.72)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing))
                    } else {
                        shape.fill(.ultraThinMaterial)
                    }
                    shape.strokeBorder(.white.opacity(prominent ? 0.55 : 0.25), lineWidth: 1)
                }
            )
            .shadow(color: prominent ? m.accent.opacity(0.35) : .clear, radius: 14, y: 4)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct SectionTitle: View {
    @EnvironmentObject var m: AppModel
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundColor(m.accent)
            Text(title).font(m.font(18, bold: true))
            Spacer()
        }
    }
}

struct SliderRow: View {
    @EnvironmentObject var m: AppModel
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit = ""
    var decimals = 0

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title).font(m.font(15))
                Spacer()
                Text(String(format: "%.\(decimals)f", value) + (unit.isEmpty ? "" : " " + unit))
                    .font(m.font(15, bold: true))
                    .foregroundColor(m.accent)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

struct ToggleRow: View {
    @EnvironmentObject var m: AppModel
    let title: String
    var subtitle = ""
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn.animation(.spring(response: 0.35, dampingFraction: 0.8))) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(m.font(15))
                if !subtitle.isEmpty {
                    Text(subtitle).font(m.font(12)).opacity(0.6)
                }
            }
        }
    }
}

struct Segments: View {
    @EnvironmentObject var m: AppModel
    let items: [String]
    @Binding var selection: Int
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items.indices, id: \.self) { i in
                Text(items[i])
                    .font(m.font(14, bold: selection == i))
                    .foregroundColor(selection == i ? (m.accent.isLight ? .black : .white) : m.textColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        ZStack {
                            if selection == i {
                                Capsule().fill(m.accent).matchedGeometryEffect(id: "seg", in: ns)
                            }
                        }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { selection = i }
                    }
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
    }
}
