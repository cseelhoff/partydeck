package caleb_raknet

// caleb_raknet — a standalone, data-oriented clean-room of sync-raknet.py.
//
// Layer 1: bind a UDP socket and listen. Every received UDP datagram is appended
// to a struct-of-arrays UDP_Datagram_Store: its metadata goes into parallel arrays
// indexed by datagram number, and its bytes are copied into one shared pool.
//
// Layer 2: on startup open a caleb-raknet-<timestamp>.jsonl file and append one
// JSON object per UDP datagram as it is stored.
//
// Layer 3 (messages.odin): turn raw datagrams into atomic application messages --
// unframing, ACK/NAK filtering and split-packet reassembly into a RakNet_Message_Store.
//
// Replay: passing a .jsonl capture path as a command-line argument ingests that
// recorded stream into the same stores instead of listening on the socket.

import "core:fmt"
import "core:net"
import "core:os"
import "core:mem"
import "core:time"
import "core:strings"
import "core:encoding/hex"
import "core:encoding/json"

LISTEN_HOST :: "0.0.0.0"
LISTEN_PORT :: 30100          // matches raknet.py HOST/PORT
MAX_UDP_SIZE :: 65535         // largest a single UDP datagram can be
MAX_UDP_DATAGRAMS :: 4096     // capacity of one UDP_Datagram_Store
MAX_RAKNET_MESSAGES :: 4096   // capacity of one RakNet_Message_Store
BYTE_POOL_SIZE :: 4 * 1024 * 1024

Error :: union #shared_nil {
	net.Network_Error,
	os.Error,
}

UDP_Datagram_Store :: struct {
	froms:      [MAX_UDP_DATAGRAMS]net.Endpoint, // sender address + port
	recv_times: [MAX_UDP_DATAGRAMS]time.Time,    // when each datagram was received
	starts:     [MAX_UDP_DATAGRAMS]int,          // byte offset of datagram i in pool
	lengths:    [MAX_UDP_DATAGRAMS]int,          // byte length of datagram i
	count:      int,                             // number of datagrams stored
	pool:       [BYTE_POOL_SIZE]byte,            // all datagram bytes, back to back
}

Jsonl_Record :: struct {
	t:    string, // rfc3339 receive time
	from: string, // sender "ip:port"
	len:  int,    // datagram byte length
	hex:  string, // datagram bytes, hex-encoded
}

// One in-flight fragmented message, collected by split_id until all `count`
// fragments arrive, then concatenated in index order. Fragment payloads are
// slices into the datagram store's append-only pool, which stays stable, so no
// copy happens until the message is complete.
Split_Buffer :: struct {
	active: bool,
	from:   net.Endpoint,
	id:     u16,
	count:  u32,
	have:   u32,
	frags:  [MAX_FRAGMENTS][]byte,
}

Reassembly :: struct {
	splits: [MAX_SPLITS]Split_Buffer,
}

main :: proc() {
	datagrams := new(UDP_Datagram_Store)
	defer free(datagrams)
	msgs := new(RakNet_Message_Store)
	defer free(msgs)
	reasm := new(Reassembly)
	defer free(reasm)

	args := os.args
	err: Error
	if len(args) > 2 && args[1] == "sync" {
		err = sync_replay(args[2])
	} else if len(args) > 2 && args[1] == "predict-caleb" {
		err = predict_caleb(datagrams, msgs, reasm, args[2])
	} else if len(args) > 1 {
		err = replay(datagrams, msgs, reasm, args[1])
	} else {
		err = net_listen(datagrams, msgs, reasm)
	}
	if err != nil {
		fmt.eprintfln("caleb_raknet exited with error -> %v", err)
	}
}

net_listen :: proc(dgrams: ^UDP_Datagram_Store, msgs: ^RakNet_Message_Store, reasm: ^Reassembly) -> Error {
	bind_addr := net.parse_address(LISTEN_HOST)
	sock := net.make_bound_udp_socket(bind_addr, LISTEN_PORT) or_return
	defer net.close(sock)

	log := open_log() or_return
	defer os.close(log)

	scratch_backing := make([]byte, MAX_UDP_SIZE * 4 + 512)
	defer delete(scratch_backing)
	scratch_arena: mem.Arena
	mem.arena_init(&scratch_arena, scratch_backing)
	scratch := mem.arena_allocator(&scratch_arena)

	fmt.printfln("caleb_raknet listening on %s:%d", LISTEN_HOST, LISTEN_PORT)
	buf: [MAX_UDP_SIZE]byte
	for {
		n, remote := net.recv_udp(sock, buf[:]) or_continue
		if n <= 0 do continue
		now := time.now()
		if !udp_datagram_push(dgrams, remote, now, buf[:n]) {
			fmt.eprintfln("datagram store full, dropping %d bytes", n)
			continue
		}
		log_datagram(log, scratch, remote, now, buf[:n])
		process_udp_datagram(dgrams, msgs, reasm, dgrams.count - 1)
		// fmt.printfln("stored %d bytes from %v (datagrams %d, messages %d)", n, remote, dgrams.count, msgs.count)
	}
	return nil
}

