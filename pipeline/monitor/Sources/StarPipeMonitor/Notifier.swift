import Foundation
import StarPipeMonitorCore
import UserNotifications

/// Native notifications need a real app bundle (`make app`); run from `swift run` there is no bundle and this does nothing.
final class Notifier: @unchecked Sendable {
    private var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func deliver(_ alert: Alert) {
        guard available, Alerts.shouldDeliver(alert, at: Date()) else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = alert.isPage ? .default : nil
        let id = "\(alert.kind.rawValue)-\(alert.ticket ?? 0)"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
