package caleb_raknet

// simple_net is a fresh, intentionally flat entrypoint for building the next
// network predictor/server shape. It listens locally, runs the plain dtlive HTTP
// token shim, reassembles client RakNet content datagrams into encoded messages,
// decodes each message into the typed unions, then dispatches through explicit
// switch cases. The cases are stubs for now.

import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:time"

SIMPLE_DEFAULT_RAKNET_ENDPOINT :: "10.1.1.129:30100"
SIMPLE_DEFAULT_DTLIVE_PORT :: 8080
SIMPLE_DEFAULT_PREDICT_FILE :: "/tmp/pdlog/probe/simple_predict.json"
SIMPLE_DEFAULT_RELAY_PREDICT_FILE :: "/tmp/pdlog/probe/simple_relay_predict.json"
SIMPLE_POLL_TIMEOUT_MS :: 1000
SIMPLE_MAX_RESPONSES :: 12

Poll_Slot :: enum int {
	UDP,
	HTTP,
}

Simple_Server_State :: struct {
	remote:                      net.Endpoint,
	scenes:                      [dynamic; SCENE_CONNECTION_RESULT_MAX_SCENES]Simple_Scene,
	connected_ping:              Connected_Ping,
	connected_pong:              Connected_Pong,
	connection_request:          Connection_Request,
	connection_request_accepted: Connection_Request_Accepted,
	new_incoming_connection:     New_Incoming_Connection,
	disconnection_notification:  Disconnection_Notification,
	system_request:              System_Request,
	response_msg:                Response_Msg,
	response_complete:           Response_Complete,
	response_error:              Response_Error,
	connection_result:           Connection_Result,
	scene_message:               Scene_Message,
	malformed_message:           Malformed_Message,
	unknown_message:             Unknown_Message,
	connect_to_scene_args:       Connect_To_Scene_Args,
	get_scene_infos_args:        Get_Scene_Infos_Args,
	set_metadata_args:           Set_Metadata_Args,
	scene_ready_args:            Scene_Ready_Args,
	disconnect_from_scene_args:  Disconnect_From_Scene_Args,
	ping_args:                   Ping_Args,
	no_args:                     No_Args,
	unparsed_args:               Unparsed_Args,
	scene_infos:                 Scene_Infos,
	scene_connection_result:     Scene_Connection_Result,
	bool_result:                 Bool_Result,
	session_token:               Session_Token,
	ping_response:               Ping_Response,
	other_response:              Other_Response,
	user_id:                     string,
	steam_id:                    string,
	steam_lobby_id:              u64,
	scene_raw_body:              Scene_Raw_Body,
	stormancer_rpc_completed:    Stormancer_Rpc_Completed_Body,
	stormancer_rpc_next:         Stormancer_Rpc_Next_Body,
	stormancer_rpc_error:        Stormancer_Rpc_Error_Body,
	authentication_login:        Authentication_Login_Body,
	friends_subscribe:           Friends_Subscribe_Body,
	friends_update_friend_list:  Friends_UpdateFriendList_Body,
	friends_notification:        Friends_Notification_Body,
	gamesession_get_p2p_token:   GameSession_GetP2PToken_Body,
	game_session_ready:          bool,
	game_version_update:         GameVersion_Update_Body,
	gamefinder_update:           Gamefinder_Update_Body,
	locator_get_scene_token:     Locator_GetSceneConnectionToken_Body,
	party_create_invitation:     Party_CreateInvitationCode_Body,
	invitation_code_override:    string,
	party_get_party_state2:      Party_GetPartyState2_Body,
	party_leader_user_id:        string,
	party_member_connected:      Party_MemberConnected_Body,
	party_member_connected_raw_override: []byte,
	party_member_data_updated:   Party_MemberDataUpdated_Body,
	party_member_disconnected:   Party_MemberDisconnected_Body,
	party_member_status_updated: Party_MemberStatusUpdated_Body,
	party_member_connected_after_settings_ack: bool,
	party_settings_updated:      Party_SettingsUpdated_Body,
	party_update_gf_status:      Party_UpdateGameFinderPlayerStatus_Body,
	party_update_settings:       Party_UpdatePartySettings_Body,
	party_update_user_data2:     Party_UpdatePartyUserData2_Body,
	party_conn_token_from_code:  PartyManagement_CreateConnectionTokenFromInvitationCode_Body,
	party_create_session:        PartyManagement_CreateSession_Body,
	party_scene_override:        string,
	party_create_session_tail:   []byte,
	pending_response_complete_req: u16,
	pending_matchmaking_infos_complete_req: u16,
	pending_party_scene_infos:   string,
	user_session_data_override:  []byte,
	party_merging_status:        PartyMerging_GetMergerStatus_Body,
	player_update:               Player_Update_Body,
	steam_create_lobby:          Steam_CreateLobby_Body,
	steam_join_lobby:            Steam_JoinLobby_Body,
	steam_update_joinable:       Steam_UpdateLobbyJoinable_Body,
	user_session_update_options: UserSession_UpdateUserOptions_Body,
}

