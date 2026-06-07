package caleb_raknet

// Layer 4 (inverse): re-encode a Decoded_Message back into the exact RakNet_Message
// byte array it was decoded from. This is the encoder half of frames.odin's
// decode_message, and the round-trip property
//
//     encode_message(decode_message(bytes)) == bytes
//
// is what verify_roundtrip (main.odin) asserts over a whole capture. Byte-exactness
// is the proof that the decoder dropped nothing: every variant either rebuilds its
// body from the scalars it parsed (fixed-width frames) or carries the original blob
// verbatim (the raw / trailer / internal_list slices added in frames.odin).
//
// No OOP, no methods -- a switch over the same tagged union, writing into a caller-
// owned byte buffer. Output uses `allocator`; the caller owns the returned slice.

import "core:slice"

// Re-encode `message` into its on-the-wire bytes (leading id + body). The result is
// a fresh slice allocated with `allocator`. For variants that retained the original
// payload, the bytes are reproduced exactly; for fixed-layout frames they are
// rebuilt field by field in wire order.
encode_message :: proc(message: Decoded_Message, allocator := context.allocator) -> []byte {
	b := make([dynamic]byte, allocator)

	switch f in message {
	case Connected_Ping:
		append(&b, u8(Message_Id.Connected_Ping))
		write_u64_be(&b, f.clock)

	case Connected_Pong:
		append(&b, u8(Message_Id.Connected_Pong))
		write_u64_be(&b, f.echo_clock)
		write_u64_be(&b, f.clock)

	case Connection_Request:
		append(&b, u8(Message_Id.Connection_Request))
		write_u64_be(&b, f.guid)
		write_u64_be(&b, f.time)
		// guid+time are the first 16 body bytes; `trailer` is everything after them
		// (the security byte and any padding) kept verbatim so a present-but-zero
		// security byte round-trips distinctly from an absent one.
		append(&b, ..f.trailer)

	case Connection_Request_Accepted:
		append(&b, u8(Message_Id.Connection_Request_Accepted))
		encode_system_address(&b, f.remote)
		write_u16_be(&b, f.system_index)
		for k in 0 ..< MAX_INTERNAL_IDS {
			encode_system_address(&b, f.internal[k])
		}
		write_u64_be(&b, f.echo_time)
		write_u64_be(&b, f.server_time)

	case New_Incoming_Connection:
		append(&b, u8(Message_Id.New_Incoming_Connection))
		encode_system_address(&b, f.server)
		// The internal-address list has a non-fixed stride (IPv4/IPv6), so it was kept
		// as an opaque span rather than parsed -- write it back unchanged.
		append(&b, ..f.internal_list)
		write_u64_be(&b, f.ping_time)
		write_u64_be(&b, f.pong_time)

	case Disconnection_Notification:
		append(&b, u8(Message_Id.Disconnection_Notification))

	case System_Request:
		append(&b, u8(Message_Id.System_Request))
		append(&b, u8(f.msg_id))
		write_u16_le(&b, f.req_id)
		// The typed `args` normalizes map order and cannot reproduce the original
		// msgpack bytes; `raw_args` is that original args blob, written verbatim.
		append(&b, ..f.raw_args)

	case Response_Msg:
		append(&b, u8(Message_Id.Response_Msg))
		write_u16_le(&b, f.req_id)
		// `data` is a typed view; `raw` is the undecoded payload after req_id.
		append(&b, ..f.raw)

	case Response_Complete:
		append(&b, u8(Message_Id.Response_Complete))
		write_u16_le(&b, f.req_id)
		append(&b, f.has_values ? 1 : 0)

	case Response_Error:
		append(&b, u8(Message_Id.Response_Error))
		write_u16_le(&b, f.req_id)
		// decode_msgpack_field aliased the body after req_id into data.raw.
		append(&b, ..f.data.raw)

	case Connection_Result:
		append(&b, u8(Message_Id.Connection_Result))
		write_u64_le(&b, f.connection_id)

	case Scene_Message:
		// scene_handle is itself the leading id byte (>= SCENE_HANDLE_MIN).
		append(&b, f.scene_handle)
		write_u16_le(&b, f.route_handle)
		append(&b, ..encode_scene_message_body(f.body, f.raw_body, allocator))

	case Malformed_Message:
		// Could not be parsed; `raw` is the full original message (id included).
		append(&b, ..f.raw)

	case Unknown_Message:
		append(&b, f.id)
		append(&b, ..f.body)
	}

	return b[:]
}

