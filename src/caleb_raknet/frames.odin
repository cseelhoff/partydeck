package caleb_raknet

// Layer 4: decode a reassembled RakNet_Message byte array into a Decoded_Message
// -- a typed, structured value describing what the message actually is.
//
// A RakNet_Message (messages.odin) is still opaque bytes: a leading message-id
// byte followed by an id-specific body. This layer interprets that body. The
// result is a Decoded_Message: a tagged union over every message kind the
// Ravenswatch / Stormancer flow can carry (see src/raknet-dictionary.md).
//
// Decoding is zero-copy: variable-length bodies (msgpack blobs, scene payloads)
// are kept as slices into the message store's pool, never copied. Fields that are
// fixed-width on the wire (clocks, addresses, ids) are read out into scalars.
//
// No OOP, no methods -- a union of plain structs and one free decode function.

import "core:encoding/base64"
import "core:fmt"
import "core:net"
import "core:strings"

// Message_Id is the first byte of a connected-layer / transport message: the id
// the application switches on (mirrors RakNet's `MessageID` / enum
// DefaultMessageIDTypes). Values < 0x80 are RakNet system ids; >= 0x86 are
// Stormancer transport ids; a byte >= SCENE_HANDLE_MIN is a dynamically-assigned
// scene handle, not a fixed id. See raknet-dictionary §3-4.
Message_Id :: enum u8 {
	Connected_Ping              = 0x00,
	Connected_Pong              = 0x03,
	Connection_Request          = 0x09,
	Connection_Request_Accepted = 0x10,
	New_Incoming_Connection     = 0x13,
	Disconnection_Notification  = 0x15,
	System_Request              = 134, // 0x86
	Response_Msg                = 137, // 0x89
	Response_Complete           = 138, // 0x8A
	Response_Error              = 139, // 0x8B
	Connection_Result           = 140, // 0x8C
}

SCENE_HANDLE_MIN :: 141 // 0x8D; payload[0] >= this => scene message

MAX_INTERNAL_IDS :: 32 // internal addresses in a Connection_Request_Accepted

// A RakNet IPv4 SystemAddress: version(1) + complemented IPv4(4) + port(2 BE).
// `ip` holds the de-complemented octets; the all-zero address (0.0.0.0:0) is the
// UNASSIGNED padding value used to fill the internal-address array.
System_Address :: struct {
	version: u8,
	ip:      [4]u8,
	port:    u16,
}

// --- RakNet system frames (connected layer, id < 0x80) ----------------------

// Connected_Ping: one RakNetTime clock (uint64 BE).
Connected_Ping :: struct {
	clock: u64,
}

// Connected_Pong: the echoed ping clock plus the responder's clock (two BE).
Connected_Pong :: struct {
	echo_clock: u64,
	clock:      u64,
}

// Connection_Request (c->s): client GUID(8) + RakNet::Time(8 BE) + useSecurity.
// `trailer` is every byte after the 16-byte guid+time (the security byte and any
// padding) kept verbatim so the message re-encodes exactly -- a present-but-zero
// security byte is not the same wire as an absent one.
Connection_Request :: struct {
	guid:         u64,
	time:         u64,
	use_security: bool,
	trailer:      []byte,
}

// Connection_Request_Accepted (s->c): the server's reply binding the client's
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

// New_Incoming_Connection (c->s): server address + the sender's internal address
// list + ping/pong clocks. The middle is the sender's own ipList -- up to
// MAXIMUM_NUMBER_OF_INTERNAL_IDS RakNet SystemAddresses (mostly UNASSIGNED
// 0.0.0.0:0 padding), the same data as Connection_Request_Accepted.internal. It is
// kept as an unparsed byte span (internal_list) because entries may be IPv4 or
// IPv6, so the stride is not fixed; decoding each address is left to a caller.
// internal_list_bytes is len(internal_list), retained for the existing renderer.
New_Incoming_Connection :: struct {
	server:              System_Address,
	internal_list:       []byte,
	internal_list_bytes: int,
	ping_time:           u64,
	pong_time:           u64,
}

// Disconnection_Notification: no body.
Disconnection_Notification :: struct {}

// --- Stormancer transport frames (id >= 0x86) -------------------------------

