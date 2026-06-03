#!/usr/bin/env python3
"""Reconcile the JOINER's RakNet/Stormancer event stream between a working ONLINE
join capture and the failing OFFLINE one, to PROVE exactly where (and only where)
they diverge.

Why this is a fair comparison:
  * The RakNet :30100 plane is plaintext msgpack in BOTH captures (online to the
    real dt-live broker, offline to raknet.py), so the decoded events are directly
    comparable — unlike TLS/EOS which are encrypted/emulated.
  * We compare only the JOINER's stream (online is joiner-only; the offline CSV
    already labels JOINER vs HOST), i.e. apples-to-apples.

How it normalizes away benign per-run differences so a real gap can't hide:
  * Scene HANDLES (0x90 vs 0xa0) and reqIds/seq numbers are dynamic per session →
    stripped. Scenes are identified by NAME (authenticator, party-manager, friends,
    matchmaking, party-<guid>) resolved from the TOKEN{scene=...} / SceneId fields.
  * Party GUIDs differ every run → normalized positionally: the FIRST party the
    joiner touches = party-OWN, a later DIFFERENT party = party-HOST.

Output: the ordered, aligned JOINER event sequences with a unified diff. If Phase A
had ANY missing packet offline, it would appear as an ONLINE-ONLY block BEFORE the
join click — not only at the join click.

Usage:
  python3 src/reconcile_join.py pcaps/join_online_102258.csv pcaps/join_fwd_154048.csv
"""
import csv
import difflib
import re
import sys


def is_raknet(row):
    s, d = row.get("src", ""), row.get("dst", "")
    return any("30100" in x or x in ("RAKNET", "JOINER", "HOST") for x in (s, d))


def joiner_dir(row):
    """Return 'OUT' if JOINER->broker, 'IN' if broker->JOINER, else None."""
    s, d = row.get("src", ""), row.get("dst", "")
    if s == "JOINER" and (d == "RAKNET" or "30100" in d):
        return "OUT"
    if d == "JOINER" and (s == "RAKNET" or "30100" in s):
        return "IN"
    # Online labels the game side as JOINER/GAME and broker as RAKNET; also accept
    # raw GAME:port <-> :30100 form.
    if "GAME" in s and "30100" in d:
        return "OUT"
    if "GAME" in d and "30100" in s:
        return "IN"
    return None


