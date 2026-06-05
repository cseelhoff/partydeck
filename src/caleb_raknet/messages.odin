package caleb_raknet

// Layer 3: turn raw datagrams into atomic application messages.
//
// process_udp_datagram unframes one stored datagram (RFC 768 UDP datagram) into
// its RakNet internal packets, drops ACK/NAK and offline datagrams, reassembles
// split-packet fragments by splitPacketId, and appends each complete message to a
// RakNet_Message_Store. No OOP, no methods -- just data structs and free functions.

import "core:fmt"
import "core:net"
import "core:strings"
import "core:time"

MAX_INTERNAL_PACKETS :: 512   // internal packets unframed from one datagram
MAX_SPLITS       :: 64    // concurrent in-flight fragmented messages
MAX_FRAGMENTS    :: 1024  // max fragments in one split packet

// RakNet PacketReliability (raknet.py: UNRELIABLE..RELIABLE_SEQUENCED).
Reliability :: enum u8 {
	Unreliable           = 0,
	Unreliable_Sequenced = 1,
	Reliable             = 2,
	Reliable_Ordered     = 3,
	Reliable_Sequenced   = 4,
}

// One encapsulated message unframed from a data datagram -- RakNet's
// "InternalPacket". When has_split is set it is fragment split_index of
// split_count total, belonging to the split packet identified by split_id.
RakNet_Internal_Packet :: struct {
	reliability:             Reliability,
	reliable_message_number: u32,
	has_split:               bool,
	split_count:             u32,
	split_id:                u16,
	split_index:             u32,
	payload:                 []byte, // slice into the datagram store's pool
}

// Struct-of-Arrays store of reassembled application messages: complete RakNet
// messages after ACK/NAK filtering and fragment reassembly. n_fragments records
// how many datagram fragments were combined (1 for an unfragmented message).
RakNet_Message_Store :: struct {
	froms:         [MAX_RAKNET_MESSAGES]net.Endpoint,
	recv_times:    [MAX_RAKNET_MESSAGES]time.Time,
	reliabilities: [MAX_RAKNET_MESSAGES]Reliability,
	n_fragments:   [MAX_RAKNET_MESSAGES]int,
	starts:        [MAX_RAKNET_MESSAGES]int,
	lengths:       [MAX_RAKNET_MESSAGES]int,
	count:         int,
	pool:          [BYTE_POOL_SIZE]byte,
}

// Process one stored datagram: drop ACK/NAK and offline datagrams, unframe the
// rest into internal packets, reassemble split fragments via `reasm`, and
// append every complete application message to `msgs`.
process_udp_datagram :: proc(dgrams: ^UDP_Datagram_Store, msgs: ^RakNet_Message_Store, reasm: ^Reassembly, i: int) {
	datagram_bytes := udp_datagram_bytes(dgrams, i)
	if len(datagram_bytes) == 0 do return
	flags := datagram_bytes[0]
	if flags & 0xC0 == 0xC0 do return // ACK / NAK
	if flags & 0x80 == 0 do return    // offline / handshake datagram

	from := dgrams.froms[i]
	recv_time := dgrams.recv_times[i]

	raknet_packets: [MAX_INTERNAL_PACKETS]RakNet_Internal_Packet
	raknet_packets_count := parse_internal_packets(datagram_bytes, raknet_packets[:])
	for packet_index in 0 ..< raknet_packets_count {
		raknet_packet := raknet_packets[packet_index]
		if len(raknet_packet.payload) == 0 do continue
		if !raknet_packet.has_split {
			raknet_message_push(msgs, from, recv_time, raknet_packet.reliability, 1, raknet_packet.payload)
			continue
		}
		if raknet_packet.split_count == 0 || raknet_packet.split_count > MAX_FRAGMENTS do continue
		if raknet_packet.split_index >= raknet_packet.split_count do continue

		split_buffer := split_find(reasm, from, raknet_packet.split_id)
		if split_buffer == nil do continue // all slots busy; drop fragment
		if !split_buffer.active {
			split_buffer.active = true
			split_buffer.from = from
			split_buffer.id = raknet_packet.split_id
			split_buffer.count = raknet_packet.split_count
			split_buffer.have = 0
			split_buffer.frags = {}
		}
		idx := int(raknet_packet.split_index)
		if split_buffer.frags[idx] == nil {
			split_buffer.frags[idx] = raknet_packet.payload
			split_buffer.have += 1
		}
		if split_buffer.have < split_buffer.count do continue

		reassemble_and_push(msgs, split_buffer, from, recv_time, raknet_packet.reliability)
		split_buffer.active = false
	}
}