// System_Request_Id is the sub-id (second byte of an ID_SYSTEM_REQUEST frame):
// which system RPC is being invoked. Mirrors Stormancer SystemRequestIDTypes
// (stormancer-sdk-js). 0/1/2/134/135/136 are the stock SDK ids; 14 and 16 are
// Ravenswatch-specific extensions observed in capture (see predict.py SR_*).
System_Request_Id :: enum u8 {
	Set_Metadata          = 0,
	Scene_Ready           = 1,
	Ping                  = 2,
	Get_Session_Token     = 14,
	Scene_Ready2          = 16,
	Connect_To_Scene      = 134,
	Disconnect_From_Scene = 135,
	Get_Scene_Infos       = 136,
}

// System_Request (c->s): a Stormancer system RPC. `msg_id` selects the request,
// `req_id` correlates the reply, `args` is the typed argument shape for that
// request (see system_request.odin). `raw_args` is the undecoded msgpack args blob
// (body after the 3-byte header), kept so the message re-encodes byte-exact -- the
// typed `args` reorders/normalizes and cannot reproduce the original map order.
// RequestProcessor.sendSystemRequest: [msgId:1][reqId:2 LE][msgpack args].
// RakNet has no analog -- it hands the whole payload up opaque.
System_Request :: struct {
	msg_id:   System_Request_Id,
	req_id:   u16,
	args:     System_Request_Args,
	raw_args: []byte,
}

// Response_Msg (s->c): one streamed RPC value / result for `req_id`. `data` is the
// typed reply shape (see response.odin), chosen by the structure of the payload
// since the originating RPC type is not known from a req_id alone. `raw` is the
// undecoded payload after the 2-byte req_id, kept so the message re-encodes
// byte-exact (the typed `data` does not retain every blob).
Response_Msg :: struct {
	req_id: u16,
	data:   Response_Data,
	raw:    []byte,
}

// Response_Complete (s->c): RPC `req_id` finished; has_values flags
// whether any Response_Msg values preceded it.
Response_Complete :: struct {
	req_id:     u16,
	has_values: bool,
}

// Response_Error (s->c): RPC `req_id` failed; data is the decoded msgpack error.
Response_Error :: struct {
	req_id: u16,
	data:   Msgpack,
}

// Connection_Result (s->c): the server-assigned connection id (uint64 LE).
Connection_Result :: struct {
	connection_id: u64,
}

// Scene data message (payload[0] >= SCENE_HANDLE_MIN): addressed to a scene by its
// runtime-assigned handle and to a route within that scene. `body` is the route
// payload (often [rpcReqId:2 LE] + msgpack); `decoded` is that payload parsed into
// its rpc id + msgpack value list (scene_message.odin). Resolving handle->scene/
// route names requires the learned route tables, a higher layer.
Scene_Message :: struct {
	scene_handle: u8,
	route_handle: u16,
	body:         Scene_Message_Body,
	raw_body:     []byte,
	decoded:      Scene_Body,
}

// A known message id whose body was too short / wrong length to decode. Surfaced
// as an explicit value -- NOT collapsed into Unknown_Message -- so a malformed
// known message is distinguishable from a genuinely unknown id. `expected` is the
// body length the decoder required; `body_len` is what actually arrived. `raw` is
// the full original message bytes (id included) so it still re-encodes exactly.
Malformed_Message :: struct {
	id:       u8,
	body_len: int,
	expected: int,
	raw:      []byte,
}

// Any message-id this layer does not model (reserved transport ids, future ids).
// `id` is the leading byte; `body` is everything after it. Nothing is hidden.
Unknown_Message :: struct {
	id:   u8,
	body: []byte,
}

// The decoded form of one RakNet_Message: exactly one of the message kinds above.
Decoded_Message :: union {
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
	Malformed_Message,
	Unknown_Message,
}

