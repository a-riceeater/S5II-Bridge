#!/usr/bin/env python3
"""Discovery + port probe for a Panasonic Lumix camera on the LAN. Stdlib only."""
import socket, sys, urllib.request, urllib.error, concurrent.futures, re

IP = sys.argv[1] if len(sys.argv) > 1 else "10.0.0.177"

# Ports worth checking on Lumix bodies.
PORTS = {
    80:    "HTTP  /cam.cgi control API",
    554:   "RTSP (BGH1-class only)",
    1900:  "SSDP (usually UDP)",
    5000:  "misc",
    8080:  "alt HTTP",
    15740: "PTP/IP (LUMIX Tether)",
    49152: "UPnP/live-view UDP range",
    50001: "misc",
    60606: "UPnP device description (Lumix)",
}

def tcp(ip, port, timeout=1.5):
    s = socket.socket()
    s.settimeout(timeout)
    try:
        return s.connect_ex((ip, port)) == 0
    finally:
        s.close()

def http_get(url, timeout=5, headers=None):
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return None, f"{type(e).__name__}: {e}"

def ssdp(timeout=4):
    """M-SEARCH for any UPnP root device; return list of (addr, response)."""
    msg = ("M-SEARCH * HTTP/1.1\r\n"
           "HOST: 239.255.255.250:1900\r\n"
           'MAN: "ssdp:discover"\r\n'
           "MX: 3\r\n"
           "ST: ssdp:all\r\n\r\n").encode()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.settimeout(timeout)
    out = []
    try:
        s.sendto(msg, ("239.255.255.250", 1900))
        while True:
            try:
                data, addr = s.recvfrom(65507)
            except socket.timeout:
                break
            out.append((addr[0], data.decode("utf-8", "replace")))
    finally:
        s.close()
    return out

print(f"=== TCP port scan {IP} ===")
with concurrent.futures.ThreadPoolExecutor(max_workers=16) as ex:
    res = dict(zip(PORTS, ex.map(lambda p: tcp(IP, p), PORTS)))
for p, desc in PORTS.items():
    print(f"  {p:>6}  {'OPEN' if res[p] else 'closed':>6}  {desc}")

print(f"\n=== SSDP M-SEARCH (all devices on LAN) ===")
seen = ssdp()
if not seen:
    print("  (no SSDP responses)")
for addr, resp in seen:
    loc = re.search(r"(?im)^LOCATION:\s*(.+)$", resp)
    srv = re.search(r"(?im)^SERVER:\s*(.+)$", resp)
    mark = "  <<< TARGET" if addr == IP else ""
    print(f"  {addr:<16} {loc.group(1).strip() if loc else '?'}{mark}")
    if addr == IP and srv:
        print(f"      SERVER: {srv.group(1).strip()}")

print(f"\n=== UPnP device description candidates ===")
for path in ["/Lumix/Server0/ddd", "/Server0/ddd", "/nmrp/device.xml", "/ddd"]:
    url = f"http://{IP}:60606{path}"
    code, body = http_get(url)
    print(f"  {url} -> {code}")
    if code == 200:
        for tag in ["friendlyName", "manufacturer", "modelName", "modelNumber",
                    "serialNumber", "UDN", "pana:X_FirmVersion"]:
            m = re.search(rf"<{re.escape(tag)}>(.*?)</{re.escape(tag)}>", body, re.S)
            if m:
                print(f"      {tag:<20} = {m.group(1).strip()}")
        break

print(f"\n=== bare cam.cgi reachability (no session) ===")
for q in ["mode=getstate", "mode=getinfo&type=capability"]:
    code, body = http_get(f"http://{IP}/cam.cgi?{q}")
    print(f"  ?{q} -> {code}\n      {body[:300].strip()}")
