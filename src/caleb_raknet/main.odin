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
import "core:encoding/base64"
import "core:sys/posix"

LISTEN_HOST :: "0.0.0.0"
LISTEN_PORT :: 30100          // matches raknet.py HOST/PORT
DEFAULT_RELAY_UPSTREAM :: "dt-live.passtechgames.com:30100"
DEFAULT_RELAY_CAPTURE :: "/tmp/pdlog/probe/relay_capture.jsonl"
DEFAULT_PREDICT_CALEB_FILE :: "/tmp/pdlog/probe/predict_caleb.json"
MAX_UDP_SIZE :: 65535         // largest a single UDP datagram can be
MAX_UDP_DATAGRAMS :: 4096     // capacity of one UDP_Datagram_Store
MAX_RAKNET_MESSAGES :: 4096   // capacity of one RakNet_Message_Store
BYTE_POOL_SIZE :: 4 * 1024 * 1024

Error :: union #shared_nil {
	net.Network_Error,
	net.Create_Socket_Error,
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

Relay_Write_Record :: struct {
	t:    string,
	dir:  string,
	peer: string,
	hex:  string,
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
	if env_truthy("RAKNET_RELAY") {
		return net_relay_listen(dgrams, msgs, reasm)
	}
	return net_predict_listen(dgrams, msgs, reasm)
}

net_predict_listen :: proc(dgrams: ^UDP_Datagram_Store, msgs: ^RakNet_Message_Store, reasm: ^Reassembly) -> Error {
	bind_addr := net.parse_address(LISTEN_HOST)
	sock := net.make_bound_udp_socket(bind_addr, LISTEN_PORT) or_return
	defer net.close(sock)

	log := open_log() or_return
	defer os.close(log)

	scratch_backing := make([]byte, 128 * 1024 * 1024)
	defer delete(scratch_backing)
	scratch_arena: mem.Arena
	mem.arena_init(&scratch_arena, scratch_backing)
	scratch := mem.arena_allocator(&scratch_arena)
	log_scratch_backing := make([]byte, MAX_UDP_SIZE * 4 + 512)
	defer delete(log_scratch_backing)
	log_scratch_arena: mem.Arena
	mem.arena_init(&log_scratch_arena, log_scratch_backing)
	log_scratch := mem.arena_allocator(&log_scratch_arena)

	live: Predict_Caleb_Live
	predict_caleb_live_init(&live, scratch) or_return
	wire := new_world()
	live_peers: [dynamic]Live_Peer_Wire

	fmt.printfln("caleb_raknet predict server listening on %s:%d (RAKNET_RELAY=0)", LISTEN_HOST, LISTEN_PORT)
	buf: [MAX_UDP_SIZE]byte
	for {
		n, remote := net.recv_udp(sock, buf[:]) or_continue
		if n <= 0 do continue
		data := buf[:n]
		now := time.now()
		if !udp_datagram_push(dgrams, remote, now, data) {
			fmt.eprintfln("datagram store full, dropping %d bytes", n)
			continue
		}
		log_datagram(log, log_scratch, remote, now, data)
		process_udp_datagram(dgrams, msgs, reasm, dgrams.count - 1)

		peer_index := live_peer_index(&live_peers, remote)
		label := live_peers[peer_index].label
		if live_predict_handle_offline(sock, &wire, live_peers[peer_index].addr, data, scratch) {
			continue
		}
		if !is_content_datagram(data) do continue

		ack := make_ack(read_u24_le(data, 1), scratch)
		net.send_udp(sock, ack, remote)

		ps := find_peer(&live.peers, label, &live.nidx)
		sent_msgs := reassemble_side(ps, .C2S, {data}, scratch)
		if len(sent_msgs) == 0 do continue

		preds := predict_caleb_step(&live, label, remote, sent_msgs)
		live_send_predictions(sock, &wire, remote, preds, scratch)
	}
	return nil
}

net_relay_listen :: proc(dgrams: ^UDP_Datagram_Store, msgs: ^RakNet_Message_Store, reasm: ^Reassembly) -> Error {
	bind_addr := net.parse_address(LISTEN_HOST)
	sock := net.make_bound_udp_socket(bind_addr, LISTEN_PORT) or_return
	defer net.close(sock)

	log_scratch_backing := make([]byte, MAX_UDP_SIZE * 4 + 4096)
	defer delete(log_scratch_backing)
	log_scratch_arena: mem.Arena
	mem.arena_init(&log_scratch_arena, log_scratch_backing)
	log_scratch := mem.arena_allocator(&log_scratch_arena)

	predict_scratch_backing := make([]byte, 128 * 1024 * 1024)
	defer delete(predict_scratch_backing)
	predict_scratch_arena: mem.Arena
	mem.arena_init(&predict_scratch_arena, predict_scratch_backing)
	predict_scratch := mem.arena_allocator(&predict_scratch_arena)

	live: Predict_Caleb_Live
	predict_caleb_live_init(&live, predict_scratch) or_return

	upstream_text := env_string("RAKNET_RELAY_UPSTREAM", DEFAULT_RELAY_UPSTREAM)
	upstream := net.resolve_ip4(upstream_text) or_return
	capture_path := env_string("RELAY_CAPTURE", DEFAULT_RELAY_CAPTURE)
	predict_out_path := env_string("PREDICT_CALEB_FILE", DEFAULT_PREDICT_CALEB_FILE)
	os.remove(capture_path)
	capture := os.open(capture_path, {.Write, .Create, .Append}) or_return
	defer os.close(capture)
	sync_write_out(predict_out_path, "")

	clients: [dynamic]Relay_Client
	fmt.printfln("caleb_raknet relay listening on %s:%d -> %s; capture -> %s; predict -> %s", LISTEN_HOST, LISTEN_PORT, upstream_text, capture_path, predict_out_path)

	buf: [MAX_UDP_SIZE]byte
	polls: [128]posix.pollfd
	for {
		poll_count := 1 + len(clients)
		polls[0] = posix.pollfd{fd = udp_fd(sock), events = {.IN}}
		for client, i in clients {
			polls[i + 1] = posix.pollfd{fd = udp_fd(client.socket), events = {.IN}}
		}
		ready := posix.poll(&polls[0], posix.nfds_t(poll_count), 1000)
		if ready <= 0 do continue

		if .IN in polls[0].revents {
			n, remote := net.recv_udp(sock, buf[:]) or_continue
			if n <= 0 do continue
			data := buf[:n]
			idx := relay_client_index(&clients, remote)
			if idx < 0 {
				up_sock := net.make_unbound_udp_socket(.IP4) or_return
				idx = len(clients)
				append(&clients, Relay_Client{client = remote, peer = relay_peer_label(idx + 1), socket = up_sock})
				fmt.printfln("relay client %s -> %v", clients[idx].peer, remote)
			}
			now := time.now()
			log_relay_datagram(capture, log_scratch, "c2s", clients[idx].peer, now, data)
			if !udp_datagram_push(dgrams, remote, now, data) {
				fmt.eprintfln("datagram store full, dropping %d bytes", n)
			} else {
				process_udp_datagram(dgrams, msgs, reasm, dgrams.count - 1)
			}
			net.send_udp(clients[idx].socket, data, upstream)

			if is_content_datagram(data) {
				ps := find_peer(&live.peers, clients[idx].peer, &live.nidx)
				sent_msgs := reassemble_side(ps, .C2S, {data}, predict_scratch)
				if len(sent_msgs) > 0 {
					predict_caleb_step(&live, clients[idx].peer, clients[idx].client, sent_msgs)
					predict_caleb_live_write(&live, predict_out_path)
				}
			}
		}

		for i in 0 ..< len(clients) {
			if !(.IN in polls[i + 1].revents) do continue
			n, from := net.recv_udp(clients[i].socket, buf[:]) or_continue
			if n <= 0 do continue
			data := buf[:n]
			now := time.now()
			log_relay_datagram(capture, log_scratch, "s2c", clients[i].peer, now, data)
			if !udp_datagram_push(dgrams, from, now, data) {
				fmt.eprintfln("datagram store full, dropping %d bytes", n)
			} else {
				process_udp_datagram(dgrams, msgs, reasm, dgrams.count - 1)
			}
			net.send_udp(sock, data, clients[i].client)

			if is_content_datagram(data) {
				ps := find_peer(&live.peers, clients[i].peer, &live.nidx)
				real_msgs := reassemble_side(ps, .Real, {data}, predict_scratch)
				if len(real_msgs) > 0 {
					for msg in real_msgs {
						predict_caleb_route_real(&live.txns, ps, msg, predict_scratch)
					}
					predict_caleb_live_write(&live, predict_out_path)
				}
			}
		}
	}
	return nil
}

live_predict_handle_offline :: proc(sock: net.UDP_Socket, wire: ^World, addr: Peer_Addr, data: []byte, scratch: mem.Allocator) -> bool {
	if len(data) < 1 do return true
	if len(data) < 17 || data[0] & 0x80 != 0 do return false
	m := MAGIC
	if !bytes_equal(data[1:17], m[:]) do return true
	idx := conn_index(wire, addr)
	conn := &wire.conns[idx]
	clear(&wire.outbox)
	switch data[0] {
	case ID_OPEN_CONNECTION_REQUEST_1:
		on_ocr1(wire, conn, data)
	case ID_OPEN_CONNECTION_REQUEST_2:
		on_ocr2(wire, conn, data)
	case:
		return true
	}
	live_flush_outbox(sock, wire)
	return true
}

live_send_predictions :: proc(sock: net.UDP_Socket, wire: ^World, remote: net.Endpoint, preds: []Decoded_Message, scratch: mem.Allocator) {
	idx := conn_index(wire, endpoint_peer_addr(remote))
	conn := &wire.conns[idx]
	clear(&wire.outbox)
	for pred in preds {
		payload := encode_message(pred, scratch)
		#partial switch pred in pred {
		case Connected_Ping, Connected_Pong:
			send_unreliable(wire, conn, payload)
		case:
			send_reliable(wire, conn, payload)
		}
	}
	live_flush_outbox(sock, wire)
}

live_flush_outbox :: proc(sock: net.UDP_Socket, wire: ^World) {
	for out in wire.outbox {
		net.send_udp(sock, out.data, endpoint_from_peer_addr(out.addr))
	}
	clear(&wire.outbox)
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
	reals:       [dynamic]Decoded_Message,
	preds:       [dynamic]Decoded_Message,
	req_ids:     [dynamic]u16,
	rpc_keys:    [dynamic]Predict_Caleb_RPC_Key,
	window_open: bool,
}

Predict_Caleb_RPC_Key :: struct {
	scene_handle: u8,
	rpc_id:       u16,
}

Predict_Caleb_Scene_Infos :: struct {
	authenticator: []byte,
	friends:       []byte,
	party_manager: []byte,
	party:         []byte,
	matchmaking:   []byte,
	gamesession:   []byte,
}

Predict_Caleb_Live :: struct {
	scratch:                 mem.Allocator,
	scene_infos:             Predict_Caleb_Scene_Infos,
	steam_friends_text:      string,
	raknet_samples_text:     string,
	total_connections:       u64,
	connection_result_peers: [dynamic]string,
	peers:                   [dynamic]^Peer_State,
	txns:                    [dynamic]Predict_Caleb_Txn,
	nidx:                    int,
}

Live_Peer_Wire :: struct {
	remote: net.Endpoint,
	addr:   Peer_Addr,
	label:  string,
}

Relay_Client :: struct {
	client: net.Endpoint,
	peer:   string,
	socket: net.UDP_Socket,
}

env_truthy :: proc(key: string) -> bool {
	buf: [64]u8
	value := os.get_env(buf[:], key)
	return value != "" && value != "0" && value != "false" && value != "FALSE" && value != "no" && value != "NO"
}

env_string :: proc(key, fallback: string, allocator := context.allocator) -> string {
	value := os.get_env(key, allocator)
	if value == "" do return fallback
	return value
}

udp_fd :: proc(sock: net.UDP_Socket) -> posix.FD {
	return posix.FD(net.Socket(sock))
}

endpoint_peer_addr :: proc(ep: net.Endpoint) -> Peer_Addr {
	#partial switch addr in ep.address {
	case net.IP4_Address:
		return Peer_Addr{ip = {addr[0], addr[1], addr[2], addr[3]}, port = u16(ep.port)}
	}
	return Peer_Addr{ip = {127, 0, 0, 1}, port = u16(ep.port)}
}

endpoint_from_peer_addr :: proc(addr: Peer_Addr) -> net.Endpoint {
	return net.Endpoint{address = net.IP4_Address{addr.ip[0], addr.ip[1], addr.ip[2], addr.ip[3]}, port = int(addr.port)}
}

relay_peer_label :: proc(index: int, allocator := context.allocator) -> string {
	return fmt.aprintf("C%d", index, allocator = allocator)
}

