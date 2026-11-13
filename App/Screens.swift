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
                .preferredColorScheme(model.isLight ? .light : .dark)
        }
    }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var m: AppModel
    @State private var tab = 0
    @State private var page: String?            // settings sub-page
    @Namespace private var ns
    @State private var keyboardShown = false

    private let tabs: [(icon: String, name: String)] = [
        ("character.cursor.ibeam", "Печать"), ("slider.horizontal.3", "Параметры"), ("gearshape", "Настройки")
    ]

    private var screenID: String { tab == 2 ? "s-\(page ?? "root")" : "t-\(tab)" }

    var body: some View {
        ZStack {
            BackgroundView()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    switch tab {
                    case 0: PrintTab()
                    case 1: ParamsTab()
                    default: SettingsTab(page: $page)
                    }
                }
                .id(screenID)
                .transition(.opacity)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 110)
            }
            .scrollDismissesKeyboard(.interactively)
            VStack {
                Spacer()
                tabBar
            }
            .ignoresSafeArea(.keyboard)
            if keyboardShown {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .font(.system(size: 17, weight: .medium))
                                .frame(width: 48, height: 40)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .glass(radius: 14, padding: 0)
                        .padding(.trailing, 14)
                        .padding(.bottom, 8)
                    }
                }
                .transition(.opacity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) { keyboardShown = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) { keyboardShown = false }
        }
        .foregroundColor(m.textColor)
        .tint(m.accent)
        .animation(.easeInOut(duration: 0.45), value: m.theme)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(tabs.indices, id: \.self) { i in
                VStack(spacing: 3) {
                    Image(systemName: tabs[i].icon).font(.system(size: 18, weight: .medium))
                    Text(tabs[i].name).font(m.font(10.5))
                }
                .foregroundColor(tab == i ? m.onAccent : m.textColor.opacity(0.56))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    ZStack {
                        if tab == i {
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .fill(m.accent)
                                .matchedGeometryEffect(id: "tab", in: ns)
                        }
                    }
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                        tab = i
                        page = nil
                    }
                }
            }
        }
        .glass(radius: 22, padding: 5)
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }
}

struct ScreenTitle: View {
    @EnvironmentObject var m: AppModel
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(m.font(28, bold: true))
                .kerning(-0.5)
            Spacer()
            Text("сборка \(Store.build)").font(m.font(12)).opacity(0.45)
        }
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
    }
}

// MARK: - Print

struct PrintTab: View {
    @EnvironmentObject var m: AppModel
    @State private var importing = false
    @State private var copied = false

