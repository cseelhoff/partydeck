package caleb_raknet

// Step 3 harness: replay a relay_capture.jsonl ({t, dir, peer, hex}) through the
// clean-room predictor and write sync_assert.json -- the side-by-side of what the
// real backend sent vs what the predictor would send, per client transaction. This
// is the Odin port of sync-raknet.py's replay_main / TxnDecoder / _finalize.
//
// The atomic unit is the reassembled RakNet MESSAGE (mid + body), never a UDP
// datagram: split fragments are joined before anything is logged or compared. The
// match verdict is byte-level over the reassembled messages. Human renderings are
// still written for eyeballing, but route-name cache differences must not turn an
// otherwise identical prediction into a mismatch.

import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:slice"
import "core:strings"

SYNC_ASSERT_FILE :: "/tmp/pdlog/probe/sync_assert.json"
HR_MSG_SEP :: " | " // joins per-message renderings within one burst

// One capture row. Mirrors the ORIGINAL relay format (dir + peer), distinct from
// the caleb format ({t, from, len, hex}) the live logger writes.
Relay_Record :: struct {
	t:    string,
	dir:  string, // "c2s" | "s2c"
	peer: string, // "C1", "C2", ...
	hex:  string,
}

// Reassembly side: client->server, real server->client, predicted server->client.
// Real and predicted keep independent split buffers (a fragment stream on one side
// must not be confused with the other's).
Side :: enum {
	C2S  = 0,
	Real = 1,
	Pred = 2,
}

// One in-flight fragmented message: fragments collected by split id until all
// `count` arrive, then concatenated in index order. frags is sized to count on the
// first fragment; nil slots are the still-missing fragments.
Split_Entry :: struct {
	active: bool,
	id:     u16,
	count:  u32,
	have:   u32,
	frags:  [][]byte,
}

Side_Reasm :: struct {
	entries: [dynamic]Split_Entry,
}

// Per-peer harness state. Allocated via `new` so its route registries and split
// buffers keep stable addresses across the run (the peer list never copies them).
Peer_State :: struct {
	label:         string,
	addr:          Peer_Addr, // synthetic predictor client address
	ep_client:     net.Endpoint, // route-learning key for c2s (role Client)
	ep_real:       net.Endpoint, // route-learning key for real s2c (role Server)
	ep_pred:       net.Endpoint, // route-learning key for pred s2c (role Server)
	reg_real:      Route_Registry, // learns from c2s + real (renders sent + real)
	reg_pred:      Route_Registry, // learns from pred (renders pred)
	reasm:         [3]Side_Reasm,
	seen_reliable: [3]map[u32]bool, // per-side reliable message numbers already delivered (retransmit guard)
	active:        bool,
	t:             string,
	sent_msgs:     [dynamic][]byte, // already-reassembled c2s MESSAGES
	sent_human:    string,
	reals:         [dynamic][]byte, // accumulated real s2c DATAGRAMS (reassembled at finalize)
	preds:         [dynamic][]byte, // accumulated pred s2c DATAGRAMS
	pending_preds: [dynamic][]byte, // pred datagrams carried to the peer's next txn
}

Sync_Stats :: struct {
	total:   int,
	matched: int,
}

// True for an online data datagram carrying encapsulated content (predict.py
// _is_content_datagram): flags 0x80 set, ACK (0x40) and NAK (0x20) clear.
is_content_datagram :: proc(dg: []byte) -> bool {
	if len(dg) == 0 do return false
	f := dg[0]
	return (f & 0x80) != 0 && (f & 0x40) == 0 && (f & 0x20) == 0
}

// True for a RakNet ACK (0xC0) or NAK (0xA0) datagram: the online bit (0x80) set
// together with the ACK (0x40) or NAK (0x20) bit. The relay drops these from the
// upstream because it re-encodes client traffic into its own sequence space and
// acknowledges the clients itself.
datagram_is_ack_or_nak :: proc(dg: []byte) -> bool {
	if len(dg) == 0 do return false
	f := dg[0]
	return (f & 0x80) != 0 && ((f & 0x40) != 0 || (f & 0x20) != 0)
}

