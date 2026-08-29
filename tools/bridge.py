#!/usr/bin/env python3
"""
S5II Bridge -- a long-lived process that owns the camera session.

Why this exists
---------------
The S5II expects ONE controller that stays connected. A short-lived CLI that
pairs, fires a command and exits abandons the session; the camera notices its
controller vanished, shows "connection failed" and drops out of remote mode.
That is the root cause of the err_critical / hung-HTTP flapping.

So: one process holds the session open and keeps it warm, and everything else
talks to *it*. A warm session also keeps recstart at ~10-70ms instead of ~6.5s,
because the expensive play->rec transition is paid once at connect.

    discover -> pair -> ensure rec mode -> keepalive @3s -> serve -> teardown

Local control API (bind is 127.0.0.1 by default):

    GET  /status            -> JSON: connection + camera state
    POST /record/start      -> {"ok": true, "recording": true}
    POST /record/stop       -> {"ok": true, "recording": false}
    POST /record/toggle     -> {"ok": true, "recording": ...}
    POST /reconnect         -> force rediscovery + re-pair

This maps 1:1 onto the planned iOS app: LumixBridge becomes a long-lived object
owned by the app, the HTTP layer is replaced by the UI/Shortcuts layer, and the
threading here becomes a serial DispatchQueue or an actor. See ARCHITECTURE.md.
"""
import argparse, json, os, socket, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import discover
from lumix import Lumix, LumixError, LumixRefused, LumixBusy, KEEPALIVE_INTERVAL


class BridgeState(object):
    DISCONNECTED = "disconnected"
    SEARCHING = "searching"
    CONNECTING = "connecting"
    READY = "ready"
    REFUSED = "refused"          # terminal until a human re-arms the camera
    FAULTED = "faulted"          # terminal: camera reported err_busy