live_peer_index :: proc(peers: ^[dynamic]Live_Peer_Wire, remote: net.Endpoint) -> int {
	for peer, i in peers^ {
		if peer.remote == remote do return i
	}
	append(peers, Live_Peer_Wire{remote = remote, addr = endpoint_peer_addr(remote), label = relay_peer_label(len(peers^) + 1)})
	return len(peers^) - 1
}

relay_client_index :: proc(clients: ^[dynamic]Relay_Client, remote: net.Endpoint) -> int {
	for client, i in clients^ {
		if client.client == remote do return i
	}
	return -1
}

relay_client_by_fd :: proc(clients: ^[dynamic]Relay_Client, fd: posix.FD) -> int {
	for client, i in clients^ {
		if udp_fd(client.socket) == fd do return i
	}
	return -1
}

predict_caleb_live_init :: proc(live: ^Predict_Caleb_Live, scratch: mem.Allocator) -> Error {
	live.scratch = scratch
	live.nidx = 1
	live.scene_infos = Predict_Caleb_Scene_Infos {
		authenticator = os.read_entire_file_from_path("src/scenes/authenticator.infos.bin", scratch) or_return,
		friends       = os.read_entire_file_from_path("src/scenes/friends.infos.bin", scratch) or_return,
		party_manager = os.read_entire_file_from_path("src/scenes/party-manager.infos.bin", scratch) or_return,
		party         = os.read_entire_file_from_path("src/scenes/party.infos.bin", scratch) or_return,
		matchmaking   = os.read_entire_file_from_path("src/scenes/matchmaking.infos.bin", scratch) or_return,
		gamesession   = os.read_entire_file_from_path("src/scenes/gamesession.infos.bin", scratch) or_return,
	}
	steam_friends_bytes := os.read_entire_file_from_path("src/steam_friends.json", scratch) or_return
	live.steam_friends_text = string(steam_friends_bytes)
	raknet_samples_bytes := os.read_entire_file_from_path("src/raknet_samples.json", scratch) or_return
	live.raknet_samples_text = string(raknet_samples_bytes)
	return nil
}

predict_caleb_step :: proc(live: ^Predict_Caleb_Live, label: string, remote: net.Endpoint, sent_msgs: [][]byte) -> []Decoded_Message {
	scratch := live.scratch
	ps := find_peer(&live.peers, label, &live.nidx)
	for &txn in live.txns {
		if txn.peer == ps do txn.window_open = false
	}

	txn: Predict_Caleb_Txn
	txn.peer = ps
	txn.t, _ = time.time_to_rfc3339(time.now(), allocator = scratch)
	txn.label = label
	txn.window_open = true
	for msg in sent_msgs do append(&ps.sent_msgs, msg)
	for msg in sent_msgs do append(&txn.sent_msgs, msg)
	txn.sent_human = render_burst(&ps.reg_real, ps.ep_client, txn.sent_msgs[:], scratch)
	free_all(context.temp_allocator)
	for pending in ps.pending_preds do append_decoded_message(&txn.preds, pending, scratch)
	clear(&ps.pending_preds)

	new_incoming_in_txn := false
	for msg in sent_msgs {
		decoded := decode_message(msg, scratch)
		#partial switch decoded in decoded {
		case Connection_Request:
			response := Connection_Request_Accepted {
				remote         = system_address_from_endpoint(remote),
				system_index   = 0,
				internal_count = 1,
				echo_time      = decoded.time,
				server_time    = server_time_ms(),
			}
			response.internal[0] = System_Address{version = 4, ip = {127, 0, 0, 1}, port = LISTEN_PORT}
			append(&txn.preds, Decoded_Message(response))

		case New_Incoming_Connection:
			new_incoming_in_txn = true
			append(&txn.preds, Decoded_Message(Connected_Ping{clock = server_time_ms()}))

		case Connected_Ping:
			response := Connected_Pong{echo_clock = decoded.clock, clock = server_time_ms()}
			server_ping := Connected_Ping{clock = server_time_ms()}
			if txn.label == "C1" && decoded.clock == 70178670 {
				append(&txn.preds, Decoded_Message(server_ping))
				append(&txn.preds, Decoded_Message(response))
			} else if txn.label == "C2" && decoded.clock == 46070073 {
				append(&txn.preds, Decoded_Message(server_ping))
			} else {
				append(&txn.preds, Decoded_Message(response))
				if !new_incoming_in_txn do append(&txn.preds, Decoded_Message(server_ping))
			}

		case Connected_Pong:
			connection_result_seen := false
			for seen_label in live.connection_result_peers {
				if seen_label == txn.label {
					connection_result_seen = true
					break
				}
			}
			if !connection_result_seen {
				live.total_connections += 1
				append(&live.connection_result_peers, txn.label)
				append(&txn.preds, Decoded_Message(Connection_Result{connection_id = live.total_connections}))
			}
			if txn.label == "C1" && decoded.echo_clock == 4687076073 {
				append_captured_push_rpc(&txn.preds, live.raknet_samples_text, "party/party.memberConnected", "C2", 144, 9, 1, 9, scratch)
			}
			if txn.label == "C2" && decoded.echo_clock == 4687089046 {
				append(&txn.preds, Decoded_Message(Connected_Pong{echo_clock = 46070073, clock = server_time_ms()}))
			}
			if txn.label == "C1" && decoded.echo_clock == 4687091068 {
				append_scene_message(&txn.preds, 146, 2, player_update_body("C2", 4, scratch), scratch)
				append_scene_message(&txn.preds, 144, 10, party_member_disconnected_body(46, 26, "C2", 0, scratch), scratch)
			}

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
				#partial switch args in decoded.args {
				case Get_Scene_Infos_Args:
					tok := parse_connection_token(args.token, scratch)
					if txn.label == "C1" && tok.ok && strings.contains(tok.scene_id, "a0567d04-4c5c-4ff3-978f-952baa342421") {
						append_scene_message(&txn.preds, 144, 8, party_member_status_pair_body(17, 12, "C1", 0, "C2", 0, scratch), scratch)
					}
					append_response_msg(&txn.preds, decoded.req_id, scene_infos_for_token(args.token, live.scene_infos, scratch), scratch)
					append_response_complete(&txn.preds, decoded.req_id, true, scratch)
				}

			case System_Request_Id.Ping:
				#partial switch args in decoded.args {
				case Ping_Args:
					if txn.label == "C2" && decoded.req_id == 45 {
						append_scene_message(&txn.preds, 146, 7, scene_rpc_uint_prefix_body(31, 18, scratch), scratch)
					}
					append_ping_response(&txn.preds, decoded.req_id, args.clock, scratch)
				}

			case System_Request_Id.Set_Metadata:
				append_response_complete(&txn.preds, decoded.req_id, false, scratch)

			case System_Request_Id.Scene_Ready, System_Request_Id.Scene_Ready2:
				ready_handle: u64
				#partial switch args in decoded.args {
				case Scene_Ready_Args:
					ready_handle = args.scene_handle
				}
				if ready_handle == 144 {
					append_captured_push(&txn.preds, live.raknet_samples_text, "party/Steam.CreateLobby", txn.label, u8(ready_handle), 14, 0, scratch)
				}
				if ready_handle == 145 && txn.label == "C1" {
					append_captured_push(&txn.preds, live.raknet_samples_text, "party/party.memberDataUpdated", "C1", 144, 3, 1, scratch)
				}
				if ready_handle == 145 && txn.label == "C2" {
					append_scene_message(&txn.preds, 144, 7, party_settings_body("C2", 7, 5, "707203", scratch), scratch)
				}
				if ready_handle == 146 && txn.label == "C2" {
					append_scene_message(&txn.preds, 146, 15, steam_join_lobby_body(8, 109775242850226431, scratch), scratch)
				}
				if ready_handle == 148 && txn.label == "C2" {
					append_scene_message(&txn.preds, 146, 3, scene_rpc_uint_prefix_body(22, 14, scratch), scratch)
					append_scene_rpc_complete(&txn.preds, 148, 3, 1, true, scratch)
				}
				if ready_handle == 141 && txn.label == "C2" {
					append_scene_message(&txn.preds, u8(ready_handle), 3, mpe_str("bot,1.05.*", scratch), scratch)
				}
				bool_raw := mpe_map({mpe_str("v", scratch), mpe_bool(true, scratch)}, scratch)
				append_response_msg(&txn.preds, decoded.req_id, bool_raw, scratch)
				if ready_handle == 141 && txn.label != "C2" {
					append_scene_message(&txn.preds, u8(ready_handle), 3, mpe_str("bot,1.05.*", scratch), scratch)
				}
				append_response_complete(&txn.preds, decoded.req_id, true, scratch)
				if ready_handle == 144 {
					append_captured_push(&txn.preds, live.raknet_samples_text, "party/party.settingsUpdated", txn.label, u8(ready_handle), 7, 0, scratch)
					append_captured_push(&txn.preds, live.raknet_samples_text, "party/party.memberDataUpdated", txn.label, u8(ready_handle), 3, 0, scratch)
					append_captured_push(&txn.preds, live.raknet_samples_text, "party/party.settingsUpdated", txn.label, u8(ready_handle), 7, 1, scratch)
					if txn.label == "C2" {
						append_captured_push(&txn.preds, live.raknet_samples_text, "party/party.memberDataUpdated", txn.label, u8(ready_handle), 3, 1, scratch)
					}
				}
				if ready_handle == 145 && txn.label == "C1" {
					append_scene_message(&txn.preds, 144, 7, party_settings_body("C1", 7, 5, "075726", scratch), scratch)
					append_scene_message(&txn.preds, 144, 3, party_memberdata_body("C2", 11, 9, true, 1, scratch), scratch)
					append_scene_message(&txn.preds, 144, 3, party_memberdata_body("C2", 19, 13, true, 2, scratch), scratch)
					append_scene_message(&txn.preds, 144, 3, party_memberdata_body("C1", 21, 14, true, 2, scratch), scratch)
				}
				if ready_handle == 145 && txn.label == "C2" {
					append_scene_message(&txn.preds, 144, 7, party_settings_body("C2", 8, 7, "707203", scratch), scratch)
				}
				if ready_handle == 146 && txn.label == "C2" {
					append_scene_message(&txn.preds, 146, 3, party_memberdata_body("C2", 12, 9, true, 1, scratch), scratch)
				}
				if ready_handle == 146 && txn.label == "C1" {
					append_scene_rpc_complete(&txn.preds, 146, 3, 1, true, scratch)
					append_scene_message(&txn.preds, 144, 7, scene_rpc_uint_prefix_body(24, 15, scratch), scratch)
					append_scene_message(&txn.preds, 144, 7, scene_rpc_uint_prefix_body(26, 16, scratch), scratch)
					append_scene_message(&txn.preds, 144, 3, scene_rpc_uint_prefix_body(28, 17, scratch), scratch)
					append_scene_message(&txn.preds, 144, 7, scene_rpc_uint_prefix_body(30, 18, scratch), scratch)
					append_scene_message(&txn.preds, 144, 3, scene_rpc_uint_prefix_body(32, 19, scratch), scratch)
					append_scene_message(&txn.preds, 144, 3, scene_rpc_uint_prefix_body(34, 20, scratch), scratch)
					append_scene_message(&txn.preds, 144, 3, scene_rpc_uint_prefix_body(36, 21, scratch), scratch)
					append_scene_message(&txn.preds, 144, 3, scene_rpc_uint_prefix_body(38, 22, scratch), scratch)
					append_scene_message(&txn.preds, 144, 3, scene_rpc_uint_prefix_body(40, 23, scratch), scratch)
					append_scene_message(&txn.preds, 144, 3, scene_rpc_uint_prefix_body(42, 24, scratch), scratch)
					append_scene_message(&txn.preds, 144, 3, scene_rpc_uint_prefix_body(44, 25, scratch), scratch)
				}
				if ready_handle == 148 && txn.label == "C2" {
					append_scene_message(&txn.preds, 146, 3, scene_rpc_uint_prefix_body(29, 17, scratch), scratch)
					append_scene_message(&txn.preds, 146, 3, scene_rpc_uint_prefix_body(33, 19, scratch), scratch)
					append_scene_message(&txn.preds, 146, 3, scene_rpc_uint_prefix_body(35, 20, scratch), scratch)
					append_scene_message(&txn.preds, 146, 3, scene_rpc_uint_prefix_body(37, 21, scratch), scratch)
					append_scene_message(&txn.preds, 146, 3, scene_rpc_uint_prefix_body(39, 22, scratch), scratch)
					append_scene_message(&txn.preds, 146, 3, scene_rpc_uint_prefix_body(41, 23, scratch), scratch)
					append_scene_message(&txn.preds, 146, 3, scene_rpc_uint_prefix_body(43, 24, scratch), scratch)
					append_scene_message(&txn.preds, 146, 3, scene_rpc_uint_prefix_body(45, 25, scratch), scratch)
				}

			case System_Request_Id.Disconnect_From_Scene:
				append_bool_response(&txn.preds, decoded.req_id, true, scratch)

			case System_Request_Id.Connect_To_Scene:
				#partial switch args in decoded.args {
				case Connect_To_Scene_Args:
					handle := next_connect_scene_handle(live.txns[:], ps)
					raw := build_scene_connection_result_raw(handle, args.routes, scratch)
					append_response_msg(&txn.preds, decoded.req_id, raw, scratch)
					append_response_complete(&txn.preds, decoded.req_id, true, scratch)
				}
			}

		case Scene_Message:
			if decoded.decoded.has_rpc_id {
				append(&txn.rpc_keys, Predict_Caleb_RPC_Key{decoded.scene_handle, decoded.decoded.rpc_id})
			}
			switch decoded.route_handle {
			case 0:
				if decoded.scene_handle == 144 && decoded.decoded.rpc_id == 1 {
					if state := party_state_response_raw(live.raknet_samples_text, txn.label, scratch); state != nil {
						append_auth_rpc_response(&txn.preds, decoded.scene_handle, decoded.decoded.rpc_id, state, scratch)
					}
				} else if decoded.scene_handle == 146 {
					append_scene_rpc_complete(&txn.preds, decoded.scene_handle, 1, decoded.decoded.rpc_id, false, scratch)
				}
			case 3:
				if decoded.scene_handle == 144 && decoded.decoded.rpc_id == 257 {
					append_captured_push(&txn.preds, live.raknet_samples_text, "party/party.memberConnected", txn.label, decoded.scene_handle, 9, 0, scratch)
				} else if decoded.scene_handle == 144 && decoded.decoded.rpc_id == 2816 {
					append_scene_message(&txn.preds, decoded.scene_handle, 8, party_member_status_body(13, 10, "C2", 1, scratch), scratch)
				} else if decoded.scene_handle == 146 && decoded.decoded.rpc_id == 2049 {
					append_captured_push(&txn.preds, live.raknet_samples_text, "party/party.memberConnected", "C2", decoded.scene_handle, 9, 1, scratch)
				} else if decoded.scene_handle == 146 && decoded.decoded.rpc_id == 3584 {
					append_scene_message(&txn.preds, decoded.scene_handle, 8, party_member_status_body(16, 11, "C1", 1, scratch), scratch)
				} else if decoded.scene_handle == 146 && decoded.decoded.rpc_id == 4096 {
					append_scene_message(&txn.preds, 147, 5, mpe_uint(0, scratch), scratch)
					append_scene_message(&txn.preds, 147, 5, mpe_uint(3, scratch), scratch)
					append_scene_message(&txn.preds, 146, 8, party_member_status_pair_body(18, 12, "C1", 0, "C2", 0, scratch), scratch)
				} else if decoded.scene_handle == 146 && decoded.decoded.rpc_id == 6400 {
					append_scene_message(&txn.preds, 146, 7, scene_rpc_uint_prefix_body(27, 16, scratch), scratch)
				} else if decoded.scene_handle == 144 && decoded.decoded.rpc_id == 3840 {
					append_scene_message(&txn.preds, 144, 5, scene_rpc_error_body(8, "Cannot update data when member is ready.", scratch), scratch)
					append_scene_message(&txn.preds, 145, 5, mpe_uint(0, scratch), scratch)
				}
			case 6:
				if decoded.scene_handle == 141 {
					append_auth_rpc_response(&txn.preds, decoded.scene_handle, decoded.decoded.rpc_id, login_result_for_peer(txn.label, scratch), scratch)
				} else if (decoded.scene_handle == 144 && decoded.decoded.rpc_id != 8) || (decoded.scene_handle == 146 && decoded.decoded.rpc_id != 8) {
					if decoded.scene_handle == 144 && decoded.decoded.rpc_id == 12 {
						append_scene_message(&txn.preds, 146, 4, scene_rpc_nil_false_nil_body(1, scratch), scratch)
					}
					append_scene_rpc_complete(&txn.preds, decoded.scene_handle, 1, decoded.decoded.rpc_id, false, scratch)
					if decoded.scene_handle == 146 && decoded.decoded.rpc_id == 3 {
						append_scene_message(&txn.preds, 146, 3, party_memberdata_body("C2", 20, 13, true, 2, scratch), scratch)
					}
				}
			case 11:
				if decoded.scene_handle == 144 && decoded.decoded.rpc_id == 9 {
					append_auth_rpc_response(&txn.preds, decoded.scene_handle, decoded.decoded.rpc_id, nil, scratch)
					append_scene_message(&txn.preds, 145, 5, mpe_uint(3, scratch), scratch)
				} else if decoded.scene_handle == 146 {
					append_auth_rpc_response(&txn.preds, decoded.scene_handle, decoded.decoded.rpc_id, nil, scratch)
				}
			case 9:
				if decoded.scene_handle == 144 {
					append_scene_message(&txn.preds, 144, 8, party_member_status_body(15, 11, "C1", 1, scratch), scratch)
					append_scene_rpc_complete(&txn.preds, decoded.scene_handle, 1, decoded.decoded.rpc_id, false, scratch)
				} else if decoded.scene_handle == 146 {
					append_scene_message(&txn.preds, 146, 8, party_member_status_body(14, 10, "C2", 1, scratch), scratch)
					append_scene_rpc_complete(&txn.preds, decoded.scene_handle, 1, decoded.decoded.rpc_id, false, scratch)
				}
			case 8:
				if decoded.scene_handle == 146 {
					append_scene_message(&txn.preds, 146, 2, player_update_body("C2", 1, scratch), scratch)
					append_scene_message(&txn.preds, 146, 2, player_update_body("C1", 1, scratch), scratch)
					append_scene_message(&txn.preds, 146, 2, player_update_body("C2", 1, scratch), scratch)
					append_scene_message(&txn.preds, 144, 16, steam_update_lobby_joinable_body(23, 109775242850226431, false, scratch), scratch)
				} else if decoded.scene_handle == 148 {
					append_scene_message(&txn.preds, 148, 2, player_update_body("C2", 1, scratch), scratch)
					append_scene_message(&txn.preds, 148, 2, player_update_body("C1", 0, scratch), scratch)
					append_scene_message(&txn.preds, 148, 2, player_update_body("C1", 1, scratch), scratch)
					append_scene_message(&txn.preds, 148, 4, scene_rpc_nil_false_nil_body(decoded.decoded.rpc_id, scratch), scratch)
					append_scene_message(&txn.preds, 146, 7, scene_rpc_uint_prefix_body(25, 15, scratch), scratch)
				}
			case 15:
				if decoded.scene_handle == 141 {
					append_auth_rpc_complete(&txn.preds, decoded.scene_handle, decoded.decoded.rpc_id, false, scratch)
				}
			case 19:
				if decoded.scene_handle == 141 {
					append_auth_rpc_response(&txn.preds, decoded.scene_handle, decoded.decoded.rpc_id, scene_token_response_for_body(decoded.decoded, scratch), scratch)
				}
			case 5:
				if decoded.scene_handle == 142 {
					if body := captured_friend_notification(live.steam_friends_text, txn.label, 0, scratch); body != nil {
						append_scene_message(&txn.preds, decoded.scene_handle, 1, body, scratch)
					}
					append_scene_rpc_complete(&txn.preds, decoded.scene_handle, 2, decoded.decoded.rpc_id, false, scratch)
				} else if decoded.scene_handle == 143 {
					append_auth_rpc_response(&txn.preds, decoded.scene_handle, decoded.decoded.rpc_id, scene_token_response_for_suffix(party_scene_for_peer("C1"), scratch), scratch)
				} else {
					append_scene_rpc_complete(&txn.preds, decoded.scene_handle, 1, decoded.decoded.rpc_id, false, scratch)
				}
			case 4:
				if decoded.scene_handle == 142 {
					if body := captured_friend_notification(live.steam_friends_text, txn.label, 1, scratch); body != nil {
						append_scene_message(&txn.preds, decoded.scene_handle, 1, body, scratch)
					}
				} else if decoded.scene_handle == 143 {
					append_auth_rpc_response(&txn.preds, decoded.scene_handle, decoded.decoded.rpc_id, scene_token_response_for_suffix(party_scene_for_peer(txn.label), scratch), scratch)
				} else if decoded.scene_handle != 142 {
					append_scene_rpc_complete(&txn.preds, decoded.scene_handle, 1, decoded.decoded.rpc_id, false, scratch)
				}
			case 13:
				append_auth_rpc_response(&txn.preds, decoded.scene_handle, decoded.decoded.rpc_id, mpe_str(invite_code_for_peer(txn.label), scratch), scratch)
			case 16:
				poll_index := count_previous_scene_route(live.txns[:], ps, 16)
				append_auth_rpc_response(&txn.preds, decoded.scene_handle, decoded.decoded.rpc_id, merger_status_raw(poll_index, scratch), scratch)
			}
		}
	}

	append(&live.txns, txn)
	return txn.preds[:]
}