encode_scene_message_body :: proc(
	body: Scene_Message_Body,
	fallback_raw_body: []byte,
	allocator := context.allocator,
) -> []byte {
	#partial switch b in body {
	case Scene_Raw_Body:
		return b.raw
	case Stormancer_Rpc_Completed_Body:
		out := make([dynamic]byte, allocator)
		append(&out, b.message_sent ? 1 : 0)
		write_u16_le(&out, b.rpc_id)
		return out[:]
	case Stormancer_Rpc_Next_Body:
		return encode_stormancer_rpc_next_body(b, allocator)
	case Friends_Notification_Body:
		if len(b.friends) > 0 do return encode_friends_notification_body(b, allocator)
	}
	return fallback_raw_body
}

encode_stormancer_rpc_next_body :: proc(
	body: Stormancer_Rpc_Next_Body,
	allocator := context.allocator,
) -> []byte {
	out := make([dynamic]byte, allocator)
	write_u16_le(&out, body.rpc_id)
	#partial switch body.kind {
	case .Scene_Connection_Token:
		append(&out, ..mpe_str(body.token_json, allocator))
	case .Authentication_Login_Result:
		result := body.result_is_nil ? mpe_nil(allocator) : mpe_bool(false, allocator)
		identities := mpe_byte(MP_EMPTY_MAP, allocator)
		if len(body.steam_identity) > 0 {
			identities = mpe_map({mpe_str("steam", allocator), mpe_str(body.steam_identity, allocator)}, allocator)
		}
		append(
			&out,
			..mpe_array(
				{
					result,
					mpe_bool(body.success, allocator),
					mpe_str(body.user_id, allocator),
					mpe_str(body.error_message, allocator),
					identities,
					mpe_byte(MP_EMPTY_MAP, allocator),
				},
				allocator,
			),
		)
	case:
	}
	return out[:]
}

// True when `encode_message(decode_message(original))` reproduces `original`
// byte-for-byte. The decode uses `allocator` for its scratch trees; the re-encode
// allocates its output there too.
message_roundtrips :: proc(original: []byte, allocator := context.allocator) -> bool {
	decoded := decode_message(original, allocator)
	encoded := encode_message(decoded, allocator)
	return slice.equal(encoded, original)
}

// --- wire writers (inverses of the read_* helpers in frames.odin/messages.odin) --

write_u16_le :: proc(b: ^[dynamic]byte, v: u16) {
	append(b, u8(v), u8(v >> 8))
}

write_u16_be :: proc(b: ^[dynamic]byte, v: u16) {
	append(b, u8(v >> 8), u8(v))
}

write_u64_be :: proc(b: ^[dynamic]byte, v: u64) {
	append(
		b,
		u8(v >> 56),
		u8(v >> 48),
		u8(v >> 40),
		u8(v >> 32),
		u8(v >> 24),
		u8(v >> 16),
		u8(v >> 8),
		u8(v),
	)
}

write_u64_le :: proc(b: ^[dynamic]byte, v: u64) {
	append(
		b,
		u8(v),
		u8(v >> 8),
		u8(v >> 16),
		u8(v >> 24),
		u8(v >> 32),
		u8(v >> 40),
		u8(v >> 48),
		u8(v >> 56),
	)
}

// Inverse of decode_system_address: version(1) + one's-complemented IPv4(4) +
// port(2 BE). The octets are complemented on the wire, so re-complement on write.
encode_system_address :: proc(b: ^[dynamic]byte, a: System_Address) {
	append(b, a.version)
	append(b, ~a.ip[0], ~a.ip[1], ~a.ip[2], ~a.ip[3])
	write_u16_be(b, a.port)
}
