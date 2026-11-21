#!/usr/bin/env python3
"""Check a pump's Wi-Fi API from a computer on the same network.

    scripts/wifi_api_check.py <pump ip or tanklink-XXXX.local> <token hex> [--beep]

Does HELLO, AUTH, reads Info and State and, with --beep, sends the test beep
(Cmd 0xB1) so you hear it work. <token hex> is one phone's 16-byte pairing
token (32 hex characters). Framing and tags: docs/PROTOCOL.md, "Wi-Fi
transport"; the app's lib/link/wifi_link.dart must match this script.
"""

import argparse
import hashlib
import hmac
import socket
import struct
import sys

PORT = 7580
HELLO, AUTH, READ, WRITE, RESULT, NOTIFY, ERROR = range(1, 8)
CHR_INFO, CHR_AUTH, CHR_STATE, CHR_CMD = 0x02, 0x04, 0x05, 0x06
CMD_TEST_BEEP = 0xB1
TAG_LEN = 8


def hmac_sha256(key: bytes, *parts: bytes) -> bytes:
    return hmac.new(key, b"".join(parts), hashlib.sha256).digest()


def auth_response(token: bytes, nonce: bytes) -> bytes:
    """Same as authResponse in the app and tl_auth_response in the firmware."""
    return hmac_sha256(token, b"TLauth", nonce)[:16]


def session_key(token: bytes, nonce: bytes) -> bytes:
    return hmac_sha256(token, nonce, b"tcp")


def build_frame(ftype: int, chr_id: int, counter: int, payload: bytes, key=None) -> bytes:
    """length(u16) type chr counter(u32) payload [tag]; all little-endian.
    length counts everything after itself, tag included."""
    body_len = 6 + len(payload) + (TAG_LEN if key else 0)
    frame = struct.pack("<HBBI", body_len, ftype, chr_id, counter) + payload
    if key:
        frame += hmac_sha256(key, frame)[:TAG_LEN]
    return frame


class Client:
    def __init__(self, host: str):
        self.sock = socket.create_connection((host, PORT), timeout=5)
        self.key = None
        self.tx = 0
        self.rx = 0

    def recv_exact(self, n: int) -> bytes:
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("pump closed the connection")
            buf += chunk
        return buf

    def recv_frame(self):
        (length,) = struct.unpack("<H", self.recv_exact(2))
        body = self.recv_exact(length)
        ftype, chr_id, counter = struct.unpack("<BBI", body[:6])
        payload = body[6:]
        if self.key:
            frame, tag = body[:-TAG_LEN], body[-TAG_LEN:]
            want = hmac_sha256(self.key, struct.pack("<H", length) + frame)[:TAG_LEN]
            if not hmac.compare_digest(want, tag):
                raise ValueError("bad tag from the pump")
            payload = frame[6:]
        if counter <= self.rx:
            raise ValueError("counter did not go up")
        self.rx = counter
        return ftype, chr_id, payload

    def send(self, ftype: int, chr_id: int, payload: bytes = b""):
        self.tx += 1
        self.sock.sendall(build_frame(ftype, chr_id, self.tx, payload, self.key))

    def request(self, ftype: int, chr_id: int, payload: bytes = b""):
        """Send and wait for the RESULT (notifications in between are printed)."""
        self.send(ftype, chr_id, payload)
        while True:
            t, c, p = self.recv_frame()
            if t == NOTIFY:
                print(f"  notify chr=0x{c:02x} {p.hex()}")
                continue
            if t != RESULT:
                raise ValueError(f"unexpected frame type {t}")
            return p[0], p[1:]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("host")
    ap.add_argument("token", help="32 hex characters")
    ap.add_argument("--beep", action="store_true", help="send the test beep")
    args = ap.parse_args()
    token = bytes.fromhex(args.token)
    if len(token) != 16:
        sys.exit("token must be 16 bytes (32 hex characters)")

    c = Client(args.host)
    t, _, hello = c.recv_frame()
    assert t == HELLO, "expected HELLO"
    nonce, info = hello[:16], hello[16:]
    print(f"HELLO ok, Info before sign-in: {info.hex()}")

    c.send(AUTH, 0, auth_response(token, nonce))
    c.key = session_key(token, nonce)
    try:  # a success RESULT is tagged; a refusal is not, so it fails the tag check
        t, _, p = c.recv_frame()
    except (ValueError, ConnectionError):
        sys.exit("sign-in refused")
    if t != RESULT or p[:1] != b"\x00":
        sys.exit("sign-in refused")
    print("AUTH ok")

    status, info = c.request(READ, CHR_INFO)
    print(f"Info: status={status} proto={info[0]}.{info[1]} fw={info[11]}.{info[12]}.{info[13]}")
    status, state = c.request(READ, CHR_STATE)
    print(f"State: status={status} pump {'ON' if state[:1] == bytes([1]) else 'off'}")
    if args.beep:
        status, _ = c.request(WRITE, CHR_CMD, bytes([CMD_TEST_BEEP]))
        print(f"Test beep: status={status}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
