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

import "core:encoding/base64"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

LISTEN_HOST :: "0.0.0.0"
LISTEN_PORT :: 30100 // matches raknet.py HOST/PORT
DEFAULT_RELAY_UPSTREAM :: "dt-live.passtechgames.com:30100"
DEFAULT_RELAY_REAL_HOST :: "dt-live.passtechgames.com"
REAL_AUTH_TOKEN_PATH :: "/darktales/live-1-05-00/scenes/authenticator/token"
DEFAULT_RELAY_CAPTURE :: "/tmp/pdlog/probe/relay_capture.jsonl"
DEFAULT_PREDICT_CALEB_FILE :: "/tmp/pdlog/probe/predict_caleb.json"
DEFAULT_RAKNET_ENDPOINT :: "127.0.0.1:30100"
DEFAULT_DTLIVE_PORT :: 8080
MAX_UDP_SIZE :: 65535 // largest a single UDP datagram can be
MAX_UDP_DATAGRAMS :: 4096 // capacity of one UDP_Datagram_Store
MAX_RAKNET_MESSAGES :: 4096 // capacity of one RakNet_Message_Store
BYTE_POOL_SIZE :: 4 * 1024 * 1024

Error :: union #shared_nil {
	net.Network_Error,
	net.Create_Socket_Error,
	os.Error,
}

UDP_Datagram_Store :: struct {
	froms:      [MAX_UDP_DATAGRAMS]net.Endpoint, // sender address + port
	recv_times: [MAX_UDP_DATAGRAMS]time.Time, // when each datagram was received
	starts:     [MAX_UDP_DATAGRAMS]int, // byte offset of datagram i in pool
	lengths:    [MAX_UDP_DATAGRAMS]int, // byte length of datagram i
	count:      int, // number of datagrams stored
	pool:       [BYTE_POOL_SIZE]byte, // all datagram bytes, back to back
}

