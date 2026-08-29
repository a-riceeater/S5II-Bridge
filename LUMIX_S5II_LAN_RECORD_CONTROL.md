# Lumix S5II — video record start/stop over LAN

Reverse-engineered against a real body. Target: a low-bandwidth remote shutter with
**no live-view stream**.

| | |
|---|---|
| Model | `DC-S5M2` (`friendlyName` `S5M2-E86421`) |
| Firmware | `3.61` (`pana:X_FirmVersion`) |
| UDN | `uuid:4D454930-0100-1000-8000-A0CDF3E86421` |
| IP under test | `10.0.0.177` (DHCP, same /24 as client) |
| Protocol | Plain HTTP `GET` to `/cam.cgi`, XML replies. No TLS, no auth beyond a session token. |

> **Correction.** An earlier version of this document claimed live view was completely
> avoidable. **That was wrong.** Recording *commands* need no stream, but the camera does
> not *stay* in record mode without one: with keepalive alone `cammode` falls back to
> `play` (2s in one measurement, ~8s in another) and `video_recstart` then fails. A/B
> measured — see §4a. Plan on running `startstream`; you can request the smallest frame
> size and never decode it, but you cannot skip it.

---

## 1. Ports

Scanned on `10.0.0.177`:

| Port | State | Purpose |
|------|-------|---------|
| 80 | **open** | `/cam.cgi` control API — everything below |
| 60606 | **open** | UPnP device description (`/Lumix/Server0/ddd`) |
| 50001 | **open** | Accepts TCP, returns nothing to HTTP/RTSP probes. Not needed. *(purpose unconfirmed)* |
| 554, 1900, 5000, 8080, 15740, 49152 | closed | No RTSP, **no PTP/IP** |

Port 15740 being closed matters: **LUMIX Tether's PTP/IP path is not available over Wi-Fi.**
Panasonic's docs confirm Tether-over-LAN requires a USB-Ethernet adaptor and disables Wi-Fi
and Bluetooth while active. So `cam.cgi` is the only route for a Wi-Fi client.

## 2. Discovery

The device description carries the UDN needed for the handshake:

```bash
curl -s http://10.0.0.177:60606/Lumix/Server0/ddd
```

```xml
<friendlyName>S5M2-E86421</friendlyName>
<manufacturer>Panasonic</manufacturer>
<modelName>LUMIX</modelName>
<modelNumber>DC-S5M2</modelNumber>
<serialNumber>000000000000000000XXXXXXXXXXXX</serialNumber>
<UDN>uuid:4D454930-0100-1000-8000-A0CDF3E86421</UDN>
<pana:X_FirmVersion>3.61</pana:X_FirmVersion>
```

A bare `GET http://10.0.0.177:60606/` returns `404` — useful as a fast "is the camera awake"
probe without waiting on a TCP timeout.

`ddd` is also served at `/Server0/ddd` on older bodies; try `/Lumix/Server0/ddd` first.

> An SSDP `M-SEARCH` to `239.255.255.250:1900` returned nothing here, but the local Windows
> firewall blocked *all* SSDP replies on this host, so this is **untested**, not a negative
> result. Fixed IP or an ARP/`:60606` sweep is the reliable discovery method regardless.

## 3. Pairing handshake

The legacy `mode=accctrl&type=req_acc` handshake is **gone** on this firmware — it returns
`err_param`. Firmware 3.61 uses a two-step `req_acc_g` / `req_acc_e` flow.

```
GET /cam.cgi?mode=accctrl&type=req_acc_g
    -> ok,7cfd35c2                       # arms a pending request slot, returns a nonce

GET /cam.cgi?mode=accctrl&type=req_acc_e&value=<hex(UDN)>&value2=<hex(client name)>
    -> ok_under_research,S5M2-E86421,remote,open           # deciding (may prompt on screen)
    -> ok_under_research_no_msg,S5M2-E86421,remote,open    # deciding silently (known device)
    -> ok,S5M2-E86421,remote,open,F203CA4BF50DC91F         # granted; last field = SESSION_ID
```

- `value` and `value2` are **lowercase hex of the ASCII bytes**. The UDN is sent *without*
  the `uuid:` prefix: `4D454930-...` → `34443435343933302d...`.
- These replies are **plain text CSV, not XML** — unlike every other endpoint. Parse both.
- The camera holds **exactly one pending request slot**. Re-sending an *identical* `req_acc_e`
  polls that same request; a *different* `value`/`value2` while one is pending returns
  `err_others_requesting`.