message_is_health_channel :: proc(msg: []byte) -> bool {
	if len(msg) == 0 do return false
	switch msg[0] {
	case u8(Message_Id.Connected_Ping),
	     u8(Message_Id.Connected_Pong),
	     u8(Message_Id.New_Incoming_Connection),
	     u8(Message_Id.Connection_Result):
		return true
	}
	if message_is_system_ping(msg) do return true
	if _, ok := message_ping_response_req_id(msg); ok do return true
	return false
}

message_is_system_ping :: proc(msg: []byte) -> bool {
	return(
		len(msg) >= 2 &&
		msg[0] == u8(Message_Id.System_Request) &&
		msg[1] == u8(System_Request_Id.Ping) \
	)
}

message_ping_response_req_id :: proc(msg: []byte) -> (u16, bool) {
	if len(msg) != 19 || msg[0] != u8(Message_Id.Response_Msg) do return 0, false
	return read_u16_le(msg, 1), true
}

message_response_complete_req_id :: proc(msg: []byte) -> (u16, bool) {
	if len(msg) != 4 || msg[0] != u8(Message_Id.Response_Complete) do return 0, false
	return read_u16_le(msg, 1), true
}

datagram_is_health_channel :: proc(dg: []byte) -> bool {
	if !is_content_datagram(dg) do return false
	packets: [MAX_INTERNAL_PACKETS]RakNet_Internal_Packet
	n := parse_internal_packets(dg, packets[:])
	if n == 0 do return false
	ping_reqs: [MAX_INTERNAL_PACKETS]u16
	ping_req_count := 0
	for i in 0 ..< n {
		pk := packets[i]
		if len(pk.payload) == 0 || pk.has_split do continue
		if req, ok := message_ping_response_req_id(pk.payload); ok {
			ping_reqs[ping_req_count] = req
			ping_req_count += 1
		}
	}
	seen := false
	for i in 0 ..< n {
		pk := packets[i]
		if len(pk.payload) == 0 do continue
		if pk.has_split do return false
		if !message_is_health_channel(pk.payload) {
			if req, ok := message_response_complete_req_id(pk.payload);
			   ok && u16_in(ping_reqs[:ping_req_count], req) {
				seen = true
				continue
			}
			return false
		}
		seen = true
	}
	return seen
}

messages_are_health_channel :: proc(msgs: [][]byte) -> bool {
	if len(msgs) == 0 do return false
	for msg in msgs {
		if !message_is_health_channel(msg) do return false
	}
	return true
}

filter_health_messages :: proc(msgs: [][]byte, allocator := context.allocator) -> [][]byte {
	out := make([dynamic][]byte, allocator)
	ping_reqs := make([dynamic]u16, allocator)
	for msg in msgs {
		if req, ok := message_ping_response_req_id(msg); ok do append(&ping_reqs, req)
	}
	for msg in msgs {
		if req, ok := message_response_complete_req_id(msg); ok && u16_in(ping_reqs[:], req) do continue
		if !message_is_health_channel(msg) do append(&out, msg)
	}
	return out[:]
}

u16_in :: proc(values: []u16, value: u16) -> bool {
	for v in values {
		if v == value do return true
	}
	return false
}

