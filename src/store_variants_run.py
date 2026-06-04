#!/usr/bin/env python3
"""Persist the newly-differenced 2-peer push variants (bounded to their real
message bytes) into raknet_samples.json so the data is never lost."""
import sys
sys.path.insert(0, "/home/caleb/partydeck/src")
import raknet as R, join_diff as JD, raknet_samples as S
exec(open("/tmp/pdlog/probe/diff_pushes.py").read().split("def main()")[0])

c1 = load_peer("C1"); c2 = load_peer("C2")


def bound(body, nvals):
    """Slice body to exactly the bytes of its first `nvals` top-level msgpack
    values (drops over-read trailing from un-separated concatenated messages)."""
    i = 0
    for _ in range(nvals):
        _, i = JD.mp(body, i)
    return body[:i]


def member_fields(body):
    f = {}
    try:
        vals = JD.mp_all(body)
    except Exception:
        return f
    return f


added = 0

# 1) match-found gamefinder.update  (status, token, gsInfo) = 3 top-level values
for peer, ex in (("C1", c1), ("C2", c2)):
    for body, _pl in ex.bodies.get("matchmaking/gamefinder.update", []):
        vals = JD.mp_all(body)
        if vals and vals[0] == 3:
            clean = bound(body, 3)
            s = S.record("matchmaking/gamefinder.update", clean,
                         hr="match-found [3, token, gsInfo]", peer=peer,
                         fields={"variant": "match-found"})
            added += 1
            print("stored gamefinder.update match-found", peer, "len", len(clean))
            break

# 2) settingsUpdated with serverData (in-gamesession): prefix(3) + settings(1) = 4
for peer, ex in (("C1", c1), ("C2", c2)):
    for body, _pl in ex.bodies.get("party/party.settingsUpdated", []):
        vals = JD.mp_all(body)
        arr = next((v for v in vals if isinstance(v, tuple) and v[0] == "arr"
                    and len(v[1]) == 8), None)
        if arr and isinstance(arr[1][5], tuple) and arr[1][5][0] == "map" and arr[1][5][1]:
            clean = bound(body, 4)
            S.record("party/party.settingsUpdated", clean,
                     hr="in-gamesession (isJoinable=False, serverData partyStatus)",
                     peer=peer, fields={"variant": "in-gamesession"})
            added += 1
            print("stored settingsUpdated in-gamesession", peer, "len", len(clean))
            break

# 3) memberStatusUpdated 2-entry batch: prefix(3) + payload(1) = 4
for peer, ex in (("C1", c1), ("C2", c2)):
    for body, _pl in ex.bodies.get("party/party.memberStatusUpdated", []):
        vals = JD.mp_all(body)
        pay = next((v for v in vals if isinstance(v, tuple) and v[0] == "arr"
                    and v[1] and isinstance(v[1][0], tuple) and v[1][0][0] == "arr"
                    and len(v[1][0][1]) == 2), None)
        if pay:
            clean = bound(body, 4)
            S.record("party/party.memberStatusUpdated", clean,
                     hr="2-member batch [[[g1,s1],[g2,s2]]]", peer=peer,
                     fields={"variant": "batch2"})
            added += 1
            print("stored memberStatusUpdated batch2", peer, "len", len(clean))
            break

print("added", added, "samples")
