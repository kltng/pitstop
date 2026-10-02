import Foundation

enum Format {
    // Templates rather than fixed formats so 24-hour locales aren't forced
    // into "h:mm a".
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEdMMMjmm")
        return f
    }()

    static func percent(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "–" }
        // Same trapping hazard as wholeSeconds: utilization comes from provider
        // payloads, so pin it to a displayable range before converting.
        return "\(Int(min(max(v, -1_000_000), 1_000_000).rounded()))%"
    }

    static func reset(_ date: Date?) -> String {
        guard let date else { return "" }
        let stamp = Calendar.current.isDateInToday(date)
            ? time.string(from: date)
            : day.string(from: date)
        return "resets \(stamp) (\(relative(date.timeIntervalSinceNow)))"
    }

    /// Whole seconds, clamped into a range `Int` can represent. Reset stamps
    /// arrive straight from provider payloads, and `Int(_: Double)` traps on
    /// anything past `Int.max` — a nonsense timestamp must not kill the app.
    /// NaN and negatives collapse to zero, which the callers already render
    /// as "now" / "<1m".
    static func wholeSeconds(_ seconds: TimeInterval) -> Int {
        guard seconds > 0 else { return 0 }
        return seconds < Double(Int.max) ? Int(seconds) : .max
    }

    static func relative(_ seconds: TimeInterval) -> String {
        let total = wholeSeconds(seconds)
        let d = total / 86400
        let h = (total % 86400) / 3600
        let m = (total % 3600) / 60
        if d > 0 { return "in \(d)d \(h)h" }
        if h > 0 { return "in \(h)h \(m)m" }
        if m > 0 { return "in \(m)m" }
        return total > 0 ? "in \(total)s" : "now"
    }

    static let updated: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmmss")
        return f
    }()

    private static let weekdayTime: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEjmm")
        return f
    }()

    /// Short reset stamp for the menu rows: "9:49 PM · 3h 34m" /
    /// "Thu 10:29 AM · 5d 16h".
    static func compactReset(_ date: Date?) -> String {
        guard let date else { return "" }
        let stamp = Calendar.current.isDateInToday(date)
            ? time.string(from: date)
            : weekdayTime.string(from: date)
        return "\(stamp) · \(relativeShort(date.timeIntervalSinceNow))"
    }

    static func relativeShort(_ seconds: TimeInterval) -> String {
        let total = wholeSeconds(seconds)
        let d = total / 86400
        let h = (total % 86400) / 3600
        let m = (total % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "<1m"   // sub-minute (or already elapsed, clamped) — never "0m"
    }

    /// A coarse clock stamp for projections — "6:40 PM" today, "Sun 6:40 PM"
    /// otherwise. No seconds: an extrapolated estimate can't justify that.
    static func shortClock(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? time.string(from: date)
            : weekdayTime.string(from: date)
    }
}