class LumixBridge(object):
    """
    Owns discovery, the session, and the keepalive. Thread-safe. All camera I/O
    is serialised through one lock so the keepalive can never interleave with a
    record command mid-request.
    """

    def __init__(self, name="S5II Bridge", udn=None, ip=None,
                 keepalive=KEEPALIVE_INTERVAL, verbose=False):
        self.name = name
        self.want_udn = udn
        self.fixed_ip = ip
        self.keepalive_interval = keepalive
        self.verbose = verbose

        self.cam = None
        self.stream_sock = None
        self.stream_thread = None
        self.stream_stop = threading.Event()
        self.state = BridgeState.DISCONNECTED
        self.detail = ""
        self.last_state = {}
        self.last_error = ""
        self.connected_at = None

        self._lock = threading.RLock()
        self._stop = threading.Event()
        self._thread = None

    # ---------- logging ----------
    def log(self, msg):
        print("[{}] {}".format(time.strftime("%H:%M:%S"), msg), flush=True)

    # ---------- lifecycle ----------
    def start(self):
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=5)
        self._teardown()

    def _teardown(self):
        try:
            if self.cam:
                self.cam.stop_stream()
        except Exception:
            pass
        self._stop_stream()
        """
        Leave the camera as tidily as we can. There is no documented 'release
        session' verb, so the best available exit is to stop recording if we
        started it and let the session lapse naturally.
        """
        with self._lock:
            if self.cam and self.state == BridgeState.READY:
                try:
                    if self.cam.getstate().get("rec") == "on":
                        self.log("teardown: stopping in-progress recording")
                        self.cam.rec_stop()
                except Exception:
                    pass
            self.state = BridgeState.DISCONNECTED

    # ---------- connection ----------
    def _locate(self):
        if self.fixed_ip:
            info = discover.fetch_ddd(self.fixed_ip, timeout=3.0)
            return discover.Camera(self.fixed_ip, info) if info else None
        return discover.find(udn=self.want_udn, verbose=self.verbose)

    def _connect(self):
        self.state = BridgeState.SEARCHING
        found = self._locate()
        if not found:
            self.detail = ("camera not found. If its port 60606 accepts TCP but "
                           "never answers HTTP, the body is hung -- re-arm it.")
            return False

        self.state = BridgeState.CONNECTING
        self.log("found {} at {}".format(found.model, found.ip))
        cam = Lumix(found.ip, name=self.name, verbose=self.verbose)
        cam.info = found.info
        cam.udn = found.udn
        try:
            cam.pair()
            cam.ensure_rec()
        except LumixRefused as e:
            # Terminal. Retrying is what trips the camera's lockout.
            self.state = BridgeState.REFUSED
            self.last_error = str(e)
            self.log("REFUSED -- not retrying. {}".format(e))
            return False
        except LumixBusy as e:
            # Terminal too. The per-connection breaker inside Lumix does not
            # survive here because _connect() builds a fresh client each time,
            # so the supervisor would happily retry err_busy forever -- which is
            # exactly the cascade that locks the body. Latch it at this level.
            self.state = BridgeState.FAULTED
            self.last_error = str(e)
            self.log("FAULTED -- not retrying. {}".format(e))
            return False
        except LumixError as e:
            self.last_error = str(e)
            self.log("connect failed: {}".format(e))
            return False

        # The live-view stream is what holds cammode=rec; without it the camera
        # falls back to playback after ~2s and the shutter stops working. We
        # bind and drain the socket but never decode the frames.
        self._start_stream(cam)

        with self._lock:
            self.cam = cam
            self.state = BridgeState.READY
            self.connected_at = time.time()
            self.detail = ""
        self.log("READY (session {})".format(cam.session_id))
        return True

    def _start_stream(self, cam, port=49199):
        self._stop_stream()
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind(("0.0.0.0", port))
            sock.settimeout(1.0)
        except Exception as e:
            self.log("could not bind udp/{}: {}".format(port, e))
            return
        self.stream_sock = sock
        self.stream_stop.clear()

        def drain():
            while not self.stream_stop.is_set():
                try:
                    sock.recvfrom(65535)      # discarded; we only need a receiver
                except Exception:
                    pass

        self.stream_thread = threading.Thread(target=drain, daemon=True)
        self.stream_thread.start()
        cam.set_liveview_size("qvga")         # smallest, since we never show it
        cam.start_stream(port)

    def _stop_stream(self):
        self.stream_stop.set()
        if self.stream_thread:
            self.stream_thread.join(timeout=2)
            self.stream_thread = None
        if self.stream_sock:
            try:
                self.stream_sock.close()
            except Exception:
                pass
            self.stream_sock = None

    # ---------- supervisor ----------
    def _run(self):
        backoff = 2.0
        while not self._stop.is_set():
            if self.state in (BridgeState.REFUSED, BridgeState.FAULTED):
                self._stop.wait(5)          # wait for an explicit /reconnect
                continue

            if self.state != BridgeState.READY:
                if self._connect():
                    backoff = 2.0
                else:
                    self._stop.wait(backoff)
                    backoff = min(backoff * 1.6, 30.0)
                continue

            # READY: keep the session warm. getstate doubles as our state feed,
            # so the keepalive costs nothing extra.
            try:
                with self._lock:
                    st = self.cam.getstate(timeout=4)
                if st:
                    self.last_state = st
                    # Record mode lapses ~2s after the stream stops. Re-issuing
                    # startstream restores it and is safe; recmode is NOT (it
                    # locks the body if it lands while recording).
                    if st.get("cammode") != "rec" and st.get("rec") != "on":
                        self.log("cammode={} -- restarting stream to hold record mode"
                                 .format(st.get("cammode")))
                        with self._lock:
                            self.cam.start_stream(self.cam.stream_port or 49199)
                else:
                    raise LumixError("keepalive got no state")
            except Exception as e:
                self.log("keepalive lost the session ({}) -- reconnecting".format(e))
                with self._lock:
                    self.state = BridgeState.DISCONNECTED
                    self.cam = None
                continue

            self._stop.wait(self.keepalive_interval)

    # ---------- commands ----------
    def _require_ready(self):
        if self.state != BridgeState.READY or not self.cam:
            raise LumixError("bridge not ready ({}) {}".format(self.state, self.detail))

    # <rec> does not settle instantly. Measured on DC-S5M2 3.61:
    #   recstart -> <rec>on  in ~11 ms
    #   recstop  -> <rec>off in ~1.95 s   (camera is finalising the clip)
    # So the state right after a command is NOT trustworthy; wait for it to settle
    # or a toggle will read the stale value and do the opposite of what was asked.
    REC_SETTLE_TIMEOUT = 6.0

    def _await_rec(self, expected, timeout=None):
        """Poll until <rec> reaches `expected`. Returns True if it settled."""
        timeout = self.REC_SETTLE_TIMEOUT if timeout is None else timeout
        t0 = time.time()
        while time.time() - t0 < timeout:
            st = self.cam.getstate(timeout=4)
            if st:
                self.last_state = st
                if st.get("rec") == expected:
                    return True
            time.sleep(0.15)
        return False

    def record_start(self):
        with self._lock:
            self._require_ready()
            ok, _ = self.cam.rec_start()
            if ok:
                self._await_rec("on")
            else:
                self.last_state = self.cam.getstate()
            return ok

    def record_stop(self):
        with self._lock:
            self._require_ready()
            ok, _ = self.cam.rec_stop()
            if ok:
                self._await_rec("off")       # ~2s while the clip is finalised
            else:
                self.last_state = self.cam.getstate()
            return ok

    def record_toggle(self):
        with self._lock:
            self._require_ready()
            # Read fresh state rather than trusting the cached keepalive sample.
            st = self.cam.getstate(timeout=4)
            if st:
                self.last_state = st
            return self.record_stop() if self.is_recording() else self.record_start()

    def is_recording(self):
        return self.last_state.get("rec") == "on"

    def status(self):
        with self._lock:
            cam = self.cam
            return {
                "state": self.state,
                "detail": self.detail,
                "error": self.last_error,
                "recording": self.is_recording(),
                "ip": cam.ip if cam else None,
                "model": (cam.info.get("modelNumber") if cam else None),
                "firmware": (cam.info.get("pana:X_FirmVersion") if cam else None),
                "udn": cam.udn if cam else None,
                "session_id": cam.session_id if cam else None,
                "client_name": self.name,
                "uptime_s": (round(time.time() - self.connected_at, 1)
                             if self.connected_at else None),
                "cammode": self.last_state.get("cammode"),
                "battery": self.last_state.get("batt"),
                "sd": self.last_state.get("sdcardstatus"),
                "video_remaining_s": self.last_state.get("video_remaincapacity"),
                "temperature": self.last_state.get("temperature"),
            }

    def force_reconnect(self):
        with self._lock:
            self.cam = None
            self.last_error = ""
            self.state = BridgeState.DISCONNECTED