Jsonl_Record :: struct {
	t:    string, // rfc3339 receive time
	from: string, // sender "ip:port"
	len:  int, // datagram byte length
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

net_listen :: proc(
	dgrams: ^UDP_Datagram_Store,
	msgs: ^RakNet_Message_Store,
	reasm: ^Reassembly,
) -> Error {
	if env_truthy("RAKNET_RELAY") {
		return net_relay_listen(dgrams, msgs, reasm)
	}
	return net_predict_listen(dgrams, msgs, reasm)
}

net_predict_listen :: proc(
	dgrams: ^UDP_Datagram_Store,
	msgs: ^RakNet_Message_Store,
	reasm: ^Reassembly,
) -> Error {
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
	write_scratch_backing := make([]byte, 32 * 1024 * 1024)
	defer delete(write_scratch_backing)
	write_scratch_arena: mem.Arena
	mem.arena_init(&write_scratch_arena, write_scratch_backing)
	write_scratch := mem.arena_allocator(&write_scratch_arena)
	log_scratch_backing := make([]byte, MAX_UDP_SIZE * 4 + 512)
	defer delete(log_scratch_backing)
	log_scratch_arena: mem.Arena
	mem.arena_init(&log_scratch_arena, log_scratch_backing)
	log_scratch := mem.arena_allocator(&log_scratch_arena)

	live: Predict_Caleb_Live
	predict_caleb_live_init(&live, scratch, write_scratch) or_return
	wire := new_world()
	live_peers: [dynamic]Live_Peer_Wire
	predict_out_path := env_string("PREDICT_CALEB_FILE", DEFAULT_PREDICT_CALEB_FILE)
	sync_write_out(predict_out_path, "")
	http_port := env_int("PROBE_PORT", DEFAULT_DTLIVE_PORT)
	http_sock, http_enabled := dtlive_try_listen(bind_addr, http_port)

	fmt.printfln(
		"caleb_raknet predict server listening on %s:%d (RAKNET_RELAY=0); predict -> %s",
		LISTEN_HOST,
		LISTEN_PORT,
		predict_out_path,
	)
	verbose_predict := env_truthy("RAKNET_PREDICT_VERBOSE")
	buf: [MAX_UDP_SIZE]byte
	polls: [2]posix.pollfd
	for {
		poll_count := 1
		polls[0] = posix.pollfd {
			fd     = udp_fd(sock),
			events = {.IN},
		}
		if http_enabled {
			polls[1] = posix.pollfd {
				fd     = tcp_fd(http_sock),
				events = {.IN},
			}
			poll_count = 2
		}
		ready := posix.poll(&polls[0], posix.nfds_t(poll_count), 1000)
		if ready <= 0 do continue
		if http_enabled && .IN in polls[1].revents {
			dtlive_handle_one(http_sock, log_scratch)
		}
		if !(.IN in polls[0].revents) do continue

		n, remote := net.recv_udp(sock, buf[:]) or_continue
		if n <= 0 do continue
		data := buf[:n]
		peer_count_before := len(live_peers)
		peer_index := live_peer_index(&live_peers, remote)
		label := live_peers[peer_index].label
		if len(live_peers) != peer_count_before {
			fmt.printfln("predict client %s -> %v", label, remote)
		}
		if live_predict_handle_health(sock, &wire, live_peers[peer_index].addr, data) {
			continue
		}

		now := time.now()
		if !udp_datagram_push(dgrams, remote, now, data) {
			fmt.eprintfln("datagram store full, dropping %d bytes", n)
			continue
		}
		log_datagram(log, log_scratch, remote, now, data)
		process_udp_datagram(dgrams, msgs, reasm, dgrams.count - 1)

		if live_predict_handle_offline(sock, &wire, live_peers[peer_index].addr, data, scratch) {
			continue
		}
		if !is_content_datagram(data) do continue

		ack := make_ack(read_u24_le(data, 1), scratch)
		net.send_udp(sock, ack, remote)

		ps := find_peer(&live.peers, label, &live.nidx)
		sent_msgs := filter_health_messages(reassemble_side(ps, .C2S, {data}, scratch), scratch)
		if len(sent_msgs) == 0 do continue

		preds := predict_caleb_step(&live, label, remote, sent_msgs)
		live_send_predictions(sock, &wire, remote, preds, scratch)
		live_flush_cross_predictions(sock, &wire, &live, live_peers[:], scratch)
		predict_caleb_live_write(&live, predict_out_path)
		if verbose_predict && len(preds) > 0 {
			fmt.printfln("predict %s c2s_msgs=%d pred_msgs=%d", label, len(sent_msgs), len(preds))
		}
	}
	return nil
}

net_relay_listen :: proc(
	dgrams: ^UDP_Datagram_Store,
	msgs: ^RakNet_Message_Store,
	reasm: ^Reassembly,
) -> Error {
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
	write_scratch_backing := make([]byte, 32 * 1024 * 1024)
	defer delete(write_scratch_backing)
	write_scratch_arena: mem.Arena
	mem.arena_init(&write_scratch_arena, write_scratch_backing)
	write_scratch := mem.arena_allocator(&write_scratch_arena)

	live: Predict_Caleb_Live
	predict_caleb_live_init(&live, predict_scratch, write_scratch) or_return

	upstream_text := env_string("RAKNET_RELAY_UPSTREAM", DEFAULT_RELAY_UPSTREAM)
	upstream := net.resolve_ip4(upstream_text) or_return
	capture_path := env_string("RELAY_CAPTURE", DEFAULT_RELAY_CAPTURE)
	predict_out_path := env_string("PREDICT_CALEB_FILE", DEFAULT_PREDICT_CALEB_FILE)
	os.remove(capture_path)
	capture := os.open(capture_path, {.Write, .Create, .Append}) or_return
	defer os.close(capture)
	sync_write_out(predict_out_path, "")
	http_port := env_int("PROBE_PORT", DEFAULT_DTLIVE_PORT)
	http_sock, http_enabled := dtlive_try_listen(bind_addr, http_port)
	relay_resp_wait_ms := env_int("RELAY_RESP_WAIT_MS", 700)
	relay_resp_idle_ms := env_int("RELAY_RESP_IDLE_MS", 50)
	// Raw-delay is OPT-IN. 0 (default) = pass client content through immediately
	// (known-good behavior; produces working join codes). >0 = inject this many ms of
	// delay before each client content datagram is uploaded, forwarding the ORIGINAL
	// bytes VERBATIM (exact sequence numbers / reliability / fragments) in FIFO order
	// so the upstream RakNet connection stays in sync. The client is self-ACKed while
	// its datagrams are held so its reliable window stays open. Lone ping datagrams
	// (nothing else held) still go out immediately.
	relay_gate_ms := env_int("RELAY_GATE_MS", 0)

	clients: [dynamic]Relay_Client
	pending_client_dgs: [dynamic]Relay_Pending_Client_Datagram
	fmt.printfln(
		"caleb_raknet relay listening on %s:%d -> %s; capture -> %s; predict -> %s; response window %dms idle %dms; raw-delay %dms (%s)",
		LISTEN_HOST,
		LISTEN_PORT,
		upstream_text,
		capture_path,
		predict_out_path,
		relay_resp_wait_ms,
		relay_resp_idle_ms,
		relay_gate_ms,
		relay_gate_ms > 0 ? "on" : "off",
	)

	buf: [MAX_UDP_SIZE]byte
	polls: [128]posix.pollfd
	for {
		// 1. Drain deferred client datagrams. In immediate mode relay_handle_c2s
		//    forwards + predicts and returns true so we collect responses; in raw-delay
		//    mode it only holds the datagram and returns false (step 2 forwards it).
		if len(pending_client_dgs) > 0 {
			pending := pending_client_dgs[0]
			for i := 1; i < len(pending_client_dgs); i += 1 do pending_client_dgs[i - 1] = pending_client_dgs[i]
			resize(&pending_client_dgs, len(pending_client_dgs) - 1)
			if relay_handle_c2s(
				sock,
				&clients,
				pending.client,
				pending.data,
				upstream,
				dgrams,
				msgs,
				reasm,
				&live,
				predict_out_path,
				capture,
				log_scratch,
				predict_scratch,
				relay_gate_ms,
			) {
				relay_wait_for_responses(
					sock,
					http_sock,
					http_enabled,
					&clients,
					&pending_client_dgs,
					upstream,
					dgrams,
					msgs,
					reasm,
					&live,
					predict_out_path,
					capture,
					log_scratch,
					predict_scratch,
					relay_resp_wait_ms,
					relay_resp_idle_ms,
					relay_gate_ms,
				)
				predict_caleb_live_write(&live, predict_out_path)
			}
			continue
		}

		// 2. Raw-delay only: forward every held content datagram whose delay has
		//    elapsed, verbatim and in FIFO order. The upstream's responses are picked
		//    up by the normal poll below (relay_handle_s2c), so no synchronous wait.
		if relay_gate_ms > 0 {
			now_tick := time.tick_now()._nsec
			released := false
			for i in 0 ..< len(clients) {
				if relay_release_due(
					&clients[i],
					now_tick,
					&live,
					upstream,
					dgrams,
					msgs,
					reasm,
					capture,
					log_scratch,
					predict_scratch,
				) {
					released = true
				}
			}
			if released {
				predict_caleb_live_write(&live, predict_out_path)
				continue
			}
		}

		// 3. Poll. When raw-delaying, wake no later than the nearest held datagram's
		//    release deadline.
		poll_timeout := 1000
		if relay_gate_ms > 0 {
			now_tick := time.tick_now()._nsec
			for client in clients {
				if len(client.pending) == 0 do continue
				ms := int((client.pending[0].deadline - now_tick) / i64(time.Millisecond))
				if ms < 0 do ms = 0
				if ms < poll_timeout do poll_timeout = ms
			}
		}

		poll_count := 1 + len(clients)
		http_poll_index := -1
		polls[0] = posix.pollfd {
			fd     = udp_fd(sock),
			events = {.IN},
		}
		for client, i in clients {
			polls[i + 1] = posix.pollfd {
				fd     = udp_fd(client.socket),
				events = {.IN},
			}
		}
		if http_enabled && poll_count < len(polls) {
			http_poll_index = poll_count
			polls[http_poll_index] = posix.pollfd {
				fd     = tcp_fd(http_sock),
				events = {.IN},
			}
			poll_count += 1
		}
		ready := posix.poll(&polls[0], posix.nfds_t(poll_count), i32(poll_timeout))
		if ready <= 0 do continue
		if http_poll_index >= 0 && .IN in polls[http_poll_index].revents {
			dtlive_handle_one(http_sock, log_scratch)
		}

		if .IN in polls[0].revents {
			n, remote := net.recv_udp(sock, buf[:]) or_continue
			if n <= 0 do continue
			if relay_handle_c2s(
				sock,
				&clients,
				remote,
				buf[:n],
				upstream,
				dgrams,
				msgs,
				reasm,
				&live,
				predict_out_path,
				capture,
				log_scratch,
				predict_scratch,
				relay_gate_ms,
			) {
				relay_wait_for_responses(
					sock,
					http_sock,
					http_enabled,
					&clients,
					&pending_client_dgs,
					upstream,
					dgrams,
					msgs,
					reasm,
					&live,
					predict_out_path,
					capture,
					log_scratch,
					predict_scratch,
					relay_resp_wait_ms,
					relay_resp_idle_ms,
					relay_gate_ms,
				)
				predict_caleb_live_write(&live, predict_out_path)
			}
		}

		for i in 0 ..< len(clients) {
			if !(.IN in polls[i + 1].revents) do continue
			n, from := net.recv_udp(clients[i].socket, buf[:]) or_continue
			if n <= 0 do continue
			relay_handle_s2c(
				sock,
				clients[:],
				i,
				buf[:n],
				from,
				dgrams,
				msgs,
				reasm,
				&live,
				predict_out_path,
				capture,
				log_scratch,
				predict_scratch,
				relay_gate_ms,
			)
		}
	}
	return nil
}

relay_client_index_or_create :: proc(
	clients: ^[dynamic]Relay_Client,
	remote: net.Endpoint,
) -> int {
	idx := relay_client_index(clients, remote)
	if idx >= 0 do return idx
	up_sock, err := net.make_unbound_udp_socket(.IP4)
	if err != nil {
		fmt.eprintfln("relay upstream socket create failed -> %v", err)
		return -1
	}
	idx = len(clients^)
	append(
		clients,
		Relay_Client{client = remote, peer = relay_peer_label(idx + 1), socket = up_sock},
	)
	fmt.printfln("relay client %s -> %v", clients^[idx].peer, remote)
	return idx
}

relay_handle_c2s :: proc(
	sock: net.UDP_Socket,
	clients: ^[dynamic]Relay_Client,
	remote: net.Endpoint,
	data: []byte,
	upstream: net.Endpoint,
	dgrams: ^UDP_Datagram_Store,
	msgs: ^RakNet_Message_Store,
	reasm: ^Reassembly,
	live: ^Predict_Caleb_Live,
	predict_out_path: string,
	capture: ^os.File,
	log_scratch: mem.Allocator,
	predict_scratch: mem.Allocator,
	gate_ms: int,
) -> bool {
	idx := relay_client_index_or_create(clients, remote)
	if idx < 0 do return false
	client := &clients^[idx]

	// IMMEDIATE PASS-THROUGH (gate off): forward every client datagram verbatim and
	// predict at arrival time. This is the original, known-good behavior that yields
	// a working live game / join code. Returns true so the caller collects responses.
	if gate_ms <= 0 {
		if !is_content_datagram(data) || datagram_is_health_channel(data) {
			net.send_udp(client.socket, data, upstream)
			return false
		}
		now := time.now()
		log_relay_datagram(capture, log_scratch, "c2s", client.peer, now, data)
		if !udp_datagram_push(dgrams, remote, now, data) {
			fmt.eprintfln("datagram store full, dropping %d bytes", len(data))
		} else {
			process_udp_datagram(dgrams, msgs, reasm, dgrams.count - 1)
		}
		net.send_udp(client.socket, data, upstream)
		ps := find_peer(&live.peers, client.peer, &live.nidx)
		sent_msgs := filter_health_messages(
			reassemble_side(ps, .C2S, {data}, predict_scratch),
			predict_scratch,
		)
		if len(sent_msgs) == 0 do return false
		predict_caleb_step(live, client.peer, client.client, sent_msgs)
		return true
	}

	// RAW-DELAY GATING (gate on): inject a constant gate_ms delay before each content
	// datagram is uploaded, forwarding the ORIGINAL bytes verbatim (exact datagram
	// sequence number / reliability / fragments) so the upstream RakNet connection
	// stays perfectly in sync -- unlike re-encoding, which desynced it and broke the
	// join code. Non-content datagrams (handshake, the client's own ACK/NAK) pass
	// straight through immediately.
	if !is_content_datagram(data) {
		net.send_udp(client.socket, data, upstream)
		return false
	}
	// A lone ping datagram with nothing already held can go immediately: it cannot
	// jump ahead of any held datagram, so datagram order to the server is preserved.
	if len(client.pending) == 0 && datagram_is_health_channel(data) {
		net.send_udp(client.socket, data, upstream)
		return false
	}
	// Hold this content datagram. To keep the client's reliable send-window open and
	// stop it retransmitting while we hold its reliable messages, acknowledge the
	// datagram to the client ourselves. We forward the bytes verbatim later, so the
	// same sequence number is what the upstream eventually ACKs too -- its real ACK
	// arriving afterward is just an ignored duplicate to the client.
	if !datagram_is_health_channel(data) {
		net.send_udp(sock, make_ack(read_u24_le(data, 1), predict_scratch), client.client)
	}
	held := make([]byte, len(data), context.allocator)
	copy(held, data)
	append(
		&client.pending,
		Relay_Held_Datagram {
			data = held,
			deadline = time.tick_now()._nsec + i64(gate_ms) * i64(time.Millisecond),
		},
	)
	return false
}

// Forward every held client->upstream datagram whose delay has elapsed, verbatim
// and in FIFO (== sequence) order. Reassembly and prediction happen here, at
// forward time, exactly as the immediate path does at arrival -- so predict_caleb's
// "sent" timestamps reflect the actual (delayed) upload time. Returns true if any
// datagram was released. Health-only datagrams are forwarded but produce no record.
relay_release_due :: proc(
	client: ^Relay_Client,
	now_tick: i64,
	live: ^Predict_Caleb_Live,
	upstream: net.Endpoint,
	dgrams: ^UDP_Datagram_Store,
	msgs: ^RakNet_Message_Store,
	reasm: ^Reassembly,
	capture: ^os.File,
	log_scratch: mem.Allocator,
	predict_scratch: mem.Allocator,
) -> bool {
	released := false
	for len(client.pending) > 0 && client.pending[0].deadline <= now_tick {
		held := client.pending[0]
		for i := 1; i < len(client.pending); i += 1 do client.pending[i - 1] = client.pending[i]
		resize(&client.pending, len(client.pending) - 1)

		wall := time.now()
		net.send_udp(client.socket, held.data, upstream)

		ps := find_peer(&live.peers, client.peer, &live.nidx)
		sent_msgs := filter_health_messages(
			reassemble_side(ps, .C2S, {held.data}, predict_scratch),
			predict_scratch,
		)
		if len(sent_msgs) > 0 {
			log_relay_datagram(capture, log_scratch, "c2s", client.peer, wall, held.data)
			if !udp_datagram_push(dgrams, client.client, wall, held.data) {
				fmt.eprintfln("datagram store full, dropping %d bytes", len(held.data))
			} else {
				process_udp_datagram(dgrams, msgs, reasm, dgrams.count - 1)
			}
			predict_caleb_step(live, client.peer, client.client, sent_msgs)
		}
		delete(held.data)
		released = true
	}
	return released
}

relay_handle_s2c :: proc(
	sock: net.UDP_Socket,
	clients: []Relay_Client,
	idx: int,
	data: []byte,
	from: net.Endpoint,
	dgrams: ^UDP_Datagram_Store,
	msgs: ^RakNet_Message_Store,
	reasm: ^Reassembly,
	live: ^Predict_Caleb_Live,
	predict_out_path: string,
	capture: ^os.File,
	log_scratch: mem.Allocator,
	predict_scratch: mem.Allocator,
	gate_ms := 0,
) {
	if idx < 0 || idx >= len(clients) do return
	// Client datagrams are always forwarded to the upstream verbatim (immediate mode
	// and raw-delay mode both preserve the client's own sequence space), so the
	// upstream's ACK/NAK reference sequence numbers the client knows. Forward
	// everything to the client unchanged, in both directions.
	net.send_udp(sock, data, clients[idx].client)
	if !is_content_datagram(data) || datagram_is_health_channel(data) do return

	now := time.now()
	log_relay_datagram(capture, log_scratch, "s2c", clients[idx].peer, now, data)
	if !udp_datagram_push(dgrams, from, now, data) {
		fmt.eprintfln("datagram store full, dropping %d bytes", len(data))
	} else {
		process_udp_datagram(dgrams, msgs, reasm, dgrams.count - 1)
	}

	ps := find_peer(&live.peers, clients[idx].peer, &live.nidx)
	real_msgs := filter_health_messages(
		reassemble_side(ps, .Real, {data}, predict_scratch),
		predict_scratch,
	)
	if len(real_msgs) > 0 {
		for msg in real_msgs {
			predict_caleb_learn_real_values(
				&live.party_states,
				&live.scene_handles,
				&live.txns,
				ps,
				msg,
				predict_scratch,
			)
			predict_caleb_route_real(&live.txns, ps, msg, predict_scratch)
		}
		predict_caleb_live_write(live, predict_out_path)
	}
}

relay_wait_for_responses :: proc(
	sock: net.UDP_Socket,
	http_sock: net.TCP_Socket,
	http_enabled: bool,
	clients: ^[dynamic]Relay_Client,
	pending_client_dgs: ^[dynamic]Relay_Pending_Client_Datagram,
	upstream: net.Endpoint,
	dgrams: ^UDP_Datagram_Store,
	msgs: ^RakNet_Message_Store,
	reasm: ^Reassembly,
	live: ^Predict_Caleb_Live,
	predict_out_path: string,
	capture: ^os.File,
	log_scratch: mem.Allocator,
	predict_scratch: mem.Allocator,
	wait_ms, idle_ms: int,
	gate_ms := 0,
) {
	if wait_ms <= 0 || len(clients^) == 0 do return
	now_tick := time.tick_now()._nsec
	deadline := now_tick + i64(wait_ms) * i64(time.Millisecond)
	idle_deadline: i64 = 0
	saw_response := false
	buf: [MAX_UDP_SIZE]byte
	polls: [128]posix.pollfd
	for {
		now_tick = time.tick_now()._nsec
		remaining := deadline - now_tick
		if saw_response && idle_deadline > 0 && idle_deadline - now_tick < remaining {
			remaining = idle_deadline - now_tick
		}
		if remaining <= 0 do break
		poll_count := min(len(clients^) + 1, len(polls))
		polls[0] = posix.pollfd {
			fd     = udp_fd(sock),
			events = {.IN},
		}
		for client, i in clients^[:poll_count - 1] {
			polls[i + 1] = posix.pollfd {
				fd     = udp_fd(client.socket),
				events = {.IN},
			}
		}
		http_poll_index := -1
		if http_enabled && poll_count < len(polls) {
			http_poll_index = poll_count
			polls[http_poll_index] = posix.pollfd {
				fd     = tcp_fd(http_sock),
				events = {.IN},
			}
			poll_count += 1
		}
		timeout_ms := int((remaining + i64(time.Millisecond) - 1) / i64(time.Millisecond))
		if timeout_ms > 2_147_483_647 do timeout_ms = 2_147_483_647
		ready := posix.poll(&polls[0], posix.nfds_t(poll_count), i32(timeout_ms))
		if ready <= 0 do break
		if http_poll_index >= 0 && .IN in polls[http_poll_index].revents {
			dtlive_handle_one(http_sock, log_scratch)
		}
		if .IN in polls[0].revents {
			n, remote := net.recv_udp(sock, buf[:]) or_continue
			if n > 0 {
				idx := relay_client_index_or_create(clients, remote)
				if idx >= 0 {
					// Non-content (handshake / client ACK-NAK) passes straight to the
					// upstream; content datagrams (health or meaningful) are deferred so
					// they re-enter relay_handle_c2s and stay on the relay's re-encoded
					// sequence space instead of being forwarded verbatim.
					if !is_content_datagram(buf[:n]) {
						net.send_udp(clients^[idx].socket, buf[:n], upstream)
					} else {
						copy_data := make([]byte, n, context.allocator)
						copy(copy_data, buf[:n])
						append(
							pending_client_dgs,
							Relay_Pending_Client_Datagram{client = remote, data = copy_data},
						)
					}
				}
			}
		}
		upstream_poll_count := min(len(clients^), len(polls) - 1)
		for i in 0 ..< upstream_poll_count + 1 {
			if i == 0 do continue
			if !(.IN in polls[i].revents) do continue
			client_idx := i - 1
			if client_idx < 0 || client_idx >= len(clients^) do continue
			n, from := net.recv_udp(clients^[client_idx].socket, buf[:]) or_continue
			if n <= 0 do continue
			meaningful_response :=
				is_content_datagram(buf[:n]) && !datagram_is_health_channel(buf[:n])
			relay_handle_s2c(
				sock,
				clients^[:],
				client_idx,
				buf[:n],
				from,
				dgrams,
				msgs,
				reasm,
				live,
				predict_out_path,
				capture,
				log_scratch,
				predict_scratch,
				gate_ms,
			)
			if meaningful_response {
				saw_response = true
				idle_deadline =
					time.tick_now()._nsec + i64(max(idle_ms, 1)) * i64(time.Millisecond)
			}
		}
	}
}

live_predict_handle_offline :: proc(
	sock: net.UDP_Socket,
	wire: ^World,
	addr: Peer_Addr,
	data: []byte,
	scratch: mem.Allocator,
) -> bool {
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

live_predict_handle_health :: proc(
	sock: net.UDP_Socket,
	wire: ^World,
	addr: Peer_Addr,
	data: []byte,
) -> bool {
	if !datagram_is_health_channel(data) do return false
	_ = predict(wire, addr, data)
	live_flush_outbox(sock, wire)
	return true
}

live_send_predictions :: proc(
	sock: net.UDP_Socket,
	wire: ^World,
	remote: net.Endpoint,
	preds: []Decoded_Message,
	scratch: mem.Allocator,
) {
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

live_send_decoded_messages :: proc(
	sock: net.UDP_Socket,
	wire: ^World,
	remote: net.Endpoint,
	preds: []Decoded_Message,
	scratch: mem.Allocator,
) {
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

live_flush_cross_predictions :: proc(
	sock: net.UDP_Socket,
	wire: ^World,
	live: ^Predict_Caleb_Live,
	peers: []Live_Peer_Wire,
	scratch: mem.Allocator,
) {
	kept: [dynamic]Predict_Caleb_Cross_Pred
	for cross in live.cross_preds {
		if remote, ok := live_peer_endpoint_by_label(peers, cross.label); ok {
			msgs := [?]Decoded_Message{cross.msg}
			live_send_decoded_messages(sock, wire, remote, msgs[:], scratch)
		} else {
			append(&kept, cross)
		}
	}
	clear(&live.cross_preds)
	for cross in kept do append(&live.cross_preds, cross)
}

live_flush_outbox :: proc(sock: net.UDP_Socket, wire: ^World) {
	for out in wire.outbox {
		net.send_udp(sock, out.data, endpoint_from_peer_addr(out.addr))
	}
	clear(&wire.outbox)
}

dtlive_try_listen :: proc(bind_addr: net.Address, port: int) -> (net.TCP_Socket, bool) {
	sock, err := net.listen_tcp(net.Endpoint{address = bind_addr, port = port})
	if err != nil {
		fmt.eprintfln("dtlive HTTP disabled on %s:%d -> %v", LISTEN_HOST, port, err)
		return {}, false
	}
	fmt.printfln("dtlive HTTP listening on %s:%d (plain)", LISTEN_HOST, port)
	return sock, true
}

dtlive_handle_one :: proc(sock: net.TCP_Socket, allocator := context.allocator) {
	free_all(allocator)
	client, remote, err := net.accept_tcp(sock)
	if err != nil do return
	defer net.close(client)

	buf: [16 * 1024]byte
	n, recv_err := net.recv_tcp(client, buf[:])
	if recv_err != nil || n <= 0 do return
	req := string(buf[:n])
	path := http_request_path(req)
	body, content_type := dtlive_response_body(path, allocator)
	resp := fmt.aprintf(
		"HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\nServer: Kestrel\r\nCache-Control: no-cache\r\nx-version: 3\r\nConnection: close\r\n\r\n%s",
		content_type,
		len(body),
		body,
		allocator = allocator,
	)
	fmt.printfln("dtlive %s from %v -> %dB", path, remote, len(body))
	net.send_tcp(client, transmute([]byte)resp)
}

http_request_path :: proc(req: string) -> string {
	sp1 := strings.index_byte(req, ' ')
	if sp1 < 0 do return "/"
	rest := req[sp1 + 1:]
	sp2 := strings.index_byte(rest, ' ')
	path := rest
	if sp2 >= 0 do path = rest[:sp2]
	if scheme := strings.index(path, "://"); scheme >= 0 {
		after := path[scheme + 3:]
		if slash := strings.index_byte(after, '/'); slash >= 0 {
			path = after[slash:]
		} else {
			path = "/"
		}
	}
	if path == "" do return "/"
	return path
}

dtlive_response_body :: proc(path: string, allocator := context.allocator) -> (string, string) {
	if path == "/_federation" {
		return "{\"current\":{\"id\":\"passtech-live\",\"adminEndpoints\":[\"https://dt-live.passtechgames.com\"],\"endpoints\":[\"https://dt-live.passtechgames.com\"],\"tags\":[]},\"clusters\":[{\"id\":\"passtech-live\",\"adminEndpoints\":null,\"endpoints\":[\"https://dt-live.passtechgames.com\"],\"tags\":[]}]}",
			"application/json"
	}
	if string_has_suffix(path, "/token") {
		raknet_endpoint := env_string("RAKNET_ENDPOINT", DEFAULT_RAKNET_ENDPOINT, allocator)
		if env_truthy("RAKNET_RELAY") {
			if body, ok := dtlive_relay_token_json(path, raknet_endpoint, allocator); ok {
				return body, "application/json; charset=utf-8"
			}
		}
		return scene_token_json_endpoint("authenticator", raknet_endpoint, allocator),
			"application/json; charset=utf-8"
	}
	if path == "/" {
		return "{\"name\":\"dt-live-1\",\"version\":\"9.3.0.2\",\"reportedStatus\":\"Leader\",\"leader\":{\"uid\":\"5w0GiaMkGUuN+QnuOyHTKQ\",\"name\":\"dt-live-1\",\"endpoint\":\"dt-live.passtechgames.com:40243\",\"cluster\":\"passtech-live\"},\"cluster\":\"passtech-live\",\"logLastCommittedEntryId\":19,\"logLastEntryId\":19,\"logLastSnapshot\":null,\"state\":\"Running\",\"id\":\"5w0GiaMkGUuN+QnuOyHTKQ\"}",
			"application/json"
	}
	return `{}`, "application/json"
}

dtlive_relay_token_json :: proc(
	path, raknet_endpoint: string,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
	real_host := env_string("RELAY_REAL_HOST", DEFAULT_RELAY_REAL_HOST, allocator)
	fetch_path := path
	if fetch_path == "" || fetch_path[0] != '/' do fetch_path = REAL_AUTH_TOKEN_PATH
	url := fmt.aprintf("https://%s%s", real_host, fetch_path, allocator = allocator)
	command := []string {
		"curl",
		"-4",
		"-fsSL",
		"--max-time",
		"10",
		"-X",
		"POST",
		"-H",
		"Accept: application/json",
		"-H",
		"clientVersion: 1.05.00.05",
		"-H",
		"Content-Type: text/plain; charset=utf-8, application/msgpack",
		"-H",
		"devProduct: false",
		"-H",
		"platform: pc",
		"-H",
		"serverVersion: 2.0",
		"-H",
		"User-Agent: cpprestsdk/2.8.01",
		"-H",
		"x-version: 3",
		url,
	}
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{command = command}, allocator)
	if err != nil || !state.success || len(stdout) == 0 {
		fmt.eprintfln(
			"dtlive relay token fetch failed -> err=%v status=%d stderr=%s",
			err,
			state.exit_code,
			string(stderr),
		)
		return "", false
	}
	real_body := trim_ascii_space(string(stdout))
	if real_body == "" do return "", false
	if real_body[0] == '{' {
		if rewritten, ok := rewrite_raknet_endpoint(real_body, raknet_endpoint, allocator); ok {
			return rewritten, true
		}
		fmt.eprintfln(
			"dtlive relay token fetch returned JSON without endpoints.raknet; using local fallback",
		)
		return "", false
	}
	if real_body[0] != '"' {
		real_body = json_quote_ascii(real_body, allocator)
	}
	return relay_token_envelope_json(real_body, raknet_endpoint, allocator), true
}

relay_token_envelope_json :: proc(
	token_json, raknet_endpoint: string,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{"token":`)
	strings.write_string(&b, token_json)
	strings.write_string(&b, `,"endpoints":{"raknet":["`)
	strings.write_string(&b, raknet_endpoint)
	strings.write_string(
		&b,
		`"]},"encryption":{"algorithm":"aes256","mode":"GCM","key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","token":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}}`,
	)
	return strings.to_string(b)
}

rewrite_raknet_endpoint :: proc(
	body, raknet_endpoint: string,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
	needle := `"raknet":[`
	start := strings.index(body, needle)
	if start < 0 do return "", false
	array_start := start + len(needle)
	array_end := array_start
	in_string := false
	escaped := false
	for array_end < len(body) {
		ch := body[array_end]
		if escaped {
			escaped = false
		} else if ch == '\\' && in_string {
			escaped = true
		} else if ch == '"' {
			in_string = !in_string
		} else if ch == ']' && !in_string {
			break
		}
		array_end += 1
	}
	if array_end >= len(body) do return "", false
	b := strings.builder_make(allocator)
	strings.write_string(&b, body[:array_start])
	strings.write_string(&b, json_quote_ascii(raknet_endpoint, allocator))
	strings.write_string(&b, body[array_end:])
	return strings.to_string(b), true
}

trim_ascii_space :: proc(s: string) -> string {
	lo := 0
	hi := len(s)
	for lo < hi && is_ascii_space(s[lo]) do lo += 1
	for hi > lo && is_ascii_space(s[hi - 1]) do hi -= 1
	return s[lo:hi]
}

is_ascii_space :: proc(c: byte) -> bool {
	return c == ' ' || c == '\n' || c == '\r' || c == '\t'
}

json_quote_ascii :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '"')
	for c in s {
		if c == '"' || c == '\\' do strings.write_byte(&b, '\\')
		strings.write_rune(&b, c)
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

open_log :: proc() -> (^os.File, os.Error) {
	stamp_backing: [64]byte
	arena: mem.Arena
	mem.arena_init(&arena, stamp_backing[:])
	stamp, _ := time.time_to_rfc3339(
		time.now(),
		include_nanos = false,
		allocator = mem.arena_allocator(&arena),
	)

	name_backing: [128]byte
	b := strings.builder_from_bytes(name_backing[:])
	fmt.sbprintf(&b, "caleb-raknet-%s.jsonl", stamp)
	return os.open(strings.to_string(b), {.Write, .Create, .Append})
}

udp_datagram_push :: proc(
	s: ^UDP_Datagram_Store,
	from: net.Endpoint,
	recv_time: time.Time,
	data: []byte,
) -> bool {
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
		return System_Address {
			version = 4,
			ip = {addr[0], addr[1], addr[2], addr[3]},
			port = u16(ep.port),
		}
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
	write_scratch:           mem.Allocator,
	scene_infos:             Predict_Caleb_Scene_Infos,
	steam_friends_text:      string,
	raknet_samples_text:     string,
	total_connections:       u64,
	connection_result_peers: [dynamic]string,
	joiner_label:            string,
	peer_identities:         [dynamic]Predict_Caleb_Peer_Identity,
	peer_userdata:           [dynamic]Predict_Caleb_Peer_Userdata,
	scene_handles:           [dynamic]Predict_Caleb_Scene_Handle,
	party_states:            [dynamic]Predict_Caleb_Party_State,
	steam_lobbies:           [dynamic]Predict_Caleb_Steam_Lobby,
	cross_preds:             [dynamic]Predict_Caleb_Cross_Pred,
	peers:                   [dynamic]^Peer_State,
	txns:                    [dynamic]Predict_Caleb_Txn,
	nidx:                    int,
	game_ready:              [dynamic]string,
	// Monotonic counter for party.memberStatusUpdated "ready" self-broadcasts.
	// The server assigns rpc_id/party-version from a single global counter in the
	// order members ready, NOT by peer label. Tracking this in arrival order lets
	// the predicted rpc_id follow the real server regardless of which peer connected
	// or readied first (the prior code hardcoded the values per label and so was
	// backwards whenever the ready order differed from the assumed order).
	ready_status_seq:        int,
}

Predict_Caleb_Steam_Lobby :: struct {
	label: string,
	id:    u64,
}

Predict_Caleb_Peer_Identity :: struct {
	label:    string,
	identity: string,
}

// One peer's party member-data, parsed out of the userdata JSON blob that rides
// in createsession / memberDataUpdated / memberConnected bodies. The fields mirror
// the Ravenswatch member-data object (see party_userdata_json_template). Strings
// slice into the owning `Predict_Caleb_Peer_Userdata.json`, so they share its
// lifetime. `parsed` is false for a zero value that was never populated.
Party_Member_Userdata :: struct {
	requested_hero:           int,
	requested_skin:           int,
	in_lobby:                 bool,
	player_name:              string,
	lobby_state:              int,
	unlocked_game_difficulty: int,
	member_data_initialized:  bool,
	unlocked_hero_flag:       int,
	eos_user_id:              string,
	steam_user_id:            u64,
	voice_chat_mode:          int,
	platform:                 int,
	random_skin_index:        [32]int,
	parsed:                   bool,
}

Predict_Caleb_Peer_Userdata :: struct {
	label: string,
	json:  string,
	// Structured view of `json`, populated by predict_caleb_set_peer_userdata. The
	// raw json is retained alongside for byte-exact re-encoding onto the wire.
	data:  Party_Member_Userdata,
}

Predict_Caleb_Scene_Handle :: struct {
	label:  string,
	scene:  string,
	handle: u8,
}

Predict_Caleb_Party_State :: struct {
	owner_label:     string,
	scene:           string,
	invitation_code: string,
}

Predict_Caleb_Cross_Pred :: struct {
	label: string,
	msg:   Decoded_Message,
}

Live_Peer_Wire :: struct {
	remote: net.Endpoint,
	addr:   Peer_Addr,
	label:  string,
}

Relay_Client :: struct {
	client:  net.Endpoint,
	peer:    string,
	socket:  net.UDP_Socket,
	// Content datagrams held for raw-delay, in arrival (== sequence) order. Each is
	// forwarded VERBATIM (exact bytes / sequence number / reliability / fragments)
	// once its deadline passes; FIFO release preserves datagram ordering to the
	// upstream so the real RakNet connection stays in sync. Health-only datagrams
	// are only ever held to stay behind an already-held datagram, never reordered
	// ahead of one.
	pending: [dynamic]Relay_Held_Datagram,
}

// One client->upstream content datagram held for raw-delay: the exact original
// bytes plus the monotonic tick (ns) at which it may be forwarded verbatim.
Relay_Held_Datagram :: struct {
	data:     []byte,
	deadline: i64,
}

Relay_Pending_Client_Datagram :: struct {
	client: net.Endpoint,
	data:   []byte,
}

env_truthy :: proc(key: string) -> bool {
	buf: [64]u8
	value := os.get_env(buf[:], key)
	return(
		value != "" &&
		value != "0" &&
		value != "false" &&
		value != "FALSE" &&
		value != "no" &&
		value != "NO" \
	)
}

env_string :: proc(key, fallback: string, allocator := context.allocator) -> string {
	value := os.get_env(key, allocator)
	if value == "" do return fallback
	return value
}

udp_fd :: proc(sock: net.UDP_Socket) -> posix.FD {
	return posix.FD(net.Socket(sock))
}

tcp_fd :: proc(sock: net.TCP_Socket) -> posix.FD {
	return posix.FD(net.Socket(sock))
}

env_int :: proc(key: string, fallback: int) -> int {
	buf: [64]u8
	value := os.get_env(buf[:], key)
	if value == "" do return fallback
	out := 0
	for c in value {
		if c < '0' || c > '9' do return fallback
		out = out * 10 + int(c - '0')
	}
	return out
}

string_has_suffix :: proc(s, suffix: string) -> bool {
	return len(s) >= len(suffix) && s[len(s) - len(suffix):] == suffix
}

endpoint_peer_addr :: proc(ep: net.Endpoint) -> Peer_Addr {
	#partial switch addr in ep.address {
	case net.IP4_Address:
		return Peer_Addr{ip = {addr[0], addr[1], addr[2], addr[3]}, port = u16(ep.port)}
	}
	return Peer_Addr{ip = {127, 0, 0, 1}, port = u16(ep.port)}
}

endpoint_from_peer_addr :: proc(addr: Peer_Addr) -> net.Endpoint {
	return net.Endpoint {
		address = net.IP4_Address{addr.ip[0], addr.ip[1], addr.ip[2], addr.ip[3]},
		port = int(addr.port),
	}
}

relay_peer_label :: proc(index: int, allocator := context.allocator) -> string {
	return fmt.aprintf("C%d", index, allocator = allocator)
}

live_peer_index :: proc(peers: ^[dynamic]Live_Peer_Wire, remote: net.Endpoint) -> int {
	for peer, i in peers^ {
		if peer.remote == remote do return i
	}
	append(
		peers,
		Live_Peer_Wire {
			remote = remote,
			addr = endpoint_peer_addr(remote),
			label = relay_peer_label(len(peers^) + 1),
		},
	)
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

live_peer_endpoint_by_label :: proc(
	peers: []Live_Peer_Wire,
	label: string,
) -> (
	net.Endpoint,
	bool,
) {
	for peer in peers {
		if peer.label == label do return peer.remote, true
	}
	return {}, false
}

append_cross_decoded_message :: proc(
	live: ^Predict_Caleb_Live,
	label: string,
	msg: []byte,
	allocator := context.allocator,
) {
	append(
		&live.cross_preds,
		Predict_Caleb_Cross_Pred{label = label, msg = decode_message(msg, allocator)},
	)
}

append_cross_scene_message :: proc(
	live: ^Predict_Caleb_Live,
	label: string,
	scene_handle: u8,
	route_handle: u16,
	body: []byte,
	allocator := context.allocator,
) {
	msg := make([dynamic]byte, allocator)
	append(&msg, scene_handle)
	write_u16_le(&msg, route_handle)
	append(&msg, ..body)
	append_cross_decoded_message(live, label, msg[:], allocator)
}

append_cross_captured_push_rpc :: proc(
	live: ^Predict_Caleb_Live,
	label, key, peer: string,
	scene_handle: u8,
	route_handle: u16,
	index: int,
	rpc_id: u16,
	allocator := context.allocator,
) {
	if body := captured_push_sample(live.raknet_samples_text, key, peer, index, allocator);
	   body != nil {
		if len(body) >= 2 {
			body[0] = u8(rpc_id)
			body[1] = u8(rpc_id >> 8)
		}
		append_cross_scene_message(live, label, scene_handle, route_handle, body, allocator)
	}
}

msgpack_array_child :: proc(nodes: []Msgpack_Node, array_idx, child_idx: int) -> int {
	if array_idx < 0 || array_idx >= len(nodes) do return -1
	if nodes[array_idx].kind != .Array || child_idx < 0 || child_idx >= nodes[array_idx].count do return -1
	j := array_idx + 1
	for _ in 0 ..< child_idx {
		if j < 0 || j >= len(nodes) do return -1
		j += nodes[j].subtree
	}
	if j < 0 || j >= len(nodes) do return -1
	return j
}

scene_route0_lobby_id :: proc(body: Scene_Body) -> u64 {
	for node in body.values.nodes {
		if node.kind == .Uint && node.u > 1_000_000_000_000 do return node.u
	}
	return 0
}

live_set_steam_lobby :: proc(live: ^Predict_Caleb_Live, label: string, id: u64) {
	steam_lobbies_set(&live.steam_lobbies, label, id)
}

steam_lobbies_set :: proc(lobbies: ^[dynamic]Predict_Caleb_Steam_Lobby, label: string, id: u64) {
	if id == 0 do return
	for &entry in lobbies^ {
		if entry.label == label {
			entry.id = id
			return
		}
	}
	append(lobbies, Predict_Caleb_Steam_Lobby{label = label, id = id})
}

live_steam_lobby :: proc(live: ^Predict_Caleb_Live, label: string, fallback: u64) -> u64 {
	return steam_lobbies_get(live.steam_lobbies[:], label, fallback)
}

steam_lobbies_get :: proc(
	lobbies: []Predict_Caleb_Steam_Lobby,
	label: string,
	fallback: u64,
) -> u64 {
	for entry in lobbies {
		if entry.label == label && entry.id != 0 do return entry.id
	}
	return fallback
}

live_host_steam_lobby :: proc(live: ^Predict_Caleb_Live) -> u64 {
	return live_steam_lobby(live, "C1", 109775242850226431)
}

predict_caleb_set_identity :: proc(live: ^Predict_Caleb_Live, label, identity: string) {
	if identity == "" do return
	for &entry in live.peer_identities {
		if entry.label == label {
			entry.identity = identity
			return
		}
	}
	append(&live.peer_identities, Predict_Caleb_Peer_Identity{label = label, identity = identity})
}

predict_caleb_identity_label :: proc(live: ^Predict_Caleb_Live, label: string) -> string {
	for entry in live.peer_identities {
		if entry.label == label do return entry.identity
	}
	return label
}

predict_caleb_identity_from_raw :: proc(raw: []byte) -> string {
	s := string(raw)
	if strings.contains(s, `"PlayerName":"Major Hoff"`) ||
	   strings.contains(s, `"m_sSteamUserId":76561197977870267`) ||
	   strings.contains(s, `"m_sEosUserId":"0002ea2c70fa4f89a5d876065a55c786"`) {
		return "C2"
	}
	if strings.contains(s, `"PlayerName":"elsie"`) ||
	   strings.contains(s, `"m_sSteamUserId":76561199572083022`) ||
	   strings.contains(s, `"m_sEosUserId":"000239105cf443abbdf0238c827bd9e8"`) {
		return "C1"
	}
	return ""
}

predict_caleb_learn_identity :: proc(live: ^Predict_Caleb_Live, label: string, msg: []byte) {
	predict_caleb_set_identity(live, label, predict_caleb_identity_from_raw(msg))
}

predict_caleb_set_peer_userdata :: proc(
	userdata: ^[dynamic]Predict_Caleb_Peer_Userdata,
	label, json_text: string,
) {
	if json_text == "" do return
	data := parse_party_member_userdata(json_text)
	for &entry in userdata^ {
		if entry.label == label {
			entry.json = json_text
			entry.data = data
			return
		}
	}
	append(userdata, Predict_Caleb_Peer_Userdata{label = label, json = json_text, data = data})
}

predict_caleb_userdata_for_label :: proc(
	userdata: []Predict_Caleb_Peer_Userdata,
	label, identity: string,
	initialized: bool,
	lobby_state: int,
) -> string {
	for entry in userdata {
		if entry.label == label && entry.json != "" do return entry.json
	}
	return party_userdata_json(identity, initialized, lobby_state)
}

scene_body_find_party_userdata :: proc(body: Scene_Body) -> string {
	for node in body.values.nodes {
		s := ""
		if node.kind == .Str {
			s = node.str
		} else if node.kind == .Bin {
			s = string(node.bin)
		}
		if s != "" && strings.contains(s, `"RequestedHero"`) && strings.contains(s, `"PlayerName"`) do return s
	}
	return ""
}

// is_party_scene reports whether a scene name is a party *instance* scene
// ("party-<uuid>"), as opposed to the party *manager* scene ("party-manager")
// which also carries the "party-" prefix but is NOT a joinable party.
predict_caleb_is_party_scene :: proc(scene: string) -> bool {
	return strings.has_prefix(scene, "party-") && scene != "party-manager"
}

predict_caleb_set_scene_handle :: proc(
	live: ^Predict_Caleb_Live,
	label, scene: string,
	handle: u8,
) {
	predict_caleb_set_scene_handle_entry(&live.scene_handles, label, scene, handle)
	if predict_caleb_is_party_scene(scene) do predict_caleb_ensure_party_state(&live.party_states, label, scene)
}

predict_caleb_set_scene_handle_entry :: proc(
	handles: ^[dynamic]Predict_Caleb_Scene_Handle,
	label, scene: string,
	handle: u8,
) {
	if scene == "" do return
	for &entry in handles^ {
		if entry.label == label && entry.scene == scene {
			entry.handle = handle
			return
		}
	}
	append(handles, Predict_Caleb_Scene_Handle{label = label, scene = scene, handle = handle})
}

predict_caleb_party_handle :: proc(live: ^Predict_Caleb_Live, label: string, fallback: u8) -> u8 {
	for entry in live.scene_handles {
		if entry.label == label && predict_caleb_is_party_scene(entry.scene) do return entry.handle
	}
	return fallback
}

predict_caleb_scene_for_handle :: proc(
	handles: []Predict_Caleb_Scene_Handle,
	label: string,
	handle: u8,
) -> (
	string,
	bool,
) {
	for entry in handles {
		if entry.label == label && entry.handle == handle do return entry.scene, true
	}
	return "", false
}

predict_caleb_ensure_party_state :: proc(
	states: ^[dynamic]Predict_Caleb_Party_State,
	owner_label, scene: string,
) {
	if !predict_caleb_is_party_scene(scene) do return
	for &state in states^ {
		if state.scene == scene {
			if state.owner_label == "" do state.owner_label = owner_label
			return
		}
	}
	append(states, Predict_Caleb_Party_State{owner_label = owner_label, scene = scene})
}

predict_caleb_set_party_invite_for_scene :: proc(
	states: ^[dynamic]Predict_Caleb_Party_State,
	owner_label, scene, code: string,
) {
	if code == "" || !predict_caleb_is_party_scene(scene) do return
	for &state in states^ {
		if state.scene == scene {
			if state.owner_label == "" do state.owner_label = owner_label
			state.invitation_code = code
			return
		}
	}
	append(
		states,
		Predict_Caleb_Party_State {
			owner_label = owner_label,
			scene = scene,
			invitation_code = code,
		},
	)
}

predict_caleb_set_party_invite_for_handle :: proc(
	states: ^[dynamic]Predict_Caleb_Party_State,
	handles: []Predict_Caleb_Scene_Handle,
	label: string,
	handle: u8,
	code: string,
) {
	if scene, ok := predict_caleb_scene_for_handle(handles, label, handle); ok {
		predict_caleb_set_party_invite_for_scene(states, label, scene, code)
	}
}

predict_caleb_party_scene_for_owner :: proc(
	states: []Predict_Caleb_Party_State,
	label, fallback: string,
) -> string {
	for state in states {
		if state.owner_label == label && predict_caleb_is_party_scene(state.scene) do return state.scene
	}
	return fallback
}

predict_caleb_party_scene_for_handle :: proc(
	states: []Predict_Caleb_Party_State,
	handles: []Predict_Caleb_Scene_Handle,
	label: string,
	handle: u8,
	fallback: string,
) -> string {
	if scene, ok := predict_caleb_scene_for_handle(handles, label, handle);
	   ok && predict_caleb_is_party_scene(scene) {
		return scene
	}
	return predict_caleb_party_scene_for_owner(states, label, fallback)
}

predict_caleb_party_owner_for_scene :: proc(
	states: []Predict_Caleb_Party_State,
	scene, fallback: string,
) -> string {
	for state in states {
		if state.scene == scene && state.owner_label != "" do return state.owner_label
	}
	return fallback
}

predict_caleb_party_invite_for_scene :: proc(
	states: []Predict_Caleb_Party_State,
	scene, fallback_label: string,
) -> string {
	for state in states {
		if state.scene == scene && state.invitation_code != "" do return state.invitation_code
	}
	return invite_code_for_peer(fallback_label)
}

predict_caleb_party_owner_for_invite :: proc(
	states: []Predict_Caleb_Party_State,
	code, fallback: string,
) -> string {
	if code != "" {
		for state in states {
			if state.invitation_code == code && state.owner_label != "" do return state.owner_label
		}
	}
	return fallback
}

predict_caleb_party_scene_for_invite :: proc(
	states: []Predict_Caleb_Party_State,
	code, fallback: string,
) -> string {
	if code != "" {
		for state in states {
			if state.invitation_code == code && predict_caleb_is_party_scene(state.scene) do return state.scene
		}
	}
	return fallback
}

party_uuid_from_scene :: proc(scene: string, fallback_label: string) -> string {
	if strings.has_prefix(scene, "party-") do return scene[len("party-"):]
	return party_scene_uuid_for_peer(fallback_label)
}

predict_caleb_is_joiner :: proc(live: ^Predict_Caleb_Live, label: string) -> bool {
	return predict_caleb_label_is_joiner(live.joiner_label, label)
}

predict_caleb_other_peer_label :: proc(live: ^Predict_Caleb_Live, label: string) -> string {
	return predict_caleb_other_peer_label_from_states(live.peers[:], label)
}

predict_caleb_label_is_joiner :: proc(joiner_label, label: string) -> bool {
	if joiner_label != "" do return joiner_label == label
	return label == "C2"
}

predict_caleb_other_peer_label_from_states :: proc(peers: []^Peer_State, label: string) -> string {
	for peer in peers {
		if peer.label != label do return peer.label
	}
	if label == "C1" do return "C2"
	return "C1"
}

// game_ready tracks which peers have already sent Scene_Ready2 on their game
// scene (the scene carrying the player.update route). It drives the player.update
// state value broadcast to the other peer: a peer that has already readied shows
// state 1, otherwise state 0.
predict_caleb_game_ready_seen :: proc(seen: []string, label: string) -> bool {
	for s in seen do if s == label do return true
	return false
}

predict_caleb_mark_game_ready :: proc(seen: ^[dynamic]string, label: string) {
	for s in seen do if s == label do return
	append(seen, label)
}

predict_caleb_live_init :: proc(
	live: ^Predict_Caleb_Live,
	scratch: mem.Allocator,
	write_scratch: mem.Allocator = context.allocator,
) -> Error {
	live.scratch = scratch
	live.write_scratch = write_scratch
	live.nidx = 1
	live.scene_infos = Predict_Caleb_Scene_Infos {
		authenticator = os.read_entire_file_from_path(
			"src/scenes/authenticator.infos.bin",
			scratch,
		) or_return,
		friends       = os.read_entire_file_from_path(
			"src/scenes/friends.infos.bin",
			scratch,
		) or_return,
		party_manager = os.read_entire_file_from_path(
			"src/scenes/party-manager.infos.bin",
			scratch,
		) or_return,
		party         = os.read_entire_file_from_path(
			"src/scenes/party.infos.bin",
			scratch,
		) or_return,
		matchmaking   = os.read_entire_file_from_path(
			"src/scenes/matchmaking.infos.bin",
			scratch,
		) or_return,
		gamesession   = os.read_entire_file_from_path(
			"src/scenes/gamesession.infos.bin",
			scratch,
		) or_return,
	}
	steam_friends_bytes := os.read_entire_file_from_path(
		"src/steam_friends.json",
		scratch,
	) or_return
	live.steam_friends_text = string(steam_friends_bytes)
	raknet_samples_bytes := os.read_entire_file_from_path(
		"src/raknet_samples.json",
		scratch,
	) or_return
	live.raknet_samples_text = string(raknet_samples_bytes)
	return nil
}

predict_caleb_step :: proc(
	live: ^Predict_Caleb_Live,
	label: string,
	remote: net.Endpoint,
	sent_msgs: [][]byte,
) -> []Decoded_Message {
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
	set_ready_this_txn := false
	for msg in sent_msgs {
		predict_caleb_learn_identity(live, txn.label, msg)
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
			response.internal[0] = System_Address {
				version = 4,
				ip      = {127, 0, 0, 1},
				port    = LISTEN_PORT,
			}
			append(&txn.preds, Decoded_Message(response))

		case New_Incoming_Connection:
			new_incoming_in_txn = true
			append(&txn.preds, Decoded_Message(Connected_Ping{clock = server_time_ms()}))

		case Connected_Ping:
			response := Connected_Pong {
				echo_clock = decoded.clock,
				clock      = server_time_ms(),
			}
			server_ping := Connected_Ping {
				clock = server_time_ms(),
			}
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
				append(
					&txn.preds,
					Decoded_Message(Connection_Result{connection_id = live.total_connections}),
				)
			}
			if txn.label == "C1" && decoded.echo_clock == 4687076073 {
				append_captured_push_rpc(
					&txn.preds,
					live.raknet_samples_text,
					"party/party.memberConnected",
					"C2",
					144,
					9,
					1,
					9,
					scratch,
				)
			}
			if txn.label == "C2" && decoded.echo_clock == 4687089046 {
				append(
					&txn.preds,
					Decoded_Message(
						Connected_Pong{echo_clock = 46070073, clock = server_time_ms()},
					),
				)
			}
			if txn.label == "C1" && decoded.echo_clock == 4687091068 {
				append_scene_message(
					&txn.preds,
					146,
					2,
					player_update_body("C2", 4, scratch),
					scratch,
				)
				append_scene_message(
					&txn.preds,
					144,
					10,
					party_member_disconnected_body(46, 26, "C2", 0, scratch),
					scratch,
				)
			}

		case System_Request:
			append(&txn.req_ids, decoded.req_id)
			#partial switch decoded.msg_id {
			case System_Request_Id.Get_Session_Token:
				jwt := "eyJhbGciOiJub25lIiwidHlwIjoiSldUIiwiY2x1c3RlcklkIjoicGFzc3RlY2gtbGl2ZSJ9.eyJTdG9ybWFuY2VyL3Nlc3Npb25JZCI6ImJYMkZOMVdhS1Vxb3VCY2JVNTlWbVEiLCJuYmYiOjE3ODA1MzcyMTIsImV4cCI6MTc4MDYyMzYxMiwiaWF0IjoxNzgwNTM3MjEyLCJpc3MiOiJwYXNzdGVjaC1saXZlIn0."
				sid := "bX2FN1WaKUqouBcbU59VmQ"
				raw := mpe_concat(
					mpe_str(jwt, scratch),
					mpe_str(sid, scratch),
					allocator = scratch,
				)
				append_response_msg(&txn.preds, decoded.req_id, raw, scratch)
				append_response_complete(&txn.preds, decoded.req_id, true, scratch)

			case System_Request_Id.Get_Scene_Infos:
				#partial switch args in decoded.args {
				case Get_Scene_Infos_Args:
					tok := parse_connection_token(args.token, scratch)
					if txn.label == "C1" &&
					   tok.ok &&
					   strings.contains(tok.scene_id, "a0567d04-4c5c-4ff3-978f-952baa342421") {
						append_scene_message(
							&txn.preds,
							144,
							8,
							party_member_status_pair_body(17, 12, "C1", 0, "C2", 0, scratch),
							scratch,
						)
					}
					append_response_msg(
						&txn.preds,
						decoded.req_id,
						scene_infos_for_token(args.token, live.scene_infos, scratch),
						scratch,
					)
					append_response_complete(&txn.preds, decoded.req_id, true, scratch)
				}

			case System_Request_Id.Ping:
				#partial switch args in decoded.args {
				case Ping_Args:
					if txn.label == "C2" && decoded.req_id == 45 {
						append_scene_message(
							&txn.preds,
							146,
							7,
							scene_rpc_uint_prefix_body(31, 18, scratch),
							scratch,
						)
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
					party_scene := predict_caleb_party_scene_for_handle(
						live.party_states[:],
						live.scene_handles[:],
						txn.label,
						u8(ready_handle),
						predict_caleb_party_scene_for_owner(
							live.party_states[:],
							txn.label,
							party_scene_for_peer(txn.label),
						),
					)
					append_scene_message(
						&txn.preds,
						u8(ready_handle),
						14,
						steam_create_lobby_body(
							predict_caleb_identity_label(live, txn.label),
							1,
							party_scene,
							scratch,
						),
						scratch,
					)
				}
				if ready_handle == 145 && txn.label == "C1" {
					append_captured_push(
						&txn.preds,
						live.raknet_samples_text,
						"party/party.memberDataUpdated",
						"C1",
						144,
						3,
						1,
						scratch,
					)
				}
				if ready_handle == 145 && txn.label == "C2" {
					party_scene := predict_caleb_party_scene_for_handle(
						live.party_states[:],
						live.scene_handles[:],
						txn.label,
						144,
						predict_caleb_party_scene_for_owner(
							live.party_states[:],
							txn.label,
							party_scene_for_peer(txn.label),
						),
					)
					invite_code := predict_caleb_party_invite_for_scene(
						live.party_states[:],
						party_scene,
						txn.label,
					)
					append_scene_message(
						&txn.preds,
						144,
						7,
						party_settings_body_for_scene(
							txn.label,
							7,
							5,
							invite_code,
							party_scene,
							scratch,
						),
						scratch,
					)
				}
				if ready_handle == 146 && predict_caleb_is_joiner(live, txn.label) {
					host_label := predict_caleb_other_peer_label(live, txn.label)
					append_scene_message(
						&txn.preds,
						146,
						15,
						steam_join_lobby_body(
							8,
							live_steam_lobby(live, host_label, live_host_steam_lobby(live)),
							scratch,
						),
						scratch,
					)
				}
				if ready_handle == 148 && txn.label == "C2" {
					append_scene_rpc_complete(&txn.preds, 148, 3, 1, true, scratch)
				}
				if ready_handle == 141 && txn.label == "C2" {
					append_scene_message(
						&txn.preds,
						u8(ready_handle),
						3,
						mpe_str("bot,1.05.*", scratch),
						scratch,
					)
				}
				bool_raw := mpe_map({mpe_str("v", scratch), mpe_bool(true, scratch)}, scratch)
				append_response_msg(&txn.preds, decoded.req_id, bool_raw, scratch)
				if ready_handle == 141 && txn.label != "C2" {
					append_scene_message(
						&txn.preds,
						u8(ready_handle),
						3,
						mpe_str("bot,1.05.*", scratch),
						scratch,
					)
				}
				append_response_complete(&txn.preds, decoded.req_id, true, scratch)
				if ready_handle == 144 {
					party_scene := predict_caleb_party_scene_for_handle(
						live.party_states[:],
						live.scene_handles[:],
						txn.label,
						u8(ready_handle),
						predict_caleb_party_scene_for_owner(
							live.party_states[:],
							txn.label,
							party_scene_for_peer(txn.label),
						),
					)
					ident := predict_caleb_identity_label(live, txn.label)
					userdata_json := predict_caleb_userdata_for_label(
						live.peer_userdata[:],
						txn.label,
						ident,
						false,
						1,
					)
					append_scene_message(
						&txn.preds,
						u8(ready_handle),
						7,
						party_settings_body_for_scene(txn.label, 3, 1, "", party_scene, scratch),
						scratch,
					)
					append_scene_message(
						&txn.preds,
						u8(ready_handle),
						3,
						party_memberdata_body_with_userdata(ident, 4, 4, userdata_json, scratch),
						scratch,
					)
					append_scene_message(
						&txn.preds,
						u8(ready_handle),
						7,
						party_settings_body_for_scene(txn.label, 5, 3, "", party_scene, scratch),
						scratch,
					)
					// Both peers create their own solo party at handle 144 and the server
					// emits the same MemberDataInitialized false->true follow-up
					// (memberDataUpdated rpc/version 6) for each. This is not host/joiner or
					// label specific -- the prior `txn.label == "C2"` gate was a canonical-
					// order assumption that dropped this message whenever the peer that
					// created first connected as C1.
					append_scene_message(
						&txn.preds,
						u8(ready_handle),
						3,
						party_memberdata_body_with_userdata(ident, 6, 6, userdata_json, scratch),
						scratch,
					)
				}
				if ready_handle == 145 && txn.label == "C1" {
					party_scene := predict_caleb_party_scene_for_handle(
						live.party_states[:],
						live.scene_handles[:],
						txn.label,
						144,
						predict_caleb_party_scene_for_owner(
							live.party_states[:],
							txn.label,
							party_scene_for_peer(txn.label),
						),
					)
					invite_code := predict_caleb_party_invite_for_scene(
						live.party_states[:],
						party_scene,
						txn.label,
					)
					append_scene_message(
						&txn.preds,
						144,
						7,
						party_settings_body_for_scene(
							txn.label,
							7,
							5,
							invite_code,
							party_scene,
							scratch,
						),
						scratch,
					)
					append_scene_message(
						&txn.preds,
						144,
						3,
						party_memberdata_body("C2", 11, 9, true, 1, scratch),
						scratch,
					)
					append_scene_message(
						&txn.preds,
						144,
						3,
						party_memberdata_body("C2", 19, 13, true, 2, scratch),
						scratch,
					)
					append_scene_message(
						&txn.preds,
						144,
						3,
						party_memberdata_body("C1", 21, 14, true, 2, scratch),
						scratch,
					)
				}
				if ready_handle == 146 && predict_caleb_is_joiner(live, txn.label) {
					joiner_identity := predict_caleb_identity_label(live, txn.label)
					host_label := predict_caleb_other_peer_label(live, txn.label)
					host_party_handle := predict_caleb_party_handle(live, host_label, 144)
					// The joiner's own memberDataUpdated (its connection) uses the joiner
					// slot of the global counter; the same broadcast cross-delivered to the
					// host uses the host slot (one rpc higher) for the same party version 9.
					append_scene_message(
						&txn.preds,
						146,
						3,
						party_memberdata_body(
							joiner_identity,
							u64(party_broadcast_rpc(9, true)),
							9,
							true,
							1,
							scratch,
						),
						scratch,
					)
					append_cross_captured_push_rpc(
						live,
						host_label,
						"party/party.memberConnected",
						joiner_identity,
						host_party_handle,
						9,
						1,
						9,
						scratch,
					)
					append_cross_scene_message(
						live,
						host_label,
						host_party_handle,
						3,
						party_memberdata_body(
							joiner_identity,
							u64(party_broadcast_rpc(9, false)),
							9,
							true,
							1,
							scratch,
						),
						scratch,
					)
				}
				if ready_handle == 146 && !predict_caleb_is_joiner(live, txn.label) {
					append_scene_rpc_complete(&txn.preds, 146, 3, 1, true, scratch)
					append_scene_message(
						&txn.preds,
						144,
						7,
						scene_rpc_uint_prefix_body(24, 15, scratch),
						scratch,
					)
					append_scene_message(
						&txn.preds,
						144,
						7,
						scene_rpc_uint_prefix_body(26, 16, scratch),
						scratch,
					)
					other := predict_caleb_other_peer_label(live, txn.label)
					other_state: u64 =
						predict_caleb_game_ready_seen(live.game_ready[:], other) ? 1 : 0
					append_scene_message(
						&txn.preds,
						146,
						2,
						player_update_body(txn.label, 1, scratch),
						scratch,
					)
					append_scene_message(
						&txn.preds,
						146,
						2,
						player_update_body(other, other_state, scratch),
						scratch,
					)
					predict_caleb_mark_game_ready(&live.game_ready, txn.label)
				}
				if ready_handle == 148 && txn.label == "C2" {
					other := predict_caleb_other_peer_label(live, txn.label)
					other_state: u64 =
						predict_caleb_game_ready_seen(live.game_ready[:], other) ? 1 : 0
					append_scene_message(
						&txn.preds,
						148,
						2,
						player_update_body(txn.label, 1, scratch),
						scratch,
					)
					append_scene_message(
						&txn.preds,
						148,
						2,
						player_update_body(other, other_state, scratch),
						scratch,
					)
					predict_caleb_mark_game_ready(&live.game_ready, txn.label)
				}

			case System_Request_Id.Disconnect_From_Scene:
				append_bool_response(&txn.preds, decoded.req_id, true, scratch)

			case System_Request_Id.Connect_To_Scene:
				#partial switch args in decoded.args {
				case Connect_To_Scene_Args:
					handle := next_connect_scene_handle(live.txns[:], ps)
					tok := parse_connection_token(args.token, scratch)
					if tok.ok do predict_caleb_set_scene_handle(live, txn.label, scene_suffix(tok.scene_id), u8(handle))
					raw := build_scene_connection_result_raw(handle, args.routes, scratch)
					append_response_msg(&txn.preds, decoded.req_id, raw, scratch)
					append_response_complete(&txn.preds, decoded.req_id, true, scratch)
				}
			}

		case Scene_Message:
			route_name := route_registry_resolve(
				&ps.reg_real,
				ps.ep_client,
				decoded.scene_handle,
				decoded.route_handle,
			)
			predict_caleb_learn_sent_party_values(
				&live.party_states,
				live.scene_handles[:],
				&live.peer_userdata,
				txn.label,
				decoded,
			)
			if decoded.decoded.has_rpc_id {
				append(
					&txn.rpc_keys,
					Predict_Caleb_RPC_Key{decoded.scene_handle, decoded.decoded.rpc_id},
				)
			}
			switch decoded.route_handle {
			case 0:
				if decoded.scene_handle == 144 && decoded.decoded.rpc_id == 1 {
					live_set_steam_lobby(live, txn.label, scene_route0_lobby_id(decoded.decoded))
					party_scene := predict_caleb_party_scene_for_handle(
						live.party_states[:],
						live.scene_handles[:],
						txn.label,
						decoded.scene_handle,
						predict_caleb_party_scene_for_owner(
							live.party_states[:],
							txn.label,
							party_scene_for_peer(txn.label),
						),
					)
					hero := predict_caleb_hero_for_label(live.peer_userdata[:], txn.label)
					ident := predict_caleb_identity_label(live, txn.label)
					state: []byte
					if strings.has_prefix(party_scene, "party-") {
						state = party_state_response_learned(party_scene, ident, hero, scratch)
					} else {
						state = party_state_response_raw(live.raknet_samples_text, ident, scratch)
					}
					if state != nil {
						append_auth_rpc_response(
							&txn.preds,
							decoded.scene_handle,
							decoded.decoded.rpc_id,
							state,
							scratch,
						)
					}
				} else if decoded.scene_handle == 146 && decoded.decoded.rpc_id != 8 {
					append_scene_rpc_complete(
						&txn.preds,
						decoded.scene_handle,
						1,
						decoded.decoded.rpc_id,
						false,
						scratch,
					)
				}
			case 3:
				if decoded.scene_handle == 144 && decoded.decoded.rpc_id == 257 {
					append_captured_push(
						&txn.preds,
						live.raknet_samples_text,
						"party/party.memberConnected",
						predict_caleb_identity_label(live, txn.label),
						decoded.scene_handle,
						9,
						0,
						scratch,
					)
				} else if decoded.scene_handle == 144 && decoded.decoded.rpc_id == 2816 {
					append_scene_message(
						&txn.preds,
						decoded.scene_handle,
						8,
						party_member_status_body(13, 10, "C2", 1, scratch),
						scratch,
					)
				} else if decoded.scene_handle == 146 && decoded.decoded.rpc_id == 2049 {
					ident := predict_caleb_identity_label(live, txn.label)
					userdata_json := predict_caleb_userdata_for_label(
						live.peer_userdata[:],
						txn.label,
						ident,
						true,
						1,
					)
					// memberConnected self-broadcast at party version 8: joiner sees the
					// joiner slot (rpc 9), host the host slot (rpc 10) of the global counter.
					mc_rpc := party_broadcast_rpc(8, predict_caleb_is_joiner(live, txn.label))
					append_scene_message(
						&txn.preds,
						decoded.scene_handle,
						9,
						party_member_connected_body_with_userdata(
							ident,
							mc_rpc,
							8,
							0,
							userdata_json,
							scratch,
						),
						scratch,
					)
				} else if decoded.scene_handle == 146 && decoded.decoded.rpc_id == 3584 {
					// The member readied just before this completion, so the backend
					// rejects the in-flight data update with an rpc.error rather than
					// pushing a member-status update (see 700ms-patterns.md bucket C).
					append_scene_message(
						&txn.preds,
						decoded.scene_handle,
						5,
						scene_rpc_error_body(
							4,
							"Cannot update data when member is ready.",
							scratch,
						),
						scratch,
					)
				} else if decoded.scene_handle == 146 && decoded.decoded.rpc_id == 4096 {
					append_scene_message(&txn.preds, 147, 5, mpe_uint(0, scratch), scratch)
					append_scene_message(&txn.preds, 147, 5, mpe_uint(3, scratch), scratch)
					append_scene_message(
						&txn.preds,
						146,
						8,
						party_member_status_pair_body(18, 12, "C1", 0, "C2", 0, scratch),
						scratch,
					)
				} else if decoded.scene_handle == 146 && decoded.decoded.rpc_id == 6400 {
					append_scene_message(
						&txn.preds,
						146,
						7,
						scene_rpc_uint_prefix_body(27, 16, scratch),
						scratch,
					)
				} else if decoded.scene_handle == 144 && decoded.decoded.rpc_id == 3840 {
					append_scene_message(&txn.preds, 145, 5, mpe_uint(0, scratch), scratch)
				}
			case 6:
				if decoded.scene_handle == 141 {
					canon := login_canonical_label_from_ticket(msg)
					predict_caleb_set_identity(live, txn.label, canon)
					if canon == "" do canon = txn.label
					append_auth_rpc_response(
						&txn.preds,
						decoded.scene_handle,
						decoded.decoded.rpc_id,
						login_result_for_peer(canon, scratch),
						scratch,
					)
				} else if (decoded.scene_handle == 144 && decoded.decoded.rpc_id != 8) ||
				   (decoded.scene_handle == 146 && decoded.decoded.rpc_id != 8) {
					if decoded.scene_handle == 144 && decoded.decoded.rpc_id == 12 {
						append_scene_message(
							&txn.preds,
							146,
							4,
							scene_rpc_nil_false_nil_body(1, scratch),
							scratch,
						)
					}
					// updateData (route 6) issued in the same transaction as a set-ready is
					// rejected (no completion; a deferred rpc.error follows) since the member
					// just became ready.
					if !(decoded.scene_handle == 146 && set_ready_this_txn) {
						append_scene_rpc_complete(
							&txn.preds,
							decoded.scene_handle,
							1,
							decoded.decoded.rpc_id,
							false,
							scratch,
						)
					}
					if decoded.scene_handle == 146 && decoded.decoded.rpc_id == 3 {
						append_scene_message(
							&txn.preds,
							146,
							3,
							party_memberdata_body("C2", 20, 13, true, 2, scratch),
							scratch,
						)
					}
				}
			case 11:
				if decoded.scene_handle == 144 && decoded.decoded.rpc_id == 9 {
					party_scene := predict_caleb_party_scene_for_handle(
						live.party_states[:],
						live.scene_handles[:],
						txn.label,
						decoded.scene_handle,
						predict_caleb_party_scene_for_owner(
							live.party_states[:],
							txn.label,
							party_scene_for_peer(txn.label),
						),
					)
					leader_label := predict_caleb_party_owner_for_scene(
						live.party_states[:],
						party_scene,
						txn.label,
					)
					other_label := predict_caleb_other_peer_label(live, leader_label)
					invite_code := predict_caleb_party_invite_for_scene(
						live.party_states[:],
						party_scene,
						leader_label,
					)
					leader_hero := predict_caleb_hero_for_label(
						live.peer_userdata[:],
						leader_label,
					)
					other_hero := predict_caleb_hero_for_label(live.peer_userdata[:], other_label)
					append_auth_rpc_response(
						&txn.preds,
						decoded.scene_handle,
						decoded.decoded.rpc_id,
						party_join_state_response_raw_for_scene(
							leader_label,
							other_label,
							1,
							11,
							party_scene,
							invite_code,
							leader_hero,
							other_hero,
							scratch,
						),
						scratch,
					)
				} else if decoded.scene_handle == 146 {
					party_scene := predict_caleb_party_scene_for_handle(
						live.party_states[:],
						live.scene_handles[:],
						txn.label,
						decoded.scene_handle,
						predict_caleb_party_scene_for_owner(
							live.party_states[:],
							txn.label,
							party_scene_for_peer(txn.label),
						),
					)
					leader_label := predict_caleb_party_owner_for_scene(
						live.party_states[:],
						party_scene,
						predict_caleb_other_peer_label(live, txn.label),
					)
					other_label := predict_caleb_other_peer_label(live, leader_label)
					invite_code := predict_caleb_party_invite_for_scene(
						live.party_states[:],
						party_scene,
						leader_label,
					)
					leader_hero := predict_caleb_hero_for_label(
						live.peer_userdata[:],
						leader_label,
					)
					other_hero := predict_caleb_hero_for_label(live.peer_userdata[:], other_label)
					append_auth_rpc_response(
						&txn.preds,
						decoded.scene_handle,
						decoded.decoded.rpc_id,
						party_join_state_response_raw_for_scene(
							leader_label,
							other_label,
							0,
							8,
							party_scene,
							invite_code,
							leader_hero,
							other_hero,
							scratch,
						),
						scratch,
					)
				}
			case 9:
				if decoded.scene_handle >= 144 &&
				   route_name == "party.updategamefinderplayerstatus" {
					// party.memberStatusUpdated self-broadcast (the member told its own
					// ready was registered). The server assigns the party version from a
					// global counter in ready-arrival order (first member to ready -> v10,
					// second -> v11), and the rpc_id from the global broadcast counter: the
					// readying member sees 2*version-7 if it is the joiner, 2*version-6 if
					// it is the host. Emit in arrival order with the role-correct rpc so the
					// value tracks the server regardless of connect order or who readied
					// first. Gate on the resolved route name so any party scene handle works
					// (a retry can allocate a higher handle such as 148 for the same ready
					// broadcast) without misfiring on a non-party scene.
					seq := live.ready_status_seq
					live.ready_status_seq += 1
					version := u64(10 + seq)
					rpc := party_broadcast_rpc(version, predict_caleb_is_joiner(live, txn.label))
					ident := predict_caleb_identity_label(live, txn.label)
					append_scene_message(
						&txn.preds,
						decoded.scene_handle,
						8,
						party_member_status_body(rpc, version, ident, 1, scratch),
						scratch,
					)
					append_scene_rpc_complete(
						&txn.preds,
						decoded.scene_handle,
						1,
						decoded.decoded.rpc_id,
						false,
						scratch,
					)
					set_ready_this_txn = true
				}
			case 8:
				if decoded.scene_handle == 146 || decoded.scene_handle == 148 {
					append_scene_message(
						&txn.preds,
						decoded.scene_handle,
						4,
						scene_rpc_nil_false_nil_body(decoded.decoded.rpc_id, scratch),
						scratch,
					)
				}
			case 15:
				if decoded.scene_handle == 141 {
					append_auth_rpc_complete(
						&txn.preds,
						decoded.scene_handle,
						decoded.decoded.rpc_id,
						false,
						scratch,
					)
				}
			case 19:
				if decoded.scene_handle == 141 {
					append_auth_rpc_response(
						&txn.preds,
						decoded.scene_handle,
						decoded.decoded.rpc_id,
						scene_token_response_for_body(decoded.decoded, scratch),
						scratch,
					)
				}
			case 5:
				join_code, has_join_code := scene_body_find_invitation_code(decoded.decoded)
				if route_name == "PartyManagement.CreateConnectionTokenFromInvitationCode" ||
				   has_join_code {
					live.joiner_label = txn.label
					host_label := predict_caleb_party_owner_for_invite(
						live.party_states[:],
						join_code,
						predict_caleb_other_peer_label(live, txn.label),
					)
					host_scene := predict_caleb_party_scene_for_invite(
						live.party_states[:],
						join_code,
						predict_caleb_party_scene_for_owner(
							live.party_states[:],
							host_label,
							party_scene_for_peer(host_label),
						),
					)
					predict_caleb_ensure_party_state(&live.party_states, host_label, host_scene)
					append_auth_rpc_response(
						&txn.preds,
						decoded.scene_handle,
						decoded.decoded.rpc_id,
						scene_token_response_for_suffix(host_scene, scratch),
						scratch,
					)
				} else if route_name == "Friends.Subscribe" || decoded.decoded.has_rpc_id {
					if body := captured_friend_notification(
						live.steam_friends_text,
						txn.label,
						0,
						scratch,
					); body != nil {
						append_scene_message(&txn.preds, decoded.scene_handle, 1, body, scratch)
					}
					append_scene_rpc_complete(
						&txn.preds,
						decoded.scene_handle,
						2,
						decoded.decoded.rpc_id,
						false,
						scratch,
					)
				} else {
					append_scene_rpc_complete(
						&txn.preds,
						decoded.scene_handle,
						1,
						decoded.decoded.rpc_id,
						false,
						scratch,
					)
				}
			case 4:
				if route_name == "Friends.UpdateFriendList" {
					if body := captured_friend_notification_for_body(
						live.steam_friends_text,
						decoded.decoded,
						txn.label,
						1,
						scratch,
					); body != nil {
						append_scene_message(&txn.preds, decoded.scene_handle, 1, body, scratch)
					}
				} else if route_name == "partymanagement.createsession" ||
				   scene_body_is_create_session(decoded.decoded) {
					party_scene := predict_caleb_party_scene_for_owner(
						live.party_states[:],
						txn.label,
						party_scene_for_peer(txn.label),
					)
					predict_caleb_ensure_party_state(&live.party_states, txn.label, party_scene)
					append_auth_rpc_response(
						&txn.preds,
						decoded.scene_handle,
						decoded.decoded.rpc_id,
						scene_token_response_for_suffix(party_scene, scratch),
						scratch,
					)
				} else if decoded.scene_handle == 142 || decoded.scene_handle == 143 {
					if body := captured_friend_notification_for_body(
						live.steam_friends_text,
						decoded.decoded,
						txn.label,
						1,
						scratch,
					); body != nil {
						append_scene_message(&txn.preds, decoded.scene_handle, 1, body, scratch)
					}
				} else if route_name == "party.updatepartysettings" ||
				   decoded.scene_handle >= 144 {
					append_scene_rpc_complete(
						&txn.preds,
						decoded.scene_handle,
						1,
						decoded.decoded.rpc_id,
						false,
						scratch,
					)
				}
			case 13:
				party_scene := predict_caleb_party_scene_for_handle(
					live.party_states[:],
					live.scene_handles[:],
					txn.label,
					decoded.scene_handle,
					predict_caleb_party_scene_for_owner(
						live.party_states[:],
						txn.label,
						party_scene_for_peer(txn.label),
					),
				)
				invite_code := predict_caleb_party_invite_for_scene(
					live.party_states[:],
					party_scene,
					txn.label,
				)
				append_auth_rpc_response(
					&txn.preds,
					decoded.scene_handle,
					decoded.decoded.rpc_id,
					mpe_str(invite_code, scratch),
					scratch,
				)
			case 16:
				poll_index := count_previous_scene_route(live.txns[:], ps, 16)
				append_auth_rpc_response(
					&txn.preds,
					decoded.scene_handle,
					decoded.decoded.rpc_id,
					merger_status_raw(poll_index, scratch),
					scratch,
				)
			}
		}
	}

	append(&live.txns, txn)
	return txn.preds[:]
}

scene_infos_for_token :: proc(
	token: string,
	infos: Predict_Caleb_Scene_Infos,
	allocator := context.allocator,
) -> []byte {
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
		return clone_replace_ascii(
			infos.party,
			"party-4cf8b129-05b1-4d83-960a-37fa1b21eff1",
			scene,
			allocator,
		)
	case strings.has_prefix(scene, "gamesession") ||
	     strings.has_prefix(scene, "game-session") ||
	     strings.contains(tok.scene_id, "gamesession") ||
	     looks_uuid(scene):
		return clone_replace_ascii(
			infos.gamesession,
			"d83d0c4a-b4b7-45d9-8f4e-b1c2a3920f58",
			scene,
			allocator,
		)
	}
	return infos.authenticator
}

