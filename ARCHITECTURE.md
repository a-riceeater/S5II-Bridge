# S5II control — architecture, and how it maps to iOS

Companion to `LUMIX_S5II_LAN_RECORD_CONTROL.md` (the wire protocol). This document
covers *structure*: why the code is split the way it is, and what changes when this
becomes an iOS app.

## The one design constraint that drives everything

**The S5II expects a single controller that stays connected.**

A short-lived process that pairs, fires `video_recstart`, and exits abandons the
session. The camera notices its controller vanished, displays *"connection failed"*,
and drops out of remote-control mode. Observed downstream symptoms:

- `req_acc_e` starts returning `err_critical` with a **frozen** `req_acc_g` nonce
- port 60606 still **accepts TCP** but the HTTP server **never responds** — a hung
  body looks "reachable" to a naive port scan
- recovery requires re-arming the camera by hand, sometimes a power cycle

So the correct shape is a long-lived object owning the session, with everything else
talking to *it* — never to the camera directly.

```
        ┌──────────────────────────────────────────────┐
        │  LumixBridge (long-lived, owns the session)  │
        │                                              │
        │  discover ─► pair ─► ensure rec ─► keepalive │
        │       ▲                                 │    │
        │       └──────── supervisor loop ◄───────┘    │
        └───────────────┬──────────────────────────────┘
                        │  start / stop / toggle / status
        ┌───────────────┴───────────────┐
        │  transport (swappable)        │
        │  CLI+HTTP today │ SwiftUI/    │
        │                 │ Shortcuts   │
        └───────────────────────────────┘
```

Keeping the session warm is also a **performance** decision, not just a stability one:
a warm session makes `recstart` ~10–70 ms. A cold one costs ~6.5 s, because the
`play → rec` transition (~5 s) is paid per session, not per take.

## Layers

| Layer | File | Responsibility | iOS equivalent |
|---|---|---|---|
| Discovery | `tools/discover.py` | Find cameras by UDN, cache addresses | `NWConnection` + `TaskGroup` |
| Protocol | `tools/lumix.py` | `cam.cgi` verbs, pairing, session, encodings | `URLSession` actor |
| Session owner | `tools/bridge.py` | Keepalive, supervision, reconnect, state | `@Observable` object / actor |
| Transport | `bridge.py` HTTP | Local JSON API | SwiftUI views, Shortcuts, Watch |

The split matters: **only the bridge layer is allowed to hold a session.** The CLI is a
client of the bridge, not of the camera.

## Discovery

No manual IP. Three strategies, cheapest first:

1. **Cached address** — verify the last known IP via `:60606/Lumix/Server0/ddd`. ~40 ms.
2. **Subnet sweep** — concurrent TCP probe of the local `/24` on port 60606, then an
   HTTP verify on hosts that answer. **Measured: 0.78 s for a full /24.**
3. **SSDP** — optional, off by default.

Cameras are keyed by **UDN**, not IP, so DHCP reassignment is transparent.

### Why the sweep is primary, not the fallback

This is the decision that most affects the iOS port:

- **SSDP/mDNS need multicast.** On iOS, SSDP requires the
  `com.apple.developer.networking.multicast` entitlement — Apple grants it only on
  request with written justification. That is a real shipping risk for a feature you
  can get without it.
- **A TCP sweep needs no entitlement**, only the standard local-network permission
  (`NSLocalNetworkUsageDescription`), which every LAN app already prompts for.
- It is fast enough that the optimisation is not worth the entitlement.

Bonjour/`NWBrowser` would avoid the entitlement too, but **it is unverified whether
the camera advertises any mDNS service** — do not design around it without testing.

### Validation gate

A host counts as a camera only if `ddd` parses **and** `manufacturer` contains
"Panasonic" **and** a `UDN` is present. This matters because of the hung-body failure
mode: TCP-open is not evidence of a working camera. Always require a parsed HTTP
response.

### Swift sketch

```swift
actor LumixDiscovery {
    struct Camera: Sendable { let ip: String; let udn: String; let model: String }

    func find(udn: String? = nil) async -> Camera? {
        if let c = cached, let hit = try? await verify(c.ip), udn == nil || hit.udn == udn {
            return hit                                   // ~40 ms
        }
        return await sweep(subnet: LocalInterface.current.subnet, matching: udn)
    }

    private func sweep(subnet: [String], matching udn: String?) async -> Camera? {
        await withTaskGroup(of: Camera?.self) { group in
            for host in subnet {                          // cap concurrency ~64 on iOS
                group.addTask { try? await self.verify(host, connectTimeout: .milliseconds(350)) }
            }
            for await case let c? in group where udn == nil || c.udn == udn {
                group.cancelAll()
                return c
            }
            return nil
        }
    }
}
```