// Decode one complete message payload into its Decoded_Message. Slices in the
// result alias `msg`, so `msg` must outlive the result. A known id whose body is
// too short returns Malformed_Message; an unmodeled id returns Unknown_Message.
// Either way nothing is dropped, and a decode failure is an explicit value.
decode_message :: proc(msg: []byte, allocator := context.allocator) -> Decoded_Message {
	if len(msg) == 0 do return Malformed_Message{id = 0, body_len = 0, expected = 1, raw = msg}
	id := msg[0]
	body := msg[1:]

	#partial switch Message_Id(id) {
	case .Connected_Ping:
		if len(body) < 8 do return Malformed_Message{id, len(body), 8, msg}
		return Connected_Ping{clock = read_u64_be(body, 0)}

	case .Connected_Pong:
		if len(body) < 16 do return Malformed_Message{id, len(body), 16, msg}
		return Connected_Pong{echo_clock = read_u64_be(body, 0), clock = read_u64_be(body, 8)}

	case .Connection_Request:
		if len(body) < 16 do return Malformed_Message{id, len(body), 16, msg}
		return Connection_Request {
			guid = read_u64_be(body, 0),
			time = read_u64_be(body, 8),
			use_security = len(body) > 16 && body[16] != 0,
			trailer = body[16:],
		}

	case .Connection_Request_Accepted:
		expect := 7 + 2 + MAX_INTERNAL_IDS * 7 + 8 + 8
		if len(body) != expect do return Malformed_Message{id, len(body), expect, msg}
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

	case .New_Incoming_Connection:
		if len(body) < 7 + 16 do return Malformed_Message{id, len(body), 7 + 16, msg}
		return New_Incoming_Connection {
			server = decode_system_address(body[:7]),
			internal_list = body[7:len(body) - 16],
			internal_list_bytes = len(body) - 7 - 16,
			ping_time = read_u64_be(body, len(body) - 16),
			pong_time = read_u64_be(body, len(body) - 8),
		}

	case .Disconnection_Notification:
		return Disconnection_Notification{}

	case .System_Request:
		if len(body) < 3 do return Malformed_Message{id, len(body), 3, msg}
		msg_id := System_Request_Id(body[0])
		decoded := decode_msgpack_field(body[3:], allocator)
		return System_Request {
			msg_id = msg_id,
			req_id = read_u16_le(body, 1),
			args = parse_system_request_args(msg_id, decoded, allocator),
			raw_args = body[3:],
		}

	case .Response_Msg:
		if len(body) < 2 do return Malformed_Message{id, len(body), 2, msg}
		return Response_Msg {
			req_id = read_u16_le(body, 0),
			data = parse_response_data(decode_msgpack_field(body[2:], allocator), allocator),
			raw = body[2:],
		}

	case .Response_Complete:
		if len(body) < 3 do return Malformed_Message{id, len(body), 3, msg}
		return Response_Complete{req_id = read_u16_le(body, 0), has_values = body[2] != 0}

	case .Response_Error:
		if len(body) < 2 do return Malformed_Message{id, len(body), 2, msg}
		return Response_Error {
			req_id = read_u16_le(body, 0),
			data = decode_msgpack_field(body[2:], allocator),
		}

	case .Connection_Result:
		if len(body) < 8 do return Malformed_Message{id, len(body), 8, msg}
		return Connection_Result{connection_id = read_u64_le(body, 0)}
	}

	if int(id) >= SCENE_HANDLE_MIN {
		if len(body) < 2 do return Malformed_Message{id, len(body), 2, msg}
		route_payload := body[2:]
		decoded_body := decode_scene_body(route_payload, allocator)
		return Scene_Message {
			scene_handle = id,
			route_handle = read_u16_le(body, 0),
			body = parse_scene_message_body("", route_payload, decoded_body, allocator),
			raw_body = route_payload,
			decoded = decoded_body,
		}
	}
	return Unknown_Message{id = id, body = body}
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

