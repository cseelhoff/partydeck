#!/usr/bin/env python3
"""Tiny stdlib-only DNS forwarder that suppresses AAAA (IPv6) answers for a set
of domains, forcing IPv4 fallback.

Why: some game backends (e.g. Passtech/Stormancer for Ravenswatch) publish a
dead AAAA record. Wine's winhttp resolves via res_query (reading resolv.conf,
ignoring /etc/hosts), grabs the dead IPv6, and never falls back to the working
IPv4 -> WinHttp 12029. Pointing the sandbox's resolv.conf at this shim makes
AAAA lookups for the target domains return NODATA, so the client uses the live A
record. All other queries are forwarded untouched to the upstream resolver.

Usage:
  dns_aaaa_filter.py [--listen 127.0.0.1:53] [--upstream 10.1.1.1:53] \
                     [--domain passtechgames.com ...]
With no --domain, AAAA is stripped for ALL names.
"""
import argparse
import socket
import struct
import sys
import threading


def parse_question(data):
    """Return (qname_lower, qtype) from a DNS query, or (None, None)."""
    try:
        pos = 12  # skip header
        labels = []
        while True:
            length = data[pos]
            if length == 0:
                pos += 1
                break
            if length & 0xC0:  # compression pointer in a question -> bail
                return None, None
            labels.append(data[pos + 1 : pos + 1 + length].decode("ascii", "ignore"))
            pos += 1 + length
        qtype = struct.unpack("!H", data[pos : pos + 2])[0]
        return ".".join(labels).lower(), qtype
    except Exception:
        return None, None


def nodata_response(query):
    """Build a NOERROR/NODATA reply (QR=1, RA=1, ANCOUNT=0) echoing the question."""
    txid = query[:2]
    # flags: QR=1, Opcode=0, AA=0, TC=0, RD=1, RA=1, RCODE=0
    flags = struct.pack("!H", 0x8180)
    # QDCOUNT=1, ANCOUNT=0, NSCOUNT=0, ARCOUNT=0
    counts = struct.pack("!HHHH", 1, 0, 0, 0)
    question = query[12:]  # original question section
    return txid + flags + counts + question


def servfail_response(query):
    """Build a SERVFAIL reply (QR=1, RA=1, RCODE=2) echoing the question. Used
    when upstream forwarding fails so the client gets a prompt, well-formed
    answer instead of timing out — important when this shim sits behind a
    system-wide DNS redirect, so a transient upstream hiccup never hangs other
    apps' name resolution."""
    txid = query[:2]
    flags = struct.pack("!H", 0x8182)  # QR=1, RD=1, RA=1, RCODE=2 (SERVFAIL)
    counts = struct.pack("!HHHH", 1, 0, 0, 0)
    question = query[12:]
    return txid + flags + counts + question


def handle(data, addr, sock, upstream, domains, tcp_upstream):
    qname, qtype = parse_question(data)
    strip = qtype == 28 and (  # 28 = AAAA
        not domains or any(qname == d or qname.endswith("." + d) for d in domains)
    )
    if strip:
        sock.sendto(nodata_response(data), addr)
        return
    # Forward to upstream and relay the reply. TCP upstream is used when this
    # shim is fed by an iptables UDP-53 REDIRECT: forwarding upstream over TCP
    # avoids the redirect catching our own upstream query (an infinite loop).
    try:
        if tcp_upstream:
            up = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            up.settimeout(5)
            up.connect(upstream)
            up.sendall(struct.pack("!H", len(data)) + data)
            hdr = up.recv(2)
            if len(hdr) == 2:
                length = struct.unpack("!H", hdr)[0]
                reply = b""
                while len(reply) < length:
                    chunk = up.recv(length - len(reply))
                    if not chunk:
                        break
                    reply += chunk
                sock.sendto(reply, addr)
            up.close()
        else:
            up = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            up.settimeout(5)
            up.sendto(data, upstream)
            reply, _ = up.recvfrom(65535)
            up.close()
            sock.sendto(reply, addr)
    except Exception as e:
        sys.stderr.write(f"forward error for {qname}/{qtype}: {e}\n")
        # Never leave the client hanging: answer SERVFAIL so resolution fails
        # fast and the system resolver can fall back instead of timing out.
        try:
            sock.sendto(servfail_response(data), addr)
        except Exception:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", default="127.0.0.1:53")
    ap.add_argument("--upstream", default="10.1.1.1:53")
    ap.add_argument("--domain", action="append", default=[])
    ap.add_argument(
        "--tcp-upstream",
        action="store_true",
        help="forward upstream over TCP (use with an iptables UDP-53 REDIRECT to avoid loops)",
    )
    args = ap.parse_args()

    lhost, lport = args.listen.rsplit(":", 1)
    uhost, uport = args.upstream.rsplit(":", 1)
    upstream = (uhost, int(uport))
    domains = [d.lower().rstrip(".") for d in args.domain]

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((lhost, int(lport)))
    sys.stderr.write(
        f"dns_aaaa_filter: listening {lhost}:{lport} -> upstream {uhost}:{uport}"
        f"{' (tcp)' if args.tcp_upstream else ''}; stripping AAAA for {domains or 'ALL'}\n"
    )
    sys.stderr.flush()
    while True:
        try:
            data, addr = sock.recvfrom(65535)
        except KeyboardInterrupt:
            break
        threading.Thread(
            target=handle,
            args=(data, addr, sock, upstream, domains, args.tcp_upstream),
            daemon=True,
        ).start()


if __name__ == "__main__":
    main()
