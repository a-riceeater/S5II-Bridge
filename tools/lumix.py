#!/usr/bin/env python3
"""
Minimal Panasonic Lumix DC-S5M2 record controller over LAN. Stdlib only.

Protocol (confirmed against DC-S5M2, firmware 3.61):

    GET http://<ip>:60606/Lumix/Server0/ddd          -> device description, UDN
    GET http://<ip>/cam.cgi?mode=accctrl&type=req_acc_g
    GET http://<ip>/cam.cgi?mode=accctrl&type=req_acc_e&value=<hex UDN>&value2=<hex name>
        -> "ok,<friendly>,remote,open,<SESSION_ID>"
    every later request carries header  X-SESSION_ID: <SESSION_ID>
    GET .../cam.cgi?mode=camcmd&value=recmode        -> leave playback, enter rec
    GET .../cam.cgi?mode=camcmd&value=video_recstart
    GET .../cam.cgi?mode=camcmd&value=video_recstop

No live-view stream is ever required.
"""
import argparse, json, os, re, threading, time
import urllib.request, urllib.error, urllib.parse

STATE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".lumix_session.json")

# The camera drops an idle session after ~12s (measured: 11s alive, 12s dead).
SESSION_IDLE_TIMEOUT = 12.0
KEEPALIVE_INTERVAL = 3.0


class LumixError(Exception):
    pass


class LumixRefused(LumixError):
    """Camera explicitly refused pairing. Never retry this -- see pair()."""