udp_datagram_bytes :: proc(s: ^UDP_Datagram_Store, i: int) -> []byte {
	return s.pool[s.starts[i]:][:s.lengths[i]]
}

// Unframe a data datagram (header already validated by process_udp_datagram) into
// its internal packets, filling out[] and returning how many were parsed.
// Mirrors raknet.py parse_messages_ex: stop on any bounds/format failure and
// return what was decoded so far.
parse_internal_packets :: proc(datagram_bytes: []byte, raknet_packets: []RakNet_Internal_Packet) -> int {
	datagram_bytes_count := len(datagram_bytes)
	header_offset := 4 // past flags(1) + uint24 LE sequence number(3)
	raknet_packets_count := 0
	for header_offset < datagram_bytes_count && raknet_packets_count < len(raknet_packets) {
		flags_byte := datagram_bytes[header_offset]; header_offset += 1
		reliability := Reliability((flags_byte >> 5) & 0x7)
		has_split := (flags_byte >> 4) & 0x1 != 0
		if u8(reliability) >= 8 || header_offset + 2 > datagram_bytes_count do break
		data_bits := int(read_u16_be(datagram_bytes, header_offset)); header_offset += 2
		if data_bits == 0 do break

		is_reliable := reliability == .Reliable || reliability == .Reliable_Ordered || reliability == .Reliable_Sequenced
		is_sequenced := reliability == .Unreliable_Sequenced || reliability == .Reliable_Sequenced
		is_ordered := is_sequenced || reliability == .Reliable_Ordered

		raknet_packet: RakNet_Internal_Packet
		raknet_packet.reliability = reliability
		raknet_packet.has_split = has_split

		if is_reliable {
			if header_offset + 3 > datagram_bytes_count do break
			raknet_packet.reliable_message_number = read_u24_le(datagram_bytes, header_offset); header_offset += 3
		}
		if is_sequenced {
			if header_offset + 3 > datagram_bytes_count do break
			header_offset += 3 // sequencingIndex (unused this layer)
		}
		if is_ordered {
			if header_offset + 4 > datagram_bytes_count do break
			header_offset += 4 // orderingIndex(3) + orderingChannel(1)
		}
		if has_split {
			if header_offset + 10 > datagram_bytes_count do break
			raknet_packet.split_count = read_u32_be(datagram_bytes, header_offset)
			raknet_packet.split_id = read_u16_be(datagram_bytes, header_offset + 4)
			raknet_packet.split_index = read_u32_be(datagram_bytes, header_offset + 6)
			header_offset += 10
		}
		nbytes := (data_bits + 7) / 8
		if header_offset + nbytes > datagram_bytes_count do break
		raknet_packet.payload = datagram_bytes[header_offset:][:nbytes]; header_offset += nbytes

		raknet_packets[raknet_packets_count] = raknet_packet
		raknet_packets_count += 1
	}
	return raknet_packets_count
}

read_u16_be :: proc(b: []byte, off: int) -> u16 {
	return u16(b[off]) << 8 | u16(b[off + 1])
}

read_u24_le :: proc(b: []byte, off: int) -> u32 {
	return u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16
}

read_u32_be :: proc(b: []byte, off: int) -> u32 {
	return u32(b[off]) << 24 | u32(b[off + 1]) << 16 | u32(b[off + 2]) << 8 | u32(b[off + 3])
}

