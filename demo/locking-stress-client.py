#!/usr/bin/env python3
"""Bounded HTTP upload/download traffic from the worker to test VMI pod IPs."""
import collections
import http.client
import json
import sys
import threading
import time

seconds = int(sys.argv[1])
if not 1 <= seconds <= 900:
    raise SystemExit("duration must be 1..900 seconds")
targets = sys.argv[2:]
if not targets:
    raise SystemExit("supply at least one test VMI pod IP")
end = time.monotonic() + seconds
counts = collections.Counter()
lock = threading.Lock()
payload = b"s" * (1024 * 1024)


def traffic(target):
    while time.monotonic() < end:
        conn = http.client.HTTPConnection(target, 8080, timeout=4)
        try:
            conn.request("POST", "/", body=payload)
            response = conn.getresponse()
            response.read()
            if response.status != 200:
                raise RuntimeError(str(response.status))
            conn.close()
            conn = http.client.HTTPConnection(target, 8080, timeout=4)
            conn.request("GET", "/")
            response = conn.getresponse()
            received = 0
            while True:
                data = response.read(65536)
                if not data:
                    break
                received += len(data)
            if response.status != 200 or received != 2 * 1024 * 1024:
                raise RuntimeError("incomplete download")
            with lock:
                counts[target + ":cycles"] += 1
                counts[target + ":bytes"] += len(payload) + received
        except Exception as exc:
            with lock:
                counts[target + ":errors"] += 1
                counts[target + ":last_error:" + type(exc).__name__] += 1
            time.sleep(0.2)
        finally:
            conn.close()
        time.sleep(0.02)


threads = [threading.Thread(target=traffic, args=(target,), daemon=True)
           for target in targets for _ in range(2)]
for thread in threads:
    thread.start()
print(json.dumps({"targets": targets, "duration": seconds}), flush=True)
while time.monotonic() < end:
    time.sleep(min(10, max(0, end - time.monotonic())))
    with lock:
        print(json.dumps(dict(counts), sort_keys=True), flush=True)
for thread in threads:
    thread.join(timeout=5)
print("CLIENT_DONE", flush=True)
