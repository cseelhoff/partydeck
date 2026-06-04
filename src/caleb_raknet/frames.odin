package caleb_raknet

// Layer 4: decode a reassembled RakNet_Message byte array into a RakNet_Frame --
// a typed, structured value describing what the message actually is.
//
// A RakNet_Message (messages.odin) is still opaque bytes: a leading message-id
// byte followed by an id-specific body. This layer interprets that body. The
// result is a RakNet_Frame: a tagged union over every message kind the
// Ravenswatch / Stormancer flow can carry (see src/raknet-dictionary.md). The
// wire dictionary calls these typed units "frames", hence the name.
//
// Decoding is zero-copy: variable-length bodies (msgpack blobs, scene payloads)
// are kept as slices into the message store's pool, never copied. Fields that are
// fixed-width on the wire (clocks, addresses, ids) are read out into scalars.
//
// No OOP, no methods -- a union of plain structs and one free decode function.

import "core:fmt"
import "core:net"

// Message-id bytes (first byte of a connected-layer / transport message). Values
// < 0x80 are RakNet system ids; >= 0x86 are Stormancer transport ids; >= 0x8D is
// a dynamically-assigned scene handle, not a fixed id. See raknet-dictionary §3-4.
ID_CONNECTED_PING              :: 0x00
ID_CONNECTED_PONG              :: 0x03
ID_CONNECTION_REQUEST          :: 0x09
ID_CONNECTION_REQUEST_ACCEPTED :: 0x10
ID_NEW_INCOMING_CONNECTION     :: 0x13
ID_DISCONNECTION_NOTIFICATION  :: 0x15
ID_SYSTEM_REQUEST              :: 134 // 0x86
ID_REQUEST_RESPONSE_MSG        :: 137 // 0x89
ID_REQUEST_RESPONSE_COMPLETE   :: 138 // 0x8A
ID_REQUEST_RESPONSE_ERROR      :: 139 // 0x8B
ID_CONNECTION_RESULT           :: 140 // 0x8C
SCENE_HANDLE_MIN               :: 141 // 0x8D; payload[0] >= this => scene message

MAX_INTERNAL_IDS :: 32 // internal addresses in an ID_CONNECTION_REQUEST_ACCEPTED

// A RakNet IPv4 SystemAddress: version(1) + complemented IPv4(4) + port(2 BE).
// `ip` holds the de-complemented octets; the all-zero address (0.0.0.0:0) is the
// UNASSIGNED padding value used to fill the internal-address array.
System_Address :: struct {
	version: u8,
	ip:      [4]u8,
	port:    u16,
}

// --- RakNet system frames (connected layer, id < 0x80) ----------------------

// ID_CONNECTED_PING: one RakNetTime clock (uint64 BE).
Connected_Ping :: struct {
	clock: u64,
}

// ID_CONNECTED_PONG: the echoed ping clock plus the responder's clock (two BE).
Connected_Pong :: struct {
	echo_clock: u64,
	clock:      u64,
}

// ID_CONNECTION_REQUEST (c->s): client GUID(8) + RakNet::Time(8 BE) + useSecurity.
Connection_Request :: struct {
	guid:         u64,
	time:         u64,
	use_security: bool,
}

// ID_CONNECTION_REQUEST_ACCEPTED (s->c): the server's reply binding the client's
// external address, its system index, the server's internal address list, and the
// ping/pong clocks. `internal_count` is how many of `internal` are non-UNASSIGNED.
Connection_Request_Accepted :: struct {
	remote:         System_Address,
	system_index:   u16,
	internal:       [MAX_INTERNAL_IDS]System_Address,
	internal_count: int,
	echo_time:      u64,
	server_time:    u64,
}

// ID_NEW_INCOMING_CONNECTION (c->s): server address + ping/pong clocks. The middle
// of the body is uninitialized RakNet stack memory (junk_bytes long), not data.
New_Incoming_Connection :: struct {
	server:     System_Address,
	junk_bytes: int,
	ping_time:  u64,
	pong_time:  u64,
}

// ID_DISCONNECTION_NOTIFICATION: no body.
Disconnection_Notification :: struct {}

// --- Stormancer transport frames (id >= 0x86) -------------------------------

// ID_SYSTEM_REQUEST (c->s): a system RPC. `msg_id` selects the request (see
// raknet-dictionary §5), `req_id` correlates the reply, `data` is the msgpack
// argument blob (kept as a slice; decoding msgpack is a higher layer).
System_Request :: struct {
	msg_id: u8,
	req_id: u16,
	data:   []byte,
}