// Find the in-flight split buffer for (from, id), or the first free slot to start
// a new one. Returns nil when all slots are busy.
split_find :: proc(r: ^Reassembly, from: net.Endpoint, id: u16) -> ^Split_Buffer {
	free_slot: ^Split_Buffer
	for &s in r.splits {
		if s.active && s.id == id && s.from == from do return &s
		if !s.active && free_slot == nil do free_slot = &s
	}
	return free_slot
}

// Concatenate a completed split packet's fragments in index order straight into
// the message store's pool, then record one message spanning them.
reassemble_and_push :: proc(msgs: ^RakNet_Message_Store, sb: ^Split_Buffer, from: net.Endpoint, recv_time: time.Time, reliability: Reliability) -> bool {
	total := 0
	for k in 0 ..< int(sb.count) {
		total += len(sb.frags[k])
	}
	if msgs.count >= MAX_RAKNET_MESSAGES do return false
	start := pool_end(msgs.starts[:], msgs.lengths[:], msgs.count)
	if start + total > BYTE_POOL_SIZE do return false

	i := msgs.count
	off := start
	for k in 0 ..< int(sb.count) {
		f := sb.frags[k]
		copy(msgs.pool[off:][:len(f)], f)
		off += len(f)
	}
	msgs.froms[i] = from
	msgs.recv_times[i] = recv_time
	msgs.reliabilities[i] = reliability
	msgs.n_fragments[i] = int(sb.count)
	msgs.starts[i] = start
	msgs.lengths[i] = total
	msgs.count = i + 1
	return true
}

raknet_message_push :: proc(s: ^RakNet_Message_Store, from: net.Endpoint, recv_time: time.Time, reliability: Reliability, n_fragments: int, data: []byte) -> bool {
	if s.count >= MAX_RAKNET_MESSAGES do return false
	start := pool_end(s.starts[:], s.lengths[:], s.count)
	if start + len(data) > BYTE_POOL_SIZE do return false
	i := s.count
	copy(s.pool[start:][:len(data)], data)
	s.froms[i] = from
	s.recv_times[i] = recv_time
	s.reliabilities[i] = reliability
	s.n_fragments[i] = n_fragments
	s.starts[i] = start
	s.lengths[i] = len(data)
	s.count = i + 1
	return true
}

raknet_message_bytes :: proc(s: ^RakNet_Message_Store, i: int) -> []byte {
	return s.pool[s.starts[i]:][:s.lengths[i]]
}

// Dump every reassembled message in the store: sender, receive time, reliability,
// fragment count, byte length, and the Decoded_Message.
print_all_messages :: proc(s: ^RakNet_Message_Store) {
	fmt.printfln("=== %d RakNet messages ===", s.count)
	// Route names are learned across the stream (route_table.odin), so the registry
	// persists for the whole loop -- allocated outside temp, which is reset per message.
	reg: Route_Registry
	route_registry_init(&reg)
	defer route_registry_destroy(&reg)
	// One line buffer reused for every message; reset (not freed) each iteration so
	// no per-message summary string is allocated.
	line := strings.builder_make()
	defer strings.builder_destroy(&line)
	for i in 0 ..< s.count {
		payload := raknet_message_bytes(s, i)
		// Per-message scratch: the decoded msgpack trees and address strings live in
		// temp and are reclaimed after the line prints.
		decoded := decode_message(payload, context.temp_allocator)
		from := s.froms[i]
		route_registry_observe(&reg, from, decoded)
		route_name := ""
		if sm, ok := decoded.(Scene_Message); ok {
			route_name = route_registry_resolve(&reg, from, sm.scene_handle, sm.route_handle)
		}
		strings.builder_reset(&line)
		// fmt.sbprintf(
		// 	&line,
		// 	"[%d] from=%v recv=%v reliability=%v fragments=%d len=%d -> ",
		// 	i,
		// 	s.froms[i],
		// 	s.recv_times[i],
		// 	s.reliabilities[i],
		// 	s.n_fragments[i],
		// 	s.lengths[i],
		// )
		write_decoded_message(&line, decoded, route_name)
		fmt.println(strings.to_string(line))
		free_all(context.temp_allocator)
	}
}
