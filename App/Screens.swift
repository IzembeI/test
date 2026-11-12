import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

@main
struct AutoTyperApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var m: AppModel
    @State private var tab = 0
    @Namespace private var ns

    private let tabs: [(icon: String, name: String)] = [
        ("text.cursor", "Текст"), ("speedometer", "Скорость"), ("keyboard", "Печать"),
        ("paintpalette", "Стиль"), ("questionmark.circle", "Помощь")
    ]

    var body: some View {
        ZStack {
            BackgroundView()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    header
                    Group {
                        switch tab {
                        case 0: TextTab()
                        case 1: SpeedTab()
                        case 2: TypingTab()
                        case 3: StyleTab()
                        default: HelpTab()
                        }
                    }
                    .id(tab)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 120)
            }
            .scrollDismissesKeyboard(.interactively)
            VStack {
                Spacer()
                tabBar
            }
            .ignoresSafeArea(.keyboard)
        }
        .foregroundColor(m.textColor)
        .tint(m.accent)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("AutoTyper")
                .font(m.font(34, bold: true))
                .shimmer()
            Spacer()
            Text(tabs[tab].name)
                .font(m.font(15))
                .opacity(0.6)
        }
        .padding(.top, 8)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(tabs.indices, id: \.self) { i in
                VStack(spacing: 3) {
                    Image(systemName: tabs[i].icon)
                        .font(.system(size: 19, weight: .semibold))
                        .scaleEffect(tab == i ? 1.15 : 1)
                    Text(tabs[i].name).font(m.font(10))
                }
                .foregroundColor(tab == i ? (m.accent.isLight ? .black : .white) : m.textColor.opacity(0.75))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    ZStack {
                        if tab == i {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(m.accent)
                                .matchedGeometryEffect(id: "tab", in: ns)
                        }
                    }
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { tab = i }
                }
            }
        }
        .glass(radius: 26, padding: 6)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }
}

// MARK: - Text & launch

struct TextTab: View {
    @EnvironmentObject var m: AppModel

    private var progress: Double {
        m.status.total > 0 ? min(1, Double(m.status.pos) / Double(m.status.total)) : 0
    }

    private var stateName: String {
        if m.waitingForKeyboard { return "Запуск" }
        switch m.status.state {
        case "armed": return "Отсчёт"
        case "running": return "Печатает"
        case "paused": return "Пауза"
        case "done": return "Готово"
        default: return "Ожидание"
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            statusCard.appear(0)
            editorCard.appear(1)
            launchCard.appear(2)
        }
        .onChange(of: m.text) { _ in
            if m.status.pos > 0 || m.status.state == "paused" || m.status.state == "running" { m.send("stop") }
        }
    }

