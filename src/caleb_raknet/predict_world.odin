package caleb_raknet

// Predictor state + outgoing-datagram helpers (predict.py §D/§E/§F foundation
// subset). The broker's "world" is plain data: a flat list of connections plus a
// few scalars. predict.py keeps these in nested dicts; here they are structs and a
// dynamic array scanned by address, so there is no nested-map aliasing to worry
// about. Party / gamesession / binding state is intentionally omitted -- it lands
// with the scene-connect handlers in a later phase.
//
// Outgoing datagrams are appended to world.outbox during a predict() call; the
// harness drains it immediately afterwards. Everything is heap-allocated and left
// for the process to reclaim: a replay is short-lived and bounded, so a per-call
// arena would only add complexity. accepted_bytes is the one value cached across
// calls (an ID_CONNECTION_REQUEST retransmit re-emits the same accepted datagram).

import "core:encoding/base64"
import "core:fmt"
import "core:strings"

// A synthetic client endpoint. The harness assigns ("10.0.0.<n>", <n>) per peer;
// ip octets feed encode_address in the CONNECTION_REQUEST_ACCEPTED / OPEN_CONNECTION
// _REPLY_2 bodies, so they must round-trip through the wire exactly.
Peer_Addr :: struct {
	ip:   [4]u8,
	port: u16,
}

// One connection's transport + handshake state (foundation subset of _new_conn).
Conn :: struct {
	addr:             Peer_Addr,
	next_datagram:    u32,
	next_reliable:    u32,
	next_ordering:    [8]u32, // per ordering channel; only channel 0 is used here
	next_split:       u16,
	accepted_bytes:   []byte, // cached CONNECTION_REQUEST_ACCEPTED datagram (nil until built)
	accepted_valid:   bool,
	established:       bool,
	server_ping_sent: bool,
	conn_result_sent: bool,
	connection_id:    u64,
}

// One emitted server->client datagram, tagged with its destination so the harness
// can split own-peer replies from cross-peer ones (predict.py returns (addr,bytes)).
Out_Dg :: struct {
	addr: Peer_Addr,
	data: []byte,
}

// The broker world: every connection plus the server identity/clock and the
// transient outbox for the current predict() call.
World :: struct {
	conns:       [dynamic]Conn,
	server_guid: u64,
	rng:         u64, // xorshift state -- deterministic stand-in for os.urandom
	now_unix:    u64, // wall-clock stand-in for JWT nbf/iat/exp (noise, fixed)
	clock_ms:    u64, // server clock for pings/pongs (noise, monotonic)
	outbox:      [dynamic]Out_Dg,
}

new_world :: proc(allocator := context.allocator) -> World {
	w := World {
		conns    = make([dynamic]Conn, allocator),
		outbox   = make([dynamic]Out_Dg, allocator),
		rng      = 0x9e3779b97f4a7c15, // fixed seed -> reproducible runs
		now_unix = 1_700_000_000,
		clock_ms = 1000,
	}
	w.server_guid = rng_next(&w)
	return w
}

// Find the connection for `addr`, creating one if absent. Returns an index (not a
// pointer): callers take the pointer only after this returns so a reallocating
// append never dangles a held pointer.
conn_index :: proc(w: ^World, addr: Peer_Addr) -> int {
	for &c, i in w.conns {
		if c.addr == addr do return i
	}
	append(&w.conns, Conn{addr = addr, connection_id = 1})
	return len(w.conns) - 1
}

// xorshift64 -- a deterministic source for guids / session ids / token bytes. Not
// cryptographic; the predictor only needs values that differ from the real ones
// (those fields are treated as noise by the semantic comparison).
rng_next :: proc(w: ^World) -> u64 {
	x := w.rng
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	w.rng = x
	return x
}

rand_bytes :: proc(w: ^World, n: int, allocator := context.allocator) -> []byte {
	out := make([]byte, n, allocator)
	for i in 0 ..< n {
		out[i] = byte(rng_next(w))
	}
	return out
}

server_clock_ms :: proc(w: ^World) -> u64 {
	w.clock_ms += 1
	return w.clock_ms
}

// --- §E outgoing-datagram helpers --------------------------------------------

out_dg :: proc(w: ^World, addr: Peer_Addr, dg: []byte) {
	append(&w.outbox, Out_Dg{addr, dg})
}

alloc_ordering :: proc(conn: ^Conn, channel: u8) -> u32 {
	i := conn.next_ordering[channel]
	conn.next_ordering[channel] += 1
	return i
}

