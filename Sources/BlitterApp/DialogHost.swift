import AppKit
import BlitterModel

/// Shows the dialogs and windows the Model asks for (#42), by kind: each kind's window is
/// registered at launch. Open windows are kept until they close; then nothing holds them, so a
/// closed window and its model (a whole history, say) are freed.
@MainActor
enum DialogHost {
    private static var factories: [String: (DialogRequest) -> NSWindowController] = [:]
    private(set) static var open: [NSWindowController] = []
    /// The close observer of each open window, removed when it closes.
    private static var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    static func register(_ kind: String, _ factory: @escaping (DialogRequest) -> NSWindowController) {
        factories[kind] = factory
    }

    /// A kind nobody registered shows nothing.
    static func present(_ request: DialogRequest) {
        guard let factory = factories[request.kind] else {
            return
        }
        let controller = factory(request)
        open.append(controller)
        if let window = controller.window {
            let id = ObjectIdentifier(controller)
            // Weak: the observer must not keep the controller alive after it closed.
            observers[id] = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak controller] _ in
                MainActor.assumeIsolated { closed(id, controller) }
            }
        }
        controller.showWindow(nil)
    }

    private static func closed(_ id: ObjectIdentifier, _ controller: NSWindowController?) {
        if let observer = observers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(observer)
        }
        open.removeAll { ObjectIdentifier($0) == id || $0 === controller }
    }
}
