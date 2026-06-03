#!/usr/bin/env python3
"""Stormancer authenticator token builder (offline / self-hosted).

Reproduces the real `authenticator/token` JSON envelope captured by MITM:
    {
      "token": "<base64(msgpack ConnectionData)>-<base64 signature>",
      "endpoints": {"raknet": ["<host:port>"]},
      "encryption": {"algorithm":"aes256","mode":"GCM","key":"<b64>","token":"<b64>"}
    }

The client (Stormancer C++ SDK) parses the JSON, splits `.token` on '-', and
base64-decodes part[0] into a msgpack `ConnectionData`. It then opens a RakNet
UDP connection to `endpoints.raknet[0]`. The signature is validated server-side
(by us), so any value is accepted offline.

This module hand-encodes msgpack (no external deps) so it runs under the system
python the probe uses. It is the reference for the eventual Rust port.
"""
import base64
import os
import struct
import time

# ----- minimal msgpack encoders --------------------------------------------

def mp_str(s: str) -> bytes:
    b = s.encode("utf-8")
    n = len(b)
    if n < 32:
        return bytes([0xA0 | n]) + b
    if n < 256:
        return bytes([0xD9, n]) + b
    if n < 65536:
        return b"\xDA" + struct.pack(">H", n) + b
    return b"\xDB" + struct.pack(">I", n) + b


def mp_bin(b: bytes) -> bytes:
    n = len(b)
    if n < 256:
        return bytes([0xC4, n]) + b
    if n < 65536:
        return b"\xC5" + struct.pack(">H", n) + b
    return b"\xC6" + struct.pack(">I", n) + b


def mp_nil() -> bytes:
    return b"\xC0"


def mp_uint(n: int) -> bytes:
    if 0 <= n < 128:
        return bytes([n])
    if n < 256:
        return bytes([0xCC, n])
    if n < 65536:
        return b"\xCD" + struct.pack(">H", n)
    if n < 2**32:
        return b"\xCE" + struct.pack(">I", n)
    return b"\xCF" + struct.pack(">Q", n)


def mp_map_header(n: int) -> bytes:
    if n < 16:
        return bytes([0x80 | n])
    if n < 65536:
        return b"\xDE" + struct.pack(">H", n)
    return b"\xDF" + struct.pack(">I", n)


def mp_timestamp(unix_sec: int, nanos: int) -> bytes:
    """msgpack timestamp64 (ext type -1, fixext8 0xD7 0xFF).

    data64 = (nanoseconds << 34) | seconds, big-endian. Matches the real token's
    Issued/Expiration encoding exactly (seconds < 2^34).
    """
    data = ((nanos & 0x3FFFFFFFF) << 34) | (unix_sec & 0x3FFFFFFFF)
    return b"\xD7\xFF" + struct.pack(">Q", data)


# ----- ConnectionData -------------------------------------------------------

# Values captured from the real server (MITM). Keep these identical so the
# client/server scene routing matches what the game expects.
REAL_ACCOUNT_ID = "darktales"
REAL_APPLICATION = "live-1-05-00"
REAL_SCENE_ID = "scene:/passtech-live/darktales/live-1-05-00/authenticator"
REAL_CONTENT_TYPE = "text/plain; charset=utf-8, application/msgpack"
REAL_DEPLOYMENT_ID = "2564d8be-2dbb-4967-b6bb-0e157aa7f63f"
REAL_VERSION = 2
TOKEN_TTL_SECONDS = 300  # real token had a 5-minute lifetime


def build_connection_data(scene_id: str = REAL_SCENE_ID,
                          account_id: str = REAL_ACCOUNT_ID,
                          application: str = REAL_APPLICATION,
                          deployment_id: str = REAL_DEPLOYMENT_ID,
                          version: int = REAL_VERSION) -> bytes:
    """Hand-encode the 11-field ConnectionData fixmap, byte-compatible with the
    real token but with fresh Issued/Expiration timestamps."""
    now = time.time()
    issued_s = int(now)
    issued_ns = int((now - issued_s) * 1e9)
    exp_s = issued_s + TOKEN_TTL_SECONDS

    out = bytearray()
    out += mp_map_header(11)
    out += mp_str("AccountId");    out += mp_str(account_id)
    out += mp_str("Application");  out += mp_str(application)
    out += mp_str("Issued");       out += mp_timestamp(issued_s, issued_ns)
    out += mp_str("Expiration");   out += mp_timestamp(exp_s, issued_ns)
    out += mp_str("UserData");     out += mp_bin(b"")
    out += mp_str("ContentType");  out += mp_str(REAL_CONTENT_TYPE)
    out += mp_str("Endpoints");    out += mp_nil()
    out += mp_str("SceneId");      out += mp_str(scene_id)
    out += mp_str("Routing");      out += mp_nil()
    out += mp_str("DeploymentId"); out += mp_str(deployment_id)
    out += mp_str("Version");      out += mp_uint(version)
    return bytes(out)


# ----- token envelope -------------------------------------------------------

# When True, include the AES-256-GCM encryption block (fidelity to real). The
# key is stored in `LAST_ENCRYPTION` so Phase B (RakNet) can decrypt the
# client's encrypted online messages.
#
# Phase B finding: the C++ client REQUIRES this encryption block. With it OFF the
# client fails to deserialize the token envelope ("[Exception: not a string]" in
# UsersApi::loginImpl) and never connects RakNet, retrying /token ~1x/sec. With it
# ON the token parses and RakNet connects. So encryption stays ON.
ENABLE_ENCRYPTION = True

# Where the game should send RakNet UDP. The game pins this hostname to
# 127.0.0.1 via partydeck's /etc/hosts, so it reaches our local RakNet server.
RAKNET_ENDPOINT = "dt-live.passtechgames.com:30100"

LAST_ENCRYPTION = {}  # token-id (b64) -> raw 32-byte key, for Phase B lookup


def make_token_envelope(scene_id: str = REAL_SCENE_ID,
                        raknet_endpoint: str = RAKNET_ENDPOINT) -> dict:
    cd = build_connection_data(scene_id=scene_id)
    b64_cd = base64.b64encode(cd).decode("ascii")  # standard alphabet, no '-'
    sig = base64.b64encode(os.urandom(32)).decode("ascii")  # server-side only
    token = f"{b64_cd}-{sig}"

    env = {
        "token": token,
        "endpoints": {"raknet": [raknet_endpoint]},
    }
    if ENABLE_ENCRYPTION:
        key = os.urandom(32)
        # The real server's encryption.token decodes to 74 bytes (100 base64
        # chars, one '=' pad). Match that exactly: an unpadded 48-byte value
        # produced a 64-char string the client's strict base64 decoder
        # rejected ("length of base64 string is not an even multiple of 4").
        key_token_raw = os.urandom(74)
        key_token_b64 = base64.b64encode(key_token_raw).decode("ascii")
        LAST_ENCRYPTION[key_token_b64] = key
        env["encryption"] = {
            "algorithm": "aes256",
            "mode": "GCM",
            "key": base64.b64encode(key).decode("ascii"),
            "token": key_token_b64,
        }
    return env


if __name__ == "__main__":
    import json
    cd = build_connection_data()
    print("ConnectionData msgpack hex:")
    print(cd.hex())
    print("\nEnvelope:")
    print(json.dumps(make_token_envelope(), indent=2))
