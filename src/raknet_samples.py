#!/usr/bin/env python3
"""raknet_samples.py — JSON-backed library of REAL captured server->client
scene-push samples.

Rationale: several server-initiated pushes (gamefinder.update,
friends.notification, gamesession player.update, Steam.JoinLobby /
UpdateLobbyJoinable, party.memberDisconnected, ...) carry bytes that are only
ever produced by a *real* server reacting to a *real* second peer. Rather than
fabricate those bytes (guessing field formats from a single sample), the
emulator looks them up in a captured-sample library on disk. If a sample the
emulator needs has not been captured yet, it raises MissingSampleError naming
exactly what to add — it never invents the data.

The store is plain JSON (src/raknet_samples.json) so new samples can be appended
by hand or via record(). Each push route maps to a list of samples; a sample is:

    {
      "hex":    "<raw scene-message BODY hex>",   # bytes after [handle][route]
      "len":    <int>,
      "hr":     "<symbol-free human-readable decode>",
      "peer":   "<capture peer label, optional>",
      "fields": { "steamId": "...", "PlayerName": "...", ... }  # extracted ids
    }

Look-ups are by full route name "<kind>/<route>" e.g. "matchmaking/gamefinder.update".
"""
import os
import json
import threading

_HERE = os.path.dirname(os.path.abspath(__file__))
SAMPLES_PATH = os.environ.get(
    "RAKNET_SAMPLES_FILE", os.path.join(_HERE, "raknet_samples.json"))

_lock = threading.Lock()
_cache = None


class MissingSampleError(LookupError):
    """Raised when the emulator needs a captured push sample that is not in the
    library. The message tells the operator exactly which route to capture and
    where to add it."""
    def __init__(self, route, detail=""):
        self.route = route
        msg = ("no captured sample for server push %r in %s%s\n"
               "  -> capture this push from a real session and add it under "
               "pushes[%r].samples (or call raknet_samples.record(...))."
               % (route, SAMPLES_PATH, (" (" + detail + ")") if detail else "",
                  route))
        super().__init__(msg)


def _load():
    global _cache
    if _cache is not None:
        return _cache
    with _lock:
        if _cache is not None:
            return _cache
        if os.path.exists(SAMPLES_PATH):
            with open(SAMPLES_PATH, "r", encoding="utf-8") as fh:
                _cache = json.load(fh)
        else:
            _cache = {"pushes": {}}
        _cache.setdefault("pushes", {})
        return _cache


def reload():
    """Drop the in-memory cache (e.g. after editing the JSON on disk)."""
    global _cache
    with _lock:
        _cache = None
    return _load()


def has(route):
    """True if at least one sample exists for `route`."""
    entry = _load()["pushes"].get(route)
    return bool(entry and entry.get("samples"))


def samples(route):
    """Return the list of samples for `route` (empty list if none)."""
    entry = _load()["pushes"].get(route)
    return list(entry.get("samples", [])) if entry else []


def require(route, index=0, detail=""):
    """Return one captured sample dict for `route`, or raise MissingSampleError.

    `index` selects among multiple captured samples (default the first). Asking
    for an index beyond what was captured also raises (the operator needs to add
    that variant)."""
    sl = samples(route)
    if not sl:
        raise MissingSampleError(route, detail)
    if index >= len(sl):
        raise MissingSampleError(
            route, "%s; only %d sample(s) captured, need index %d"
            % (detail, len(sl), index) if detail
            else "only %d sample(s) captured, need index %d" % (len(sl), index))
    return sl[index]


def require_body(route, index=0, detail=""):
    """Return the raw scene-message BODY bytes for `route` (decoded from hex),
    or raise MissingSampleError. This is the byte payload to hand to
    send_scene_msg after the [handle][routeHandle] header."""
    return bytes.fromhex(require(route, index, detail)["hex"])


def record(route, body, *, hr="", peer="", fields=None, persist=True,
           dedupe=True):
    """Append a newly observed sample for `route` and (optionally) persist to
    disk. `body` is the raw scene-message body (bytes or hex str). Returns the
    sample dict that was stored."""
    if isinstance(body, (bytes, bytearray)):
        hx = bytes(body).hex()
        blen = len(body)
    else:
        hx = str(body)
        blen = len(hx) // 2
    sample = {"hex": hx, "len": blen, "hr": hr, "peer": peer,
              "fields": dict(fields or {})}
    with _lock:
        data = _load()
        entry = data["pushes"].setdefault(route, {"samples": []})
        entry.setdefault("samples", [])
        if dedupe and any(s.get("hex") == hx for s in entry["samples"]):
            return sample
        entry["samples"].append(sample)
        if persist:
            _write(data)
    return sample


def _write(data):
    tmp = SAMPLES_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=1, ensure_ascii=False)
    os.replace(tmp, SAMPLES_PATH)
