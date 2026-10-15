import BlitterCore

/// One of the two side-by-side listers.
public enum Side: CaseIterable, Sendable {
    case left
    case right

    /// The side across from this one. When this side is the source, that is the destination.
    public var opposite: Side {
        switch self {
        case .left: .right
        case .right: .left
        }
    }
}

/// State of a single side.
public struct SideState: Equatable, Sendable {
    /// Absolute path of the folder this side shows.
    public var location: String
}

/// Everything the user can do. The UI (and later the MCP server) changes state only through these.
public enum Command: Sendable {
    /// Make the other side the active (source) side.
    case switchActiveSide
}

/// The state of the whole window: both sides and which of them is active.
@MainActor
public final class Workspace {
    public private(set) var left: SideState
    public private(set) var right: SideState

    /// The source side. File operations go from here to the opposite side.
    public private(set) var activeSide: Side = .left

    /// Called after every command that changed state.
    public var onChange: (() -> Void)?

    public init(initialLocation: String = UserPaths.home) {
        left = SideState(location: initialLocation)
        right = SideState(location: initialLocation)
    }

    public func state(of side: Side) -> SideState {
        switch side {
        case .left: left
        case .right: right
        }
    }

    public func perform(_ command: Command) {
        switch command {
        case .switchActiveSide:
            activeSide = activeSide.opposite
        }
        onChange?()
    }
}