// Feed one split fragment; return the complete message once the last fragment of
// its split id has arrived, else ("", false).
split_feed :: proc(
	sr: ^Side_Reasm,
	pk: RakNet_Internal_Packet,
	allocator := context.allocator,
) -> (
	[]byte,
	bool,
) {
	ent: ^Split_Entry
	for &e in sr.entries {
		if e.active && e.id == pk.split_id {
			ent = &e
			break
		}
	}
	if ent == nil {
		for &e in sr.entries {
			if !e.active {
				ent = &e
				break
			}
		}
		if ent == nil {
			append(&sr.entries, Split_Entry{})
			ent = &sr.entries[len(sr.entries) - 1]
		}
		ent.active = true
		ent.id = pk.split_id
		ent.count = pk.split_count
		ent.have = 0
		ent.frags = make([][]byte, pk.split_count, allocator)
	}
	idx := int(pk.split_index)
	if idx < 0 || idx >= int(ent.count) do return nil, false
	if ent.frags[idx] == nil {
		ent.frags[idx] = slice.clone(pk.payload, allocator)
		ent.have += 1
	}
	if ent.have < ent.count do return nil, false

	total := 0
	for f in ent.frags do total += len(f)
	full := make([]byte, total, allocator)
	off := 0
	for f in ent.frags {
		copy(full[off:], f)
		off += len(f)
	}
	ent.active = false
	ent.frags = nil
	return full, true
}

// Parse a sequence of datagrams into the complete encapsulated MESSAGES they
// carry, reassembling split fragments via the side's persistent buffer.
reassemble_side :: proc(
	ps: ^Peer_State,
	side: Side,
	dgs: [][]byte,
	allocator := context.allocator,
) -> [][]byte {
	out := make([dynamic][]byte, allocator)
	sr := &ps.reasm[int(side)]
	seen := &ps.seen_reliable[int(side)]
	packets: [MAX_INTERNAL_PACKETS]RakNet_Internal_Packet
	for dg in dgs {
		n := parse_internal_packets(dg, packets[:])
		for i in 0 ..< n {
			pk := packets[i]
			if len(pk.payload) == 0 do continue
			// Drop reliable retransmits: RakNet's reliability layer delivers each
			// reliable message number to the application exactly once. A resent
			// datagram reuses the number, so a server would not re-respond.
			if pk.reliability == .Reliable ||
			   pk.reliability == .Reliable_Ordered ||
			   pk.reliability == .Reliable_Sequenced {
				if seen^ == nil do seen^ = make(map[u32]bool)
				if seen^[pk.reliable_message_number] do continue
				seen^[pk.reliable_message_number] = true
			}
			if !pk.has_split {
				append(&out, slice.clone(pk.payload, allocator))
				continue
			}
			full, ok := split_feed(sr, pk, allocator)
			if ok do append(&out, full)
		}
	}
	return out[:]
}

// One complete application message plus the reliability class it arrived on, so
// the relay can re-frame and forward it upstream individually (gated) while
// keeping each message's delivery semantics.
Reassembled_Message :: struct {
	reliability: Reliability,
	payload:     []byte,
}

// Same reassembly as reassemble_side, but it preserves each message's reliability
// class instead of discarding it. The relay uses this to re-encode and forward one
// decoded message at a time toward upstream.
reassemble_side_meta :: proc(
	ps: ^Peer_State,
	side: Side,
	dgs: [][]byte,
	allocator := context.allocator,
) -> []Reassembled_Message {
	out := make([dynamic]Reassembled_Message, allocator)
	sr := &ps.reasm[int(side)]
	seen := &ps.seen_reliable[int(side)]
	packets: [MAX_INTERNAL_PACKETS]RakNet_Internal_Packet
	for dg in dgs {
		n := parse_internal_packets(dg, packets[:])
		for i in 0 ..< n {
			pk := packets[i]
			if len(pk.payload) == 0 do continue
			if pk.reliability == .Reliable ||
			   pk.reliability == .Reliable_Ordered ||
			   pk.reliability == .Reliable_Sequenced {
				if seen^ == nil do seen^ = make(map[u32]bool)
				if seen^[pk.reliable_message_number] do continue
				seen^[pk.reliable_message_number] = true
			}
			if !pk.has_split {
				append(
					&out,
					Reassembled_Message {
						reliability = pk.reliability,
						payload = slice.clone(pk.payload, allocator),
					},
				)
				continue
			}
			full, ok := split_feed(sr, pk, allocator)
			if ok do append(&out, Reassembled_Message{reliability = pk.reliability, payload = full})
		}
	}
	return out[:]
}

