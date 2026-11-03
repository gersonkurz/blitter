import AppKit
import BlitterModel

/// Asks the user in a sheet whether a change an automation client wants (#58) may run: what it
/// is, on which items, to where. Deny is the default button (Return and Escape); allowing takes a
/// click on Allow. When the request goes away unanswered (the client quit), the sheet closes.
@MainActor
final class AutomationPrompt {
    static let allow = NSApplication.ModalResponse.alertSecondButtonReturn
    /// How many items the sheet names; the rest are counted.
    static let shownItems = 12
    private(set) var shown: (token: Int, alert: NSAlert)?

    func render(_ workspace: Workspace, in window: NSWindow?) {
        let request = workspace.automationConfirmation
        if let shown, shown.token != request?.token {
            self.shown = nil
            window?.endSheet(shown.alert.window) // answered elsewhere, or the client went away
        }
        guard let request, shown == nil, let window else {
            return
        }
        let alert = Self.alert(for: request)
        shown = (request.token, alert)
        alert.beginSheetModal(for: window) { [weak self] response in
            if self?.shown?.token == request.token {
                self?.shown = nil
            }
            workspace.perform(.answerAutomation(token: request.token, allow: response == Self.allow))
        }
    }

    static func alert(for request: AutomationConfirmation) -> NSAlert {
        let plan = request.plan
        let alert = NSAlert()
        alert.alertStyle = plan.effect == .changes ? .warning : .informational
        alert.messageText = "\(request.client) wants to run “\(plan.title)”"
        alert.informativeText = informativeText(plan)
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Allow")
        return alert
    }

    static func informativeText(_ plan: AutomationPlan) -> String {
        var lines = plan.items.prefix(shownItems).map(\.self)
        if plan.items.count > shownItems {
            lines.append("and \(plan.items.count - shownItems) more")
        }
        if let detail = plan.detail {
            lines.append(detail)
        }
        if let destination = plan.destination {
            lines.append("in “\(destination)”")
        }
        return lines.joined(separator: "\n")
    }
}
