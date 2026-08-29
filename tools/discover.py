#!/usr/bin/env python3
"""
Lumix camera discovery. No multicast, no manual IP.

Strategy (in order, each cheap enough to just run):
  1. Verify a cached address        -- ~50 ms when the camera hasn't moved
  2. Sweep the local /24 on :60606  -- ~1-2 s, no special permissions
  3. (optional) SSDP M-SEARCH       -- fast but needs multicast; off by default

Cameras are identified by UDN, not by IP, so a DHCP reassignment is transparent.
This module is deliberately structured to mirror what the iOS client will do:
enumerate local interfaces -> concurrent TCP probe -> HTTP verify -> match UDN.
"""
import concurrent.futures as cf
import ipaddress, json, os, re, socket, sys, time
import urllib.request, urllib.error

CACHE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".lumix_cameras.json")
DDD_PORT = 60606
DDD_PATHS = ("/Lumix/Server0/ddd", "/Server0/ddd")


class Camera(object):
    def __init__(self, ip, info):
        self.ip = ip
        self.info = info

    @property
    def udn(self):
        u = self.info.get("UDN", "")
        return u[5:] if u.startswith("uuid:") else u

    @property
    def name(self):
        return self.info.get("friendlyName", "?")

    @property
    def model(self):
        return self.info.get("modelNumber", "?")

    def __repr__(self):
        return "<Camera {} {} at {} fw {}>".format(
            self.model, self.name, self.ip, self.info.get("pana:X_FirmVersion", "?"))

    def to_dict(self):
        return {"ip": self.ip, "info": self.info}


# ---------- low level ----------
def _tcp_open(ip, port, timeout):
    s = socket.socket()
    s.settimeout(timeout)
    try:
        return s.connect_ex((str(ip), port)) == 0
    except Exception:
        return False
    finally:
        s.close()


def fetch_ddd(ip, timeout=2.5):
    """Fetch + parse the UPnP description. Returns info dict or None."""
    for path in DDD_PATHS:
        try:
            url = "http://{}:{}{}".format(ip, DDD_PORT, path)
            with urllib.request.urlopen(url, timeout=timeout) as r:
                if r.status != 200:
                    continue
                body = r.read().decode("utf-8", "replace")
        except Exception:
            continue
        info = {}
        for tag in ("friendlyName", "manufacturer", "modelName", "modelNumber",
                    "serialNumber", "UDN", "pana:X_FirmVersion"):
            m = re.search(r"<{}>(.*?)</{}>".format(re.escape(tag), re.escape(tag)),
                          body, re.S)
            if m:
                info[tag] = m.group(1).strip()
        # Only accept an actual Panasonic camera, not some other UPnP device.
        if "panasonic" in info.get("manufacturer", "").lower() and info.get("UDN"):
            return info
    return None


def probe(ip, connect_timeout=0.35):
    """Cheap TCP gate, then a real HTTP verify only on hosts that answer."""
    if not _tcp_open(ip, DDD_PORT, connect_timeout):
        return None
    info = fetch_ddd(ip)
    return Camera(str(ip), info) if info else None


# ---------- interface enumeration ----------
def local_ipv4s():
    """Local IPv4 addresses, best-effort and dependency-free."""
    addrs = set()
    try:                                     # the address used for off-link traffic
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        addrs.add(s.getsockname()[0])
        s.close()
    except Exception:
        pass
    try:
        for res in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            addrs.add(res[4][0])
    except Exception:
        pass
    return {a for a in addrs if not a.startswith("127.")}


def candidate_networks(prefix=24):
    return [ipaddress.ip_network("{}/{}".format(a, prefix), strict=False)
            for a in sorted(local_ipv4s())]


# ---------- discovery ----------
def sweep(network, workers=128, connect_timeout=0.35, first_only=True):
    """Concurrently probe every host in `network`. Returns list of Camera."""
    hosts = [h for h in network.hosts()]
    found = []
    with cf.ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(probe, h, connect_timeout): h for h in hosts}
        for f in cf.as_completed(futs):
            cam = f.result()
            if cam:
                found.append(cam)
                if first_only:
                    for other in futs:
                        other.cancel()
                    break
    return found


def ssdp(timeout=3.0):
    """Optional multicast fast path. Needs firewall/multicast permission."""
    msg = ("M-SEARCH * HTTP/1.1\r\n"
           "HOST: 239.255.255.250:1900\r\n"
           'MAN: "ssdp:discover"\r\n'
           "MX: 2\r\nST: ssdp:all\r\n\r\n").encode()
    out = []
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.settimeout(timeout)
    try:
        s.sendto(msg, ("239.255.255.250", 1900))
        end = time.time() + timeout
        seen = set()
        while time.time() < end:
            try:
                _, addr = s.recvfrom(65507)
            except socket.timeout:
                break
            if addr[0] in seen:
                continue
            seen.add(addr[0])
            info = fetch_ddd(addr[0], timeout=1.5)
            if info:
                out.append(Camera(addr[0], info))
    except Exception:
        pass
    finally:
        s.close()
    return out


# ---------- cache ----------
def load_cache():
    try:
        with open(CACHE_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def save_cache(cams):
    data = load_cache()
    for c in cams:
        data[c.udn] = c.to_dict()
    try:
        with open(CACHE_FILE, "w") as f:
            json.dump(data, f, indent=2)
    except Exception:
        pass


def find(udn=None, use_ssdp=False, verbose=True):
    """
    Locate a camera. If `udn` is given, only that specific body matches.
    Returns a Camera or None.
    """
    def log(m):
        if verbose:
            print(m)

    # 1. cached address
    for cached_udn, entry in load_cache().items():
        if udn and cached_udn != udn:
            continue
        t = time.time()
        info = fetch_ddd(entry["ip"], timeout=1.5)
        if info and (not udn or info.get("UDN", "")[5:] == udn):
            log("  cache hit: {} ({:.0f} ms)".format(entry["ip"], (time.time() - t) * 1000))
            return Camera(entry["ip"], info)

    # 2. optional multicast
    if use_ssdp:
        t = time.time()
        for c in ssdp():
            if not udn or c.udn == udn:
                log("  via SSDP: {} ({:.0f} ms)".format(c.ip, (time.time() - t) * 1000))
                save_cache([c])
                return c

    # 3. subnet sweep
    for net in candidate_networks():
        t = time.time()
        log("  sweeping {} ...".format(net))
        for c in sweep(net, first_only=(udn is None)):
            if not udn or c.udn == udn:
                log("  found {} ({:.1f} s)".format(c, time.time() - t))
                save_cache([c])
                return c
    return None


if __name__ == "__main__":
    want = sys.argv[1] if len(sys.argv) > 1 else None
    t0 = time.time()
    cam = find(udn=want)
    print("\n{}".format(cam if cam else "no Lumix camera found"))
    if cam:
        print("  udn   {}".format(cam.udn))
        print("  model {}   fw {}".format(cam.model, cam.info.get("pana:X_FirmVersion")))
    print("  total {:.2f} s".format(time.time() - t0))