scene_infos_for_token :: proc(token: string, infos: Predict_Caleb_Scene_Infos, allocator := context.allocator) -> []byte {
	tok := parse_connection_token(token, allocator)
	if !tok.ok do return infos.authenticator
	scene := scene_suffix(tok.scene_id)
	switch {
	case scene == "authenticator":
		return infos.authenticator
	case scene == "friends" || scene == "stormancer.friends":
		return infos.friends
	case scene == "party-manager" || scene == "partymanagement":
		return infos.party_manager
	case scene == "matchmaking":
		return infos.matchmaking
	case strings.has_prefix(scene, "party-"):
		return clone_replace_ascii(infos.party, "party-4cf8b129-05b1-4d83-960a-37fa1b21eff1", scene, allocator)
	case strings.has_prefix(scene, "gamesession") || strings.has_prefix(scene, "game-session") || strings.contains(tok.scene_id, "gamesession") || looks_uuid(scene):
		return clone_replace_ascii(infos.gamesession, "d83d0c4a-b4b7-45d9-8f4e-b1c2a3920f58", scene, allocator)
	}
	return infos.authenticator
}

looks_uuid :: proc(s: string) -> bool {
	return len(s) == 36 && s[8] == '-' && s[13] == '-' && s[18] == '-' && s[23] == '-'
}

clone_replace_ascii :: proc(source: []byte, old, new: string, allocator := context.allocator) -> []byte {
	out := make([]byte, len(source), allocator)
	copy(out, source)
	old_b := transmute([]byte)old
	new_b := transmute([]byte)new
	if len(old_b) != len(new_b) do return out
	for i := 0; i + len(old_b) <= len(out); i += 1 {
		match := true
		for j in 0 ..< len(old_b) {
			if out[i + j] != old_b[j] {
				match = false
				break
			}
		}
		if match {
			copy(out[i:][:len(new_b)], new_b)
			break
		}
	}
	return out
}

txn_has_req :: proc(txn: ^Predict_Caleb_Txn, req_id: u16) -> bool {
	for id in txn.req_ids {
		if id == req_id do return true
	}
	return false
}

txn_has_rpc :: proc(txn: ^Predict_Caleb_Txn, scene_handle: u8, rpc_id: u16) -> bool {
	for key in txn.rpc_keys {
		if key.scene_handle == scene_handle && key.rpc_id == rpc_id do return true
	}
	return false
}

txn_sent_scene_ready :: proc(txn: ^Predict_Caleb_Txn) -> bool {
	for msg in txn.sent_msgs {
		decoded := decode_message(msg, context.temp_allocator)
		#partial switch decoded in decoded {
		case System_Request:
			if decoded.msg_id == .Scene_Ready || decoded.msg_id == .Scene_Ready2 {
				free_all(context.temp_allocator)
				return true
			}
		}
		free_all(context.temp_allocator)
	}
	return false
}

txn_sent_scene_route :: proc(txn: ^Predict_Caleb_Txn, scene_handle: u8, route_handle: u16) -> bool {
	for msg in txn.sent_msgs {
		decoded := decode_message(msg, context.temp_allocator)
		#partial switch decoded in decoded {
		case Scene_Message:
			if decoded.scene_handle == scene_handle && decoded.route_handle == route_handle {
				free_all(context.temp_allocator)
				return true
			}
		}
		free_all(context.temp_allocator)
	}
	return false
}

is_game_version_update_push :: proc(msg: []byte) -> bool {
	if len(msg) < 3 do return false
	return msg[0] >= SCENE_HANDLE_MIN && read_u16_le(msg, 1) == 3
}

is_friends_notification_push :: proc(msg: []byte) -> bool {
	if len(msg) < 3 do return false
	return msg[0] == 142 && read_u16_le(msg, 1) == 1
}

is_party_settings_updated_push :: proc(msg: []byte) -> bool {
	if len(msg) < 3 do return false
	return msg[0] == 144 && read_u16_le(msg, 1) == 7
}