// Write a one-line summary of a decoded message into `sb`, for debug output. The
// caller owns `sb` and can reset and reuse it across many messages, so no per-call
// string is allocated. `route_name` is the resolved name for a Scene_Message's
// route handle (route_table.odin), or "" when unknown / not a scene message.
write_decoded_message :: proc(sb: ^strings.Builder, message: Decoded_Message, route_name := "") {
	switch f in message {
	case Connected_Ping:
		fmt.sbprintf(sb, "Connected_Ping clk=%d", f.clock)
	case Connected_Pong:
		fmt.sbprintf(sb, "Connected_Pong echo=%d clk=%d", f.echo_clock, f.clock)
	case Connection_Request:
		fmt.sbprintf(
			sb,
			"Connection_Request guid=%016x time=%d sec=%v",
			f.guid,
			f.time,
			f.use_security,
		)
	case Connection_Request_Accepted:
		fmt.sbprintf(
			sb,
			"Connection_Request_Accepted remote=%s sysidx=%d internal=%d echo=%d srv=%d",
			address_to_string(f.remote),
			f.system_index,
			f.internal_count,
			f.echo_time,
			f.server_time,
		)
	case New_Incoming_Connection:
		fmt.sbprintf(
			sb,
			"New_Incoming_Connection server=%s internal_list=%dB ping=%d pong=%d",
			address_to_string(f.server),
			f.internal_list_bytes,
			f.ping_time,
			f.pong_time,
		)
	case Disconnection_Notification:
		fmt.sbprintf(sb, "Disconnection_Notification")
	case System_Request:
		fmt.sbprintf(sb, "System_Request msg_id=%v req=%d args=", f.msg_id, f.req_id)
		write_system_request_args(sb, f.args)
	case Response_Msg:
		fmt.sbprintf(sb, "Response_Msg req=%d data=", f.req_id)
		write_response_data(sb, f.data)
	case Response_Complete:
		fmt.sbprintf(sb, "Response_Complete req=%d has_values=%v", f.req_id, f.has_values)
	case Response_Error:
		fmt.sbprintf(sb, "Response_Error req=%d data=%s", f.req_id, msgpack_field_string(f.data))
	case Connection_Result:
		fmt.sbprintf(sb, "Connection_Result connid=%d", f.connection_id)
	case Scene_Message:
		fmt.sbprintf(sb, "Scene_Message handle=%d route=%d", f.scene_handle, f.route_handle)
		if route_name != "" do fmt.sbprintf(sb, "(%s)", route_name)
		if strings.contains(route_name, "party.memberConnected") {
			if body, ok := f.body.(Party_MemberConnected_Body); ok {
				strings.write_byte(sb, ' ')
				write_party_member_connected_body(sb, body)
				return
			}
			strings.write_byte(sb, ' ')
			write_party_member_connected_body(sb, parse_party_member_connected_body(f.decoded, context.temp_allocator))
			return
		}
		if route_name == "party.memberDataUpdated" {
			if body, ok := f.body.(Party_MemberDataUpdated_Body); ok {
				strings.write_byte(sb, ' ')
				write_party_member_data_updated_body(sb, body)
				return
			}
		}
		if body, ok := f.body.(Friends_Notification_Body); ok {
			strings.write_byte(sb, ' ')
			write_friends_notification_body(sb, body)
			return
		}
		if body, ok := f.body.(Stormancer_Rpc_Next_Body); ok {
			strings.write_byte(sb, ' ')
			write_stormancer_rpc_next_body(sb, body)
			return
		}
		if body, ok := f.body.(Locator_GetSceneConnectionToken_Body); ok {
			strings.write_byte(sb, ' ')
			fmt.sbprintf(sb, "rpc=%d [", body.rpc_id)
			write_scene_string(sb, body.scene_type)
			strings.write_string(sb, ", ")
			write_scene_string(sb, body.scene_id)
			strings.write_byte(sb, ']')
			return
		}
		if strings.contains(route_name, "stormancer.rpc.next") {
			strings.write_byte(sb, ' ')
			write_stormancer_rpc_next_body(sb, parse_stormancer_rpc_next_body(f.decoded))
			return
		}
		if scene_body_has_token_envelope(f.decoded) {
			strings.write_byte(sb, ' ')
			write_stormancer_rpc_next_body(sb, parse_stormancer_rpc_next_body(f.decoded))
			return
		}
		if (f.scene_handle == 141 || f.scene_handle == 143) && f.route_handle == 2 && f.decoded.has_rpc_id {
			strings.write_byte(sb, ' ')
			write_stormancer_rpc_next_body(sb, parse_stormancer_rpc_next_body(f.decoded))
			return
		}
		if body, ok := f.body.(Party_State_Response_Body); ok {
			strings.write_byte(sb, ' ')
			write_party_state_response_body(sb, body)
			return
		}
		// Show the raw byte length only when the body did not decode cleanly --
		// otherwise the decoded value list already accounts for every byte.
		if f.decoded.values.ok do strings.write_byte(sb, ' ')
		else do fmt.sbprintf(sb, " body=%dB ", len(f.raw_body))
		write_scene_body(sb, f.decoded)
	case Malformed_Message:
		fmt.sbprintf(
			sb,
			"Malformed_Message id=0x%02x body=%dB expected>=%dB",
			f.id,
			f.body_len,
			f.expected,
		)
	case Unknown_Message:
		fmt.sbprintf(sb, "Unknown_Message id=0x%02x body=%dB", f.id, len(f.body))
	case:
		fmt.sbprintf(sb, "nil")
	}
}

write_party_member_connected_body :: proc(sb: ^strings.Builder, body: Party_MemberConnected_Body) {
	fmt.sbprintf(sb, "rpc=%d [%d, ", body.rpc_id, body.version)
	write_party_connected_member(sb, body.member)
	strings.write_byte(sb, ']')
	write_quoted_printable_tail(sb, body.raw_tail)
}