Simple_Cross_Message :: struct {
	remote: net.Endpoint,
	msg:    Decoded_Message,
}

Simple_Relay_Shadow :: struct {
	enabled:  bool,
	out_path: string,
	log:      strings.Builder,
	peers:    [dynamic]^Peer_State,
	nidx:     int,
	records:  int,
}

client_list: map[net.Endpoint]int
g_server_state: [dynamic]Simple_Server_State
g_simple_scene_infos: Predict_Caleb_Scene_Infos
g_simple_raknet_samples_text: string
g_simple_steam_friends_text: string
g_simple_user_ids_by_steam: map[string]string
g_simple_party_scene_by_invite: map[string]string
g_simple_party_owner_by_invite: map[string]string
g_simple_client_id_by_user_id: map[string]int
g_simple_steam_lobby_by_party_scene: map[string]u64
g_simple_steam_lobby_by_invite: map[string]u64
g_simple_latest_party_steam_lobby_id: u64
g_simple_cross_messages: [dynamic]Simple_Cross_Message
g_simple_party_join_announced: map[string]bool
g_simple_party_join_ready_announced: map[string]bool

simple_net :: proc(
	dgrams: ^UDP_Datagram_Store,
	msgs: ^RakNet_Message_Store,
	reasm: ^Reassembly,
) -> Error {
	simple_net_globals_init()

	bind_addr := net.parse_address(LISTEN_HOST)
	sock := net.make_bound_udp_socket(bind_addr, LISTEN_PORT) or_return
	defer net.close(sock)

	scratch_backing := make([]byte, 128 * 1024 * 1024)
	defer delete(scratch_backing)
	scratch_arena: mem.Arena
	mem.arena_init(&scratch_arena, scratch_backing)
	scratch := mem.arena_allocator(&scratch_arena)
	simple_scene_infos_load(scratch) or_return

	log_scratch_backing := make([]byte, MAX_UDP_SIZE * 4 + 512)
	defer delete(log_scratch_backing)
	log_scratch_arena: mem.Arena
	mem.arena_init(&log_scratch_arena, log_scratch_backing)
	log_scratch := mem.arena_allocator(&log_scratch_arena)

	wire := new_world()
	live_peers: [dynamic]Live_Peer_Wire
	peers: [dynamic]^Peer_State
	nidx := 1

	http_port := env_int("PROBE_PORT", SIMPLE_DEFAULT_DTLIVE_PORT)
	http_sock, http_enabled := dtlive_try_listen(bind_addr, http_port)
	raknet_endpoint := env_string("RAKNET_ENDPOINT", SIMPLE_DEFAULT_RAKNET_ENDPOINT, scratch)
	verbose := env_truthy("SIMPLE_NET_VERBOSE")
	simple_predict_path := env_string("SIMPLE_PREDICT_FILE", SIMPLE_DEFAULT_PREDICT_FILE, scratch)
	simple_predict_log := strings.builder_make()
	defer strings.builder_destroy(&simple_predict_log)
	sync_write_out(simple_predict_path, "")

	fmt.printfln(
		"simple_net listening on udp %s:%d; dtlive plain %s:%d; token raknet endpoint %s; predict -> %s",
		LISTEN_HOST,
		LISTEN_PORT,
		LISTEN_HOST,
		http_port,
		raknet_endpoint,
		simple_predict_path,
	)

	polls: [dynamic; 2]posix.pollfd
	for {
		clear(&polls)
		append(&polls, posix.pollfd {
			fd     = udp_fd(sock),
			events = {.IN},
		})
		if http_enabled {
			append(&polls, posix.pollfd {
				fd     = tcp_fd(http_sock),
				events = {.IN},
			})
		}

		ready := posix.poll(&polls[Poll_Slot.UDP], posix.nfds_t(len(polls)), SIMPLE_POLL_TIMEOUT_MS)
		if ready <= 0 do continue
		if http_enabled && .IN in polls[Poll_Slot.HTTP].revents {
			simple_dtlive_handle_one(http_sock, log_scratch)
		}
		if !(.IN in polls[Poll_Slot.UDP].revents) do continue

		buf: [MAX_UDP_SIZE]byte
		bytes_read, remote := net.recv_udp(sock, buf[:]) or_continue
		if bytes_read <= 0 do continue
		simple_handle_udp_datagram(
			sock,
			remote,
			buf[:bytes_read],
			dgrams,
			msgs,
			reasm,
			&wire,
			&live_peers,
			&peers,
			&nidx,
			&simple_predict_log,
			simple_predict_path,
			verbose,
			scratch,
		)
	}
	return nil
}

