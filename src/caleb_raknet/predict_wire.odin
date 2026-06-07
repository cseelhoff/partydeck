package caleb_raknet

// Outgoing RakNet wire codec for the predictor (predict.py §B port). The decoder
// side (parse_internal_packets in messages.odin) already turns a datagram into
// RakNet_Internal_Packets; this file is the inverse the broker needs to *emit*
// datagrams: it frames a payload into an encapsulated message, wraps messages in a
// data datagram, and builds bare ACKs. Constants mirror predict.py's id/reliability
// tables so the predicted bytes line up with the real server's.

// RakNet offline-message magic (16 bytes). Present at [1:17] of every handshake
// (offline) datagram; its absence is how predict() tells offline from connected.
MAGIC :: [16]byte {
	0x00, 0xFF, 0xFF, 0x00, 0xFE, 0xFE, 0xFE, 0xFE,
	0xFD, 0xFD, 0xFD, 0xFD, 0x12, 0x34, 0x56, 0x78,
}

// Offline (handshake) datagram ids.
ID_UNCONNECTED_PING :: 0x01
ID_UNCONNECTED_PING_OPEN_CONN :: 0x02
ID_UNCONNECTED_PONG :: 0x1C
ID_OPEN_CONNECTION_REQUEST_1 :: 0x05
ID_OPEN_CONNECTION_REPLY_1 :: 0x06
ID_OPEN_CONNECTION_REQUEST_2 :: 0x07
ID_OPEN_CONNECTION_REPLY_2 :: 0x08

// System-request msgIds (the byte after ID_SYSTEM_REQUEST / 0x86).
SR_SET_METADATA :: 0
SR_PING :: 2
SR_GET_SESSION_TOKEN :: 14
SR_SCENE_READY2 :: 16
SR_CONNECT_TO_SCENE :: 134
SR_DISCONNECT_FROM_SCENE :: 135
SR_GET_SCENE_INFOS :: 136

SERVER_PORT :: 30100
DYN_HANDLE_BASE :: 160
SCENE_ID_BASE :: "scene:/passtech-live/darktales/live-1-05-00/"

// A split (fragmented) message descriptor: fragment `index` of `count`, all
// sharing `id`. predict.py passes split=None for unfragmented messages.
Split_Info :: struct {
	count: u32,
	id:    u16,
	index: u32,
}

write_u24_le :: proc(b: ^[dynamic]byte, v: u32) {
	append(b, u8(v), u8(v >> 8), u8(v >> 16))
}

write_u32_be :: proc(b: ^[dynamic]byte, v: u32) {
	append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
}

// Build a RakNet SystemAddress from dotted-quad octets + port (predict.py
// _encode_address). version is always 4 (IPv4); octets are one's-complemented on
// the wire by encode_system_address.
encode_address :: proc(ip: [4]u8, port: u16) -> System_Address {
	return System_Address{version = 4, ip = ip, port = port}
}

// UNASSIGNED padding address (0.0.0.0:0). On the wire its octets complement to
// 0xFF -- the value used to fill the 32-slot internal-address array.
UNASSIGNED_ADDR :: System_Address{version = 4, ip = {0, 0, 0, 0}, port = 0}

// Frame `payload` into one encapsulated RakNet message (predict.py _make_message).
// Header order: flags, payload bit-length (u16 BE), then a reliable number (u24 LE)
// for any RELIABLE* class, then an ordering index (u24 LE) + channel for the
// ordered/sequenced classes, then the split header (count u32 BE, id u16 BE, index
// u32 BE) when fragmented, then the payload.
make_message :: proc(
	reliability: Reliability,
	payload: []byte,
	reliable_num: u32 = 0,
	ordering_index: u32 = 0,
	ordering_channel: u8 = 0,
	split: Maybe(Split_Info) = nil,
	allocator := context.allocator,
) -> []byte {
	out := make([dynamic]byte, allocator)
	flags := u8(reliability) << 5
	if split != nil do flags |= 0x10
	append(&out, flags)
	write_u16_be(&out, u16(len(payload) * 8))

	#partial switch reliability {
	case .Reliable, .Reliable_Ordered, .Reliable_Sequenced:
		write_u24_le(&out, reliable_num)
	}
	#partial switch reliability {
	case .Unreliable_Sequenced, .Reliable_Sequenced, .Reliable_Ordered:
		write_u24_le(&out, ordering_index)
		append(&out, ordering_channel)
	}
	if s, ok := split.?; ok {
		write_u32_be(&out, s.count)
		write_u16_be(&out, s.id)
		write_u32_be(&out, s.index)
	}
	append(&out, ..payload)
	return out[:]
}

// Wrap one framed message in a data datagram (flags 0x80 + u24 LE sequence
// number). predict.py _make_data_datagram.
make_data_datagram :: proc(seq: u32, message: []byte, allocator := context.allocator) -> []byte {
	out := make([dynamic]byte, allocator)
	append(&out, 0x80)
	write_u24_le(&out, seq)
	append(&out, ..message)
	return out[:]
}

// Build a bare ACK datagram for one sequence number (predict.py _make_ack):
// 0xC0 + range-count(1, u16 BE) + max-equals-min flag(1) + seq(u24 LE).
make_ack :: proc(seq: u32, allocator := context.allocator) -> []byte {
	out := make([dynamic]byte, allocator)
	append(&out, 0xC0)
	write_u16_be(&out, 1)
	append(&out, 1)
	write_u24_le(&out, seq)
	return out[:]
}