write_friends_notification_body :: proc(sb: ^strings.Builder, body: Friends_Notification_Body) {
	write_scene_body(sb, Scene_Body{values = body.values, raw_tail = body.raw_tail})
}

write_stormancer_rpc_next_body :: proc(sb: ^strings.Builder, body: Stormancer_Rpc_Next_Body) {
	fmt.sbprintf(sb, "rpc=%d [", body.rpc_id)
	#partial switch body.kind {
	case .Scene_Connection_Token:
		write_stormancer_rpc_next_token(sb, body)
	case .Authentication_Login_Result:
		fmt.sbprintf(
			sb,
			"login success=%v user=%q steam=%q metadata=%d",
			body.success,
			body.user_id,
			body.steam_id,
			body.metadata_count,
		)
	case .GameSession_P2PToken_Result:
		strings.write_string(sb, "[nil, false, nil]")
	case:
		strings.write_string(sb, "unknown")
	}
	strings.write_byte(sb, ']')
	write_stormancer_rpc_next_tail(sb, body)
}

write_stormancer_rpc_next_token :: proc(sb: ^strings.Builder, body: Stormancer_Rpc_Next_Body) {
	if !body.token.ok {
		write_scene_string(sb, body.token_json)
		return
	}
	strings.write_string(sb, "token=")
	write_connection_token(sb, body.token)
	fmt.sbprintf(sb, " content=%q user_data=", body.token.content_type)
	write_token_user_data(sb, body.token.user_data, body.token.content_type)
	strings.write_string(sb, " endpoints=[")
	for endpoint, i in body.token_raknet_endpoints {
		if i > 0 do strings.write_string(sb, ", ")
		fmt.sbprintf(sb, "%q", endpoint)
	}
	strings.write_string(sb, "]")
	fmt.sbprintf(sb, " encryption={{algorithm=%q, mode=%q, key=", body.encryption_algorithm, body.encryption_mode)
	write_base64_decoded_bytes(sb, body.encryption_key)
	strings.write_string(sb, ", token=")
	write_base64_decoded_bytes(sb, body.encryption_token)
	strings.write_byte(sb, '}')
}

write_token_user_data :: proc(sb: ^strings.Builder, user_data: []byte, content_type: string) {
	if len(user_data) == 0 {
		strings.write_string(sb, "bin<0>")
		return
	}
	if content_type == "stormancer/userSession" {
		write_user_session_data(sb, parse_user_session_data(user_data, context.temp_allocator))
		return
	}
	decoded := msgpack_decode_seq(user_data, allocator = context.temp_allocator)
	if decoded.ok && len(decoded.roots) > 0 {
		strings.write_string(sb, "msgpack=[")
		for root, i in decoded.roots {
			if i > 0 do strings.write_string(sb, ", ")
			write_scene_value(sb, decoded.nodes, root)
		}
		strings.write_byte(sb, ']')
		return
	}
	write_scene_bin(sb, user_data)
}

write_user_session_token_data :: proc(sb: ^strings.Builder, data: []byte) {
	fmt.sbprintf(sb, "userSession{{bytes=%d", len(data))
	decoded_payload := false
	if len(data) >= 4 {
		payload_len := int(read_u32_be(data, 0))
		fmt.sbprintf(sb, ", payload_len=%d", payload_len)
		if payload_len >= 0 && payload_len == len(data) - 4 {
			decoded := msgpack_decode_seq(data[4:], allocator = context.temp_allocator)
			if decoded.ok && len(decoded.roots) == 1 {
				write_user_session_payload_fields(sb, decoded.nodes, decoded.roots[0])
				decoded_payload = true
			}
		}
	}
	if !decoded_payload {
		strings.write_string(sb, ", raw_bytes=")
		write_byte_values(sb, data)
	}
	strings.write_byte(sb, '}')
}

write_user_session_payload_fields :: proc(sb: ^strings.Builder, nodes: []Msgpack_Node, root: int) {
	if root < 0 || root >= len(nodes) || nodes[root].kind != .Array do return
	strings.write_string(sb, ", fields={")
	child := root + 1
	for index := 0; index < nodes[root].count; index += 1 {
		if child < 0 || child >= len(nodes) do break
		if index > 0 do strings.write_string(sb, ", ")
		fmt.sbprintf(sb, "%02d=", index)
		write_user_session_value(sb, nodes, child)
		child += nodes[child].subtree
	}
	strings.write_byte(sb, '}')
}