Cap concurrency around 64 on iOS — 128+ simultaneous `NWConnection`s will hit file
descriptor pressure on a phone.

## The client-name encoding

The camera **hex-decodes `value2` and renders the result as UTF-16.** Sending hex of
UTF-8 — what `liblumix` does — makes the on-screen connect prompt show CJK characters
or empty squares. This is why the prompt read as garbage.

```
name            "S5II Bridge"
utf-16-le hex   53003500490049002000420072006900640067006500   <- renders correctly
utf-8 hex       5335494920427269646765                          <- renders as squares
```

Proof by construction: our old UTF-8 bytes `7335696963746c` ("s5iictl"), re-read as
UTF-16LE, decode to `0x3573 0x6969 0x7463` — CJK codepoints, exactly the squares seen.

`value` (the UDN) stays **plain ASCII hex** — it is byte-compared, never displayed.

> **Status: still open.** `hex(utf-8)` demonstrably renders as CJK squares. A `hex(utf-16-le)`
> attempt displayed `-`, but that test was contaminated by the re-arm race (below), which
> blanks the pending request's name — so it is not a clean negative.
> `setsetting device_name` accepts plain, utf-8-hex, utf-16-le-hex and utf-16-be-hex all
> with `ok`, and `getsetting device_name` returns `err_non_support`, so there is **no
> programmatic read-back** to test against. Confirming this needs one clean pairing against
> an *unregistered* name with a human reading the screen.
> `Lumix.NAME_ENCODINGS` makes it a one-flag change.

### The re-arm race (fixed)

`ok_under_research` means a dialog is up and a human is being asked. Re-arming with
`req_acc_g` while it is displayed **replaces the pending request**, so the operator's
acceptance applies to a request the client already abandoned: the client hangs in
`CONNECTING` forever and the on-screen name can blank to `-`. `pair()` now extends its
deadline to 240 s on first seeing `ok_under_research` and never re-arms while it is up.

## Recording state settles asynchronously

`<rec>` is not a synchronous acknowledgement:

| Transition | Settle time |
|---|---|
| `recstart` → `<rec>on` | ~11 ms |
| `recstop` → `<rec>off` | **~1.95 s** (clip finalisation) |

A toggle that reads state immediately after `recstop` sees `on` and starts a new
recording instead of confirming the stop. `LumixBridge` polls until the expected value
appears (6 s cap) before returning, and `record_toggle` reads fresh state rather than
the cached keepalive sample. **Any iOS UI must do the same** — and should show a
"stopping…" state for those ~2 s rather than pretending it's instant.

## There is no live view — but there is a stream

The app shows no preview and decodes no frames. It still runs `startstream`,
because the camera will not *stay* in record mode without one:

| | |
|---|---|
| `recmode`, keepalive only | `cammode` falls back to `play` (2 s / ~8 s) |
| `recmode`, then `startstream` | held `cammode=rec` for 45 s+ |
| `startstream` alone from `play` | stays in `play` — never enters `rec` |

So `recmode` **enters** record mode and `startstream` **holds** it. `StreamSink`
exists only to give the camera somewhere to send the datagrams: it binds the UDP
port, drains it, and discards every byte at the smallest frame size (`qvga`).

`StreamSink` is deliberately **not** `@MainActor` — Network framework delivers on
its own queue, and hopping to the main actor to throw bytes away is pure waste.

## `recmode` never touches the shutter path

`recmode` is the command that freezes the camera. The subtle trap: a client wants
to check `cammode` before rolling and fix it if it reads `play` — but the cached
value is up to one keepalive old, so **it can read `play` while the camera is
already recording**, and `recmode` then freezes the body.

It is therefore sent exactly once, at connect. Drift recovery on the shutter path
re-issues `startstream` instead, which is harmless in every state.

## Releasing the camera

A Lumix under remote control disables its physical buttons. That is normal, but a
client that auto-connects makes it inescapable: freeing the camera on the body is
instantly undone by the client re-pairing. Disconnect is therefore **sticky** —
`userDisconnected` suppresses auto-connect on both launch and foreground until an
explicit Connect — and surfaced as a "Release camera" button on the main screen.