class Lumix:
    # The camera hex-decodes value2 and renders the result as UTF-16. Sending hex
    # of UTF-8 (what liblumix does) makes the on-screen connect prompt show CJK
    # garbage / empty squares. "utf-16-le" is the encoding that renders correctly.
    NAME_ENCODINGS = ("utf-16-le", "utf-16-be", "utf-8")

    def __init__(self, ip, name="S5II Bridge", session_id=None, verbose=True,
                 name_encoding="utf-16-le"):
        self.ip = ip
        self.name = name
        self.name_encoding = name_encoding
        self.session_id = session_id
        self.udn = None
        self.info = {}
        self.verbose = verbose
        self._ka_stop = threading.Event()
        self._ka_thread = None
        self._lock = threading.RLock()

    def log(self, msg):
        if self.verbose:
            print(msg)

    # ---------- low level ----------
    def _get(self, url, headers=None, timeout=8):
        req = urllib.request.Request(url, headers=headers or {})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.status, r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", "replace")

    def cgi(self, query, use_session=True, timeout=8):
        """Raw cam.cgi call. Returns (http_status, body). Raises on transport error."""
        url = "http://{}/cam.cgi?{}".format(self.ip, query)
        headers = {}
        if use_session and self.session_id:
            headers["X-SESSION_ID"] = self.session_id
        with self._lock:
            st, body = self._get(url, headers, timeout)
        self.log("  GET ?{}\n      -> {} {}".format(query, st, body.strip()[:220]))
        return st, body

    @staticmethod
    def result(body):
        m = re.search(r"<result>(\w+)</result>", body)
        return m.group(1) if m else None

    # ---------- discovery ----------
    def describe(self):
        """Fetch the UPnP device description on :60606 and extract the UDN."""
        for path in ("/Lumix/Server0/ddd", "/Server0/ddd"):
            st, body = self._get("http://{}:60606{}".format(self.ip, path))
            if st == 200:
                for tag in ("friendlyName", "manufacturer", "modelName", "modelNumber",
                            "serialNumber", "UDN", "pana:X_FirmVersion"):
                    m = re.search(r"<{}>(.*?)</{}>".format(re.escape(tag), re.escape(tag)),
                                  body, re.S)
                    if m:
                        self.info[tag] = m.group(1).strip()
                udn = self.info.get("UDN", "")
                self.udn = udn[5:] if udn.startswith("uuid:") else udn
                self.log("  device description {} -> 200".format(path))
                for k, v in self.info.items():
                    self.log("      {:<20} = {}".format(k, v))
                return self.info
        raise LumixError("no UPnP description on {}:60606 -- camera off, "
                         "asleep, or on another IP".format(self.ip))

    # ---------- pairing ----------
    def pair(self, timeout_s=30, prompt_timeout_s=240):
        """
        req_acc_g arms a single pending request slot and returns a nonce;
        req_acc_e polls that slot. Re-sending an *identical* req_acc_e polls the
        same request, a different value/value2 gets err_others_requesting.

        States seen on DC-S5M2 3.61:
            ok,<friendly>,remote,open,<SESSION_ID>  granted
            ok_under_research                       prompting the operator
            ok_under_research_no_msg                deciding silently (known device)
            err_user_refused                        REFUSED -- see below
            err_others_requesting                   another request holds the slot
            err_critical                            stale slot / not in remote mode
        """
        if not self.udn:
            self.describe()

        # value  : camera UDN, plain ASCII hex (never displayed, byte-compared)
        # value2 : client name, hex of UTF-16 -- this is what the camera shows
        v1 = self.udn.encode("ascii").hex()
        v2 = self.name.encode(self.name_encoding).hex()

        self.cgi("mode=accctrl&type=req_acc_g", use_session=False)

        deadline = time.time() + timeout_s
        rearms = 0
        prompted = False
        last = ""
        while time.time() < deadline:
            st, body = self.cgi(
                "mode=accctrl&type=req_acc_e&value={}&value2={}".format(v1, v2),
                use_session=False)
            last = body.strip()
            state = last.split(",")[0].strip()

            if state == "ok":
                self.session_id = last.split(",")[-1].strip()
                self.log("  paired, session_id = {}".format(self.session_id))
                self.set_device_name(self.name)
                return self.session_id

            # 'ok_under_research' (without _no_msg) means the camera is showing a
            # confirmation dialog and is waiting on a HUMAN. Extend the deadline --
            # 30s is nowhere near long enough for someone to walk to the camera --
            # and never re-arm while it is up, because a fresh req_acc_g replaces
            # the pending request and the operator's acceptance lands on a dead one.
            if state.startswith("ok"):
                if state == "ok_under_research" and not prompted:
                    prompted = True
                    deadline = time.time() + prompt_timeout_s
                    self.log("  camera is prompting the operator -- waiting up to "
                             "{}s for acceptance".format(prompt_timeout_s))
                time.sleep(0.5)
                continue

            # NEVER re-arm after an explicit refusal. The S5II counts refused
            # pairing attempts and after a handful trips an "invalid login"
            # lockout that needs a physical power cycle and drops the camera off
            # the network. A refusal means the body is not armed to accept a new
            # remote device -- that is fixed on the camera, not by retrying.
            if state == "err_user_refused":
                raise LumixRefused(
                    "camera refused pairing. Do NOT retry -- repeated refusals "
                    "trigger the 'invalid login' lockout (needs a power cycle). "
                    "On the camera: MENU > Setup > IN/OUT > LAN/Wi-Fi > Wi-Fi "
                    "Function > New Connection > Remote Shooting & View.")

            # err_critical / err_others_requesting: a stale pending request holds
            # the slot, or the body has left remote mode. Re-arming can clear the
            # former; bound the attempts so we never spin.
            rearms += 1
            if rearms > 3:
                raise LumixError(
                    "pairing stuck after {} re-arms (last: {}). The camera has "
                    "most likely left remote-control mode -- re-arm it with "
                    "Wi-Fi Function > New Connection > Remote Shooting & View."
                    .format(rearms, last))
            time.sleep(1.0)
            self.cgi("mode=accctrl&type=req_acc_g", use_session=False)

        raise LumixError("pairing not granted within {}s (last: {})".format(timeout_s, last))

    def set_device_name(self, name):
        """
        Sets the name the camera stores for this client. Sent immediately after a
        grant to confirm the connection. Tries plain (percent-encoded) first, then
        the hex-of-UTF-16 form used by value2, since which one this endpoint wants
        is not the same question as which one the connect prompt wants.
        """
        st, body = self.cgi("mode=setsetting&type=device_name&value={}".format(
            urllib.parse.quote(name)))
        if self.result(body) == "ok":
            return "plain"
        st, body = self.cgi("mode=setsetting&type=device_name&value={}".format(
            name.encode(self.name_encoding).hex()))
        return "hex" if self.result(body) == "ok" else None

    def get_device_name(self):
        """Read back the name the camera stored for us, if the endpoint exists."""
        st, body = self.cgi("mode=getsetting&type=device_name")
        return body.strip()

    # ---------- state ----------
    def getstate(self, tries=1, timeout=4):
        """
        Returns the parsed <state> dict, or {} if unreachable. The camera stops
        answering HTTP for a few seconds while switching between play and rec,
        so callers that span a mode change should pass tries>1.
        """
        for _ in range(tries):
            try:
                st, body = self.cgi("mode=getstate", timeout=timeout)
                if self.result(body) == "ok":
                    return dict(re.findall(r"<(\w+)>([^<]*)</\1>", body))
            except Exception:
                pass
            time.sleep(0.5)
        return {}

    def cammode(self, tries=1):
        return self.getstate(tries).get("cammode")

    def is_recording(self):
        return self.getstate().get("rec") == "on"

    # ---------- session management ----------
    def connect(self):
        """Pair and leave the camera in record mode, ready to roll."""
        if not self.udn:
            self.describe()
        self.pair()
        self.ensure_rec()
        return self.session_id

    def ensure_rec(self, timeout_s=20):
        """
        After every fresh pairing the camera reports <cammode>play</cammode>, and
        video_recstart returns err_critical until it is switched. The play->rec
        transition takes ~5s and the HTTP server is unresponsive during part of
        it, so poll tolerantly. No-op if already in rec mode.
        """
        if self.cammode(tries=3) == "rec":
            return 0.0
        t = time.time()
        try:
            self.cgi("mode=camcmd&value=recmode", timeout=12)
        except Exception:
            pass                                   # expected during the switch
        while time.time() - t < timeout_s:
            if self.cammode(tries=1) == "rec":
                return time.time() - t
            time.sleep(0.3)
        raise LumixError("camera did not enter rec mode within {}s".format(timeout_s))

    def cmd(self, query, recover=True):
        """cam.cgi call with automatic session recovery."""
        st, body = self.cgi(query)
        if recover and self.result(body) == "err_critical":
            self.log("  err_critical -> re-pairing and retrying")
            self.session_id = None
            self.pair()
            self.ensure_rec()
            st, body = self.cgi(query)
        return st, body

    # ---------- keepalive ----------
    def start_keepalive(self, interval=KEEPALIVE_INTERVAL):
        """
        Cheap getstate ping. Keeps the session AND the rec-mode state warm, which
        is what keeps recstart at ~10-70ms instead of ~5s. Costs roughly 400 bytes
        per ping -- nothing like a live-view stream.
        """
        def loop():
            while not self._ka_stop.wait(interval):
                try:
                    v, self.verbose = self.verbose, False
                    self.cgi("mode=getstate", timeout=4)
                    self.verbose = v
                except Exception:
                    pass
        self._ka_stop.clear()
        self._ka_thread = threading.Thread(target=loop, daemon=True)
        self._ka_thread.start()

    def stop_keepalive(self):
        self._ka_stop.set()
        if self._ka_thread:
            self._ka_thread.join(timeout=2)
            self._ka_thread = None

    # ---------- record ----------
    def rec_start(self):
        st, body = self.cmd("mode=camcmd&value=video_recstart")
        return self.result(body) == "ok", body

    def rec_stop(self):
        st, body = self.cmd("mode=camcmd&value=video_recstop")
        return self.result(body) == "ok", body