- The `req_acc_g` nonce never had to be used. It stays constant while a request is pending
  and rotates on re-arm — a frozen nonce is a reliable sign the slot is stuck. *(Its intended
  use is unconfirmed; pairing succeeds without referencing it.)*

Poll `req_acc_e` every 500 ms until it returns `ok`. Once a client name has been accepted
the camera **remembers it**: later pairings return `ok_under_research_no_msg` and grant in
~650 ms with no operator action.

> **Do not re-arm while a prompt is up.** `ok_under_research` (without `_no_msg`) means the
> camera is showing a dialog and waiting on a human. Sending another `req_acc_g` *replaces*
> the pending request, so the operator's acceptance lands on a request you already
> abandoned — the connection appears to hang forever and the on-screen name can blank to
> `-`. Allow a human-scale window (~240 s) and poll the *same* `req_acc_e` throughout.

### Session token

Every subsequent request must carry the session as a header:

```
X-SESSION_ID: F203CA4BF50DC91F
```

Without it **every** endpoint returns `<result>err_critical</result>` — including `getstate`.
There is no cookie, no sequence number, and no per-request signature.

### ⚠️ The lockout — the one genuinely destructive failure mode

`err_user_refused` means the body is **not armed to accept a new remote device**. It is
returned automatically within ~3 s, with no prompt shown to anyone.

**Never retry after `err_user_refused`.** The camera counts refused attempts and after a
handful displays *"An invalid login occurred. Please turn the power off and then on again"*,
drops off the network entirely, and requires a physical power cycle. This was hit during
testing by a retry loop that re-armed on refusal.

`err_critical` and `err_others_requesting` during pairing are *not* refusals — they mean a
stale slot or that the body has left remote mode. Re-arming with `req_acc_g` can clear a
stale slot; bound it to ~3 attempts.

### Arming the camera

For a *new* client, the body must be sitting in remote-shooting mode:

> `MENU` → **Setup** (wrench) → **IN/OUT** → **LAN / Wi-Fi** → **Wi-Fi Function** →
> **New Connection** → **Remote Shooting & View** → **Via Network** → select the AP

Simply being joined to Wi-Fi for Lumix Sync image transfer is **not** enough — that state
auto-refuses. Once a client name has been granted once, later pairings are silent
(`ok_under_research_no_msg`) and need no operator action — **but only while the body stays in
remote mode.** It drops out of remote mode after hard connection failures, after which
`req_acc_e` returns `err_critical` with a frozen nonce until it is re-armed by hand.

## 4. Camera mode — the easy thing to miss

**After every fresh pairing the camera reports `<cammode>play</cammode>`**, and
`video_recstart` returns `err_critical` in that state. You must send `recmode` first:

```
GET /cam.cgi?mode=camcmd&value=recmode      -> <result>ok</result>
```

This transition takes **~5 s**, and the HTTP server stops answering for part of it — expect
timeouts and poll `getstate` tolerantly until `<cammode>rec</cammode>`. This ~5 s is the
single largest latency in the whole system, and it is paid **once per session**, not per take.

## 4a. Record mode is not self-sustaining

Two separate facts, both measured on `DC-S5M2` fw 3.61:

**`recmode` enters record mode. `startstream` keeps it there.**

| | |
|---|---|
| `startstream` alone, from `play` | **stays in `play`** — 12s observed, never enters `rec` |
| `recmode`, then keepalive only | drifts back to `play` (2s in one run, ~8s in another) |
| `recmode`, then `startstream` | **held `rec` for 45s+** |

So the working order is:

```
pair  ->  recmode (enter)  ->  startstream (hold, within ~2s)
```

A client that skips the stream will appear to work — right up until the first pause
between takes, when `video_recstart` starts returning `err_critical`.

Recovery from a drift should re-issue **`startstream`**, never `recmode`: the stream is
harmless, whereas `recmode` landing during a recording locks the body (§5a).

### `recmode`'s reply code is unreliable

`mode=camcmd&value=recmode` frequently returns `err_critical` **while still succeeding**:

```
recmode -> err_critical
t+2s     cammode=rec      <- it worked
t+8s     cammode=rec
```

Ignore the result and poll `getstate` for `cammode=rec` instead. Treating that
`err_critical` as a failure will stop a client connecting at all.

### Reducing the cost

`liveviewsize` is readable and writable (`qvga`, `vga`, `low`, `standard`, `fine`).
Set it to `qvga` and simply never decode the datagrams — the camera only needs a live
receiver, not an attentive one. Bind the UDP port **before** calling `startstream` so the
first datagrams aren't met with ICMP port-unreachable.

