import SwiftUI
import NetworkExtension

enum Theme {
    static let accents: [(String, Color)] = [
        ("Аврора", Color(red: 0.31, green: 0.86, blue: 0.67)),
        ("Океан", Color(red: 0.25, green: 0.56, blue: 1.0)),
        ("Фиалка", Color(red: 0.58, green: 0.42, blue: 1.0)),
        ("Закат", Color(red: 1.0, green: 0.48, blue: 0.33)),
        ("Роза", Color(red: 1.0, green: 0.36, blue: 0.6)),
        ("Янтарь", Color(red: 1.0, green: 0.74, blue: 0.2)),
    ]

    static func accent(_ i: Int) -> Color { accents[max(0, min(i, accents.count - 1))].1 }

    static func latencyColor(_ ms: Int?) -> Color {
        guard let ms else { return .secondary }
        if ms < 0 { return .red }
        if ms < 300 { return .green }
        if ms < 800 { return .orange }
        return .red
    }

    static func latencyText(_ ms: Int?) -> String {
        guard let ms else { return "—" }
        return ms < 0 ? "нет" : "\(ms) мс"
    }
}

extension NEVPNStatus {
    var title: String {
        switch self {
        case .connected: return "Защищено"
        case .connecting: return "Подключение…"
        case .disconnecting: return "Отключение…"
        case .reasserting: return "Переподключение…"
        case .disconnected: return "Не подключено"
        case .invalid: return "Не настроено"
        @unknown default: return "—"
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct ProtoBadge: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
            .foregroundStyle(Color.accentColor)
    }
}

/// Simple area chart of the last minute of throughput.
struct Sparkline: View {
    var values: [Double]
    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.max() ?? 1, 1)
            let step = geo.size.width / CGFloat(max(values.count - 1, 1))
            let points = values.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) * step, y: geo.size.height * (1 - CGFloat(v / maxV)))
            }
            ZStack {
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: CGPoint(x: first.x, y: geo.size.height))
                    points.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: first)
                    points.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