simple_handle_udp_datagram :: proc(
	sock: net.UDP_Socket,
	remote: net.Endpoint,
	data: []byte,
	dgrams: ^UDP_Datagram_Store,
	msgs: ^RakNet_Message_Store,
	reasm: ^Reassembly,
	wire: ^World,
	live_peers: ^[dynamic]Live_Peer_Wire,
	peers: ^[dynamic]^Peer_State,
	nidx: ^int,
	simple_predict_log: ^strings.Builder,
	simple_predict_path: string,
	verbose: bool,
	scratch: mem.Allocator,
) {
	client_id, is_new_client := simple_net_client_id(remote)
	if is_new_client {
		fmt.printfln("simple client_id=%d -> %v", client_id, remote)
	}

	peer_count_before := len(live_peers^)
	peer_index := live_peer_index(live_peers, remote)
	label := live_peers^[peer_index].label
	if len(live_peers^) != peer_count_before {
		fmt.printfln("simple client %s -> %v", label, remote)
	}

	if live_predict_handle_health(sock, wire, live_peers^[peer_index].addr, data) do return

	if !udp_datagram_push(dgrams, remote, time.now(), data) {
		fmt.eprintfln("datagram store full, dropping %d bytes", len(data))
		return
	}
	process_udp_datagram(dgrams, msgs, reasm, dgrams.count - 1)

	if live_predict_handle_offline(sock, wire, live_peers^[peer_index].addr, data, scratch) do return
	if !is_content_datagram(data) do return

	net.send_udp(sock, make_ack(read_u24_le(data, 1), scratch), remote)

	peer_state := find_peer(peers, label, nidx)
	all_encoded_messages := reassemble_side(peer_state, .C2S, {data}, scratch)
	if len(all_encoded_messages) == 0 do return
	encoded_messages := filter_health_messages(all_encoded_messages, scratch)

	decoded_messages: [dynamic]Decoded_Message
	response_messages: [dynamic]Decoded_Message
	simple_server_state := &g_server_state[client_id]
	for encoded_message in all_encoded_messages {
		if !message_is_health_channel(encoded_message) do continue
		decoded := decode_message(encoded_message, scratch)
		partial_response_messages := get_response_from_request(
			client_id,
			label,
			decoded,
			verbose,
			simple_server_state,
		) or_continue
		for response_message in partial_response_messages do append(&response_messages, response_message)
	}
	for encoded_message in encoded_messages {
		decoded := decode_message(encoded_message, scratch)
		route_registry_observe(&peer_state.reg_real, peer_state.ep_client, decoded)
		if sm, ok := decoded.(Scene_Message); ok {
			route_name := route_registry_resolve(
				&peer_state.reg_real,
				peer_state.ep_client,
				sm.scene_handle,
				sm.route_handle,
			)
			decoded = scene_message_with_route_body(decoded, route_name, scratch)
		}
		append(&decoded_messages, decoded)
	}
	defer delete(decoded_messages)
	defer delete(response_messages)

	for decoded in decoded_messages {
		partial_response_messages := get_response_from_request(
			client_id,
			label,
			decoded,
			verbose,
			simple_server_state,
		) or_continue
		for response_message in partial_response_messages do append(&response_messages, response_message)
	}

	for response_message in response_messages {
		route_registry_observe(&peer_state.reg_real, peer_state.ep_real, response_message, scratch)
	}
	if len(decoded_messages) > 0 || len(response_messages) > 0 {
		simple_net_write_live_record(
			simple_predict_log,
			simple_predict_path,
			&peer_state.reg_real,
			peer_state.ep_client,
			peer_state.ep_real,
			label,
			encoded_messages,
			decoded_messages[:],
			response_messages[:],
			scratch,
		)
	}
	if len(response_messages) > 0 {
		live_send_decoded_messages(sock, wire, remote, response_messages[:], scratch)
	}
	simple_net_flush_cross_messages(
		sock,
		wire,
		live_peers,
		peers,
		nidx,
		simple_predict_log,
		simple_predict_path,
		scratch,
	)

	if verbose && env_truthy("SIMPLE_NET_TRACE_COUNTS") {
		fmt.printfln(
			"simple %s c2s_msgs=%d pred_msgs=%d",
			label,
			len(encoded_messages),
			len(response_messages),
		)
	}
}

