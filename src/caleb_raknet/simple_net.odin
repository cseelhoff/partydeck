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
import "core:strings"
import "core:sys/posix"
import "core:time"

SIMPLE_DEFAULT_RAKNET_ENDPOINT :: "10.1.1.129:30100"
SIMPLE_DEFAULT_DTLIVE_PORT :: 8080
SIMPLE_DEFAULT_PREDICT_FILE :: "/tmp/pdlog/probe/simple_predict.json"
SIMPLE_POLL_TIMEOUT_MS :: 1000
SIMPLE_MAX_RESPONSES :: 12

Poll_Slot :: enum int {
	UDP,
	HTTP,
}

Simple_Server_State :: struct {
	remote:                      net.Endpoint,
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
	identity_label:              string,
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
	game_version_update:         GameVersion_Update_Body,
	gamefinder_update:           Gamefinder_Update_Body,
	locator_get_scene_token:     Locator_GetSceneConnectionToken_Body,
	party_create_invitation:     Party_CreateInvitationCode_Body,
	party_get_party_state2:      Party_GetPartyState2_Body,
	party_member_connected:      Party_MemberConnected_Body,
	party_member_data_updated:   Party_MemberDataUpdated_Body,
	party_member_disconnected:   Party_MemberDisconnected_Body,
	party_member_status_updated: Party_MemberStatusUpdated_Body,
	party_settings_updated:      Party_SettingsUpdated_Body,
	party_update_gf_status:      Party_UpdateGameFinderPlayerStatus_Body,
	party_update_settings:       Party_UpdatePartySettings_Body,
	party_update_user_data2:     Party_UpdatePartyUserData2_Body,
	party_conn_token_from_code:  PartyManagement_CreateConnectionTokenFromInvitationCode_Body,
	party_create_session:        PartyManagement_CreateSession_Body,
	party_merging_status:        PartyMerging_GetMergerStatus_Body,
	player_update:               Player_Update_Body,
	steam_create_lobby:          Steam_CreateLobby_Body,
	steam_join_lobby:            Steam_JoinLobby_Body,
	steam_update_joinable:       Steam_UpdateLobbyJoinable_Body,
	user_session_update_options: UserSession_UpdateUserOptions_Body,
}

client_list: map[net.Endpoint]int
g_server_state: [dynamic]Simple_Server_State
g_simple_scene_infos: Predict_Caleb_Scene_Infos
g_simple_steam_friends_text: string
g_simple_user_ids_by_steam: map[string]string

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
	encoded_messages := filter_health_messages(reassemble_side(peer_state, .C2S, {data}, scratch), scratch)
	if len(encoded_messages) == 0 do return

	decoded_messages: [dynamic]Decoded_Message
	response_messages: [dynamic]Decoded_Message
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

	simple_server_state := &g_server_state[client_id]
	for decoded in decoded_messages {
		simple_apply_decoded_message(client_id, label, decoded, verbose, simple_server_state)
		partial_response_messages := simple_dispatch_decoded_message(
			client_id,
			label,
			decoded,
			verbose,
			simple_server_state,
		)
		for response_message in partial_response_messages do append(&response_messages, response_message)
	}

	for response_message in response_messages {
		route_registry_observe(&peer_state.reg_real, peer_state.ep_real, response_message, scratch)
		simple_apply_decoded_message(client_id, label, response_message, verbose, simple_server_state)
	}
	if len(response_messages) > 0 {
		live_send_decoded_messages(sock, wire, remote, response_messages[:], scratch)
	}
	simple_write_prediction_record(
		simple_predict_log,
		simple_predict_path,
		label,
		peer_state,
		encoded_messages,
		response_messages[:],
	)
	if verbose {
		fmt.printfln(
			"simple %s c2s_msgs=%d pred_msgs=%d",
			label,
			len(encoded_messages),
			len(response_messages),
		)
	}
}

simple_net_globals_init :: proc() {
	if client_list == nil do client_list = make(map[net.Endpoint]int)
	if g_server_state == nil do g_server_state = make([dynamic]Simple_Server_State)
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
	steam_user_id_bytes := os.read_entire_file_from_path("src/steam_user_ids.json", allocator) or_return
	g_simple_user_ids_by_steam = make(map[string]string, allocator)
	if json.unmarshal_string(string(steam_user_id_bytes), &g_simple_user_ids_by_steam, allocator = allocator) != nil {
		fmt.eprintfln("simple_net: failed to parse src/steam_user_ids.json")
	}
	return nil
}

simple_net_stub :: proc(label, name: string, verbose: bool) {
	if verbose do fmt.printfln("simple %s -> %s", label, name)
}

simple_write_prediction_record :: proc(
	out: ^strings.Builder,
	out_path: string,
	label: string,
	ps: ^Peer_State,
	sent_msgs: [][]byte,
	preds: []Decoded_Message,
) {
	allocator := context.temp_allocator
	t, _ := time.time_to_rfc3339(time.now(), allocator = allocator)
	sent_human := render_burst(&ps.reg_real, ps.ep_client, sent_msgs, allocator)
	pred_human := render_decoded_burst(&ps.reg_pred, ps.ep_pred, preds, allocator)
	pred_bytes := encode_decoded_messages(preds, allocator)
	real_bytes := make([dynamic][]byte, allocator)
	sync_write_record(
		out,
		t,
		label,
		false,
		sent_msgs,
		real_bytes[:],
		pred_bytes,
		sent_human,
		"",
		pred_human,
	)
	sync_write_out(out_path, strings.to_string(out^))
	free_all(allocator)
}

simple_scene_message :: proc(
	scene_handle: u8,
	route_handle: u16,
	body: []byte,
	allocator := context.allocator,
) -> Decoded_Message {
	msg := make([dynamic]byte, allocator)
	append(&msg, scene_handle)
	write_u16_le(&msg, route_handle)
	append(&msg, ..body)
	return decode_message(msg[:], allocator)
}

simple_response_msg :: proc(req_id: u16, raw: []byte, allocator := context.allocator) -> Decoded_Message {
	msg := make([dynamic]byte, allocator)
	append(&msg, u8(Message_Id.Response_Msg))
	write_u16_le(&msg, req_id)
	append(&msg, ..raw)
	return decode_message(msg[:], allocator)
}

simple_response_complete :: proc(
	req_id: u16,
	has_values: bool,
	allocator := context.allocator,
) -> Decoded_Message {
	msg := make([dynamic]byte, allocator)
	append(&msg, u8(Message_Id.Response_Complete))
	write_u16_le(&msg, req_id)
	append(&msg, has_values ? 1 : 0)
	return decode_message(msg[:], allocator)
}

simple_bool_response_msg :: proc(
	req_id: u16,
	value: bool,
	allocator := context.allocator,
) -> Decoded_Message {
	raw := mpe_map({mpe_str("v", allocator), mpe_bool(value, allocator)}, allocator)
	return simple_response_msg(req_id, raw, allocator)
}

simple_session_token_response_msg :: proc(req_id: u16, allocator := context.allocator) -> Decoded_Message {
	jwt := "eyJhbGciOiJub25lIiwidHlwIjoiSldUIiwiY2x1c3RlcklkIjoicGFzc3RlY2gtbGl2ZSJ9.eyJTdG9ybWFuY2VyL3Nlc3Npb25JZCI6ImJYMkZOMVdhS1Vxb3VCY2JVNTlWbVEiLCJuYmYiOjE3ODA1MzcyMTIsImV4cCI6MTc4MDYyMzYxMiwiaWF0IjoxNzgwNTM3MjEyLCJpc3MiOiJwYXNzdGVjaC1saXZlIn0."
	sid := "bX2FN1WaKUqouBcbU59VmQ"
	raw := mpe_concat(mpe_str(jwt, allocator), mpe_str(sid, allocator), allocator = allocator)
	return simple_response_msg(req_id, raw, allocator)
}

