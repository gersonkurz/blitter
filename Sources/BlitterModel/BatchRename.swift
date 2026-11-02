import Foundation

/// How Batch Rename makes the new names: find and replace (text or regular expression), a
/// template with a counter, and a change of case. The name and the extension are treated apart
/// unless `includesExtension`; a folder's whole name is its name.
public struct BatchRename: Equatable, Sendable {
    public enum CaseChange: String, CaseIterable, Sendable {
        case unchanged
        case lower
        case upper
        case title
    }

    public var find = ""
    public var replace = ""
    /// `find` is a regular expression; `replace` may name its groups ($1).
    public var usesRegex = false
    public var ignoresCase = true
    /// Find and replace and the template work on the whole name, the extension included.
    public var includesExtension = false
    /// The new name: `{name}` is the name after find and replace, `{n}` the counter, `{n:3}` the
    /// counter with at least three digits. The extension follows unless it is included.
    public var template = "{name}"
    /// The counter's value for the first item, in list order; within `counterRange`.
    public var counterStart = 1
    public static let counterRange = 0 ... 999_999_999
    public var nameCase = CaseChange.unchanged
    public var extensionCase = CaseChange.unchanged

    public init() {}

    /// An item to rename: its name, and whether it is a folder (whose name has no extension).
    public struct Item: Equatable, Sendable {
        public let name: String
        public let isFolder: Bool

        public init(name: String, isFolder: Bool) {
            self.name = name
            self.isFolder = isFolder
        }
    }

    /// Why a rule gives no names at all.
    public enum Problem: Error, Equatable, Sendable {
        case invalidExpression
        case counterOutOfRange

        public var message: String {
            switch self {
            case .invalidExpression: "The search is not a valid regular expression."
            case .counterOutOfRange: "The counter must start between 0 and 999,999,999."
            }
        }
    }

    /// The new names, in the items' order.
    public func newNames(for items: [Item]) throws(Problem) -> [String] {
        guard Self.counterRange.contains(counterStart) else {
            throw .counterOutOfRange // so counting on can never overflow
        }
        var expression: NSRegularExpression?
        if usesRegex, !find.isEmpty {
            expression = try? NSRegularExpression(pattern: find, options: ignoresCase ? [.caseInsensitive] : [])
            if expression == nil {
                throw .invalidExpression
            }
        }
        return items.enumerated().map { index, item in
            newName(for: item, counter: counterStart + index, expression: expression)
        }
    }

    private func newName(for item: Item, counter: Int, expression: NSRegularExpression?) -> String {
        let splits = !includesExtension && !item.isFolder && !(item.name as NSString).pathExtension.isEmpty
        var name = splits ? (item.name as NSString).deletingPathExtension : item.name
        let pathExtension = splits ? (item.name as NSString).pathExtension : ""
        if let expression {
            name = expression.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name),
                                                       withTemplate: replace)
        } else if !find.isEmpty {
            name = name.replacingOccurrences(of: find, with: replace, options: ignoresCase ? [.caseInsensitive] : [])
        }
        name = Self.render(template, name: name, counter: counter)
        name = Self.change(name, to: nameCase)
        let changedExtension = Self.change(pathExtension, to: extensionCase)
        return changedExtension.isEmpty ? name : name + "." + changedExtension
    }

    /// The template with `{name}` and the counters (`{n}`, `{n:width}`) put in. Only the template
    /// is read for them: a name that contains "{n}" is put in as it is. Anything else stays.
    private static func render(_ template: String, name: String, counter: Int) -> String {
        var result = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            let after = rest[open...]
            if after.hasPrefix("{name}") {
                result += name
                rest = after.dropFirst(6)
            } else if after.hasPrefix("{n}") {
                result += String(counter)
                rest = after.dropFirst(3)
            } else if after.hasPrefix("{n:"), let close = after.firstIndex(of: "}"),
                      let width = Int(after[after.index(open, offsetBy: 3) ..< close]), (1 ... 12).contains(width)
            {
                let digits = String(counter)
                result += String(repeating: "0", count: max(0, width - digits.count)) + digits
                rest = after[after.index(after: close)...]
            } else {
                result += "{"
                rest = after.dropFirst()
            }
        }
        return result + rest
    }

    private static func change(_ text: String, to change: CaseChange) -> String {
        switch change {
        case .unchanged: text
        case .lower: text.lowercased()
        case .upper: text.uppercased()
        case .title: text.capitalized
        }
    }
}

/// What Batch Rename would do with the items, and whether it can.
public struct BatchRenamePreview: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let oldName: String
        public let newName: String
        /// Why this item cannot get its new name, if it cannot.
        public let problem: String?

        public var changes: Bool {
            oldName != newName
        }
    }

    /// The folder the items are in.
    public let folder: String
    public let rows: [Row]
    /// A problem with the rule itself (a regular expression that does not parse).
    public let problem: String?

    /// Every new name usable, and at least one item changes.
    public var canRename: Bool {
        problem == nil && rows.allSatisfy { $0.problem == nil } && rows.contains(where: \.changes)
    }

    public var changeCount: Int {
        rows.count(where: \.changes)
    }

    /// `taken`: the names of everything in the folder, those being renamed included. A new name
    /// must be valid, differ from the other new names, and not be taken by an item that keeps its
    /// name; all compared ignoring case, as most volumes do (and the job does on every volume).
    init(_ rule: BatchRename, items: [BatchRename.Item], taken: [String], folder: String) {
        self.folder = folder
        do {
            let names = try rule.newNames(for: items)
            problem = nil
            rows = Self.checked(Array(zip(items.map(\.name), names)), taken: taken)
        } catch {
            rows = items.map { Row(oldName: $0.name, newName: $0.name, problem: nil) }
            problem = error.message
        }
    }

    /// The same renames checked again against the folder as it is now (`taken`): each item must
    /// still be there, under its old name.
    func rechecked(taken: [String]) -> BatchRenamePreview {
        let present = Set(taken)
        let rows = Self.checked(rows.map { ($0.oldName, $0.newName) }, taken: taken).map { row in
            present.contains(row.oldName) ? row
                : Row(oldName: row.oldName, newName: row.newName, problem: "It is no longer there.")
        }
        return BatchRenamePreview(folder: folder, rows: rows, problem: problem)
    }

    private init(folder: String, rows: [Row], problem: String?) {
        self.folder = folder
        self.rows = rows
        self.problem = problem
    }

    private static func checked(_ renames: [(old: String, new: String)], taken: [String]) -> [Row] {
        let renamed = Set(renames.map(\.old)) // exactly these: "FOO" next to a renamed "foo" stays
        let kept = Set(taken.lazy.filter { !renamed.contains($0) }.map { $0.lowercased() })
        var counts: [String: Int] = [:]
        for rename in renames {
            counts[rename.new.lowercased(), default: 0] += 1
        }
        return renames.map { old, name in
            let key = name.lowercased()
            let problem: String? = if name.isEmpty || name == "." || name == ".." || name.contains("/")
                || name.utf8.count > 255
            {
                "Not a valid name."
            } else if counts[key, default: 0] > 1 {
                "Another item would get the same name."
            } else if kept.contains(key) {
                "An item with this name is already there."
            } else {
                nil
            }
            return Row(oldName: old, newName: name, problem: problem)
        }
    }
}
