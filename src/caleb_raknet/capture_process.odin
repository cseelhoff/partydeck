package caleb_raknet

import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

Capture_Simple_Client :: struct {
	label:     string,
	client_id: int,
	state:     ^Simple_Server_State,
	ps:        ^Peer_State,
	pending:   [dynamic][]byte,
}

capture_to_text :: proc(path: string, out_path: string) -> Error {
	data := os.read_entire_file_from_path(path, context.allocator) or_return
	defer delete(data)

	scratch_backing := make([]byte, 256 * 1024 * 1024)
	defer delete(scratch_backing)
	scratch_arena: mem.Arena
	mem.arena_init(&scratch_arena, scratch_backing)
	scratch := mem.arena_allocator(&scratch_arena)

	peers: [dynamic]^Peer_State
	nidx := 1
	out := strings.builder_make(context.allocator)

	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if len(line) == 0 do continue

		rec: Relay_Record
		if json.unmarshal_string(line, &rec, allocator = context.temp_allocator) != nil {
			strings.write_string(&out, line)
			strings.write_byte(&out, '\n')
			free_all(context.temp_allocator)
			continue
		}
		peer, dir, ok_dir := relay_record_peer_dir(rec)
		if !ok_dir {
			capture_write_text_record(&out, rec, "<invalid relay direction>")
			free_all(context.temp_allocator)
			continue
		}
		dg, ok_hex := hex.decode(transmute([]byte)rec.hex, scratch)
		if !ok_hex {
			capture_write_text_record(&out, rec, "<invalid hex>")
			free_all(context.temp_allocator)
			continue
		}

		ps := find_peer(&peers, peer, &nidx)
		side := dir == "s2c" ? Side.Real : Side.C2S
		ep := dir == "s2c" ? ps.ep_real : ps.ep_client
		msgs := reassemble_side_all(ps, side, {dg}, scratch)
		if len(msgs) == 0 {
			capture_write_text_record(&out, rec, "<no complete messages>")
			free_all(context.temp_allocator)
			continue
		}
		human := render_burst(&ps.reg_real, ep, msgs, context.temp_allocator)
		capture_write_text_record(&out, rec, human)
		free_all(context.temp_allocator)
	}

	sync_write_out(out_path, strings.to_string(out))
	fmt.printfln("capture-text wrote -> %s", out_path)
	return nil
}

capture_simple_sv :: proc(path: string, out_path: string) -> Error {
	data := os.read_entire_file_from_path(path, context.allocator) or_return
	defer delete(data)

	scratch_backing := make([]byte, 256 * 1024 * 1024)
	defer delete(scratch_backing)
	scratch_arena: mem.Arena
	mem.arena_init(&scratch_arena, scratch_backing)
	scratch := mem.arena_allocator(&scratch_arena)

	simple_scene_infos_load(scratch) or_return
	if g_simple_party_scene_by_invite == nil do g_simple_party_scene_by_invite = make(map[string]string, scratch)
	if g_simple_party_owner_by_invite == nil do g_simple_party_owner_by_invite = make(map[string]string, scratch)
	if g_simple_client_id_by_user_id == nil do g_simple_client_id_by_user_id = make(map[string]int, scratch)
	if g_simple_steam_lobby_by_party_scene == nil do g_simple_steam_lobby_by_party_scene = make(map[string]u64, scratch)
	if g_simple_steam_lobby_by_invite == nil do g_simple_steam_lobby_by_invite = make(map[string]u64, scratch)
	g_simple_latest_party_steam_lobby_id = 0

	peers: [dynamic]^Peer_State
	clients: [dynamic]Capture_Simple_Client
	nidx := 1
	wire := new_world(scratch)
	out := strings.builder_make(context.allocator)

	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if len(line) == 0 do continue

		rec: Relay_Record
		if json.unmarshal_string(line, &rec, allocator = context.temp_allocator) != nil {
			strings.write_string(&out, line)
			strings.write_byte(&out, '\n')
			free_all(context.temp_allocator)
			continue
		}
		peer, dir, ok_dir := relay_record_peer_dir(rec)
		if !ok_dir {
			strings.write_string(&out, line)
			strings.write_byte(&out, '\n')
			free_all(context.temp_allocator)
			continue
		}
		dg, ok_hex := hex.decode(transmute([]byte)rec.hex, scratch)
		if !ok_hex {
			strings.write_string(&out, line)
			strings.write_byte(&out, '\n')
			free_all(context.temp_allocator)
			continue
		}

		ps := find_peer(&peers, peer, &nidx)
		client := capture_simple_client_for_peer(&clients, peer, ps, scratch)
		if dir == "c2s" {
			capture_simple_feed_request(client, &wire, dg, scratch)
			capture_write_hex_record(&out, rec, rec.hex)
		} else {
			capture_simple_seed_server(client, dg, scratch)
			new_hex := rec.hex
			if len(client.pending) > 0 {
				new_hex = string(hex.encode(client.pending[0], context.temp_allocator))
				ordered_remove(&client.pending, 0)
			}
			capture_write_hex_record(&out, rec, new_hex)
		}
		free_all(context.temp_allocator)
	}

	sync_write_out(out_path, strings.to_string(out))
	fmt.printfln("capture-simple-sv wrote -> %s", out_path)
	return nil
}

