import AppKit
import BlitterModel

/// The main windows (#96): each with a workspace of its own, all sharing one `AppModel`. Keeps
/// them in the order they were opened, knows which one is in front (what menus, shortcuts and
/// automation act on, even while the Settings window is), lets a closed one go, and keeps them
/// all for the next launch. It is the only owner of the windows' workspaces: a closed window's
/// goes with it (unless a Git window of it is still open).
@MainActor
final class MainWindows {
    private(set) var controllers: [MainWindowController] = []
    /// The main window that was main last: the Settings window or a Git window in front does
    /// not change which one the menus act on.
    private weak var lastMain: MainWindowController?
    private var observers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    /// Where the windows are kept for the next launch; nil: nowhere (BLITTER_PROFILE, tests).
    var store: StateStore?
    /// Each new window is set up by the app (what runs after a render).
    var configure: ((MainWindowController) -> Void)?
    /// Blitter is quitting: windows closing now stay among those saved, and nothing is saved.
    var isQuitting = false
    /// While the last session's windows open again, nothing is saved: the first window's first
    /// render would otherwise save a session of one window over the session being restored.
    private var isRestoring = false

    /// The window menus and automation act on: the one main last, else the oldest.
    var front: MainWindowController? {
        lastMain ?? controllers.first
    }

    /// Every window's sides and place, oldest first.
    var saved: [SavedWindow] {
        controllers.map { SavedWindow(state: $0.workspace.savedState, frame: $0.window?.frameDescriptor) }
    }

    /// Keeps every window for the next launch; only what changed is written (StateStore).
    func save() {
        if !isQuitting, !isRestoring {
            store?.save(saved)
        }
    }

    /// The last session's windows, oldest first: `first` (which made the `AppModel` from the
    /// first window's state) where it was, then the others sharing it, each with its sides and
    /// place. Saved once all are open.
    func restore(_ windows: [SavedWindow], first: Workspace) {
        isRestoring = true
        open(first, frame: windows.first?.frame)
        for window in windows.dropFirst() {
            open(Workspace(sharingWith: first, location: window.state.left.location, restoring: window.state),
                 frame: window.frame)
        }
        isRestoring = false
        save()
    }

    /// Opens a window for `workspace`: where it was (`frame`), or the size of the window in
    /// front, a little below and right of it.
    @discardableResult
    func open(_ workspace: Workspace, frame: String? = nil) -> MainWindowController {
        let previous = front
        let controller = MainWindowController(workspace: workspace, frame: frame)
        if frame == nil, let previous = previous?.window, let window = controller.window {
            window.setFrame(NSRect(origin: previous.frame.origin, size: previous.frame.size), display: false)
            let topLeft = NSPoint(x: previous.frame.minX, y: previous.frame.maxY)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: topLeft))
        }
        workspace.system = .appKit(window: controller)
        controller.openWindow = { [weak self, weak workspace] folder in
            if let self, let workspace {
                openWindow(sharingWith: workspace, at: folder)
            }
        }
        controllers.append(controller)
        observe(controller)
        configure?(controller)
        controller.showWindow(nil)
        // A new window is the one in front at once (#98: `blitter --new ~/a` goes on to show ~/a in
        // it), even before it becomes main — which waits for Blitter to be active.
        lastMain = controller
        save()
        return controller
    }

    /// File → New Window: another window sharing `workspace`'s app, both its sides at `folder`.
    @discardableResult
    func openWindow(sharingWith workspace: Workspace, at folder: String) -> MainWindowController {
        open(Workspace(sharingWith: workspace, location: folder))
    }

    private func observe(_ controller: MainWindowController) {
        guard let window = controller.window else {
            return
        }
        let id = ObjectIdentifier(controller)
        var tokens = [observe(NSWindow.didBecomeMainNotification, of: window) { [weak controller] windows in
            windows.lastMain = controller
        }]
        tokens.append(observe(NSWindow.willCloseNotification, of: window) { [weak controller] windows in
            windows.closed(id, controller)
        })
        for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
            tokens.append(observe(name, of: window) { $0.save() })
        }
        observers[id] = tokens
    }

    private func observe(_ name: Notification.Name, of window: NSWindow,
                         _ handle: @escaping @MainActor (MainWindows) -> Void) -> NSObjectProtocol
    {
        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self {
                    handle(self)
                }
            }
        }
    }

    /// A closed window goes, and the windows left are saved; the last one closing ends Blitter,
    /// and stays saved.
    private func closed(_ id: ObjectIdentifier, _ controller: MainWindowController?) {
        if controllers.count > 1, !isQuitting {
            controller?.workspace.windowClosed() // its searches and measurings end (#112)
            controllers.removeAll { ObjectIdentifier($0) == id || $0 === controller }
            save()
        }
        for token in observers.removeValue(forKey: id) ?? [] {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
