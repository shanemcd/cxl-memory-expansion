#!/usr/bin/env python3
"""Bounded guest workload: 384 MiB resident memory, CPU hashing, HTTP traffic."""
import hashlib
import http.server
import threading
import time

memory = bytearray(384 * 1024 * 1024)
for offset in range(0, len(memory), 4096):
    memory[offset] = 1


def burn():
    while True:
        hashlib.sha256(memory).digest()
        time.sleep(0.02)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", str(2 * 1024 * 1024))
        self.end_headers()
        try:
            for _ in range(32):
                self.wfile.write(b"x" * 65536)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        remaining = min(int(self.headers.get("Content-Length", "0")), 8 * 1024 * 1024)
        while remaining:
            chunk = self.rfile.read(min(remaining, 65536))
            if not chunk:
                break
            remaining -= len(chunk)
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()


threading.Thread(target=burn, daemon=True).start()
http.server.ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
