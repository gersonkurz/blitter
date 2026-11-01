import Foundation
import TOMLKit

/// The user's configuration from the settings file (TOML). Every entry has a default; a missing
/// file means all defaults. New tickets add their sections here.
public struct Settings: Equatable, Sendable {
    /// How the Date Modified column shows dates, as a Unicode date pattern (#12).
    public var dateFormat = "dd.MM.yyyy HH:mm"

    public init() {}

    /// What `Settings… (⌘,)` creates when there is no file yet: every entry, commented.
    public static let defaultFile = """
    # Blitter settings. Blitter reads this file at launch and again whenever it changes.
    # Anything missing or invalid falls back to its default; problems are shown in the window.

    [files]
    # How the Date Modified column shows dates (Unicode date pattern), e.g. "yyyy-MM-dd HH:mm".
    date_format = "dd.MM.yyyy HH:mm"

    """

    /// Parses a settings file. Never fails: problems (syntax errors, unknown entries, wrong types)
    /// are listed, and the entries they concern keep their defaults.
    public static func parse(_ text: String) -> (settings: Settings, problems: [String]) {
        var settings = Settings()
        let root: TOMLTable
        do {
            root = try TOMLTable(string: text)
        } catch let error as TOMLParseError {
            return (settings, ["Line \(error.source.begin.line): \(error.description)"])
        } catch {
            return (settings, ["The settings file could not be read: \(error.localizedDescription)"])
        }
        var problems: [String] = []
        for (section, value) in entries(of: root) {
            guard let value else {
                problems.append(unreadableKey(section))
                continue
            }
            guard let table = value.table, let known = schema[section] else {
                problems.append("Unknown setting “\(section)”.")
                continue
            }
            for (key, value) in entries(of: table) {
                guard let value else {
                    problems.append(unreadableKey("\(section).\(key)"))
                    continue
                }
                guard let apply = known[key] else {
                    problems.append("Unknown setting “\(section).\(key)”.")
                    continue
                }
                if let problem = apply(&settings, value) {
                    problems.append("“\(section).\(key)”: \(problem)")
                }
            }
        }
        return (settings, problems)
    }

    /// A table's entries in key order. TOMLKit's own iterator is not used: its keys go through C
    /// strings, so a key with an escaped NUL ("bad\u0000key") comes back cut short, and the
    /// iterator crashes when the lookup finds nothing. A cut-short key either finds nothing or —
    /// if it now reads like another key in the table — shows up twice, which the real, unique
    /// keys of a table never do. Either way the entry gets no value, so it is reported, not used.
    private static func entries(of table: TOMLTable) -> [(key: String, value: TOMLValueConvertible?)] {
        let keys = table.keys
        var counts: [String: Int] = [:]
        for key in keys {
            counts[key, default: 0] += 1
        }
        var entries: [(key: String, value: TOMLValueConvertible?)] = []
        for key in counts.keys.sorted() {
            entries.append((key, table[key]))
            for _ in 1 ..< (counts[key] ?? 1) {
                entries.append((key, nil)) // the extra one(s): cut-short keys with this prefix
            }
        }
        return entries
    }

    private static func unreadableKey(_ start: String) -> String {
        "A setting starting with “\(start)” has a control character (such as \\u0000) in its name."
    }

    /// Each known entry with a function that applies its value, or explains why it can't. The
    /// value keeps its TOML type: a date is not a string, a float is not an integer.
    private typealias Entry = @Sendable (inout Settings, TOMLValueConvertible) -> String?
    private static let schema: [String: [String: Entry]] = [
        "files": [
            "date_format": { settings, value in
                guard let format = value.string, !format.isEmpty else {
                    return "expected a date pattern such as “dd.MM.yyyy HH:mm”."
                }
                settings.dateFormat = format
                return nil
            },
        ],
    ]
}