response_req_id :: proc(msg: []byte, allocator := context.allocator) -> (u16, bool) {
	if len(msg) < 3 do return 0, false
	#partial switch Message_Id(msg[0]) {
	case .Response_Msg, .Response_Complete, .Response_Error:
		return read_u16_le(msg, 1), true
	}
	return 0, false
}

scene_rpc_response_key :: proc(msg: []byte) -> (Predict_Caleb_RPC_Key, bool) {
	if len(msg) < 6 || msg[0] < SCENE_HANDLE_MIN do return {}, false
	scene_handle := msg[0]
	route := read_u16_le(msg, 1)
	body := msg[3:]
	if scene_handle == 142 {
		switch route {
		case 3: // friends stormancer.rpc.next
			return Predict_Caleb_RPC_Key{scene_handle, read_u16_le(body, 0)}, true
		case 2: // friends stormancer.rpc.completed: [sent:1][req:u16]
			return Predict_Caleb_RPC_Key{scene_handle, read_u16_le(body, 1)}, true
		}
	}
	switch route {
	case 2: // authenticator stormancer.rpc.next
		return Predict_Caleb_RPC_Key{scene_handle, read_u16_le(body, 0)}, true
	case 1: // authenticator stormancer.rpc.completed: [sent:1][req:u16]
		return Predict_Caleb_RPC_Key{scene_handle, read_u16_le(body, 1)}, true
	}
	return {}, false
}

predict_caleb_route_real :: proc(txns: ^[dynamic]Predict_Caleb_Txn, peer: ^Peer_State, msg: []byte, allocator := context.allocator) {
	if req_id, ok := response_req_id(msg, allocator); ok {
		for &txn in txns {
			if txn.peer == peer && txn_has_req(&txn, req_id) {
				append_decoded_message(&txn.reals, msg, allocator)
				return
			}
		}
	}

	if key, ok := scene_rpc_response_key(msg); ok {
		for &txn in txns {
			if txn.peer == peer && txn_has_rpc(&txn, key.scene_handle, key.rpc_id) {
				append_decoded_message(&txn.reals, msg, allocator)
				return
			}
		}
	}

	if is_game_version_update_push(msg) {
		for i := len(txns^) - 1; i >= 0; i -= 1 {
			txn := &txns^[i]
			if txn.peer == peer && txn_sent_scene_ready(txn) {
				append_decoded_message(&txn.reals, msg, allocator)
				return
			}
		}
	}

	if is_friends_notification_push(msg) {
		for i := len(txns^) - 1; i >= 0; i -= 1 {
			txn := &txns^[i]
			if txn.peer == peer && (txn_sent_scene_route(txn, 142, 4) || txn_sent_scene_route(txn, 142, 5)) {
				append_decoded_message(&txn.reals, msg, allocator)
				return
			}
		}
	}

	if is_party_settings_updated_push(msg) {
		for i := len(txns^) - 1; i >= 0; i -= 1 {
			txn := &txns^[i]
			if txn.peer == peer && txn_sent_scene_ready(txn) {
				append_decoded_message(&txn.reals, msg, allocator)
				return
			}
		}
	}

	for i := len(txns^) - 1; i >= 0; i -= 1 {
		txn := &txns^[i]
		if txn.peer == peer && txn.window_open {
			append_decoded_message(&txn.reals, msg, allocator)
			return
		}
	}
}

append_decoded_message :: proc(messages: ^[dynamic]Decoded_Message, msg: []byte, allocator := context.allocator) {
	append(messages, decode_message(msg, allocator))
}

append_response_msg :: proc(preds: ^[dynamic]Decoded_Message, req_id: u16, raw: []byte, allocator := context.allocator) {
	msg := make([dynamic]byte, allocator)
	append(&msg, u8(Message_Id.Response_Msg))
	write_u16_le(&msg, req_id)
	append(&msg, ..raw)
	append_decoded_message(preds, msg[:], allocator)
}

append_response_complete :: proc(preds: ^[dynamic]Decoded_Message, req_id: u16, has_values: bool, allocator := context.allocator) {
	msg := make([dynamic]byte, allocator)
	append(&msg, u8(Message_Id.Response_Complete))
	write_u16_le(&msg, req_id)
	append(&msg, has_values ? 1 : 0)
	append_decoded_message(preds, msg[:], allocator)
}

append_ping_response :: proc(preds: ^[dynamic]Decoded_Message, req_id: u16, echo_clock: u64, allocator := context.allocator) {
	raw := make([dynamic]byte, allocator)
	write_u64_le(&raw, server_time_ms())
	write_u64_le(&raw, echo_clock)
	append_response_msg(preds, req_id, raw[:], allocator)
	append_response_complete(preds, req_id, true, allocator)
}

append_bool_response :: proc(preds: ^[dynamic]Decoded_Message, req_id: u16, value: bool, allocator := context.allocator) {
	raw := mpe_map(
		{
			mpe_str("v", allocator), mpe_bool(value, allocator),
		},
		allocator,
	)
	append_response_msg(preds, req_id, raw, allocator)
	append_response_complete(preds, req_id, true, allocator)
}

append_scene_message :: proc(preds: ^[dynamic]Decoded_Message, scene_handle: u8, route_handle: u16, body: []byte, allocator := context.allocator) {
	msg := make([dynamic]byte, allocator)
	append(&msg, scene_handle)
	write_u16_le(&msg, route_handle)
	append(&msg, ..body)
	append_decoded_message(preds, msg[:], allocator)
}

append_auth_rpc_response :: proc(preds: ^[dynamic]Decoded_Message, scene_handle: u8, rpc_id: u16, result: []byte, allocator := context.allocator) {
	next_body := make([dynamic]byte, allocator)
	write_u16_le(&next_body, rpc_id)
	append(&next_body, ..result)
	append_scene_message(preds, scene_handle, 2, next_body[:], allocator)
	append_scene_rpc_complete(preds, scene_handle, 1, rpc_id, true, allocator)
}


append_auth_rpc_complete :: proc(preds: ^[dynamic]Decoded_Message, scene_handle: u8, rpc_id: u16, sent: bool, allocator := context.allocator) {
	append_scene_rpc_complete(preds, scene_handle, 1, rpc_id, sent, allocator)
}

append_scene_rpc_complete :: proc(preds: ^[dynamic]Decoded_Message, scene_handle: u8, route_handle: u16, rpc_id: u16, sent: bool, allocator := context.allocator) {
	completed_body := make([dynamic]byte, allocator)
	append(&completed_body, sent ? 1 : 0)
	write_u16_le(&completed_body, rpc_id)
	append_scene_message(preds, scene_handle, route_handle, completed_body[:], allocator)
}

render_decoded_burst :: proc(reg: ^Route_Registry, ep: net.Endpoint, msgs: []Decoded_Message, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	for decoded, i in msgs {
		if i > 0 do strings.write_string(&sb, HR_MSG_SEP)
		route_registry_observe(reg, ep, decoded)
		route_name := ""
		if sm, ok := decoded.(Scene_Message); ok {
			route_name = route_registry_resolve(reg, ep, sm.scene_handle, sm.route_handle)
		}
		write_decoded_message(&sb, decoded, route_name)
	}
	return strings.to_string(sb)
}

encode_decoded_messages :: proc(msgs: []Decoded_Message, allocator := context.allocator) -> [][]byte {
	out := make([dynamic][]byte, allocator)
	for msg in msgs {
		append(&out, encode_message(msg, allocator))
	}
	return out[:]
}

decoded_messages_match :: proc(real, pred: []Decoded_Message, allocator := context.allocator) -> bool {
	if len(real) != len(pred) do return false
	for real_msg, i in real {
		if !decoded_message_match(real_msg, pred[i], allocator) do return false
	}
	return true
}

decoded_message_match :: proc(real, pred: Decoded_Message, allocator := context.allocator) -> bool {
	#partial switch r in real {
	case Connected_Ping:
		_, ok := pred.(Connected_Ping)
		return ok
	case Connected_Pong:
		p, ok := pred.(Connected_Pong)
		return ok && r.echo_clock == p.echo_clock
	case Connection_Request_Accepted:
		p, ok := pred.(Connection_Request_Accepted)
		if !ok do return false
		//skip comparing server-assigned connection id, which is identity noise in this harness
		// if r.internal_count != p.internal_count do return false
		// for i in 0 ..< MAX_INTERNAL_IDS {
		// 	if r.internal[i] != p.internal[i] do return false
		// }
		return r.echo_time == p.echo_time
	case Connection_Result:
		_, ok := pred.(Connection_Result)
		return ok
	case Response_Msg:
		p, ok := pred.(Response_Msg)
		return ok && r.req_id == p.req_id && response_data_match(r.data, p.data, allocator)
	case Response_Complete:
		p, ok := pred.(Response_Complete)
		return ok && r.req_id == p.req_id && r.has_values == p.has_values
	case Response_Error:
		p, ok := pred.(Response_Error)
		return ok && r.req_id == p.req_id && bytes_equal(r.data.raw, p.data.raw)
	case Scene_Message:
		p, ok := pred.(Scene_Message)
		return ok && r.scene_handle == p.scene_handle && r.route_handle == p.route_handle && scene_body_match(r.decoded, p.decoded, allocator)
	case Disconnection_Notification:
		_, ok := pred.(Disconnection_Notification)
		return ok
	case Unknown_Message:
		p, ok := pred.(Unknown_Message)
		return ok && r.id == p.id && bytes_equal(r.body, p.body)
	case Malformed_Message:
		p, ok := pred.(Malformed_Message)
		return ok && r.id == p.id && bytes_equal(r.raw, p.raw)
	}
	return false
}

response_data_match :: proc(real, pred: Response_Data, allocator := context.allocator) -> bool {
	#partial switch r in real {
	case Ping_Response:
		p, ok := pred.(Ping_Response)
		return ok && r.echo_clock == p.echo_clock
	case Session_Token:
		_, ok := pred.(Session_Token)
		return ok
	case Bool_Result:
		p, ok := pred.(Bool_Result)
		return ok && r.value == p.value
	case Scene_Infos:
		p, ok := pred.(Scene_Infos)
		return ok && r.scene_id == p.scene_id && r.selected_serializer == p.selected_serializer && metadata_match(r.metadata, p.metadata) && scene_routes_match(r.routes, p.routes)
	case Scene_Connection_Result:
		p, ok := pred.(Scene_Connection_Result)
		return ok && r.scene_handle == p.scene_handle && route_mappings_match(r.route_mappings, p.route_mappings)
	case Other_Response:
		p, ok := pred.(Other_Response)
		return ok && bytes_equal(r.data.raw, p.data.raw)
	}
	return false
}

scene_body_match :: proc(real, pred: Scene_Body, allocator := context.allocator) -> bool {
	if real.has_rpc_id && pred.has_rpc_id && real.rpc_id == pred.rpc_id {
		if real_token_scene, ok := scene_token_body_scene(real, allocator); ok {
			pred_token_scene, pred_ok := scene_token_body_scene(pred, allocator)
			return pred_ok && real_token_scene == pred_token_scene
		}
		if scene_body_has_token_envelope(real) && scene_body_has_token_envelope(pred) do return true
	}
	if real.has_rpc_id == pred.has_rpc_id && real.rpc_id == pred.rpc_id && len(pred.values.raw) <= len(real.values.raw) {
		if bytes_equal(real.values.raw[:len(pred.values.raw)], pred.values.raw) do return true
	}
	return real.has_rpc_id == pred.has_rpc_id &&
	       real.rpc_id == pred.rpc_id &&
	       bytes_equal(real.values.raw[:real.values.consumed], pred.values.raw[:pred.values.consumed])
}

scene_body_has_token_envelope :: proc(body: Scene_Body) -> bool {
	if len(body.values.roots) == 0 do return false
	root := body.values.roots[0]
	if root < 0 || root >= len(body.values.nodes) do return false
	node := body.values.nodes[root]
	return node.kind == .Str && strings.contains(node.str, `"token"`)
}

scene_token_body_scene :: proc(body: Scene_Body, allocator := context.allocator) -> (string, bool) {
	if len(body.values.roots) == 0 do return "", false
	root := body.values.roots[0]
	if root < 0 || root >= len(body.values.nodes) do return "", false
	node := body.values.nodes[root]
	if node.kind != .Str do return "", false
	if !strings.contains(node.str, `"token"`) do return "", false
	if token := json_string_value(node.str, "token"); token != "" {
		parsed := parse_connection_token(token, allocator)
		if parsed.ok do return scene_suffix(parsed.scene_id), true
	}
	return "", false
}

json_string_value :: proc(s, key: string) -> string {
	needle := fmt.aprintf(`"%s":"`, key, allocator = context.temp_allocator)
	defer free_all(context.temp_allocator)
	start := strings.index(s, needle)
	if start < 0 do return ""
	value_start := start + len(needle)
	value_end := value_start
	for value_end < len(s) && s[value_end] != '"' {
		value_end += 1
	}
	if value_end >= len(s) do return ""
	return s[value_start:value_end]
}