# ---------- session cache ----------
def save_session(ip, name, sid):
    with open(STATE_FILE, "w") as f:
        json.dump({"ip": ip, "name": name, "session_id": sid, "t": time.time()}, f)


def load_session(ip):
    try:
        with open(STATE_FILE) as f:
            d = json.load(f)
        if d.get("ip") == ip and (time.time() - d.get("t", 0)) < SESSION_IDLE_TIMEOUT:
            return d.get("name"), d.get("session_id")
    except Exception:
        pass
    return None, None


def main():
    ap = argparse.ArgumentParser(description="Lumix S5II LAN record control")
    ap.add_argument("cmd", choices=["describe", "pair", "state", "start", "stop",
                                    "cycle", "raw"])
    ap.add_argument("--ip", default="10.0.0.177")
    ap.add_argument("--name", default="S5II Bridge")
    ap.add_argument("--name-encoding", default="utf-16-le",
                    choices=list(Lumix.NAME_ENCODINGS))
    ap.add_argument("--query", help="raw cam.cgi query for `raw`")
    ap.add_argument("--seconds", type=float, default=3.0, help="clip length for `cycle`")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()

    name, sid = load_session(args.ip)
    cam = Lumix(args.ip, name=args.name or name, session_id=sid,
                verbose=not args.quiet, name_encoding=args.name_encoding)

    if args.cmd == "describe":
        cam.describe()
        return

    if not cam.session_id:
        cam.connect()
        save_session(args.ip, cam.name, cam.session_id)
    if args.cmd == "pair":
        print("session_id =", cam.session_id, " cammode =", cam.cammode())
        return

    if args.cmd == "raw":
        cam.cmd(args.query)
        return

    if args.cmd == "state":
        for k, v in sorted(cam.getstate().items()):
            print("  {:<24} {}".format(k, v))
        return

    cam.start_keepalive()
    try:
        if args.cmd == "start":
            ok, _ = cam.rec_start()
            print("record START -> {}".format("ok" if ok else "FAILED"))
        elif args.cmd == "stop":
            ok, _ = cam.rec_stop()
            print("record STOP  -> {}".format("ok" if ok else "FAILED"))
        elif args.cmd == "cycle":
            ok, _ = cam.rec_start()
            print("record START -> {}  rec={}".format("ok" if ok else "FAILED",
                                                      cam.getstate().get("rec")))
            time.sleep(args.seconds)
            ok, _ = cam.rec_stop()
            print("record STOP  -> {}  rec={}".format("ok" if ok else "FAILED",
                                                      cam.getstate().get("rec")))
    finally:
        cam.stop_keepalive()
        save_session(args.ip, cam.name, cam.session_id)


if __name__ == "__main__":
    main()