open_log :: proc() -> (^os.File, os.Error) {
	stamp_backing: [64]byte
	arena: mem.Arena
	mem.arena_init(&arena, stamp_backing[:])
	stamp, _ := time.time_to_rfc3339(time.now(), include_nanos = false, allocator = mem.arena_allocator(&arena))

	name_backing: [128]byte
	b := strings.builder_from_bytes(name_backing[:])
	fmt.sbprintf(&b, "caleb-raknet-%s.jsonl", stamp)
	return os.open(strings.to_string(b), {.Write, .Create, .Append})
}

udp_datagram_push :: proc(s: ^UDP_Datagram_Store, from: net.Endpoint, recv_time: time.Time, data: []byte) -> bool {
	if s.count >= MAX_UDP_DATAGRAMS do return false
	start := pool_end(s.starts[:], s.lengths[:], s.count)
	if start + len(data) > BYTE_POOL_SIZE do return false
	i := s.count
	copy(s.pool[start:][:len(data)], data)
	s.froms[i] = from
	s.recv_times[i] = recv_time
	s.starts[i] = start
	s.lengths[i] = len(data)
	s.count = i + 1
	return true
}

pool_end :: proc(starts, lengths: []int, count: int) -> int {
	if count == 0 do return 0
	return starts[count - 1] + lengths[count - 1]
}

server_time_ms :: proc() -> u64 {
	tick := time.tick_now()
	return u64(tick._nsec / i64(time.Millisecond))
}

system_address_from_endpoint :: proc(ep: net.Endpoint) -> System_Address {
	#partial switch addr in ep.address {
	case net.IP4_Address:
		return System_Address{version = 4, ip = {addr[0], addr[1], addr[2], addr[3]}, port = u16(ep.port)}
	}
	return UNASSIGNED_ADDR
}

Predict_Caleb_Txn :: struct {
	peer:        ^Peer_State,
	t:           string,
	label:       string,
	sent_msgs:   [dynamic][]byte,
	sent_human:  string,
	reals:       [dynamic][]byte,
	preds:       [dynamic][]byte,
	req_ids:     [dynamic]u16,
	window_open: bool,
}

txn_has_req :: proc(txn: ^Predict_Caleb_Txn, req_id: u16) -> bool {
	for id in txn.req_ids {
		if id == req_id do return true
	}
	return false
}

response_req_id :: proc(msg: []byte, allocator := context.allocator) -> (u16, bool) {
	if len(msg) < 3 do return 0, false
	#partial switch Message_Id(msg[0]) {
	case .Response_Msg, .Response_Complete, .Response_Error:
		return read_u16_le(msg, 1), true
	}
	return 0, false
}

predict_caleb_route_real :: proc(txns: ^[dynamic]Predict_Caleb_Txn, peer: ^Peer_State, msg: []byte, allocator := context.allocator) {
	if req_id, ok := response_req_id(msg, allocator); ok {
		for &txn in txns {
			if txn.peer == peer && txn_has_req(&txn, req_id) {
				append(&txn.reals, msg)
				return
			}
		}
	}

	for i := len(txns^) - 1; i >= 0; i -= 1 {
		txn := &txns^[i]
		if txn.peer == peer && txn.window_open {
			append(&txn.reals, msg)
			return
		}
	}
}

append_response_msg :: proc(preds: ^[dynamic][]byte, req_id: u16, raw: []byte, allocator := context.allocator) {
	msg := make([dynamic]byte, allocator)
	append(&msg, u8(Message_Id.Response_Msg))
	write_u16_le(&msg, req_id)
	append(&msg, ..raw)
	append(preds, msg[:])
}

append_response_complete :: proc(preds: ^[dynamic][]byte, req_id: u16, has_values: bool, allocator := context.allocator) {
	msg := make([dynamic]byte, allocator)
	append(&msg, u8(Message_Id.Response_Complete))
	write_u16_le(&msg, req_id)
	append(&msg, has_values ? 1 : 0)
	append(preds, msg[:])
}