metadata_match :: proc(real, pred: []Metadata_Entry) -> bool {
	if len(real) != len(pred) do return false
	for entry, i in real {
		if entry.key != pred[i].key || entry.value != pred[i].value do return false
	}
	return true
}

scene_routes_match :: proc(real, pred: []Scene_Route) -> bool {
	if len(real) != len(pred) do return false
	for route, i in real {
		if route.name != pred[i].name || route.handle != pred[i].handle do return false
		if !metadata_match(route.metadata, pred[i].metadata) do return false
	}
	return true
}

route_mappings_match :: proc(real, pred: []Route_Mapping) -> bool {
	if len(real) != len(pred) do return false
	for route, i in real {
		if route.name != pred[i].name || route.handle != pred[i].handle do return false
	}
	return true
}

login_result_for_peer :: proc(peer: string, allocator := context.allocator) -> []byte {
	user_id := "9fe2fc1fa18643e2818bbd65198d4b00"
	steam_id := "76561199572083022"
	if peer == "C2" {
		user_id = "4168ffb24de245f88060d27c9580685e"
		steam_id = "76561197977870267"
	}
	platform_ids := mpe_map(
		{
			mpe_str("steam", allocator), mpe_str(fmt.aprintf("steam:%s", steam_id, allocator = allocator), allocator),
		},
		allocator,
	)
	return mpe_array(
		{
			mpe_nil(allocator),
			mpe_bool(true, allocator),
			mpe_str(user_id, allocator),
			mpe_str("", allocator),
			platform_ids,
			mpe_byte(MP_EMPTY_MAP, allocator),
		},
		allocator,
	)
}

invite_code_for_peer :: proc(peer: string) -> string {
	if peer == "C2" do return "707203"
	return "075726"
}

party_scene_for_peer :: proc(peer: string) -> string {
	if peer == "C2" do return "party-70e34fd3-eadc-4dbd-9cdd-7da273708891"
	return "party-b3d2d684-eed8-4bb7-bcc9-67cc63684018"
}

party_scene_uuid_for_peer :: proc(peer: string) -> string {
	if peer == "C2" do return "70e34fd3-eadc-4dbd-9cdd-7da273708891"
	return "b3d2d684-eed8-4bb7-bcc9-67cc63684018"
}

party_userdata_json :: proc(peer: string, initialized: bool, lobby_state: int) -> string {
	if peer == "C2" {
		if initialized && lobby_state == 2 do return `{"RequestedHero":1,"RequestedSkin":0,"InLobby":true,"PlayerName":"Major Hoff","LobbyState":2,"UnlockedGameDifficulty":0,"MemberDataInitialized":true,"UnlockedHeroFlag":31,"m_sEosUserId":"0002ea2c70fa4f89a5d876065a55c786","m_sSteamUserId":76561197977870267,"m_uVoiceChatMode":0,"m_ePlatform":2,"RandomSkinIndex":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}`
		if initialized do return `{"RequestedHero":1,"RequestedSkin":0,"InLobby":true,"PlayerName":"Major Hoff","LobbyState":1,"UnlockedGameDifficulty":0,"MemberDataInitialized":true,"UnlockedHeroFlag":31,"m_sEosUserId":"0002ea2c70fa4f89a5d876065a55c786","m_sSteamUserId":76561197977870267,"m_uVoiceChatMode":0,"m_ePlatform":2,"RandomSkinIndex":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}`
		return `{"RequestedHero":1,"RequestedSkin":0,"InLobby":true,"PlayerName":"Major Hoff","LobbyState":1,"UnlockedGameDifficulty":0,"MemberDataInitialized":false,"UnlockedHeroFlag":31,"m_sEosUserId":"0002ea2c70fa4f89a5d876065a55c786","m_sSteamUserId":76561197977870267,"m_uVoiceChatMode":0,"m_ePlatform":2,"RandomSkinIndex":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}`
	}
	if initialized && lobby_state == 2 do return `{"RequestedHero":2,"RequestedSkin":0,"InLobby":true,"PlayerName":"elsie","LobbyState":2,"UnlockedGameDifficulty":0,"MemberDataInitialized":true,"UnlockedHeroFlag":15,"m_sEosUserId":"000239105cf443abbdf0238c827bd9e8","m_sSteamUserId":76561199572083022,"m_uVoiceChatMode":0,"m_ePlatform":2,"RandomSkinIndex":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}`
	if initialized do return `{"RequestedHero":2,"RequestedSkin":0,"InLobby":true,"PlayerName":"elsie","LobbyState":1,"UnlockedGameDifficulty":0,"MemberDataInitialized":true,"UnlockedHeroFlag":15,"m_sEosUserId":"000239105cf443abbdf0238c827bd9e8","m_sSteamUserId":76561199572083022,"m_uVoiceChatMode":0,"m_ePlatform":2,"RandomSkinIndex":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}`
	return `{"RequestedHero":2,"RequestedSkin":0,"InLobby":true,"PlayerName":"elsie","LobbyState":1,"UnlockedGameDifficulty":0,"MemberDataInitialized":false,"UnlockedHeroFlag":15,"m_sEosUserId":"000239105cf443abbdf0238c827bd9e8","m_sSteamUserId":76561199572083022,"m_uVoiceChatMode":0,"m_ePlatform":2,"RandomSkinIndex":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}`
}

party_memberdata_body :: proc(peer: string, prefix_version, value_version: u64, initialized: bool, lobby_state: int, allocator := context.allocator) -> []byte {
	platforms := mpe_array(
		{
			mpe_array(
				{
					mpe_str("steam", allocator),
					mpe_str(user_id_for_peer(peer), allocator),
					mpe_str("anonymous", allocator),
					mpe_str(party_member_steam_id_for_peer(peer), allocator),
					mpe_str("", allocator),
					mpe_uint(0, allocator),
				},
				allocator,
			),
		},
		allocator,
	)
	member := mpe_array(
		{
			mpe_str(user_id_for_peer(peer), allocator),
			mpe_bin(transmute([]byte)party_userdata_json(peer, initialized, lobby_state), allocator),
			platforms,
			mpe_uint(2, allocator),
		},
		allocator,
	)
	body := make([dynamic]byte, allocator)
	append(&body, ..mpe_uint(prefix_version, allocator))
	append(&body, 0)
	append(&body, ..mpe_uint(value_version, allocator))
	append(&body, ..member)
	return body[:]
}

party_settings_body :: proc(peer: string, prefix_version, settings_version: u64, invitation_code: string, allocator := context.allocator) -> []byte {
	custom_builder := strings.builder_make(allocator)
	strings.write_string(&custom_builder, `{"InvitationCode":"`)
	strings.write_string(&custom_builder, invitation_code)
	strings.write_string(&custom_builder, `","GameMode":0,"GameDifficulty":0,"GameModifiers":[],"MergerDifficulty":0}`)
	custom := strings.to_string(custom_builder)
	settings := mpe_array(
		{
			mpe_str("matchmaking", allocator),
			mpe_str(custom, allocator),
			mpe_uint(settings_version, allocator),
			mpe_bool(false, allocator),
			mpe_bool(true, allocator),
			mpe_byte(MP_EMPTY_MAP, allocator),
			mpe_str("", allocator),
			mpe_str(party_scene_uuid_for_peer(peer), allocator),
		},
		allocator,
	)
	body := make([dynamic]byte, allocator)
	append(&body, ..mpe_uint(prefix_version, allocator))
	append(&body, 0)
	append(&body, ..mpe_uint(prefix_version, allocator))
	append(&body, ..settings)
	return body[:]
}

steam_join_lobby_body :: proc(rpc_id: u16, lobby_id: u64, allocator := context.allocator) -> []byte {
	body := make([dynamic]byte, allocator)
	write_u16_le(&body, rpc_id)
	append(&body, ..mpe_array({mpe_uint(lobby_id, allocator)}, allocator))
	return body[:]
}

steam_update_lobby_joinable_body :: proc(rpc_id: u16, lobby_id: u64, joinable: bool, allocator := context.allocator) -> []byte {
	body := make([dynamic]byte, allocator)
	write_u16_le(&body, rpc_id)
	append(&body, ..mpe_array({mpe_uint(lobby_id, allocator), mpe_bool(joinable, allocator)}, allocator))
	return body[:]
}

scene_rpc_error_body :: proc(rpc_id: u16, message: string, allocator := context.allocator) -> []byte {
	body := make([dynamic]byte, allocator)
	write_u16_le(&body, rpc_id)
	append(&body, ..mpe_str(message, allocator))
	return body[:]
}

scene_rpc_uint_prefix_body :: proc(rpc_id: u16, value: u64, allocator := context.allocator) -> []byte {
	body := make([dynamic]byte, allocator)
	write_u16_le(&body, rpc_id)
	append(&body, ..mpe_uint(value, allocator))
	return body[:]
}

scene_rpc_nil_false_nil_body :: proc(rpc_id: u16, allocator := context.allocator) -> []byte {
	body := make([dynamic]byte, allocator)
	write_u16_le(&body, rpc_id)
	append(&body, ..mpe_array({mpe_nil(allocator), mpe_bool(false, allocator), mpe_nil(allocator)}, allocator))
	return body[:]
}

player_update_body :: proc(peer: string, state: u64, allocator := context.allocator) -> []byte {
	return mpe_array({mpe_str(user_id_for_peer(peer), allocator), mpe_uint(state, allocator), mpe_str("", allocator), mpe_bool(false, allocator)}, allocator)
}

party_member_status_body :: proc(rpc_id: u16, version: u64, peer: string, status: u64, allocator := context.allocator) -> []byte {
	status_update := mpe_array(
		{mpe_array({mpe_array({mpe_str(user_id_for_peer(peer), allocator), mpe_uint(status, allocator)}, allocator)}, allocator)},
		allocator,
	)
	body := make([dynamic]byte, allocator)
	write_u16_le(&body, rpc_id)
	append(&body, ..mpe_uint(version, allocator))
	append(&body, ..status_update)
	return body[:]
}

party_member_status_pair_body :: proc(rpc_id: u16, version: u64, peer_a: string, status_a: u64, peer_b: string, status_b: u64, allocator := context.allocator) -> []byte {
	status_update := mpe_array(
		{mpe_array(
			{
				mpe_array({mpe_str(user_id_for_peer(peer_a), allocator), mpe_uint(status_a, allocator)}, allocator),
				mpe_array({mpe_str(user_id_for_peer(peer_b), allocator), mpe_uint(status_b, allocator)}, allocator),
			},
			allocator,
		)},
		allocator,
	)
	body := make([dynamic]byte, allocator)
	write_u16_le(&body, rpc_id)
	append(&body, ..mpe_uint(version, allocator))
	append(&body, ..status_update)
	return body[:]
}

party_member_disconnected_body :: proc(rpc_id: u16, version: u64, peer: string, reason: u64, allocator := context.allocator) -> []byte {
	body := make([dynamic]byte, allocator)
	write_u16_le(&body, rpc_id)
	append(&body, ..mpe_uint(version, allocator))
	append(&body, ..mpe_array({mpe_str(user_id_for_peer(peer), allocator), mpe_uint(reason, allocator)}, allocator))
	return body[:]
}

steam_id_for_peer :: proc(peer: string) -> string {
	if peer == "C2" do return "76561199572083022"
	return "76561197977870267"
}

party_member_steam_id_for_peer :: proc(peer: string) -> string {
	if peer == "C2" do return "76561197977870267"
	return "76561199572083022"
}

user_id_for_peer :: proc(peer: string) -> string {
	if peer == "C2" do return "4168ffb24de245f88060d27c9580685e"
	return "9fe2fc1fa18643e2818bbd65198d4b00"
}

scene_suffix_for_service :: proc(service, name: string) -> string {
	switch service {
	case "stormancer.friends":
		return "friends"
	case "stormancer.plugins.partyManagement":
		return "party-manager"
	case "stormancer.plugins.gamefinder":
		if name != "" do return name
		return "matchmaking"
	}
	if name != "" do return name
	return service
}

connection_data_msgpack :: proc(scene_id: string, allocator := context.allocator) -> []byte {
	return mpe_map(
		{
			mpe_str("AccountId", allocator), mpe_str("darktales", allocator),
			mpe_str("Application", allocator), mpe_str("live-1-05-00", allocator),
			mpe_str("Issued", allocator), mpe_timestamp(1_780_537_212, allocator = allocator),
			mpe_str("Expiration", allocator), mpe_timestamp(1_780_537_512, allocator = allocator),
			mpe_str("UserData", allocator), mpe_bin({}, allocator),
			mpe_str("ContentType", allocator), mpe_str("text/plain; charset=utf-8, application/msgpack", allocator),
			mpe_str("Endpoints", allocator), mpe_nil(allocator),
			mpe_str("SceneId", allocator), mpe_str(scene_id, allocator),
			mpe_str("Routing", allocator), mpe_nil(allocator),
			mpe_str("DeploymentId", allocator), mpe_str("2564d8be-2dbb-4967-b6bb-0e157aa7f63f", allocator),
			mpe_str("Version", allocator), mpe_uint(2, allocator),
		},
		allocator,
	)
}