> Actual stream bandwidth was **not measured**: the test host's firewall blocked all
> inbound UDP (0 datagrams in every run, the same block that defeated SSDP), so no
> throughput figure here would be trustworthy.

## 5. Record start / stop

```
GET /cam.cgi?mode=camcmd&value=video_recstart
    Header: X-SESSION_ID: <session>
    -> <?xml version="1.0" encoding="UTF-8"?><camrply><result>ok</result></camrply>

GET /cam.cgi?mode=camcmd&value=video_recstop
    Header: X-SESSION_ID: <session>
    -> <?xml version="1.0" encoding="UTF-8"?><camrply><result>ok</result></camrply>
```

Raw HTTP:

```http
GET /cam.cgi?mode=camcmd&value=video_recstart HTTP/1.1
Host: 10.0.0.177
X-SESSION_ID: F203CA4BF50DC91F
Connection: keep-alive
```

`curl`:

```bash
SID=F203CA4BF50DC91F
curl -s -H "X-SESSION_ID: $SID" "http://10.0.0.177/cam.cgi?mode=camcmd&value=video_recstart"
curl -s -H "X-SESSION_ID: $SID" "http://10.0.0.177/cam.cgi?mode=camcmd&value=video_recstop"
```

> **`mode=camcmd&type=video_recstart` is wrong** — it returns `err_param`. The parameter is
> `value`, not `type`. (The `liblumix` C++ driver enumerates these under `type`; that path is
> dead code there and does not work on this firmware.)

### Confirming it actually rolled

`getstate` is authoritative — `<rec>` flips and `video_remaincapacity` (seconds remaining)
counts down:

```
before  <rec>off</rec><cammode>rec</cammode><video_remaincapacity>8983</video_remaincapacity>
during  <rec>on</rec> <cammode>rec</cammode><video_remaincapacity>8982</video_remaincapacity>
during  <rec>on</rec> <cammode>rec</cammode><video_remaincapacity>8979</video_remaincapacity>
```

**`<rec>` does not settle instantly.** Measured:

| Transition | Time for `<rec>` to reflect it |
|---|---|
| `recstart` → `on` | **~11 ms** (effectively immediate) |
| `recstop` → `off` | **~1.95 s** (camera finalises the clip) |

A client that reads state immediately after `recstop` sees `on` and will get a toggle
backwards. Poll until it settles (allow ~6 s) before acting on it.

Full `getstate` payload (~400 bytes):

```xml
<camrply><result>ok</result><state>
  <batt>2/5</batt><batt_per>-1</batt_per>
  <rec>off</rec><cammode>rec</cammode>
  <video_remaincapacity>8983</video_remaincapacity>
  <remaincapacity>3121</remaincapacity>
  <sdcardstatus>write_enable</sdcardstatus><sd_memory>unset</sd_memory>
  <version>VD4.80</version><temperature>low</temperature><sd_access>off</sd_access>
</state></camrply>
```

## 5a. ⚠️ Never send `recmode` while recording

`mode=camcmd&value=recmode` during an active recording **hard-locks the camera**:
the screen goes black and the body only recovers by removing the battery.
Reproduced on `DC-S5M2` fw 3.61.

This is easy to trigger by accident. The dangerous pattern is a client that treats
an unreadable `getstate` as "probably in playback" and switches mode to be safe —
the camera routinely stops answering for a beat right after `video_recstart`, so
that heuristic fires exactly when recording has just begun.

Rules:

1. Only send `recmode` on a **positively confirmed** `cammode=play` **and** `rec=off`.
2. Treat an unreadable state as "do not touch", never as "in playback".
3. Never rebuild a session out from under an active take — a single missed
   keepalive is normal; require several consecutive misses before reconnecting,
   and never reconnect while `<rec>` is `on`.

## 5bis. ⚠️ `err_busy` is a stop sign, not a retry hint

`err_busy` is a **persistent camera state, not a transient one**. Once in it the camera
still answers `getstate` normally and still reports `cammode=rec`, while rejecting
*every* command — `video_recstart`, `video_recstop` and even `startstream`. Nothing the
client sends clears it; the body needs attention.

`err_busy` means the camera cannot accept the command in its current state.
**Sending anything further into that state escalates into a hard lock** — black
screen, unresponsive physical buttons, recoverable only by removing the battery.
Observed twice on `DC-S5M2` fw 3.61.

