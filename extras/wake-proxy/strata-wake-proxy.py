#!/usr/bin/env python3
"""strata-wake-proxy -- keep a port open for Strata and start the container on demand.

Strata cannot unload its model and keep listening, so the only way to give the
GPU back (to sleep, or to another program) is to stop the container. This proxy
listens on the port your clients use and stays up while Strata is stopped:

  * Strata up   -> every request is passed through unchanged (streaming included).
  * Strata down -> a model request (POST /v1/...) runs `docker start <container>`,
                   waits until /health reports the model loaded (1-3 min), then
                   forwards it. Anything else (dashboard polls, /health, /metrics)
                   gets a 503 "asleep" reply and does NOT wake it, so an open
                   dashboard tab cannot keep restarting Strata. GET /v1/models is
                   answered from the last copy seen while Strata was up.
  * STRATA_BLOCKER set and that container running -> no wake (503), for a PC where
                   another GPU program must not be fought over. The proxy never
                   stops anything.

Set Strata's own port to 127.0.0.1:18081 (STRATA_PORT=18081 in .env) and point
clients at this proxy's port instead. Settings, all optional, by environment:
  STRATA_PROXY_HOST / STRATA_PROXY_PORT      where to listen (0.0.0.0:8081)
  STRATA_BACKEND_HOST / STRATA_BACKEND_PORT  the container (127.0.0.1:18081)
  STRATA_CONTAINER (strata)  STRATA_BLOCKER (none)  STRATA_WAKE_TIMEOUT (300 s)
  STRATA_DOCKER (docker)

The API key is still checked by Strata itself; the proxy never needs it
(Strata's /health answers before its key gate). Python standard library only.
"""
import http.client
import http.server
import json
import os
import socketserver
import subprocess
import sys
import threading
import time

LISTEN_HOST = os.environ.get("STRATA_PROXY_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("STRATA_PROXY_PORT", "8081"))
BACKEND_HOST = os.environ.get("STRATA_BACKEND_HOST", "127.0.0.1")
BACKEND_PORT = int(os.environ.get("STRATA_BACKEND_PORT", "18081"))
CONTAINER = os.environ.get("STRATA_CONTAINER", "strata")
BLOCKER = os.environ.get("STRATA_BLOCKER", "")              # optional: a container that holds the GPU
WAKE_TIMEOUT_S = int(os.environ.get("STRATA_WAKE_TIMEOUT", "300"))
DOCKER = os.environ.get("STRATA_DOCKER", "docker")

HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
              "te", "trailers", "transfer-encoding", "upgrade"}

_wake_lock = threading.Lock()
_models_cache = None                # last good GET /v1/models body (bytes)


def log(msg):
    print(f"strata-wake-proxy: {msg}", flush=True)


