#!/usr/bin/env python3
"""
SECODS dashboard bridge (read-only).

Serves the JSON file written by the EA (MQL5 Common\\Files\\SECODS_status.json)
at http://localhost:8787/status.json so the dashboard in your browser can show it.
It exposes NO trading or withdrawal functions. Only listens on 127.0.0.1.

Usage (Windows):
    python bridge.py
    python bridge.py --file "C:\\Users\\YOU\\AppData\\Roaming\\MetaQuotes\\Terminal\\Common\\Files\\SECODS_status.json"
"""
import argparse, json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

def default_path():
    appdata = os.environ.get("APPDATA")
    if appdata:
        return os.path.join(appdata, "MetaQuotes", "Terminal", "Common", "Files", "SECODS_status.json")
    return "SECODS_status.json"

p = argparse.ArgumentParser()
p.add_argument("--file", default=default_path())
p.add_argument("--port", type=int, default=8787)
a = p.parse_args()

class H(BaseHTTPRequestHandler):
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Private-Network", "true")
        self.send_header("Cache-Control", "no-store")
    def do_OPTIONS(self):
        self.send_response(204); self._cors(); self.end_headers()
    def do_GET(self):
        if self.path.split("?")[0] != "/status.json":
            self.send_response(404); self.end_headers(); return
        try:
            with open(a.file, "rb") as f:
                body = f.read()
            json.loads(body)  # validate
            self.send_response(200)
        except Exception as e:
            body = json.dumps({"error": str(e)}).encode()
            self.send_response(503)
        self._cors()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args): pass

print(f"Serving {a.file}\n -> http://127.0.0.1:{a.port}/status.json  (Ctrl+C to stop)")
try:
    HTTPServer(("127.0.0.1", a.port), H).serve_forever()
except KeyboardInterrupt:
    sys.exit(0)
