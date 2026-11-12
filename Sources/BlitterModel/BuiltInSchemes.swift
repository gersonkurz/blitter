// Generated from the owner's Base16 scheme files (tinted-theming YAML, #73); each scheme's
// author is named with it. Two lines of eight colors: base00 … base07, then base08 … base0F.

/// A scheme that comes with Blitter (#73): its name in the settings file, its title, whether it is
/// for dark mode, and its colors.
public struct BuiltInScheme: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let author: String
    public let isDark: Bool
    public let scheme: Base24Scheme
}

public extension BuiltInScheme {
    /// What a mode's list offers (#78): that mode's schemes only, and the chosen one even if it is
    /// the other mode's (set so in the file), so the choice is never out of sight.
    static func choices(dark isDark: Bool, chosen: String) -> [BuiltInScheme] {
        all.filter { $0.isDark == isDark || $0.id == chosen }
    }

    // swiftlint:disable force_unwrapping
    /// Light schemes and dark schemes, each by title.
    static let all: [BuiltInScheme] = [
        BuiltInScheme(
            id: "default-dark",
            title: "Default Dark",
            author: "Chris Kempson",
            isDark: true,
            scheme: Base24Scheme([
                "181818", "282828", "383838", "585858", "b8b8b8", "d8d8d8", "e8e8e8", "f8f8f8",
                "ab4642", "dc9656", "f7ca88", "a1b56c", "86c1b9", "7cafc2", "ba8baf", "a16946",
            ])!
        ),
        BuiltInScheme(
            id: "default-light",
            title: "Default Light",
            author: "Chris Kempson",
            isDark: false,
            scheme: Base24Scheme([
                "f8f8f8", "e8e8e8", "d8d8d8", "b8b8b8", "585858", "383838", "282828", "181818",
                "ab4642", "dc9656", "f7ca88", "a1b56c", "86c1b9", "7cafc2", "ba8baf", "a16946",
            ])!
        ),
        BuiltInScheme(
            id: "catppuccin-latte",
            title: "Catppuccin Latte",
            author: "https://github.com/catppuccin/catppuccin",
            isDark: false,
            scheme: Base24Scheme([
                "eff1f5", "e6e9ef", "ccd0da", "bcc0cc", "acb0be", "4c4f69", "dc8a78", "7287fd",
                "d20f39", "fe640b", "df8e1d", "40a02b", "179299", "1e66f5", "8839ef", "dd7878",
            ])!
        ),
        BuiltInScheme(
            id: "catppuccin-macchiato",
            title: "Catppuccin Macchiato",
            author: "https://github.com/catppuccin/catppuccin",
            isDark: true,
            scheme: Base24Scheme([
                "24273a", "1e2030", "363a4f", "494d64", "5b6078", "cad3f5", "f4dbd6", "b7bdf8",
                "ed8796", "f5a97f", "eed49f", "a6da95", "8bd5ca", "8aadf4", "c6a0f6", "f0c6c6",
            ])!
        ),
        BuiltInScheme(
            id: "catppuccin-mocha",
            title: "Catppuccin Mocha",
            author: "https://github.com/catppuccin/catppuccin",
            isDark: true,
            scheme: Base24Scheme([
                "1e1e2e", "181825", "313244", "45475a", "585b70", "cdd6f4", "f5e0dc", "b4befe",
                "f38ba8", "fab387", "f9e2af", "a6e3a1", "94e2d5", "89b4fa", "cba6f7", "f2cdcd",
            ])!
        ),
        BuiltInScheme(
            id: "dracula",
            title: "Dracula",
            author: "clach04 (https://github.com/clach04)",
            isDark: true,
            scheme: Base24Scheme([
                "282a36", "21222c", "44475a", "6272a4", "9ea8c7", "f8f8f2", "f8f8f2", "ffffff",
                "ff5555", "ffb86c", "f1fa8c", "50fa7b", "8be9fd", "bd93f9", "ff79c6", "993333",
            ])!
        ),
        BuiltInScheme(
            id: "everforest-dark-hard",
            title: "Everforest Dark Hard",
            author: "Sainnhe Park (https://github.com/sainnhe)",
            isDark: true,
            scheme: Base24Scheme([
                "272e33", "2e383c", "414b50", "859289", "9da9a0", "d3c6aa", "edeada", "fffbef",
                "e67e80", "e69875", "dbbc7f", "a7c080", "83c092", "7fbbb3", "d699b6", "9da9a0",
            ])!
        ),
        BuiltInScheme(
            id: "gruvbox-dark-hard",
            title: "Gruvbox dark, hard",
            author: "Dawid Kurek (dawikur@gmail.com), morhetz (https://github.com/morhetz/gruvbox)",
            isDark: true,
            scheme: Base24Scheme([
                "1d2021", "3c3836", "504945", "665c54", "bdae93", "d5c4a1", "ebdbb2", "fbf1c7",
                "fb4934", "fe8019", "fabd2f", "b8bb26", "8ec07c", "83a598", "d3869b", "d65d0e",
            ])!
        ),
        BuiltInScheme(
            id: "gruvbox-light-hard",
            title: "Gruvbox light, hard",
            author: "Dawid Kurek (dawikur@gmail.com), morhetz (https://github.com/morhetz/gruvbox)",
            isDark: false,
            scheme: Base24Scheme([
                "f9f5d7", "ebdbb2", "d5c4a1", "bdae93", "665c54", "504945", "3c3836", "282828",
                "9d0006", "af3a03", "b57614", "79740e", "427b58", "076678", "8f3f71", "d65d0e",
            ])!
        ),
        BuiltInScheme(
            id: "monokai",
            title: "Monokai",
            author: "Wimer Hazenberg (http://www.monokai.nl)",
            isDark: true,
            scheme: Base24Scheme([
                "272822", "383830", "49483e", "75715e", "a59f85", "f8f8f2", "f5f4f1", "f9f8f5",
                "f92672", "fd971f", "f4bf75", "a6e22e", "a1efe4", "66d9ef", "ae81ff", "cc6633",
            ])!
        ),
        BuiltInScheme(id: "nord", title: "Nord", author: "arcticicestudio", isDark: true, scheme: Base24Scheme([
            "2e3440", "3b4252", "434c5e", "4c566a", "d8dee9", "e5e9f0", "eceff4", "8fbcbb",
            "bf616a", "d08770", "ebcb8b", "a3be8c", "88c0d0", "81a1c1", "b48ead", "5e81ac",
        ])!),
        BuiltInScheme(
            id: "one-light",
            title: "One Light",
            author: "Daniel Pfeifer (http://github.com/purpleKarrot)",
            isDark: false,
            scheme: Base24Scheme([
                "fafafa", "f0f0f1", "e5e5e6", "a0a1a7", "696c77", "383a42", "202227", "090a0b",
                "ca1243", "d75f00", "c18401", "50a14f", "0184bc", "4078f2", "a626a4", "986801",
            ])!
        ),
        BuiltInScheme(
            id: "onedark",
            title: "OneDark",
            author: "Lalit Magant (http://github.com/tilal6991)",
            isDark: true,
            scheme: Base24Scheme([
                "282c34", "353b45", "3e4451", "545862", "565c64", "abb2bf", "b6bdca", "c8ccd4",
                "e06c75", "d19a66", "e5c07b", "98c379", "56b6c2", "61afef", "c678dd", "be5046",
            ])!
        ),
        BuiltInScheme(
            id: "rose-pine-dawn",
            title: "Rose Pine Dawn",
            author: "Emilia Dunfelt <edun@dunfelt.se>",
            isDark: false,
            scheme: Base24Scheme([
                "faf4ed", "fffaf3", "f2e9de", "9893a5", "797593", "575279", "575279", "cecacd",
                "b4637a", "ea9d34", "d7827e", "286983", "56949f", "907aa9", "ea9d34", "cecacd",
            ])!
        ),
        BuiltInScheme(
            id: "rose-pine",
            title: "Rose Pine",
            author: "Emilia Dunfelt <edun@dunfelt.se>",
            isDark: true,
            scheme: Base24Scheme([
                "191724", "1f1d2e", "26233a", "6e6a86", "908caa", "e0def4", "e0def4", "524f67",
                "eb6f92", "f6c177", "ebbcba", "31748f", "9ccfd8", "c4a7e7", "f6c177", "524f67",
            ])!
        ),
        BuiltInScheme(
            id: "solarized-dark",
            title: "Solarized Dark",
            author: "Ethan Schoonover (modified by aramisgithub)",
            isDark: true,
            scheme: Base24Scheme([
                "002b36", "073642", "586e75", "657b83", "839496", "93a1a1", "eee8d5", "fdf6e3",
                "dc322f", "cb4b16", "b58900", "859900", "2aa198", "268bd2", "6c71c4", "d33682",
            ])!
        ),
        BuiltInScheme(
            id: "solarized-light",
            title: "Solarized Light",
            author: "Ethan Schoonover (modified by aramisgithub)",
            isDark: false,
            scheme: Base24Scheme([
                "fdf6e3", "eee8d5", "93a1a1", "839496", "657b83", "586e75", "073642", "002b36",
                "dc322f", "cb4b16", "b58900", "859900", "2aa198", "268bd2", "6c71c4", "d33682",
            ])!
        ),
        BuiltInScheme(
            id: "tokyo-night-dark",
            title: "Tokyo Night Dark",
            author: "Michaël Ball",
            isDark: true,
            scheme: Base24Scheme([
                "1a1b26", "16161e", "2f3549", "444b6a", "787c99", "a9b1d6", "cbccd1", "d5d6db",
                "c0caf5", "a9b1d6", "0db9d7", "9ece6a", "b4f9f8", "2ac3de", "bb9af7", "f7768e",
            ])!
        ),
        BuiltInScheme(
            id: "tomorrow-night-blue",
            title: "Tomorrow Night Blue",
            author: "Chris Kempson (http://chriskempson.com)",
            isDark: true,
            scheme: Base24Scheme([
                "002451", "00346e", "003f8e", "7285b7", "a3b2d6", "ffffff", "ffffff", "ffffff",
                "ff9da4", "ffc58f", "ffeead", "d1f1a9", "99ffff", "bbdaff", "ebbbff", "d18f52",
            ])!
        ),
        BuiltInScheme(
            id: "tomorrow-night-eighties",
            title: "Tomorrow Night Eighties",
            author: "Chris Kempson (http://chriskempson.com)",
            isDark: true,
            scheme: Base24Scheme([
                "2d2d2d", "393939", "515151", "999999", "b4b7b4", "cccccc", "e0e0e0", "ffffff",
                "f2777a", "f99157", "ffcc66", "99cc99", "66cccc", "6699cc", "cc99cc", "a3685a",
            ])!
        ),
        BuiltInScheme(
            id: "tomorrow-night",
            title: "Tomorrow Night",
            author: "Chris Kempson (http://chriskempson.com)",
            isDark: true,
            scheme: Base24Scheme([
                "1d1f21", "282a2e", "373b41", "969896", "b4b7b4", "c5c8c6", "e0e0e0", "ffffff",
                "cc6666", "de935f", "f0c674", "b5bd68", "8abeb7", "81a2be", "b294bb", "a3685a",
            ])!
        ),
        BuiltInScheme(
            id: "tomorrow",
            title: "Tomorrow",
            author: "Chris Kempson (http://chriskempson.com)",
            isDark: false,
            scheme: Base24Scheme([
                "ffffff", "e0e0e0", "c5c8c6", "b4b7b4", "969896", "373b41", "282a2e", "1d1f21",
                "c82829", "f5871f", "eab700", "718c00", "3e999f", "4271ae", "8959a8", "a3685a",
            ])!
        ),
    ].sorted { ($0.isDark ? 1 : 0, $0.title) < ($1.isDark ? 1 : 0, $1.title) }
    // swiftlint:enable force_unwrapping
}