write_user_session_value :: proc(sb: ^strings.Builder, nodes: []Msgpack_Node, i: int) -> int {
	if i < 0 || i >= len(nodes) do return i
	n := nodes[i]
	#partial switch n.kind {
	case .Str:
		write_scene_string(sb, n.str)
		return i + 1
	case .Bin:
		if is_printable_text(n.bin) {
			write_scene_string(sb, string(n.bin))
		} else {
			strings.write_string(sb, "bytes=")
			write_byte_values(sb, n.bin)
		}
		return i + 1
	case .Ext:
		if n.ext_type == -1 && len(n.bin) == 8 {
			seconds := read_u64_be(n.bin, 0) & 0x3_FFFF_FFFF
			fmt.sbprintf(sb, "timestamp{{sec=%d, bytes=", seconds)
			write_byte_values(sb, n.bin)
			strings.write_byte(sb, '}')
		} else {
			fmt.sbprintf(sb, "ext(%d){{bytes=", n.ext_type)
			write_byte_values(sb, n.bin)
			strings.write_byte(sb, '}')
		}
		return i + 1
	case .Array:
		strings.write_byte(sb, '[')
		j := i + 1
		for index in 0 ..< n.count {
			if j >= len(nodes) do break
			if index > 0 do strings.write_string(sb, ", ")
			j = write_user_session_value(sb, nodes, j)
		}
		strings.write_byte(sb, ']')
		return j
	case .Map:
		strings.write_byte(sb, '{')
		j := i + 1
		for index in 0 ..< n.count {
			if j >= len(nodes) do break
			if index > 0 do strings.write_string(sb, ", ")
			j = write_user_session_value(sb, nodes, j)
			if j >= len(nodes) do break
			strings.write_string(sb, ": ")
			j = write_user_session_value(sb, nodes, j)
		}
		strings.write_byte(sb, '}')
		return j
	}
	return mp_write(sb, nodes, i)
}

write_base64_decoded_bytes :: proc(sb: ^strings.Builder, value: string) {
	decoded, err := base64.decode(value, base64.DEC_TABLE, context.temp_allocator)
	if err != nil {
		fmt.sbprintf(sb, "%q", value)
		return
	}
	fmt.sbprintf(sb, "base64<%d> ", len(decoded))
	write_byte_values(sb, decoded)
}

write_stormancer_rpc_next_tail :: proc(sb: ^strings.Builder, body: Stormancer_Rpc_Next_Body) {
	if len(body.raw_tail) == 0 do return
	write_quoted_printable_tail(sb, body.raw_tail)
}

tail_all_zero :: proc(data: []byte) -> bool {
	if len(data) == 0 do return false
	for b in data {
		if b != 0 do return false
	}
	return true
}

write_party_state_response_body :: proc(sb: ^strings.Builder, body: Party_State_Response_Body) {
	fmt.sbprintf(sb, "rpc=%d [", body.rpc_id)
	write_party_settings(sb, body.settings)
	fmt.sbprintf(sb, ", %q, [", body.leader_user_id)
	for member, i in body.members {
		if i > 0 do strings.write_string(sb, ", ")
		write_party_state_member(sb, member)
	}
	fmt.sbprintf(sb, "], %d]", body.revision)
	write_connection_metadata_trailer(sb, body.connection_metadata)
}

write_party_settings :: proc(sb: ^strings.Builder, settings: Scene_Party_Settings) {
	strings.write_byte(sb, '[')
	fmt.sbprintf(sb, "%q, ", settings.game_finder)
	write_scene_string(sb, settings.custom_data_json)
	fmt.sbprintf(
		sb,
		", %d, %v, %v, ",
		settings.revision,
		settings.only_leader_invite,
		settings.is_joinable,
	)
	if settings.server_status != "" || settings.server_status_details != "" {
		fmt.sbprintf(
			sb,
			"{\"stormancer.partyStatus\": %q, \"stormancer.partyStatus.details\": %q}",
			settings.server_status,
			settings.server_status_details,
		)
	} else {
		strings.write_string(sb, "{}")
	}
	fmt.sbprintf(sb, ", %q, %q]", settings.public_data, settings.party_id)
}

write_party_state_member :: proc(sb: ^strings.Builder, member: Party_State_Member) {
	strings.write_byte(sb, '[')
	fmt.sbprintf(sb, "%q, %d, ", member.user_id, member.connection_state)
	write_scene_string(sb, member.userdata_json)
	strings.write_string(sb, ", ")
	write_hex_text(sb, member.session_token_hex)
	strings.write_string(sb, ", ")
	write_scene_platforms(sb, member.platforms)
	fmt.sbprintf(sb, ", %d]", member.state)
}