SCENE_RE = re.compile(r"scene=scene:/[^/]+/[^/]+/[^/]+/([^,\s}]+)")
SCENEID_RE = re.compile(r"SceneId'?\s*[:=]\s*'([^']+)'")
PARTY_RE = re.compile(r"party-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
SYSREQ_RE = re.compile(r"SYSREQ ([A-Z_]+)")
SCENE_MSG_RE = re.compile(r"scene h=0x[0-9a-f]+ route=(\d+)")
CODE_RE = re.compile(r"'(\d{6})'")


class PartyNormalizer:
    def __init__(self):
        self.order = []  # distinct party guids in first-seen order

    def norm(self, name):
        if not name:
            return name
        m = PARTY_RE.search(name)
        if not m:
            return name
        guid = m.group(0)
        if guid not in self.order:
            self.order.append(guid)
        idx = self.order.index(guid)
        tag = "party-OWN" if idx == 0 else ("party-HOST" if idx == 1 else f"party-{idx}")
        return PARTY_RE.sub(tag, name)


def scene_name(dec, pn):
    m = SCENE_RE.search(dec)
    if m:
        return pn.norm(m.group(1))
    m = SCENEID_RE.search(dec)
    if m:
        return pn.norm(m.group(1))
    return None


def events_for_joiner(path, milestones_only=False):
    """Return an ordered list of normalized (direction, token, raw_excerpt, t) for
    the JOINER's RakNet stream. Only semantically meaningful messages are kept
    (drops bare ACK / PING keepalives that just reflect link liveness)."""
    pn = PartyNormalizer()
    out = []
    DROP = ("ACK", "ID_CONNECTED_PING", "ID_CONNECTED_PONG", "split fragment",
            "SYSREQ PING", "NEE-P2P", "LAN-BCAST")
    for row in csv.DictReader(open(path)):
        if not is_raknet(row):
            continue
        dirn = joiner_dir(row)
        if dirn is None:
            continue
        dec = row.get("decoded") or row.get("summary") or ""
        t = row.get("t_off", "")
        # split each datagram's concatenated sub-messages so multi-part rows count
        # each semantic event once
        for part in re.split(r"\s*\|\s*", dec):
            part = part.strip()
            if not part or any(k in part for k in DROP):
                continue
            tok = classify(part, dirn, pn, milestones_only=milestones_only)
            if tok:
                out.append((dirn, tok, part[:90], t))
    return out


# Gamefinder (join-by-code) scene handle byte is 0x8e in BOTH captures.
GAMEFINDER_HANDLE = "0x8e"

# The high-value milestones that define the join flow. Everything else (per-packet
# RESP-MSG / RESP-COMPLETE / ID_SCENES / handshake / keepalive cadence) is transport
# noise that legitimately differs run-to-run and is filtered out in milestone mode.
MILESTONE_SYSREQS = {"CONNECT_TO_SCENE", "DISCONNECT_FROM_SCENE", "GET_SCENE_INFOS"}


def classify(part, dirn, pn, milestones_only=False):
    """Map one decoded sub-message to a normalized semantic token.

    In milestones_only mode, return None for transport-noise messages so the
    comparison shows only join-flow-defining events.
    """
    sc = scene_name(part, pn)
    m = SYSREQ_RE.search(part)
    if m:
        kind = m.group(1)
        if kind in MILESTONE_SYSREQS:
            return f"{dirn} {kind}" + (f":{sc}" if sc else "")
        if milestones_only:
            return None
        if kind in ("GET_SCENE_HANDLE", "GET_SESSION_TOKEN", "SET_METADATA"):
            return f"{dirn} {kind}"
        return f"{dirn} SYSREQ {kind}"
    # gamefinder / party scene route message = the actual join-by-code RPC traffic
    mm = SCENE_MSG_RE.search(part)
    if mm:
        route = mm.group(1)
        is_gamefinder = GAMEFINDER_HANDLE in part
        if milestones_only and not is_gamefinder:
            return None
        tag = "GAMEFINDER" if is_gamefinder else "SCENE-MSG"
        return f"{dirn} {tag} route={route}"
    if milestones_only:
        return None
    # ---- verbose-mode-only transport tokens ----
    if "ID_REQUEST_RESPONSE_MSG" in part:
        return f"{dirn} RESP-MSG" + (f":{sc}" if sc else "")
    if "ID_REQUEST_RESPONSE_COMPLETE" in part:
        return f"{dirn} RESP-COMPLETE"
    if "ID_SCENES" in part:
        return f"{dirn} ID_SCENES"
    for idm in ("ID_CONNECTION_REQUEST_ACCEPTED", "ID_NEW_INCOMING_CONNECTION",
                "ID_CONNECTION_RESULT", "ID_CONNECTION_REQUEST",
                "ID_OPEN_CONNECTION_REQUEST", "ID_OPEN_CONNECTION_REPLY"):
        if idm in part:
            return f"{dirn} {idm}"
    return None


def summarize(events):
    return [f"{d} {t}".split("  ")[0] for d, t, _, _ in events]


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    verbose = "--verbose" in sys.argv or "-v" in sys.argv
    online_path, offline_path = args[0], args[1]
    milestones_only = not verbose
    on = events_for_joiner(online_path, milestones_only)
    off = events_for_joiner(offline_path, milestones_only)

    on_tok = [e[1] for e in on]
    off_tok = [e[1] for e in off]

    mode = "VERBOSE (all transport)" if verbose else "MILESTONE (join-flow-defining events only)"
    print("=" * 80)
    print(f"JOINER RakNet/Stormancer event reconciliation  [{mode}]")
    print(f"  ONLINE  {online_path}: {len(on)} joiner events")
    print(f"  OFFLINE {offline_path}: {len(off)} joiner events")
    print("=" * 80)

    # Ordered alignment of the two normalized token sequences.
    sm = difflib.SequenceMatcher(a=on_tok, b=off_tok, autojunk=False)
    matched = online_only = offline_only = 0
    print("\nALIGNED TIMELINE  (=both  |  < ONLINE-only=missing offline  |  > OFFLINE-only=extra)\n")
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            for k in range(i1, i2):
                matched += 1
                jj = j1 + (k - i1)
                print(f"  =  {on_tok[k]:<46} [on {on[k][3]:>9} | off {off[jj][3]:>9}]")
        elif tag in ("replace", "delete"):
            for k in range(i1, i2):
                online_only += 1
                print(f"  <  {on_tok[k]:<46} [on {on[k][3]:>9}]  {on[k][2]}")
            if tag == "replace":
                for k in range(j1, j2):
                    offline_only += 1
                    print(f"  >  {off_tok[k]:<46} [off {off[k][3]:>9}]  {off[k][2]}")
        elif tag == "insert":
            for k in range(j1, j2):
                offline_only += 1
                print(f"  >  {off_tok[k]:<46} [off {off[k][3]:>9}]  {off[k][2]}")

    print("\n" + "=" * 80)
    print(f"SUMMARY: {matched} matched   {online_only} ONLINE-only(missing offline)   "
          f"{offline_only} OFFLINE-only(extra)")
    # Highlight the join-by-code-specific events online has that offline lacks.
    on_set, off_set = set(on_tok), set(off_tok)
    print("\nKey join-flow tokens — ONLINE has / OFFLINE has:")
    for t in ["OUT DISCONNECT_FROM_SCENE", "OUT CONNECT_TO_SCENE:party-HOST",
              "OUT GAMEFINDER route=5", "IN GAMEFINDER route=2",
              "OUT CONNECT_TO_SCENE:matchmaking", "OUT CONNECT_TO_SCENE:party-OWN",
              "OUT CONNECT_TO_SCENE:authenticator", "OUT CONNECT_TO_SCENE:friends"]:
        oc = on_tok.count(t)
        fc = off_tok.count(t)
        flag = "  <-- ONLINE-ONLY" if oc and not fc else ("  <-- OFFLINE-ONLY" if fc and not oc else "")
        print(f"  {t:<42} online={oc:<3} offline={fc:<3}{flag}")
    print("=" * 80)


if __name__ == "__main__":
    main()
