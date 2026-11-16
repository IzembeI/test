import SwiftUI
import BackgroundTasks
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.werx.aurora.refresh", using: nil) { task in
            Self.handleRefresh(task as! BGAppRefreshTask)
        }
        return true
    }

    // Show notifications while the app is open too.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    static func scheduleRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: "com.werx.aurora.refresh")
        req.earliestBeginDate = Date(timeIntervalSinceNow: 3 * 3600)
        try? BGTaskScheduler.shared.submit(req)
    }

    static func handleRefresh(_ task: BGAppRefreshTask) {
        scheduleRefresh()
        let work = Task { @MainActor in
            let model = AppModel()
            await model.updateAll(onlyDue: true)
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }
}

@main
struct AuroraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.vpn)
                .environmentObject(model.autopilot)
                .preferredColorScheme(model.settings.theme == .system ? nil : (model.settings.theme == .dark ? .dark : .light))
                .tint(Theme.accent(model.settings.accent))
                .onOpenURL { url in model.handle(text: url.absoluteString) }
                .task {
                    model.startPolling()
                    if model.settings.updateSubsOnLaunch { await model.updateAll(onlyDue: true) }
                    if !model.vpn.isConnected { await model.autopilot.probeWhitelist() }
                    if model.settings.autoSelect && model.settings.autopilotScanOnOpen {
                        model.autopilotScan()
                    } else if model.settings.autoPingOnOpen {
                        model.testAll()
                    }
                    Notifier.scheduleExpiry(model.subscriptions, settings: model.settings.notifications)
                }
        }
        .onChange(of: phase) { p in
            switch p {
            case .active:
                model.startPolling()
                Notifier.clearBadge()
            case .background:
                model.stopPolling()
                AppDelegate.scheduleRefresh()
            default: break
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            HomeView(tab: $tab)
                .tabItem { Label("Главная", systemImage: "power.circle") }
                .tag(0)
            ServersView()
                .tabItem { Label("Серверы", systemImage: "server.rack") }
                .tag(1)
            RoutingView()
                .tabItem { Label("Маршруты", systemImage: "arrow.triangle.branch") }
                .tag(2)
            SettingsView()
                .tabItem { Label("Настройки", systemImage: "gearshape") }
                .tag(3)
        }
        .overlay(alignment: .top) { ToastView() }
        .alert(model.announcement?.title ?? "", isPresented: Binding(get: { model.announcement != nil }, set: { if !$0 { model.announcement = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.announcement?.text ?? "")
        }
    }
}

struct ToastView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let t = model.toast {
            Text(t)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(radius: 8, y: 4)
                .padding(.top, 8).padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { model.toast = nil }
                .task(id: t) {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    withAnimation { model.toast = nil }
                }
        }
    }
}