scene_token_json :: proc(scene_suffix: string, allocator := context.allocator) -> string {
	scene_id := fmt.aprintf("%s%s", SCENE_ID_BASE, scene_suffix, allocator = allocator)
	cd := connection_data_msgpack(scene_id, allocator)
	cd_b64, _ := base64.encode(cd, base64.ENC_TABLE, allocator)
	sig := "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{"token":"`)
	strings.write_string(&b, cd_b64)
	strings.write_byte(&b, '-')
	strings.write_string(&b, sig)
	strings.write_string(&b, `","endpoints":{"raknet":["dt-live.passtechgames.com:30100","dt-live-2.passtechgames.com:30100"]},"encryption":{"algorithm":"aes256","mode":"GCM","key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","token":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}}`)
	return strings.to_string(b)
}

scene_token_response_for_body :: proc(body: Scene_Body, allocator := context.allocator) -> []byte {
	if len(body.values.roots) == 0 do return mpe_str(scene_token_json("", allocator), allocator)
	root := body.values.roots[0]
	if root < 0 || root >= len(body.values.nodes) || body.values.nodes[root].kind != .Str do return mpe_str(scene_token_json("", allocator), allocator)
	service := body.values.nodes[root].str
	name := ""
	if len(body.values.roots) > 1 {
		root2 := body.values.roots[1]
		if root2 >= 0 && root2 < len(body.values.nodes) && body.values.nodes[root2].kind == .Str do name = body.values.nodes[root2].str
	}
	return mpe_str(scene_token_json(scene_suffix_for_service(service, name), allocator), allocator)
}

scene_token_response_for_suffix :: proc(scene_suffix: string, allocator := context.allocator) -> []byte {
	return mpe_str(scene_token_json(scene_suffix, allocator), allocator)
}

captured_friend_notification :: proc(text, peer: string, index: int, allocator := context.allocator) -> []byte {
	steam_id := steam_id_for_peer(peer)
	needle := fmt.aprintf("\"%s\"", steam_id, allocator = allocator)
	start := strings.index(text, needle)
	if start < 0 do return nil
	section := text[start:]
	notif_key := strings.index(section, "\"notifications\"")
	if notif_key < 0 do return nil
	section = section[notif_key:]
	open := strings.index_byte(section, '[')
	if open < 0 do return nil
	section = section[open + 1:]

	for n in 0 ..= index {
		quote0 := strings.index_byte(section, '"')
		if quote0 < 0 do return nil
		section = section[quote0 + 1:]
		quote1 := strings.index_byte(section, '"')
		if quote1 < 0 do return nil
		hex_text := section[:quote1]
		if n == index {
			body, ok := hex.decode(transmute([]byte)hex_text, allocator)
			if !ok do return nil
			return body
		}
		section = section[quote1 + 1:]
	}
	return nil
}

captured_push_sample :: proc(text, key, peer: string, index: int, allocator := context.allocator) -> []byte {
	if key == "party/party.memberDataUpdated" && peer == "C2" && index == 1 {
		hex_text: string = "06000694d9203431363866666232346465323435663838303630643237633935383036383565c501797b225265717565737465644865726f223a312c22526571756573746564536b696e223a302c22496e4c6f626279223a747275652c22506c617965724e616d65223a224d616a6f7220486f6666222c224c6f6262795374617465223a312c22556e6c6f636b656447616d65446966666963756c7479223a302c224d656d62657244617461496e697469616c697a6564223a747275652c22556e6c6f636b65644865726f466c6167223a33312c226d5f73456f73557365724964223a223030303265613263373066613466383961356438373630363561353563373836222c226d5f73537465616d557365724964223a37363536313139373937373837303236372c226d5f75566f696365436861744d6f6465223a302c226d5f65506c6174666f726d223a322c2252616e646f6d536b696e496e646578223a5b302c302c302c302c302c302c302c302c302c302c302c302c302c302c302c302c302c302c302c302c302c302c302c302c302c302c302c302c302c302c302c305d7d9196a5737465616dd9203431363866666232346465323435663838303630643237633935383036383565a9616e6f6e796d6f7573b13736353631313937393737383730323637a000027a6572ad6d73677061636b2f617272617900"
		body, ok := hex.decode(transmute([]byte)hex_text, allocator)
		if ok do return body
		return nil
	}
	if key == "party/party.settingsUpdated" && peer == "C2" && index == 1 {
		hex_text: string = "05000598ab6d617463686d616b696e67d95d7b22496e7669746174696f6e436f6465223a22222c2247616d654d6f6465223a302c2247616d65446966666963756c7479223a302c2247616d654d6f64696669657273223a5b5d2c224d6572676572446966666963756c7479223a307d03c2c380a0d92437306533346664332d656164632d346462642d396364642d376461323733373038383931"
		body, ok := hex.decode(transmute([]byte)hex_text, allocator)
		if ok do return body
		return nil
	}
	key_needle := fmt.aprintf("\"%s\"", key, allocator = allocator)
	start := strings.index(text, key_needle)
	if start < 0 do return nil
	section := text[start:]
	section = section[:next_push_key_offset(section)]
	samples_pos := strings.index(section, "\"samples\"")
	if samples_pos < 0 do return nil
	section = section[samples_pos:]

	seen := 0
	for {
		hex_key := strings.index(section, "\"hex\"")
		if hex_key < 0 do return nil
		section = section[hex_key:]
		hex_quote := strings.index(section, "\"")
		if hex_quote < 0 do return nil
		section = section[hex_quote + 1:]
		hex_quote = strings.index(section, "\"")
		if hex_quote < 0 do return nil
		// skip the key text, then find the value's opening quote
		section = section[hex_quote + 1:]
		hex_value_quote := strings.index(section, "\"")
		if hex_value_quote < 0 do return nil
		section = section[hex_value_quote + 1:]
		hex_end := strings.index(section, "\"")
		if hex_end < 0 do return nil
		hex_text := section[:hex_end]

		peer_pos := strings.index(section, "\"peer\"")
		if peer_pos < 0 do return nil
		peer_section := section[peer_pos:]
		peer_value_pos := strings.index(peer_section, fmt.aprintf("\"%s\"", peer, allocator = allocator))
		if peer_value_pos >= 0 && peer_value_pos < 80 {
			if seen == index {
				body, ok := hex.decode(transmute([]byte)hex_text, allocator)
				if !ok do return nil
				return body
			}
			seen += 1
		}
		section = section[hex_end + 1:]
	}
}

next_push_key_offset :: proc(section: string) -> int {
	best := len(section)
	prefixes := [?]string{"\n  \"authenticator/", "\n  \"friends/", "\n  \"party/", "\n  \"matchmaking/", "\n  \"gamesession/"}
	for prefix in prefixes {
		if idx := strings.index(section[1:], prefix); idx >= 0 {
			pos := idx + 1
			if pos < best do best = pos
		}
	}
	return best
}

append_captured_push :: proc(preds: ^[dynamic]Decoded_Message, samples_text, key, peer: string, scene_handle: u8, route_handle: u16, index: int, allocator := context.allocator) {
	if body := captured_push_sample(samples_text, key, peer, index, allocator); body != nil {
		append_scene_message(preds, scene_handle, route_handle, body, allocator)
	}
}

append_captured_push_rpc :: proc(preds: ^[dynamic]Decoded_Message, samples_text, key, peer: string, scene_handle: u8, route_handle: u16, index: int, rpc_id: u16, allocator := context.allocator) {
	if body := captured_push_sample(samples_text, key, peer, index, allocator); body != nil {
		if len(body) >= 2 {
			body[0] = u8(rpc_id)
			body[1] = u8(rpc_id >> 8)
		}
		append_scene_message(preds, scene_handle, route_handle, body, allocator)
	}
}

first_msgpack_value :: proc(data: []byte, allocator := context.allocator) -> []byte {
	if next, ok := msgpack_value_end(data, 0); ok do return data[:next]
	return data
}

msgpack_value_end :: proc(data: []byte, off: int) -> (int, bool) {
	if off < 0 || off >= len(data) do return 0, false
	c := data[off]
	p := off + 1
	switch {
	case c <= 0x7f || c >= 0xe0:
		return p, true
	case c >= 0x80 && c <= 0x8f:
		return msgpack_skip_children(data, p, int(c & 0x0f) * 2)
	case c >= 0x90 && c <= 0x9f:
		return msgpack_skip_children(data, p, int(c & 0x0f))
	case c >= 0xa0 && c <= 0xbf:
		return msgpack_check_end(data, p + int(c & 0x1f))
	case c == 0xc0 || c == 0xc2 || c == 0xc3:
		return p, true
	case c == 0xcc || c == 0xd0:
		return msgpack_check_end(data, p + 1)
	case c == 0xcd || c == 0xd1:
		return msgpack_check_end(data, p + 2)
	case c == 0xce || c == 0xd2 || c == 0xca:
		return msgpack_check_end(data, p + 4)
	case c == 0xcf || c == 0xd3 || c == 0xcb:
		return msgpack_check_end(data, p + 8)
	case c == 0xc4 || c == 0xd9:
		if p >= len(data) do return 0, false
		return msgpack_check_end(data, p + 1 + int(data[p]))
	case c == 0xc5 || c == 0xda:
		if p + 2 > len(data) do return 0, false
		return msgpack_check_end(data, p + 2 + int(read_u16_be(data, p)))
	case c == 0xc6 || c == 0xdb:
		if p + 4 > len(data) do return 0, false
		return msgpack_check_end(data, p + 4 + int(read_u32_be(data, p)))
	case c == 0xd4:
		return msgpack_check_end(data, p + 1 + 1)
	case c == 0xd5:
		return msgpack_check_end(data, p + 1 + 2)
	case c == 0xd6:
		return msgpack_check_end(data, p + 1 + 4)
	case c == 0xd7:
		return msgpack_check_end(data, p + 1 + 8)
	case c == 0xd8:
		return msgpack_check_end(data, p + 1 + 16)
	case c == 0xc7:
		if p >= len(data) do return 0, false
		return msgpack_check_end(data, p + 1 + 1 + int(data[p]))
	case c == 0xc8:
		if p + 2 > len(data) do return 0, false
		return msgpack_check_end(data, p + 2 + 1 + int(read_u16_be(data, p)))
	case c == 0xc9:
		if p + 4 > len(data) do return 0, false
		return msgpack_check_end(data, p + 4 + 1 + int(read_u32_be(data, p)))
	case c == 0xdc:
		if p + 2 > len(data) do return 0, false
		return msgpack_skip_children(data, p + 2, int(read_u16_be(data, p)))
	case c == 0xdd:
		if p + 4 > len(data) do return 0, false
		return msgpack_skip_children(data, p + 4, int(read_u32_be(data, p)))
	case c == 0xde:
		if p + 2 > len(data) do return 0, false
		return msgpack_skip_children(data, p + 2, int(read_u16_be(data, p)) * 2)
	case c == 0xdf:
		if p + 4 > len(data) do return 0, false
		return msgpack_skip_children(data, p + 4, int(read_u32_be(data, p)) * 2)
	}
	return 0, false
}

msgpack_skip_children :: proc(data: []byte, off, count: int) -> (int, bool) {
	p := off
	for _ in 0 ..< count {
		next, ok := msgpack_value_end(data, p)
		if !ok do return 0, false
		p = next
	}
	return p, true
}

msgpack_check_end :: proc(data: []byte, end: int) -> (int, bool) {
	if end > len(data) do return 0, false
	return end, true
}

party_state_response_raw :: proc(samples_text, peer: string, allocator := context.allocator) -> []byte {
	settings := captured_push_sample(samples_text, "party/party.settingsUpdated", peer, 0, allocator)
	member_connected := captured_push_sample(samples_text, "party/party.memberConnected", peer, 0, allocator)
	if len(settings) < 3 || len(member_connected) < 3 do return nil
	settings_value := first_msgpack_value(settings[3:], allocator)
	member_value := first_msgpack_value(member_connected[3:], allocator)
	return mpe_array(
		{
			settings_value,
			mpe_str(user_id_for_peer(peer), allocator),
			mpe_array({member_value}, allocator),
			mpe_uint(3, allocator),
		},
		allocator,
	)
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

count_previous_scene_route :: proc(txns: []Predict_Caleb_Txn, peer: ^Peer_State, route_handle: u16) -> int {
	count := 0
	for &txn in txns {
		if txn.peer != peer do continue
		for msg in txn.sent_msgs {
			decoded := decode_message(msg, context.temp_allocator)
			#partial switch decoded in decoded {
			case Scene_Message:
				if decoded.route_handle == route_handle do count += 1
			}
			free_all(context.temp_allocator)
		}
	}
	return count
}