simple_ping_response_msg :: proc(
	req_id: u16,
	echo_clock: u64,
	allocator := context.allocator,
) -> Decoded_Message {
	raw := make([dynamic]byte, allocator)
	write_u64_le(&raw, server_time_ms())
	write_u64_le(&raw, echo_clock)
	return simple_response_msg(req_id, raw[:], allocator)
}

simple_rpc_next_message :: proc(
	scene_handle: u8,
	route_handle: u16,
	rpc_id: u16,
	result: []byte,
	allocator := context.allocator,
) -> Decoded_Message {
	body := make([dynamic]byte, allocator)
	write_u16_le(&body, rpc_id)
	append(&body, ..result)
	return simple_scene_message(scene_handle, route_handle, body[:], allocator)
}

simple_rpc_completed_message :: proc(
	scene_handle: u8,
	route_handle: u16,
	rpc_id: u16,
	message_sent: bool,
	allocator := context.allocator,
) -> Decoded_Message {
	body := make([dynamic]byte, allocator)
	append(&body, message_sent ? 1 : 0)
	write_u16_le(&body, rpc_id)
	return simple_scene_message(scene_handle, route_handle, body[:], allocator)
}

simple_append_rpc_response :: proc(
	messages: ^[dynamic; SIMPLE_MAX_RESPONSES]Decoded_Message,
	scene_handle: u8,
	rpc_next_route: u16,
	rpc_completed_route: u16,
	rpc_id: u16,
	result: []byte,
	allocator := context.allocator,
) {
	if rpc_next_route != 0 {
		append(
			messages,
			simple_rpc_next_message(scene_handle, rpc_next_route, rpc_id, result, allocator),
		)
	}
	if rpc_completed_route != 0 {
		append(
			messages,
			simple_rpc_completed_message(scene_handle, rpc_completed_route, rpc_id, true, allocator),
		)
	}
}

simple_append_rpc_complete :: proc(
	messages: ^[dynamic; SIMPLE_MAX_RESPONSES]Decoded_Message,
	scene_handle: u8,
	rpc_completed_route: u16,
	rpc_id: u16,
	message_sent: bool,
	allocator := context.allocator,
) {
	if rpc_completed_route == 0 do return
	append(
		messages,
		simple_rpc_completed_message(scene_handle, rpc_completed_route, rpc_id, message_sent, allocator),
	)
}

simple_scene_token_response_for_suffix :: proc(scene_suffix: string, allocator := context.allocator) -> []byte {
	raknet_endpoint := env_string("RAKNET_ENDPOINT", SIMPLE_DEFAULT_RAKNET_ENDPOINT, allocator)
	return mpe_str(scene_token_json_endpoint(scene_suffix, raknet_endpoint, allocator), allocator)
}

simple_party_scene_for_invite :: proc(invitation_code, fallback_label: string) -> string {
	if invitation_code == invite_code_for_peer("C1") do return party_scene_for_peer("C1")
	if invitation_code == invite_code_for_peer("C2") do return party_scene_for_peer("C2")
	return party_scene_for_peer(fallback_label)
}

simple_identity_label :: proc(simple_server_state: ^Simple_Server_State, fallback_label: string) -> string {
	if simple_server_state.identity_label != "" do return simple_server_state.identity_label
	return fallback_label
}

simple_party_userdata_json :: proc(
	simple_server_state: ^Simple_Server_State,
	identity: string,
	initialized: bool,
	lobby_state: int,
) -> string {
	if simple_server_state.party_update_user_data2.userdata_json != "" {
		return simple_server_state.party_update_user_data2.userdata_json
	}
	if simple_server_state.party_create_session.userdata_json != "" {
		return simple_server_state.party_create_session.userdata_json
	}
	return party_userdata_json(identity, initialized, lobby_state, 3)
}

get_route_from_handle :: proc(
	simple_server_state: ^Simple_Server_State,
	scene_handle: u64,
    route_name_query: string,
) -> u16 {
	if scene_handle < u64(SCENE_HANDLE_MIN) do return 0
	scene_index := int(scene_handle - u64(SCENE_HANDLE_MIN))
	if scene_index < 0 || scene_index >= len(simple_server_state.scene_connection_result.scenes) {
		return 0
	}

	scene := simple_server_state.scene_connection_result.scenes[scene_index]
	for route_name, route_index in scene.routes {
		if route_name == route_name_query do return u16(route_index + 1)
	}
	return 0
}

steam_id_from_login_ticket :: proc(ticket: string, allocator := context.allocator) -> string {
	data, ok := hex.decode(transmute([]byte)ticket, allocator)
	if !ok || len(data) < 20 do return ""
	defer delete(data, allocator)
	return fmt.aprintf("%d", read_u64_le(data, 12), allocator = allocator)
}

simple_apply_decoded_message :: proc(
	client_id: int,
	label: string,
	message: Decoded_Message,
	verbose: bool,
	simple_server_state: ^Simple_Server_State,
) {
	switch m in message {
	case Connected_Ping:
		simple_server_state.connected_ping = m
		simple_net_stub(label, "Connected_Ping", verbose)
	case Connected_Pong:
		simple_server_state.connected_pong = m
		simple_net_stub(label, "Connected_Pong", verbose)
	case Connection_Request:
		simple_server_state.connection_request = m
		simple_net_stub(label, "Connection_Request", verbose)
	case Connection_Request_Accepted:
		simple_server_state.connection_request_accepted = m
		simple_net_stub(label, "Connection_Request_Accepted", verbose)
	case New_Incoming_Connection:
		simple_server_state.new_incoming_connection = m
		simple_net_stub(label, "New_Incoming_Connection", verbose)
	case Disconnection_Notification:
		simple_server_state.disconnection_notification = m
		simple_net_stub(label, "Disconnection_Notification", verbose)
	case System_Request:
		simple_server_state.system_request = m
		simple_apply_system_request(client_id, label, m, verbose, simple_server_state)
	case Response_Msg:
		simple_server_state.response_msg = m
		simple_dispatch_response_msg(client_id, label, m, verbose, simple_server_state)
	case Response_Complete:
		simple_server_state.response_complete = m
		simple_net_stub(label, "Response_Complete", verbose)
	case Response_Error:
		simple_server_state.response_error = m
		simple_net_stub(label, "Response_Error", verbose)
	case Connection_Result:
		simple_server_state.connection_result = m
		simple_net_stub(label, "Connection_Result", verbose)
	case Scene_Message:
		simple_server_state.scene_message = m
		simple_net_stub(label, "Scene_Message", verbose)
	case Malformed_Message:
		simple_server_state.malformed_message = m
		simple_net_stub(label, "Malformed_Message", verbose)
	case Unknown_Message:
		simple_server_state.unknown_message = m
		simple_net_stub(label, "Unknown_Message", verbose)
	}
}