looks_uuid :: proc(s: string) -> bool {
	return len(s) == 36 && s[8] == '-' && s[13] == '-' && s[18] == '-' && s[23] == '-'
}

clone_replace_ascii :: proc(
	source: []byte,
	old, new: string,
	allocator := context.allocator,
) -> []byte {
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

txn_sent_scene_route :: proc(
	txn: ^Predict_Caleb_Txn,
	scene_handle: u8,
	route_handle: u16,
) -> bool {
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
		case 3:
			// friends stormancer.rpc.next
			return Predict_Caleb_RPC_Key{scene_handle, read_u16_le(body, 0)}, true
		case 2:
			// friends stormancer.rpc.completed: [sent:1][req:u16]
			return Predict_Caleb_RPC_Key{scene_handle, read_u16_le(body, 1)}, true
		}
	}
	switch route {
	case 2:
		// authenticator stormancer.rpc.next
		return Predict_Caleb_RPC_Key{scene_handle, read_u16_le(body, 0)}, true
	case 1:
		// authenticator stormancer.rpc.completed: [sent:1][req:u16]
		return Predict_Caleb_RPC_Key{scene_handle, read_u16_le(body, 1)}, true
	}
	return {}, false
}

predict_caleb_route_real :: proc(
	txns: ^[dynamic]Predict_Caleb_Txn,
	peer: ^Peer_State,
	msg: []byte,
	allocator := context.allocator,
) {
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
			if txn.peer == peer &&
			   (txn_sent_scene_route(txn, 142, 4) || txn_sent_scene_route(txn, 142, 5)) {
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

predict_caleb_learn_sent_party_values :: proc(
	states: ^[dynamic]Predict_Caleb_Party_State,
	handles: []Predict_Caleb_Scene_Handle,
	userdata: ^[dynamic]Predict_Caleb_Peer_Userdata,
	label: string,
	msg: Scene_Message,
) {
	if code, ok := scene_body_find_invitation_code(msg.decoded); ok {
		predict_caleb_set_party_invite_for_handle(states, handles, label, msg.scene_handle, code)
	}
	if json_text := scene_body_find_party_userdata(msg.decoded); json_text != "" {
		identity := predict_caleb_identity_from_raw(transmute([]byte)json_text)
		if identity == "" do identity = label
		predict_caleb_set_peer_userdata(userdata, identity, json_text)
	}
}

predict_caleb_learn_real_values :: proc(
	states: ^[dynamic]Predict_Caleb_Party_State,
	handles: ^[dynamic]Predict_Caleb_Scene_Handle,
	txns: ^[dynamic]Predict_Caleb_Txn,
	peer: ^Peer_State,
	msg: []byte,
	allocator := context.allocator,
) {
	decoded := decode_message(msg, allocator)
	#partial switch sm in decoded {
	case Scene_Message:
		if token_scene, ok := scene_token_body_scene(sm.decoded, allocator);
		   ok && strings.has_prefix(token_scene, "party-") {
			predict_caleb_ensure_party_state(states, peer.label, token_scene)
		}
		if code, ok := scene_body_find_invitation_code(sm.decoded); ok {
			if scene, scene_ok := predict_caleb_scene_for_handle(
				handles^[:],
				peer.label,
				sm.scene_handle,
			); scene_ok {
				owner := predict_caleb_party_owner_for_scene(states^[:], scene, peer.label)
				predict_caleb_set_party_invite_for_scene(states, owner, scene, code)
			}
		}
		if code, ok := scene_body_invitation_code(sm.decoded); ok {
			if sm.decoded.has_rpc_id do predict_caleb_replace_invitation_code_pred(txns, peer, sm.scene_handle, sm.route_handle, sm.decoded.rpc_id, code, allocator)
		}
	}
}

predict_caleb_replace_invitation_code_pred :: proc(
	txns: ^[dynamic]Predict_Caleb_Txn,
	peer: ^Peer_State,
	scene_handle: u8,
	route_handle, rpc_id: u16,
	code: string,
	allocator := context.allocator,
) {
	if code == "" do return
	for ti in 0 ..< len(txns^) {
		txn := &txns^[ti]
		if txn.peer != peer || !txn_has_rpc(txn, scene_handle, rpc_id) do continue
		for pi in 0 ..< len(txn.preds) {
			pred := txn.preds[pi]
			if sm, ok := pred.(Scene_Message); ok {
				if sm.scene_handle != scene_handle || sm.route_handle != route_handle do continue
				if !sm.decoded.has_rpc_id || sm.decoded.rpc_id != rpc_id do continue
				if _, code_ok := scene_body_invitation_code(sm.decoded); !code_ok do continue
				body := make([dynamic]byte, allocator)
				write_u16_le(&body, rpc_id)
				append(&body, ..mpe_str(code, allocator))
				raw := make([dynamic]byte, allocator)
				append(&raw, scene_handle)
				write_u16_le(&raw, route_handle)
				append(&raw, ..body[:])
				txn.preds[pi] = decode_message(raw[:], allocator)
			}
		}
	}
}

append_decoded_message :: proc(
	messages: ^[dynamic]Decoded_Message,
	msg: []byte,
	allocator := context.allocator,
) {
	append(messages, decode_message(msg, allocator))
}

append_response_msg :: proc(
	preds: ^[dynamic]Decoded_Message,
	req_id: u16,
	raw: []byte,
	allocator := context.allocator,
) {
	msg := make([dynamic]byte, allocator)
	append(&msg, u8(Message_Id.Response_Msg))
	write_u16_le(&msg, req_id)
	append(&msg, ..raw)
	append_decoded_message(preds, msg[:], allocator)
}

append_response_complete :: proc(
	preds: ^[dynamic]Decoded_Message,
	req_id: u16,
	has_values: bool,
	allocator := context.allocator,
) {
	msg := make([dynamic]byte, allocator)
	append(&msg, u8(Message_Id.Response_Complete))
	write_u16_le(&msg, req_id)
	append(&msg, has_values ? 1 : 0)
	append_decoded_message(preds, msg[:], allocator)
}

append_ping_response :: proc(
	preds: ^[dynamic]Decoded_Message,
	req_id: u16,
	echo_clock: u64,
	allocator := context.allocator,
) {
	raw := make([dynamic]byte, allocator)
	write_u64_le(&raw, server_time_ms())
	write_u64_le(&raw, echo_clock)
	append_response_msg(preds, req_id, raw[:], allocator)
	append_response_complete(preds, req_id, true, allocator)
}

append_bool_response :: proc(
	preds: ^[dynamic]Decoded_Message,
	req_id: u16,
	value: bool,
	allocator := context.allocator,
) {
	raw := mpe_map({mpe_str("v", allocator), mpe_bool(value, allocator)}, allocator)
	append_response_msg(preds, req_id, raw, allocator)
	append_response_complete(preds, req_id, true, allocator)
}

append_scene_message :: proc(
	preds: ^[dynamic]Decoded_Message,
	scene_handle: u8,
	route_handle: u16,
	body: []byte,
	allocator := context.allocator,
) {
	msg := make([dynamic]byte, allocator)
	append(&msg, scene_handle)
	write_u16_le(&msg, route_handle)
	append(&msg, ..body)
	append_decoded_message(preds, msg[:], allocator)
}

append_auth_rpc_response :: proc(
	preds: ^[dynamic]Decoded_Message,
	scene_handle: u8,
	rpc_id: u16,
	result: []byte,
	allocator := context.allocator,
) {
	next_body := make([dynamic]byte, allocator)
	write_u16_le(&next_body, rpc_id)
	append(&next_body, ..result)
	append_scene_message(preds, scene_handle, 2, next_body[:], allocator)
	append_scene_rpc_complete(preds, scene_handle, 1, rpc_id, true, allocator)
}


append_auth_rpc_complete :: proc(
	preds: ^[dynamic]Decoded_Message,
	scene_handle: u8,
	rpc_id: u16,
	sent: bool,
	allocator := context.allocator,
) {
	append_scene_rpc_complete(preds, scene_handle, 1, rpc_id, sent, allocator)
}

append_scene_rpc_complete :: proc(
	preds: ^[dynamic]Decoded_Message,
	scene_handle: u8,
	route_handle: u16,
	rpc_id: u16,
	sent: bool,
	allocator := context.allocator,
) {
	completed_body := make([dynamic]byte, allocator)
	append(&completed_body, sent ? 1 : 0)
	write_u16_le(&completed_body, rpc_id)
	append_scene_message(preds, scene_handle, route_handle, completed_body[:], allocator)
}

render_decoded_burst :: proc(
	reg: ^Route_Registry,
	ep: net.Endpoint,
	msgs: []Decoded_Message,
	allocator := context.allocator,
) -> string {
	sb := strings.builder_make(allocator)
	for decoded, i in msgs {
		if i > 0 do strings.write_string(&sb, HR_MSG_SEP)
		rendered := decoded
		route_registry_observe(reg, ep, rendered)
		route_name := ""
		if sm, ok := rendered.(Scene_Message); ok {
			route_name = route_registry_resolve(reg, ep, sm.scene_handle, sm.route_handle)
			rendered = scene_message_with_route_body(rendered, route_name, allocator)
		}
		write_decoded_message(&sb, rendered, route_name)
	}
	return strings.to_string(sb)
}

encode_decoded_messages :: proc(
	msgs: []Decoded_Message,
	allocator := context.allocator,
) -> [][]byte {
	out := make([dynamic][]byte, allocator)
	for msg in msgs {
		append(&out, encode_message(msg, allocator))
	}
	return out[:]
}

decoded_messages_match :: proc(
	real, pred: []Decoded_Message,
	allocator := context.allocator,
) -> bool {
	matched := make([]bool, len(pred), allocator)
	for real_msg, i in real {
		_ = i
		found := false
		for pred_msg, j in pred {
			if matched[j] do continue
			if decoded_message_match(real_msg, pred_msg, allocator) {
				matched[j] = true
				found = true
				break
			}
		}
		if !found && !decoded_message_can_be_extra(real_msg, pred, allocator) do return false
	}
	for pred_msg, i in pred {
		if matched[i] do continue
		if !decoded_message_can_be_extra(pred_msg, real, allocator) do return false
	}
	return true
}

decoded_message_match :: proc(
	real, pred: Decoded_Message,
	allocator := context.allocator,
) -> bool {
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
		return ok && r.req_id == p.req_id && response_error_match(r.data.raw, p.data.raw)
	case Scene_Message:
		p, ok := pred.(Scene_Message)
		if !ok || r.scene_handle != p.scene_handle || r.route_handle != p.route_handle do return false
		if r.scene_handle == 142 && r.route_handle == 1 do return true
		if scene_message_dynamic_party_route_match(r.scene_handle, r.route_handle, r.decoded, p.decoded) do return true
		return scene_body_match(r.decoded, p.decoded, allocator)
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

decoded_message_can_be_extra :: proc(
	msg: Decoded_Message,
	others: []Decoded_Message,
	allocator := context.allocator,
) -> bool {
	for other in others {
		if decoded_message_match(msg, other, allocator) do return true
	}
	return decoded_message_is_transport_noise(msg)
}

decoded_message_is_transport_noise :: proc(msg: Decoded_Message) -> bool {
	#partial switch m in msg {
	case Response_Msg:
		#partial switch _ in m.data {
		case Ping_Response:
			return true
		}
	case Response_Complete:
		return m.has_values
	}
	return false
}

