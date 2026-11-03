"""Blitter from Python: the automation socket of a running Blitter (#28).

Standard library only. Every change that touches files or opens something waits until you
click Allow in Blitter; see docs/AUTOMATION.md for the methods and their results.

    import blitter

    with blitter.Blitter() as app:
        left = app.state()["sides"]["left"]
        names = [e["name"] for e in app.all_entries("left") if e["name"].endswith(".log")]
        app.select("left", names)
        print(app.preview("move-to-trash", "left"))
        app.run("move-to-trash", "left")      # waits for Allow in Blitter

Copy this file (Blitter.app/Contents/Resources/python/blitter.py) next to your script. Importing
it from inside the app would make Python write a __pycache__ folder into the signed app; if you
point PYTHONPATH there anyway, set PYTHONDONTWRITEBYTECODE=1. As a tool in Blitter's settings, a
script gets BLITTER_SOCKET set:

    [tools.tidy-logs]
    title = "Tidy Logs"
    command = ["python3", "/Users/me/scripts/tidy_logs.py", "{paths}"]
    on = "selection"
"""

import json
import os
import socket

__all__ = ["Blitter", "BlitterError", "NotRunning", "DEFAULT_SOCKET"]

DEFAULT_SOCKET = os.path.expanduser("~/Library/Application Support/Blitter/automation.sock")


class BlitterError(Exception):
    """Blitter answered with an error: `code` and `message` as docs/AUTOMATION.md lists them
    (3 is denied in Blitter, 4 the side changed while Blitter asked, ...)."""

    def __init__(self, code, message):
        super().__init__(f"{message} (code {code})")
        self.code = code
        self.message = message


class NotRunning(BlitterError):
    """Nothing serves the socket: Blitter is not running."""

    def __init__(self, path):
        super().__init__(0, f"Blitter is not running (nothing serves {path})")
        self.path = path


class Blitter:
    """One connection to a running Blitter. Methods return the result as Python values and raise
    BlitterError for an error. `side` is "left" or "right"; None means the active side."""

    def __init__(self, path=None):
        self.path = path or os.environ.get("BLITTER_SOCKET") or DEFAULT_SOCKET
        self._socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self._socket.connect(self.path)
        except (FileNotFoundError, ConnectionRefusedError):
            self._socket.close()
            raise NotRunning(self.path) from None
        self._reader = self._socket.makefile("r", encoding="utf-8", newline="\n")
        self._next_id = 1

    def close(self):
        self._reader.close()
        self._socket.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def call(self, method, **params):
        """Any request; params left as None are not sent."""
        request_id = self._next_id
        self._next_id += 1
        params = {key: value for key, value in params.items() if value is not None}
        line = json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        self._socket.sendall(line.encode("utf-8") + b"\n")
        while True:
            answer = self._reader.readline()
            if not answer:
                raise BlitterError(-1, f"the connection to Blitter ended before it answered {method!r}")
            reply = json.loads(answer)
            if reply.get("id") != request_id:
                continue  # an answer to something else
            if "error" in reply:
                raise BlitterError(reply["error"].get("code"), reply["error"].get("message"))
            return reply.get("result")

    def state(self):
        return self.call("state")

    def listing(self, side=None, offset=None, limit=None):
        return self.call("listing", side=side, offset=offset, limit=limit)

    def all_entries(self, side=None, page=1000):
        """Every item the side lists, page by page (`listing` gives one page, 1000 by default)."""
        offset = 0
        while True:
            result = self.listing(side, offset=offset, limit=page)
            entries = result["entries"]
            yield from entries
            offset += len(entries)
            if not entries or offset >= result["total"]:
                return

    def actions(self, side=None):
        return self.call("actions", side=side)

    def navigate(self, side, path):
        return self.call("navigate", side=side, path=path)

    def select(self, side, names):
        return self.call("select", side=side, names=list(names))

    def activate(self, side):
        return self.call("activate", side=side)

    def preview(self, action, side=None):
        return self.call("preview", action=action, side=side)

    def run(self, action, side=None):
        """Runs an action; one that changes files or opens something waits for Allow."""
        return self.call("run", action=action, side=side)