simple_apply_system_request :: proc(
	client_id: int,
	label: string,
	message: System_Request,
	verbose: bool,
	simple_server_state: ^Simple_Server_State,
) -> (
	response_messages: [dynamic; SIMPLE_MAX_RESPONSES]Decoded_Message,
){
	switch args in message.args {
	case Connect_To_Scene_Args:
//   "sent_human_readable": "System_Request msg_id=Connect_To_Scene req=7 args=Connect token=449B routes=[stormancer.rpc.completed#0, stormancer.rpc.next#0, gameVersion.update#0, stormancer.rpc.cancel#0, sendRequest#0, stormancer.rpc.error#0, serverVersion.update#0, users.renewCredentials#0] scene_meta={stormancer.plugins.rpc=\"1.1.0\", stormancer.plugins.nintendo=\"enabled\", Stormancer.plugins.XBLServices.useModernGamerTag=\"false\", stormancer.plugins.steam=\"4.2.1.42\", appId=\"live-1-05-00\", accountId=\"darktales\", stormancer.gameVersion=\"default\", stormancer.plugins.psn=\"202006171\"} conn_meta={stormancer.party=\"2022-06-09.1\", version=\"\", server.name=\"dt-live-1\", timeout=\"5000\", server.version=\"9.3.0.2\", stormancer.party.plugin=\"2020-08-21.1\", stormancer.partymanagement=\"2020-05-20.1\", stormancer.plugins.gamefinder.protocol=\"202006091\", plugins=\"RPC(1.0.0); Users(1.0.0); Party(2020-08-21.1); PartyMerging(1.0.0); GameFinder(202006091); GameSession(1.0.0); GameVersion(1.0.0); Friends(2.0.0); PlayerReports(1.0.0); DarkTales.GameSessions(1.0.0); Steam(1.0.0)\", serializers=\"msgpack/array\", transport=\"raknet\", platform=\"Win64\", protocol=\"4\", type=\"server\", serializer=\"msgpack/array\"}",
//   "real_human_readable": "Response_Msg req=7 data=Scene_Connection_Result handle=141 routes=[stormancer.rpc.completed#1, stormancer.rpc.next#2, gameVersion.update#3, stormancer.rpc.cancel#4, sendRequest#5, stormancer.rpc.error#6, serverVersion.update#7, users.renewCredentials#8] | Response_Complete req=7 has_values=true",
 
		simple_server_state.connect_to_scene_args = args
        simple_server_state
		append(&response_messages, Response_Msg {
            req_id = message.req_id,
            data = Scene_Connection_Result {
                handle = 141,
                routes = args.routes,
            },
        })
	case Get_Scene_Infos_Args:
		simple_server_state.get_scene_infos_args = args
		simple_net_stub(label, "System_Request.Get_Scene_Infos", verbose)
	case Set_Metadata_Args:
		simple_server_state.set_metadata_args = args
		simple_net_stub(label, "System_Request.Set_Metadata", verbose)
	case Scene_Ready_Args:
		was_sent := simple_server_state.scene_ready_args.sent_game_version_update
		simple_server_state.scene_ready_args = args
		simple_server_state.scene_ready_args.sent_game_version_update = was_sent
		simple_server_state.scene_message.scene_handle = u8(args.scene_handle)
		simple_net_stub(label, "System_Request.Scene_Ready", verbose)
	case Disconnect_From_Scene_Args:
		simple_server_state.disconnect_from_scene_args = args
		simple_net_stub(label, "System_Request.Disconnect_From_Scene", verbose)
	case Ping_Args:
		simple_server_state.ping_args = args
		simple_net_stub(label, "System_Request.Ping", verbose)
	case No_Args:
		simple_server_state.no_args = args
		simple_net_stub(label, "System_Request.No_Args", verbose)
	case Unparsed_Args:
		simple_server_state.unparsed_args = args
		simple_net_stub(label, "System_Request.Unparsed_Args", verbose)
	}
}

simple_dispatch_decoded_message :: proc(
	client_id: int,
	label: string,
	message: Decoded_Message,
	verbose: bool,
	simple_server_state: ^Simple_Server_State,
) -> (
	response_messages: [dynamic; SIMPLE_MAX_RESPONSES]Decoded_Message,
) {
	switch m in message {
	case Connected_Ping:
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Connected_Ping", verbose)
	case Connected_Pong:
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Connected_Pong", verbose)
	case Connection_Request:
		// predict_caleb sent_human_readable t=2026-06-06T01:03:47.962577337Z line=  "sent_human_readable": "Connection_Request guid=0dd000327154492d time=216649998 sec=false",
		response := Connection_Request_Accepted {
			remote = system_address_from_endpoint(simple_server_state.remote),
			system_index = simple_server_state.connection_request_accepted.system_index + 1,
			internal = [MAX_INTERNAL_IDS]System_Address {
				0 = System_Address{version = 4, ip = {127, 0, 0, 1}, port = SERVER_PORT},
			},
			internal_count = 1,
			echo_time = m.time,
			server_time = server_time_ms(),
		}
		append(&response_messages, Decoded_Message(response))
	case Connection_Request_Accepted:
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Connection_Request_Accepted", verbose)
	case New_Incoming_Connection:
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "New_Incoming_Connection", verbose)
	case Disconnection_Notification:
		// predict_caleb sent_human_readable t=2026-06-06T01:04:55.599718695Z line=  "sent_human_readable": "Disconnection_Notification",
		simple_net_stub(label, "Disconnection_Notification", verbose)
	case System_Request:
		// predict_caleb sent_human_readable t=2026-06-06T01:03:49.582001573Z line=  "sent_human_readable": "System_Request msg_id=Get_Session_Token req=1 args=(none)",
		return get_system_request_response(client_id, label, m, verbose, simple_server_state)
	case Response_Msg:
		simple_net_stub(label, "Response_Msg", verbose)
		// predict_caleb sent_human_readable: not found in sent_human_readable
	case Response_Complete:
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Response_Complete", verbose)
	case Response_Error:
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Response_Error", verbose)
	case Connection_Result:
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Connection_Result", verbose)
	case Scene_Message:
		// predict_caleb sent_human_readable t=2026-06-06T01:03:54.547386728Z line=  "sent_human_readable": "Scene_Message handle=141 route=6(Authentication.Login) rpc=1 [[\"steam\", {\"gameVersion.clientVersion\": \"1.05.00.05\", \"provider\": \"steam\", \"ticket\": \"140000004F316731E9C817C7BB9F0C0101001001C24E236A180000000100000005000000C7D1724E00372436898F5A0AB9000000B20000003200000004000000BB9F0C0101001001F09A1F00A7599BB88101010A00000000BC531B6A3C03376A010059C2100000000000BA6E72D9F085C7D5CD2628D22C0C0D67544C6D4C162CA664248F076E7D4D8A1CED297A86B596A9A28B2CAF53E1FC7E91B8D486F59399B96EC6C110FED6589A3B49E0846268CCC94B17B81FEAF04BB0B0DC23263FFEEA5B70A43A1FA6CC3427AF84EC70F53AFED224AE327149656DEB25CDA05E87CDF2677BA72EE53B8F905BA0\", \"version\": \"v1\", \"appId\": \"2071280\"}]]",
		return simple_dispatch_scene_message(client_id, label, m, verbose, simple_server_state)
	case Malformed_Message:
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Malformed_Message", verbose)
	case Unknown_Message:
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Unknown_Message", verbose)
	}
	return
}