Both times the sequence was the same: a command was rejected, the client sent
more commands anyway, the replies degraded to a solid `err_busy` cascade, and
the body then locked.

Treat the first `err_busy` as a latched fault:

1. Stop sending commands entirely — no retries, no re-pair, no mode change.
2. Surface it to a human; the cause is usually on the body (mode dial, playback,
   a dialog, or the camera not being in a state that allows recording).
3. Only resume after someone has actually looked at the camera.

A related trap: the camera can drift from `cammode=rec` back to `play` **on its
own while idle**, with nothing but keepalive traffic. Confirmed by observing the
mode flip during a 10-second idle control period with no commands sent. So
`cammode` must be re-checked before recording rather than assumed to persist.

## 5c. Exposure settings (read + write)

All confirmed round-tripping on `DC-S5M2` fw 3.61, **only while `cammode=rec`**.
In playback every one of these returns `err_busy` / `err_critical`.

| Setting | `type=` | Value form | Example |
|---|---|---|---|
| Shutter | `shtrspeed` | `n/256`, denominator = `2^(n/256)` | `1792/256` = 1/125 |
| Aperture | `focal` | `n/256`, f-number = `2^(n/512)` | `1024/256` = f/4.0 |
| ISO | `iso` | `auto` or a number | `800` |
| Exposure comp | `exposure` | EV in thirds | `1/3`, `0`, `-2/3` |
| White balance | `whitebalance` | token | `cloudy` |
| Video mode | `videoquality` | token | `mov_24p_200mbps_6k_10bit` |
| Container | `videoformat` | `mov` / `mp4` / `mp4ed` / `mp4lite` | `mov` |

A full stop is **256** in both the shutter and aperture numerators, so a third of
a stop is `256/3`. Invalid values are rejected with `err_param` and leave the
current value untouched.

```
GET /cam.cgi?mode=getsetting&type=shtrspeed
    -> <camrply><result>ok</result><settingvalue shtrspeed="1536/256"></settingvalue></camrply>
GET /cam.cgi?mode=setsetting&type=shtrspeed&value=1792/256
    -> <camrply><result>ok</result></camrply>
```

### Option lists

`getinfo&type=curmenu` (~65 KB, ~120 ms) is a flat list of
`<item id="menu_item_id_X" enable="yes|no" value="…">`. The parent carries the
current value; children `menu_item_id_X_<token>` are the options, and only
`enable="yes"` ones are selectable in the camera's current state.

**The menu prefix is not always the setting type:**

| Setting type | Menu prefix |
|---|---|
| `iso` | `sensitivity` |
| `videoquality` | `v_quality` |
| `whitebalance`, `exposure`, `videoformat` | same |

Shutter and aperture have **no** menu entries — they are continuous and bounded
by the lens.

### Lens limits — CSV, not XML

`getinfo&type=lens` breaks the pattern and returns plain CSV:

```
ok,2304/256,935/256,3584/256,1195/256,0,off,60,20,on,128/1024,on,off,l,LUMIX S 20-60/F3.5-5.6,Panasonic,8433,512,
   [1] max f-number  f/22      [3] fastest shutter 1/16000
   [2] min f-number  f/3.5     [4] slowest shutter 1/25       [14] lens name
```

### Cost

A full settings read is **~700 bytes / ~350 ms** for five `getsetting` calls plus
`lens`. `curmenu` is the only large request and only needs fetching once per
session. None of this belongs on a timer — see the keepalive rules above.

## 5b. Capability document

`mode=getinfo&type=capability` (session required) returns ~6.5 KB:

```
comm_proto_ver  10.0
modelname       S5M2
appname         LUMIX_Sync
camcmdlist      tele-normal tele-fast wide-normal wide-fast poweroff 4kphoto_marking
```

Note the `camcmdlist` advertises only *optional extras* — the core verbs
(`recmode`, `video_recstart`, `video_recstop`, `capture`) are **not** listed, so this is
not a usable command-discovery mechanism. Other tags present: `camspeclist`, `asst_disp`,
`crop_disp`, `autouploaddirlist`.

**There is no disconnect / release-session verb**, here or anywhere else found. Graceful
teardown is not available; the session can only be allowed to lapse.

`mode=getsetting&type=device_name` returns `err_non_support` — the stored client name
cannot be read back.

## 6. Session lifetime and keepalive

**Measured, fresh session per trial:**

| Idle | Result |
|------|--------|
| 11 s | alive |
| 12 s | **dead** |