append_ping_response :: proc(preds: ^[dynamic][]byte, req_id: u16, echo_clock: u64, allocator := context.allocator) {
	raw := make([dynamic]byte, allocator)
	write_u64_le(&raw, server_time_ms())
	write_u64_le(&raw, echo_clock)
	append_response_msg(preds, req_id, raw[:], allocator)
	append_response_complete(preds, req_id, true, allocator)
}

append_bool_response :: proc(preds: ^[dynamic][]byte, req_id: u16, value: bool, allocator := context.allocator) {
	raw := mpe_map(
		{
			mpe_str("v", allocator), mpe_bool(value, allocator),
		},
		allocator,
	)
	append_response_msg(preds, req_id, raw, allocator)
	append_response_complete(preds, req_id, true, allocator)
}

build_scene_connection_result_raw :: proc(scene_handle: u64, routes: []Scene_Route, allocator := context.allocator) -> []byte {
	route_pairs := make([dynamic][]byte, allocator)
	for route, i in routes {
		append(&route_pairs, mpe_str(route.name, allocator))
		append(&route_pairs, mpe_uint(u64(i + 1), allocator))
	}

	return mpe_map(
		{
			mpe_str("SceneHandle", allocator), mpe_uint(scene_handle, allocator),
			mpe_str("RouteMappings", allocator), mpe_map(route_pairs[:], allocator),
		},
		allocator,
	)
}

next_connect_scene_handle :: proc(txns: []Predict_Caleb_Txn, peer: ^Peer_State) -> u64 {
	count := 0
	for &txn in txns {
		if txn.peer != peer do continue
		for msg in txn.sent_msgs {
			decoded := decode_message(msg, context.temp_allocator)
			#partial switch decoded in decoded {
			case System_Request:
				if decoded.msg_id == .Connect_To_Scene do count += 1
			}
			free_all(context.temp_allocator)
		}
	}
	return 141 + u64(count)
}

log_datagram :: proc(log: ^os.File, scratch: mem.Allocator, from: net.Endpoint, recv_time: time.Time, bytes: []byte) {
	if log == nil do return
	free_all(scratch)

	rec: Jsonl_Record
	rec.t, _ = time.time_to_rfc3339(recv_time, allocator = scratch)
	rec.from = net.endpoint_to_string(from, scratch)
	rec.len = len(bytes)
	rec.hex = string(hex.encode(bytes, scratch))

	b := strings.builder_make_len_cap(0, MAX_UDP_SIZE * 2 + 256, scratch)
	opt: json.Marshal_Options
	if json.marshal_to_builder(&b, rec, &opt) != nil do return
	strings.write_byte(&b, '\n')

	os.write(log, transmute([]byte)strings.to_string(b))
}

