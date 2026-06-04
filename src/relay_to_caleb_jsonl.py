#!/usr/bin/env python3
"""Convert a relay_capture.jsonl into the JSONL format caleb_raknet replay expects.

Source records: {"t", "dir" (c2s|s2c), "peer", "hex"}
Target records: {"t" (rfc3339), "from" (ip:port), "len", "hex"}

`from` is synthesized per (peer, direction) so that client-sent and server-sent
split fragments are keyed to distinct senders during reassembly. The timestamp is
normalized to RFC3339 by appending a 'Z' when no timezone is present.
"""

import json
import sys


def synth_from(peer: str, direction: str) -> str:
    # Stable, distinct ip:port per (peer, direction). Octet from peer hash, port
    # from direction so c2s and s2c never share a sender key.
    octet = (abs(hash(peer)) % 254) + 1
    port = 10001 if direction == "c2s" else 20001
    return f"10.0.0.{octet}:{port}"


def normalize_time(t: str) -> str:
    if t.endswith("Z") or "+" in t[10:]:
        return t
    return t + "Z"


def main() -> int:
    src = sys.argv[1] if len(sys.argv) > 1 else "pcaps/relay_capture.jsonl"
    dst = sys.argv[2] if len(sys.argv) > 2 else "pcaps/relay_capture.caleb.jsonl"

    n = 0
    with open(src) as fin, open(dst, "w") as fout:
        for line in fin:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            hexstr = rec["hex"]
            out = {
                "t": normalize_time(rec["t"]),
                "from": synth_from(rec.get("peer", "?"), rec.get("dir", "c2s")),
                "len": len(hexstr) // 2,
                "hex": hexstr,
            }
            fout.write(json.dumps(out) + "\n")
            n += 1

    print(f"wrote {n} records to {dst}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