The session dies after **~12 s of silence**, after which everything returns `err_critical`.
Any request resets the timer. Recommended keepalive: **`mode=getstate` every 3 s** — a
comfortable margin, ~130 bytes/s of traffic, and it doubles as your record-state feed.

Recovery from a dead session is cheap and needs no operator action *while the body is still in
remote mode*: re-pair (~650 ms) then `recmode` (~5 s).

## 7. Measured latency

With the session and rec mode kept warm by a keepalive:

| Operation | Time |
|-----------|------|
| `video_recstart` | **12–70 ms** |
| `video_recstop` | **10–45 ms** |
| `req_acc_g` + `req_acc_e` (known client) | ~650 ms |
| `recmode` (play → rec) | ~5.0 s |
| Cold: pair + recmode + recstart | ~6.5 s |

The design conclusion is sharp: **hold the session open.** A warm session gives a
~10–70 ms shutter. Letting it lapse costs ~6.5 s to get back to rolling, dominated by the
mode switch.

## 8. Reference client

`tools/lumix.py` (stdlib only) implements all of the above — discovery, handshake, session
cache, keepalive thread, `err_critical` auto-recovery, and refusal handling that will not
trip the lockout.

```bash
python tools/lumix.py describe              # UPnP info, no session needed
python tools/lumix.py pair                  # handshake, leaves camera in rec mode
python tools/lumix.py state                 # parsed getstate
python tools/lumix.py cycle --seconds 5     # start, hold 5s, stop
python tools/lumix.py start
python tools/lumix.py stop
python tools/lumix.py raw --query "mode=getinfo&type=capability"
```

Minimal embeddable version:

```python
import re, time, urllib.request

IP = "10.0.0.177"
NAME = "shutter"

def cgi(q, sid=None, timeout=8):
    r = urllib.request.Request("http://%s/cam.cgi?%s" % (IP, q),
                               headers={"X-SESSION_ID": sid} if sid else {})
    return urllib.request.urlopen(r, timeout=timeout).read().decode()

def pair():
    ddd = urllib.request.urlopen("http://%s:60606/Lumix/Server0/ddd" % IP).read().decode()
    udn = re.search(r"<UDN>uuid:(.*?)</UDN>", ddd).group(1)
    cgi("mode=accctrl&type=req_acc_g")
    q = ("mode=accctrl&type=req_acc_e&value=%s&value2=%s"
         % (udn.encode().hex(), NAME.encode().hex()))
    for _ in range(60):
        body = cgi(q).strip()
        state = body.split(",")[0]
        if state == "ok":
            return body.split(",")[-1]                 # session id
        if state == "err_user_refused":
            raise SystemExit("refused - arm the camera; DO NOT retry (lockout risk)")
        time.sleep(0.5)                                 # ok_under_research*
    raise SystemExit("pairing timed out")

def cammode(sid):
    m = re.search(r"<cammode>(\w+)</cammode>", cgi("mode=getstate", sid))
    return m.group(1) if m else None

sid = pair()
if cammode(sid) != "rec":                               # always true after pairing
    try: cgi("mode=camcmd&value=recmode", sid, timeout=12)
    except Exception: pass                              # unresponsive mid-switch
    t = time.time()
    while time.time() - t < 20:
        try:
            if cammode(sid) == "rec": break
        except Exception: pass
        time.sleep(0.3)

cgi("mode=camcmd&value=video_recstart", sid)
time.sleep(5)                                           # keep pinging if longer than ~10s
cgi("mode=camcmd&value=video_recstop", sid)
```

## 9. Recommended architecture for a shutter box

1. On boot: `describe` → `pair` → `recmode`. Pay the ~5 s once.
2. Run a keepalive thread: `getstate` every 3 s. Parse `<rec>` from it for free — that gives
   you a rec tally light with zero extra traffic.
3. Shutter press → `video_recstart` / `video_recstop`. ~10–70 ms.
4. On any `err_critical`: re-pair, re-`recmode`, retry once.
5. On `err_user_refused`: **stop and alert a human.** Do not retry.
6. Never call `startstream`.

Watch for: `<sdcardstatus>`, `<video_remaincapacity>` hitting 0, `<temperature>`, and
`<batt>` (only 5 coarse steps; `batt_per` reads `-1` and is useless).

## 10. Confirmed vs. inferred

**Confirmed experimentally on this body:**