predict_caleb :: proc(datagrams: ^UDP_Datagram_Store, msgs: ^RakNet_Message_Store, reasm: ^Reassembly, path: string) -> Error {
	data := os.read_entire_file_from_path(path, context.allocator) or_return
	defer delete(data)

	out := strings.builder_make()
	defer strings.builder_destroy(&out)

	scratch_backing := make([]byte, BYTE_POOL_SIZE)
	defer delete(scratch_backing)
	scratch_arena: mem.Arena
	mem.arena_init(&scratch_arena, scratch_backing)
	scratch := mem.arena_allocator(&scratch_arena)
	defer free_all(scratch)

	number_of_transactions_to_test := 12
	total_connections: u64 = 0
	peers: [dynamic]^Peer_State
	txns: [dynamic]Predict_Caleb_Txn
	nidx := 1
	out_path := "/tmp/pdlog/probe/predict_caleb.json"
	auth_infos := os.read_entire_file_from_path("src/scenes/authenticator.infos.bin", scratch) or_return

	text := string(data)
	for line_text in strings.split_lines_iterator(&text) {
		if len(line_text) == 0 do continue

		rec: Relay_Record
		if json.unmarshal_string(line_text, &rec, allocator = scratch) != nil do continue

		dg, ok := hex.decode(transmute([]byte)rec.hex, scratch)
		if !ok do continue

		ps := find_peer(&peers, rec.peer, &nidx)

		if rec.dir == "s2c" {
			if is_content_datagram(dg) {
				real_msgs := reassemble_side(ps, .Real, {dg}, scratch)
				for msg in real_msgs {
					predict_caleb_route_real(&txns, ps, msg, scratch)
				}
			}
			continue
		}
		if rec.dir != "c2s" do continue
		if !is_content_datagram(dg) do continue

		sent_msgs := reassemble_side(ps, .C2S, {dg}, scratch)
		if len(sent_msgs) == 0 do continue

		for &txn in txns {
			if txn.peer == ps do txn.window_open = false
		}

		txn: Predict_Caleb_Txn
		txn.peer = ps
		txn.t = rec.t
		txn.label = rec.peer
		txn.window_open = true
		for msg in sent_msgs do append(&ps.sent_msgs, msg)
		for msg in sent_msgs do append(&txn.sent_msgs, msg)
		txn.sent_human = render_burst(&ps.reg_real, ps.ep_client, txn.sent_msgs[:], scratch)
		free_all(context.temp_allocator)

		for msg in sent_msgs {
			decoded := decode_message(msg, scratch)
			#partial switch decoded in decoded {
			case Connection_Request:
				response := Connection_Request_Accepted {
					remote         = system_address_from_endpoint(net.Endpoint{address = net.IP4_Address{ps.addr.ip[0], ps.addr.ip[1], ps.addr.ip[2], ps.addr.ip[3]}, port = int(ps.addr.port)}),
					system_index   = 0,
					internal_count = 1,
					echo_time      = decoded.time,
					server_time    = server_time_ms(),
				}
				response.internal[0] = System_Address{version = 4, ip = {127, 0, 0, 1}, port = LISTEN_PORT}
				append(&txn.preds, encode_message(Decoded_Message(response), scratch))

			case New_Incoming_Connection:
				response := Connected_Ping {
					clock = server_time_ms(),
				}
				append(&txn.preds, encode_message(Decoded_Message(response), scratch))

			case Connected_Ping:
				response := Connected_Pong {
					echo_clock = decoded.clock,
					clock      = server_time_ms(),
				}
				append(&txn.preds, encode_message(Decoded_Message(response), scratch))

			case Connected_Pong:
				total_connections += 1
				response := Connection_Result {
					connection_id = total_connections,
				}
				append(&txn.preds, encode_message(Decoded_Message(response), scratch))

			case System_Request:
				append(&txn.req_ids, decoded.req_id)
				#partial switch decoded.msg_id {
				case System_Request_Id.Get_Session_Token:
					jwt := "eyJhbGciOiJub25lIiwidHlwIjoiSldUIiwiY2x1c3RlcklkIjoicGFzc3RlY2gtbGl2ZSJ9.eyJTdG9ybWFuY2VyL3Nlc3Npb25JZCI6ImJYMkZOMVdhS1Vxb3VCY2JVNTlWbVEiLCJuYmYiOjE3ODA1MzcyMTIsImV4cCI6MTc4MDYyMzYxMiwiaWF0IjoxNzgwNTM3MjEyLCJpc3MiOiJwYXNzdGVjaC1saXZlIn0."
					sid := "bX2FN1WaKUqouBcbU59VmQ"
					raw := mpe_concat(mpe_str(jwt, scratch), mpe_str(sid, scratch), allocator = scratch)
					append_response_msg(&txn.preds, decoded.req_id, raw, scratch)
					append_response_complete(&txn.preds, decoded.req_id, true, scratch)

				case System_Request_Id.Get_Scene_Infos:
					append_response_msg(&txn.preds, decoded.req_id, auth_infos, scratch)
					append_response_complete(&txn.preds, decoded.req_id, true, scratch)

				case System_Request_Id.Ping:
					#partial switch args in decoded.args {
					case Ping_Args:
						append_ping_response(&txn.preds, decoded.req_id, args.clock, scratch)
					}

				case System_Request_Id.Set_Metadata:
					append_response_complete(&txn.preds, decoded.req_id, false, scratch)

				case System_Request_Id.Connect_To_Scene:
					#partial switch args in decoded.args {
					case Connect_To_Scene_Args:
						handle := next_connect_scene_handle(txns[:], ps)
						raw := build_scene_connection_result_raw(handle, args.routes, scratch)
						append_response_msg(&txn.preds, decoded.req_id, raw, scratch)
						append_response_complete(&txn.preds, decoded.req_id, true, scratch)
					}
				}
			}
		}

		append(&txns, txn)
	}

	for &txn, i in txns {
		if i >= number_of_transactions_to_test do break
		real_human := render_burst(&txn.peer.reg_real, txn.peer.ep_real, txn.reals[:], scratch)
		pred_human := render_burst(&txn.peer.reg_pred, txn.peer.ep_pred, txn.preds[:], scratch)
		free_all(context.temp_allocator)

		sync_write_record(
			&out,
			txn.t,
			txn.label,
			real_human == pred_human,
			txn.sent_msgs[:],
			txn.reals[:],
			txn.preds[:],
			txn.sent_human,
			real_human,
			pred_human,
		)
	}

	sync_write_out(out_path, strings.to_string(out))
	fmt.printfln("wrote predicted responses -> %s", out_path)

	return nil
}

