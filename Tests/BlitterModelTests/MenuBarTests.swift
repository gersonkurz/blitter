@testable import BlitterModel
import Testing

/// The menu bar's action items in the settings file (#24).
struct MenuBarTests {
    @Test func shortcutsAreRead() {
        #expect(Shortcut("shift+cmd+n") == Shortcut(.character("n"), [.shift, .command]))
        #expect(Shortcut("F2") == Shortcut(.function(2)))
        #expect(Shortcut("opt+cmd+backspace") == Shortcut(.backspace, [.option, .command]))
        #expect(Shortcut("⌃⇧⌥⌘ + Return".replacingOccurrences(of: "⌃⇧⌥⌘ ", with: "ctrl+shift+alt+command"))
            == Shortcut(.returnKey, [.control, .shift, .option, .command]))
        #expect(Shortcut("cmd+,") == Shortcut(.character(","), [.command]))
        #expect(Shortcut("cmd+plus") == Shortcut(.character("+"), [.command]))
        #expect(Shortcut("f") == Shortcut(.character("f")))
        for bad in ["", "cmd+", "cmd++", "hyper+n", "cmd+cmd+n", "f21", "f0", "cmd+nn", "cmd+ "] {
            #expect(Shortcut(bad) == nil, "\(bad)")
        }
    }

    @Test func theDefaultsAreTheOldMenusAndTheDefaultFileSpellsThemOut() {
        let bar = Settings().menuBar
        let file = bar.file.compactMap { item -> String? in
            if case let .action(id, _, _) = item {
                id
            } else {
                nil
            }
        }
        #expect(file == ["new-folder", "rename", "copy-to-other-side", "move-to-other-side", "reveal-in-finder",
                         "compare-files", "compare-folders", "move-to-trash", "delete-immediately",
                         "delete-immediately-without-asking"])
        #expect(bar.file.last == .action("delete-immediately-without-asking",
                                         shortcut: Shortcut(.backspace, [.shift, .option, .command]), alternate: true))
        #expect(bar.edit.count == 2)
        #expect(Settings.parse(Settings.defaultFile) == (Settings(), []))
    }

    @Test func aMenuOfTheUsersOwnWithATool() {
        let (settings, problems) = Settings.parse("""
        [menu_bar]
        file = ["open", "-", { action = "preview", key = "cmd+p" }, { action = "copy", alternate = false }]
        edit = []
        [tools.preview]
        app = "Preview"
        """)
        #expect(problems.isEmpty)
        #expect(settings.menuBar.file == [
            .action("open", shortcut: nil, alternate: false), .separator,
            .action("preview", shortcut: Shortcut(.character("p"), [.command]), alternate: false),
            .action("copy", shortcut: nil, alternate: false),
        ])
        #expect(settings.menuBar.edit.isEmpty)
    }

    @Test func problemsAreReported() {
        let (unknown, unknownProblems) = Settings.parse("[menu_bar]\nfile = [\"open\", \"brew-coffee\"]\n")
        #expect(unknown.menuBar.file == [.action("open", shortcut: nil, alternate: false)])
        #expect(unknownProblems.count == 1 && unknownProblems[0].contains("brew-coffee"))

        let (bad, badProblems) = Settings.parse("""
        [menu_bar]
        file = [{ action = "open", key = "hyper+o" }]
        edit = [{ action = "copy", alternate = "yes" }, { action = "copy", colour = "red" }, 3]
        view = []
        """)
        #expect(bad.menuBar == Settings().menuBar) // both lists keep the defaults
        #expect(badProblems.count == 5)
        #expect(badProblems.contains { $0.contains("menu_bar.view") })
    }

    /// TOMLKit cuts keys at an escaped NUL; a cut key must be reported, not read as "no shortcut".
    @Test func keysWithANulAreReportedAndTheMenuKept() {
        for key in ["key", "alternate", "action"] {
            let (settings, problems) = Settings.parse("""
            [menu_bar]
            file = [{ action = "open", "\(key)\\u0000x" = "cmd+o" }]
            """)
            #expect(settings.menuBar == Settings().menuBar, "\(key)")
            #expect(problems.count == 1 && problems[0].contains("menu_bar.file"), "\(key)")
        }
    }
}