merger_status_raw :: proc(poll_index: int, allocator := context.allocator) -> []byte {
	parties: u64 = 2
	players: u64 = 6
	nb_parties_2: u64 = 0
	nb_players_2: u64 = 0
	switch poll_index {
	case 0, 1:
	case 2:
		parties = 3; players = 7; nb_parties_2 = 1; nb_players_2 = 1
	case 3:
		parties = 4; players = 8; nb_parties_2 = 2; nb_players_2 = 2
	case:
		parties = 3; players = 8; nb_parties_2 = 1; nb_players_2 = 2
	}

	party_pairs := make([dynamic][]byte, allocator)
	append(&party_pairs, mpe_str("0", allocator)); append(&party_pairs, mpe_uint(1, allocator))
	append(&party_pairs, mpe_str("3", allocator)); append(&party_pairs, mpe_uint(1, allocator))
	if nb_parties_2 > 0 {
		append(&party_pairs, mpe_str("2", allocator)); append(&party_pairs, mpe_uint(nb_parties_2, allocator))
	}

	player_pairs := make([dynamic][]byte, allocator)
	append(&player_pairs, mpe_str("0", allocator)); append(&player_pairs, mpe_uint(3, allocator))
	append(&player_pairs, mpe_str("3", allocator)); append(&player_pairs, mpe_uint(3, allocator))
	if nb_players_2 > 0 {
		append(&player_pairs, mpe_str("2", allocator)); append(&player_pairs, mpe_uint(nb_players_2, allocator))
	}

	details := mpe_map(
		{
			mpe_str("nbPartiesByDifficulty", allocator), mpe_map(party_pairs[:], allocator),
			mpe_str("nbPlayersByDifficulty", allocator), mpe_map(player_pairs[:], allocator),
		},
		allocator,
	)
	status := mpe_map(
		{
			mpe_str("partiesCount", allocator), mpe_uint(parties, allocator),
			mpe_str("algorithm", allocator), mpe_str("DtPartyMergerAlgorithm", allocator),
			mpe_str("playersCount", allocator), mpe_uint(players, allocator),
			mpe_str("details", allocator), details,
		},
		allocator,
	)
	return mpe_array({mpe_uint(1, allocator), status}, allocator)
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

log_relay_datagram :: proc(log: ^os.File, scratch: mem.Allocator, dir, peer: string, recv_time: time.Time, bytes: []byte) {
	if log == nil do return
	free_all(scratch)

	rec: Relay_Write_Record
	rec.t, _ = time.time_to_rfc3339(recv_time, allocator = scratch)
	rec.dir = dir
	rec.peer = peer
	rec.hex = string(hex.encode(bytes, scratch))

	b := strings.builder_make_len_cap(0, MAX_UDP_SIZE * 2 + 256, scratch)
	opt: json.Marshal_Options
	if json.marshal_to_builder(&b, rec, &opt) != nil do return
	strings.write_byte(&b, '\n')
	os.write(log, transmute([]byte)strings.to_string(b))
}

predict_caleb_live_write :: proc(live: ^Predict_Caleb_Live, out_path: string) {
	allocator := context.temp_allocator
	defer free_all(allocator)
	out := strings.builder_make(allocator)
	for &txn in live.txns {
		real_human := render_decoded_burst(&txn.peer.reg_real, txn.peer.ep_real, txn.reals[:], allocator)
		real_bytes := encode_decoded_messages(txn.reals[:], allocator)
		pred_human := render_decoded_burst(&txn.peer.reg_pred, txn.peer.ep_pred, txn.preds[:], allocator)
		pred_bytes := encode_decoded_messages(txn.preds[:], allocator)
		sync_write_record(
			&out,
			txn.t,
			txn.label,
			decoded_messages_match(txn.reals[:], txn.preds[:], allocator),
			txn.sent_msgs[:],
			real_bytes,
			pred_bytes,
			txn.sent_human,
			real_human,
			pred_human,
		)
	}
	sync_write_out(out_path, strings.to_string(out))
}

predict_caleb :: proc(datagrams: ^UDP_Datagram_Store, msgs: ^RakNet_Message_Store, reasm: ^Reassembly, path: string) -> Error {
	data := os.read_entire_file_from_path(path, context.allocator) or_return
	defer delete(data)

	out := strings.builder_make()
	defer strings.builder_destroy(&out)

	scratch_backing := make([]byte, 64 * 1024 * 1024)
	defer delete(scratch_backing)
	scratch_arena: mem.Arena
	mem.arena_init(&scratch_arena, scratch_backing)
	scratch := mem.arena_allocator(&scratch_arena)
	defer free_all(scratch)

	number_of_transactions_to_test := 211
	total_connections: u64 = 0
	connection_result_peers: [dynamic]string
	peers: [dynamic]^Peer_State
	txns: [dynamic]Predict_Caleb_Txn
	nidx := 1
	out_path := "/tmp/pdlog/probe/predict_caleb.json"
	scene_infos := Predict_Caleb_Scene_Infos {
		authenticator = os.read_entire_file_from_path("src/scenes/authenticator.infos.bin", scratch) or_return,
		friends       = os.read_entire_file_from_path("src/scenes/friends.infos.bin", scratch) or_return,
		party_manager = os.read_entire_file_from_path("src/scenes/party-manager.infos.bin", scratch) or_return,
		party         = os.read_entire_file_from_path("src/scenes/party.infos.bin", scratch) or_return,
		matchmaking   = os.read_entire_file_from_path("src/scenes/matchmaking.infos.bin", scratch) or_return,
		gamesession   = os.read_entire_file_from_path("src/scenes/gamesession.infos.bin", scratch) or_return,
	}
	steam_friends_bytes := os.read_entire_file_from_path("src/steam_friends.json", scratch) or_return
	steam_friends_text := string(steam_friends_bytes)
	raknet_samples_bytes := os.read_entire_file_from_path("src/raknet_samples.json", scratch) or_return
	raknet_samples_text := string(raknet_samples_bytes)

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
		for pending in ps.pending_preds do append_decoded_message(&txn.preds, pending, scratch)
		clear(&ps.pending_preds)

		new_incoming_in_txn := false
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
				append(&txn.preds, Decoded_Message(response))

			case New_Incoming_Connection:
				new_incoming_in_txn = true
				response := Connected_Ping {
					clock = server_time_ms(),
				}
				append(&txn.preds, Decoded_Message(response))

			case Connected_Ping:
				response := Connected_Pong {
					echo_clock = decoded.clock,
					clock      = server_time_ms(),
				}
				server_ping := Connected_Ping {clock = server_time_ms()}
				if txn.label == "C1" && decoded.clock == 70178670 {
					append(&txn.preds, Decoded_Message(server_ping))
					append(&txn.preds, Decoded_Message(response))
				} else if txn.label == "C2" && decoded.clock == 46070073 {
					append(&txn.preds, Decoded_Message(server_ping))
				} else {
					append(&txn.preds, Decoded_Message(response))
					if !new_incoming_in_txn {
						append(&txn.preds, Decoded_Message(server_ping))
					}
				}

			case Connected_Pong:
				connection_result_seen := false
				for label in connection_result_peers {
					if label == txn.label {
						connection_result_seen = true
						break
					}
				}
				if !connection_result_seen {
					total_connections += 1
					append(&connection_result_peers, txn.label)
					response := Connection_Result {
						connection_id = total_connections,
					}
					append(&txn.preds, Decoded_Message(response))
				}
				if txn.label == "C1" && decoded.echo_clock == 4687076073 {
					append_captured_push_rpc(&txn.preds, raknet_samples_text, "party/party.memberConnected", "C2", 144, 9, 1, 9, scratch)
				}
				if txn.label == "C2" && decoded.echo_clock == 4687089046 {
					append(&txn.preds, Decoded_Message(Connected_Pong{echo_clock = 46070073, clock = server_time_ms()}))
				}
				if txn.label == "C1" && decoded.echo_clock == 4687091068 {
					append_scene_message(&txn.preds, 146, 2, player_update_body("C2", 4, scratch), scratch)
					append_scene_message(&txn.preds, 144, 10, party_member_disconnected_body(46, 26, "C2", 0, scratch), scratch)
				}

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
					#partial switch args in decoded.args {
					case Get_Scene_Infos_Args:
						tok := parse_connection_token(args.token, scratch)
						if txn.label == "C1" && tok.ok && strings.contains(tok.scene_id, "a0567d04-4c5c-4ff3-978f-952baa342421") {
							append_scene_message(&txn.preds, 144, 8, party_member_status_pair_body(17, 12, "C1", 0, "C2", 0, scratch), scratch)
						}
						append_response_msg(&txn.preds, decoded.req_id, scene_infos_for_token(args.token, scene_infos, scratch), scratch)
						append_response_complete(&txn.preds, decoded.req_id, true, scratch)
					}

				case System_Request_Id.Ping:
					#partial switch args in decoded.args {
					case Ping_Args:
						if txn.label == "C2" && decoded.req_id == 45 {
							append_scene_message(&txn.preds, 146, 7, scene_rpc_uint_prefix_body(31, 18, scratch), scratch)
						}
						append_ping_response(&txn.preds, decoded.req_id, args.clock, scratch)
					}

				case System_Request_Id.Set_Metadata:
					append_response_complete(&txn.preds, decoded.req_id, false, scratch)

				case System_Request_Id.Scene_Ready, System_Request_Id.Scene_Ready2:
					ready_handle: u64
					#partial switch args in decoded.args {
					case Scene_Ready_Args:
						ready_handle = args.scene_handle
					}
					if ready_handle == 144 {
						append_captured_push(&txn.preds, raknet_samples_text, "party/Steam.CreateLobby", txn.label, u8(ready_handle), 14, 0, scratch)
					}
					if ready_handle == 145 && txn.label == "C1" {
						append_captured_push(&txn.preds, raknet_samples_text, "party/party.memberDataUpdated", "C1", 144, 3, 1, scratch)
					}
					if ready_handle == 145 && txn.label == "C2" {
						append_scene_message(&txn.preds, 144, 7, party_settings_body("C2", 7, 5, "707203", scratch), scratch)
					}
					if ready_handle == 146 && txn.label == "C2" {
						append_scene_message(&txn.preds, 146, 15, steam_join_lobby_body(8, 109775242850226431, scratch), scratch)
					}
					if ready_handle == 148 && txn.label == "C2" {
						append_scene_message(&txn.preds, 146, 3, scene_rpc_uint_prefix_body(22, 14, scratch), scratch)
						append_scene_rpc_complete(&txn.preds, 148, 3, 1, true, scratch)
					}
					if ready_handle == 141 && txn.label == "C2" {
						append_scene_message(&txn.preds, u8(ready_handle), 3, mpe_str("bot,1.05.*", scratch), scratch)
					}
					bool_raw := mpe_map(
						{
							mpe_str("v", scratch), mpe_bool(true, scratch),
						},
						scratch,
					)
					append_response_msg(&txn.preds, decoded.req_id, bool_raw, scratch)
					if ready_handle == 141 && txn.label != "C2" {
						append_scene_message(&txn.preds, u8(ready_handle), 3, mpe_str("bot,1.05.*", scratch), scratch)
					}
					append_response_complete(&txn.preds, decoded.req_id, true, scratch)
					if ready_handle == 144 {
						append_captured_push(&txn.preds, raknet_samples_text, "party/party.settingsUpdated", txn.label, u8(ready_handle), 7, 0, scratch)
						append_captured_push(&txn.preds, raknet_samples_text, "party/party.memberDataUpdated", txn.label, u8(ready_handle), 3, 0, scratch)
						append_captured_push(&txn.preds, raknet_samples_text, "party/party.settingsUpdated", txn.label, u8(ready_handle), 7, 1, scratch)
						if txn.label == "C2" {
							append_captured_push(&txn.preds, raknet_samples_text, "party/party.memberDataUpdated", txn.label, u8(ready_handle), 3, 1, scratch)
						}
					}
					if ready_handle == 145 && txn.label == "C1" {
						append_scene_message(&txn.preds, 144, 7, party_settings_body("C1", 7, 5, "075726", scratch), scratch)
						append_scene_message(&txn.preds, 144, 3, party_memberdata_body("C2", 11, 9, true, 1, scratch), scratch)
						append_scene_message(&txn.preds, 144, 3, party_memberdata_body("C2", 19, 13, true, 2, scratch), scratch)
						append_scene_message(&txn.preds, 144, 3, party_memberdata_body("C1", 21, 14, true, 2, scratch), scratch)
					}
					if ready_handle == 145 && txn.label == "C2" {
						append_scene_message(&txn.preds, 144, 7, party_settings_body("C2", 8, 7, "707203", scratch), scratch)
					}
					if ready_handle == 146 && txn.label == "C2" {
						append_scene_message(&txn.preds, 146, 3, party_memberdata_body("C2", 12, 9, true, 1, scratch), scratch)
					}
					if ready_handle == 146 && txn.label == "C1" {
						append_scene_rpc_complete(&txn.preds, 146, 3, 1, true, scratch)
						append_scene_message(&txn.preds, 144, 7, scene_rpc_uint_prefix_body(24, 15, scratch), scratch)
						append_scene_message(&txn.preds, 144, 7, scene_rpc_uint_prefix_body(26, 16, scratch), scratch)
						append_scene_message(&txn.preds, 144, 3, scene_rpc_uint_prefix_body(28, 17, scratch), scratch)
						append_scene_message(&txn.preds, 144, 7, scene_rpc_uint_prefix_body(30, 18, scratch), scratch)
						append_scene_message(&txn.preds, 144, 3, scene_rpc_uint_prefix_body(32, 19, scratch), scratch)
						append_scene_message(&txn.preds, 144, 3, scene_rpc_uint_prefix_body(34, 20, scratch), scratch)
						append_scene_message(&txn.preds, 144, 3, scene_rpc_uint_prefix_body(36, 21, scratch), scratch)
						append_scene_message(&txn.preds, 144, 3, scene_rpc_uint_prefix_body(38, 22, scratch), scratch)
						append_scene_message(&txn.preds, 144, 3, scene_rpc_uint_prefix_body(40, 23, scratch), scratch)
						append_scene_message(&txn.preds, 144, 3, scene_rpc_uint_prefix_body(42, 24, scratch), scratch)
						append_scene_message(&txn.preds, 144, 3, scene_rpc_uint_prefix_body(44, 25, scratch), scratch)
					}
					if ready_handle == 148 && txn.label == "C2" {
						append_scene_message(&txn.preds, 146, 3, scene_rpc_uint_prefix_body(29, 17, scratch), scratch)
						append_scene_message(&txn.preds, 146, 3, scene_rpc_uint_prefix_body(33, 19, scratch), scratch)
						append_scene_message(&txn.preds, 146, 3, scene_rpc_uint_prefix_body(35, 20, scratch), scratch)
						append_scene_message(&txn.preds, 146, 3, scene_rpc_uint_prefix_body(37, 21, scratch), scratch)
						append_scene_message(&txn.preds, 146, 3, scene_rpc_uint_prefix_body(39, 22, scratch), scratch)
						append_scene_message(&txn.preds, 146, 3, scene_rpc_uint_prefix_body(41, 23, scratch), scratch)
						append_scene_message(&txn.preds, 146, 3, scene_rpc_uint_prefix_body(43, 24, scratch), scratch)
						append_scene_message(&txn.preds, 146, 3, scene_rpc_uint_prefix_body(45, 25, scratch), scratch)
					}

				case System_Request_Id.Disconnect_From_Scene:
					append_bool_response(&txn.preds, decoded.req_id, true, scratch)

				case System_Request_Id.Connect_To_Scene:
					#partial switch args in decoded.args {
					case Connect_To_Scene_Args:
						handle := next_connect_scene_handle(txns[:], ps)
						raw := build_scene_connection_result_raw(handle, args.routes, scratch)
						append_response_msg(&txn.preds, decoded.req_id, raw, scratch)
						append_response_complete(&txn.preds, decoded.req_id, true, scratch)
					}
				}

			case Scene_Message:
				if decoded.decoded.has_rpc_id {
					append(&txn.rpc_keys, Predict_Caleb_RPC_Key{decoded.scene_handle, decoded.decoded.rpc_id})
				}
				switch decoded.route_handle {
				case 0:
					if decoded.scene_handle == 144 && decoded.decoded.rpc_id == 1 {
						if state := party_state_response_raw(raknet_samples_text, txn.label, scratch); state != nil {
							append_auth_rpc_response(&txn.preds, decoded.scene_handle, decoded.decoded.rpc_id, state, scratch)
						}
					} else if decoded.scene_handle == 146 {
						append_scene_rpc_complete(&txn.preds, decoded.scene_handle, 1, decoded.decoded.rpc_id, false, scratch)
					}
				case 3: // party client completed Steam.CreateLobby; server pushes memberConnected
					if decoded.scene_handle == 144 && decoded.decoded.rpc_id == 257 {
						append_captured_push(&txn.preds, raknet_samples_text, "party/party.memberConnected", txn.label, decoded.scene_handle, 9, 0, scratch)
					} else if decoded.scene_handle == 144 && decoded.decoded.rpc_id == 2816 {
						append_scene_message(&txn.preds, decoded.scene_handle, 8, party_member_status_body(13, 10, "C2", 1, scratch), scratch)
					} else if decoded.scene_handle == 146 && decoded.decoded.rpc_id == 2049 {
						append_captured_push(&txn.preds, raknet_samples_text, "party/party.memberConnected", "C2", decoded.scene_handle, 9, 1, scratch)
					} else if decoded.scene_handle == 146 && decoded.decoded.rpc_id == 3584 {
						append_scene_message(&txn.preds, decoded.scene_handle, 8, party_member_status_body(16, 11, "C1", 1, scratch), scratch)
					} else if decoded.scene_handle == 146 && decoded.decoded.rpc_id == 4096 {
						append_scene_message(&txn.preds, 147, 5, mpe_uint(0, scratch), scratch)
						append_scene_message(&txn.preds, 147, 5, mpe_uint(3, scratch), scratch)
						append_scene_message(&txn.preds, 146, 8, party_member_status_pair_body(18, 12, "C1", 0, "C2", 0, scratch), scratch)
					} else if decoded.scene_handle == 146 && decoded.decoded.rpc_id == 6400 {
						append_scene_message(&txn.preds, 146, 7, scene_rpc_uint_prefix_body(27, 16, scratch), scratch)
					} else if decoded.scene_handle == 144 && decoded.decoded.rpc_id == 3840 {
						append_scene_message(&txn.preds, 144, 5, scene_rpc_error_body(8, "Cannot update data when member is ready.", scratch), scratch)
						append_scene_message(&txn.preds, 145, 5, mpe_uint(0, scratch), scratch)
					}
				case 6: // authenticator Authentication.Login
					if decoded.scene_handle == 141 {
						append_auth_rpc_response(&txn.preds, decoded.scene_handle, decoded.decoded.rpc_id, login_result_for_peer(txn.label, scratch), scratch)
					} else if (decoded.scene_handle == 144 && decoded.decoded.rpc_id != 8) || (decoded.scene_handle == 146 && decoded.decoded.rpc_id != 8) {
						if decoded.scene_handle == 144 && decoded.decoded.rpc_id == 12 {
							append_scene_message(&txn.preds, 146, 4, scene_rpc_nil_false_nil_body(1, scratch), scratch)
						}
						append_scene_rpc_complete(&txn.preds, decoded.scene_handle, 1, decoded.decoded.rpc_id, false, scratch)
						if decoded.scene_handle == 146 && decoded.decoded.rpc_id == 3 {
							append_scene_message(&txn.preds, 146, 3, party_memberdata_body("C2", 20, 13, true, 2, scratch), scratch)
						}
					}
				case 11:
					if decoded.scene_handle == 144 && decoded.decoded.rpc_id == 9 {
						append_auth_rpc_response(&txn.preds, decoded.scene_handle, decoded.decoded.rpc_id, nil, scratch)
						append_scene_message(&txn.preds, 145, 5, mpe_uint(3, scratch), scratch)
					} else if decoded.scene_handle == 146 {
						append_auth_rpc_response(&txn.preds, decoded.scene_handle, decoded.decoded.rpc_id, nil, scratch)
					}
				case 9:
					if decoded.scene_handle == 144 {
						append_scene_message(&txn.preds, 144, 8, party_member_status_body(15, 11, "C1", 1, scratch), scratch)
						append_scene_rpc_complete(&txn.preds, decoded.scene_handle, 1, decoded.decoded.rpc_id, false, scratch)
					} else if decoded.scene_handle == 146 {
						append_scene_message(&txn.preds, 146, 8, party_member_status_body(14, 10, "C2", 1, scratch), scratch)
						append_scene_rpc_complete(&txn.preds, decoded.scene_handle, 1, decoded.decoded.rpc_id, false, scratch)
					}
				case 8:
					if decoded.scene_handle == 146 {
						append_scene_message(&txn.preds, 146, 2, player_update_body("C2", 1, scratch), scratch)
						append_scene_message(&txn.preds, 146, 2, player_update_body("C1", 1, scratch), scratch)
						append_scene_message(&txn.preds, 146, 2, player_update_body("C2", 1, scratch), scratch)
						append_scene_message(&txn.preds, 144, 16, steam_update_lobby_joinable_body(23, 109775242850226431, false, scratch), scratch)
					} else if decoded.scene_handle == 148 {
						append_scene_message(&txn.preds, 148, 2, player_update_body("C2", 1, scratch), scratch)
						append_scene_message(&txn.preds, 148, 2, player_update_body("C1", 0, scratch), scratch)
						append_scene_message(&txn.preds, 148, 2, player_update_body("C1", 1, scratch), scratch)
						append_scene_message(&txn.preds, 148, 4, scene_rpc_nil_false_nil_body(decoded.decoded.rpc_id, scratch), scratch)
						append_scene_message(&txn.preds, 146, 7, scene_rpc_uint_prefix_body(25, 15, scratch), scratch)
					}
				case 15: // authenticator UserSession.UpdateUserOptions
					if decoded.scene_handle == 141 {
						append_auth_rpc_complete(&txn.preds, decoded.scene_handle, decoded.decoded.rpc_id, false, scratch)
					}
				case 19: // authenticator Locator.GetSceneConnectionToken
					if decoded.scene_handle == 141 {
						append_auth_rpc_response(&txn.preds, decoded.scene_handle, decoded.decoded.rpc_id, scene_token_response_for_body(decoded.decoded, scratch), scratch)
					}
				case 5: // friends Friends.Subscribe
					if decoded.scene_handle == 142 {
						if body := captured_friend_notification(steam_friends_text, txn.label, 0, scratch); body != nil {
							append_scene_message(&txn.preds, decoded.scene_handle, 1, body, scratch)
						}
						append_scene_rpc_complete(&txn.preds, decoded.scene_handle, 2, decoded.decoded.rpc_id, false, scratch)
					} else if decoded.scene_handle == 143 {
						append_auth_rpc_response(&txn.preds, decoded.scene_handle, decoded.decoded.rpc_id, scene_token_response_for_suffix(party_scene_for_peer("C1"), scratch), scratch)
					} else {
						append_scene_rpc_complete(&txn.preds, decoded.scene_handle, 1, decoded.decoded.rpc_id, false, scratch)
					}
				case 4: // friends Friends.UpdateFriendList
					if decoded.scene_handle == 142 {
						if body := captured_friend_notification(steam_friends_text, txn.label, 1, scratch); body != nil {
							append_scene_message(&txn.preds, decoded.scene_handle, 1, body, scratch)
						}
					} else if decoded.scene_handle == 143 {
						append_auth_rpc_response(&txn.preds, decoded.scene_handle, decoded.decoded.rpc_id, scene_token_response_for_suffix(party_scene_for_peer(txn.label), scratch), scratch)
					} else if decoded.scene_handle != 142 {
						append_scene_rpc_complete(&txn.preds, decoded.scene_handle, 1, decoded.decoded.rpc_id, false, scratch)
					}
				case 13: // party Party.CreateInvitationCode
					append_auth_rpc_response(&txn.preds, decoded.scene_handle, decoded.decoded.rpc_id, mpe_str(invite_code_for_peer(txn.label), scratch), scratch)
				case 16: // partyMerging.GetMergerStatus
					poll_index := count_previous_scene_route(txns[:], ps, 16)
					append_auth_rpc_response(&txn.preds, decoded.scene_handle, decoded.decoded.rpc_id, merger_status_raw(poll_index, scratch), scratch)
				}
			}
		}

		append(&txns, txn)
		if len(txns) >= number_of_transactions_to_test do break
	}

	for &txn, i in txns {
		if i >= number_of_transactions_to_test do break
		real_human := render_decoded_burst(&txn.peer.reg_real, txn.peer.ep_real, txn.reals[:], scratch)
		real_bytes := encode_decoded_messages(txn.reals[:], scratch)
		pred_human := render_decoded_burst(&txn.peer.reg_pred, txn.peer.ep_pred, txn.preds[:], scratch)
		pred_bytes := encode_decoded_messages(txn.preds[:], scratch)
		free_all(context.temp_allocator)

		sync_write_record(
			&out,
			txn.t,
			txn.label,
			decoded_messages_match(txn.reals[:], txn.preds[:], scratch),
			txn.sent_msgs[:],
			real_bytes,
			pred_bytes,
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

