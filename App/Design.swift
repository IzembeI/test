import SwiftUI

extension Color {
    var isLight: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.299 * r + 0.587 * g + 0.114 * b > 0.6
    }
}

// MARK: - Background

struct BackgroundView: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        ZStack {
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
                m.theme.gradient
                // Slow rotating sheen that makes the gradient shimmer.
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !m.theme.animated)) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate * m.theme.speed
                    let mid = Color(hex: m.theme.bg.count > 1 ? m.theme.bg[1] : "808080")
                    AngularGradient(colors: [.clear, mid, .white.opacity(0.5), .clear, m.accent.opacity(0.5), .clear, .clear],
                                    center: .center, angle: .degrees(t * 14))
                        .scaleEffect(1.8)
                        .blur(radius: 70)
                        .opacity(m.isLight ? 0.45 : 0.36)
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Glass card

struct Glass: ViewModifier {
    @EnvironmentObject var m: AppModel
    var radius: CGFloat = 20
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(padding)
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(m.stroke, lineWidth: 1))
    }
}

extension View {
    func glass(radius: CGFloat = 20, padding: CGFloat = 14) -> some View {
        modifier(Glass(radius: radius, padding: padding))
    }

    func appear(_ index: Int) -> some View { modifier(Appear(index: index)) }
}

struct Appear: ViewModifier {
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85).delay(Double(index) * 0.05)) {
                    shown = true
                }
            }
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
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        configuration.label
            .font(m.font(15, bold: true))
            .foregroundColor(prominent ? m.onAccent : m.textColor)
            .padding(.vertical, 12)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(shape.fill(prominent ? m.accent : m.field))
            .overlay(shape.strokeBorder(prominent ? Color.clear : m.stroke, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

struct SectionLabel: View {
    @EnvironmentObject var m: AppModel
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(m.font(11.5, bold: true))
            .kerning(0.7)
            .opacity(0.56)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RowLine: View {
    @EnvironmentObject var m: AppModel
    var body: some View { Rectangle().fill(m.stroke).frame(height: 1) }
}

struct RowTitle: View {
    @EnvironmentObject var m: AppModel
    let title: String
    var subtitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(m.font(15))
            if !subtitle.isEmpty {
                Text(subtitle).font(m.font(12)).opacity(0.56)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A value that is typed in by hand: any number is accepted.
struct NumberRow: View {
    @EnvironmentObject var m: AppModel
    let title: String
    var subtitle = ""
    @Binding var value: Double
    var unit = ""
    var decimals = 0

    @State private var input = ""
    @FocusState private var focused: Bool

    private var formatted: String { String(format: "%.\(decimals)f", value) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(spacing: 12) {
            RowTitle(title: title, subtitle: subtitle)
            HStack(spacing: 3) {
                TextField("0", text: $input)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focused)
                    .frame(width: 58)
                    .font(m.font(15, bold: true))
                    .monospacedDigit()
                if !unit.isEmpty {
                    Text(unit).font(m.font(14)).opacity(0.56)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 9)
            .background(m.field, in: shape)
            .overlay(shape.strokeBorder(focused ? m.accent : m.stroke, lineWidth: 1))
            .onTapGesture { focused = true }
        }
        .onAppear { input = formatted }
        .onChange(of: value) { _ in if !focused { input = formatted } }
        .onChange(of: focused) { f in if !f { input = formatted } }
        .onChange(of: input) { t in
            guard focused, let v = Double(t.replacingOccurrences(of: ",", with: ".")), v >= 0 else { return }
            value = v
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
                Text(String(format: "%.\(decimals)f", value) + unit)
                    .font(m.font(15, bold: true))
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

struct SwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SwitchBody(configuration: configuration)
    }
}

struct SwitchBody: View {
    @EnvironmentObject var m: AppModel
    let configuration: ToggleStyleConfiguration

    var body: some View {
        HStack(spacing: 12) {
            configuration.label
            Capsule()
                .fill(configuration.isOn ? m.accent : m.field)
                .overlay(Capsule().strokeBorder(configuration.isOn ? Color.clear : m.stroke, lineWidth: 1))
                .frame(width: 46, height: 28)
                .overlay(
                    Circle()
                        .fill(configuration.isOn ? m.onAccent : m.textColor.opacity(0.56))
                        .padding(2)
                        .offset(x: configuration.isOn ? 9 : -9)
                )
                .onTapGesture {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { configuration.isOn.toggle() }
                }
        }
    }
}

struct ToggleRow: View {
    let title: String
    var subtitle = ""
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) { RowTitle(title: title, subtitle: subtitle) }
            .toggleStyle(SwitchStyle())
    }
}

struct Segments: View {
    @EnvironmentObject var m: AppModel
    let items: [String]
    @Binding var selection: Int
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                Text(items[i])
                    .font(m.font(13.5, bold: selection == i))
                    .foregroundColor(selection == i ? m.onAccent : m.textColor.opacity(0.56))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        ZStack {
                            if selection == i {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(m.accent)
                                    .matchedGeometryEffect(id: "seg", in: ns)
                            }
                        }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = i }
                    }
            }
        }
        .padding(3)
        .background(m.field, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}
