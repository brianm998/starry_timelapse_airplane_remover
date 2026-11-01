import Foundation

/// Which snapshot transitions deserve a notification, and which of those get through quiet hours (plan §11).
public struct Alert: Equatable, Sendable {
    public enum Kind: String, Sendable { case needsInput, developRed, failed, daemonDown, monitorUpdate }

    public var kind: Kind
    public var ticket: Int?
    public var title: String
    public var body: String

    /// Pages are what ntfy pages too: they go through quiet hours.
    public var isPage: Bool { kind == .needsInput || kind == .developRed || kind == .daemonDown }
}

public enum Alerts {
    public static func diff(old: Snapshot?, new: Snapshot) -> [Alert] {
        guard let old else { return [] }  // the first snapshot is a baseline, not news
        var alerts: [Alert] = []
        let before = Dictionary(uniqueKeysWithValues: old.tickets.map { ($0.number, $0) })
        for t in new.tickets {
            let was = before[t.number]
            if t.group == "needs_you", was?.group != "needs_you" {
                alerts.append(Alert(kind: .needsInput, ticket: t.number, title: "#\(t.number) needs you",
                                    body: t.question ?? t.parkReason ?? t.title))
            }
            if t.group == "failed", let was, was.group != "failed" {
                alerts.append(Alert(kind: .failed, ticket: t.number, title: "#\(t.number) failed",
                                    body: t.parkReason ?? t.title))
            }
        }
        if let line = new.landing.stopLine, old.landing.stopLine != line {
            alerts.append(Alert(kind: .developRed, ticket: nil, title: "develop is red", body: "\(line) failed on develop; landing is paused"))
        }
        return alerts
    }

    /// 22:00 to 07:00 by default; the window may wrap midnight.
    public static func isQuiet(_ date: Date, startHour: Int = 22, endHour: Int = 7, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return startHour > endHour ? (hour >= startHour || hour < endHour) : (hour >= startHour && hour < endHour)
    }

    public static func shouldDeliver(_ alert: Alert, at date: Date, calendar: Calendar = .current) -> Bool {
        // An update notice is announced once per version, so it must not be spent on a quiet hour.
        alert.isPage || alert.kind == .monitorUpdate || !isQuiet(date, calendar: calendar)
    }
}