simple_queue_cross_message :: proc(remote: net.Endpoint, msg: Decoded_Message) {
	if g_simple_cross_messages == nil do g_simple_cross_messages = make([dynamic]Simple_Cross_Message)
	append(&g_simple_cross_messages, Simple_Cross_Message{remote = remote, msg = msg})
}

simple_net_flush_cross_messages :: proc(
	sock: net.UDP_Socket,
	wire: ^World,
	live_peers: ^[dynamic]Live_Peer_Wire,
	peers: ^[dynamic]^Peer_State,
	nidx: ^int,
	simple_predict_log: ^strings.Builder,
	simple_predict_path: string,
	scratch: mem.Allocator,
) {
	if g_simple_cross_messages == nil || len(g_simple_cross_messages) == 0 do return
	kept: [dynamic]Simple_Cross_Message
	flushed := make([]bool, len(g_simple_cross_messages), scratch)
	for i in 0 ..< len(g_simple_cross_messages) {
		if flushed[i] do continue
		remote := g_simple_cross_messages[i].remote
		if remote.port == 0 {
			append(&kept, g_simple_cross_messages[i])
			flushed[i] = true
			continue
		}
		msgs := make([dynamic]Decoded_Message, scratch)
		for j in i ..< len(g_simple_cross_messages) {
			if flushed[j] || g_simple_cross_messages[j].remote != remote do continue
			append(&msgs, g_simple_cross_messages[j].msg)
			flushed[j] = true
		}
		if env_truthy("SIMPLE_NET_VERBOSE") do fmt.printfln("simple cross flush -> %v msgs=%d", remote, len(msgs))
		if label, ok := simple_live_label_for_remote(live_peers^[:], remote); ok {
			peer_state := find_peer(peers, label, nidx)
			simple_net_write_live_record(
				simple_predict_log,
				simple_predict_path,
				&peer_state.reg_real,
				peer_state.ep_client,
				peer_state.ep_real,
				label,
				{},
				{},
				msgs[:],
				scratch,
			)
		}
		live_send_decoded_messages(sock, wire, remote, msgs[:], scratch)
	}
	clear(&g_simple_cross_messages)
	for cross in kept do append(&g_simple_cross_messages, cross)
}

