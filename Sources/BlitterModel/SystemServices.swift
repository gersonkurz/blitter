/// What the Model asks of the rest of macOS: everything that needs AppKit, which the Model must
/// not import. The app fills these in, tests record the calls. Each one is reached through a
/// command, so the future MCP server gets them too.
@MainActor
public struct SystemServices {
    /// Open a file or package with its default app.
    public var open: (String) -> Void = { _ in }
    /// Show items selected in a Finder window.
    public var reveal: ([SelectedItem]) -> Void = { _ in }
    /// Show or hide Quick Look for the side's selection.
    public var togglePreview: (Side) -> Void = { _ in }
    /// Open a text file for editing (the settings file).
    public var editText: (String) -> Void = { _ in }
    /// Put items on the clipboard as files, as Finder does.
    public var copyToPasteboard: ([SelectedItem]) -> Void = { _ in }

    public init() {}
}
