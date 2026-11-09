# Automation socket

While Blitter runs, it answers requests on a private Unix socket. The `blitter` command-line tool,
its MCP server and the Python package all talk to Blitter this way (#27, #58).

- **Socket:** `~/Library/Application Support/Blitter/automation.sock`.
  - The folder must be yours and not a link; Blitter makes it 0700. The socket is 0600.
  - Every client that doesn't run as the same user is refused.
  - Whoever holds `automation.sock.lock` owns the socket. Blitter replaces a socket left by a
    Blitter that is gone, but never anything that isn't a socket.
- **Framing:** JSON-RPC 2.0, one request per line (at most 1 MiB), answered with one line, in
  order.
  - A client may send the next request before the answer arrives, and may close its sending half
    and still read the answers.
  - A request without an `id` is a notification: it is carried out and not answered.
  - Batches (arrays) are not supported.
- **Changes need you:** whatever changes files or opens something outside Blitter runs only after
  you click **Allow** in Blitter. A sheet shows exactly what will happen. Deny is the default
  button.
- **What isn't offered:** deletes that skip the Trash, clipboard actions, and edits in place
  (rename, batch rename).
- **One instance:** a second Blitter leaves the socket to the first one and shows a notice.

## Requests

```json
{"jsonrpc": "2.0", "id": 1, "method": "state", "params": {}}
```

`side` is `"left"` or `"right"`; without it, the active side.

| Method | Params | Result |
|---|---|---|
| `hello` | | `{"app": "Blitter", "protocol": 1}` |
| `state` | | `activeSide`, `showsHiddenFiles`, `sides.left` / `sides.right` (see below) |
| `listing` | `side`, `offset` (0), `limit` (1000, at most 5000) | `location`, `total`, `offset`, `entries`: `name`, `kind` (`file`, `folder`, `link`, `other`), `size`, `modified` (ISO 8601), `hidden`, and `folderSize` once measured |
| `actions` | `side` | the actions offered here: `id`, `title`, `effect`, `runnable` (on that side, now) |
| `navigate` | `side`, `path` | the side (as in `state`) once the folder was read (or failed), at most 30 s later |
| `select` | `side`, `names` | `selection`, and `notListed` for the names the listing doesn't have |
| `activate` | `side` | `activeSide` |
| `preview` | `action`, `side` | what the action would do now: `items`, `destination`, `detail`, `effect`, `needsConfirmation`; nothing happens |
| `run` | `action`, `side` | `done`, and `jobs`: each job's `state` (`finished`, `cancelled`) and `errors` (`path`, `message`) |
| `showMenu` | `menu` (`context`, `File`, `Edit`, `View`, `Go`, `Tools`), `side`, `seconds` (5, at most 30) | `menu`, `side`, `seconds`; the menu opens over the side's list right after the answer and closes after `seconds` (for the manual's pictures) |

**A side** in `state` and `navigate`:
- `location`: where it is going;
- `listedLocation`: what the listing shows;
- `status` (`loading`, `loaded`, `failed`), with `error` when it failed;
- `selection` (names);
- `sort` (`column`, `ascending`);
- `items` (how many are listed);
- `search` while it shows search results.

Names in `listing`, `select` and `selection` are as the list shows them. For search results that
is the path below the searched folder.

## Effects and confirmation

Each action has an `effect`:
- `view`: changes only what Blitter shows, or opens one of its own windows. For example Quick
  Look, Calculate Folder Sizes, Git Log. It runs at once.
- `opens`: opens a file or an app, or shows something in the Finder. For example Open, Reveal in
  Finder, Compare, the tools that open an app.
- `changes`: changes files, or runs a command line. For example Copy / Move to Other Side, Move to
  Trash, New Folder, Undo, the tools with a command line.

**Undo** (`undo`) takes back the last file operation, whoever started it: one done in Blitter,
or over the socket. Its preview names the items it acts on and, in `detail`, what it undoes
("Undo Move to Trash"). It is runnable only while there is something to undo, on either side.

`run` with `opens` or `changes` shows the preview in a sheet, naming the client process. It waits
for your answer.

**When you click Allow, the preview must still hold.** If the side changed meanwhile, for
example a different selection, the request fails with code 4 and nothing runs; ask for a preview
again. If the client disconnects while the sheet is open, the sheet closes and nothing runs. Only
one question is open at a time.

## Errors

The standard JSON-RPC codes:

| Code | Meaning |
|---|---|
| -32700 | not JSON |
| -32600 | not a JSON-RPC 2.0 request (version, method, id), or a batch |
| -32601 | unknown method |
| -32602 | bad params |

Blitter's own codes:

| Code | Meaning |
|---|---|
| 1 | the action isn't offered over the socket |
| 2 | it doesn't fit the side now (for example nothing selected) |
| 3 | denied in Blitter, or the client disconnected while asked |
| 4 | the side changed while Blitter asked |
| 5 | Blitter is already asking about another change |

## The blitter tool and MCP

The app carries a command-line tool at `Blitter.app/Contents/Helpers/blitter`. Each call is one
request, and the result is printed as JSON. Exit status:
- 0: done;
- 1: an error from Blitter, or a wrong command line;
- 2: Blitter is not running.

`BLITTER_SOCKET` points it at another socket.

```
blitter state
blitter listing left --limit 50
blitter select left notes.txt todo.txt
blitter preview move-to-trash left
blitter run move-to-trash left        # waits for Allow in Blitter
blitter call navigate '{"side": "right", "path": "~/Downloads"}'
```

`blitter mcp` is an MCP server on stdin and stdout, with one tool per method above. Each tool's
arguments are that method's params.

To register it with Claude Code:

```
claude mcp add blitter -- /Applications/Blitter.app/Contents/Helpers/blitter mcp
```

With Codex, in `~/.codex/config.toml`:

```toml
[mcp_servers.blitter]
command = "/Applications/Blitter.app/Contents/Helpers/blitter"
args = ["mcp"]
```

If Blitter isn't running, a tool call says so and returns an error result. The server keeps one
connection to Blitter and reconnects once if Blitter was restarted. A `run` that needs Allow
waits for the answer; other calls wait behind it.

## Python

`Blitter.app/Contents/Resources/python/blitter.py` is a single module that uses only the
standard library (#28). **Copy it next to your script.** Importing it from inside the app would
make Python write a `__pycache__` folder into the signed app. If you point `PYTHONPATH` there
anyway, set `PYTHONDONTWRITEBYTECODE=1`.

```python
import blitter

with blitter.Blitter() as app:
    names = [e["name"] for e in app.all_entries("left") if e["name"].endswith(".log")]
    app.select("left", names)
    print(app.preview("move-to-trash", "left"))
    app.run("move-to-trash", "left")      # waits for Allow in Blitter
```

**Methods:** `Blitter` has a method per request: `state`, `listing`, `actions`, `navigate`,
`select`, `activate`, `preview`, `run`, plus `call` for any request. A param left as `None` is
not sent. `listing` is one page (1000 items by default); `all_entries(side)` goes through every
page.

**Errors:** an error from Blitter raises `BlitterError` (with `code` and `message`), and a
missing Blitter raises `NotRunning`.

**Scripts as actions:** a script becomes an action of its own as a tool in the settings file.
Tools' command lines get `BLITTER_SOCKET`, so the script reaches the Blitter that ran it:

```toml
[tools.tidy-logs]
title = "Tidy Logs"
command = ["python3", "/Users/me/scripts/tidy_logs.py", "{paths}"]
on = "selection"
```
