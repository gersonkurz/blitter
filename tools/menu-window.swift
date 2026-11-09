// Where the menu a process has open is on screen (#69), as "x,y,width,height" for
// `screencapture -R` (`-l` does not take a menu window on its own); used by
// `just menu-screenshots`. Exits 2 without Screen Recording permission (the pictures would be
// empty), 1 if the process has no menu open.
import CoreGraphics
import Foundation

guard CGPreflightScreenCaptureAccess() else {
    FileHandle.standardError.write(Data("""
    Taking pictures of Blitter's menus needs Screen Recording: System Settings → Privacy & Security →
    Screen & System Audio Recording, turn it on for this terminal app, then run it again.

    """.utf8))
    exit(2)
}

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: menu-window <pid>\n".utf8))
    exit(64)
}

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let menu = windows.first { window in
    (window[kCGWindowOwnerPID as String] as? Int32) == pid && (window[kCGWindowLayer as String] as? Int ?? 0) > 0
}

guard let bounds = menu?[kCGWindowBounds as String] as? [String: Double],
      let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"]
else {
    exit(1)
}

print([x, y, width, height].map { String(Int($0)) }.joined(separator: ","))