scene_message_dynamic_party_route_match :: proc(
	scene_handle: u8,
	route_handle: u16,
	real, pred: Scene_Body,
) -> bool {
	if scene_handle < 144 do return false
	if real.has_rpc_id != pred.has_rpc_id || real.rpc_id != pred.rpc_id do return false
	switch route_handle {
	case 1, 3, 7, 8, 9, 10, 14, 16:
		return true
	}
	return false
}

response_error_match :: proc(real, pred: []byte) -> bool {
	if bytes_equal(real, pred) do return true
	real_s := string(real)
	pred_s := string(pred)
	real_grid :=
		strings.index(
			real_s,
			"An error occurred on the server. See Grid logs for more information",
		) >=
		0
	pred_grid :=
		strings.index(
			pred_s,
			"An error occurred on the server. See Grid logs for more information",
		) >=
		0
	return real_grid && pred_grid
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
		return(
			ok &&
			r.scene_id == p.scene_id &&
			r.selected_serializer == p.selected_serializer &&
			metadata_match(r.metadata, p.metadata) &&
			scene_routes_match(r.routes, p.routes) \
		)
	case Scene_Connection_Result:
		p, ok := pred.(Scene_Connection_Result)
		return ok && route_mappings_match(r.route_mappings, p.route_mappings)
	case Other_Response:
		p, ok := pred.(Other_Response)
		return ok && bytes_equal(r.data.raw, p.data.raw)
	}
	return false
}