simple_live_label_for_remote :: proc(peers: []Live_Peer_Wire, remote: net.Endpoint) -> (string, bool) {
	for peer in peers {
		if peer.remote == remote do return peer.label, true
	}
	return "", false
}

simple_relay_shadow_step :: proc(
	shadow: ^Simple_Relay_Shadow,
	clients: []Relay_Client,
	label: string,
	remote: net.Endpoint,
	sent_msgs: [][]byte,
	allocator := context.allocator,
) {
	if shadow == nil || !shadow.enabled || len(sent_msgs) == 0 do return
	client_id, _ := simple_net_client_id(remote)
	peer_state := find_peer(&shadow.peers, label, &shadow.nidx)
	simple_server_state := &g_server_state[client_id]

	decoded_messages := make([dynamic]Decoded_Message, allocator)
	response_messages := make([dynamic]Decoded_Message, allocator)

	for msg in sent_msgs {
		decoded := decode_message(msg, allocator)
		route_registry_observe(&peer_state.reg_real, peer_state.ep_client, decoded)
		if sm, ok := decoded.(Scene_Message); ok {
			route_name := route_registry_resolve(
				&peer_state.reg_real,
				peer_state.ep_client,
				sm.scene_handle,
				sm.route_handle,
			)
			decoded = scene_message_with_route_body(decoded, route_name, allocator)
		}
		append(&decoded_messages, decoded)
	}

	for decoded in decoded_messages {
		partial_response_messages := get_response_from_request(
			client_id,
			label,
			decoded,
			false,
			simple_server_state,
		) or_continue
		for response_message in partial_response_messages do append(&response_messages, response_message)
	}

	for response_message in response_messages {
		route_registry_observe(&peer_state.reg_real, peer_state.ep_real, response_message, allocator)
	}
	if len(decoded_messages) > 0 || len(response_messages) > 0 {
		shadow.records += 1
		simple_net_write_live_record(
			&shadow.log,
			shadow.out_path,
			&peer_state.reg_real,
			peer_state.ep_client,
			peer_state.ep_real,
			label,
			sent_msgs,
			decoded_messages[:],
			response_messages[:],
			allocator,
		)
		if env_truthy("SIMPLE_RELAY_TRACE_COUNTS") {
			fmt.printfln(
				"simple relay shadow %s records=%d c2s_msgs=%d pred_msgs=%d",
				label,
				shadow.records,
				len(sent_msgs),
				len(response_messages),
			)
		}
	}
	simple_relay_shadow_flush_cross(shadow, clients, allocator)
}

simple_relay_shadow_flush_cross :: proc(
	shadow: ^Simple_Relay_Shadow,
	clients: []Relay_Client,
	allocator := context.allocator,
) {
	if shadow == nil || !shadow.enabled || g_simple_cross_messages == nil || len(g_simple_cross_messages) == 0 do return
	for cross in g_simple_cross_messages {
		label, ok := simple_relay_label_for_remote(clients, cross.remote)
		if !ok do continue
		peer_state := find_peer(&shadow.peers, label, &shadow.nidx)
		msgs := [?]Decoded_Message{cross.msg}
		shadow.records += 1
		simple_net_write_live_record(
			&shadow.log,
			shadow.out_path,
			&peer_state.reg_real,
			peer_state.ep_client,
			peer_state.ep_real,
			label,
			{},
			{},
			msgs[:],
			allocator,
		)
		if env_truthy("SIMPLE_RELAY_TRACE_COUNTS") {
			fmt.printfln("simple relay shadow %s records=%d cross_msgs=1", label, shadow.records)
		}
	}
	clear(&g_simple_cross_messages)
}

simple_relay_label_for_remote :: proc(clients: []Relay_Client, remote: net.Endpoint) -> (string, bool) {
	for client in clients {
		if client.client == remote do return client.peer, true
	}
	return "", false
}