write_connection_metadata_trailer :: proc(sb: ^strings.Builder, meta: Scene_Connection_Metadata_Trailer) {
	if len(meta.raw) == 0 do return
	strings.write_string(sb, " conn_meta={")
	wrote := false
	write_connection_metadata_field(sb, &wrote, "plugin_suffix", meta.plugin_suffix)
	write_connection_metadata_field(sb, &wrote, "protocol", meta.protocol)
	write_connection_metadata_field(sb, &wrote, "server.name", meta.server_name)
	write_connection_metadata_field(sb, &wrote, "stormancer.partymanagement", meta.party_management)
	write_connection_metadata_field(sb, &wrote, "server.version", meta.server_version)
	write_connection_metadata_field(sb, &wrote, "type", meta.server_type)
	write_connection_metadata_field(sb, &wrote, "serializers", meta.serializers)
	write_connection_metadata_field(sb, &wrote, "platform", meta.platform)
	if len(meta.opaque_connection_data) > 0 {
		if wrote do strings.write_string(sb, ", ")
		fmt.sbprintf(sb, "opaque<%d>", len(meta.opaque_connection_data))
		wrote = true
	}
	strings.write_byte(sb, '}')
}

write_connection_metadata_field :: proc(sb: ^strings.Builder, wrote: ^bool, name, value: string) {
	if len(value) == 0 do return
	if wrote^ do strings.write_string(sb, ", ")
	fmt.sbprintf(sb, "%s=%q", name, value)
	wrote^ = true
}

write_party_connected_member :: proc(sb: ^strings.Builder, member: Scene_Party_Member_Connected) {
	strings.write_byte(sb, '[')
	fmt.sbprintf(sb, "%q, %d, ", member.user_id, member.connection_state)
	write_scene_string(sb, member.userdata_json)
	strings.write_string(sb, ", ")
	write_hex_bytes(sb, member.session_token)
	strings.write_string(sb, ", ")
	write_scene_platforms(sb, member.platforms)
	fmt.sbprintf(sb, ", %d]", member.state)
}

write_quoted_printable_hex :: proc(sb: ^strings.Builder, hex_text: string) {
	bytes := make([dynamic]byte, context.temp_allocator)
	for i := 0; i + 1 < len(hex_text); i += 2 {
		hi, ok_hi := hex_nibble(hex_text[i])
		lo, ok_lo := hex_nibble(hex_text[i + 1])
		if !ok_hi || !ok_lo do break
		append(&bytes, byte(hi << 4 | lo))
	}
	write_quoted_printable_bytes(sb, bytes[:])
}

write_hex_text :: proc(sb: ^strings.Builder, hex_text: string) {
	fmt.sbprintf(sb, "hex<%d> \"", len(hex_text) / 2)
	for ch in hex_text {
		if ch >= 'a' && ch <= 'f' {
			strings.write_byte(sb, byte(ch - 32))
		} else {
			strings.write_byte(sb, byte(ch))
		}
	}
	strings.write_byte(sb, '"')
}

write_quoted_printable_bytes :: proc(sb: ^strings.Builder, data: []byte) {
	fmt.sbprintf(sb, "quoted_printable<%d> ", len(data))
	strings.write_byte(sb, '"')
	for value in data {
		if quoted_printable_literal(value) {
			strings.write_byte(sb, value)
		} else {
			strings.write_byte(sb, '=')
			strings.write_byte(sb, hex_upper(value >> 4))
			strings.write_byte(sb, hex_upper(value & 0x0f))
		}
	}
	strings.write_byte(sb, '"')
}

write_quoted_printable_tail :: proc(sb: ^strings.Builder, data: []byte) {
	if len(data) == 0 do return
	fmt.sbprintf(sb, " tail={{bytes=%d, quoted_printable=", len(data))
	write_quoted_printable_bytes(sb, data)
	strings.write_byte(sb, '}')
}

write_hex_bytes :: proc(sb: ^strings.Builder, data: []byte) {
	fmt.sbprintf(sb, "hex<%d> \"", len(data))
	for value in data {
		strings.write_byte(sb, hex_upper(value >> 4))
		strings.write_byte(sb, hex_upper(value & 0x0f))
	}
	strings.write_byte(sb, '"')
}

quoted_printable_literal :: proc(value: byte) -> bool {
	return value >= 0x21 && value <= 0x7e && value != '='
}

