import Foundation

/// The two usage-limit lines of the header ("5 hour: 10% resets in 3 hours (4pm)", "weekly: 24% resets at 10am friday").
/// Pure: the caller passes `now` and the time zone, so the text is testable. A window that has reset, or that no stage has
/// reported yet, reads "—" with the `.unknown` level, never its stale percentage.
public enum UsageLimitText {
    public enum Kind: Sendable { case fiveHour, weekly }
    /// ok < 80%, warn 80..<90%, critical >= 90%; unknown is a missing or elapsed window.
    public enum Level: Sendable, Equatable { case ok, warn, critical, unknown }

    public static func line(kind: Kind, window: UsageWindow?, now: Date, timeZone: TimeZone) -> (text: String, level: Level) {
        let label = kind == .fiveHour ? "5 hour:" : "weekly:"
        guard let window, Date(timeIntervalSince1970: window.resetsAt) > now else { return ("\(label) —", .unknown) }
        let percent = Int((window.utilization * 100).rounded())
        let level: Level = percent >= 90 ? .critical : percent >= 80 ? .warn : .ok
        let resets = Date(timeIntervalSince1970: window.resetsAt)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let clock = clockTime(resets, calendar)
        switch kind {
        case .fiveHour:
            return ("\(label) \(percent)% resets in \(remaining(resets.timeIntervalSince(now))) (\(clock))", level)
        case .weekly:
            let weekday = weekdayNames[calendar.component(.weekday, from: resets) - 1]
            return ("\(label) \(percent)% resets at \(clock) \(weekday)", level)
        }
    }

    private static let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// "N min" under an hour, else the hours rounded ("1 hour", "3 hours").
    static func remaining(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "\(max(minutes, 1)) min" }
        let hours = Int((Double(minutes) / 60).rounded())
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    /// "4pm", "10:30am", "12am": lowercase, minutes only when not on the hour.
    static func clockTime(_ date: Date, _ calendar: Calendar) -> String {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        let suffix = hour < 12 ? "am" : "pm"
        return minute == 0 ? "\(h12)\(suffix)" : "\(h12):" + String(format: "%02d", minute) + suffix
    }
}
