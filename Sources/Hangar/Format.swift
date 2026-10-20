import Foundation

enum Format {
    /// `<1m`, `14m`, `1h 5m`.
    static func duration(_ seconds: TimeInterval) -> String {
        let mins = Int(max(0, seconds) / 60)
        if mins < 1 { return "<1m" }
        if mins < 60 { return "\(mins)m" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// "20 Oct at 04:20": a failure's own date and time, which stays true however long the window has been open.
    static func shortDateTime(_ d: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        d.formatted(Date.FormatStyle(timeZone: timeZone).locale(locale).day().month(.abbreviated).hour().minute())
    }

    /// 8 -> "8 GB", 5.1 -> "5.1 GB".
    static func gb(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value)) GB" : String(format: "%.1f GB", value)
    }
}
