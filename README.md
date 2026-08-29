# S5II Bridge

Remote video record start/stop for the **Panasonic Lumix S5II** over Wi-Fi/LAN, with
**no live-view stream** — a low-bandwidth shutter instead of the multi-Mbit/s MJPEG feed
the Lumix Sync app opens.

Reverse-engineered against a real `DC-S5M2` on firmware `3.61`.

```bash
python tools/bridge.py --name "S5II Bridge"     # discovers, pairs, holds the session

curl        localhost:8777/status
curl -X POST localhost:8777/record/start
curl -X POST localhost:8777/record/stop
curl -X POST localhost:8777/record/toggle
```

## What it does

- **Finds the camera itself** — no hardcoded IP. Concurrent sweep of the local /24 on
  port 60606, ~0.78 s cold, ~40 ms from cache. Cameras are keyed by UDN, so DHCP
  reassignment is transparent.
- **Holds one long-lived session.** The camera drops an idle session after ~12 s; a 3 s
  keepalive holds it open indefinitely.
- **Sub-100 ms shutter.** `recstart` 12–70 ms, `recstop` 10–45 ms on a warm session.
- **Recovers by itself** from session expiry, and refuses to retry the one failure mode
  that can lock the camera out.

## Why a long-lived bridge, not a one-shot CLI

The S5II expects a single controller that stays connected. A short-lived process that
pairs, fires a command and exits abandons the session — the camera reports
*"connection failed"*, drops out of remote mode, and afterwards accepts TCP on port 60606
while never answering HTTP. Recovering needs a manual re-arm, sometimes a power cycle.

So exactly one component holds the session, and everything else talks to it.

## ⚠️ The one destructive failure mode

`err_user_refused` means the camera is not armed to accept a new remote device. **Never
retry it.** The firmware counts refused attempts and after a handful shows *"An invalid
login occurred. Please turn the power off and then on again"*, drops off the network, and
needs a physical power cycle.

To arm the camera for a new client:

> `MENU` → Setup → IN/OUT → LAN/Wi-Fi → **Wi-Fi Function** → **New Connection** →
> **Remote Shooting & View** → Via Network

Once a client name has been accepted the camera remembers it and later connections are
silent.

## Layout

| Path | What |
|---|---|
| `tools/bridge.py` | Long-lived session owner + local JSON API. **Use this.** |
| `tools/lumix.py` | Protocol layer: `cam.cgi` verbs, pairing, session, keepalive |
| `tools/discover.py` | UDN-keyed discovery with address caching |
| `tools/probe.py` | Port scan / SSDP / device-description dump for diagnostics |
| [`LUMIX_S5II_LAN_RECORD_CONTROL.md`](LUMIX_S5II_LAN_RECORD_CONTROL.md) | The wire protocol, with exact requests and what's confirmed vs inferred |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Structure, and how it maps onto a planned iOS client |

`tools/lumix.py` also works standalone (`python tools/lumix.py cycle --seconds 5`) but is
meant for protocol poking — it has the abandoned-session problem by construction.

## Protocol in one block

```
GET :60606/Lumix/Server0/ddd                                  -> UDN
GET /cam.cgi?mode=accctrl&type=req_acc_g                      -> ok,<nonce>
GET /cam.cgi?mode=accctrl&type=req_acc_e&value=<hex UDN>&value2=<hex name>
                                                              -> ok,...,<SESSION_ID>
GET /cam.cgi?mode=camcmd&value=recmode        + X-SESSION_ID  (~5 s, once per session)
GET /cam.cgi?mode=camcmd&value=video_recstart + X-SESSION_ID
GET /cam.cgi?mode=camcmd&value=video_recstop  + X-SESSION_ID
```

Every request after the handshake carries `X-SESSION_ID`; without it everything returns
`err_critical`. Note `mode=camcmd&value=…`, **not** `type=` — the `type=` form returns
`err_param`.

## Requirements

Python 3.8+. Standard library only.

## Status

Record start/stop, discovery, session management and recovery are all confirmed working
on `DC-S5M2` / fw `3.61`. Known open item: the `value2` encoding that makes the client
name render correctly on the camera's connect prompt — see `ARCHITECTURE.md`.

Not tested on S5IIX, GH6, G9II or other firmware.