capture_simple_client_for_peer :: proc(
	clients: ^[dynamic]Capture_Simple_Client,
	label: string,
	ps: ^Peer_State,
	allocator := context.allocator,
) -> ^Capture_Simple_Client {
	for &client in clients^ {
		if client.label == label do return &client
	}
	state := new(Simple_Server_State)
	state.remote = ps.ep_client
	client := Capture_Simple_Client{
		label = strings.clone(label, allocator),
		client_id = len(clients^) + 1,
		state = state,
		ps = ps,
		pending = make([dynamic][]byte, allocator),
	}
	append(clients, client)
	return &clients^[len(clients^) - 1]
}

capture_simple_feed_request :: proc(
	client: ^Capture_Simple_Client,
	wire: ^World,
	dg: []byte,
	allocator := context.allocator,
) {
	all_encoded := reassemble_side(client.ps, .C2S, {dg}, allocator)
	if len(all_encoded) == 0 do return

	responses := make([dynamic]Decoded_Message, allocator)
	for encoded in all_encoded {
		if !message_is_health_channel(encoded) do continue
		decoded := decode_message(encoded, allocator)
		partial := get_response_from_request(client.client_id, client.label, decoded, false, client.state) or_continue
		for response in partial do append(&responses, response)
	}

	encoded_messages := filter_health_messages(all_encoded, allocator)
	decoded_messages := simple_backup_decode_for_sender(
		&client.ps.reg_real,
		client.ps.ep_client,
		encoded_messages,
		allocator,
	)
	for decoded in decoded_messages {
		partial := get_response_from_request(client.client_id, client.label, decoded, false, client.state) or_continue
		for response in partial do append(&responses, response)
	}
	if len(responses) == 0 do return

	clear(&wire.outbox)
	idx := conn_index(wire, client.ps.addr)
	conn := &wire.conns[idx]
	for response in responses {
		payload := encode_message(response, allocator)
		#partial switch response in response {
		case Connected_Ping, Connected_Pong:
			send_unreliable(wire, conn, payload)
		case:
			send_reliable(wire, conn, payload)
		}
	}
	for dg_out in wire.outbox {
		append(&client.pending, dg_out.data)
	}
}

capture_simple_seed_server :: proc(
	client: ^Capture_Simple_Client,
	dg: []byte,
	allocator := context.allocator,
) {
	encoded := reassemble_side(client.ps, .Real, {dg}, allocator)
	if len(encoded) == 0 do return
	decoded := simple_backup_decode_for_sender(&client.ps.reg_real, client.ps.ep_real, encoded, allocator)
	simple_backup_seed_real_values(client.state, decoded, true)
}

capture_write_hex_record :: proc(sb: ^strings.Builder, rec: Relay_Record, hex_value: string) {
	strings.write_string(sb, "{\"t\":")
	write_json_str(sb, rec.t)
	if rec.src != "" || rec.dst != "" {
		strings.write_string(sb, ",\"src\":")
		write_json_str(sb, rec.src)
		strings.write_string(sb, ",\"dst\":")
		write_json_str(sb, rec.dst)
	} else {
		strings.write_string(sb, ",\"dir\":")
		write_json_str(sb, rec.dir)
		strings.write_string(sb, ",\"peer\":")
		write_json_str(sb, rec.peer)
	}
	strings.write_string(sb, ",\"hex\":")
	write_json_str(sb, hex_value)
	strings.write_string(sb, "}\n")
}

capture_write_text_record :: proc(sb: ^strings.Builder, rec: Relay_Record, text_value: string) {
	strings.write_string(sb, "{\"t\":")
	write_json_str(sb, rec.t)
	if rec.src != "" || rec.dst != "" {
		strings.write_string(sb, ",\"src\":")
		write_json_str(sb, rec.src)
		strings.write_string(sb, ",\"dst\":")
		write_json_str(sb, rec.dst)
	} else {
		strings.write_string(sb, ",\"dir\":")
		write_json_str(sb, rec.dir)
		strings.write_string(sb, ",\"peer\":")
		write_json_str(sb, rec.peer)
	}
	strings.write_string(sb, ",\"text\":")
	write_json_str(sb, text_value)
	strings.write_string(sb, "}\n")
}