// Render a burst of complete messages to one human-readable string, learning routes
// into `reg` along the way (so scene messages later resolve their route names).
render_burst :: proc(
	reg: ^Route_Registry,
	ep: net.Endpoint,
	msgs: [][]byte,
	allocator := context.allocator,
) -> string {
	sb := strings.builder_make(allocator)
	for m, i in msgs {
		if i > 0 do strings.write_string(&sb, HR_MSG_SEP)
		decoded := decode_message(m, context.temp_allocator)
		route_registry_observe(reg, ep, decoded)
		route_name := ""
		if sm, ok := decoded.(Scene_Message); ok {
			route_name = route_registry_resolve(reg, ep, sm.scene_handle, sm.route_handle)
			if route_name == "" do route_name = scene_message_infer_route_name(sm, allocator)
			decoded = scene_message_with_route_body(decoded, route_name, context.temp_allocator)
		}
		write_decoded_message(&sb, decoded, route_name)
	}
	return strings.to_string(sb)
}

// Run the predictor for one c2s datagram; split the emitted content datagrams into
// own (back to caddr) and cross (server-initiated pushes to other peers).
sync_predict :: proc(
	world: ^World,
	caddr: Peer_Addr,
	dg: []byte,
	own: ^[dynamic][]byte,
	cross: ^[dynamic]Out_Dg,
) {
	out := predict(world, caddr, dg)
	for od in out {
		if !is_content_datagram(od.data) do continue
		if datagram_is_health_channel(od.data) do continue
		if od.addr == caddr {
			append(own, od.data)
		} else {
			append(cross, od)
		}
	}
}

// --- record writing ----------------------------------------------------------

write_json_str :: proc(sb: ^strings.Builder, s: string) {
	opt: json.Marshal_Options
	json.marshal_to_builder(sb, s, &opt)
}

write_hex_array :: proc(sb: ^strings.Builder, msgs: [][]byte) {
	strings.write_byte(sb, '[')
	for m, i in msgs {
		if i > 0 do strings.write_byte(sb, ',')
		strings.write_byte(sb, '"')
		for x in m do fmt.sbprintf(sb, "%02x", x)
		strings.write_byte(sb, '"')
	}
	strings.write_byte(sb, ']')
}

message_bursts_equal :: proc(real, pred: [][]byte) -> bool {
	if len(real) != len(pred) do return false
	for msg, i in real {
		if !bytes_equal(msg, pred[i]) do return false
	}
	return true
}

// One pretty-printed transaction record (field order matches sync-raknet.py's
// _finalize so the three *_human_readable lines sit together for eyeballing).
sync_write_record :: proc(
	sb: ^strings.Builder,
	t, peer: string,
	match: bool,
	sent, real, pred: [][]byte,
	sent_h, real_h, pred_h: string,
) {
	strings.write_string(sb, "{\n  \"t\": ")
	write_json_str(sb, t)
	strings.write_string(sb, ",\n  \"peer\": ")
	write_json_str(sb, peer)
	strings.write_string(sb, ",\n  \"match\": ")
	strings.write_string(sb, match ? "true" : "false")
	strings.write_string(sb, ",\n  \"sent\": ")
	write_hex_array(sb, sent)
	strings.write_string(sb, ",\n  \"sent_human_readable\": ")
	write_json_str(sb, sent_h)
	strings.write_string(sb, ",\n  \"real_human_readable\": ")
	write_json_str(sb, real_h)
	strings.write_string(sb, ",\n  \"pred_human_readable\": ")
	write_json_str(sb, pred_h)
	write_human_diff_fields(sb, real_h, pred_h)
	strings.write_string(sb, ",\n  \"real\": ")
	write_hex_array(sb, real)
	strings.write_string(sb, ",\n  \"pred\": ")
	write_hex_array(sb, pred)
	strings.write_string(sb, "\n}\n\n")
}

write_human_diff_fields :: proc(sb: ^strings.Builder, real_h, pred_h: string) {
	if real_h == pred_h do return
	real_diff, pred_diff := human_diff_strings(real_h, pred_h, context.temp_allocator)
	strings.write_string(sb, ",\n  \"real_diff\": ")
	write_json_str(sb, real_diff)
	strings.write_string(sb, ",\n  \"pred_diff\": ")
	write_json_str(sb, pred_diff)
}

