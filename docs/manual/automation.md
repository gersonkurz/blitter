# Automation

While Blitter runs, other programs can drive it: read what each side shows, go to folders,
select items, and run actions. That is how an AI assistant such as Claude or Codex, a script, or
the `blitter` command-line tool works with Blitter.

**Nothing changes without you.** An action that changes files or opens something outside
Blitter runs only after you click **Allow** in a sheet in Blitter's window. The sheet says which
program asks and exactly what will happen; **Deny** is the default button. Deletes that skip the
Trash, the clipboard and renaming are not offered at all.

## The blitter tool

Blitter carries a command-line tool at `Blitter.app/Contents/Helpers/blitter`:

```
blitter state
blitter listing left --limit 50
blitter select left notes.txt todo.txt
blitter preview move-to-trash left
blitter run move-to-trash left        # waits for Allow in Blitter
```

Each call prints its result as JSON.

## AI assistants (MCP)

`blitter mcp` is an MCP server. To use it with Claude Code:

```
claude mcp add blitter -- /Applications/Blitter.app/Contents/Helpers/blitter mcp
```

With Codex, in `~/.codex/config.toml`:

```toml
[mcp_servers.blitter]
command = "/Applications/Blitter.app/Contents/Helpers/blitter"
args = ["mcp"]
```

## Python

`Blitter.app/Contents/Resources/python/blitter.py` is a module for Python scripts. Copy it next
to your script:

```python
import blitter

with blitter.Blitter() as app:
    names = [e["name"] for e in app.all_entries("left") if e["name"].endswith(".log")]
    app.select("left", names)
    app.run("move-to-trash", "left")      # waits for Allow in Blitter
```

A script becomes an action of its own as a [tool](tools-and-menus.md#tools) with a command line,
e.g. `command = ["python3", "/Users/me/scripts/tidy_logs.py", "{paths}"]`.

## The details

The requests, their answers, the error codes and how the socket is protected are in
[the automation reference](https://github.com/gersonkurz/blitter/blob/main/docs/AUTOMATION.md).

[Back to the contents](index.md)
