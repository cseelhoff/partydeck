package caleb_raknet

// The predictor: predict() takes one client->server datagram and the broker world
// and returns the server->client datagrams the real backend would emit (predict.py
// §J/§K/§L/§M foundation subset). Only the handshake, the connected-layer control
// frames, and the three simplest system-requests (session-token, ping,
// set-metadata) are modelled here; scene-connect and the party/gamesession RPCs
// arrive in a later phase together with the scenes/stoken data port.

// --- §L offline handshake ----------------------------------------------------

on_ocr1 :: proc(w: ^World, conn: ^Conn, data: []byte) {
	mtu := min(len(data) + 28, 1492)
	out := make([dynamic]byte, context.allocator)
	append(&out, ID_OPEN_CONNECTION_REPLY_1)
	m := MAGIC; append(&out, ..m[:])
	write_u64_be(&out, w.server_guid)
	append(&out, 0)
	write_u16_be(&out, u16(mtu))
	out_dg(w, conn.addr, out[:])
}

on_ocr2 :: proc(w: ^World, conn: ^Conn, data: []byte) {
	off := 1 + 16 + 7 // id + magic + server SystemAddress
	mtu := read_u16_be(data, off)
	out := make([dynamic]byte, context.allocator)
	append(&out, ID_OPEN_CONNECTION_REPLY_2)
	m := MAGIC; append(&out, ..m[:])
	write_u64_be(&out, w.server_guid)
	encode_system_address(&out, encode_address(conn.addr.ip, conn.addr.port))
	write_u16_be(&out, mtu)
	append(&out, 0)
	out_dg(w, conn.addr, out[:])
}

// --- §K online (connected-layer) control frames ------------------------------

online_connection_request :: proc(w: ^World, conn: ^Conn, payload: []byte) {
	if !conn.accepted_valid {
		body := make([dynamic]byte, context.allocator)
		append(&body, u8(Message_Id.Connection_Request_Accepted))
		encode_system_address(&body, encode_address(conn.addr.ip, conn.addr.port))
		write_u16_be(&body, 0)
		encode_system_address(&body, encode_address({127, 0, 0, 1}, SERVER_PORT))
		for _ in 0 ..< MAX_INTERNAL_IDS - 1 {
			encode_system_address(&body, UNASSIGNED_ADDR)
		}
		// echoedClientTime = the client's RakNetTime from the request (payload[9:17]).
		if len(payload) >= 17 {
			append(&body, ..payload[9:17])
		} else {
			for _ in 0 ..< 8 do append(&body, 0)
		}
		write_u64_be(&body, server_clock_ms(w))
		msg := make_message(
			.Reliable_Ordered, body[:],
			reliable_num = conn.next_reliable,
			ordering_index = alloc_ordering(conn, 0),
			ordering_channel = 0,
		)
		conn.next_reliable += 1
		conn.accepted_bytes = make_data_datagram(conn.next_datagram, msg)
		conn.accepted_valid = true
		conn.next_datagram += 1
	}
	out_dg(w, conn.addr, conn.accepted_bytes)
}

online_new_incoming :: proc(w: ^World, conn: ^Conn, payload: []byte) {
	conn.established = true
	if !conn.server_ping_sent {
		conn.server_ping_sent = true
		ping := make([dynamic]byte, context.allocator)
		append(&ping, u8(Message_Id.Connected_Ping))
		write_u64_be(&ping, server_clock_ms(w))
		send_unreliable(w, conn, ping[:])
	}
}

online_connected_ping :: proc(w: ^World, conn: ^Conn, payload: []byte) {
	pong := make([dynamic]byte, context.allocator)
	append(&pong, u8(Message_Id.Connected_Pong))
	if len(payload) >= 9 {
		append(&pong, ..payload[1:9])
	} else {
		for _ in 0 ..< 8 do append(&pong, 0)
	}
	write_u64_be(&pong, server_clock_ms(w))
	send_unreliable(w, conn, pong[:])
}

online_connected_pong :: proc(w: ^World, conn: ^Conn, payload: []byte) {
	if conn.established && !conn.conn_result_sent {
		conn.conn_result_sent = true
		res := make([dynamic]byte, context.allocator)
		append(&res, u8(Message_Id.Connection_Result))
		write_u64_le(&res, conn.connection_id)
		send_reliable(w, conn, res[:])
	}
}