# ---------- local HTTP control surface ----------
def make_handler(bridge):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _send(self, code, payload):
            body = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass                                    # keep the console readable

        def do_GET(self):
            if self.path.rstrip("/") in ("", "/status"):
                return self._send(200, bridge.status())
            self._send(404, {"error": "not found"})

        def do_POST(self):
            route = self.path.rstrip("/")
            try:
                if route == "/record/start":
                    ok = bridge.record_start()
                elif route == "/record/stop":
                    ok = bridge.record_stop()
                elif route == "/record/toggle":
                    ok = bridge.record_toggle()
                elif route == "/reconnect":
                    bridge.force_reconnect()
                    return self._send(200, {"ok": True, "state": bridge.state})
                else:
                    return self._send(404, {"error": "not found"})
            except LumixError as e:
                return self._send(503, {"ok": False, "error": str(e),
                                        "state": bridge.state})
            self._send(200, {"ok": bool(ok), "recording": bridge.is_recording()})

    return Handler


def main():
    ap = argparse.ArgumentParser(description="Persistent Lumix S5II bridge")
    ap.add_argument("--name", default="S5II Bridge",
                    help="name shown on the camera's connect prompt")
    ap.add_argument("--udn", help="pin to one specific camera by UDN")
    ap.add_argument("--ip", help="skip discovery and use this address")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8777)
    ap.add_argument("--keepalive", type=float, default=KEEPALIVE_INTERVAL)
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    bridge = LumixBridge(name=args.name, udn=args.udn, ip=args.ip,
                         keepalive=args.keepalive, verbose=args.verbose)
    bridge.start()

    srv = ThreadingHTTPServer((args.host, args.port), make_handler(bridge))
    print("S5II Bridge listening on http://{}:{}".format(args.host, args.port))
    print("  GET  /status")
    print("  POST /record/start | /record/stop | /record/toggle | /reconnect")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nshutting down...")
    finally:
        srv.shutdown()
        bridge.stop()


if __name__ == "__main__":
    main()
