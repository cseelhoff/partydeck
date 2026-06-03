#!/usr/bin/env python3
"""raknet_diff.py -- compare the Stormancer/RakNet control plane of two captures.

The game binary is deterministic: given the same server replies it emits the same
client messages. So a WORKING online join and a HANGING offline join must diverge
at some Stormancer message -- the first milestone present in one capture and
missing (or reordered) in the other is the gate.

This tool reduces each capture's `raknet` plane to an ordered list of control
milestones (dropping transport noise: ACK / PING / pong / split fragments /
connected-ping) and reports:

  1. MILESTONE SET DIFF -- verbs present in one side only (the headline signal,
     e.g. "leave scene" = DISCONNECT_FROM_SCENE present online, absent offline).
  2. FIRST DIVERGENCE -- walking both ordered sequences, the first milestone that
     does not line up.
  3. COUNT TABLE -- per-verb occurrence counts side by side.

Inputs may be either decoded CSVs (from pcap2csv.py) or raw .pcap files (decoded
on the fly via pcap2csv in the same dir). Use --role to keep only rows touching a
given endpoint label (default JOINER) so an offline capture that co-locates HOST
+ JOINER on loopback can be compared fairly to an online capture that only saw
the joiner.

Usage:
    raknet_diff.py <online.csv|pcap> <offline.csv|pcap> [--role JOINER]
                   [--all-roles] [--context N]
"""
import sys, os, csv, re, subprocess, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

# transport-level noise that carries no control-plane meaning
NOISE = re.compile(
    r"^(ACK|PING|ping reply|ping ack|CONNECTED_PING|CONNECTED_PONG|"
    r"split fragment|PONG|UNCONNECTED_)", re.I)


def to_csv(path):
    """Return a decoded CSV path: pass CSVs through, decode pcaps to a temp CSV."""
    if path.lower().endswith(".csv"):
        return path
    out = tempfile.NamedTemporaryFile(prefix="raknet_diff_", suffix=".csv",
                                      delete=False).name
    subprocess.run([sys.executable, os.path.join(HERE, "pcap2csv.py"), path, out,
                    "--signal"], check=True, stdout=subprocess.DEVNULL)
    return out


def milestone(summary):
    """Canonical control verb for a raknet summary, or None for noise.

    Collapses scene-handle/route specifics, json bodies, numbers, guids and
    addresses so only the *kind* of control message survives."""
    s = summary.split(";")[0].strip()
    if not s or NOISE.match(s):
        return None
    # SCENE payload rows: keep the verb 'SCENE' + handle marker only
    if s.startswith("SCENE h="):
        return "SCENE-route"
    # generic normalisation
    s = re.sub(r"\bh=#?\b", "", s)
    s = re.sub(r"\{.*", "", s)               # json bodies
    s = re.sub(r"'[^']*'|\"[^\"]*\"", "", s)  # quoted strings
    s = re.sub(r"\b[0-9a-fx.:]+\b", "", s)    # numbers / addrs / guids
    s = re.sub(r"[\[\]|]+", " ", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s or None


def load(path, role, all_roles):
    rows = []
    for r in csv.DictReader(open(path)):
        if r.get("plane") and r["plane"] != "raknet":
            continue
        if not r.get("plane"):
            # older CSV without plane col: keep only RAKNET-labelled rows
            if "RAKNET" not in (r.get("src", "") + r.get("dst", "")):
                continue
        if not all_roles and role:
            if role not in (r.get("src", "") + " " + r.get("dst", "")):
                continue
        m = milestone(r.get("summary", ""))
        if m:
            rows.append((float(r["t_off"]), r.get("src", ""), r.get("dst", ""), m,
                         r.get("summary", "")))
    rows.sort(key=lambda x: x[0])
    return rows


def dirn(src, dst):
    return "C>S" if "RAKNET" in dst else "S>C" if "RAKNET" in src else "?"


def main():
    args = sys.argv[1:]
    role = "JOINER"
    all_roles = False
    context = 3
    pos = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--role":
            i += 1; role = args[i]
        elif a == "--all-roles":
            all_roles = True
        elif a == "--context":
            i += 1; context = int(args[i])
        else:
            pos.append(a)
        i += 1
    if len(pos) < 2:
        raise SystemExit(__doc__)

    a_csv, b_csv = to_csv(pos[0]), to_csv(pos[1])
    A = load(a_csv, role, all_roles)
    B = load(b_csv, role, all_roles)
    an, bn = os.path.basename(pos[0]), os.path.basename(pos[1])
    scope = "all roles" if all_roles else f"role~{role}"
    print(f"A = {an}  ({len(A)} control milestones, {scope})")
    print(f"B = {bn}  ({len(B)} control milestones, {scope})")

    from collections import Counter
    ca = Counter(m for *_, m, _ in A)
    cb = Counter(m for *_, m, _ in B)

    # ---- 1. set diff ----
    only_a = sorted(set(ca) - set(cb))
    only_b = sorted(set(cb) - set(ca))
    print("\n=== MILESTONE SET DIFF (headline) ===")
    if only_a:
        print(f"  present in A only ({an}):")
        for m in only_a: print(f"    + {m}  x{ca[m]}")
    if only_b:
        print(f"  present in B only ({bn}):")
        for m in only_b: print(f"    + {m}  x{cb[m]}")
    if not only_a and not only_b:
        print("  (same milestone vocabulary on both sides)")

    # ---- 2. ordered first divergence ----
    print("\n=== ORDERED SEQUENCE -- first divergence ===")
    sa = [m for *_, m, _ in A]
    sb = [m for *_, m, _ in B]
    j = 0
    while j < len(sa) and j < len(sb) and sa[j] == sb[j]:
        j += 1
    lo = max(0, j - context)
    if j >= len(sa) and j >= len(sb):
        print("  sequences identical through the shorter capture")
    else:
        print(f"  diverge at index {j} (after {j} matching milestones):")
        print(f"  {'idx':>4}  {'A:'+an:<40}  {'B:'+bn}")
        hi = max(len(sa), len(sb))
        for k in range(lo, min(hi, j + context + 1)):
            av = f"{dirn(A[k][1],A[k][2])} {sa[k]}" if k < len(sa) else "--"
            bv = f"{dirn(B[k][1],B[k][2])} {sb[k]}" if k < len(sb) else "--"
            mark = "  " if (k < len(sa) and k < len(sb) and sa[k] == sb[k]) else ">>"
            print(f"{mark}{k:>4}  {av:<40}  {bv}")

    # ---- 3. count table ----
    print("\n=== MILESTONE COUNTS (A | B) ===")
    for m in sorted(set(ca) | set(cb)):
        flag = "" if ca[m] == cb[m] else "  <-- differs"
        print(f"  {ca.get(m,0):>4} | {cb.get(m,0):>4}  {m}{flag}")


if __name__ == "__main__":
    main()