    private var statusCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(m.accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: progress)
                Text("\(Int(progress * 100))%").font(m.font(15, bold: true)).monospacedDigit()
            }
            .frame(width: 68, height: 68)
            VStack(alignment: .leading, spacing: 4) {
                Text(stateName).font(m.font(20, bold: true))
                if m.waitingForKeyboard, let cmd = m.lastCommand {
                    TimelineView(.periodic(from: .now, by: 0.1)) { tl in
                        let left = cmd.fireAt - tl.date.timeIntervalSince1970
                        Text(left > 0
                             ? String(format: "Старт через %.1f с — откройте поле ввода", left)
                             : "Жду, когда откроется клавиатура…")
                            .font(m.font(13))
                            .opacity(0.75)
                    }
                } else {
                    Text("\(m.status.pos) из \(max(m.status.total, m.text.count)) символов")
                        .font(m.font(13))
                        .opacity(0.75)
                        .monospacedDigit()
                }
            }
            Spacer()
        }
        .glass()
    }

    private var editorCard: some View {
        VStack(spacing: 12) {
            SectionTitle(icon: "doc.text", title: "Текст")
            ZStack(alignment: .topLeading) {
                if m.text.isEmpty {
                    Text("Вставьте или введите текст, который нужно напечатать")
                        .font(m.font(15))
                        .opacity(0.4)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                }
                TextEditor(text: $m.text)
                    .font(m.font(15))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 170, maxHeight: 260)
            }
            HStack {
                let words = m.text.split(whereSeparator: { $0.isWhitespace }).count
                Text("\(m.text.count) симв. · \(words) слов · ≈ \(timeString(m.estimatedSeconds))")
                    .font(m.font(12))
                    .opacity(0.65)
                    .monospacedDigit()
                Spacer()
            }
            HStack(spacing: 10) {
                Button {
                    if let s = UIPasteboard.general.string { m.text = s }
                } label: { Label("Вставить", systemImage: "doc.on.clipboard") }
                    .buttonStyle(GlassButton())
                Button {
                    m.text = ""
                } label: { Label("Очистить", systemImage: "trash") }
                    .buttonStyle(GlassButton())
            }
        }
        .glass()
    }

    private var launchCard: some View {
        VStack(spacing: 14) {
            SectionTitle(icon: "timer", title: "Запуск")
            SliderRow(title: "Таймер до старта", value: $m.settings.startDelay, range: 0...30, unit: "с")
            let state = m.status.state
            if m.waitingForKeyboard {
                Button {
                    m.send(m.lastCommand?.action == "resume" ? "pause" : "stop")
                } label: { Label("Отменить запуск", systemImage: "xmark") }
                    .buttonStyle(GlassButton())
            } else if state == "running" || state == "armed" {
                HStack(spacing: 10) {
                    Button { m.send("pause") } label: { Label("Пауза", systemImage: "pause.fill") }
                        .buttonStyle(GlassButton(prominent: true))
                    Button { m.send("stop") } label: { Label("Стоп", systemImage: "stop.fill") }
                        .buttonStyle(GlassButton())
                }
            } else if state == "paused" && m.status.pos > 0 {
                Button { m.send("resume", delay: m.settings.startDelay) } label: {
                    Label("Продолжить с \(m.status.pos)-го символа", systemImage: "play.fill")
                }
                .buttonStyle(GlassButton(prominent: true))
                HStack(spacing: 10) {
                    Button { m.send("start", delay: m.settings.startDelay) } label: {
                        Label("Сначала", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(GlassButton())
                    Button { m.send("stop") } label: { Label("Сбросить", systemImage: "stop.fill") }
                        .buttonStyle(GlassButton())
                }
            } else {
                Button { m.send("start", delay: m.settings.startDelay) } label: {
                    Label("Старт через \(Int(m.settings.startDelay)) с", systemImage: "play.fill")
                }
                .buttonStyle(GlassButton(prominent: true))
                .disabled(m.text.isEmpty)
                .opacity(m.text.isEmpty ? 0.5 : 1)
            }
            Text(m.store.isShared
                 ? "Нажмите старт, перейдите в нужное приложение и коснитесь поля ввода — печать начнётся по таймеру."
                 : "Общий контейнер недоступен при этой подписи. Скопируйте текст и вставьте его кнопкой буфера на панели клавиатуры (долгое нажатие «123»).")
                .font(m.font(12))
                .opacity(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .glass()
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: m.status.state)
    }

    private func timeString(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 60 ? "\(t / 60) мин \(t % 60) с" : "\(t) с"
    }
}

// MARK: - Speed

struct SpeedTab: View {
    @EnvironmentObject var m: AppModel
    @StateObject private var demo = DemoRunner()

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 14) {
                SectionTitle(icon: "speedometer", title: "Скорость")
                Segments(items: ["Ровный", "Плавающий"], selection: $m.settings.wpmMode)
                if m.settings.wpmMode == 0 {
                    SliderRow(title: "Скорость", value: $m.settings.wpm, range: 20...300, unit: "впм")
                } else {
                    SliderRow(title: "От", value: $m.settings.wpmMin, range: 20...300, unit: "впм")
                    SliderRow(title: "До", value: $m.settings.wpmMax, range: 20...300, unit: "впм")
                    Text("Темп плавно гуляет между значениями: то разгоняется, то сбавляет.")
                        .font(m.font(12)).opacity(0.6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .glass()
            .appear(0)
            .onChange(of: m.settings.wpmMin) { v in if v > m.settings.wpmMax { m.settings.wpmMax = v } }
            .onChange(of: m.settings.wpmMax) { v in if v < m.settings.wpmMin { m.settings.wpmMin = v } }

            VStack(spacing: 14) {
                SectionTitle(icon: "waveform.path", title: "Ритм")
                ToggleRow(title: "Микропаузы",
                          subtitle: "После слов, знаков препинания и редкие заминки",
                          isOn: $m.settings.micropauses)
                if m.settings.micropauses {
                    SliderRow(title: "Сила пауз", value: $m.settings.pauseStrength, range: 0.2...2, step: 0.1, decimals: 1)
                }
                ToggleRow(title: "Учитывать удобство клавиш",
                          subtitle: "Удобные слова — быстрее, неудобные сочетания — медленнее",
                          isOn: $m.settings.ergonomics)
            }
            .glass()
            .appear(1)

            VStack(spacing: 12) {
                SectionTitle(icon: "play.rectangle", title: "Проба")
                Text(demo.output.isEmpty ? "Здесь видно, как будет выглядеть печать." : demo.output)
                    .font(m.font(15))
                    .opacity(demo.output.isEmpty ? 0.5 : 1)
                    .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
                HStack {
                    Text(demo.wpm > 0 ? String(format: "%.0f впм", demo.wpm) : "— впм")
                        .font(m.font(14, bold: true))
                        .foregroundColor(m.accent)
                        .monospacedDigit()
                    Spacer()
                }
                Button {
                    if demo.running {
                        demo.stop()
                    } else {
                        let sample = "Привет! Это проверка печати: длинные удобные слова набираются быстрее, а неудобные чуть медленнее."
                        demo.start(text: m.text.isEmpty ? sample : String(m.text.prefix(400)), settings: m.settings)
                    }
                } label: {
                    Label(demo.running ? "Остановить" : "Показать", systemImage: demo.running ? "stop.fill" : "play.fill")
                }
                .buttonStyle(GlassButton(prominent: !demo.running))
            }
            .glass()
            .appear(2)
        }
        .onDisappear { demo.stop() }
    }
}

// MARK: - Typos & keyboard

struct TypingTab: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 14) {
                SectionTitle(icon: "character.cursor.ibeam", title: "Опечатки")
                ToggleRow(title: "Имитация ошибок",
                          subtitle: "Ошибается, замечает, стирает и печатает заново",
                          isOn: $m.settings.errorsEnabled)
                if m.settings.errorsEnabled {
                    SliderRow(title: "Доля ошибок", value: $m.settings.errorRate, range: 0...15, step: 0.5, unit: "%", decimals: 1)
                    Text("Соседняя клавиша, перепутанные буквы, двойное нажатие, пропуск. Иногда замечает сразу, иногда через пару букв.")
                        .font(m.font(12)).opacity(0.6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .glass()
            .appear(0)

            VStack(spacing: 14) {
                SectionTitle(icon: "keyboard", title: "Клавиатура")
                Segments(items: ["iOS", "Тёмная", "Светлая", "Material"], selection: $m.settings.skin)
                ToggleRow(title: "Показывать нажатия",
                          subtitle: "Клавиши подсвечиваются, как от пальца",
                          isOn: $m.settings.showTaps)
                ToggleRow(title: "Пауза при касании",
                          subtitle: "Любое касание клавиатуры ставит печать на паузу",
                          isOn: $m.settings.pauseOnTouch)
                ToggleRow(title: "Звук клавиш", isOn: $m.settings.clickSound)
                ToggleRow(title: "Вибрация", subtitle: "Нужен «Полный доступ»", isOn: $m.settings.haptics)
            }
            .glass()
            .appear(1)

            VStack(spacing: 14) {
                SectionTitle(icon: "return", title: "Перенос строки")
                Segments(items: ["Ввод", "Пробел", "Пропуск"], selection: $m.settings.newlineMode)
                Text("В мессенджерах «Ввод» может отправить сообщение — тогда выберите пробел.")
                    .font(m.font(12)).opacity(0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .glass()
            .appear(2)
        }
    }
}

// MARK: - Style

struct StyleTab: View {
    @EnvironmentObject var m: AppModel
    @State private var photo: PhotosPickerItem?
    @State private var importing = false

    private func colorBinding(_ get: @escaping () -> String, _ set: @escaping (String) -> Void) -> Binding<Color> {
        Binding(get: { Color(hex: get()) }, set: { set($0.hex); m.theme.preset = "custom" })
    }

    private func bgBinding(_ i: Int) -> Binding<Color> {
        colorBinding({ i < m.theme.bg.count ? m.theme.bg[i] : "000000" },
                     { v in if i < m.theme.bg.count { m.theme.bg[i] = v } })
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 14) {
                SectionTitle(icon: "sparkles", title: "Темы")
                HStack(spacing: 10) {
                    ForEach(Theme.presets, id: \.id) { p in
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(LinearGradient(colors: p.theme.bg.map { Color(hex: $0) },
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(height: 62)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(m.theme.preset == p.id ? m.accent : .white.opacity(0.25),
                                                      lineWidth: m.theme.preset == p.id ? 2.5 : 1)
                                )
                                .scaleEffect(m.theme.preset == p.id ? 1.05 : 1)
                            Text(p.name).font(m.font(12, bold: m.theme.preset == p.id))
                        }
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.5)) { m.apply(preset: p.id) }
                        }
                    }
                }
            }
            .glass()
            .appear(0)

            VStack(spacing: 12) {
                SectionTitle(icon: "paintpalette", title: "Палитра")
                ColorPicker("Акцент", selection: colorBinding({ m.theme.accent }, { m.theme.accent = $0 }), supportsOpacity: false)
                ColorPicker("Текст", selection: colorBinding({ m.theme.text }, { m.theme.text = $0 }), supportsOpacity: false)
                ColorPicker("Фон — основа", selection: bgBinding(0), supportsOpacity: false)
                ColorPicker("Фон — перелив 1", selection: bgBinding(1), supportsOpacity: false)
                ColorPicker("Фон — перелив 2", selection: bgBinding(2), supportsOpacity: false)
                ToggleRow(title: "Анимация фона", isOn: $m.theme.animated)
                if m.theme.animated {
                    SliderRow(title: "Скорость анимации", value: $m.theme.speed, range: 0.2...3, step: 0.1, decimals: 1)
                }
            }
            .font(m.font(15))
            .glass()
            .appear(1)

            VStack(spacing: 12) {
                SectionTitle(icon: "photo", title: "Свой фон")
                HStack(spacing: 10) {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Выбрать фото", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(GlassButton(prominent: true))
                    if m.bgImage != nil {
                        Button { m.setBackground(nil) } label: { Label("Убрать", systemImage: "xmark") }
                            .buttonStyle(GlassButton())
                    }
                }
                if m.bgImage != nil {
                    ToggleRow(title: "Показывать фото", isOn: $m.theme.useImage)
                    SliderRow(title: "Размытие", value: $m.theme.blur, range: 0...40)
                    SliderRow(title: "Затемнение", value: $m.theme.dim, range: 0...0.8, step: 0.05, decimals: 2)
                }
            }
            .glass()
            .appear(2)
            .onChange(of: photo) { item in
                guard let item = item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        let small = StyleTab.downscale(img, max: 1600)
                        await MainActor.run { m.setBackground(small) }
                    }
                }
            }

            VStack(spacing: 12) {
                SectionTitle(icon: "textformat", title: "Шрифты")
                fontMenu("Основной (Samsung)", selection: $m.theme.fontRegular)
                fontMenu("Жирный (Samsung Bold)", selection: $m.theme.fontBold)
                ForEach(m.fonts) { f in
                    HStack {
                        Text(f.name).font(.custom(f.name, size: 15))
                        Spacer()
                        Button { m.deleteFont(f) } label: { Image(systemName: "trash") }
                    }
                }
                Button { importing = true } label: { Label("Добавить шрифт (.ttf / .otf)", systemImage: "plus") }
                    .buttonStyle(GlassButton())
                Text("Файлы Samsung Sharp Sans / SamsungOne подхватятся автоматически как основной и жирный.")
                    .font(m.font(12)).opacity(0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .glass()
            .appear(3)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.font, .data], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { m.importFonts(urls) }
            }
        }
    }

    private func fontMenu(_ title: String, selection: Binding<String>) -> some View {
        HStack {
            Text(title).font(m.font(15))
            Spacer()
            Menu {
                Button("Системный") { selection.wrappedValue = "" }
                ForEach(m.fonts) { f in
                    Button(f.name) { selection.wrappedValue = f.name }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selection.wrappedValue.isEmpty ? "Системный" : selection.wrappedValue)
                        .font(m.font(14, bold: true))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11))
                }
                .foregroundColor(m.accent)
            }
        }
    }

    static func downscale(_ img: UIImage, max side: CGFloat) -> UIImage {
        let m = Swift.max(img.size.width, img.size.height)
        guard m > side else { return img }
        let k = side / m
        let size = CGSize(width: img.size.width * k, height: img.size.height * k)
        return UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

// MARK: - Help

struct HelpTab: View {
    @EnvironmentObject var m: AppModel
    @State private var test = ""

    private func row(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(n)
                .font(m.font(14, bold: true))
                .foregroundColor(m.accent.isLight ? .black : .white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(m.accent))
            Text(text).font(m.font(14)).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 12) {
                SectionTitle(icon: "gearshape", title: "Установка клавиатуры")
                row("1", "Настройки → Основные → Клавиатура → Клавиатуры → Новые клавиатуры → AutoTyper.")
                row("2", "Откройте её в списке и включите «Полный доступ» — нужен для буфера обмена и вибрации.")
                row("3", "В любом поле ввода удерживайте 🌐 и выберите клавиатуру AutoTyper.")
                Button {
                    if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                } label: { Label("Открыть настройки", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(GlassButton(prominent: true))
                HStack(spacing: 8) {
                    Circle().fill(m.store.isShared ? Color.green : Color.orange).frame(width: 9, height: 9)
                    Text(m.store.isShared ? "Связь приложения и клавиатуры работает" : "Связь недоступна — текст передаётся через буфер")
                        .font(m.font(12)).opacity(0.75)
                    Spacer()
                }
            }
            .glass()
            .appear(0)

            VStack(spacing: 12) {
                SectionTitle(icon: "hand.tap", title: "Скрытое управление")
                row("•", "Удерживать пробел — старт, пауза или продолжение с места остановки.")
                row("•", "Любое касание клавиатуры во время печати — мгновенная пауза.")
                row("•", "Удерживать «123» — показать или скрыть панель: пауза, полный стоп, вставка из буфера, скорость.")
                row("•", "Удерживать 🌐 — переключиться на другую клавиатуру.")
            }
            .glass()
            .appear(1)

            VStack(spacing: 12) {
                SectionTitle(icon: "pencil.line", title: "Проверка")
                TextField("Коснитесь и выберите клавиатуру AutoTyper", text: $test, axis: .vertical)
                    .font(m.font(15))
                    .lineLimit(3...8)
                    .padding(12)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .glass()
            .appear(2)
        }
    }
}