human_diff_strings :: proc(
	real_h, pred_h: string,
	allocator := context.allocator,
) -> (string, string) {
	real_diff := strings.builder_make(allocator)
	pred_diff := strings.builder_make(allocator)
	shared := min(len(real_h), len(pred_h))
	for i in 0 ..< shared {
		if real_h[i] == pred_h[i] do continue
		strings.write_byte(&real_diff, real_h[i])
		strings.write_byte(&pred_diff, pred_h[i])
	}
	for i in shared ..< len(real_h) do strings.write_byte(&real_diff, real_h[i])
	for i in shared ..< len(pred_h) do strings.write_byte(&pred_diff, pred_h[i])
	return strings.to_string(real_diff), strings.to_string(pred_diff)
}

// Reassemble + render + write the peer's open transaction, then reset it.
finalize_txn :: proc(ps: ^Peer_State, out_sb: ^strings.Builder, stats: ^Sync_Stats) {
	if !ps.active do return
	real_msgs := filter_health_messages(reassemble_side(ps, .Real, ps.reals[:]))
	pred_msgs := filter_health_messages(reassemble_side(ps, .Pred, ps.preds[:]))
	real_human := render_burst(&ps.reg_real, ps.ep_real, real_msgs)
	pred_human := render_burst(&ps.reg_pred, ps.ep_pred, pred_msgs)
	free_all(context.temp_allocator)

	match := message_bursts_equal(real_msgs, pred_msgs)
	sync_write_record(
		out_sb,
		ps.t,
		ps.label,
		match,
		ps.sent_msgs[:],
		real_msgs,
		pred_msgs,
		ps.sent_human,
		real_human,
		pred_human,
	)
	stats.total += 1
	if match do stats.matched += 1

	ps.active = false
	clear(&ps.sent_msgs)
	clear(&ps.reals)
	clear(&ps.preds)
	ps.sent_human = ""
}

// --- peer registry -----------------------------------------------------------

find_peer :: proc(peers: ^[dynamic]^Peer_State, label: string, nidx: ^int) -> ^Peer_State {
	for ps in peers {
		if ps.label == label do return ps
	}
	n := nidx^
	nidx^ += 1
	ps := new(Peer_State)
	ps.label = strings.clone(label)
	ps.addr = Peer_Addr {
		ip   = {10, 0, 0, u8(n)},
		port = u16(n),
	}
	ps.ep_client = net.Endpoint {
		address = net.IP4_Address{10, 0, 0, u8(n)},
		port    = n,
	}
	ps.ep_real = net.Endpoint {
		address = net.IP4_Address{10, 1, 0, u8(n)},
		port    = n,
	}
	ps.ep_pred = net.Endpoint {
		address = net.IP4_Address{10, 2, 0, u8(n)},
		port    = n,
	}
	route_registry_init(&ps.reg_real)
	route_registry_init(&ps.reg_pred)
	append(peers, ps)
	return ps
}

peer_by_addr :: proc(peers: ^[dynamic]^Peer_State, addr: Peer_Addr) -> ^Peer_State {
	for ps in peers {
		if ps.addr == addr do return ps
	}
	return nil
}

// Attribute server-initiated cross-peer pushes to the target peer's open
// transaction, or buffer them for its next one (predict.py route_cross).
route_cross :: proc(peers: ^[dynamic]^Peer_State, cross: [dynamic]Out_Dg) {
	for od in cross {
		tp := peer_by_addr(peers, od.addr)
		if tp == nil do continue
		if tp.active {
			append(&tp.preds, od.data)
		} else {
			append(&tp.pending_preds, od.data)
		}
	}
}

// --- entry -------------------------------------------------------------------