MAX_FRAG :: 1100

// RELIABLE_ORDERED send with automatic fragmentation (predict.py _send_reliable).
send_reliable :: proc(w: ^World, conn: ^Conn, payload: []byte, channel: u8 = 0) {
	if len(payload) <= MAX_FRAG {
		msg := make_message(
			.Reliable_Ordered, payload,
			reliable_num = conn.next_reliable,
			ordering_index = alloc_ordering(conn, channel),
			ordering_channel = channel,
		)
		conn.next_reliable += 1
		out_dg(w, conn.addr, make_data_datagram(conn.next_datagram, msg))
		conn.next_datagram += 1
		return
	}
	sid := conn.next_split
	conn.next_split += 1
	oidx := alloc_ordering(conn, channel)
	nfrags := u32((len(payload) + MAX_FRAG - 1) / MAX_FRAG)
	idx: u32 = 0
	for off := 0; off < len(payload); off += MAX_FRAG {
		end := min(off + MAX_FRAG, len(payload))
		msg := make_message(
			.Reliable_Ordered, payload[off:end],
			reliable_num = conn.next_reliable,
			ordering_index = oidx,
			ordering_channel = channel,
			split = Split_Info{count = nfrags, id = sid, index = idx},
		)
		conn.next_reliable += 1
		out_dg(w, conn.addr, make_data_datagram(conn.next_datagram, msg))
		conn.next_datagram += 1
		idx += 1
	}
}

send_unreliable :: proc(w: ^World, conn: ^Conn, payload: []byte) {
	msg := make_message(.Unreliable, payload)
	out_dg(w, conn.addr, make_data_datagram(conn.next_datagram, msg))
	conn.next_datagram += 1
}

// [137] + req_id(u16 LE) + payload, sent RELIABLE_ORDERED (predict.py
// _send_response_msg).
send_response_msg :: proc(w: ^World, conn: ^Conn, req_id: u16, payload: []byte) {
	b := make([dynamic]byte, context.allocator)
	append(&b, u8(Message_Id.Response_Msg))
	write_u16_le(&b, req_id)
	append(&b, ..payload)
	send_reliable(w, conn, b[:])
}

// [138] + req_id(u16 LE) + has_values(1) (predict.py _send_response_complete).
send_response_complete :: proc(w: ^World, conn: ^Conn, req_id: u16, has_values: bool) {
	b := make([dynamic]byte, context.allocator)
	append(&b, u8(Message_Id.Response_Complete))
	write_u16_le(&b, req_id)
	append(&b, has_values ? 1 : 0)
	send_reliable(w, conn, b[:])
}

// [139] + req_id(u16 LE) + msgpack str16(message) (predict.py _send_response_error).
send_response_error :: proc(w: ^World, conn: ^Conn, req_id: u16, message: string) {
	b := make([dynamic]byte, context.allocator)
	append(&b, u8(Message_Id.Response_Error))
	write_u16_le(&b, req_id)
	mb := transmute([]byte)message
	append(&b, 0xDA, byte(len(mb) >> 8), byte(len(mb)))
	append(&b, ..mb)
	send_reliable(w, conn, b[:])
}

// --- §F identity / tokens ----------------------------------------------------

// base64url without padding (predict.py _b64url).
b64url :: proc(data: []byte, allocator := context.allocator) -> string {
	enc := base64.encode(data, base64.ENC_URL_TABLE, allocator)
	return strings.trim_right(enc, "=")
}

// Build a fake "alg:none" session JWT + its session id (predict.py
// _make_session_jwt). The token contents are deterministic-random and never match
// the real server's -- identity fields are noise to the semantic comparison.
make_session_jwt :: proc(w: ^World, allocator := context.allocator) -> (token: string, sid: string) {
	sid = b64url(rand_bytes(w, 16, allocator), allocator)
	now := w.now_unix
	hdr := `{"alg":"none","typ":"JWT","clusterId":"passtech-live"}`
	body := fmt.aprintf(
		`{"Stormancer/sessionId":"%s","nbf":%d,"exp":%d,"iat":%d,"iss":"passtech-live"}`,
		sid, now, now + 86400, now, allocator = allocator,
	)
	hdr_b64 := b64url(transmute([]byte)hdr, allocator)
	body_b64 := b64url(transmute([]byte)body, allocator)
	token = fmt.aprintf("%s.%s.", hdr_b64, body_b64, allocator = allocator)
	return token, sid
}
