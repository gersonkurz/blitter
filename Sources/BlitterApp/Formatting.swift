import AppKit
import BlitterCore

@MainActor
enum Formatting {
    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func size(of entry: DirectoryEntry) -> String {
        entry.kind == .directory ? "--" : sizeFormatter.string(fromByteCount: entry.size)
    }

    /// A formatter for the settings' date pattern (#12): exactly the pattern, never "Yesterday"
    /// or other relative forms.
    static func dateFormatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = pattern
        return formatter
    }

    /// Digits of equal width, so dates and sizes line up from row to row.
    static func tabularFont(like font: NSFont?) -> NSFont {
        .monospacedDigitSystemFont(ofSize: font?.pointSize ?? NSFont.systemFontSize, weight: .regular)
    }

    /// Dates that together show every month and every weekday name, with two-digit days and
    /// hours: the widest of them sizes the date column, whatever the pattern and language.
    static let wideSampleDates: [Date] = {
        func date(month: Int, day: Int) -> Date? {
            DateComponents(calendar: .current, year: 2026, month: month, day: day, hour: 23, minute: 58,
                           second: 58).date
        }
        let months = (1 ... 12).compactMap { date(month: $0, day: 28) }
        let weekdays = (21 ... 27).compactMap { date(month: 9, day: $0) } // Monday to Sunday
        return months + weekdays
    }()
}