    private var total: Int { max(m.status.total, m.text.count) }
    private var progress: Double { total > 0 ? min(1, Double(m.status.pos) / Double(total)) : 0 }

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
        ScreenTitle("Печать")
        statusCard.appear(0)
        editorCard.appear(1)
        launchCard.appear(2)
        libraryCard.appear(3)
            .onChange(of: m.text) { _ in
                if m.status.pos > 0 || m.status.state == "paused" || m.status.state == "running" { m.send("stop") }
            }
    }

    private var statusCard: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(stateName).font(m.font(22, bold: true))
                Spacer()
                if m.waitingForKeyboard, let cmd = m.lastCommand {
                    TimelineView(.periodic(from: .now, by: 0.1)) { tl in
                        let left = cmd.fireAt - tl.date.timeIntervalSince1970
                        Text(left > 0 ? String(format: "через %.1f с", left) : "жду клавиатуру")
                            .font(m.font(13)).opacity(0.56).monospacedDigit()
                    }
                } else {
                    Text("\(m.status.pos) / \(total) · \(Int(progress * 100))%")
                        .font(m.font(13)).opacity(0.56).monospacedDigit()
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(m.field)
                    Capsule().fill(m.accent).frame(width: g.size.width * progress)
                }
            }
            .frame(height: 5)
            .animation(.easeOut(duration: 0.4), value: progress)
        }
        .glass()
    }

    private var editorCard: some View {
        VStack(spacing: 12) {
            SectionLabel("Текст")
            ZStack(alignment: .topLeading) {
                if m.text.isEmpty {
                    Text("Вставьте или введите текст, который нужно напечатать")
                        .font(m.font(15)).opacity(0.4)
                        .padding(.top, 8).padding(.leading, 5)
                }
                TextEditor(text: $m.text)
                    .font(m.font(15))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 150, maxHeight: 260)
            }
            let words = m.text.split(whereSeparator: { $0.isWhitespace }).count
            Text("\(m.text.count) символов · \(words) слов · около \(timeString(m.estimatedSeconds))")
                .font(m.font(12.5)).opacity(0.56).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button {
                    if let s = UIPasteboard.general.string { m.text = s }
                } label: { Label("Вставить", systemImage: "doc.on.clipboard") }
                    .buttonStyle(GlassButton())
                Button {
                    UIPasteboard.general.string = m.text
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: { Label(copied ? "Скопировано" : "Копировать", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(GlassButton())
                    .disabled(m.text.isEmpty)
            }
            .lineLimit(1)
            HStack(spacing: 8) {
                Button { importing = true } label: { Label("Файл", systemImage: "doc") }
                    .buttonStyle(GlassButton())
                Button { m.text = "" } label: { Label("Очистить", systemImage: "trash") }
                    .buttonStyle(GlassButton())
            }
            .lineLimit(1)
        }
        .glass()
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text]) { result in
            if case .success(let url) = result { m.importText(url) }
        }
    }

    private var libraryCard: some View {
        VStack(spacing: 10) {
            SectionLabel("Библиотека")
            if m.library.isEmpty {
                Text("Сохранённые тексты появятся здесь.")
                    .font(m.font(12.5)).opacity(0.56)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(m.library) { item in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(m.font(15)).lineLimit(1)
                        Text("\(item.text.count) символов").font(m.font(12)).opacity(0.56)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { m.text = item.text }
                    Button {
                        withAnimation { m.library.removeAll { $0.id == item.id } }
                    } label: { Image(systemName: "trash").opacity(0.56) }
                        .buttonStyle(.plain)
                }
                RowLine()
            }
            Button { withAnimation { m.saveCurrentText() } } label: {
                Label("Сохранить текущий текст", systemImage: "plus")
            }
            .buttonStyle(GlassButton())
            .disabled(m.text.isEmpty)
            .opacity(m.text.isEmpty ? 0.5 : 1)
        }
        .glass()
    }

    private var launchCard: some View {
        VStack(spacing: 12) {
            SectionLabel("Запуск")
            NumberRow(title: "Таймер до старта", subtitle: "Успейте открыть нужное поле ввода",
                      value: $m.settings.startDelay, unit: "с")
            let state = m.status.state
            if m.waitingForKeyboard {
                Button {
                    m.send(m.lastCommand?.action == "resume" ? "pause" : "stop")
                } label: { Label("Отменить запуск", systemImage: "xmark") }
                    .buttonStyle(GlassButton())
            } else if state == "running" || state == "armed" {
                HStack(spacing: 8) {
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
                HStack(spacing: 8) {
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
            if !m.store.linked {
                Text("Клавиатура пока не отвечает. Включите для неё «Полный доступ» в настройках iOS и один раз откройте её в любом поле ввода.")
                    .font(m.font(12.5)).opacity(0.56)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .glass()
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: m.status.state)
    }

    private func timeString(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 60 ? "\(t / 60) мин \(t % 60) с" : "\(t) с"
    }
}

// MARK: - Parameters

struct ParamsTab: View {
    @EnvironmentObject var m: AppModel
    @StateObject private var demo = DemoRunner()
    @State private var profileName = ""

    private func hint(_ s: String) -> some View {
        Text(s).font(m.font(12.5)).opacity(0.56).frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        ScreenTitle("Параметры")
        VStack(spacing: 10) {
            SectionLabel("Профили")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(m.profiles) { p in
                        let on = m.matches(p)
                        Text(p.name)
                            .font(m.font(14, bold: on))
                            .foregroundColor(on ? m.onAccent : m.textColor)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 14)
                            .background(on ? m.accent : m.field, in: Capsule())
                            .overlay(Capsule().strokeBorder(on ? Color.clear : m.stroke, lineWidth: 1))
                            .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { m.apply(p) } }
                            .contextMenu {
                                Button(role: .destructive) {
                                    m.profiles.removeAll { $0.id == p.id }
                                } label: { Label("Удалить", systemImage: "trash") }
                            }
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Название профиля", text: $profileName)
                    .font(m.font(15))
                    .padding(.vertical, 9)
                    .padding(.horizontal, 11)
                    .background(m.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button {
                    m.saveProfile(named: profileName)
                    profileName = ""
                } label: { Text("Сохранить") }
                    .buttonStyle(GlassButton())
                    .frame(width: 120)
                    .disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            hint("Нажмите на профиль, чтобы применить. Удаление — долгим нажатием.")
        }
        .glass()
        .appear(0)

        VStack(spacing: 10) {
            SectionLabel("Скорость")
            Segments(items: ["Ровная", "Плавающая"], selection: $m.settings.wpmMode)
            if m.settings.wpmMode == 0 {
                NumberRow(title: "Скорость", value: $m.settings.wpm, unit: "впм")
            } else {
                NumberRow(title: "От", value: $m.settings.wpmMin, unit: "впм")
                RowLine()
                NumberRow(title: "До", value: $m.settings.wpmMax, unit: "впм")
                hint("Темп плавно гуляет между значениями.")
            }
        }
        .glass()
        .appear(1)

        VStack(spacing: 10) {
            SectionLabel("Опечатки")
            ToggleRow(title: "Имитация ошибок", subtitle: "Ошибается, стирает и печатает заново",
                      isOn: $m.settings.errorsEnabled)
            if m.settings.errorsEnabled {
                RowLine()
                NumberRow(title: "Доля ошибок", subtitle: "Любой процент символов",
                          value: $m.settings.errorRate, unit: "%", decimals: 1)
                RowLine()
                ToggleRow(title: "Автозамена", subtitle: "Часть опечаток исправляется целым словом после пробела",
                          isOn: $m.settings.autocorrect)
            }
        }
        .glass()
        .appear(2)

        VStack(spacing: 10) {
            SectionLabel("Ритм")
            ToggleRow(title: "Микропаузы", subtitle: "После слов и знаков препинания", isOn: $m.settings.micropauses)
            if m.settings.micropauses {
                RowLine()
                NumberRow(title: "Сила пауз", subtitle: "1.0 — обычная", value: $m.settings.pauseStrength, decimals: 1)
            }
            RowLine()
            ToggleRow(title: "Удобство клавиш", subtitle: "Неудобные сочетания медленнее", isOn: $m.settings.ergonomics)
            RowLine()
            ToggleRow(title: "Разгон и усталость", subtitle: "Медленнее в начале и на длинном тексте", isOn: $m.settings.warmup)
        }
        .glass()
        .appear(3)

        VStack(spacing: 10) {
            SectionLabel("Проба")
            Text(demo.output.isEmpty ? "Здесь видно, как будет выглядеть печать." : demo.output)
                .font(m.font(15))
                .opacity(demo.output.isEmpty ? 0.5 : 1)
                .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
            Text(demo.wpm > 0 ? String(format: "%.0f впм", demo.wpm) : "— впм")
                .font(m.font(13, bold: true)).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
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
        .appear(4)
        .onDisappear { demo.stop() }
    }
}

// MARK: - Settings

struct SettingsTab: View {
    @EnvironmentObject var m: AppModel
    @Binding var page: String?

    private let skins = ["iOS", "Тёмная", "Светлая", "Material", "Старая iOS"]

    private func go(_ p: String?) {
        withAnimation(.easeInOut(duration: 0.25)) { page = p }
    }

    private func nav(_ icon: String, _ title: String, _ value: String, _ target: String) -> some View {
        Button { go(target) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 30, height: 30)
                    .background(m.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(m.stroke, lineWidth: 1))
                Text(title).font(m.font(15.5))
                Spacer()
                Text(value).font(m.font(14)).opacity(0.56).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).opacity(0.4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        if let p = page {
            Button { go(nil) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                    Text("Настройки").font(m.font(15))
                }
                .foregroundColor(m.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            switch p {
            case "look": LookPage()
            case "fonts": FontsPage()
            case "keyboard": KeyboardPage()
            case "stats": StatsPage()
            default: HelpPage()
            }
        } else {
            ScreenTitle("Настройки")
            VStack(spacing: 10) {
                nav("paintbrush", "Оформление", m.theme.name, "look")
                RowLine()
                nav("textformat", "Шрифты", m.theme.fontRegular.isEmpty ? "Системный" : m.theme.fontRegular, "fonts")
                RowLine()
                nav("keyboard", "Клавиатура", skins[min(max(m.settings.skin, 0), 4)], "keyboard")
                RowLine()
                nav("chart.bar", "Статистика", "", "stats")
                RowLine()
                nav("questionmark.circle", "Установка и помощь", "", "help")
            }
            .glass()
            .appear(0)
        }
    }
}

struct LookPage: View {
    @EnvironmentObject var m: AppModel
    @State private var photo: PhotosPickerItem?

    private func binding(_ get: @escaping () -> String, _ set: @escaping (String) -> Void) -> Binding<Color> {
        Binding(get: { Color(hex: get()) }, set: { set($0.hex); m.theme.preset = "custom" })
    }

    private func stop(_ i: Int) -> Binding<Color> {
        binding({ i < m.theme.bg.count ? m.theme.bg[i] : "000000" },
                { v in if i < m.theme.bg.count { m.theme.bg[i] = v } })
    }

    private var angle: Binding<Double> {
        Binding(get: { m.theme.angle }, set: { m.theme.angle = $0; m.theme.preset = "custom" })
    }

    var body: some View {
        ScreenTitle("Оформление")
        VStack(spacing: 10) {
            SectionLabel("Готовые")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(Theme.presets, id: \.id) { p in
                    let on = m.theme.preset == p.id
                    VStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(p.theme.gradient)
                            .frame(height: 46)
                        Text(p.name).font(m.font(11.5, bold: on))
                    }
                    .padding(5)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(on ? m.accent : m.stroke, lineWidth: on ? 2 : 1))
                    .contentShape(Rectangle())
                    .onTapGesture { m.apply(preset: p.id) }
                }
            }
        }
        .glass()
        .appear(0)

        VStack(spacing: 10) {
            SectionLabel("Градиент")
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: m.theme.bg.map { Color(hex: $0) }, startPoint: .leading, endPoint: .trailing))
                .frame(height: 36)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(m.stroke, lineWidth: 1))
            HStack(spacing: 10) {
                RowTitle(title: "Цвета")
                ForEach(0..<3, id: \.self) { i in
                    ColorPicker("", selection: stop(i), supportsOpacity: false).labelsHidden()
                }
            }
            RowLine()
            SliderRow(title: "Угол", value: angle, range: 0...360, unit: "°")
            RowLine()
            ToggleRow(title: "Переливы", subtitle: "Плавная анимация фона", isOn: $m.theme.animated)
            if m.theme.animated {
                SliderRow(title: "Скорость переливов", value: $m.theme.speed, range: 0.2...3, step: 0.1, decimals: 1)
            }
        }
        .glass()
        .appear(1)

        VStack(spacing: 10) {
            SectionLabel("Палитра")
            HStack {
                RowTitle(title: "Акцент", subtitle: "Кнопки, переключатели, выделение")
                ColorPicker("", selection: binding({ m.theme.accent }, { m.theme.accent = $0 }), supportsOpacity: false).labelsHidden()
            }
            RowLine()
            HStack {
                RowTitle(title: "Текст")
                ColorPicker("", selection: binding({ m.theme.text }, { m.theme.text = $0 }), supportsOpacity: false).labelsHidden()
            }
        }
        .glass()
        .appear(2)

        VStack(spacing: 10) {
            SectionLabel("Свой фон")
            HStack(spacing: 8) {
                PhotosPicker(selection: $photo, matching: .images) {
                    Label("Из галереи", systemImage: "photo")
                }
                .buttonStyle(GlassButton(prominent: true))
                if m.bgImage != nil {
                    Button { m.setBackground(nil) } label: { Text("Убрать") }
                        .buttonStyle(GlassButton())
                }
            }
            if m.bgImage != nil {
                ToggleRow(title: "Показывать фото", isOn: $m.theme.useImage)
                RowLine()
                SliderRow(title: "Размытие", value: $m.theme.blur, range: 0...40)
                SliderRow(title: "Затемнение", value: $m.theme.dim, range: 0...0.8, step: 0.05, decimals: 2)
            }
        }
        .glass()
        .appear(3)
        .onChange(of: photo) { item in
            guard let item = item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    let small = LookPage.downscale(img, max: 1600)
                    await MainActor.run { m.setBackground(small) }
                }
            }
        }
    }

    static func downscale(_ img: UIImage, max side: CGFloat) -> UIImage {
        let longest = Swift.max(img.size.width, img.size.height)
        guard longest > side else { return img }
        let k = side / longest
        let size = CGSize(width: img.size.width * k, height: img.size.height * k)
        return UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

struct FontsPage: View {
    @EnvironmentObject var m: AppModel
    @State private var importing = false

    private func menu(_ title: String, _ selection: Binding<String>) -> some View {
        HStack {
            RowTitle(title: title)
            Menu {
                Button("Системный") { selection.wrappedValue = "" }
                ForEach(m.fonts) { f in
                    Button(f.name) { selection.wrappedValue = f.name }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selection.wrappedValue.isEmpty ? "Системный" : selection.wrappedValue)
                        .font(m.font(14, bold: true)).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11))
                }
                .foregroundColor(m.textColor)
            }
        }
    }

    var body: some View {
        ScreenTitle("Шрифты")
        VStack(spacing: 10) {
            SectionLabel("Шрифт приложения")
            menu("Основной (Samsung)", $m.theme.fontRegular)
            RowLine()
            menu("Жирный (Samsung Bold)", $m.theme.fontBold)
        }
        .glass()
        .appear(0)

        VStack(spacing: 10) {
            SectionLabel("Добавленные")
            if m.fonts.isEmpty {
                Text("Пока пусто. Добавьте файлы .ttf или .otf — шрифты Samsung подхватятся автоматически как основной и жирный.")
                    .font(m.font(12.5)).opacity(0.56)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(m.fonts) { f in
                HStack {
                    Text(f.name).font(.custom(f.name, size: 15))
                    Spacer()
                    Button { m.deleteFont(f) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                }
            }
            Button { importing = true } label: { Label("Добавить шрифт", systemImage: "plus") }
                .buttonStyle(GlassButton())
        }
        .glass()
        .appear(1)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.font, .data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { m.importFonts(urls) }
        }
    }
}

