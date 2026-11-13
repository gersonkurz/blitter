import TOMLKit

/// One button of the window's toolbar (#88), from `[toolbar] items` in the settings file: an
/// action, with another icon than its own if one is given, or a gap between groups.
public enum ToolbarEntry: Equatable, Sendable {
    /// `icon`: an SF Symbols name instead of the action's own; nil keeps that.
    case action(String, icon: String?)
    case gap

    /// The toolbar as it comes with Blitter: what is on or off, then the file operations, then
    /// the tools.
    static let defaults: [ToolbarEntry] = [
        "toggle-hidden-files", "refresh", "-",
        "new-folder", "copy-to-other-side", "move-to-other-side", "rename", "move-to-trash", "-",
        "open-in-terminal", "open-in-code", "git-log", "git-commit", "git-sync",
    ].map { $0 == "-" ? .gap : .action($0, icon: nil) }

    var actionID: String? {
        if case let .action(id, _) = self {
            return id
        }
        return nil
    }

    /// Reads the list: "-" is a gap, a string an action with its own icon, and
    /// `{ action = "…", icon = "…" }` one with another icon. Any problem leaves the list as it was.
    static func items(_ value: TOMLValueConvertible, at name: String) -> (items: [ToolbarEntry], problems: [String]) {
        guard let array = value.array else {
            return ([], ["“\(name)”: expected a list such as [\"toggle-hidden-files\", \"-\", \"new-folder\"]."])
        }
        var items: [ToolbarEntry] = []
        var problems: [String] = []
        for element in array {
            if let id = element.string {
                items.append(id == "-" ? .gap : .action(id, icon: nil))
                continue
            }
            // Every key must find its value: see `MenuBarSettings.items` (a key cut at an escaped NUL).
            guard let table = element.table, let id = table["action"]?.string, let icon = table["icon"]?.string,
                  table.keys.count == 2, table.keys.allSatisfy({ table[$0] != nil })
            else {
                problems
                    .append("“\(name)”: an entry must be an action name, \"-\" or { action = \"…\", icon = \"…\" }.")
                continue
            }
            guard !icon.isEmpty, !icon.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                problems.append("“\(name)”: “\(id)”: icon must be an SF Symbols name such as \"star\".")
                continue
            }
            items.append(.action(id, icon: icon))
        }
        return (problems.isEmpty ? items : [], problems)
    }

    /// Leaves out items naming an action that does not exist, each one reported.
    static func keepingKnown(_ items: [ToolbarEntry],
                             _ known: Set<String>) -> (items: [ToolbarEntry], problems: [String])
    {
        var problems: [String] = []
        let kept = items.filter { item in
            guard let id = item.actionID, !known.contains(id) else {
                return true
            }
            problems.append("“toolbar.items”: there is no action “\(id)”.")
            return false
        }
        return (kept, problems)
    }
}

/// A toolbar button as it is to be shown now (#88).
public struct ToolbarButtonState: Equatable, Sendable {
    /// Whether its action fits the active side as it is now.
    public let isEnabled: Bool
    /// For an action that turns something on or off: whether it is on.
    public let isOn: Bool?
}

public extension Workspace {
    /// The button for `id`: enabled exactly when the action could run on the active side, as
    /// the menu bar's items are.
    func toolbarButton(_ id: String) -> ToolbarButtonState {
        ToolbarButtonState(isEnabled: canRun(id, on: activeSide), isOn: isOn(id))
    }
}