// ID_REQUEST_RESPONSE_MSG (s->c): one streamed RPC value / result for `req_id`.
Response_Msg :: struct {
	req_id: u16,
	data:   []byte, // msgpack value
}

// ID_REQUEST_RESPONSE_COMPLETE (s->c): RPC `req_id` finished; has_values flags
// whether any Response_Msg values preceded it.
Response_Complete :: struct {
	req_id:     u16,
	has_values: bool,
}

// ID_REQUEST_RESPONSE_ERROR (s->c): RPC `req_id` failed; data is the msgpack error.
Response_Error :: struct {
	req_id: u16,
	data:   []byte,
}

// ID_CONNECTION_RESULT (s->c): the server-assigned connection id (uint64 LE).
Connection_Result :: struct {
	connection_id: u64,
}

// Scene data message (payload[0] >= SCENE_HANDLE_MIN): addressed to a scene by its
// runtime-assigned handle and to a route within that scene. `body` is the route
// payload (often [rpcReqId:2 LE] + msgpack); resolving handle->scene/route names
// requires the learned route tables, a higher layer.
Scene_Message :: struct {
	scene_handle: u8,
	route_handle: u16,
	body:         []byte,
}

// Any message-id this layer does not model (reserved transport ids, future ids).
// `id` is the leading byte; `body` is everything after it. Nothing is hidden.
Unknown_Frame :: struct {
	id:   u8,
	body: []byte,
}

// The decoded form of one RakNet_Message: exactly one of the frame kinds above.
RakNet_Frame :: union {
	Connected_Ping,
	Connected_Pong,
	Connection_Request,
	Connection_Request_Accepted,
	New_Incoming_Connection,
	Disconnection_Notification,
	System_Request,
	Response_Msg,
	Response_Complete,
	Response_Error,
	Connection_Result,
	Scene_Message,
	Unknown_Frame,
}

// Decode one complete message payload into its RakNet_Frame. Slices in the result
// alias `msg`, so `msg` must outlive the frame. A truncated or unmodeled message
// falls back to Unknown_Frame rather than failing -- nothing is dropped silently.
decode_frame :: proc(msg: []byte) -> RakNet_Frame {
	if len(msg) == 0 do return Unknown_Frame{}
	id := msg[0]
	body := msg[1:]

	switch int(id) {
	case ID_CONNECTED_PING:
		if len(body) < 8 do break
		return Connected_Ping{clock = read_u64_be(body, 0)}

	case ID_CONNECTED_PONG:
		if len(body) < 16 do break
		return Connected_Pong{echo_clock = read_u64_be(body, 0), clock = read_u64_be(body, 8)}

	case ID_CONNECTION_REQUEST:
		if len(body) < 16 do break
		return Connection_Request {
			guid         = read_u64_be(body, 0),
			time         = read_u64_be(body, 8),
			use_security = len(body) > 16 && body[16] != 0,
		}

	case ID_CONNECTION_REQUEST_ACCEPTED:
		expect := 7 + 2 + MAX_INTERNAL_IDS * 7 + 8 + 8
		if len(body) != expect do break
		f: Connection_Request_Accepted
		off := 0
		f.remote = decode_system_address(body[off:]); off += 7
		f.system_index = read_u16_be(body, off); off += 2
		for k in 0 ..< MAX_INTERNAL_IDS {
			addr := decode_system_address(body[off:]); off += 7
			f.internal[k] = addr
			if !address_is_unassigned(addr) do f.internal_count += 1
		}
		f.echo_time = read_u64_be(body, off); off += 8
		f.server_time = read_u64_be(body, off)
		return f

	case ID_NEW_INCOMING_CONNECTION:
		if len(body) < 7 + 16 do break
		return New_Incoming_Connection {
			server     = decode_system_address(body[:7]),
			junk_bytes = len(body) - 7 - 16,
			ping_time  = read_u64_be(body, len(body) - 16),
			pong_time  = read_u64_be(body, len(body) - 8),
		}

	case ID_DISCONNECTION_NOTIFICATION:
		return Disconnection_Notification{}

	case ID_SYSTEM_REQUEST:
		if len(body) < 3 do break
		return System_Request{msg_id = body[0], req_id = read_u16_le(body, 1), data = body[3:]}

	case ID_REQUEST_RESPONSE_MSG:
		if len(body) < 2 do break
		return Response_Msg{req_id = read_u16_le(body, 0), data = body[2:]}

	case ID_REQUEST_RESPONSE_COMPLETE:
		if len(body) < 3 do break
		return Response_Complete{req_id = read_u16_le(body, 0), has_values = body[2] != 0}

	case ID_REQUEST_RESPONSE_ERROR:
		if len(body) < 2 do break
		return Response_Error{req_id = read_u16_le(body, 0), data = body[2:]}

	case ID_CONNECTION_RESULT:
		if len(body) < 8 do break
		return Connection_Result{connection_id = read_u64_le(body, 0)}
	}

	if int(id) >= SCENE_HANDLE_MIN && len(body) >= 2 {
		return Scene_Message{scene_handle = id, route_handle = read_u16_le(body, 0), body = body[2:]}
	}
	return Unknown_Frame{id = id, body = body}
}

