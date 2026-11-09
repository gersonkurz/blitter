import AppKit
import BlitterModel
import SwiftUI

// The Settings window's tabs (#64), each editing its part of the draft.

struct FilesSettings: View {
    @Binding var draft: BlitterModel.Settings
    /// The moment the date preview shows: now, or a fixed one for the manual's screenshots.
    let now: Date

    var body: some View {
        Form {
            TextField("Date format", text: $draft.dateFormat)
            Text("Now: " + Formatting.dateFormatter(draft.dateFormat).string(from: now))
                .font(.caption).foregroundStyle(.secondary)
            Section("Columns of a new file list") {
                ForEach(ListColumn.allCases.filter { $0 != .name }, id: \.self) { column in
                    Toggle(FileListViewController.title(of: column), isOn: Binding(
                        get: { draft.columns.contains(column) },
                        set: { isOn in
                            if isOn {
                                draft.columns.insert(column)
                            } else {
                                draft.columns.remove(column)
                            }
                        }
                    ))
                }
            }
            Section {
                Toggle("Ask before Delete Immediately", isOn: $draft.confirmDelete)
                Toggle("Color git working copies by their state", isOn: $draft.gitColors)
            }
        }
        .formStyle(.grouped)
    }
}

struct FontSettingsView: View {
    @Binding var font: FontSettings

    var body: some View {
        Form {
            Picker("Font", selection: family(\.face)) {
                Text("System").tag("system")
                Divider()
                ForEach(SettingsWindowModel.families.all, id: \.self) { Text($0).tag($0) }
            }
            Picker("Fixed-width font (dates, permissions)", selection: family(\.mono)) {
                Text("System").tag("system")
                Divider()
                ForEach(SettingsWindowModel.families.fixedWidth, id: \.self) { Text($0).tag($0) }
            }
            Stepper(value: $font.size, in: FontSettings.sizes, step: 1) {
                Text("Size: \(font.size.formatted()) pt")
            }
            Text("⌘+ and ⌘− (or Ctrl and the mouse wheel over a list) change the size too.")
                .font(.caption).foregroundStyle(.secondary)
            let fonts = ListFonts.current(font)
            Section("Preview") {
                Text("notes.txt   Documents   Blitter.app").font(Font(fonts.text))
                Text("05.11.2026 14:30   rwxr-xr-x").font(Font(fonts.mono))
            }
        }
        .formStyle(.grouped)
    }

    /// "system" in the picker is nil in the settings.
    private func family(_ entry: WritableKeyPath<FontSettings, String?>) -> Binding<String> {
        Binding(get: { font[keyPath: entry] ?? "system" },
                set: { font[keyPath: entry] = $0 == "system" ? nil : $0 })
    }
}

struct CompareSettings: View {
    @Binding var tool: [String]?

    var body: some View {
        Form {
            Picker("Compare with", selection: Binding(
                get: { tool == nil },
                set: { tool = $0 ? nil : ["bcomp", "{left}", "{right}"] }
            )) {
                Text("Beyond Compare if installed, else FileMerge").tag(true)
                Text("A command line").tag(false)
            }
            .pickerStyle(.radioGroup)
            if tool != nil {
                Section("The command line, one argument per line; {left} and {right} are the two items") {
                    ArgumentLinesEditor(command: Binding(get: { tool ?? [] }, set: { tool = $0 }))
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A command line, one argument per line (#40, #65). Only a change the user typed is written
/// back, so showing a command never changes it; one with an empty argument or a line break in an
/// argument is shown, not edited: that one is left to the settings file.
struct ArgumentLinesEditor: View {
    @Binding var command: [String]
    /// The editor's text, and the command it was last made from or turned into.
    @State private var lines = ""
    @State private var shown: [String]?

    static func arguments(_ lines: String) -> [String] {
        lines.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    static func fitsLines(_ command: [String]) -> Bool {
        !command.contains { $0.isEmpty || $0.contains("\n") }
    }

    var body: some View {
        if Self.fitsLines(command) {
            TextEditor(text: $lines)
                .font(.body.monospaced())
                .frame(minHeight: 80)
                .onAppear { show(command) }
                .onChange(of: lines) {
                    // An empty line while typing is not yet an argument.
                    guard Self.arguments(lines) != shown else {
                        return
                    }
                    shown = Self.arguments(lines)
                    command = Self.arguments(lines)
                }
                .onChange(of: command) {
                    if command != shown {
                        show(command)
                    }
                }
        } else {
            Text(command.map { "“\($0)”" }.joined(separator: " ")).font(.body.monospaced())
            Text("It has an empty argument or one with a line break: change it in the settings file.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func show(_ command: [String]) {
        shown = command
        lines = command.joined(separator: "\n")
    }
}