## Session lifecycle

```
DISCONNECTED ──► SEARCHING ──► CONNECTING ──► READY
      ▲                             │            │
      └──── keepalive failure ◄─────┘            │
                                                 │
                            REFUSED ◄────────────┘   (terminal until a human acts)
```

- **Keepalive**: `mode=getstate` every **3 s** (session dies at ~12 s of silence).
  It doubles as the state feed, so it costs nothing extra — parse `<rec>` from it for a
  free tally light.
- **Reconnect**: exponential backoff 2 s → 30 s on failure.
- **`REFUSED` is terminal by design.** `err_user_refused` means the body is not armed.
  Retrying is what trips the camera's "invalid login" lockout, which needs a physical
  power cycle. The supervisor parks in `REFUSED` and waits for an explicit `/reconnect`.

On iOS this maps to an actor with a `Task` running the supervisor loop. Two extra
concerns that do not exist on desktop:

- **Backgrounding kills the session.** iOS suspends timers, the keepalive stops, the
  session dies within ~12 s. Re-pair on `willEnterForeground` rather than trying to
  keep it alive in the background — reconnect is only ~650 ms plus the mode switch.
- **Wi-Fi association changes** (leaving the AP, moving to cellular) invalidate the IP.
  Watch `NWPathMonitor` and force rediscovery on path change.

## Answering "how do I stop it entering the critical state"

`err_critical` has two distinct causes; only one is preventable in software.

| Cause | Prevention |
|---|---|
| Session expired (>12 s idle) | **Solved** — 3 s keepalive, plus auto re-pair on `err_critical` |
| Body left remote mode | Not preventable in software. Caused by abandoning the session, and by the hung-HTTP state. Mitigated by never letting a short-lived process own a session, and by graceful teardown. |

Practical rules, in priority order:

1. **One long-lived owner.** Never pair from a process that is about to exit.
2. **Keepalive at 3 s.** Never let the session lapse while you intend to keep control.
3. **Never retry `err_user_refused`.** This is the only truly destructive failure.
4. **Stop recording on teardown.** Don't leave the camera rolling with no controller.
5. **Treat "TCP open, no HTTP" as hung**, not as reachable. Fail fast (≤2.5 s) rather
   than blocking on long timeouts.

There is **no confirmed "release session" verb.** Probing for one would mean guessing
`accctrl` type strings, which risks the lockout, so it was not attempted. If one exists
it would make teardown cleaner and likely reduce the "connection failed" occurrences.

## Measured results

| | |
|---|---|
| Discovery, cold /24 sweep | **0.78 s** |
| Discovery, cached | 40–134 ms |
| Bridge cold start → READY | **~2 s** (camera already in rec mode) |
| Session held by 3 s keepalive | 53 s+ observed, same session id, **0 reconnects** |
| `recstart` / `recstop` warm | 12–70 ms / 10–45 ms |

Three consecutive start/stop cycles plus a toggle pair all returned correct state.

## Running it

```bash
python tools/bridge.py --name "S5II Bridge"      # holds the session; leave running
curl localhost:8777/status
curl -X POST localhost:8777/record/start
curl -X POST localhost:8777/record/stop
curl -X POST localhost:8777/record/toggle
```

`tools/lumix.py` remains a standalone one-shot CLI for protocol poking and debugging.
It is deliberately *not* the recommended way to drive recording — it has the
abandoned-session problem by construction. Use the bridge for anything real.

## Suggested iOS module layout

```
LumixKit/
  Discovery/   LumixDiscovery.swift      NWConnection sweep, UDN cache
  Protocol/    CamCGI.swift              verb builders, XML/CSV parsing
               PairingCodec.swift        UTF-16 hex for value2, ASCII hex for value
  Session/     LumixSession.swift        actor: pair, keepalive, auto-recovery
               SessionState.swift        the state machine above
  Control/     RecordController.swift    start/stop/toggle + observable state
App/
  BridgeViewModel.swift                  @Observable wrapper
  ShortcutsIntents.swift                 AppIntent for a hardware trigger
```

Keep `LumixKit` free of UI and of `URLSession` convenience APIs that don't let you set
per-request timeouts — the hung-camera case makes tight timeouts essential.