struct KeyboardPage: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        ScreenTitle("Клавиатура")
        VStack(spacing: 10) {
            SectionLabel("Вид")
            Segments(items: ["iOS", "Тёмная", "Светлая", "Material", "Старая"], selection: $m.settings.skin)
            ToggleRow(title: "Показывать нажатия", subtitle: "Клавиши подсвечиваются, как от пальца",
                      isOn: $m.settings.showTaps)
            RowLine()
            ToggleRow(title: "Звук клавиш", isOn: $m.settings.clickSound)
            RowLine()
            ToggleRow(title: "Вибрация", subtitle: "Нужен «Полный доступ»", isOn: $m.settings.haptics)
        }
        .glass()
        .appear(0)

        VStack(spacing: 10) {
            SectionLabel("Поведение")
            ToggleRow(title: "Пауза при касании", subtitle: "Любое касание клавиатуры ставит печать на паузу",
                      isOn: $m.settings.pauseOnTouch)
            RowLine()
            ToggleRow(title: "Сигнал старта", subtitle: "Короткая вибрация, когда печать началась. Нужен «Полный доступ»",
                      isOn: $m.settings.startHaptic)
        }
        .glass()
        .appear(1)

        VStack(spacing: 10) {
            SectionLabel("Перенос строки")
            Segments(items: ["Ввод", "Пробел", "Пропуск"], selection: $m.settings.newlineMode)
            Text("В мессенджерах «Ввод» может отправить сообщение — тогда выберите пробел.")
                .font(m.font(12.5)).opacity(0.56)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .glass()
        .appear(2)
    }
}