- Ports 80 / 60606 / 50001 open; 15740, 554, 1900, 5000, 8080, 49152 closed
- `ddd` endpoint, path, and all fields quoted above
- Full `req_acc_g` → `req_acc_e` handshake, hex encoding, CSV replies, all six status strings
- `X-SESSION_ID` mandatory; absent ⇒ `err_critical` on every endpoint
- Legacy `type=req_acc` ⇒ `err_param`
- One pending request slot; identical `req_acc_e` polls it, different one ⇒ `err_others_requesting`
- Session idle timeout between 11 s (alive) and 12 s (dead)
- Camera is in `play` mode after every pairing; `recmode` required; ~5 s; HTTP unresponsive during
- `video_recstart` / `video_recstop` via `value=` → `ok`, verified by `<rec>on</rec>` and a
  decrementing `video_remaincapacity`
- `type=video_recstart` ⇒ `err_param`
- Latencies in §7
- Recording works with **no** `startstream` — live view fully avoidable
- The "invalid login" lockout triggered by repeated `err_user_refused` (hit accidentally, recovered by power cycle)
- Body silently leaves remote mode after hard failures; nonce freezes and `req_acc_e` ⇒ `err_critical` until re-armed
- **`recmode` during an active recording hard-locks the camera** (black screen,
  recovers only by pulling the battery)
- Hung state: port 60606 keeps **accepting TCP** while the HTTP server never responds
  (5× consecutive 8 s timeouts) — TCP-open is not proof of a working camera
- `<rec>` settle times: `on` ~11 ms, `off` ~1.95 s
- Client names are remembered once accepted ⇒ later pairings are silent
- Re-arming during `ok_under_research` orphans the operator's acceptance
- `getinfo&type=capability` contents; `getsetting&type=device_name` ⇒ `err_non_support`
- No disconnect/release verb exists in the capability document
- Discovery by /24 sweep on :60606 — 0.78 s cold, ~40–134 ms from cache
- A 3 s keepalive holds a session indefinitely (53 s+ observed, same session id, 0 reconnects)

**Not confirmed / inferred:**

- SSDP discovery — local firewall blocked all SSDP replies, so untested either way
- Purpose of port 50001 (accepts TCP, silent to HTTP and RTSP probes)
- Intended use of the `req_acc_g` nonce — pairing works without ever sending it back
- Whether `value` should be the *client's* UUID rather than the camera's UDN. Older
  documentation (`lumixproto`) describes it as a client UUID; sending the **camera's** UDN
  works, and raw (non-hex) UDN was also accepted into `ok_under_research`. Not disambiguated.
- Exact refusal count that trips the lockout (deliberately not re-tested)
- 3 s keepalive is a recommendation with margin; only the ~12 s death boundary was measured
- Behaviour on other firmware or S5IIX / GH6 / G9II bodies
- **The `value2` encoding that renders the client name correctly on the connect prompt.**
  `hex(utf-8)` renders as CJK squares. `hex(utf-16-le)` showed `-`, but that observation is
  contaminated by the re-arm race above, so it is not a clean result. `setsetting
  device_name` accepts plain, utf-8-hex, utf-16-le-hex and utf-16-be-hex all with `ok`, and
  cannot be read back, so it gives no signal either. **Still open.**

## 11. Non-network alternatives, briefly

If the goal is shutter reliability rather than networking specifically, the S5II also has a
**2.5 mm wired remote jack** (DMW-RS2 compatible — a trivial switch closure, zero protocol,
zero latency, no pairing) and **BLE remote shutter** via the Lumix Sync pairing. The wired
jack is by far the most robust trigger; the LAN path's real advantage is that it also gives
you state feedback and works at distance.

---

## Sources

- [njfdev/liblumix](https://github.com/njfdev/liblumix) — C++ driver developed against an
  S5IIX; source of the `req_acc_g`/`req_acc_e` + `X-SESSION_ID` flow and the keepalive note
- [cleverfox/lumixproto](https://github.com/cleverfox/lumixproto) — GX80 protocol notes,
  original `video_recstart` / `video_recstop` documentation
- [palmdalian/python_lumix_control](https://github.com/palmdalian/python_lumix_control) — classic `cam.cgi` client
- [gphoto/libgphoto2 #409](https://github.com/gphoto/libgphoto2/issues/409) — Lumix HTTP/Wi-Fi protocol discussion
- [Panasonic DC-S5M2X tethering docs](https://eww.pavc.panasonic.co.jp/dscoi/DC-S5M2X/html/DC-S5M2X_DVQP2992_eng/0152.html) — confirms Tether-over-LAN needs a USB-Ethernet adaptor and disables Wi-Fi/Bluetooth