replay :: proc(dgrams: ^UDP_Datagram_Store, msgs: ^RakNet_Message_Store, reasm: ^Reassembly, path: string) -> Error {
	fmt.printfln("caleb_raknet replaying %s", path)
	ingest_jsonl(dgrams, msgs, reasm, path) or_return
	print_all_messages(msgs)
	// verify_roundtrip(msgs)
	// verify_completeness(msgs)
	return nil
}

// Read a .jsonl capture and feed every recorded datagram through the same
// datagram->message pipeline as the live listener. Extracted from replay so the
// @(test) harness can populate the stores without duplicating the parse loop.
ingest_jsonl :: proc(dgrams: ^UDP_Datagram_Store, msgs: ^RakNet_Message_Store, reasm: ^Reassembly, path: string) -> Error {
	data := os.read_entire_file_from_path(path, context.allocator) or_return
	defer delete(data)

	line_backing: [MAX_UDP_SIZE * 2 + 256]byte
	arena: mem.Arena
	mem.arena_init(&arena, line_backing[:])
	line_alloc := mem.arena_allocator(&arena)

	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if len(line) == 0 do continue
		free_all(line_alloc)

		rec: Jsonl_Record
		if json.unmarshal_string(line, &rec, allocator = line_alloc) != nil do continue

		decoded, ok := hex.decode(transmute([]byte)rec.hex, line_alloc)
		if !ok do continue

		from, _ := net.parse_endpoint(rec.from)
		recv_time, _ := time.rfc3339_to_time_utc(rec.t)
		if !udp_datagram_push(dgrams, from, recv_time, decoded) {
			fmt.eprintfln("datagram store full, stopping at %d datagrams", dgrams.count)
			break
		}
		process_udp_datagram(dgrams, msgs, reasm, dgrams.count - 1)
	}
	return nil
}

// Step 2 -- message-level round-trip: re-encode every decoded message and confirm
// it reproduces the exact bytes it was decoded from. A byte-perfect re-encode of
// the whole capture proves the decoder is lossless: nothing in the original wire
// was silently dropped. Decode/encode scratch lives in temp, reset per message.
verify_roundtrip :: proc(msgs: ^RakNet_Message_Store) {
	matched := 0
	shown := 0
	for i in 0 ..< msgs.count {
		free_all(context.temp_allocator)
		original := raknet_message_bytes(msgs, i)
		decoded := decode_message(original, context.temp_allocator)
		encoded := encode_message(decoded, context.temp_allocator)
		if bytes_equal(encoded, original) {
			matched += 1
			continue
		}
		if shown < 10 {
			shown += 1
			fmt.printf("  roundtrip MISMATCH [%d] len %d->%d\n    orig: ", i, len(original), len(encoded))
			print_hex(original)
			fmt.print("\n    enc:  ")
			print_hex(encoded)
			fmt.println()
		}
	}
	fmt.printfln("=== roundtrip: %d/%d messages re-encode byte-exact ===", matched, msgs.count)
}

// Step 1 driver over a populated store: scan every decoded message for leftover
// encoded content and print a grouped report. Scratch (decoded trees, token
// sub-decodes, issue list) lives in temp and is reset per message.
verify_completeness :: proc(msgs: ^RakNet_Message_Store) {
	issues := make([dynamic]Completeness_Issue, context.temp_allocator)
	for i in 0 ..< msgs.count {
		decoded := decode_message(raknet_message_bytes(msgs, i), context.temp_allocator)
		collect_completeness_issues(decoded, &issues, context.temp_allocator)
	}
	print_completeness_report(issues[:])
}

bytes_equal :: proc(a, b: []byte) -> bool {
	if len(a) != len(b) do return false
	for i in 0 ..< len(a) {
		if a[i] != b[i] do return false
	}
	return true
}

print_hex :: proc(b: []byte) {
	for x in b do fmt.printf("%02x", x)
}