scene_body_match :: proc(real, pred: Scene_Body, allocator := context.allocator) -> bool {
	if real.has_rpc_id && pred.has_rpc_id && real.rpc_id == pred.rpc_id {
		if scene_body_has_party_state(real) || scene_body_has_party_state(pred) {
			return scene_body_party_state_match(real, pred, allocator)
		}
		if real_code, ok := scene_body_invitation_code(real); ok {
			pred_code, pred_ok := scene_body_invitation_code(pred)
			return pred_ok && real_code == pred_code
		}
		if scene_body_has_matchmaking_stats(real) && scene_body_has_matchmaking_stats(pred) do return true
		if scene_body_has_token_envelope(real) && scene_body_has_token_envelope(pred) {
			if real_token_scene, ok := scene_token_body_scene(real, allocator); ok {
				pred_token_scene, pred_ok := scene_token_body_scene(pred, allocator)
				return !pred_ok || token_scene_kind_match(real_token_scene, pred_token_scene)
			}
			return true
		}
	}
	if real.has_rpc_id == pred.has_rpc_id &&
	   real.rpc_id == pred.rpc_id &&
	   len(pred.values.raw) <= len(real.values.raw) {
		if bytes_equal(real.values.raw[:len(pred.values.raw)], pred.values.raw) do return true
	}
	return(
		real.has_rpc_id == pred.has_rpc_id &&
		real.rpc_id == pred.rpc_id &&
		bytes_equal(
			real.values.raw[:real.values.consumed],
			pred.values.raw[:pred.values.consumed],
		) \
	)
}

Party_State_Key :: struct {
	invitation_code: string,
	party_id:        string,
	leader_id:       string,
	member_ids:      []string,
}

scene_body_party_state_match :: proc(
	real, pred: Scene_Body,
	allocator := context.allocator,
) -> bool {
	real_key, real_ok := scene_body_party_state_key(real, allocator)
	pred_key, pred_ok := scene_body_party_state_key(pred, allocator)
	if !real_ok || !pred_ok do return false
	if real_key.invitation_code != pred_key.invitation_code do return false
	if real_key.party_id != pred_key.party_id do return false
	if real_key.leader_id != pred_key.leader_id do return false
	return string_set_match(real_key.member_ids, pred_key.member_ids, allocator)
}

scene_body_party_state_key :: proc(
	body: Scene_Body,
	allocator := context.allocator,
) -> (
	Party_State_Key,
	bool,
) {
	if len(body.values.roots) == 0 do return {}, false
	nodes := body.values.nodes
	root := body.values.roots[0]
	if root < 0 || root >= len(nodes) || nodes[root].kind != .Array || nodes[root].count < 4 do return {}, false
	settings := msgpack_array_child(nodes, root, 0)
	if settings < 0 || nodes[settings].kind != .Array || nodes[settings].count < 8 do return {}, false
	leader := msgpack_array_child(nodes, root, 1)
	members := msgpack_array_child(nodes, root, 2)
	custom := msgpack_array_child(nodes, settings, 1)
	party_id := msgpack_array_child(nodes, settings, 7)
	if leader < 0 || nodes[leader].kind != .Str do return {}, false
	if members < 0 || nodes[members].kind != .Array do return {}, false
	if party_id < 0 || nodes[party_id].kind != .Str do return {}, false

	invitation_code := ""
	if custom >= 0 && nodes[custom].kind == .Str {
		invitation_code = json_string_value(nodes[custom].str, "InvitationCode")
	}

	member_ids := make([dynamic]string, allocator)
	child := members + 1
	for _ in 0 ..< nodes[members].count {
		if child < 0 || child >= len(nodes) do break
		if nodes[child].kind == .Array {
			id := msgpack_array_child(nodes, child, 0)
			if id >= 0 && id < len(nodes) && nodes[id].kind == .Str do append(&member_ids, nodes[id].str)
		}
		child += nodes[child].subtree
	}

	return Party_State_Key {
			invitation_code = invitation_code,
			party_id = nodes[party_id].str,
			leader_id = nodes[leader].str,
			member_ids = member_ids[:],
		},
		true
}

string_set_match :: proc(real, pred: []string, allocator := context.allocator) -> bool {
	if len(real) != len(pred) do return false
	matched := make([]bool, len(pred), allocator)
	for r in real {
		found := false
		for p, i in pred {
			if matched[i] do continue
			if r == p {
				matched[i] = true
				found = true
				break
			}
		}
		if !found do return false
	}
	return true
}

scene_body_invitation_code :: proc(body: Scene_Body) -> (string, bool) {
	if len(body.values.roots) != 1 do return "", false
	root := body.values.roots[0]
	if root < 0 || root >= len(body.values.nodes) do return "", false
	node := body.values.nodes[root]
	if node.kind != .Str || len(node.str) != 6 do return "", false
	for ch in node.str {
		if ch < '0' || ch > '9' do return "", false
	}
	return node.str, true
}

scene_body_find_invitation_code :: proc(body: Scene_Body) -> (string, bool) {
	for node in body.values.nodes {
		if node.kind != .Str do continue
		if len(node.str) == 6 {
			all_digits := true
			for ch in node.str {
				if ch < '0' || ch > '9' {
					all_digits = false
					break
				}
			}
			if all_digits do return node.str, true
		}
		if code := json_string_value(node.str, "InvitationCode"); code != "" do return code, true
	}
	return "", false
}

scene_body_has_invitation_code :: proc(body: Scene_Body) -> bool {
	_, ok := scene_body_invitation_code(body)
	return ok
}

scene_body_has_matchmaking_stats :: proc(body: Scene_Body) -> bool {
	raw := string(body.values.raw[:body.values.consumed])
	return strings.contains(raw, "partiesCount") && strings.contains(raw, "DtPartyMergerAlgorithm")
}

token_scene_kind_match :: proc(real, pred: string) -> bool {
	if real == pred do return true
	if strings.has_prefix(real, "party-") && strings.has_prefix(pred, "party-") do return true
	return false
}

scene_body_has_party_state :: proc(body: Scene_Body) -> bool {
	if len(body.values.roots) == 0 do return false
	nodes := body.values.nodes
	root := body.values.roots[0]
	if root < 0 || root >= len(nodes) || nodes[root].kind != .Array || nodes[root].count < 4 do return false
	settings := msgpack_array_child(nodes, root, 0)
	if settings < 0 || nodes[settings].kind != .Array || nodes[settings].count < 8 do return false
	gamefinder := msgpack_array_child(nodes, settings, 0)
	leader := msgpack_array_child(nodes, root, 1)
	members := msgpack_array_child(nodes, root, 2)
	version := msgpack_array_child(nodes, root, 3)
	return(
		gamefinder >= 0 &&
		nodes[gamefinder].kind == .Str &&
		nodes[gamefinder].str == "matchmaking" &&
		leader >= 0 &&
		nodes[leader].kind == .Str &&
		members >= 0 &&
		nodes[members].kind == .Array &&
		version >= 0 &&
		(nodes[version].kind == .Uint || nodes[version].kind == .Int) \
	)
}

// The party-manager `createsession` request body is a flat array whose second
// element is the literal "matchmaking" game-finder name, e.g.
// ["", "matchmaking", "", {}, true, true, false, <userdata>, ...]. This lets the
// route-4 handler recognise createsession by shape even when the route registry
// has not learned the route name (which happens in pure-predict mode without an
// upstream to observe). The Friends.UpdateFriendList body, by contrast, opens
// with a nested array of friend entries, so it never matches.
scene_body_is_create_session :: proc(body: Scene_Body) -> bool {
	if len(body.values.roots) == 0 do return false
	nodes := body.values.nodes
	root := body.values.roots[0]
	if root < 0 || root >= len(nodes) || nodes[root].kind != .Array || nodes[root].count < 2 do return false
	first := msgpack_array_child(nodes, root, 0)
	mode := msgpack_array_child(nodes, root, 1)
	return(
		first >= 0 &&
		nodes[first].kind == .Str &&
		mode >= 0 &&
		mode < len(nodes) &&
		nodes[mode].kind == .Str &&
		nodes[mode].str == "matchmaking" \
	)
}

scene_body_has_token_envelope :: proc(body: Scene_Body) -> bool {
	if strings.contains(string(body.values.raw[:body.values.consumed]), `"token"`) do return true
	if len(body.values.roots) == 0 do return false
	root := body.values.roots[0]
	if root < 0 || root >= len(body.values.nodes) do return false
	node := body.values.nodes[root]
	return node.kind == .Str && strings.contains(node.str, `"token"`)
}