// Decode a 7-byte RakNet SystemAddress: version(1) + complemented IPv4(4) +
// port(2 BE). The IPv4 octets are stored on the wire one's-complemented.
decode_system_address :: proc(b: []byte) -> System_Address {
	if len(b) < 7 do return System_Address{}
	return System_Address {
		version = b[0],
		ip = {~b[1], ~b[2], ~b[3], ~b[4]},
		port = read_u16_be(b, 5),
	}
}

address_is_unassigned :: proc(a: System_Address) -> bool {
	return a.ip == {0, 0, 0, 0} && a.port == 0
}

read_u16_le :: proc(b: []byte, off: int) -> u16 {
	return u16(b[off]) | u16(b[off + 1]) << 8
}

read_u64_be :: proc(b: []byte, off: int) -> u64 {
	return(
		u64(b[off]) << 56 |
		u64(b[off + 1]) << 48 |
		u64(b[off + 2]) << 40 |
		u64(b[off + 3]) << 32 |
		u64(b[off + 4]) << 24 |
		u64(b[off + 5]) << 16 |
		u64(b[off + 6]) << 8 |
		u64(b[off + 7]) \
	)
}

read_u64_le :: proc(b: []byte, off: int) -> u64 {
	return(
		u64(b[off]) |
		u64(b[off + 1]) << 8 |
		u64(b[off + 2]) << 16 |
		u64(b[off + 3]) << 24 |
		u64(b[off + 4]) << 32 |
		u64(b[off + 5]) << 40 |
		u64(b[off + 6]) << 48 |
		u64(b[off + 7]) << 56 \
	)
}

// One-line summary of a decoded frame, for debug output.
print_frame :: proc(frame: RakNet_Frame) {
	switch f in frame {
	case Connected_Ping:
		fmt.printf("Connected_Ping clk=%d", f.clock)
	case Connected_Pong:
		fmt.printf("Connected_Pong echo=%d clk=%d", f.echo_clock, f.clock)
	case Connection_Request:
		fmt.printf("Connection_Request guid=%016x time=%d sec=%v", f.guid, f.time, f.use_security)
	case Connection_Request_Accepted:
		fmt.printf(
			"Connection_Request_Accepted remote=%s sysidx=%d internal=%d echo=%d srv=%d",
			address_to_string(f.remote), f.system_index, f.internal_count, f.echo_time, f.server_time,
		)
	case New_Incoming_Connection:
		fmt.printf(
			"New_Incoming_Connection server=%s junk=%dB ping=%d pong=%d",
			address_to_string(f.server), f.junk_bytes, f.ping_time, f.pong_time,
		)
	case Disconnection_Notification:
		fmt.printf("Disconnection_Notification")
	case System_Request:
		fmt.printf("System_Request msg_id=%d req=%d data=%dB", f.msg_id, f.req_id, len(f.data))
	case Response_Msg:
		fmt.printf("Response_Msg req=%d data=%dB", f.req_id, len(f.data))
	case Response_Complete:
		fmt.printf("Response_Complete req=%d has_values=%v", f.req_id, f.has_values)
	case Response_Error:
		fmt.printf("Response_Error req=%d data=%dB", f.req_id, len(f.data))
	case Connection_Result:
		fmt.printf("Connection_Result connid=%d", f.connection_id)
	case Scene_Message:
		fmt.printf("Scene_Message handle=%d route=%d body=%dB", f.scene_handle, f.route_handle, len(f.body))
	case Unknown_Frame:
		fmt.printf("Unknown_Frame id=0x%02x body=%dB", f.id, len(f.body))
	case:
		fmt.printf("nil")
	}
}

address_to_string :: proc(a: System_Address) -> string {
	// Reuses core:net formatting via a temporary endpoint for a stable a.b.c.d:port.
	ep := net.Endpoint {
		address = net.IP4_Address{a.ip[0], a.ip[1], a.ip[2], a.ip[3]},
		port    = int(a.port),
	}
	return net.endpoint_to_string(ep, context.temp_allocator)
}
