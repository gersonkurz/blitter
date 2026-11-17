import AppKit
@testable import Blitter
import SwiftUI
import Testing

/// #111: picking a toolbar button's icon from a grid instead of typing its name.
@MainActor
struct SymbolPickerTests {
    /// Every offered symbol is one this macOS has (a misspelt one would never show), once.
    @Test func everyOfferedSymbolExistsOnce() {
        #expect(SymbolPicker.available == SymbolPicker.symbols)
        #expect(Set(SymbolPicker.symbols).count == SymbolPicker.symbols.count)
        #expect(SymbolPicker.symbols.count >= 80)
    }

    /// The search keeps the symbols whose names contain every word, in any case; dots separate
    /// words as spaces do.
    @Test func theSearchMatchesEveryWord() {
        #expect(SymbolPicker.matching("") == SymbolPicker.available)
        #expect(SymbolPicker.matching("FOLDER").allSatisfy { $0.hasPrefix("folder") })
        #expect(SymbolPicker.matching("folder").contains("folder.badge.plus"))
        #expect(SymbolPicker.matching("doc plus") == ["doc.badge.plus"])
        #expect(SymbolPicker.matching("folder.plus") == ["folder.badge.plus"])
        #expect(SymbolPicker.matching("no-such-symbol").isEmpty)
    }

    /// Drawn for real, in a window as the popover shows it: the search field, Default and the
    /// grid lay out and draw. The picture is left in the temporary folder to look at.
    @Test func thePickerDraws() async throws {
        let view = NSHostingView(rootView: SymbolPicker(own: "trash", app: nil) { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width == 320)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "blitter-symbol-picker.png"))
    }
}
