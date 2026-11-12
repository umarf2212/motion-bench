"""Serve Motion Bench locally and post mouse movement events on macOS."""

import ctypes as C
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sys
from threading import Lock, Thread


HOST = "127.0.0.1"
PORT = 8765
ADDRESS = f"{HOST}:{PORT}"
ORIGIN = f"http://{ADDRESS}"
ROOT = Path(__file__).resolve().parent
FILES = {
    "/": ("index.html", "text/html"),
    "/index.html": ("index.html", "text/html"),
    "/viewer.js": ("viewer.js", "text/javascript"),
    "/README.md": ("README.md", "text/plain"),
}
MOUSE_MOVED = 5
HID_EVENT_TAP = 0


class Point(C.Structure):
    _fields_ = [("x", C.c_double), ("y", C.c_double)]


class MacCursor:
    def __init__(self):
        frameworks = "/System/Library/Frameworks"
        graphics = C.CDLL(f"{frameworks}/CoreGraphics.framework/CoreGraphics")
        foundation = C.CDLL(f"{frameworks}/CoreFoundation.framework/CoreFoundation")

        self.allowed = graphics.CGPreflightPostEventAccess
        self.allowed.argtypes = []
        self.allowed.restype = C.c_bool

        self.request_access = graphics.CGRequestPostEventAccess
        self.request_access.argtypes = []
        self.request_access.restype = C.c_bool
        self.permission_lock = Lock()
        self.permission_requested = False

        self.current_event = graphics.CGEventCreate
        self.current_event.argtypes = [C.c_void_p]
        self.current_event.restype = C.c_void_p

        self.location = graphics.CGEventGetLocation
        self.location.argtypes = [C.c_void_p]
        self.location.restype = Point

        self.mouse_event = graphics.CGEventCreateMouseEvent
        self.mouse_event.argtypes = [C.c_void_p, C.c_uint32, Point, C.c_uint32]
        self.mouse_event.restype = C.c_void_p

        self.post = graphics.CGEventPost
        self.post.argtypes = [C.c_uint32, C.c_void_p]
        self.post.restype = None

        self.release = foundation.CFRelease
        self.release.argtypes = [C.c_void_p]
        self.release.restype = None

    def request_permission_once(self):
        with self.permission_lock:
            if self.permission_requested:
                return
            self.permission_requested = True
            # macOS can wait for the user. Keep the HTTP response independent.
            Thread(target=self.request_access, daemon=True).start()

    def move(self, dx, dy):
        event = self.current_event(None)
        if not event:
            return False
        try:
            point = self.location(event)
        finally:
            self.release(event)

        target = Point(point.x + dx, point.y + dy)
        event = self.mouse_event(None, MOUSE_MOVED, target, 0)
        if not event:
            return False
        try:
            self.post(HID_EVENT_TAP, event)
        finally:
            self.release(event)
        return True


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = 3

    def reply(self, status, body=b"", content_type="text/plain"):
        self.send_response(status)
        if status != 204:
            self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", f"{content_type}; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def log_request(self, code="-", size="-"):
        if self.path != "/cursor/move":
            super().log_request(code, size)

    def do_GET(self):
        if self.headers.get("Host") != ADDRESS or self.path not in FILES:
            self.reply(404)
            return
        filename, content_type = FILES[self.path]
        self.reply(200, (ROOT / filename).read_bytes(), content_type)

    def do_POST(self):
        # Only the viewer served by this helper can issue browser requests.
        if (
            self.headers.get("Host") != ADDRESS
            or self.headers.get("Origin") != ORIGIN
            or self.headers.get("X-Motion-Bench") != "cursor"
        ):
            self.close_connection = True
            self.reply(403)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if not 0 <= length <= 64:
            self.close_connection = True
            self.reply(400)
            return
        body = self.rfile.read(length)

        cursor = self.server.cursor
        if self.path == "/cursor/enable" and not body:
            if cursor.allowed():
                self.reply(204)
            else:
                cursor.request_permission_once()
                self.reply(403)
            return
        if self.path != "/cursor/move":
            self.reply(404)
            return
        try:
            delta = json.loads(body)
            dx, dy = delta["dx"], delta["dy"]
        except (ValueError, KeyError, TypeError):
            self.reply(400)
            return
        if any(type(value) is not int or abs(value) > 48 for value in (dx, dy)):
            self.reply(400)
            return
        if not cursor.allowed():
            self.reply(403)
            return
        self.reply(204 if cursor.move(dx, dy) else 503)


def main():
    if sys.platform != "darwin":
        sys.exit("The system cursor helper requires macOS.")
    try:
        with ThreadingHTTPServer((HOST, PORT), Handler) as server:
            server.cursor = MacCursor()
            print(f"Open {ORIGIN} in Brave, Chrome, or Edge.", flush=True)
            print("Keep this Terminal window open. Press Control-C here to stop.", flush=True)
            server.serve_forever()
    except KeyboardInterrupt:
        pass
    except OSError as error:
        sys.exit(f"Could not start the cursor helper: {error}")


if __name__ == "__main__":
    main()
