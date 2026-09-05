#!/usr/bin/env python3
"""Measure sustainable throughput of a TURN relay (Cloudflare Calls TURN or coturn).

Self-relay loopback: one TURN allocation, CreatePermission to its own
relayed address, then Send Indications to that address. The relay loops
datagrams back as Data Indications, so a single socket measures the full
relay path (up + down) end to end.

Credentials (either):
  TURN_KEY_ID + TURN_API_TOKEN  -> fetched from Cloudflare Calls API
  TURN_USERNAME + TURN_CREDENTIAL (+ optional TURN_HOST/TURN_PORT) -> used directly

Usage:
  TURN_KEY_ID=... TURN_API_TOKEN=... python3 tools/turn-capacity.py
  python3 tools/turn-capacity.py --rates 2,4,6,8,10 --step-seconds 5
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import random
import socket
import struct
import sys
import threading
import time
import urllib.request
import zlib

MAGIC_COOKIE = 0x2112A442
STUN_HEADER = 20

MSG_ALLOCATE = 0x0003
MSG_ALLOCATE_RESP = 0x0103
MSG_ALLOCATE_ERR = 0x0113
MSG_CREATE_PERM = 0x0008
MSG_CREATE_PERM_RESP = 0x0108
MSG_CREATE_PERM_ERR = 0x0118
MSG_SEND_IND = 0x0016
MSG_DATA_IND = 0x0017
MSG_REFRESH = 0x0004

ATTR_MAPPED_ADDRESS = 0x0001
ATTR_USERNAME = 0x0006
ATTR_MESSAGE_INTEGRITY = 0x0008
ATTR_ERROR_CODE = 0x0009
ATTR_REALM = 0x0014
ATTR_NONCE = 0x0015
ATTR_XOR_RELAYED_ADDRESS = 0x0016
ATTR_XOR_PEER_ADDRESS = 0x0012
ATTR_DATA = 0x0013
ATTR_LIFETIME = 0x000D
ATTR_REQUESTED_TRANSPORT = 0x0019
ATTR_FINGERPRINT = 0x8028

ATTR_PADDING = {ATTR_REALM, ATTR_NONCE, ATTR_USERNAME}


def pad4(n: int) -> int:
    return (n + 3) & ~3


def build_attr(atype: int, value: bytes) -> bytes:
    out = struct.pack(">HH", atype, len(value)) + value
    out += b"\x00" * (pad4(len(value)) - len(value))
    return out


def build_xor_address(atype: int, host: str, port: int, txid: bytes) -> bytes:
    packed_ip = socket.inet_aton(host)
    xport = port ^ (MAGIC_COOKIE >> 16)
    xip = struct.unpack(">I", packed_ip)[0] ^ MAGIC_COOKIE
    value = struct.pack(">BBH I", 0, 0x01, xport, xip)
    return build_attr(atype, value)


def parse_xor_address(value: bytes, txid: bytes) -> tuple[str, int]:
    _, family, xport, xip = struct.unpack(">BBHI", value[:8])
    port = xport ^ (MAGIC_COOKIE >> 16)
    ip = socket.inet_ntoa(struct.pack(">I", xip ^ MAGIC_COOKIE))
    return ip, port


class TurnError(Exception):
    pass


class TurnClient:
    def __init__(self, host: str, port: int, username: str, credential: str):
        self.host = host
        self.port = port
        self.username = username
        self.credential = credential
        self.realm: str | None = None
        self.nonce: str | None = None
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(3.0)
        self.txid = random.randbytes(12)
        self.relayed: tuple[str, int] | None = None
        self.peer: tuple[str, int] | None = None
        self.lock = threading.Lock()
        self.data_handler = None

    def _message(self, mtype: int, attrs: list[tuple[int, bytes]], integrity: bool) -> bytes:
        body = b""
        for atype, value in attrs:
            body += build_attr(atype, value)
        if integrity:
            assert self.realm is not None and self.nonce is not None
            body += build_attr(ATTR_USERNAME, self.username.encode())
            body += build_attr(ATTR_REALM, self.realm.encode())
            body += build_attr(ATTR_NONCE, self.nonce.encode())
            mi_len = len(body) + 24
            header = struct.pack(">HHI12s", mtype, mi_len, MAGIC_COOKIE, self.txid)
            key = hashlib.md5(f"{self.username}:{self.realm}:{self.credential}".encode()).digest()
            mac = hmac.new(key, header + body, hashlib.sha1).digest()
            body += build_attr(ATTR_MESSAGE_INTEGRITY, mac)
        fp_len = len(body) + 8
        header = struct.pack(">HHI12s", mtype, fp_len, MAGIC_COOKIE, self.txid)
        crc = zlib.crc32(header + body) ^ 0x5354554E
        body += build_attr(ATTR_FINGERPRINT, struct.pack(">I", crc))
        return struct.pack(">HHI12s", mtype, len(body), MAGIC_COOKIE, self.txid) + body

    def _parse(self, data: bytes) -> tuple[int, dict[int, bytes]]:
        mtype, mlen, cookie = struct.unpack(">HHI", data[:8])
        txid = data[8:20]
        attrs: dict[int, bytes] = {}
        off = STUN_HEADER
        end = STUN_HEADER + mlen
        while off + 4 <= end:
            atype, alen = struct.unpack(">HH", data[off:off + 4])
            attrs[atype] = data[off + 4:off + 4 + alen]
            off += 4 + pad4(alen)
        return mtype, attrs

    def _request(self, mtype: int, attrs: list[tuple[int, bytes]], integrity: bool):
        self.txid = random.randbytes(12)
        msg = self._message(mtype, attrs, integrity)
        with self.lock:
            self.sock.sendto(msg, (self.host, self.port))
            deadline = time.monotonic() + 3.0
            while time.monotonic() < deadline:
                try:
                    data, _ = self.sock.recvfrom(65535)
                except socket.timeout:
                    break
                rtype, rattrs = self._parse(data)
                if rtype == MSG_DATA_IND:
                    if self.data_handler:
                        self.data_handler(rattrs)
                    continue
                if data[8:20] == self.txid:
                    return rtype, rattrs
        raise TurnError(f"timeout waiting for response to 0x{mtype:04x}")

    def allocate(self) -> tuple[str, int]:
        rtype, attrs = self._request(MSG_ALLOCATE, [(ATTR_REQUESTED_TRANSPORT, b"\x11\x00\x00\x00")], integrity=False)
        if rtype != MSG_ALLOCATE_ERR:
            raise TurnError(f"expected 401, got 0x{rtype:04x}")
        self.realm = attrs[ATTR_REALM].decode()
        self.nonce = attrs[ATTR_NONCE].decode()
        rtype, attrs = self._request(MSG_ALLOCATE, [(ATTR_REQUESTED_TRANSPORT, b"\x11\x00\x00\x00")], integrity=True)
        if rtype != MSG_ALLOCATE_RESP:
            raise TurnError(f"allocate failed: 0x{rtype:04x} {attrs.get(ATTR_ERROR_CODE)}")
        self.relayed = parse_xor_address(attrs[ATTR_XOR_RELAYED_ADDRESS], self.txid)
        return self.relayed

    def create_permission(self, ip: str):
        self.txid = random.randbytes(12)
        attrs_body = build_xor_address(ATTR_XOR_PEER_ADDRESS, ip, 0, self.txid)
        attrs_body += build_attr(ATTR_USERNAME, self.username.encode())
        attrs_body += build_attr(ATTR_REALM, self.realm.encode())
        attrs_body += build_attr(ATTR_NONCE, self.nonce.encode())
        mi_len = len(attrs_body) + 24
        header = struct.pack(">HHI12s", MSG_CREATE_PERM, mi_len, MAGIC_COOKIE, self.txid)
        key = hashlib.md5(f"{self.username}:{self.realm}:{self.credential}".encode()).digest()
        mac = hmac.new(key, header + attrs_body, hashlib.sha1).digest()
        attrs_body += build_attr(ATTR_MESSAGE_INTEGRITY, mac)
        fp_len = len(attrs_body) + 8
        header = struct.pack(">HHI12s", MSG_CREATE_PERM, fp_len, MAGIC_COOKIE, self.txid)
        crc = zlib.crc32(header + attrs_body) ^ 0x5354554E
        attrs_body += build_attr(ATTR_FINGERPRINT, struct.pack(">I", crc))
        msg = struct.pack(">HHI12s", MSG_CREATE_PERM, len(attrs_body), MAGIC_COOKIE, self.txid) + attrs_body
        with self.lock:
            self.sock.sendto(msg, (self.host, self.port))
            deadline = time.monotonic() + 3.0
            while time.monotonic() < deadline:
                try:
                    data, _ = self.sock.recvfrom(65535)
                except socket.timeout:
                    break
                rtype, rattrs = self._parse(data)
                if rtype == MSG_DATA_IND:
                    if self.data_handler:
                        self.data_handler(rattrs)
                    continue
                if data[8:20] == self.txid:
                    if rtype != MSG_CREATE_PERM_RESP:
                        raise TurnError(f"create_permission failed: 0x{rtype:04x} {rattrs.get(ATTR_ERROR_CODE)}")
                    return
        raise TurnError("timeout waiting for create_permission response")

    def send_loop(self, payload: bytes):
        peer_ip, peer_port = self.peer
        peer = build_xor_address(ATTR_XOR_PEER_ADDRESS, peer_ip, peer_port, self.txid)
        body = peer + build_attr(ATTR_DATA, payload)
        msg = struct.pack(">HHI12s", MSG_SEND_IND, len(body), MAGIC_COOKIE, self.txid) + body
        self.sock.sendto(msg, (self.host, self.port))

    def recv_loop(self, stop: threading.Event, on_packet):
        self.sock.settimeout(0.5)
        while not stop.is_set():
            try:
                data, _ = self.sock.recvfrom(65535)
            except socket.timeout:
                continue
            if len(data) < STUN_HEADER:
                continue
            mtype = struct.unpack(">H", data[:2])[0]
            if mtype != MSG_DATA_IND:
                continue
            _, attrs = self._parse(data)
            payload = attrs.get(ATTR_DATA)
            if payload:
                on_packet(payload)


def fetch_cf_credentials(key_id: str, api_token: str) -> dict:
    url = f"https://rtc.live.cloudflare.com/v1/turn/keys/{key_id}/credentials/generate-ice-servers"
    req = urllib.request.Request(
        url,
        method="POST",
        headers={"authorization": f"Bearer {api_token}", "content-type": "application/json"},
        data=json.dumps({"ttl": 3600}).encode(),
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read())


def pick_udp_credential(ice_servers: dict) -> tuple[str, str, str, int]:
    for srv in ice_servers.get("iceServers", []):
        urls = srv.get("urls") or []
        if isinstance(urls, str):
            urls = [urls]
        for u in urls:
            if u.startswith("turn:") and "transport=udp" in u:
                hostport = u[len("turn:"):].split("?")[0]
                host, _, port = hostport.partition(":")
                return host, int(port or 3478), srv["username"], srv["credential"]
    raise TurnError("no turn udp url in iceServers")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rates", default="1,2,4,6,8,10,12,15,20,25,30",
                        help="comma-separated Mbps steps")
    parser.add_argument("--step-seconds", type=float, default=4.0)
    parser.add_argument("--payload", type=int, default=1300)
    parser.add_argument("--host", default=os.environ.get("TURN_HOST", ""))
    parser.add_argument("--port", type=int, default=int(os.environ.get("TURN_PORT", "3478")))
    args = parser.parse_args()

    username = os.environ.get("TURN_USERNAME")
    credential = os.environ.get("TURN_CREDENTIAL")
    host = args.host
    port = args.port
    ice_url = os.environ.get("TURN_ICE_URL")
    if not (username and credential) and ice_url:
        req = urllib.request.Request(ice_url, headers={"user-agent": "curl/8.0"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            ice = json.loads(resp.read())
        host, port, username, credential = pick_udp_credential(ice)
    if not (username and credential):
        key_id = os.environ.get("TURN_KEY_ID")
        api_token = os.environ.get("TURN_API_TOKEN")
        if not (key_id and api_token):
            print("need TURN_USERNAME/TURN_CREDENTIAL or TURN_KEY_ID/TURN_API_TOKEN", file=sys.stderr)
            return 2
        ice = fetch_cf_credentials(key_id, api_token)
        host, port, username, credential = pick_udp_credential(ice)
    if not host:
        print("need --host or TURN_HOST", file=sys.stderr)
        return 2

    print(f"TURN server: {host}:{port} user={username[:8]}... resolving...")
    host_ip = socket.gethostbyname(host)
    print(f"resolved: {host_ip}")

    client_a = TurnClient(host_ip, port, username, credential)
    t0 = time.monotonic()
    relayed_a = client_a.allocate()
    alloc_rtt_ms = (time.monotonic() - t0) * 1000
    print(f"alloc A relayed {relayed_a[0]}:{relayed_a[1]} in {alloc_rtt_ms:.1f}ms")
    client_b = TurnClient(host_ip, port, username, credential)
    relayed_b = client_b.allocate()
    print(f"alloc B relayed {relayed_b[0]}:{relayed_b[1]}")
    client_a.create_permission(relayed_b[0])
    client_b.create_permission(relayed_a[0])
    client_a.peer = relayed_b
    client_b.peer = relayed_a
    print("permissions created (A->B relay)")

    counts_lock = threading.Lock()
    rx_by_step: dict[int, int] = {}
    rx_bytes_by_step: dict[int, int] = {}
    rtt_samples: dict[int, list[float]] = {}
    stop = threading.Event()

    def on_packet(payload: bytes):
        try:
            if len(payload) < 20 or payload[:4] != b"ECAP":
                return
            step, seq, send_ns = struct.unpack(">IIQ", payload[4:20])
        except Exception:
            return
        now_ns = time.monotonic_ns()
        with counts_lock:
            rx_by_step[step] = rx_by_step.get(step, 0) + 1
            rx_bytes_by_step[step] = rx_bytes_by_step.get(step, 0) + len(payload)
            rtt_samples.setdefault(step, []).append((now_ns - send_ns) / 1e6)

    recv_thread = threading.Thread(target=client_b.recv_loop, args=(stop, on_packet), daemon=True)
    recv_thread.start()

    payload_len = args.payload
    print(f"\nramping payload={payload_len}B step={args.step_seconds}s")
    print(f"{'step':>4} {'target':>7} {'sent':>7} {'recv':>7} {'loss%':>7} {'achieved':>9} {'rtt p50/p95 ms':>16}")
    results = []
    for step, mbps in enumerate([float(r) for r in args.rates.split(",")]):
        interval = payload_len * 8 / (mbps * 1e6)
        body_len = payload_len - 20
        sent = 0
        start_ns = time.monotonic_ns()
        end_ns = start_ns + int(args.step_seconds * 1e9)
        next_ns = start_ns
        while time.monotonic_ns() < end_ns:
            hdr = b"ECAP" + struct.pack(">IIQ", step, sent, time.monotonic_ns())
            client_a.send_loop(hdr + bytes([sent & 0xFF]) * body_len)
            sent += 1
            next_ns += int(interval * 1e9)
            delay = (next_ns - time.monotonic_ns()) / 1e9
            if delay > 0:
                time.sleep(min(delay, 0.05))
        time.sleep(1.0)
        with counts_lock:
            recv = rx_by_step.get(step, 0)
            samples = sorted(rtt_samples.get(step, []))
        loss = 100.0 * (1 - recv / max(sent, 1))
        achieved = recv * payload_len * 8 / args.step_seconds / 1e6
        p50 = samples[len(samples) // 2] if samples else float("nan")
        p95 = samples[int(len(samples) * 0.95)] if samples else float("nan")
        print(f"{step:>4} {mbps:>6.1f}M {sent:>7} {recv:>7} {loss:>6.2f}% {achieved:>8.2f}M {p50:>7.1f}/{p95:>7.1f}")
        results.append((mbps, sent, recv, loss, achieved, p50, p95))
        if loss > 20.0:
            print("loss > 20%, stopping ramp")
            break

    stop.set()
    recv_thread.join(timeout=2)
    good = [r for r in results if r[3] <= 1.0]
    if good:
        best = max(good, key=lambda r: r[4])
        print(f"\nsustainable (<=1% loss): ~{best[4]:.2f} Mbps relay loopback")
    else:
        print("\nno step stayed under 1% loss")
    return 0


if __name__ == "__main__":
    sys.exit(main())
