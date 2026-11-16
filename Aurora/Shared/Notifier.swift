import Foundation
import UserNotifications

/// Local notifications for both the app and the packet tunnel. Every kind
/// has its own switch in NotificationSettings and its own thread, so iOS
/// groups them separately in Notification Center.
enum NotifyKind: String, CaseIterable {
    case connected, disconnected, connectionLost, reconnected, networkChanged, serverSwitched
    case expiry, quota, subscriptionUpdated, subscriptionError, announcement
    case sessionSummary, dailyReport, trafficCap, test

    var thread: String {
        switch self {
        case .connected, .disconnected, .connectionLost, .reconnected, .networkChanged, .serverSwitched: return "connection"
        case .expiry, .quota, .subscriptionUpdated, .subscriptionError, .announcement: return "subscription"
        case .sessionSummary, .dailyReport, .trafficCap: return "traffic"
        case .test: return "test"
        }
    }

    /// Alerts that still come through in quiet hours.
    var important: Bool {
        switch self {
        case .connectionLost, .expiry, .quota, .trafficCap, .test: return true
        default: return false
        }
    }

    func allowed(_ s: NotificationSettings) -> Bool {
        guard s.enabled else { return false }
        switch self {
        case .connected: return s.onConnect
        case .disconnected: return s.onDisconnect
        case .connectionLost: return s.onConnectionLost
        case .reconnected: return s.onReconnect
        case .networkChanged: return s.onNetworkChange
        case .serverSwitched: return s.onServerSwitch
        case .expiry: return s.expiryWarning
        case .quota: return s.quotaWarning
        case .subscriptionUpdated: return s.onSubscriptionUpdated
        case .subscriptionError: return s.onSubscriptionError
        case .announcement: return s.announcements
        case .sessionSummary: return s.sessionSummary
        case .dailyReport: return s.dailyReport
        case .trafficCap: return s.trafficCap
        case .test: return true
        }
    }
}

enum Notifier {
    static let categoryConnection = "aurora.connection"

    static func requestAuthorization(_ done: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            DispatchQueue.main.async { done?(ok) }
        }
    }

    static func status(_ done: @escaping (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async { done(s.authorizationStatus) }
        }
    }

    static func post(_ kind: NotifyKind, title: String, body: String, settings: NotificationSettings,
                     id: String? = nil, delay: TimeInterval = 0) {
        guard kind.allowed(settings) else { return }
        if settings.isQuiet() && !kind.important { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.threadIdentifier = kind.thread
        c.categoryIdentifier = categoryConnection
        if settings.sound && !settings.isQuiet() { c.sound = .default }
        if #available(iOS 15.0, *) {
            switch settings.level {
            case .passive: c.interruptionLevel = .passive
            case .active: c.interruptionLevel = .active
            case .timeSensitive: c.interruptionLevel = kind.important ? .timeSensitive : .active
            }
            c.relevanceScore = kind.important ? 1 : 0.3
        }
        if settings.badge && (kind == .expiry || kind == .quota) { c.badge = 1 }
        let trigger = delay > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false) : nil
        let req = UNNotificationRequest(identifier: id ?? "\(kind.rawValue)-\(UUID().uuidString)", content: c, trigger: trigger)
        UNUserNotificationCenter.current().add(req)
    }

    static func clearBadge() {
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(0)
        }
    }

    /// Repeating report at the chosen hour (scheduled by the app).
    static func scheduleDailyReport(_ s: NotificationSettings, body: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["daily-report"])
        guard s.enabled, s.dailyReport else { return }
        let c = UNMutableNotificationContent()
        c.title = "Aurora: итоги дня"
        c.body = body
        c.threadIdentifier = NotifyKind.dailyReport.thread
        if s.sound { c.sound = .default }
        if #available(iOS 15.0, *) { c.interruptionLevel = .passive }
        var comps = DateComponents()
        comps.hour = s.dailyReportHour
        comps.minute = 0
        let trig = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        center.add(UNNotificationRequest(identifier: "daily-report", content: c, trigger: trig))
    }

    /// Reminders before a subscription ends, scheduled ahead of time so they
    /// arrive even when neither the app nor the tunnel is running.
    static func scheduleExpiry(_ subs: [Subscription], settings s: NotificationSettings) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { reqs in
            let old = reqs.map(\.identifier).filter { $0.hasPrefix("expiry-") }
            center.removePendingNotificationRequests(withIdentifiers: old)
            guard s.enabled, s.expiryWarning else { return }
            for sub in subs {
                guard let exp = sub.expire else { continue }
                for days in Set([s.expiryDays, 1]) {
                    let fire = exp.addingTimeInterval(-Double(days) * 86400)
                    guard fire > Date() else { continue }
                    let c = UNMutableNotificationContent()
                    c.title = "Подписка заканчивается"
                    c.body = "«\(sub.name)» истекает \(Fmt.date(exp)) — осталось \(days) \(plural(days, "день", "дня", "дней"))."
                    c.threadIdentifier = NotifyKind.expiry.thread
                    if s.sound { c.sound = .default }
                    if s.badge { c.badge = 1 }
                    if #available(iOS 15.0, *) {
                        c.interruptionLevel = s.level == .timeSensitive ? .timeSensitive : (s.level == .passive ? .passive : .active)
                    }
                    var comps = Calendar.current.dateComponents([.year, .month, .day], from: fire)
                    comps.hour = max(10, s.quietHours ? s.quietTo : 10)
                    let trig = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                    center.add(UNNotificationRequest(identifier: "expiry-\(sub.id.uuidString)-\(days)", content: c, trigger: trig))
                }
            }
        }
    }

    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let n10 = n % 10, n100 = n % 100
        if n10 == 1 && n100 != 11 { return one }
        if (2...4).contains(n10) && !(12...14).contains(n100) { return few }
        return many
    }
}
