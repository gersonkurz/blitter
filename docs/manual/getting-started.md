# Getting started

## Installing

Blitter runs on macOS 15 or later. Open the disk image and drag **Blitter** onto
**Applications**.

Blitter is signed with a Developer ID and notarized by Apple (since 0.4.0), so it opens like any
other app. Releases before 0.4.0 were not notarized: macOS stops those the first time you open
them; go to **System Settings → Privacy & Security** and click **Open Anyway** once.

Blitter is not sandboxed. To see the folders macOS protects (other apps' data, Mail, Safari),
give it Full Disk Access: **System Settings → Privacy & Security → Full Disk Access**, add
Blitter.

## The window

![The main window](images/main-window-light.png)

The window shows two [sides](sides.md) next to each other; its title says which version of
Blitter you run (for example **Blitter 0.4.0**; the pictures in this manual leave it out). Each
side has:

- a **folder tree** on the left: your Favorites, the mounted volumes, iCloud Drive and other
  cloud drives;
- **Back**, **Up** and **Forward** buttons, a **path field** you can type into, and the
  **⌄** button with the side's [recent folders](navigation.md#recent-folders);
- the **file list** of the side's folder;
- a **status line**: how many items, how many selected and their size, and the free space on
  the volume.

Below the sides, the [Find panel](find.md) appears while you search, and a strip shows
[running file operations](file-operations.md#jobs) and notices, such as a problem in the
settings file.

## First steps

- Click into a side, or press **Tab**, to make it the active side. The active side's path is
  drawn in the accent color.
- **Return** or a double-click opens a folder in its side, and a file with its app.
- **⌘↑** goes to the enclosing folder, **⌘[** back, **⌘]** forward.
- **Space** shows the selection in Quick Look.
- **F5** copies the selection to the other side, **F6** moves it there.
- Type a few letters in a list to [find a name](file-list.md#the-fast-filter).
- Right-click anything for its context menu.

## What Blitter remembers

Blitter starts where you left off: every [window](sides.md#several-windows) you had open, with
each side's folder, sort order, columns and recent folders, whether hidden files are shown, and
your Favorites. Each window's size and position and the splitters' positions are kept too.

Your settings are in `~/.config/blitter/settings.toml`. See [Settings](settings.md).

[Back to the contents](index.md)
