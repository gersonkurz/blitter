import Foundation

/// How a job takes its turn (#112): heavy or quick, and the paths it uses — as given at once, and
/// as the file system names them once resolved off the main thread. A job starts only once its
/// own paths are resolved (and, for a move, it is known whether it stays on one volume). Others
/// compare with both forms. While a job is not resolved it is in the way of every later job that
/// uses paths — another path could lead to its items — but only for a while (`stalled`, the
/// owner's choice: about 2 s, where resolving takes milliseconds); then it counts as stalled (a
/// network volume that does not answer) and holds up only the jobs that share its paths as given.
struct Turn {
    enum Kind {
        case heavy, quick
        /// A move, until it is known whether it stays on one volume.
        case undecided
    }

    let operation: FileOperation
    var kind: Kind
    /// The paths as given, and as the file system names them (nil until resolved).
    let given: PathUse
    var resolved: PathUse?
    var started = false
    /// Not resolved in time: compared by its paths as given only.
    var stalled = false
    /// Start Now (#112): runs beside other heavy jobs (never past an earlier job's paths).
    var startsNow = false

    init(_ operation: FileOperation) {
        self.operation = operation
        given = PathUse(operation).comparable()
        if case .command = operation {
            resolved = given // no paths: nothing to resolve
        }
        kind = switch operation {
        case .copy, .delete, .undo, .removeExactly: .heavy
        case .move: .undecided
        case .trash, .command, .rename, .renameAll, .newFolder: .quick
        }
    }

    var isReady: Bool {
        resolved != nil && kind != .undecided
    }

    /// Both forms of its paths: the path used to reach an item counts (renaming a link a copy
    /// goes through), and where it really is (renaming the folder the link leads to).
    var uses: PathUse {
        resolved.map(given.adding) ?? given
    }

    /// Whether this (earlier, unfinished) job is in the way of `later`. A job without paths (a
    /// command line) is never held up by paths.
    func blocks(_ later: Turn) -> Bool {
        if resolved == nil, !stalled {
            return !later.given.isEmpty
        }
        return uses.overlaps(later.uses)
    }
}

/// The paths a job uses (#112):
/// - `items` it reads, changes or makes — those, everything in them and everything above them;
/// - `into`: folders it only puts things into (a copy's destination) — only the folder itself and
///   the folders above it count, so a new folder made inside a copy's destination does not wait
///   for the copy, renaming the destination does;
/// - `outputs`: what it will make there (`destination/name`), and the names Keep Both would give
///   instead ("name 2.txt") — so a rename or Trash of the copy's target waits too.
struct PathUse: Equatable, Sendable {
    var items: [String] = []
    var into: [String] = []
    var outputs: [String] = []

    init(items: [String] = [], into: [String] = [], outputs: [String] = []) {
        self.items = items
        self.into = into
        self.outputs = outputs
    }

    init(_ operation: FileOperation) {
        func sibling(_ path: String, _ name: String) -> String {
            ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
        }
        switch operation {
        case let .copy(sources, folder), let .move(sources, folder):
            self.init(items: sources, into: [folder], outputs: sources.map {
                (folder as NSString).appendingPathComponent(($0 as NSString).lastPathComponent)
            })
        case let .trash(paths), let .delete(paths):
            self.init(items: paths)
        case .command:
            self.init() // a command line says nothing about what it touches
        case let .rename(path, name):
            self.init(items: [path, sibling(path, name)])
        case let .renameAll(renames):
            self.init(items: renames.flatMap { [$0.path, sibling($0.path, $0.newName)] })
        case let .newFolder(parent, name):
            self.init(items: [(parent as NSString).appendingPathComponent(name)])
        case let .undo(steps):
            // Where each item is now, and where it goes back to.
            self.init(items: steps.flatMap { step -> [String] in
                switch step {
                case let .move(source, target, _): [source, target]
                case let .rename(renames, _): renames.flatMap { [$0.path, sibling($0.path, $0.newName)] }
                case .trash, .makeFolder: step.paths
                }
            })
        case let .removeExactly(plan, _):
            self.init(items: [plan.root])
        }
    }

    /// The same paths as the file system names them, for comparing: the folders on the way
    /// resolved (symbolic links, "..", the case on disk), the last part as given (an item that is
    /// a link is the link) — a destination folder resolved whole — then in one case and one
    /// Unicode form, as APFS and HFS+ usually compare names. On a volume that tells case apart
    /// this only makes a job wait that need not, never one go ahead that must wait. Reads the
    /// disk: off the main thread.
    func resolved() -> PathUse {
        PathUse(
            items: items.map(Self.resolvingFolders),
            into: into.map { Self.comparable(FileOperations.realPath($0)) },
            outputs: outputs.map(Self.resolvingFolders)
        )
    }

    /// The paths as given, in one case and one Unicode form; no disk access.
    func comparable() -> PathUse {
        PathUse(items: items.map(Self.comparable), into: into.map(Self.comparable),
                outputs: outputs.map(Self.comparable))
    }

    var isEmpty: Bool {
        items.isEmpty && into.isEmpty && outputs.isEmpty
    }

    func adding(_ other: PathUse) -> PathUse {
        PathUse(items: items + other.items, into: into + other.into, outputs: outputs + other.outputs)
    }

    private static func resolvingFolders(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != path else {
            return comparable(path)
        }
        return comparable((FileOperations.realPath(parent) as NSString)
            .appendingPathComponent((path as NSString).lastPathComponent))
    }

    private static func comparable(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Whether one job's use gets in the way of the other's: an item the other also uses, inside
    /// it or holding it; a folder above (or at) the other's destination; or what the other will
    /// make (or a Keep Both name of it), or a folder holding that.
    func overlaps(_ other: PathUse) -> Bool {
        gets(in: other) || other.gets(in: self)
    }

    private func gets(in other: PathUse) -> Bool {
        items.contains { item in
            other.items.contains { Self.isSameOrInside(item, $0) || Self.isSameOrInside($0, item) }
                || other.into.contains { Self.isSameOrInside($0, item) }
                || other.outputs.contains { Self.isOutput(item, of: $0) || Self.isSameOrInside($0, item) }
        } || outputs.contains { output in
            // Two jobs making the same item, or one Keep Both would name like it (#112 review);
            // or one making a folder the other puts things into.
            other.outputs.contains { Self.isOutput(output, of: $0) || Self.isOutput($0, of: output) }
                || other.into.contains { Self.isSameOrInside($0, output) }
        }
    }

    /// `path` is `folder` or inside it.
    static func isSameOrInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// `path` is the output, a Keep Both name of it ("report 2.txt" for "report.txt"), or inside
    /// one of those.
    static func isOutput(_ path: String, of output: String) -> Bool {
        if isSameOrInside(path, output) {
            return true
        }
        let folder = (output as NSString).deletingLastPathComponent
        guard isSameOrInside(path, folder), path != folder else {
            return false
        }
        // The name directly inside the output's folder that `path` is, or is inside of.
        let relative = path.dropFirst(folder.hasSuffix("/") ? folder.count : folder.count + 1)
        let name = String(relative.prefix { $0 != "/" })
        let base = ((output as NSString).lastPathComponent as NSString).deletingPathExtension
        let pathExtension = (output as NSString).pathExtension
        let suffix = pathExtension.isEmpty ? "" : "." + pathExtension
        guard name.hasPrefix(base + " "), name.hasSuffix(suffix) else {
            return false
        }
        let number = name.dropFirst(base.count + 1).dropLast(suffix.count)
        return !number.isEmpty && number.allSatisfy(\.isNumber)
    }
}