// --- §J system requests ------------------------------------------------------

sr_session_token :: proc(w: ^World, conn: ^Conn, req_id: u16, data: []byte) {
	token, sid := make_session_jwt(w)
	payload := mpe_concat(mpe_str(token), mpe_str(sid))
	send_response_msg(w, conn, req_id, payload)
	send_response_complete(w, conn, req_id, has_values = true)
}

sr_ping :: proc(w: ^World, conn: ^Conn, req_id: u16, data: []byte) {
	ref := make([dynamic]byte, context.allocator)
	write_u64_le(&ref, server_clock_ms(w))
	if len(data) >= 8 {
		append(&ref, ..data[:8])
	} else {
		for _ in 0 ..< 8 do append(&ref, 0)
	}
	send_response_msg(w, conn, req_id, ref[:])
	send_response_complete(w, conn, req_id, has_values = true)
}

sr_set_metadata :: proc(w: ^World, conn: ^Conn, req_id: u16, data: []byte) {
	send_response_complete(w, conn, req_id, has_values = false)
}

on_system_request :: proc(w: ^World, conn: ^Conn, payload: []byte) {
	if len(payload) < 4 do return
	msg_id := int(payload[1])
	req_id := read_u16_le(payload, 2)
	data := payload[4:]
	switch msg_id {
	case SR_GET_SESSION_TOKEN:
		sr_session_token(w, conn, req_id, data)
	case SR_PING:
		sr_ping(w, conn, req_id, data)
	case SR_SET_METADATA:
		sr_set_metadata(w, conn, req_id, data)
	case:
		// connect-to-scene / scene-infos / scene-ready2 / disconnect are not yet
		// modelled; reply with the same explicit error the Python probe sends.
		send_response_error(w, conn, req_id, "system request not implemented by offline probe")
	}
}

// --- connected-datagram dispatch ---------------------------------------------

on_connected :: proc(w: ^World, conn: ^Conn, data: []byte) {
	if len(data) == 0 do return
	flags := data[0]
	if flags & 0x80 == 0 do return // offline
	if flags & 0x60 != 0 do return // ACK (0x40) or NAK (0x20)
	seq := read_u24_le(data, 1)
	out_dg(w, conn.addr, make_ack(seq)) // harness drops bare ACKs from the record

	packets: [MAX_INTERNAL_PACKETS]RakNet_Internal_Packet
	n := parse_internal_packets(data, packets[:])
	for i in 0 ..< n {
		payload := packets[i].payload
		if len(payload) == 0 do continue
		mid := payload[0]
		switch mid {
		case u8(Message_Id.Connection_Request):
			online_connection_request(w, conn, payload)
		case u8(Message_Id.New_Incoming_Connection):
			online_new_incoming(w, conn, payload)
		case u8(Message_Id.Connected_Ping):
			online_connected_ping(w, conn, payload)
		case u8(Message_Id.Connected_Pong):
			online_connected_pong(w, conn, payload)
		case u8(Message_Id.System_Request):
			on_system_request(w, conn, payload)
		case:
		// scene messages and other transport ids are not modelled in the
		// foundation; ignored so they neither crash nor emit spurious replies.
		}
	}
}

// --- §M entry ----------------------------------------------------------------

// Process one client->server datagram against `world`; return the server->client
// datagrams the broker would emit (predict.py predict). The caller splits the
// result into own-peer and cross-peer replies by destination address.
predict :: proc(world: ^World, caddr: Peer_Addr, datagram: []byte) -> []Out_Dg {
	clear(&world.outbox)
	if len(datagram) == 0 do return world.outbox[:]
	idx := conn_index(world, caddr)
	conn := &world.conns[idx]

	mid := datagram[0]
	m := MAGIC
	is_off := len(datagram) >= 17 && bytes_equal(datagram[1:17], m[:])
	switch {
	case mid == ID_OPEN_CONNECTION_REQUEST_1 && is_off:
		on_ocr1(world, conn, datagram)
	case mid == ID_OPEN_CONNECTION_REQUEST_2 && is_off:
		on_ocr2(world, conn, datagram)
	case (mid == ID_UNCONNECTED_PING || mid == ID_UNCONNECTED_PING_OPEN_CONN) && is_off:
	// unconnected pings carry no content; the real server's reply is not modelled
	case:
		on_connected(world, conn, datagram)
	}
	return world.outbox[:]
}