// Replay `path` and write the assert file (default SYNC_ASSERT_FILE, or `out_path`).
sync_replay :: proc(path: string, out_path := SYNC_ASSERT_FILE) -> Error {
	data := os.read_entire_file_from_path(path, context.allocator) or_return
	defer delete(data)

	world := new_world()
	peers: [dynamic]^Peer_State
	nidx := 1
	out_sb := strings.builder_make()
	stats: Sync_Stats
	last_t := ""

	own: [dynamic][]byte
	cross: [dynamic]Out_Dg

	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if len(line) == 0 do continue
		rec: Relay_Record
		if json.unmarshal_string(line, &rec, allocator = context.allocator) != nil do continue
		dg, ok := hex.decode(transmute([]byte)rec.hex, context.allocator)
		if !ok do continue
		last_t = rec.t

		ps := find_peer(&peers, rec.peer, &nidx)

		if rec.dir == "c2s" {
			if datagram_is_health_channel(dg) do continue
			clear(&own)
			clear(&cross)
			if !is_content_datagram(dg) {
				// handshake / ACK: advance the predictor (so a connection exists) but
				// open no recorded transaction.
				sync_predict(&world, ps.addr, dg, &own, &cross)
				route_cross(&peers, cross)
				continue
			}
			msgs := filter_health_messages(reassemble_side(ps, .C2S, {dg}))
			if len(msgs) == 0 {
				// a pure split-fragment carrier: no complete client message yet, so
				// this is not its own transaction. Carry predictions to the txn the
				// completing fragment opens.
				sync_predict(&world, ps.addr, dg, &own, &cross)
				for d in own do append(&ps.pending_preds, d)
				route_cross(&peers, cross)
				continue
			}
			// a complete client message finalizes the previous transaction and opens
			// a new one keyed on this atomic message.
			finalize_txn(ps, &out_sb, &stats)
			sync_predict(&world, ps.addr, dg, &own, &cross)

			ps.active = true
			ps.t = rec.t
			clear(&ps.sent_msgs)
			for m in msgs do append(&ps.sent_msgs, m)
			ps.sent_human = render_burst(&ps.reg_real, ps.ep_client, msgs)
			free_all(context.temp_allocator)
			clear(&ps.preds)
			for d in ps.pending_preds do append(&ps.preds, d)
			clear(&ps.pending_preds)
			for d in own do append(&ps.preds, d)
			route_cross(&peers, cross)
		} else { 	// s2c
			if datagram_is_health_channel(dg) do continue
			if !is_content_datagram(dg) do continue
			if ps.active do append(&ps.reals, dg)
		}
	}

	// drain trailing cross-peer pushes, then flush every open transaction.
	for ps in peers {
		if len(ps.pending_preds) == 0 do continue
		if ps.active {
			for d in ps.pending_preds do append(&ps.preds, d)
		} else {
			ps.active = true
			ps.t = last_t
			ps.sent_human = "(trailing cross-peer pushes)"
			for d in ps.pending_preds do append(&ps.preds, d)
		}
		clear(&ps.pending_preds)
	}
	for ps in peers {
		finalize_txn(ps, &out_sb, &stats)
	}

	sync_write_out(out_path, strings.to_string(out_sb))
	fmt.printfln(
		"=== sync replay: %d/%d transactions match -> %s ===",
		stats.matched,
		stats.total,
		out_path,
	)
	return nil
}

// Create the output directory chain and write the assert file.
sync_write_out :: proc(out_path: string, content: string) {
	if dir := dir_of(out_path); dir != "" {
		make_dirs(dir)
	}
	werr := os.write_entire_file(out_path, transmute([]byte)content)
	_ = werr
}

dir_of :: proc(path: string) -> string {
	idx := strings.last_index_byte(path, '/')
	if idx <= 0 do return ""
	return path[:idx]
}

// Best-effort recursive mkdir (ignores "already exists"); paths here are trusted.
make_dirs :: proc(path: string) {
	start := 1 // skip leading '/'
	for i in start ..< len(path) {
		if path[i] == '/' {
			os.make_directory(path[:i])
		}
	}
	os.make_directory(path)
}
