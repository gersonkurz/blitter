import BlitterCore

/// What an action would do now, for the automation socket's preview and for the confirmation
/// the user answers (#58): the items it works on, where they go, and what else it names.
public struct AutomationPlan: Equatable, Sendable {
    public let action: String
    public let title: String
    public let side: Side
    public let effect: ActionEffect
    public let items: [String]
    public let destination: String?
    public let detail: String?
    /// Everything carrying it out depends on: the command in full (its arguments as they are,
    /// not joined) and the settings it reads then. Compared after Allow, never shown (#58 review).
    let execution: String
}

/// A change an automation client asked for, waiting for the user's Allow or Deny in Blitter.
public struct AutomationConfirmation: Equatable, Sendable {
    public let plan: AutomationPlan
    /// The client process, e.g. "blitter (pid 4711)".
    public let client: String
    /// Changes with every request, so an answer always belongs to the question it was given for.
    public let token: Int
}

// MARK: Preview and run

extension Workspace {
    func previewJSON(_ params: JSONValue) throws(AutomationError) -> JSONValue {
        let (action, side) = try automatedAction(params)
        guard canRun(action.id, on: side) else {
            throw .notRunnable(action.id)
        }
        return Self.json(plan(for: action, on: side))
    }

    /// Runs an action: one that only changes the view at once, any other once the user allows it
    /// in Blitter — and only if, at that moment, it would still do exactly what was shown.
    /// Answers when its jobs are done, with how they ended.
    func runAutomated(_ params: JSONValue, client: String) async throws(AutomationError) -> JSONValue {
        let (action, side) = try automatedAction(params)
        guard canRun(action.id, on: side) else {
            throw .notRunnable(action.id)
        }
        guard action.effect != .view else {
            perform(.runAction(action.id, side))
            return ["done": true, "jobs": []]
        }
        guard automationConfirmation == nil else {
            throw .busy
        }
        let shown = plan(for: action, on: side)
        guard await confirm(shown, client: client) else {
            throw .denied
        }
        // The action as it is now (the settings may have changed it), and exactly the command
        // that is checked is the one carried out.
        guard let current = actionRegistry.action(action.id), current.effect == action.effect,
              canRun(current.id, on: side)
        else {
            throw .changed
        }
        let command = current.command(self, side)
        guard plan(for: current, on: side, command: command) == shown else {
            throw .changed
        }
        let before = Set(jobs.map(\.id))
        perform(command)
        var results: [JSONValue] = []
        for job in jobs where !before.contains(job.id) {
            let ended = await finished(job.id)
            results.append(["state": ended.state == .cancelled ? "cancelled" : "finished",
                            "errors": .array(ended.errors.map {
                                ["path": .string($0.path), "message": .string($0.message)]
                            })])
        }
        return ["done": true, "jobs": .array(results)]
    }

    /// Asks the user; false if denied, or if the client went away meanwhile (the sheet closes).
    private func confirm(_ plan: AutomationPlan, client: String) async -> Bool {
        nextAutomationToken += 1
        let token = nextAutomationToken
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                automationConfirmation = AutomationConfirmation(plan: plan, client: client, token: token)
                automationAnswer = continuation
                notifyChange()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                _ = self?.answerAutomation(token, allow: false)
                self?.notifyChange()
            }
        }
    }

    /// The user's answer to `automationConfirmation`; an old token is ignored.
    func answerAutomation(_ token: Int, allow: Bool) -> Bool {
        guard automationConfirmation?.token == token, let answer = automationAnswer else {
            return false
        }
        automationConfirmation = nil
        automationAnswer = nil
        answer.resume(returning: allow)
        return true
    }

    private func finished(_ id: Int) async -> Job {
        await withCheckedContinuation { continuation in
            whenJobDone(id) { continuation.resume(returning: $0) }
        }
    }

    private func automatedAction(_ params: JSONValue) throws(AutomationError) -> (Action, Side) {
        guard let id = params["action"]?.string else {
            throw .invalidParams("Name the action: “action”, an id from “actions”.")
        }
        let side = try sideParameter(params)
        guard let action = actionRegistry.action(id), action.effect != .notAutomated else {
            throw .notOffered(id)
        }
        return (action, side)
    }

    /// What the action's command names: its items, where they go, and what it runs or opens.
    func plan(for action: Action, on side: Side) -> AutomationPlan {
        plan(for: action, on: side, command: action.command(self, side))
    }

    func plan(for action: Action, on side: Side, command: Command) -> AutomationPlan {
        let selected = selectedItems(on: side).map(\.path)
        let folder = state(of: side).entriesLocation
        var items: [String] = []
        var destination: String?
        var detail: String?
        var execution = String(reflecting: command)
        switch command {
        case let .copyItems(paths, target), let .moveItems(paths, target):
            (items, destination) = (paths, target)
        case .trashSelection, .revealInFinder, .togglePreview, .measureFolderSizes:
            items = selected
        case .newFolder:
            (destination, detail) = (folder, "a new folder")
        case let .runCommand(arguments, workingFolder):
            (destination, detail) = (workingFolder, arguments.joined(separator: " "))
        case let .openWithApp(app, paths, _):
            (items, detail) = (paths, app)
        case let .open(_, name):
            items = [Paths.appending(name, to: folder)]
        case let .compare(left, right):
            items = [left, right]
            execution += " with " + String(reflecting: settings.diffTool) // read when it runs
        case let .present(request):
            (items, detail) = ([request.path], request.kind)
        default:
            items = selected
        }
        return AutomationPlan(action: action.id, title: action.title, side: side, effect: action.effect,
                              items: items, destination: destination, detail: detail, execution: execution)
    }

    static func json(_ plan: AutomationPlan) -> JSONValue {
        var object: [String: JSONValue] = [
            "action": .string(plan.action), "title": .string(plan.title), "side": .string(name(of: plan.side)),
            "effect": .string(plan.effect.rawValue), "items": .array(plan.items.map(JSONValue.string)),
            "needsConfirmation": .bool(plan.effect != .view),
        ]
        if let destination = plan.destination {
            object["destination"] = .string(destination)
        }
        if let detail = plan.detail {
            object["detail"] = .string(detail)
        }
        return .object(object)
    }
}
