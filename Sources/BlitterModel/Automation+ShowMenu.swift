import BlitterCore

/// A menu `showMenu` opens (#69): the side's context menu (for its selection, or its folder when
/// nothing is selected), or one of the menu bar's menus by its title.
public enum ShownMenu: String, CaseIterable, Sendable {
    case context
    case file = "File"
    case edit = "Edit"
    case view = "View"
    case go = "Go" // swiftlint:disable:this identifier_name
    case tools = "Tools"
}

extension Workspace {
    /// `showMenu` (#69): opens a menu for `seconds` (default 5, at most 30), then closes it; for
    /// the manual's screenshots of open menus. It only shows something. The answer comes first:
    /// an open menu holds the app until it closes.
    func showMenu(_ params: JSONValue) throws(AutomationError) -> JSONValue {
        guard let name = params["menu"]?.string, let menu = ShownMenu(rawValue: name) else {
            let names = ShownMenu.allCases.map { "“\($0.rawValue)”" }.joined(separator: ", ")
            throw .invalidParams("Name the menu: “menu”, one of \(names).")
        }
        let side = try sideParameter(params)
        var seconds = 5.0
        if case let .number(given)? = params["seconds"] {
            seconds = given
        }
        guard seconds > 0, seconds <= 30 else {
            throw .invalidParams("“seconds” must be more than 0 and at most 30.")
        }
        system.showMenu(menu, side, seconds)
        return ["menu": .string(menu.rawValue), "side": .string(Self.name(of: side)), "seconds": .number(seconds)]
    }
}