simple_net_write_live_record :: proc(
	out: ^strings.Builder,
	out_path: string,
	reg: ^Route_Registry,
	ep_client, ep_server: net.Endpoint,
	label: string,
	sent_bytes: [][]byte,
	sent_decoded: []Decoded_Message,
	pred_decoded: []Decoded_Message,
	allocator := context.allocator,
) {
	pred_bytes := simple_backup_encode_generated(pred_decoded, allocator)
	sent_human := render_decoded_burst(reg, ep_client, sent_decoded, allocator)
	pred_human := render_decoded_burst(reg, ep_server, pred_decoded, allocator)
	stamp, _ := time.time_to_rfc3339(time.now(), allocator = allocator)
	sync_write_record(
		out,
		stamp,
		label,
		false,
		sent_bytes,
		{},
		pred_bytes,
		sent_human,
		"",
		pred_human,
	)
	sync_write_out(out_path, strings.to_string(out^))
}

simple_net_globals_init :: proc() {
	if client_list == nil do client_list = make(map[net.Endpoint]int)
	if g_server_state == nil do g_server_state = make([dynamic]Simple_Server_State)
	if g_simple_party_scene_by_invite == nil do g_simple_party_scene_by_invite = make(map[string]string)
	if g_simple_party_owner_by_invite == nil do g_simple_party_owner_by_invite = make(map[string]string)
	if g_simple_client_id_by_user_id == nil do g_simple_client_id_by_user_id = make(map[string]int)
	if g_simple_steam_lobby_by_party_scene == nil do g_simple_steam_lobby_by_party_scene = make(map[string]u64)
	if g_simple_steam_lobby_by_invite == nil do g_simple_steam_lobby_by_invite = make(map[string]u64)
	if g_simple_party_join_announced == nil do g_simple_party_join_announced = make(map[string]bool)
	if g_simple_party_join_ready_announced == nil do g_simple_party_join_ready_announced = make(map[string]bool)
	if len(g_server_state) == 0 do append(&g_server_state, Simple_Server_State{})
}

simple_net_client_id :: proc(remote: net.Endpoint) -> (client_id: int, is_new: bool) {
	if id, ok := client_list[remote]; ok do return id, false
	client_id = len(g_server_state)
	is_new = true
	client_list[remote] = client_id
	append(&g_server_state, Simple_Server_State {
		remote = remote,
	})
	return
}

simple_scene_infos_load :: proc(allocator: mem.Allocator) -> Error {
	g_simple_scene_infos = Predict_Caleb_Scene_Infos {
		authenticator = os.read_entire_file_from_path("src/scenes/authenticator.infos.bin", allocator) or_return,
		friends       = os.read_entire_file_from_path("src/scenes/friends.infos.bin", allocator) or_return,
		party_manager = os.read_entire_file_from_path("src/scenes/party-manager.infos.bin", allocator) or_return,
		party         = os.read_entire_file_from_path("src/scenes/party.infos.bin", allocator) or_return,
		matchmaking   = os.read_entire_file_from_path("src/scenes/matchmaking.infos.bin", allocator) or_return,
		gamesession   = os.read_entire_file_from_path("src/scenes/gamesession.infos.bin", allocator) or_return,
	}
	steam_friends_bytes := os.read_entire_file_from_path("src/steam_friends.json", allocator) or_return
	g_simple_steam_friends_text = string(steam_friends_bytes)
	raknet_samples_bytes := os.read_entire_file_from_path("src/raknet_samples.json", allocator) or_return
	g_simple_raknet_samples_text = string(raknet_samples_bytes)
	steam_user_id_bytes := os.read_entire_file_from_path("src/steam_user_ids.json", allocator) or_return
	g_simple_user_ids_by_steam = make(map[string]string, allocator)
	if json.unmarshal_string(string(steam_user_id_bytes), &g_simple_user_ids_by_steam, allocator = allocator) != nil {
		fmt.eprintfln("simple_net: failed to parse src/steam_user_ids.json")
	}
	simple_friends_rebuild(allocator)
	return nil
}