struct StatsPage: View {
    @EnvironmentObject var m: AppModel

    private func cell(_ value: String, _ name: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(m.font(22, bold: true)).monospacedDigit()
            Text(name).font(m.font(12)).opacity(0.56)
        }
        .frame(maxWidth: .infinity)
    }

    private func date(_ t: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM, HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    var body: some View {
        ScreenTitle("Статистика")
        let chars = m.stats.reduce(0) { $0 + $1.chars }
        let secs = m.stats.reduce(0) { $0 + $1.seconds }
        let typos = m.stats.reduce(0) { $0 + $1.typos }
        VStack(spacing: 10) {
            SectionLabel("Всего")
            HStack {
                cell(secs > 0 ? String(format: "%.0f", Double(chars) / 5 / (secs / 60)) : "—", "впм в среднем")
                cell("\(chars)", "символов")
                cell("\(typos)", "опечаток")
            }
        }
        .glass()
        .appear(0)
        .onAppear { m.loadStats() }

        VStack(spacing: 10) {
            SectionLabel("Запуски")
            if m.stats.isEmpty {
                Text("Пока пусто. Статистика появится после первой печати.")
                    .font(m.font(12.5)).opacity(0.56)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(m.stats) { r in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(date(r.date)).font(m.font(15))
                        Text("\(r.chars) символов · \(r.typos) опечаток · \(Int(r.seconds)) с")
                            .font(m.font(12)).opacity(0.56)
                    }
                    Spacer()
                    Text(String(format: "%.0f впм", r.wpm)).font(m.font(15, bold: true)).monospacedDigit()
                }
                RowLine()
            }
            if !m.stats.isEmpty {
                Button { withAnimation { m.clearStats() } } label: { Label("Очистить", systemImage: "trash") }
                    .buttonStyle(GlassButton())
            }
        }
        .glass()
        .appear(1)
    }
}

