import Foundation
import TOMLKit

/// Changing one entry of the settings file in place (#63): the line that sets it gets the new
/// value, everything else — order, comments, the user's own layout — stays as it is.
extension Settings {
    /// The file's text with `[font] size` set. Nil — the file must then be left alone — unless
    /// the edit provably changed that entry and nothing else: both texts parse, the edited one's
    /// `font.size` is the new size, and without `font.size` the two documents are equal, every
    /// value (strings, unknown entries) included. A `[font]` line inside a multi-line string, a
    /// size set as `font = { … }` or `font.size`, a file that does not parse: all refused.
    public static func settingFontSize(_ size: Double, in text: String) -> String? {
        let value = size == size.rounded() ? String(Int(size)) : String(size)
        let edited = setting("size", to: value, inSection: "font", of: text)
        guard let before = try? TOMLTable(string: text), let after = try? TOMLTable(string: edited),
              let font = after["font"]?.table, let saved = font["size"],
              (saved.double ?? saved.int.map(Double.init)) == size
        else {
            return nil
        }
        font.remove(at: "size")
        if font.isEmpty, before["font"] == nil {
            after.remove(at: "font") // the table was added for the size
        }
        before["font"]?.table?.remove(at: "size")
        return before == after ? edited : nil
    }

    /// The text with `key = value` in the table `[section]`: the key's line changed (its comment
    /// kept), else a line added below the table's header, else the table added at the end.
    static func setting(_ key: String, to value: String, inSection section: String, of text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let header = lines.firstIndex(where: { tableHeader($0) == section }) else {
            var result = text
            if !result.isEmpty, !result.hasSuffix("\n") {
                result += "\n"
            }
            return result + (result.isEmpty ? "" : "\n") + "[\(section)]\n\(key) = \(value)\n"
        }
        let end = lines[(header + 1)...].firstIndex { tableHeader($0) != nil } ?? lines.count
        for index in (header + 1) ..< end {
            if let range = valueRange(of: key, in: lines[index]) {
                lines[index].replaceSubrange(range, with: value)
                return lines.joined(separator: "\n")
            }
        }
        lines.insert("\(key) = \(value)", at: header + 1)
        return lines.joined(separator: "\n")
    }

    /// The table a line opens, or nil if it opens none. An array of tables (`[[x]]`) gives its
    /// whole text: it ends the table before it but is never the one looked for. A line of a
    /// multi-line array (`["a", "b"],`) has more after its `]` and opens nothing.
    private static func tableHeader(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else {
            return nil
        }
        if trimmed.hasPrefix("[[") {
            return trimmed
        }
        guard let close = trimmed.firstIndex(of: "]") else {
            return nil
        }
        let rest = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard rest.isEmpty || rest.hasPrefix("#") else {
            return nil
        }
        return trimmed[trimmed.index(after: trimmed.startIndex) ..< close].trimmingCharacters(in: .whitespaces)
    }

    /// Where the value of `key = value  # comment` is in the line, without the spaces around it.
    private static func valueRange(of key: String, in line: String) -> Range<String.Index>? {
        let pattern = /^\s*(?<key>[A-Za-z0-9_-]+)\s*=\s*(?<value>[^#]*?)\s*(#.*)?$/
        guard let match = line.wholeMatch(of: pattern), match.output.key == key else {
            return nil
        }
        return match.output.value.startIndex ..< match.output.value.endIndex
    }
}