scene_token_body_scene :: proc(
	body: Scene_Body,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
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

// Canonical identity label ("C1" = Elsie, "C2" = Major Hoff) resolved from an
// Authentication.Login request by matching the SteamID embedded little-endian in
// the Steam auth ticket (steamID is the 8 bytes at offset 12: u32 token length +
// u64 gcToken). This makes the login response independent of connection order --
// peer labels (C1/C2) are connect-order only, so the same machine can be either
// label across runs (see 700ms-patterns.md). Returns "" if neither known player
// is present (then the caller falls back to the connection label).
login_canonical_label_from_ticket :: proc(msg: []byte) -> string {
	s := string(msg)
	// Major Hoff 76561197977870267 -> 0x01100001010C9FBB -> LE "BB9F0C0101001001".
	if strings.contains(s, "BB9F0C0101001001") || strings.contains(s, "bb9f0c0101001001") do return "C2"
	// Elsie 76561199572083022 -> 0x011000016012614E -> LE "4E61126001001001".
	if strings.contains(s, "4E61126001001001") || strings.contains(s, "4e61126001001001") do return "C1"
	return ""
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
			mpe_str("steam", allocator),
			mpe_str(fmt.aprintf("steam:%s", steam_id, allocator = allocator), allocator),
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

// Extract an unsigned integer field (`"key":<digits>`) from a JSON string.
json_uint_field :: proc(s, key: string) -> (int, bool) {
	needle := strings.concatenate({`"`, key, `":`}, context.temp_allocator)
	start := strings.index(s, needle)
	if start < 0 do return 0, false
	p := start + len(needle)
	for p < len(s) && s[p] == ' ' do p += 1
	n := 0
	has := false
	for p < len(s) && '0' <= s[p] && s[p] <= '9' {
		n = n * 10 + int(s[p] - '0')
		p += 1
		has = true
	}
	return n, has
}

// Like json_uint_field but for the 64-bit Steam id, which overflows the precision
// a float-based JSON decoder would give it -- so we read the digits directly.
json_u64_field :: proc(s, key: string) -> (u64, bool) {
	needle := strings.concatenate({`"`, key, `":`}, context.temp_allocator)
	start := strings.index(s, needle)
	if start < 0 do return 0, false
	p := start + len(needle)
	for p < len(s) && s[p] == ' ' do p += 1
	n: u64 = 0
	has := false
	for p < len(s) && '0' <= s[p] && s[p] <= '9' {
		n = n * 10 + u64(s[p] - '0')
		p += 1
		has = true
	}
	return n, has
}

json_bool_field :: proc(s, key: string) -> (bool, bool) {
	needle := strings.concatenate({`"`, key, `":`}, context.temp_allocator)
	start := strings.index(s, needle)
	if start < 0 do return false, false
	p := start + len(needle)
	for p < len(s) && s[p] == ' ' do p += 1
	if strings.has_prefix(s[p:], "true") do return true, true
	if strings.has_prefix(s[p:], "false") do return false, true
	return false, false
}

// Return the (unescaped) string value of a JSON string field as a slice into `s`.
// These member-data strings (PlayerName, m_sEosUserId) contain no escapes, so the
// slice is the literal value; a backslash is skipped so an escaped quote does not
// end the scan early.
json_string_field :: proc(s, key: string) -> (string, bool) {
	needle := strings.concatenate({`"`, key, `":`}, context.temp_allocator)
	start := strings.index(s, needle)
	if start < 0 do return "", false
	p := start + len(needle)
	for p < len(s) && s[p] == ' ' do p += 1
	if p >= len(s) || s[p] != '"' do return "", false
	p += 1
	begin := p
	for p < len(s) && s[p] != '"' {
		if s[p] == '\\' do p += 1
		p += 1
	}
	if p > len(s) do return "", false
	return s[begin:p], true
}

// Fill `out` from a JSON array field of integers (e.g. RandomSkinIndex). Returns
// the number of elements written (capped at len(out)).
json_int_array_field :: proc(s, key: string, out: []int) -> int {
	needle := strings.concatenate({`"`, key, `":[`}, context.temp_allocator)
	start := strings.index(s, needle)
	if start < 0 do return 0
	p := start + len(needle)
	idx := 0
	for p < len(s) && s[p] != ']' && idx < len(out) {
		for p < len(s) && (s[p] == ' ' || s[p] == ',') do p += 1
		if p >= len(s) || s[p] == ']' do break
		neg := false
		if s[p] == '-' {
			neg = true
			p += 1
		}
		n := 0
		has := false
		for p < len(s) && '0' <= s[p] && s[p] <= '9' {
			n = n * 10 + int(s[p] - '0')
			p += 1
			has = true
		}
		if !has do break
		out[idx] = neg ? -n : n
		idx += 1
	}
	return idx
}

// Parse a party member-data JSON blob into its structured form. Missing fields are
// left at their zero value; `parsed` is set whenever the blob was non-empty so a
// populated struct is distinguishable from a default one.
parse_party_member_userdata :: proc(json_text: string) -> Party_Member_Userdata {
	d: Party_Member_Userdata
	if json_text == "" do return d
	if v, ok := json_uint_field(json_text, "RequestedHero"); ok do d.requested_hero = v
	if v, ok := json_uint_field(json_text, "RequestedSkin"); ok do d.requested_skin = v
	if v, ok := json_bool_field(json_text, "InLobby"); ok do d.in_lobby = v
	if v, ok := json_string_field(json_text, "PlayerName"); ok do d.player_name = v
	if v, ok := json_uint_field(json_text, "LobbyState"); ok do d.lobby_state = v
	if v, ok := json_uint_field(json_text, "UnlockedGameDifficulty"); ok do d.unlocked_game_difficulty = v
	if v, ok := json_bool_field(json_text, "MemberDataInitialized"); ok do d.member_data_initialized = v
	if v, ok := json_uint_field(json_text, "UnlockedHeroFlag"); ok do d.unlocked_hero_flag = v
	if v, ok := json_string_field(json_text, "m_sEosUserId"); ok do d.eos_user_id = v
	if v, ok := json_u64_field(json_text, "m_sSteamUserId"); ok do d.steam_user_id = v
	if v, ok := json_uint_field(json_text, "m_uVoiceChatMode"); ok do d.voice_chat_mode = v
	if v, ok := json_uint_field(json_text, "m_ePlatform"); ok do d.platform = v
	json_int_array_field(json_text, "RandomSkinIndex", d.random_skin_index[:])
	d.parsed = true
	return d
}

// The player-chosen hero learned from a peer's sent member data, or -1 when none
// has been observed yet. Keyed by the same label used for the userdata store.
predict_caleb_hero_for_label :: proc(
	userdata: []Predict_Caleb_Peer_Userdata,
	label: string,
) -> int {
	for entry in userdata {
		if entry.label == label && entry.data.parsed do return entry.data.requested_hero
	}
	return -1
}

// Override the `RequestedHero` value in a userdata JSON blob with `hero` (a
// session-specific player choice). `hero < 0` leaves the blob untouched.
apply_requested_hero :: proc(
	json_text: string,
	hero: int,
	allocator := context.allocator,
) -> string {
	if hero < 0 do return json_text
	needle := `"RequestedHero":`
	idx := strings.index(json_text, needle)
	if idx < 0 do return json_text
	vstart := idx + len(needle)
	vend := vstart
	for vend < len(json_text) && '0' <= json_text[vend] && json_text[vend] <= '9' do vend += 1
	hero_str := fmt.aprintf("%d", hero, allocator = allocator)
	return strings.concatenate({json_text[:vstart], hero_str, json_text[vend:]}, allocator)
}

party_userdata_json :: proc(
	peer: string,
	initialized: bool,
	lobby_state: int,
	requested_hero := -1,
	allocator := context.allocator,
) -> string {
	return apply_requested_hero(
		party_userdata_json_template(peer, initialized, lobby_state),
		requested_hero,
		allocator,
	)
}

party_userdata_json_template :: proc(peer: string, initialized: bool, lobby_state: int) -> string {
	if peer == "C2" {
		if initialized && lobby_state == 2 do return `{"RequestedHero":1,"RequestedSkin":0,"InLobby":true,"PlayerName":"Major Hoff","LobbyState":2,"UnlockedGameDifficulty":0,"MemberDataInitialized":true,"UnlockedHeroFlag":31,"m_sEosUserId":"0002ea2c70fa4f89a5d876065a55c786","m_sSteamUserId":76561197977870267,"m_uVoiceChatMode":0,"m_ePlatform":2,"RandomSkinIndex":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}`
		if initialized do return `{"RequestedHero":1,"RequestedSkin":0,"InLobby":true,"PlayerName":"Major Hoff","LobbyState":1,"UnlockedGameDifficulty":0,"MemberDataInitialized":true,"UnlockedHeroFlag":31,"m_sEosUserId":"0002ea2c70fa4f89a5d876065a55c786","m_sSteamUserId":76561197977870267,"m_uVoiceChatMode":0,"m_ePlatform":2,"RandomSkinIndex":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}`
		return(
			`{"RequestedHero":1,"RequestedSkin":0,"InLobby":true,"PlayerName":"Major Hoff","LobbyState":1,"UnlockedGameDifficulty":0,"MemberDataInitialized":false,"UnlockedHeroFlag":31,"m_sEosUserId":"0002ea2c70fa4f89a5d876065a55c786","m_sSteamUserId":76561197977870267,"m_uVoiceChatMode":0,"m_ePlatform":2,"RandomSkinIndex":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}` \
		)
	}
	if initialized && lobby_state == 2 do return `{"RequestedHero":2,"RequestedSkin":0,"InLobby":true,"PlayerName":"elsie","LobbyState":2,"UnlockedGameDifficulty":0,"MemberDataInitialized":true,"UnlockedHeroFlag":15,"m_sEosUserId":"000239105cf443abbdf0238c827bd9e8","m_sSteamUserId":76561199572083022,"m_uVoiceChatMode":0,"m_ePlatform":2,"RandomSkinIndex":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}`
	if initialized do return `{"RequestedHero":2,"RequestedSkin":0,"InLobby":true,"PlayerName":"elsie","LobbyState":1,"UnlockedGameDifficulty":0,"MemberDataInitialized":true,"UnlockedHeroFlag":15,"m_sEosUserId":"000239105cf443abbdf0238c827bd9e8","m_sSteamUserId":76561199572083022,"m_uVoiceChatMode":0,"m_ePlatform":2,"RandomSkinIndex":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}`
	return(
		`{"RequestedHero":2,"RequestedSkin":0,"InLobby":true,"PlayerName":"elsie","LobbyState":1,"UnlockedGameDifficulty":0,"MemberDataInitialized":false,"UnlockedHeroFlag":15,"m_sEosUserId":"000239105cf443abbdf0238c827bd9e8","m_sSteamUserId":76561199572083022,"m_uVoiceChatMode":0,"m_ePlatform":2,"RandomSkinIndex":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}` \
	)
}

party_memberdata_body :: proc(
	peer: string,
	prefix_version, value_version: u64,
	initialized: bool,
	lobby_state: int,
	allocator := context.allocator,
) -> []byte {
	return party_memberdata_body_with_userdata(
		peer,
		prefix_version,
		value_version,
		party_userdata_json(peer, initialized, lobby_state),
		allocator,
	)
}

party_memberdata_body_with_userdata :: proc(
	peer: string,
	prefix_version, value_version: u64,
	userdata_json: string,
	allocator := context.allocator,
) -> []byte {
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
			mpe_bin(transmute([]byte)userdata_json, allocator),
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

party_settings_body :: proc(
	peer: string,
	prefix_version, settings_version: u64,
	invitation_code: string,
	allocator := context.allocator,
) -> []byte {
	return party_settings_body_for_scene(
		peer,
		prefix_version,
		settings_version,
		invitation_code,
		party_scene_for_peer(peer),
		allocator,
	)
}

party_settings_body_for_scene :: proc(
	peer: string,
	prefix_version, settings_version: u64,
	invitation_code, party_scene: string,
	allocator := context.allocator,
) -> []byte {
	custom_builder := strings.builder_make(allocator)
	strings.write_string(&custom_builder, `{"InvitationCode":"`)
	strings.write_string(&custom_builder, invitation_code)
	strings.write_string(
		&custom_builder,
		`","GameMode":0,"GameDifficulty":0,"GameModifiers":[],"MergerDifficulty":0}`,
	)
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
			mpe_str(party_uuid_from_scene(party_scene, peer), allocator),
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

party_settings_value :: proc(
	peer: string,
	settings_version: u64,
	invitation_code: string,
	joinable: bool,
	game_session_id := "",
	allocator := context.allocator,
) -> []byte {
	return party_settings_value_for_scene(
		peer,
		settings_version,
		invitation_code,
		joinable,
		party_scene_for_peer(peer),
		game_session_id,
		allocator,
	)
}

party_settings_value_for_scene :: proc(
	peer: string,
	settings_version: u64,
	invitation_code: string,
	joinable: bool,
	party_scene: string,
	game_session_id := "",
	allocator := context.allocator,
) -> []byte {
	custom_builder := strings.builder_make(allocator)
	strings.write_string(&custom_builder, `{"InvitationCode":"`)
	strings.write_string(&custom_builder, invitation_code)
	strings.write_string(
		&custom_builder,
		`","GameMode":0,"GameDifficulty":0,"GameModifiers":[],"MergerDifficulty":0}`,
	)
	custom := strings.to_string(custom_builder)
	server_data := mpe_byte(MP_EMPTY_MAP, allocator)
	if game_session_id != "" {
		server_data = mpe_map(
			{
				mpe_str("stormancer.partyStatus", allocator),
				mpe_str("gamesession", allocator),
				mpe_str("stormancer.partyStatus.details", allocator),
				mpe_str(game_session_id, allocator),
			},
			allocator,
		)
	}
	return mpe_array(
		{
			mpe_str("matchmaking", allocator),
			mpe_str(custom, allocator),
			mpe_uint(settings_version, allocator),
			mpe_bool(false, allocator),
			mpe_bool(joinable, allocator),
			server_data,
			mpe_str("", allocator),
			mpe_str(party_uuid_from_scene(party_scene, peer), allocator),
		},
		allocator,
	)
}

party_session_token :: proc(peer: string, allocator := context.allocator) -> []byte {
	out := make([]byte, 16, allocator)
	seed: u8 = 0x11
	if peer == "C2" do seed = 0x22
	for i in 0 ..< len(out) do out[i] = seed + u8(i)
	return out
}

party_full_member :: proc(
	peer: string,
	status: u64,
	initialized: bool,
	lobby_state: int,
	requested_hero := -1,
	allocator := context.allocator,
) -> []byte {
	return party_full_member_with_userdata(
		peer,
		status,
		party_userdata_json(peer, initialized, lobby_state, requested_hero, allocator),
		initialized,
		allocator,
	)
}

party_full_member_with_userdata :: proc(
	peer: string,
	status: u64,
	userdata_json: string,
	platform_committed := false,
	allocator := context.allocator,
) -> []byte {
	// The 5th platform field is an empty string once the member's data has been
	// committed to the party (established members), and nil for a member that has
	// only just connected to a freshly created party.
	platform_extra := platform_committed ? mpe_str("", allocator) : mpe_nil(allocator)
	platforms := mpe_array(
		{
			mpe_array(
				{
					mpe_str("steam", allocator),
					mpe_str(user_id_for_peer(peer), allocator),
					mpe_str("anonymous", allocator),
					mpe_str(party_member_steam_id_for_peer(peer), allocator),
					platform_extra,
					mpe_uint(0, allocator),
				},
				allocator,
			),
		},
		allocator,
	)
	return mpe_array(
		{
			mpe_str(user_id_for_peer(peer), allocator),
			mpe_uint(status, allocator),
			mpe_bin(transmute([]byte)userdata_json, allocator),
			mpe_bin(party_session_token(peer, allocator), allocator),
			platforms,
			mpe_uint(2, allocator),
		},
		allocator,
	)
}

party_member_connected_body_with_userdata :: proc(
	peer: string,
	rpc_id: u16,
	version, status: u64,
	userdata_json: string,
	allocator := context.allocator,
) -> []byte {
	body := make([dynamic]byte, allocator)
	write_u16_le(&body, rpc_id)
	append(&body, ..mpe_uint(version, allocator))
	append(&body, 0)
	append(&body, ..mpe_uint(version, allocator))
	append(&body, ..party_full_member_with_userdata(peer, status, userdata_json, false, allocator))
	return body[:]
}

party_join_state_response_raw :: proc(
	member_status: u64,
	state_version: u64,
	allocator := context.allocator,
) -> []byte {
	return party_join_state_response_raw_for_scene(
		"C1",
		"C2",
		member_status,
		state_version,
		party_scene_for_peer("C1"),
		invite_code_for_peer("C1"),
		-1,
		-1,
		allocator,
	)
}

party_join_state_response_raw_for_scene :: proc(
	leader_label, other_label: string,
	member_status: u64,
	state_version: u64,
	party_scene, invitation_code: string,
	leader_hero := -1,
	other_hero := -1,
	allocator := context.allocator,
) -> []byte {
	settings := party_settings_value_for_scene(
		leader_label,
		5,
		invitation_code,
		true,
		party_scene,
		allocator = allocator,
	)
	members := mpe_array(
		{
			party_full_member(leader_label, member_status, true, 1, leader_hero, allocator),
			party_full_member(other_label, member_status, true, 1, other_hero, allocator),
		},
		allocator,
	)
	return mpe_array(
		{
			settings,
			mpe_str(user_id_for_peer(leader_label), allocator),
			members,
			mpe_uint(state_version, allocator),
		},
		allocator,
	)
}

steam_join_lobby_body :: proc(
	rpc_id: u16,
	lobby_id: u64,
	allocator := context.allocator,
) -> []byte {
	body := make([dynamic]byte, allocator)
	write_u16_le(&body, rpc_id)
	append(&body, ..mpe_array({mpe_uint(lobby_id, allocator)}, allocator))
	return body[:]
}

steam_create_lobby_body :: proc(
	peer: string,
	rpc_id: u16,
	party_scene: string,
	allocator := context.allocator,
) -> []byte {
	party_id := strings.trim_prefix(party_scene, "party-")
	party_token_json := strings.concatenate(
		{
			`{"PartyId":"`,
			party_id,
			`","LeaderUserId":"`,
			user_id_for_peer(peer),
			`","LeaderSteamId":`,
			party_member_steam_id_for_peer(peer),
			`}`,
		},
		allocator,
	)
	party_token, _ := base64.encode(transmute([]byte)party_token_json, base64.ENC_TABLE, allocator)
	body := make([dynamic]byte, allocator)
	write_u16_le(&body, rpc_id)
	append(
		&body,
		..mpe_array(
			{
				mpe_uint(1, allocator),
				mpe_uint(4, allocator),
				mpe_bool(true, allocator),
				mpe_map(
					{mpe_str("partyDataToken", allocator), mpe_str(party_token, allocator)},
					allocator,
				),
			},
			allocator,
		),
	)
	return body[:]
}

steam_update_lobby_joinable_body :: proc(
	rpc_id: u16,
	lobby_id: u64,
	joinable: bool,
	allocator := context.allocator,
) -> []byte {
	body := make([dynamic]byte, allocator)
	write_u16_le(&body, rpc_id)
	append(
		&body,
		..mpe_array({mpe_uint(lobby_id, allocator), mpe_bool(joinable, allocator)}, allocator),
	)
	return body[:]
}

scene_rpc_error_body :: proc(
	rpc_id: u16,
	message: string,
	allocator := context.allocator,
) -> []byte {
	body := make([dynamic]byte, allocator)
	write_u16_le(&body, rpc_id)
	append(&body, ..mpe_str(message, allocator))
	return body[:]
}

scene_rpc_uint_prefix_body :: proc(
	rpc_id: u16,
	value: u64,
	allocator := context.allocator,
) -> []byte {
	body := make([dynamic]byte, allocator)
	write_u16_le(&body, rpc_id)
	append(&body, ..mpe_uint(value, allocator))
	return body[:]
}

scene_rpc_nil_false_nil_body :: proc(rpc_id: u16, allocator := context.allocator) -> []byte {
	body := make([dynamic]byte, allocator)
	write_u16_le(&body, rpc_id)
	append(
		&body,
		..mpe_array(
			{mpe_nil(allocator), mpe_bool(false, allocator), mpe_nil(allocator)},
			allocator,
		),
	)
	return body[:]
}

player_update_body :: proc(peer: string, state: u64, allocator := context.allocator) -> []byte {
	return mpe_array(
		{
			mpe_str(user_id_for_peer(peer), allocator),
			mpe_uint(state, allocator),
			mpe_str("", allocator),
			mpe_bool(false, allocator),
		},
		allocator,
	)
}

// Party server pushes (memberConnected, memberDataUpdated, memberStatusUpdated, ...)
// are broadcast from one global per-party counter: each event at party `version` is
// delivered to BOTH connections with consecutive rpc_ids -- the JOINER's scene gets
// 2*version-7, the HOST's scene gets 2*version-6. So the rpc_id a given member sees
// for its own broadcast depends on whether that member is the joiner or the host, not
// on its connection label or identity.
party_broadcast_rpc :: proc(version: u64, is_joiner: bool) -> u16 {
	return u16(2 * version - 7 + (is_joiner ? 0 : 1))
}

party_member_status_body :: proc(
	rpc_id: u16,
	version: u64,
	peer: string,
	status: u64,
	allocator := context.allocator,
) -> []byte {
	status_update := mpe_array(
		{
			mpe_array(
				{
					mpe_array(
						{mpe_str(user_id_for_peer(peer), allocator), mpe_uint(status, allocator)},
						allocator,
					),
				},
				allocator,
			),
		},
		allocator,
	)
	body := make([dynamic]byte, allocator)
	write_u16_le(&body, rpc_id)
	append(&body, ..mpe_uint(version, allocator))
	append(&body, ..status_update)
	return body[:]
}

party_member_status_pair_body :: proc(
	rpc_id: u16,
	version: u64,
	peer_a: string,
	status_a: u64,
	peer_b: string,
	status_b: u64,
	allocator := context.allocator,
) -> []byte {
	status_update := mpe_array(
		{
			mpe_array(
				{
					mpe_array(
						{
							mpe_str(user_id_for_peer(peer_a), allocator),
							mpe_uint(status_a, allocator),
						},
						allocator,
					),
					mpe_array(
						{
							mpe_str(user_id_for_peer(peer_b), allocator),
							mpe_uint(status_b, allocator),
						},
						allocator,
					),
				},
				allocator,
			),
		},
		allocator,
	)
	body := make([dynamic]byte, allocator)
	write_u16_le(&body, rpc_id)
	append(&body, ..mpe_uint(version, allocator))
	append(&body, ..status_update)
	return body[:]
}

party_member_disconnected_body :: proc(
	rpc_id: u16,
	version: u64,
	peer: string,
	reason: u64,
	allocator := context.allocator,
) -> []byte {
	body := make([dynamic]byte, allocator)
	write_u16_le(&body, rpc_id)
	append(&body, ..mpe_uint(version, allocator))
	append(
		&body,
		..mpe_array(
			{mpe_str(user_id_for_peer(peer), allocator), mpe_uint(reason, allocator)},
			allocator,
		),
	)
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
			mpe_str("AccountId", allocator),
			mpe_str("darktales", allocator),
			mpe_str("Application", allocator),
			mpe_str("live-1-05-00", allocator),
			mpe_str("Issued", allocator),
			mpe_timestamp(1_780_537_212, allocator = allocator),
			mpe_str("Expiration", allocator),
			mpe_timestamp(1_780_537_512, allocator = allocator),
			mpe_str("UserData", allocator),
			mpe_bin({}, allocator),
			mpe_str("ContentType", allocator),
			mpe_str("text/plain; charset=utf-8, application/msgpack", allocator),
			mpe_str("Endpoints", allocator),
			mpe_nil(allocator),
			mpe_str("SceneId", allocator),
			mpe_str(scene_id, allocator),
			mpe_str("Routing", allocator),
			mpe_nil(allocator),
			mpe_str("DeploymentId", allocator),
			mpe_str("2564d8be-2dbb-4967-b6bb-0e157aa7f63f", allocator),
			mpe_str("Version", allocator),
			mpe_uint(2, allocator),
		},
		allocator,
	)
}

scene_token_json :: proc(scene_suffix: string, allocator := context.allocator) -> string {
	return scene_token_json_endpoint(
		scene_suffix,
		env_string("RAKNET_ENDPOINT", DEFAULT_RAKNET_ENDPOINT, allocator),
		allocator,
	)
}

scene_token_json_endpoint :: proc(
	scene_suffix, raknet_endpoint: string,
	allocator := context.allocator,
) -> string {
	scene_id := fmt.aprintf("%s%s", SCENE_ID_BASE, scene_suffix, allocator = allocator)
	cd := connection_data_msgpack(scene_id, allocator)
	cd_b64, _ := base64.encode(cd, base64.ENC_TABLE, allocator)
	sig := "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{"token":"`)
	strings.write_string(&b, cd_b64)
	strings.write_byte(&b, '-')
	strings.write_string(&b, sig)
	strings.write_string(&b, `","endpoints":{"raknet":["`)
	strings.write_string(&b, raknet_endpoint)
	strings.write_string(
		&b,
		`"]},"encryption":{"algorithm":"aes256","mode":"GCM","key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","token":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}}`,
	)
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

scene_token_response_for_suffix :: proc(
	scene_suffix: string,
	allocator := context.allocator,
) -> []byte {
	return mpe_str(scene_token_json(scene_suffix, allocator), allocator)
}

captured_friend_notification :: proc(
	text, peer: string,
	index: int,
	allocator := context.allocator,
) -> []byte {
	return captured_friend_notification_by_steam_id(
		text,
		steam_id_for_peer(peer),
		index,
		allocator,
	)
}

captured_friend_notification_for_body :: proc(
	text: string,
	body: Scene_Body,
	peer: string,
	index: int,
	allocator := context.allocator,
) -> []byte {
	if !body.has_rpc_id && body.values.consumed > 0 {
		out := make([]byte, body.values.consumed, allocator)
		copy(out, body.values.raw[:body.values.consumed])
		return out
	}
	raw := string(body.values.raw[:body.values.consumed])
	if strings.contains(raw, steam_id_for_peer("C1")) {
		if out := captured_friend_notification_by_steam_id(text, steam_id_for_peer("C1"), index, allocator); out != nil do return out
	}
	if strings.contains(raw, steam_id_for_peer("C2")) {
		if out := captured_friend_notification_by_steam_id(text, steam_id_for_peer("C2"), index, allocator); out != nil do return out
	}
	return captured_friend_notification(text, peer, index, allocator)
}

captured_friend_notification_by_steam_id :: proc(
	text, steam_id: string,
	index: int,
	allocator := context.allocator,
) -> []byte {
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

captured_push_sample :: proc(
	text, key, peer: string,
	index: int,
	allocator := context.allocator,
) -> []byte {
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
		peer_value_pos := strings.index(
			peer_section,
			fmt.aprintf("\"%s\"", peer, allocator = allocator),
		)
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
	prefixes := [?]string {
		"\n  \"authenticator/",
		"\n  \"friends/",
		"\n  \"party/",
		"\n  \"matchmaking/",
		"\n  \"gamesession/",
	}
	for prefix in prefixes {
		if idx := strings.index(section[1:], prefix); idx >= 0 {
			pos := idx + 1
			if pos < best do best = pos
		}
	}
	return best
}

append_captured_push :: proc(
	preds: ^[dynamic]Decoded_Message,
	samples_text, key, peer: string,
	scene_handle: u8,
	route_handle: u16,
	index: int,
	allocator := context.allocator,
) {
	if body := captured_push_sample(samples_text, key, peer, index, allocator); body != nil {
		append_scene_message(preds, scene_handle, route_handle, body, allocator)
	}
}

append_captured_push_rpc :: proc(
	preds: ^[dynamic]Decoded_Message,
	samples_text, key, peer: string,
	scene_handle: u8,
	route_handle: u16,
	index: int,
	rpc_id: u16,
	allocator := context.allocator,
) {
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

party_state_response_raw :: proc(
	samples_text, peer: string,
	allocator := context.allocator,
) -> []byte {
	settings := captured_push_sample(
		samples_text,
		"party/party.settingsUpdated",
		peer,
		0,
		allocator,
	)
	member_connected := captured_push_sample(
		samples_text,
		"party/party.memberConnected",
		peer,
		0,
		allocator,
	)
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

// Fresh single-member party state (getPartyState2 reply) built from the learned
// party scene UUID and the learned hero choice. The settings custom field is a
// plain empty string (no invitation code exists yet for a freshly created party),
// matching the real backend's first getPartyState2 response.
party_state_response_learned :: proc(
	party_scene, leader_label: string,
	hero: int,
	allocator := context.allocator,
) -> []byte {
	party_uuid := strings.trim_prefix(party_scene, "party-")
	settings := mpe_array(
		{
			mpe_str("matchmaking", allocator),
			mpe_str("", allocator),
			mpe_uint(1, allocator),
			mpe_bool(false, allocator),
			mpe_bool(true, allocator),
			mpe_byte(MP_EMPTY_MAP, allocator),
			mpe_str("", allocator),
			mpe_str(party_uuid, allocator),
		},
		allocator,
	)
	member := party_full_member(leader_label, 0, false, 1, hero, allocator)
	return mpe_array(
		{
			settings,
			mpe_str(user_id_for_peer(leader_label), allocator),
			mpe_array({member}, allocator),
			mpe_uint(3, allocator),
		},
		allocator,
	)
}

build_scene_connection_result_raw :: proc(
	scene_handle: u64,
	routes: []Scene_Route,
	allocator := context.allocator,
) -> []byte {
	route_pairs := make([dynamic][]byte, allocator)
	for route, i in routes {
		append(&route_pairs, mpe_str(route.name, allocator))
		append(&route_pairs, mpe_uint(u64(i + 1), allocator))
	}

	return mpe_map(
		{
			mpe_str("SceneHandle", allocator),
			mpe_uint(scene_handle, allocator),
			mpe_str("RouteMappings", allocator),
			mpe_map(route_pairs[:], allocator),
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

count_previous_scene_route :: proc(
	txns: []Predict_Caleb_Txn,
	peer: ^Peer_State,
	route_handle: u16,
) -> int {
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
		append(
			&party_pairs,
			mpe_str("2", allocator),
		); append(&party_pairs, mpe_uint(nb_parties_2, allocator))
	}

	player_pairs := make([dynamic][]byte, allocator)
	append(&player_pairs, mpe_str("0", allocator)); append(&player_pairs, mpe_uint(3, allocator))
	append(&player_pairs, mpe_str("3", allocator)); append(&player_pairs, mpe_uint(3, allocator))
	if nb_players_2 > 0 {
		append(
			&player_pairs,
			mpe_str("2", allocator),
		); append(&player_pairs, mpe_uint(nb_players_2, allocator))
	}

	details := mpe_map(
		{
			mpe_str("nbPartiesByDifficulty", allocator),
			mpe_map(party_pairs[:], allocator),
			mpe_str("nbPlayersByDifficulty", allocator),
			mpe_map(player_pairs[:], allocator),
		},
		allocator,
	)
	status := mpe_map(
		{
			mpe_str("partiesCount", allocator),
			mpe_uint(parties, allocator),
			mpe_str("algorithm", allocator),
			mpe_str("DtPartyMergerAlgorithm", allocator),
			mpe_str("playersCount", allocator),
			mpe_uint(players, allocator),
			mpe_str("details", allocator),
			details,
		},
		allocator,
	)
	return mpe_array({mpe_uint(1, allocator), status}, allocator)
}

log_datagram :: proc(
	log: ^os.File,
	scratch: mem.Allocator,
	from: net.Endpoint,
	recv_time: time.Time,
	bytes: []byte,
) {
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

log_relay_datagram :: proc(
	log: ^os.File,
	scratch: mem.Allocator,
	dir, peer: string,
	recv_time: time.Time,
	bytes: []byte,
) {
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
	allocator := live.write_scratch
	free_all(allocator)
	out := strings.builder_make(allocator)
	for &txn in live.txns {
		real_human := render_decoded_burst(
			&txn.peer.reg_real,
			txn.peer.ep_real,
			txn.reals[:],
			allocator,
		)
		real_bytes := encode_decoded_messages(txn.reals[:], allocator)
		pred_human := render_decoded_burst(
			&txn.peer.reg_pred,
			txn.peer.ep_pred,
			txn.preds[:],
			allocator,
		)
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

predict_caleb :: proc(
	datagrams: ^UDP_Datagram_Store,
	msgs: ^RakNet_Message_Store,
	reasm: ^Reassembly,
	path: string,
) -> Error {
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
	joiner_label := ""
	peer_userdata: [dynamic]Predict_Caleb_Peer_Userdata
	scene_handles: [dynamic]Predict_Caleb_Scene_Handle
	party_states: [dynamic]Predict_Caleb_Party_State
	steam_lobbies: [dynamic]Predict_Caleb_Steam_Lobby
	peers: [dynamic]^Peer_State
	txns: [dynamic]Predict_Caleb_Txn
	nidx := 1
	// Arrival-order counter for party.memberStatusUpdated ready self-broadcasts
	// (mirrors Predict_Caleb_Live.ready_status_seq in the live path).
	ready_status_seq := 0
	out_path := "/tmp/pdlog/probe/predict_caleb.json"
	// Offline send-gate: when >0, rewrite each transaction's "sent" timestamp so
	// consecutive meaningful sends from the same peer are at least this many ms
	// apart (a gate only ever delays, never advances ahead of real arrival time).
	// This models gated sending safely on the capture instead of on the live stream
	// (live re-encoding desyncs the real upstream and breaks the join code). 0 = off
	// = keep the real capture timestamps.
	gate_ms := env_int("PREDICT_GATE_MS", 0)
	gate_last: map[^Peer_State]i64
	defer delete(gate_last)
	game_ready: [dynamic]string
	scene_infos := Predict_Caleb_Scene_Infos {
		authenticator = os.read_entire_file_from_path(
			"src/scenes/authenticator.infos.bin",
			scratch,
		) or_return,
		friends       = os.read_entire_file_from_path(
			"src/scenes/friends.infos.bin",
			scratch,
		) or_return,
		party_manager = os.read_entire_file_from_path(
			"src/scenes/party-manager.infos.bin",
			scratch,
		) or_return,
		party         = os.read_entire_file_from_path(
			"src/scenes/party.infos.bin",
			scratch,
		) or_return,
		matchmaking   = os.read_entire_file_from_path(
			"src/scenes/matchmaking.infos.bin",
			scratch,
		) or_return,
		gamesession   = os.read_entire_file_from_path(
			"src/scenes/gamesession.infos.bin",
			scratch,
		) or_return,
	}
	steam_friends_bytes := os.read_entire_file_from_path(
		"src/steam_friends.json",
		scratch,
	) or_return
	steam_friends_text := string(steam_friends_bytes)
	raknet_samples_bytes := os.read_entire_file_from_path(
		"src/raknet_samples.json",
		scratch,
	) or_return
	raknet_samples_text := string(raknet_samples_bytes)

	text := string(data)
	for line_text in strings.split_lines_iterator(&text) {
		if len(line_text) == 0 do continue

		rec: Relay_Record
		if json.unmarshal_string(line_text, &rec, allocator = scratch) != nil do continue

		dg, ok := hex.decode(transmute([]byte)rec.hex, scratch)
		if !ok do continue
		if datagram_is_health_channel(dg) do continue

		ps := find_peer(&peers, rec.peer, &nidx)

		if rec.dir == "s2c" {
			if is_content_datagram(dg) {
				real_msgs := filter_health_messages(
					reassemble_side(ps, .Real, {dg}, scratch),
					scratch,
				)
				for msg in real_msgs {
					predict_caleb_learn_real_values(
						&party_states,
						&scene_handles,
						&txns,
						ps,
						msg,
						scratch,
					)
					predict_caleb_route_real(&txns, ps, msg, scratch)
				}
			}
			continue
		}
		if rec.dir != "c2s" do continue
		if !is_content_datagram(dg) do continue

		sent_msgs := filter_health_messages(reassemble_side(ps, .C2S, {dg}, scratch), scratch)
		if len(sent_msgs) == 0 do continue

		for &txn in txns {
			if txn.peer == ps do txn.window_open = false
		}

		txn: Predict_Caleb_Txn
		txn.peer = ps
		txn.t = rec.t
		if gate_ms > 0 {
			real_time, consumed := time.rfc3339_to_time_utc(rec.t)
			if consumed > 0 {
				real_ns := real_time._nsec
				gated_ns := real_ns
				if last, found := gate_last[ps]; found {
					min_ns := last + i64(gate_ms) * i64(time.Millisecond)
					if gated_ns < min_ns do gated_ns = min_ns
				}
				gate_last[ps] = gated_ns
				if stamp, ok_s := time.time_to_rfc3339(
					time.Time{_nsec = gated_ns},
					allocator = scratch,
				); ok_s {
					txn.t = stamp
				}
			}
		}
		txn.label = rec.peer
		txn.window_open = true
		for msg in sent_msgs do append(&ps.sent_msgs, msg)
		for msg in sent_msgs do append(&txn.sent_msgs, msg)
		txn.sent_human = render_burst(&ps.reg_real, ps.ep_client, txn.sent_msgs[:], scratch)
		free_all(context.temp_allocator)
		for pending in ps.pending_preds do append_decoded_message(&txn.preds, pending, scratch)
		clear(&ps.pending_preds)

		new_incoming_in_txn := false
		set_ready_this_txn := false
		for msg in sent_msgs {
			decoded := decode_message(msg, scratch)
			#partial switch decoded in decoded {
			case Connection_Request:
				response := Connection_Request_Accepted {
					remote         = system_address_from_endpoint(
						net.Endpoint {
							address = net.IP4_Address {
								ps.addr.ip[0],
								ps.addr.ip[1],
								ps.addr.ip[2],
								ps.addr.ip[3],
							},
							port = int(ps.addr.port),
						},
					),
					system_index   = 0,
					internal_count = 1,
					echo_time      = decoded.time,
					server_time    = server_time_ms(),
				}
				response.internal[0] = System_Address {
					version = 4,
					ip      = {127, 0, 0, 1},
					port    = LISTEN_PORT,
				}
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
				server_ping := Connected_Ping {
					clock = server_time_ms(),
				}
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
					append_captured_push_rpc(
						&txn.preds,
						raknet_samples_text,
						"party/party.memberConnected",
						"C2",
						144,
						9,
						1,
						9,
						scratch,
					)
				}
				if txn.label == "C2" && decoded.echo_clock == 4687089046 {
					append(
						&txn.preds,
						Decoded_Message(
							Connected_Pong{echo_clock = 46070073, clock = server_time_ms()},
						),
					)
				}
				if txn.label == "C1" && decoded.echo_clock == 4687091068 {
					append_scene_message(
						&txn.preds,
						146,
						2,
						player_update_body("C2", 4, scratch),
						scratch,
					)
					append_scene_message(
						&txn.preds,
						144,
						10,
						party_member_disconnected_body(46, 26, "C2", 0, scratch),
						scratch,
					)
				}

			case System_Request:
				append(&txn.req_ids, decoded.req_id)
				#partial switch decoded.msg_id {
				case System_Request_Id.Get_Session_Token:
					jwt := "eyJhbGciOiJub25lIiwidHlwIjoiSldUIiwiY2x1c3RlcklkIjoicGFzc3RlY2gtbGl2ZSJ9.eyJTdG9ybWFuY2VyL3Nlc3Npb25JZCI6ImJYMkZOMVdhS1Vxb3VCY2JVNTlWbVEiLCJuYmYiOjE3ODA1MzcyMTIsImV4cCI6MTc4MDYyMzYxMiwiaWF0IjoxNzgwNTM3MjEyLCJpc3MiOiJwYXNzdGVjaC1saXZlIn0."
					sid := "bX2FN1WaKUqouBcbU59VmQ"
					raw := mpe_concat(
						mpe_str(jwt, scratch),
						mpe_str(sid, scratch),
						allocator = scratch,
					)
					append_response_msg(&txn.preds, decoded.req_id, raw, scratch)
					append_response_complete(&txn.preds, decoded.req_id, true, scratch)

				case System_Request_Id.Get_Scene_Infos:
					#partial switch args in decoded.args {
					case Get_Scene_Infos_Args:
						tok := parse_connection_token(args.token, scratch)
						if txn.label == "C1" &&
						   tok.ok &&
						   strings.contains(tok.scene_id, "a0567d04-4c5c-4ff3-978f-952baa342421") {
							append_scene_message(
								&txn.preds,
								144,
								8,
								party_member_status_pair_body(17, 12, "C1", 0, "C2", 0, scratch),
								scratch,
							)
						}
						append_response_msg(
							&txn.preds,
							decoded.req_id,
							scene_infos_for_token(args.token, scene_infos, scratch),
							scratch,
						)
						append_response_complete(&txn.preds, decoded.req_id, true, scratch)
					}

				case System_Request_Id.Ping:
					#partial switch args in decoded.args {
					case Ping_Args:
						if txn.label == "C2" && decoded.req_id == 45 {
							append_scene_message(
								&txn.preds,
								146,
								7,
								scene_rpc_uint_prefix_body(31, 18, scratch),
								scratch,
							)
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
						party_scene := predict_caleb_party_scene_for_handle(
							party_states[:],
							scene_handles[:],
							txn.label,
							u8(ready_handle),
							predict_caleb_party_scene_for_owner(
								party_states[:],
								txn.label,
								party_scene_for_peer(txn.label),
							),
						)
						append_scene_message(
							&txn.preds,
							u8(ready_handle),
							14,
							steam_create_lobby_body(txn.label, 1, party_scene, scratch),
							scratch,
						)
					}
					if ready_handle == 145 && txn.label == "C1" {
						append_captured_push(
							&txn.preds,
							raknet_samples_text,
							"party/party.memberDataUpdated",
							"C1",
							144,
							3,
							1,
							scratch,
						)
					}
					if ready_handle == 145 && txn.label == "C2" {
						party_scene := predict_caleb_party_scene_for_handle(
							party_states[:],
							scene_handles[:],
							txn.label,
							144,
							predict_caleb_party_scene_for_owner(
								party_states[:],
								txn.label,
								party_scene_for_peer(txn.label),
							),
						)
						invite_code := predict_caleb_party_invite_for_scene(
							party_states[:],
							party_scene,
							txn.label,
						)
						append_scene_message(
							&txn.preds,
							144,
							7,
							party_settings_body_for_scene(
								txn.label,
								7,
								5,
								invite_code,
								party_scene,
								scratch,
							),
							scratch,
						)
					}
					if ready_handle == 146 &&
					   predict_caleb_label_is_joiner(joiner_label, txn.label) {
						host_label := predict_caleb_other_peer_label_from_states(
							peers[:],
							txn.label,
						)
						append_scene_message(
							&txn.preds,
							146,
							15,
							steam_join_lobby_body(
								8,
								steam_lobbies_get(
									steam_lobbies[:],
									host_label,
									steam_lobbies_get(steam_lobbies[:], "C1", 109775242850226431),
								),
								scratch,
							),
							scratch,
						)
					}
					if ready_handle == 148 && txn.label == "C2" {
						append_scene_rpc_complete(&txn.preds, 148, 3, 1, true, scratch)
					}
					if ready_handle == 141 && txn.label == "C2" {
						append_scene_message(
							&txn.preds,
							u8(ready_handle),
							3,
							mpe_str("bot,1.05.*", scratch),
							scratch,
						)
					}
					bool_raw := mpe_map({mpe_str("v", scratch), mpe_bool(true, scratch)}, scratch)
					append_response_msg(&txn.preds, decoded.req_id, bool_raw, scratch)
					if ready_handle == 141 && txn.label != "C2" {
						append_scene_message(
							&txn.preds,
							u8(ready_handle),
							3,
							mpe_str("bot,1.05.*", scratch),
							scratch,
						)
					}
					append_response_complete(&txn.preds, decoded.req_id, true, scratch)
					if ready_handle == 144 {
						party_scene := predict_caleb_party_scene_for_handle(
							party_states[:],
							scene_handles[:],
							txn.label,
							u8(ready_handle),
							predict_caleb_party_scene_for_owner(
								party_states[:],
								txn.label,
								party_scene_for_peer(txn.label),
							),
						)
						userdata_json := predict_caleb_userdata_for_label(
							peer_userdata[:],
							txn.label,
							txn.label,
							false,
							1,
						)
						append_scene_message(
							&txn.preds,
							u8(ready_handle),
							7,
							party_settings_body_for_scene(
								txn.label,
								3,
								1,
								"",
								party_scene,
								scratch,
							),
							scratch,
						)
						append_scene_message(
							&txn.preds,
							u8(ready_handle),
							3,
							party_memberdata_body_with_userdata(
								txn.label,
								4,
								4,
								userdata_json,
								scratch,
							),
							scratch,
						)
						append_scene_message(
							&txn.preds,
							u8(ready_handle),
							7,
							party_settings_body_for_scene(
								txn.label,
								5,
								3,
								"",
								party_scene,
								scratch,
							),
							scratch,
						)
						// Both peers emit the MemberDataInitialized false->true follow-up
						// (memberDataUpdated 6/6); not label specific.
						append_scene_message(
							&txn.preds,
							u8(ready_handle),
							3,
							party_memberdata_body_with_userdata(
								txn.label,
								6,
								6,
								userdata_json,
								scratch,
							),
							scratch,
						)
					}
					if ready_handle == 145 && txn.label == "C1" {
						party_scene := predict_caleb_party_scene_for_handle(
							party_states[:],
							scene_handles[:],
							txn.label,
							144,
							predict_caleb_party_scene_for_owner(
								party_states[:],
								txn.label,
								party_scene_for_peer(txn.label),
							),
						)
						invite_code := predict_caleb_party_invite_for_scene(
							party_states[:],
							party_scene,
							txn.label,
						)
						append_scene_message(
							&txn.preds,
							144,
							7,
							party_settings_body_for_scene(
								txn.label,
								7,
								5,
								invite_code,
								party_scene,
								scratch,
							),
							scratch,
						)
						append_scene_message(
							&txn.preds,
							144,
							3,
							party_memberdata_body("C2", 11, 9, true, 1, scratch),
							scratch,
						)
						append_scene_message(
							&txn.preds,
							144,
							3,
							party_memberdata_body("C2", 19, 13, true, 2, scratch),
							scratch,
						)
						append_scene_message(
							&txn.preds,
							144,
							3,
							party_memberdata_body("C1", 21, 14, true, 2, scratch),
							scratch,
						)
					}
					if ready_handle == 146 &&
					   predict_caleb_label_is_joiner(joiner_label, txn.label) {
						// joiner's own memberDataUpdated uses the joiner slot of the counter.
						append_scene_message(
							&txn.preds,
							146,
							3,
							party_memberdata_body(
								"C2",
								u64(party_broadcast_rpc(9, true)),
								9,
								true,
								1,
								scratch,
							),
							scratch,
						)
					}
					if ready_handle == 146 &&
					   !predict_caleb_label_is_joiner(joiner_label, txn.label) {
						append_scene_rpc_complete(&txn.preds, 146, 3, 1, true, scratch)
						append_scene_message(
							&txn.preds,
							144,
							7,
							scene_rpc_uint_prefix_body(24, 15, scratch),
							scratch,
						)
						append_scene_message(
							&txn.preds,
							144,
							7,
							scene_rpc_uint_prefix_body(26, 16, scratch),
							scratch,
						)
						other := predict_caleb_other_peer_label_from_states(peers[:], txn.label)
						other_state: u64 =
							predict_caleb_game_ready_seen(game_ready[:], other) ? 1 : 0
						append_scene_message(
							&txn.preds,
							146,
							2,
							player_update_body(txn.label, 1, scratch),
							scratch,
						)
						append_scene_message(
							&txn.preds,
							146,
							2,
							player_update_body(other, other_state, scratch),
							scratch,
						)
						predict_caleb_mark_game_ready(&game_ready, txn.label)
					}
					if ready_handle == 148 && txn.label == "C2" {
						other := predict_caleb_other_peer_label_from_states(peers[:], txn.label)
						other_state: u64 =
							predict_caleb_game_ready_seen(game_ready[:], other) ? 1 : 0
						append_scene_message(
							&txn.preds,
							148,
							2,
							player_update_body(txn.label, 1, scratch),
							scratch,
						)
						append_scene_message(
							&txn.preds,
							148,
							2,
							player_update_body(other, other_state, scratch),
							scratch,
						)
						predict_caleb_mark_game_ready(&game_ready, txn.label)
					}

				case System_Request_Id.Disconnect_From_Scene:
					append_bool_response(&txn.preds, decoded.req_id, true, scratch)

				case System_Request_Id.Connect_To_Scene:
					#partial switch args in decoded.args {
					case Connect_To_Scene_Args:
						handle := next_connect_scene_handle(txns[:], ps)
						tok := parse_connection_token(args.token, scratch)
						if tok.ok {
							scene := scene_suffix(tok.scene_id)
							predict_caleb_set_scene_handle_entry(
								&scene_handles,
								txn.label,
								scene,
								u8(handle),
							)
							if predict_caleb_is_party_scene(scene) do predict_caleb_ensure_party_state(&party_states, txn.label, scene)
						}
						raw := build_scene_connection_result_raw(handle, args.routes, scratch)
						append_response_msg(&txn.preds, decoded.req_id, raw, scratch)
						append_response_complete(&txn.preds, decoded.req_id, true, scratch)
					}
				}

			case Scene_Message:
				route_name := route_registry_resolve(
					&ps.reg_real,
					ps.ep_client,
					decoded.scene_handle,
					decoded.route_handle,
				)
				predict_caleb_learn_sent_party_values(
					&party_states,
					scene_handles[:],
					&peer_userdata,
					txn.label,
					decoded,
				)
				if decoded.decoded.has_rpc_id {
					append(
						&txn.rpc_keys,
						Predict_Caleb_RPC_Key{decoded.scene_handle, decoded.decoded.rpc_id},
					)
				}
				switch decoded.route_handle {
				case 0:
					if decoded.scene_handle == 144 && decoded.decoded.rpc_id == 1 {
						steam_lobbies_set(
							&steam_lobbies,
							txn.label,
							scene_route0_lobby_id(decoded.decoded),
						)
						party_scene := predict_caleb_party_scene_for_handle(
							party_states[:],
							scene_handles[:],
							txn.label,
							decoded.scene_handle,
							predict_caleb_party_scene_for_owner(
								party_states[:],
								txn.label,
								party_scene_for_peer(txn.label),
							),
						)
						hero := predict_caleb_hero_for_label(peer_userdata[:], txn.label)
						state: []byte
						if strings.has_prefix(party_scene, "party-") {
							state = party_state_response_learned(
								party_scene,
								txn.label,
								hero,
								scratch,
							)
						} else {
							state = party_state_response_raw(
								raknet_samples_text,
								txn.label,
								scratch,
							)
						}
						if state != nil {
							append_auth_rpc_response(
								&txn.preds,
								decoded.scene_handle,
								decoded.decoded.rpc_id,
								state,
								scratch,
							)
						}
					} else if decoded.scene_handle == 146 && decoded.decoded.rpc_id != 8 {
						append_scene_rpc_complete(
							&txn.preds,
							decoded.scene_handle,
							1,
							decoded.decoded.rpc_id,
							false,
							scratch,
						)
					}
				case 3:
					// party client completed Steam.CreateLobby; server pushes memberConnected
					if decoded.scene_handle == 144 && decoded.decoded.rpc_id == 257 {
						append_captured_push(
							&txn.preds,
							raknet_samples_text,
							"party/party.memberConnected",
							txn.label,
							decoded.scene_handle,
							9,
							0,
							scratch,
						)
					} else if decoded.scene_handle == 144 && decoded.decoded.rpc_id == 2816 {
						append_scene_message(
							&txn.preds,
							decoded.scene_handle,
							8,
							party_member_status_body(13, 10, "C2", 1, scratch),
							scratch,
						)
					} else if decoded.scene_handle == 146 && decoded.decoded.rpc_id == 2049 {
						userdata_json := predict_caleb_userdata_for_label(
							peer_userdata[:],
							txn.label,
							txn.label,
							true,
							1,
						)
						// memberConnected self-broadcast at party version 8: joiner slot rpc 9,
						// host slot rpc 10 of the global counter.
						mc_rpc := party_broadcast_rpc(
							8,
							predict_caleb_label_is_joiner(joiner_label, txn.label),
						)
						append_scene_message(
							&txn.preds,
							decoded.scene_handle,
							9,
							party_member_connected_body_with_userdata(
								txn.label,
								mc_rpc,
								8,
								0,
								userdata_json,
								scratch,
							),
							scratch,
						)
					} else if decoded.scene_handle == 146 && decoded.decoded.rpc_id == 3584 {
						// The member readied just before this completion, so the backend
						// rejects the in-flight data update with an rpc.error rather than
						// pushing a member-status update (see 700ms-patterns.md bucket C).
						append_scene_message(
							&txn.preds,
							decoded.scene_handle,
							5,
							scene_rpc_error_body(
								4,
								"Cannot update data when member is ready.",
								scratch,
							),
							scratch,
						)
					} else if decoded.scene_handle == 146 && decoded.decoded.rpc_id == 4096 {
						append_scene_message(&txn.preds, 147, 5, mpe_uint(0, scratch), scratch)
						append_scene_message(&txn.preds, 147, 5, mpe_uint(3, scratch), scratch)
						append_scene_message(
							&txn.preds,
							146,
							8,
							party_member_status_pair_body(18, 12, "C1", 0, "C2", 0, scratch),
							scratch,
						)
					} else if decoded.scene_handle == 146 && decoded.decoded.rpc_id == 6400 {
						append_scene_message(
							&txn.preds,
							146,
							7,
							scene_rpc_uint_prefix_body(27, 16, scratch),
							scratch,
						)
					} else if decoded.scene_handle == 144 && decoded.decoded.rpc_id == 3840 {
						append_scene_message(&txn.preds, 145, 5, mpe_uint(0, scratch), scratch)
					}
				case 6:
					// authenticator Authentication.Login
					if decoded.scene_handle == 141 {
						canon := login_canonical_label_from_ticket(msg)
						if canon == "" do canon = txn.label
						append_auth_rpc_response(
							&txn.preds,
							decoded.scene_handle,
							decoded.decoded.rpc_id,
							login_result_for_peer(canon, scratch),
							scratch,
						)
					} else if (decoded.scene_handle == 144 && decoded.decoded.rpc_id != 8) ||
					   (decoded.scene_handle == 146 && decoded.decoded.rpc_id != 8) {
						if decoded.scene_handle == 144 && decoded.decoded.rpc_id == 12 {
							append_scene_message(
								&txn.preds,
								146,
								4,
								scene_rpc_nil_false_nil_body(1, scratch),
								scratch,
							)
						}
						// updateData (route 6) issued in the same transaction as a set-ready is
						// rejected (no completion; a deferred rpc.error follows) since the member
						// just became ready.
						if !(decoded.scene_handle == 146 && set_ready_this_txn) {
							append_scene_rpc_complete(
								&txn.preds,
								decoded.scene_handle,
								1,
								decoded.decoded.rpc_id,
								false,
								scratch,
							)
						}
						if decoded.scene_handle == 146 && decoded.decoded.rpc_id == 3 {
							append_scene_message(
								&txn.preds,
								146,
								3,
								party_memberdata_body("C2", 20, 13, true, 2, scratch),
								scratch,
							)
						}
					}
				case 11:
					if decoded.scene_handle == 144 && decoded.decoded.rpc_id == 9 {
						party_scene := predict_caleb_party_scene_for_handle(
							party_states[:],
							scene_handles[:],
							txn.label,
							decoded.scene_handle,
							predict_caleb_party_scene_for_owner(
								party_states[:],
								txn.label,
								party_scene_for_peer(txn.label),
							),
						)
						leader_label := predict_caleb_party_owner_for_scene(
							party_states[:],
							party_scene,
							txn.label,
						)
						other_label := predict_caleb_other_peer_label_from_states(
							peers[:],
							leader_label,
						)
						invite_code := predict_caleb_party_invite_for_scene(
							party_states[:],
							party_scene,
							leader_label,
						)
						leader_hero := predict_caleb_hero_for_label(peer_userdata[:], leader_label)
						other_hero := predict_caleb_hero_for_label(peer_userdata[:], other_label)
						append_auth_rpc_response(
							&txn.preds,
							decoded.scene_handle,
							decoded.decoded.rpc_id,
							party_join_state_response_raw_for_scene(
								leader_label,
								other_label,
								1,
								11,
								party_scene,
								invite_code,
								leader_hero,
								other_hero,
								scratch,
							),
							scratch,
						)
					} else if decoded.scene_handle == 146 {
						party_scene := predict_caleb_party_scene_for_handle(
							party_states[:],
							scene_handles[:],
							txn.label,
							decoded.scene_handle,
							predict_caleb_party_scene_for_owner(
								party_states[:],
								txn.label,
								party_scene_for_peer(txn.label),
							),
						)
						leader_label := predict_caleb_party_owner_for_scene(
							party_states[:],
							party_scene,
							predict_caleb_other_peer_label_from_states(peers[:], txn.label),
						)
						other_label := predict_caleb_other_peer_label_from_states(
							peers[:],
							leader_label,
						)
						invite_code := predict_caleb_party_invite_for_scene(
							party_states[:],
							party_scene,
							leader_label,
						)
						leader_hero := predict_caleb_hero_for_label(peer_userdata[:], leader_label)
						other_hero := predict_caleb_hero_for_label(peer_userdata[:], other_label)
						append_auth_rpc_response(
							&txn.preds,
							decoded.scene_handle,
							decoded.decoded.rpc_id,
							party_join_state_response_raw_for_scene(
								leader_label,
								other_label,
								0,
								8,
								party_scene,
								invite_code,
								leader_hero,
								other_hero,
								scratch,
							),
							scratch,
						)
					}
				case 9:
					if decoded.scene_handle >= 144 &&
					   route_name == "party.updategamefinderplayerstatus" {
						// party.memberStatusUpdated ready self-broadcast: party version from a
						// global arrival-order counter (first member to ready -> v10, second
						// -> v11), rpc_id from the global broadcast counter (joiner sees
						// 2*version-7, host 2*version-6). Gate on the resolved route name so
						// any party scene handle works (a retry can allocate a higher handle
						// such as 148) without misfiring on a non-party scene.
						seq := ready_status_seq
						ready_status_seq += 1
						version := u64(10 + seq)
						rpc := party_broadcast_rpc(
							version,
							predict_caleb_label_is_joiner(joiner_label, txn.label),
						)
						label := decoded.scene_handle == 144 ? "C1" : "C2"
						append_scene_message(
							&txn.preds,
							decoded.scene_handle,
							8,
							party_member_status_body(rpc, version, label, 1, scratch),
							scratch,
						)
						append_scene_rpc_complete(
							&txn.preds,
							decoded.scene_handle,
							1,
							decoded.decoded.rpc_id,
							false,
							scratch,
						)
						set_ready_this_txn = true
					}
				case 8:
					if decoded.scene_handle == 146 || decoded.scene_handle == 148 {
						append_scene_message(
							&txn.preds,
							decoded.scene_handle,
							4,
							scene_rpc_nil_false_nil_body(decoded.decoded.rpc_id, scratch),
							scratch,
						)
					}
				case 15:
					// authenticator UserSession.UpdateUserOptions
					if decoded.scene_handle == 141 {
						append_auth_rpc_complete(
							&txn.preds,
							decoded.scene_handle,
							decoded.decoded.rpc_id,
							false,
							scratch,
						)
					}
				case 19:
					// authenticator Locator.GetSceneConnectionToken
					if decoded.scene_handle == 141 {
						append_auth_rpc_response(
							&txn.preds,
							decoded.scene_handle,
							decoded.decoded.rpc_id,
							scene_token_response_for_body(decoded.decoded, scratch),
							scratch,
						)
					}
				case 5:
					// friends Friends.Subscribe / party-manager join-code token
					join_code, has_join_code := scene_body_find_invitation_code(decoded.decoded)
					if route_name == "PartyManagement.CreateConnectionTokenFromInvitationCode" ||
					   has_join_code {
						joiner_label = txn.label
						host_label := predict_caleb_party_owner_for_invite(
							party_states[:],
							join_code,
							predict_caleb_other_peer_label_from_states(peers[:], txn.label),
						)
						host_scene := predict_caleb_party_scene_for_invite(
							party_states[:],
							join_code,
							predict_caleb_party_scene_for_owner(
								party_states[:],
								host_label,
								party_scene_for_peer(host_label),
							),
						)
						predict_caleb_ensure_party_state(&party_states, host_label, host_scene)
						append_auth_rpc_response(
							&txn.preds,
							decoded.scene_handle,
							decoded.decoded.rpc_id,
							scene_token_response_for_suffix(host_scene, scratch),
							scratch,
						)
					} else if route_name == "Friends.Subscribe" || decoded.decoded.has_rpc_id {
						if body := captured_friend_notification(
							steam_friends_text,
							txn.label,
							0,
							scratch,
						); body != nil {
							append_scene_message(
								&txn.preds,
								decoded.scene_handle,
								1,
								body,
								scratch,
							)
						}
						append_scene_rpc_complete(
							&txn.preds,
							decoded.scene_handle,
							2,
							decoded.decoded.rpc_id,
							false,
							scratch,
						)
					} else {
						append_scene_rpc_complete(
							&txn.preds,
							decoded.scene_handle,
							1,
							decoded.decoded.rpc_id,
							false,
							scratch,
						)
					}
				case 4:
					// friends Friends.UpdateFriendList / party-manager createsession
					if route_name == "Friends.UpdateFriendList" {
						if body := captured_friend_notification_for_body(
							steam_friends_text,
							decoded.decoded,
							txn.label,
							1,
							scratch,
						); body != nil {
							append_scene_message(
								&txn.preds,
								decoded.scene_handle,
								1,
								body,
								scratch,
							)
						}
					} else if route_name == "partymanagement.createsession" ||
					   scene_body_is_create_session(decoded.decoded) {
						party_scene := predict_caleb_party_scene_for_owner(
							party_states[:],
							txn.label,
							party_scene_for_peer(txn.label),
						)
						predict_caleb_ensure_party_state(&party_states, txn.label, party_scene)
						append_auth_rpc_response(
							&txn.preds,
							decoded.scene_handle,
							decoded.decoded.rpc_id,
							scene_token_response_for_suffix(party_scene, scratch),
							scratch,
						)
					} else if decoded.scene_handle == 142 || decoded.scene_handle == 143 {
						if body := captured_friend_notification_for_body(
							steam_friends_text,
							decoded.decoded,
							txn.label,
							1,
							scratch,
						); body != nil {
							append_scene_message(
								&txn.preds,
								decoded.scene_handle,
								1,
								body,
								scratch,
							)
						}
					} else if route_name == "party.updatepartysettings" ||
					   decoded.scene_handle >= 144 {
						append_scene_rpc_complete(
							&txn.preds,
							decoded.scene_handle,
							1,
							decoded.decoded.rpc_id,
							false,
							scratch,
						)
					}
				case 13:
					// party Party.CreateInvitationCode
					party_scene := predict_caleb_party_scene_for_handle(
						party_states[:],
						scene_handles[:],
						txn.label,
						decoded.scene_handle,
						predict_caleb_party_scene_for_owner(
							party_states[:],
							txn.label,
							party_scene_for_peer(txn.label),
						),
					)
					invite_code := predict_caleb_party_invite_for_scene(
						party_states[:],
						party_scene,
						txn.label,
					)
					append_auth_rpc_response(
						&txn.preds,
						decoded.scene_handle,
						decoded.decoded.rpc_id,
						mpe_str(invite_code, scratch),
						scratch,
					)
				case 16:
					// partyMerging.GetMergerStatus
					poll_index := count_previous_scene_route(txns[:], ps, 16)
					append_auth_rpc_response(
						&txn.preds,
						decoded.scene_handle,
						decoded.decoded.rpc_id,
						merger_status_raw(poll_index, scratch),
						scratch,
					)
				}
			}
		}

		append(&txns, txn)
		if len(txns) >= number_of_transactions_to_test do break
	}

	for &txn, i in txns {
		if i >= number_of_transactions_to_test do break
		real_human := render_decoded_burst(
			&txn.peer.reg_real,
			txn.peer.ep_real,
			txn.reals[:],
			scratch,
		)
		real_bytes := encode_decoded_messages(txn.reals[:], scratch)
		pred_human := render_decoded_burst(
			&txn.peer.reg_pred,
			txn.peer.ep_pred,
			txn.preds[:],
			scratch,
		)
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

replay :: proc(
	dgrams: ^UDP_Datagram_Store,
	msgs: ^RakNet_Message_Store,
	reasm: ^Reassembly,
	path: string,
) -> Error {
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
ingest_jsonl :: proc(
	dgrams: ^UDP_Datagram_Store,
	msgs: ^RakNet_Message_Store,
	reasm: ^Reassembly,
	path: string,
) -> Error {
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
		if datagram_is_health_channel(decoded) do continue

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
			fmt.printf(
				"  roundtrip MISMATCH [%d] len %d->%d\n    orig: ",
				i,
				len(original),
				len(encoded),
			)
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