struct HelpPage: View {
    @EnvironmentObject var m: AppModel
    @State private var test = ""

    private func row(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Text(n)
                .font(m.font(13, bold: true))
                .foregroundColor(m.onAccent)
                .frame(width: 24, height: 24)
                .background(Circle().fill(m.accent))
            Text(text).font(m.font(14)).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        ScreenTitle("Установка")
        VStack(spacing: 12) {
            SectionLabel("Клавиатура")
            row("1", "Настройки → Основные → Клавиатура → Клавиатуры → Новые клавиатуры → Mercury.")
            row("2", "Откройте её в списке и включите «Полный доступ» — нужен для буфера обмена и вибрации.")
            row("3", "В любом поле ввода удерживайте кнопку с глобусом и выберите Mercury.")
            Button {
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            } label: { Label("Открыть настройки", systemImage: "arrow.up.forward.app") }
                .buttonStyle(GlassButton(prominent: true))
            HStack(spacing: 8) {
                Circle().fill(m.store.linked ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(m.store.linked ? "Связь приложения и клавиатуры работает" : "Клавиатура не отвечает — включите «Полный доступ» и откройте её один раз")
                    .font(m.font(12.5)).opacity(0.7)
                Spacer()
            }
            let kb = m.status.build
            Text("Сборка приложения: \(Store.build) · сборка клавиатуры: \(kb.isEmpty ? "нет данных" : kb)")
                .font(m.font(12.5, bold: true))
                .foregroundColor(kb.isEmpty || kb == Store.build ? m.textColor : .orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !kb.isEmpty && kb != Store.build {
                Text("Клавиатура осталась от старой установки. Удалите её из списка клавиатур, удалите старые копии приложения, перезагрузите телефон и добавьте клавиатуру заново.")
                    .font(m.font(12.5)).opacity(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .glass()
        .appear(0)

        VStack(spacing: 12) {
            SectionLabel("Скрытое управление")
            row("1", "Удерживать пробел — старт, пауза или продолжение с места остановки.")
            row("2", "Любое касание клавиатуры во время печати — мгновенная пауза.")
            row("3", "Удерживать «123» — панель: пауза, полный стоп, вставка из буфера, скорость.")
            row("4", "Удерживать глобус — переключиться на другую клавиатуру.")
        }
        .glass()
        .appear(1)

        VStack(spacing: 10) {
            SectionLabel("Проверка")
            TextField("Коснитесь и выберите клавиатуру Mercury", text: $test, axis: .vertical)
                .font(m.font(15))
                .lineLimit(3...8)
                .padding(11)
                .background(m.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .glass()
        .appear(2)
    }
}
