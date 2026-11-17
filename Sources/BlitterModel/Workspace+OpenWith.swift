import Foundation
import UniformTypeIdentifiers

/// A kind of file (#109): a name extension and the content type macOS gives it, one it knows.
public struct FileKind: Equatable, Sendable {
    public let pathExtension: String
    public let contentType: UTType

    public init(pathExtension: String, contentType: UTType) {
        self.pathExtension = pathExtension
        self.contentType = contentType
    }
}

/// What an app chosen for Open With is for (#109): files to open, or a kind to make it the
/// default of.
public enum OpenWithTarget: Equatable, Sendable {
    case open([String])
    case setDefault(FileKind)
}

/// Open With (#109): the selected files with an app of the user's choice, and that app as the
/// default for their kind, as Finder's Get Info > Open with > Change All. Which apps can open
/// them is the app's to find (Launch Services); the Model names the files and the kind. A menu
/// takes the files or the kind when it opens and acts on those (`openWithApp`, `setDefaultApp`).
public extension Workspace {
    /// A menu item's title for the action on the side as it is now: Always Open With names the
    /// selected files' extension ("Always Open .md Files With").
    func menuTitle(_ id: String, on side: Side) -> String {
        let title = actionRegistry.action(id)?.title ?? id
        guard id == "always-open-with", let kind = selectedKind(on: side) else {
            return title
        }
        return "Always Open .\(kind.pathExtension) Files With"
    }

    /// The side's selected files that an app would open (not folders), as paths.
    func selectedFilePaths(on side: Side) -> [String] {
        selectedItems(on: side).filter { !$0.isDirectory }.map(\.path)
    }

    /// The kind of the side's selected files when they are all of one kind macOS knows.
    func selectedKind(on side: Side) -> FileKind? {
        state(of: side).selectedKind
    }

    /// "Open With TextEdit", for a failure's notice.
    static func openWithTitle(_ app: String) -> String {
        "Open With \(appName(app))"
    }

    private static func appName(_ app: String) -> String {
        ((app as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

extension Workspace {
    func setDefaultApp(_ app: String, for kind: FileKind) -> Bool {
        let name = Self.appName(app)
        system.setDefaultApp(app, kind.contentType.identifier) { [weak self] problem in
            guard let self else {
                return
            }
            if let problem {
                addNotice("\(name) could not be made the default for .\(kind.pathExtension) files: \(problem)")
            } else {
                addNotice(".\(kind.pathExtension) files now open with \(name).")
            }
            notifyChange()
        }
        return false
    }

    /// The target is named by whoever asks (the action, from the selection as it runs; a menu,
    /// from the selection as it opened): the panel stays open for as long as the user likes.
    func chooseApp(for target: OpenWithTarget) -> Bool {
        if case let .open(paths) = target, paths.isEmpty {
            return false // nothing to open
        }
        system.chooseApp { [weak self] app in
            guard let self, let app else {
                return // none chosen
            }
            switch target {
            case let .open(paths): perform(.openWithApp(app, paths: paths, title: Self.openWithTitle(app)))
            case let .setDefault(kind): perform(.setDefaultApp(app, for: kind))
            }
        }
        return false
    }
}