get_system_request_response :: proc(
	client_id: int,
	label: string,
	message: System_Request,
	verbose: bool,
	simple_server_state: ^Simple_Server_State,
) -> (
	response_messages: [dynamic; SIMPLE_MAX_RESPONSES]Decoded_Message,
) {
	switch args in message.msg_id {
	case Set_Metadata:
		// predict_caleb sent_human_readable t=2026-06-06T01:03:52.313899701Z line=  "sent_human_readable": "System_Request msg_id=Connect_To_Scene req=7 args=Connect token=449B routes=[stormancer.rpc.completed#0, stormancer.rpc.next#0, gameVersion.update#0, stormancer.rpc.cancel#0, sendRequest#0, stormancer.rpc.error#0, serverVersion.update#0, users.renewCredentials#0] scene_meta={stormancer.plugins.rpc=\"1.1.0\", stormancer.plugins.nintendo=\"enabled\", Stormancer.plugins.XBLServices.useModernGamerTag=\"false\", stormancer.plugins.steam=\"4.2.1.42\", appId=\"live-1-05-00\", accountId=\"darktales\", stormancer.gameVersion=\"default\", stormancer.plugins.psn=\"202006171\"} conn_meta={stormancer.party=\"2022-06-09.1\", version=\"\", server.name=\"dt-live-1\", timeout=\"5000\", server.version=\"9.3.0.2\", stormancer.party.plugin=\"2020-08-21.1\", stormancer.partymanagement=\"2020-05-20.1\", stormancer.plugins.gamefinder.protocol=\"202006091\", plugins=\"RPC(1.0.0); Users(1.0.0); Party(2020-08-21.1); PartyMerging(1.0.0); GameFinder(202006091); GameSession(1.0.0); GameVersion(1.0.0); Friends(2.0.0); PlayerReports(1.0.0); DarkTales.GameSessions(1.0.0); Steam(1.0.0)\", serializers=\"msgpack/array\", transport=\"raknet\", platform=\"Win64\", protocol=\"4\", type=\"server\", serializer=\"msgpack/array\"}",
		scene_handle := u64(SCENE_HANDLE_MIN + len(simple_server_state.scene_connection_result.scenes))
		raw := build_scene_connection_result_raw(scene_handle, args.routes, context.allocator)
		append(
			&response_messages,
			simple_response_msg(message.req_id, raw),
			simple_response_complete(message.req_id, true),
		)
	case Scene_Ready:

	case Ping:
		append(&response_messages, simple_response_complete(message.req_id, false))
	case Scene_Ready_Args:
		//  "real_human_readable": "Response_Msg req=9 data=Bool_Result v=true | Scene_Message handle=141 route=3(gameVersion.update) [\"bot,1.05.*\"] | Response_Complete req=9 has_values=true | Response_Complete req=12 has_values=true",
		steam_create_lobby_route := get_route_from_handle(
			simple_server_state,
			args.scene_handle,
			"Steam.CreateLobby",
		)
		identity := simple_identity_label(simple_server_state, label)
		if steam_create_lobby_route != 0 {
			append(
				&response_messages,
				simple_scene_message(
					u8(args.scene_handle),
					steam_create_lobby_route,
					steam_create_lobby_body(identity, 1, party_scene_for_peer(identity)),
				),
			)
		}
		append(&response_messages, simple_bool_response_msg(message.req_id, true))
		if simple_server_state.scene_ready_args.sent_game_version_update == false {
			append(
				&response_messages,
				simple_scene_message(
					u8(args.scene_handle),
					get_route_from_handle(simple_server_state, args.scene_handle, "gameVersion.update"),
					mpe_str("bot,1.05.*"),
				),
			)
			simple_server_state.scene_ready_args.sent_game_version_update = true
		}
		append(&response_messages, simple_response_complete(message.req_id, true))
		if steam_create_lobby_route != 0 {
			settings_route := get_route_from_handle(
				simple_server_state,
				args.scene_handle,
				"party.settingsUpdated",
			)
			member_data_route := get_route_from_handle(
				simple_server_state,
				args.scene_handle,
				"party.memberDataUpdated",
			)
			if settings_route != 0 {
				append(
					&response_messages,
					simple_scene_message(
						u8(args.scene_handle),
						settings_route,
						party_settings_body(identity, 3, 1, ""),
					),
				)
			}
			if member_data_route != 0 {
				append(
					&response_messages,
					simple_scene_message(
						u8(args.scene_handle),
						member_data_route,
						party_memberdata_body(identity, 4, 4, false, 3),
					),
				)
			}
			if settings_route != 0 {
				append(
					&response_messages,
					simple_scene_message(
						u8(args.scene_handle),
						settings_route,
						party_settings_body(identity, 5, 3, ""),
					),
				)
			}
			if member_data_route != 0 {
				append(
					&response_messages,
					simple_scene_message(
						u8(args.scene_handle),
						member_data_route,
						party_memberdata_body(identity, 6, 6, true, 3),
					),
				)
			}
		}
	case Get_Session_Token:
// "sent_human_readable": "System_Request msg_id=Get_Session_Token req=1 args=(none)",
// "real_human_readable": "Response_Msg req=1 data=Session_Token sid=\"mK3b_FfCGU6pNfjn4w8Pxg\" jwt=JWT{header={\"alg\":\"none\",\"typ\":\"JWT\",\"clusterId\":\"passtech-live\"} payload={\"Stormancer/sessionId\":\"mK3b_FfCGU6pNfjn4w8Pxg\",\"nbf\":1780707829,\"exp\":1780794229,\"iat\":1780707829,\"iss\":\"passtech-live\"} sig=0B} | Response_Complete req=1 has_values=true",
 
		append(
			&response_messages,
			Response_Msg{
                req_id = message.req_id,
                data = Session_Token {
                    jwt = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIiwiY2x1c3RlcklkIjoicGFzc3RlY2gtbGl2ZSJ9.eyJTdG9ybWFuY2VyL3Nlc3Npb25JZCI6Im1LM2JfRmZDRVU2cE5fjn4w8PxgIiwibmJmIjoxNzgwNzA3ODI5LCJleHAiOjE3ODA3OTQyMjksImlhdCI6MTc4MDcwNzgyOSwiaXNzIjoicGFzc3RlY2gtbGl2ZSJ9.",
                    sid = "mK3b_FfCGU6pNfjn4w8Pxg",
                },
            },
            simple_response_complete(message.req_id, true),
		)
		simple_net_stub(label, "System_Request.No_Args", verbose)

	case Scene_Ready2:
		// predict_caleb sent_human_readable: not found in sent_human_readable
		append(
			&response_messages,
			simple_ping_response_msg(message.req_id, args.clock),
			simple_response_complete(message.req_id, true),
		)
		simple_net_stub(label, "System_Request.Ping", verbose)
	case Connect_To_Scene:
		// predict_caleb sent_human_readable t=2026-06-06T01:03:49.582001573Z line=  "sent_human_readable": "System_Request msg_id=Get_Session_Token req=1 args=(none)",

		return
	case Disconnect_From_Scene:
        // predict_caleb sent_human_readable t=2026-06-06T01:04:26.261603647Z line=  "sent_human_readable": "System_Request msg_id=Disconnect_From_Scene req=36 args=Disconnect handle=144",
		append(
			&response_messages,
			simple_bool_response_msg(message.req_id, true),
			simple_response_complete(message.req_id, true),
		)
		simple_net_stub(label, "System_Request.Disconnect_From_Scene", verbose)
	
	case Get_Scene_Infos:
// "sent_human_readable": "System_Request msg_id=Get_Scene_Infos req=2 args=Get_Scene_Infos token=449B metadata={stormancer.party=\"2022-06-09.1\", version=\"\", server.name=\"dt-live-1\", timeout=\"5000\", server.version=\"9.3.0.2\", stormancer.party.plugin=\"2020-08-21.1\", stormancer.partymanagement=\"2020-05-20.1\", stormancer.plugins.gamefinder.protocol=\"202006091\", plugins=\"RPC(1.0.0); Users(1.0.0); Party(2020-08-21.1); PartyMerging(1.0.0); GameFinder(202006091); GameSession(1.0.0); GameVersion(1.0.0); Friends(2.0.0); PlayerReports(1.0.0); DarkTales.GameSessions(1.0.0); Steam(1.0.0)\", serializers=\"msgpack/array\", transport=\"raknet\", platform=\"Win64\", protocol=\"4\", type=\"server\"}",
//   "real_human_readable": "Response_Msg req=2 data=Scene_Infos shard=0 scene=\"authenticator\" serializer=\"msgpack/array\" meta={stormancer.plugins.nintendo=\"enabled\", stormancer.plugins.steam=\"4.2.1.42\", stormancer.gameVersion=\"default\", stormancer.plugins.rpc=\"1.1.0\", stormancer.plugins.psn=\"202006171\", accountId=\"darktales\", appId=\"live-1-05-00\", Stormancer.plugins.XBLServices.useModernGamerTag=\"false\"} routes=[stormancer.rpc.next#0, stormancer.rpc.cancel#1, stormancer.rpc.error#2, stormancer.rpc.completed#3, Authentication.GetMetadata#4, Authentication.Register#5, Authentication.Login#6, Authentication.GetStatus#7, Authentication.Unlink#8, sendRequest#9, sceneauthorization.gettoken#10, UserSession.GetAuthenticatedUsersCountPublic#11, UserSession.CreateUserBearerToken#12, UserSession.GetUserIdFromBearerToken#13, UserSession.GetUserOptions#14, UserSession.UpdateUserOptions#15, NX.GetAdvertisedParties#16, Steam.QueryUserIds#17, Steam.DecodePartyDataBearerTokens#18, Locator.GetSceneConnectionToken#19] | Response_Complete req=2 has_values=true",
        simple_server_state.get_scene_infos_args = args
        append(
			&response_messages,
			Request_Msg{
                req_id = message.req_id,
                data = Scene_Infos {
                    shard = 0,
                    scene = "authenticator",
                    serializer = "msgpack/array",
                    stormancer_plugins_nintendo = "enabled",
                    stormancer_plugins_steam = "4.2.1.42",
                    stormancer_gameVersion = "default",
                    stormancer_plugins_rpc = "1.1.0",
                    stormancer_plugins_psn = "202006171",
                    accountId = "darktales",
                    appId = "live-1-05-00",
                    stormancer_plugins_XBLServices_useModernGamerTag = "false",
                    routes = []Scene_Route {
                        Scene_Route{name = "stormancer.rpc.next", index = 0},
                        Scene_Route{name = "stormancer.rpc.cancel", index = 1},
                        Scene_Route{name = "stormancer.rpc.error", index = 2},
                        Scene_Route{name = "stormancer.rpc.completed", index = 3},
                        Scene_Route{name = "Authentication.GetMetadata", index = 4},
                        Scene_Route{name = "Authentication.Register", index = 5},
                        Scene_Route{name = "Authentication.Login", index = 6},
                        Scene_Route{name = "Authentication.GetStatus", index = 7},
                        Scene_Route{name = "Authentication.Unlink", index = 8},
                        Scene_Route{name = "sendRequest", index = 9},
                        Scene_Route{name = "sceneauthorization.gettoken", index = 10},
                        Scene_Route{name = "UserSession.GetAuthenticatedUsersCountPublic", index = 11},
                        Scene_Route{name = "UserSession.CreateUserBearerToken", index = 12},
                        Scene_Route{name = "UserSession.GetUserIdFromBearerToken", index = 13},
                        Scene_Route{name = "UserSession.GetUserOptions", index = 14},
                        Scene_Route{name = "UserSession.UpdateUserOptions", index = 15},
                        Scene_Route{name = "NX.GetAdvertisedParties", index = 16},
                        Scene_Route{name = "Steam.QueryUserIds", index = 17},
                        Scene_Route{name = "Steam.DecodePartyDataBearerTokens", index = 18},
                        Scene_Route{name = "Locator.GetSceneConnectionToken", index = 19},
                    }
                }
            }
        )
        append(&response_messages, Response_Complete{req_id = message.req_id, has_values = true})
	return
}

simple_dispatch_response_msg :: proc(
	client_id: int,
	label: string,
	message: Response_Msg,
	verbose: bool,
	simple_server_state: ^Simple_Server_State,
) {
	switch data in message.data {
	case Scene_Infos:
		simple_server_state.scene_infos = data
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Response_Msg.Scene_Infos", verbose)
	case Scene_Connection_Result:
		simple_server_state.scene_connection_result = data
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Response_Msg.Scene_Connection_Result", verbose)
	case Bool_Result:
		simple_server_state.bool_result = data
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Response_Msg.Bool_Result", verbose)
	case Session_Token:
		simple_server_state.session_token = data
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Response_Msg.Session_Token", verbose)
	case Ping_Response:
		simple_server_state.ping_response = data
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Response_Msg.Ping_Response", verbose)
	case Other_Response:
		simple_server_state.other_response = data
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Response_Msg.Other_Response", verbose)
	}
}

simple_dispatch_scene_message :: proc(
	client_id: int,
	label: string,
	message: Scene_Message,
	verbose: bool,
	simple_server_state: ^Simple_Server_State,
) -> (
	response_messages: [dynamic; SIMPLE_MAX_RESPONSES]Decoded_Message) {
	switch body in message.body {
	case Scene_Raw_Body:
		simple_server_state.scene_raw_body = body
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Scene_Message.Scene_Raw_Body", verbose)
	case Stormancer_Rpc_Completed_Body:
		simple_server_state.stormancer_rpc_completed = body
		// predict_caleb sent_human_readable t=2026-06-06T01:04:02.935732632Z line=  "sent_human_readable": "Scene_Message handle=144 route=3(stormancer.rpc.completed) rpc=257 [0]",
		if body.rpc_id == 257 {
			identity := simple_identity_label(simple_server_state, label)
			if member_connected_route := get_route_from_handle(
				simple_server_state,
				u64(message.scene_handle),
				"party.memberConnected",
			); member_connected_route != 0 {
				append(
					&response_messages,
					simple_scene_message(
						message.scene_handle,
						member_connected_route,
						party_member_connected_body_with_userdata(
							identity,
							2,
							2,
							0,
							simple_party_userdata_json(simple_server_state, identity, false, 1),
						),
					),
				)
			}
		}
		simple_net_stub(label, "Scene_Message.Stormancer_Rpc_Completed", verbose)
	case Stormancer_Rpc_Next_Body:
		simple_server_state.stormancer_rpc_next = body
		// predict_caleb sent_human_readable t=2026-06-06T01:04:02.920778728Z line=  "sent_human_readable": "Scene_Message handle=144 route=0(stormancer.rpc.next) rpc=1 [[true, \"\", \"\", 109775243056466233]]",
		if body.rpc_id == 1 {
			identity := simple_identity_label(simple_server_state, label)
			simple_server_state.steam_lobby_id = scene_route0_lobby_id(message.decoded)
			simple_append_rpc_response(
				&response_messages,
				message.scene_handle,
				get_route_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.next"),
				get_route_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
				body.rpc_id,
				party_state_response_learned(party_scene_for_peer(identity), identity, 3),
			)
		} else if message.scene_handle >= SCENE_HANDLE_MIN + 3 {
			simple_append_rpc_complete(
				&response_messages,
				message.scene_handle,
				get_route_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
				body.rpc_id,
				false,
			)
		}
		simple_net_stub(label, "Scene_Message.Stormancer_Rpc_Next", verbose)
	case Stormancer_Rpc_Error_Body:
		simple_server_state.stormancer_rpc_error = body
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Scene_Message.Stormancer_Rpc_Error", verbose)
	case Authentication_Login_Body:
		simple_server_state.authentication_login = body
		peer := login_canonical_label_from_ticket(transmute([]byte)body.ticket)
		if len(peer) == 0 do peer = label
		steam_id := steam_id_from_login_ticket(body.ticket)
		if len(steam_id) == 0 do steam_id = party_member_steam_id_for_peer(peer)
		simple_server_state.identity_label = peer
		simple_server_state.steam_id = steam_id
		user_id := ""
		if id, ok := g_simple_user_ids_by_steam[steam_id]; ok do user_id = id
		if len(user_id) == 0 do user_id = user_id_for_peer(peer)
		steam_identity := fmt.aprintf("steam:%s", steam_id)
		login_result := mpe_array(
			{
				mpe_nil(),
				mpe_bool(true),
				mpe_str(user_id),
				mpe_str(""),
				mpe_map({mpe_str("steam"), mpe_str(steam_identity)}),
				mpe_byte(MP_EMPTY_MAP),
			},
		)
		// "Scene_Message handle=141 route=2(stormancer.rpc.next) rpc=1 [[nil, true, \"4168ffb24de245f88060d27c9580685e\", \"\", {\"steam\": \"steam:76561197977870267\"}, {}]]"
		simple_append_rpc_response(
			&response_messages,
			message.scene_handle,
			get_route_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.next"),
			get_route_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
			body.rpc_id,
			login_result,
		)
	case Friends_Subscribe_Body:
		simple_server_state.friends_subscribe = body
		// predict_caleb sent_human_readable t=2026-06-06T01:03:58.633021004Z line=  "sent_human_readable": "Scene_Message handle=142 route=5(Friends.Subscribe) rpc=1 []",
		if notification_body := captured_friend_notification(g_simple_steam_friends_text, label, 0); notification_body != nil {
			if notification_route := get_route_from_handle(
				simple_server_state,
				u64(message.scene_handle),
				"friends.notification",
			); notification_route != 0 {
				append(
					&response_messages,
					simple_scene_message(message.scene_handle, notification_route, notification_body),
				)
			}
		}
		simple_append_rpc_complete(
			&response_messages,
			message.scene_handle,
			get_route_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
			body.rpc_id,
			false,
		)
		simple_net_stub(label, "Scene_Message.Friends_Subscribe", verbose)
	case Friends_UpdateFriendList_Body:
		simple_server_state.friends_update_friend_list = body
		// predict_caleb sent_human_readable t=2026-06-06T01:03:59.745662219Z line=  "sent_human_readable": "Scene_Message handle=142 route=4(Friends.UpdateFriendList) [[[0, [[[\"steam\", \"76561197962835656\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Matt Kinsman\"},\"pseudo\":\"Matt Kinsman\"}], 123145230078164], [0, [[[\"steam\", \"76561197963463195\"]], {\"steam\": 2}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Josh\"},\"pseudo\":\"Josh\"}], 123145230078164], [0, [[[\"steam\", \"76561197965691904\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Tron\"},\"pseudo\":\"Tron\"}], 123145230078164], [0, [[[\"steam\", \"76561197970237715\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Rabid Rhino\"},\"pseudo\":\"Rabid Rhino\"}], 123145230078164], [0, [[[\"steam\", \"76561197970685477\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Gwythok\"},\"pseudo\":\"Gwythok\"}], 123145230078164], [0, [[[\"steam\", \"76561197970984788\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Brian\"},\"pseudo\":\"Brian\"}], 123145230078164], [0, [[[\"steam\", \"76561197971424039\"]], {\"steam\": 2}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Zach\"},\"pseudo\":\"Zach\"}], 123145230078164], [0, [[[\"steam\", \"76561197980757944\"]], {\"steam\": 2}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Mitch\"},\"pseudo\":\"Mitch\"}], 123145230078164], [0, [[[\"steam\", \"76561197983745634\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Ryan\"},\"pseudo\":\"Ryan\"}], 123145230078164], [0, [[[\"steam\", \"76561197984407279\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Lenny\"},\"pseudo\":\"Lenny\"}], 123145230078164], [0, [[[\"steam\", \"76561197984830921\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Chris Pruett\"},\"pseudo\":\"Chris Pruett\"}], 123145230078164], [0, [[[\"steam\", \"76561197985758551\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"JoJo\"},\"pseudo\":\"JoJo\"}], 123145230078164], [0, [[[\"steam\", \"76561197987091370\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Corey\"},\"pseudo\":\"Corey\"}], 123145230078164], [0, [[[\"steam\", \"76561197991218302\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Ataman\"},\"pseudo\":\"Ataman\"}], 123145230078164], [0, [[[\"steam\", \"76561197992107525\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Bryce\"},\"pseudo\":\"Bryce\"}], 123145230078164], [0, [[[\"steam\", \"76561197995666815\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Wai Ching\"},\"pseudo\":\"Wai Ching\"}], 123145230078164], [0, [[[\"steam\", \"76561197996333937\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Victor\"},\"pseudo\":\"Victor\"}], 123145230078164], [0, [[[\"steam\", \"76561198000855323\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Bill\"},\"pseudo\":\"Bill\"}], 123145230078164], [0, [[[\"steam\", \"76561198001131269\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Ken\"},\"pseudo\":\"Ken\"}], 123145230078164], [0, [[[\"steam\", \"76561198007310426\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"speedep\"},\"pseudo\":\"speedep\"}], 123145230078164], [0, [[[\"steam\", \"76561198007552845\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Sernior\"},\"pseudo\":\"Sernior\"}], 123145230078164], [0, [[[\"steam\", \"76561198010807042\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Omegaprime02\"},\"pseudo\":\"Omegaprime02\"}], 123145230078164], [0, [[[\"steam\", \"76561198011994934\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Nolo\"},\"pseudo\":\"Nolo\"}], 123145230078164], [0, [[[\"steam\", \"76561198014863330\"]], {\"steam\": 2}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Lmaomyasoff\"},\"pseudo\":\"Lmaomyasoff\"}], 123145230078164], [0, [[[\"steam\", \"76561198025509553\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Damon\"},\"pseudo\":\"Damon\"}], 123145230078164], [0, [[[\"steam\", \"76561198025675048\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Jacen Solo\"},\"pseudo\":\"Jacen Solo\"}], 123145230078164], [0, [[[\"steam\", \"76561198028939126\"]], {\"steam\": 2}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Derrick Kraft\"},\"pseudo\":\"Derrick Kraft\"}], 123145230078164], [0, [[[\"steam\", \"76561198030532105\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Trevor\"},\"pseudo\":\"Trevor\"}], 123145230078164], [0, [[[\"steam\", \"76561198031513313\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"The Village Guy\"},\"pseudo\":\"The Village Guy\"}], 123145230078164], [0, [[[\"steam\", \"76561198034269964\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Austin\"},\"pseudo\":\"Austin\"}], 123145230078164], [0, [[[\"steam\", \"76561198042638974\"]], {\"steam\": 2}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"nikos\"},\"pseudo\":\"nikos\"}], 123145230078164], [0, [[[\"steam\", \"76561198046852761\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Nate Miller\"},\"pseudo\":\"Nate Miller\"}], 123145230078164], [0, [[[\"steam\", \"76561198047650167\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"pgames-food\"},\"pseudo\":\"pgames-food\"}], 123145230078164], [0, [[[\"steam\", \"76561198048290490\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"willerxxmiller\"},\"pseudo\":\"willerxxmiller\"}], 123145230078164], [0, [[[\"steam\", \"76561198049745028\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Fred\"},\"pseudo\":\"Fred\"}], 123145230078164], [0, [[[\"steam\", \"76561198050937181\"]], {\"steam\": 2}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"jiseng.so\"},\"pseudo\":\"jiseng.so\"}], 123145230078164], [0, [[[\"steam\", \"76561198056389260\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Slendy\"},\"pseudo\":\"Slendy\"}], 123145230078164], [0, [[[\"steam\", \"76561198056701856\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Nippy Little Mink\"},\"pseudo\":\"Nippy Little Mink\"}], 123145230078164], [0, [[[\"steam\", \"76561198066396096\"]], {\"steam\": 2}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Tim\"},\"pseudo\":\"Tim\"}], 123145230078164], [0, [[[\"steam\", \"76561198069654342\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Tyler\"},\"pseudo\":\"Tyler\"}], 123145230078164], [0, [[[\"steam\", \"76561198070801552\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"ZerosAesyr\"},\"pseudo\":\"ZerosAesyr\"}], 123145230078164], [0, [[[\"steam\", \"76561198071731863\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"IcyBlackAgeis\"},\"pseudo\":\"IcyBlackAgeis\"}], 123145230078164], [0, [[[\"steam\", \"76561198072244509\"]], {\"steam\": 2}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Simon\"},\"pseudo\":\"Simon\"}], 123145230078164], [0, [[[\"steam\", \"76561198073007967\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"drkpuma\"},\"pseudo\":\"drkpuma\"}], 123145230078164], [0, [[[\"steam\", \"76561198073009947\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"EwokFetus\"},\"pseudo\":\"EwokFetus\"}], 123145230078164], [0, [[[\"steam\", \"76561198073047503\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"enew34\"},\"pseudo\":\"enew34\"}], 123145230078164], [0, [[[\"steam\", \"76561198080150801\"]], {\"steam\": 2}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Ryan\"},\"pseudo\":\"Ryan\"}], 123145230078164], [0, [[[\"steam\", \"76561198081744625\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Nate Peterson\"},\"pseudo\":\"Nate Peterson\"}], 123145230078164], [0, [[[\"steam\", \"76561198081780510\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Kyle\"},\"pseudo\":\"Kyle\"}], 123145230078164], [0, [[[\"steam\", \"76561198081812692\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"MPruett\"},\"pseudo\":\"MPruett\"}], 123145230078164], [0, [[[\"steam\", \"76561198082331798\"]], {\"steam\": 2}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Pandemic\"},\"pseudo\":\"Pandemic\"}], 123145230078164], [0, [[[\"steam\", \"76561198087479767\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"A name\"},\"pseudo\":\"A name\"}], 123145230078164], [0, [[[\"steam\", \"76561198091544713\"]], {\"steam\": 2}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"ShamusOReilly\"},\"pseudo\":\"ShamusOReilly\"}], 123145230078164], [0, [[[\"steam\", \"76561198094195713\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"yek\"},\"pseudo\":\"yek\"}], 123145230078164], [0, [[[\"steam\", \"76561198114275468\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Phat Lance\"},\"pseudo\":\"Phat Lance\"}], 123145230078164], [0, [[[\"steam\", \"76561198119289517\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Chuck\"},\"pseudo\":\"Chuck\"}], 123145230078164], [0, [[[\"steam\", \"76561198139991405\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Centurion011G\"},\"pseudo\":\"Centurion011G\"}], 123145230078164], [0, [[[\"steam\", \"76561198144588203\"]], {\"steam\": 2}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Lenin's Cat\"},\"pseudo\":\"Lenin's Cat\"}], 123145230078164], [0, [[[\"steam\", \"76561198206038412\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Rachael Mae\"},\"pseudo\":\"Rachael Mae\"}], 123145230078164], [0, [[[\"steam\", \"76561198208933207\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"erst24\"},\"pseudo\":\"erst24\"}], 123145230078164], [0, [[[\"steam\", \"76561198215440589\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Stephen\"},\"pseudo\":\"Stephen\"}], 123145230078164], [0, [[[\"steam\", \"76561198240994238\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"emilyerstad\"},\"pseudo\":\"emilyerstad\"}], 123145230078164], [0, [[[\"steam\", \"76561198240996126\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"day\"},\"pseudo\":\"day\"}], 123145230078164], [0, [[[\"steam\", \"76561198241063678\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"eric.j.vanbruggen\"},\"pseudo\":\"eric.j.vanbruggen\"}], 123145230078164], [0, [[[\"steam\", \"76561198800616087\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"DEMOTED\"},\"pseudo\":\"DEMOTED\"}], 123145230078164], [0, [[[\"steam\", \"76561198805460425\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"jpuff\"},\"pseudo\":\"jpuff\"}], 123145230078164], [0, [[[\"steam\", \"76561198812454773\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Jonathan\"},\"pseudo\":\"Jonathan\"}], 123145230078164], [0, [[[\"steam\", \"76561199037460582\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"LatinoHeatNCU5W\"},\"pseudo\":\"LatinoHeatNCU5W\"}], 123145230078164], [0, [[[\"steam\", \"76561199050487318\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Paul\"},\"pseudo\":\"Paul\"}], 123145230078164], [0, [[[\"steam\", \"76561199495854608\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"deadmeme92\"},\"pseudo\":\"deadmeme92\"}], 123145230078164], [0, [[[\"steam\", \"76561199572083022\"]], {\"steam\": 2}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"elsie\"},\"pseudo\":\"elsie\"}], 123145230078164], [0, [[[\"steam\", \"76561199659479288\"]], {\"steam\": 0}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Patrick Stoeffel\"},\"pseudo\":\"Patrick Stoeffel\"}], 123145230078164]]]",
		simple_net_stub(label, "Scene_Message.Friends_UpdateFriendList", verbose)
	case Friends_Notification_Body:
		simple_server_state.friends_notification = body
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Scene_Message.Friends_Notification", verbose)
	case GameSession_GetP2PToken_Body:
		simple_server_state.gamesession_get_p2p_token = body
		// predict_caleb sent_human_readable t=2026-06-06T01:04:42.626194203Z line=  "sent_human_readable": "Scene_Message handle=148 route=8(GameSession.GetP2PToken) rpc=1 [1]",
		simple_net_stub(label, "Scene_Message.GameSession_GetP2PToken", verbose)
	case GameVersion_Update_Body:
		simple_server_state.game_version_update = body
		simple_server_state.scene_ready_args.sent_game_version_update = true
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Scene_Message.GameVersion_Update", verbose)
	case Gamefinder_Update_Body:
		simple_server_state.gamefinder_update = body
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Scene_Message.Gamefinder_Update", verbose)
	case Locator_GetSceneConnectionToken_Body:
		simple_server_state.locator_get_scene_token = body
		// predict_caleb sent_human_readable t=2026-06-06T01:03:55.897566898Z line=  "sent_human_readable": "Scene_Message handle=141 route=19(Locator.GetSceneConnectionToken) rpc=2 [\"stormancer.friends\", \"\"] | Scene_Message handle=141 route=19(Locator.GetSceneConnectionToken) rpc=3 [\"stormancer.plugins.partyManagement\", \"\"] | Scene_Message handle=141 route=15(UserSession.UpdateUserOptions) rpc=4 [\"crossplay\", {\"enabled\": true}]",
		suffix := scene_suffix_for_service(body.scene_type, body.scene_id)
		simple_append_rpc_response(
			&response_messages,
			message.scene_handle,
			get_route_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.next"),
			get_route_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
			body.rpc_id,
			simple_scene_token_response_for_suffix(suffix),
		)
		simple_net_stub(label, "Scene_Message.Locator_GetSceneConnectionToken", verbose)
	case Party_CreateInvitationCode_Body:
		simple_server_state.party_create_invitation = body
		// predict_caleb sent_human_readable t=2026-06-06T01:04:05.82094369Z line=  "sent_human_readable": "Scene_Message handle=144 route=13(Party.CreateInvitationCode) rpc=4 []",
		simple_append_rpc_response(
			&response_messages,
			message.scene_handle,
			get_route_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.next"),
			get_route_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
			body.rpc_id,
			mpe_str(invite_code_for_peer(simple_identity_label(simple_server_state, label))),
		)
		simple_net_stub(label, "Scene_Message.Party_CreateInvitationCode", verbose)
	case Party_GetPartyState2_Body:
		simple_server_state.party_get_party_state2 = body
		// predict_caleb sent_human_readable t=2026-06-06T01:04:03.832602873Z line=  "sent_human_readable": "Scene_Message handle=144 route=11(party.getpartystate2) rpc=1 [] | Scene_Message handle=144 route=3(stormancer.rpc.completed) rpc=512 [0]",
		simple_append_rpc_response(
			&response_messages,
			message.scene_handle,
			get_route_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.next"),
			get_route_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
			body.rpc_id,
			party_state_response_learned(
				party_scene_for_peer(simple_identity_label(simple_server_state, label)),
				simple_identity_label(simple_server_state, label),
				3,
			),
		)
		simple_net_stub(label, "Scene_Message.Party_GetPartyState2", verbose)
	case Party_MemberConnected_Body:
		simple_server_state.party_member_connected = body
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Scene_Message.Party_MemberConnected", verbose)
	case Party_MemberDataUpdated_Body:
		simple_server_state.party_member_data_updated = body
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Scene_Message.Party_MemberDataUpdated", verbose)
	case Party_MemberDisconnected_Body:
		simple_server_state.party_member_disconnected = body
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Scene_Message.Party_MemberDisconnected", verbose)
	case Party_MemberStatusUpdated_Body:
		simple_server_state.party_member_status_updated = body
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Scene_Message.Party_MemberStatusUpdated", verbose)
	case Party_SettingsUpdated_Body:
		simple_server_state.party_settings_updated = body
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Scene_Message.Party_SettingsUpdated", verbose)
	case Party_UpdateGameFinderPlayerStatus_Body:
		simple_server_state.party_update_gf_status = body
		// predict_caleb sent_human_readable t=2026-06-06T01:04:36.733189817Z line=  "sent_human_readable": "Scene_Message handle=146 route=9(party.updategamefinderplayerstatus) rpc=4 [[1, 5]]",
		simple_append_rpc_complete(
			&response_messages,
			message.scene_handle,
			get_route_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
			body.rpc_id,
			false,
		)
		simple_net_stub(label, "Scene_Message.Party_UpdateGameFinderPlayerStatus", verbose)
	case Party_UpdatePartySettings_Body:
		simple_server_state.party_update_settings = body
		// predict_caleb sent_human_readable t=2026-06-06T01:04:05.780613393Z line=  "sent_human_readable": "Scene_Message handle=144 route=6(Party.UpdatePartyUserData2) rpc=2 [json:{\"RequestedHero\":3,\"RequestedSkin\":0,\"InLobby\":true,\"PlayerName\":\"Major Hoff\",\"LobbyState\":1,\"UnlockedGameDifficulty\":0,\"MemberDataInitialized\":false,\"UnlockedHeroFlag\":31,\"m_sEosUserId\":\"0002ea2c70fa4f89a5d876065a55c786\",\"m_sSteamUserId\":76561197977870267,\"m_uVoiceChatMode\":0,\"m_ePlatform\":2,\"RandomSkinIndex\":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}, [[\"steam\", \"4168ffb24de245f88060d27c9580685e\", \"anonymous\", \"76561197977870267\", \"\", 0]]] | Scene_Message handle=144 route=4(party.updatepartysettings) rpc=3 [[\"matchmaking\", json:{\"InvitationCode\":\"\",\"GameMode\":0,\"GameDifficulty\":0,\"GameModifiers\":[],\"MergerDifficulty\":0}, true, true, \"\", \"\"]]",
		simple_append_rpc_complete(
			&response_messages,
			message.scene_handle,
			get_route_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
			body.rpc_id,
			false,
		)
		simple_net_stub(label, "Scene_Message.Party_UpdatePartySettings", verbose)
	case Party_UpdatePartyUserData2_Body:
		simple_server_state.party_update_user_data2 = body
		// predict_caleb sent_human_readable t=2026-06-06T01:04:05.780613393Z line=  "sent_human_readable": "Scene_Message handle=144 route=6(Party.UpdatePartyUserData2) rpc=2 [json:{\"RequestedHero\":3,\"RequestedSkin\":0,\"InLobby\":true,\"PlayerName\":\"Major Hoff\",\"LobbyState\":1,\"UnlockedGameDifficulty\":0,\"MemberDataInitialized\":false,\"UnlockedHeroFlag\":31,\"m_sEosUserId\":\"0002ea2c70fa4f89a5d876065a55c786\",\"m_sSteamUserId\":76561197977870267,\"m_uVoiceChatMode\":0,\"m_ePlatform\":2,\"RandomSkinIndex\":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}, [[\"steam\", \"4168ffb24de245f88060d27c9580685e\", \"anonymous\", \"76561197977870267\", \"\", 0]]] | Scene_Message handle=144 route=4(party.updatepartysettings) rpc=3 [[\"matchmaking\", json:{\"InvitationCode\":\"\",\"GameMode\":0,\"GameDifficulty\":0,\"GameModifiers\":[],\"MergerDifficulty\":0}, true, true, \"\", \"\"]]",
		simple_append_rpc_complete(
			&response_messages,
			message.scene_handle,
			get_route_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
			body.rpc_id,
			false,
		)
		simple_net_stub(label, "Scene_Message.Party_UpdatePartyUserData2", verbose)
	case PartyManagement_CreateConnectionTokenFromInvitationCode_Body:
		simple_server_state.party_conn_token_from_code = body
		// predict_caleb sent_human_readable t=2026-06-06T01:04:27.270107477Z line=  "sent_human_readable": "Scene_Message handle=143 route=5(PartyManagement.CreateConnectionTokenFromInvitationCode) rpc=2 [\"923100\", json:{\"RequestedHero\":3,\"RequestedSkin\":0,\"InLobby\":true,\"PlayerName\":\"Major Hoff\",\"LobbyState\":1,\"UnlockedGameDifficulty\":0,\"MemberDataInitialized\":true,\"UnlockedHeroFlag\":31,\"m_sEosUserId\":\"0002ea2c70fa4f89a5d876065a55c786\",\"m_sSteamUserId\":76561197977870267,\"m_uVoiceChatMode\":0,\"m_ePlatform\":2,\"RandomSkinIndex\":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}]",
		simple_net_stub(
			label,
			"Scene_Message.PartyManagement_CreateConnectionTokenFromInvitationCode",
			verbose,
		)
		simple_append_rpc_response(
			&response_messages,
			message.scene_handle,
			get_route_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.next"),
			get_route_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
			body.rpc_id,
			simple_scene_token_response_for_suffix(
				simple_party_scene_for_invite(
					body.invitation_code,
					simple_identity_label(simple_server_state, label),
				),
			),
		)
	case PartyManagement_CreateSession_Body:
		simple_server_state.party_create_session = body
		// predict_caleb sent_human_readable t=2026-06-06T01:03:58.819997978Z line=  "sent_human_readable": "Scene_Message handle=143 route=4(partymanagement.createsession) rpc=1 [[\"\", \"matchmaking\", \"\", {}, true, true, false, json:{\"RequestedHero\":3,\"RequestedSkin\":0,\"InLobby\":true,\"PlayerName\":\"Major Hoff\",\"LobbyState\":1,\"UnlockedGameDifficulty\":0,\"MemberDataInitialized\":false,\"UnlockedHeroFlag\":31,\"m_sEosUserId\":\"0002ea2c70fa4f89a5d876065a55c786\",\"m_sSteamUserId\":76561197977870267,\"m_uVoiceChatMode\":0,\"m_ePlatform\":2,\"RandomSkinIndex\":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}]]",
		simple_append_rpc_response(
			&response_messages,
			message.scene_handle,
			get_route_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.next"),
			get_route_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
			body.rpc_id,
			simple_scene_token_response_for_suffix(
				party_scene_for_peer(simple_identity_label(simple_server_state, label)),
			),
		)
		simple_net_stub(label, "Scene_Message.PartyManagement_CreateSession", verbose)
	case PartyMerging_GetMergerStatus_Body:
		simple_server_state.party_merging_status = body
		// predict_caleb sent_human_readable t=2026-06-06T01:04:11.383956296Z line=  "sent_human_readable": "Scene_Message handle=144 route=16(PartyMerging.GetMergerStatus) rpc=7 [\"default\"] | Scene_Message handle=144 route=4(party.updatepartysettings) rpc=8 [[\"matchmaking\", json:{\"InvitationCode\":\"448157\",\"GameMode\":0,\"GameDifficulty\":0,\"GameModifiers\":[],\"MergerDifficulty\":0}, true, true, \"\", \"\"]]",
		simple_append_rpc_response(
			&response_messages,
			message.scene_handle,
			get_route_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.next"),
			get_route_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
			body.rpc_id,
			merger_status_raw(0),
		)
		simple_net_stub(label, "Scene_Message.PartyMerging_GetMergerStatus", verbose)
	case Player_Update_Body:
		simple_server_state.player_update = body
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Scene_Message.Player_Update", verbose)
	case Steam_CreateLobby_Body:
		simple_server_state.steam_create_lobby = body
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Scene_Message.Steam_CreateLobby", verbose)
	case Steam_JoinLobby_Body:
		simple_server_state.steam_join_lobby = body
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Scene_Message.Steam_JoinLobby", verbose)
	case Steam_UpdateLobbyJoinable_Body:
		simple_server_state.steam_update_joinable = body
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Scene_Message.Steam_UpdateLobbyJoinable", verbose)
	case UserSession_UpdateUserOptions_Body:
		simple_server_state.user_session_update_options = body
		// predict_caleb sent_human_readable t=2026-06-06T01:03:55.897566898Z line=  "sent_human_readable": "Scene_Message handle=141 route=19(Locator.GetSceneConnectionToken) rpc=2 [\"stormancer.friends\", \"\"] | Scene_Message handle=141 route=19(Locator.GetSceneConnectionToken) rpc=3 [\"stormancer.plugins.partyManagement\", \"\"] | Scene_Message handle=141 route=15(UserSession.UpdateUserOptions) rpc=4 [\"crossplay\", {\"enabled\": true}]",
		simple_append_rpc_complete(
			&response_messages,
			message.scene_handle,
			get_route_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
			body.rpc_id,
			false,
		)
		simple_net_stub(label, "Scene_Message.UserSession_UpdateUserOptions", verbose)
	}
	return
}