hex_nibble :: proc(value: byte) -> (u8, bool) {
	if value >= '0' && value <= '9' do return u8(value - '0'), true
	if value >= 'a' && value <= 'f' do return u8(value - 'a' + 10), true
	if value >= 'A' && value <= 'F' do return u8(value - 'A' + 10), true
	return 0, false
}

hex_upper :: proc(value: byte) -> byte {
	if value < 10 do return '0' + value
	return 'A' + (value - 10)
}

write_party_member_data_updated_body :: proc(sb: ^strings.Builder, body: Party_MemberDataUpdated_Body) {
	fmt.sbprintf(sb, "rpc=%d [%d, ", body.rpc_id, body.version)
	write_party_member_data(sb, body.member)
	if len(body.tail_values) > 0 {
		strings.write_string(sb, ", tail=")
		write_party_member_data_tail(sb, body.tail_values)
	}
	strings.write_byte(sb, ']')
	write_raw_tail(sb, body.raw_tail)
}

write_party_member_data_tail :: proc(sb: ^strings.Builder, values: []Party_MemberData_Tail_Value) {
	strings.write_byte(sb, '[')
	for i := 0; i < len(values); {
		if i > 0 do strings.write_string(sb, ", ")
		if tail_ascii_run_len(values, i) >= 2 {
			strings.write_string(sb, "codes:")
			write_party_member_data_tail_codes(sb, values, i)
			i += tail_ascii_run_len(values, i)
			continue
		}
		write_party_member_data_tail_value(sb, values[i])
		i += 1
	}
	strings.write_byte(sb, ']')
}

tail_ascii_run_len :: proc(values: []Party_MemberData_Tail_Value, start: int) -> int {
	n := 0
	for i in start ..< len(values) {
		if values[i].kind != .Uint || values[i].uint_value < 32 || values[i].uint_value > 126 do break
		n += 1
	}
	return n
}

write_party_member_data_tail_codes :: proc(sb: ^strings.Builder, values: []Party_MemberData_Tail_Value, start: int) {
	strings.write_byte(sb, '"')
	for i in start ..< len(values) {
		if values[i].kind != .Uint || values[i].uint_value < 32 || values[i].uint_value > 126 do break
		strings.write_byte(sb, byte(values[i].uint_value))
	}
	strings.write_byte(sb, '"')
}

write_party_member_data_tail_value :: proc(sb: ^strings.Builder, value: Party_MemberData_Tail_Value) {
	#partial switch value.kind {
	case .Nil:
		strings.write_string(sb, "nil")
	case .Bool:
		fmt.sbprintf(sb, "%v", value.bool_value)
	case .Int:
		fmt.sbprintf(sb, "%d", value.int_value)
	case .Uint:
		fmt.sbprintf(sb, "%d", value.uint_value)
	case .Str:
		fmt.sbprintf(sb, "%q", value.text)
	case .Bin:
		fmt.sbprintf(sb, "bin<%d>", len(value.bytes))
	case:
		strings.write_string(sb, "nil")
	}
}

write_party_member_data :: proc(sb: ^strings.Builder, member: Scene_Party_Member_Data) {
	strings.write_byte(sb, '[')
	fmt.sbprintf(sb, "%q, ", member.user_id)
	write_scene_string(sb, member.userdata_json)
	strings.write_string(sb, ", ")
	write_scene_platforms(sb, member.platforms)
	fmt.sbprintf(sb, ", %d]", member.state)
}

write_scene_platforms :: proc(sb: ^strings.Builder, platforms: []Scene_Platform_Identity) {
	strings.write_byte(sb, '[')
	for platform, i in platforms {
		if i > 0 do strings.write_string(sb, ", ")
		strings.write_byte(sb, '[')
		fmt.sbprintf(
			sb,
			"%q, %q, %q, %q, ",
			platform.provider,
			platform.user_id,
			platform.visibility,
			platform.platform_id,
		)
		if platform.extra_is_nil do strings.write_string(sb, "nil")
		else do fmt.sbprintf(sb, "%q", platform.extra)
		fmt.sbprintf(sb, ", %d]", platform.flags)
	}
	strings.write_byte(sb, ']')
}

address_to_string :: proc(a: System_Address) -> string {
	// Reuses core:net formatting via a temporary endpoint for a stable a.b.c.d:port.
	ep := net.Endpoint {
		address = net.IP4_Address{a.ip[0], a.ip[1], a.ip[2], a.ip[3]},
		port    = int(a.port),
	}
	return net.endpoint_to_string(ep, context.temp_allocator)
}