def container_running(name):
    try:
        out = subprocess.run([DOCKER, "inspect", "-f", "{{.State.Running}}", name],
                             capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return out.returncode == 0 and out.stdout.strip() == "true"


def backend_loaded():
    """True once Strata's /health says the model is loaded."""
    try:
        conn = http.client.HTTPConnection(BACKEND_HOST, BACKEND_PORT, timeout=5)
        conn.request("GET", "/health")
        resp = conn.getresponse()
        body = resp.read()
        conn.close()
        return resp.status == 200 and json.loads(body).get("loaded") is True
    except (OSError, ValueError, http.client.HTTPException):
        return False


def wake():
    """Start Strata if needed and wait for it. Returns None on success, else a reason."""
    with _wake_lock:                                  # one waker; the rest wait here
        if backend_loaded():
            return None
        if BLOCKER and container_running(BLOCKER):
            return f"{BLOCKER} is running and holds the GPU; stop it first (docker stop {BLOCKER})"
        if not container_running(CONTAINER):
            log(f"model request while asleep: docker start {CONTAINER}")
            r = subprocess.run([DOCKER, "start", CONTAINER], capture_output=True, text=True)
            if r.returncode != 0:
                return f"docker start {CONTAINER} failed: {r.stderr.strip()[:200]}"
        t0 = time.time()
        while time.time() - t0 < WAKE_TIMEOUT_S:
            if backend_loaded():
                log(f"{CONTAINER} loaded after {time.time() - t0:.0f} s")
                return None
            if not container_running(CONTAINER):
                return f"{CONTAINER} exited while loading (docker logs {CONTAINER})"
            time.sleep(3)
        return f"{CONTAINER} not loaded after {WAKE_TIMEOUT_S} s (docker logs {CONTAINER})"


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "strata-wake-proxy"

    def log_message(self, fmt, *args):                # quiet: Strata logs requests itself
        pass

    # ---- helpers -------------------------------------------------------------
    def _read_body(self):
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            chunks = []
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                        pass                          # trailers
                    break
                chunks.append(self.rfile.read(size))
                self.rfile.readline()                 # CRLF after each chunk
            return b"".join(chunks)
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _reply(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def _asleep(self, why):
        self._reply(503, {"error": {"message": f"Strata is asleep: {why}", "type": "strata_asleep"},
                          "status": "asleep", "loaded": False, "service": "strata-wake-proxy"})

    def _forward(self, body):
        global _models_cache
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP}
        if body or self.command in ("POST", "PUT", "PATCH"):
            headers["Content-Length"] = str(len(body))
        conn = http.client.HTTPConnection(BACKEND_HOST, BACKEND_PORT, timeout=3600)
        try:
            conn.request(self.command, self.path, body=body or None, headers=headers)
            resp = conn.getresponse()
        except (OSError, http.client.HTTPException) as e:
            conn.close()
            self._reply(502, {"error": {"message": f"strata-wake-proxy: backend error: {e}"}})
            return
        length = resp.getheader("Content-Length")
        self.send_response(resp.status, resp.reason)
        for k, v in resp.getheaders():
            if k.lower() not in HOP_BY_HOP and k.lower() != "content-length":
                self.send_header(k, v)
        if length is not None:
            self.send_header("Content-Length", length)
        else:
            self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Connection", "close")
        self.end_headers()
        keep = self.command == "GET" and self.path.split("?")[0] == "/v1/models" and resp.status == 200
        saved = []
        if self.command == "HEAD":
            conn.close()
            self.close_connection = True
            return
        try:
            while True:
                data = resp.read1(65536)
                if not data:
                    break
                if keep:
                    saved.append(data)
                if length is not None:
                    self.wfile.write(data)
                else:
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
            if length is None:
                self.wfile.write(b"0\r\n\r\n")
            if keep:
                _models_cache = b"".join(saved)
        except (BrokenPipeError, ConnectionResetError):
            pass                                      # client went away: closing upstream cancels it
        finally:
            conn.close()
            self.close_connection = True

    # ---- dispatch ------------------------------------------------------------
    def _handle(self):
        body = self._read_body()
        path = self.path.split("?")[0]
        if backend_loaded():
            return self._forward(body)
        if self.command == "GET" and path == "/v1/models" and _models_cache is not None:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(_models_cache)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(_models_cache)
            self.close_connection = True
            return None
        if self.command == "POST" and path.startswith("/v1/"):
            why = wake()
            if why is None:
                return self._forward(body)
            log(f"wake refused: {why}")
            return self._asleep(why)
        if container_running(CONTAINER):
            return self._reply(503, {"error": {"message": "Strata is loading the model (1-3 min); try again shortly",
                                               "type": "strata_loading"},
                                     "status": "loading", "loaded": False, "service": "strata-wake-proxy"})
        return self._asleep("only a model request (POST /v1/...) wakes it")

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = do_HEAD = _handle


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64         # default 5: bursts from several agents could be refused


def main():
    srv = Server((LISTEN_HOST, LISTEN_PORT), Handler)
    log(f"listening on {LISTEN_HOST}:{LISTEN_PORT} -> {BACKEND_HOST}:{BACKEND_PORT} ({CONTAINER})")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
