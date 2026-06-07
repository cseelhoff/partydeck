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
SIMPLE_POLL_TIMEOUT_MS :: 1000
SIMPLE_MAX_RESPONSES :: 12

Poll_Slot :: enum int {
	UDP,
	HTTP,
}

Simple_Server_State :: struct {
	remote:                      net.Endpoint,
    scenes:                      [dynamic; SCENE_CONNECTION_RESULT_MAX_SCENES]Routes,
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
	if len(response_messages) > 0 {
		live_send_decoded_messages(sock, wire, remote, response_messages[:], scratch)
	}

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

get_route_num_from_handle :: proc(
	simple_server_state: ^Simple_Server_State,
	scene_handle: u64,
    route_name_query: string,
) -> u16 {
    assert(scene_handle >= u64(SCENE_HANDLE_MIN))
	scene_index := scene_handle - u64(SCENE_HANDLE_MIN)

	scene := simple_server_state.scenes[scene_index]
	route_index, found := slice.linear_search(scene[:], route_name_query)
	if found {
		return u16(route_index + 1)
	}
	assert(false, "route not found")
	return 0
}

steam_id_from_login_ticket :: proc(ticket: string, allocator := context.allocator) -> string {
	data, ok := hex.decode(transmute([]byte)ticket, allocator)
	if !ok || len(data) < 20 do return ""
	defer delete(data, allocator)
	return fmt.aprintf("%d", read_u64_le(data, 12), allocator = allocator)
}

get_response_from_request :: proc(
	client_id: int,
	label: string,
	message: Decoded_Message,
	verbose: bool,
	simple_server_state: ^Simple_Server_State,
) -> (
	response_messages: [dynamic; SIMPLE_MAX_RESPONSES]Decoded_Message,
	ok: bool,
) {
	#partial switch request_message in message {
	case Connection_Request:
		// predict_caleb sent_human_readable t=2026-06-06T01:03:47.962577337Z line=  "sent_human_readable": "Connection_Request guid=0dd000327154492d time=216649998 sec=false",
        simple_server_state.connection_request = request_message
		append(&response_messages, Connection_Request_Accepted {
			remote = system_address_from_endpoint(simple_server_state.remote),
			system_index = simple_server_state.connection_request_accepted.system_index + 1,
			internal = [MAX_INTERNAL_IDS]System_Address {
				0 = System_Address{version = 4, ip = {127, 0, 0, 1}, port = SERVER_PORT},
			},
			internal_count = 1,
			echo_time = request_message.time,
			server_time = server_time_ms(),
		})
	case System_Request:
		// predict_caleb sent_human_readable t=2026-06-06T01:03:49.582001573Z line=  "sent_human_readable": "System_Request msg_id=Get_Session_Token req=1 args=(none)",
		response_messages = get_system_request_response(client_id, label, request_message, verbose, simple_server_state) or_return
	case Scene_Message:
		// predict_caleb sent_human_readable t=2026-06-06T01:03:54.547386728Z line=  "sent_human_readable": "Scene_Message handle=141 route=6(Authentication.Login) rpc=1 [[\"steam\", {\"gameVersion.clientVersion\": \"1.05.00.05\", \"provider\": \"steam\", \"ticket\": \"140000004F316731E9C817C7BB9F0C0101001001C24E236A180000000100000005000000C7D1724E00372436898F5A0AB9000000B20000003200000004000000BB9F0C0101001001F09A1F00A7599BB88101010A00000000BC531B6A3C03376A010059C2100000000000BA6E72D9F085C7D5CD2628D22C0C0D67544C6D4C162CA664248F076E7D4D8A1CED297A86B596A9A28B2CAF53E1FC7E91B8D486F59399B96EC6C110FED6589A3B49E0846268CCC94B17B81FEAF04BB0B0DC23263FFEEA5B70A43A1FA6CC3427AF84EC70F53AFED224AE327149656DEB25CDA05E87CDF2677BA72EE53B8F905BA0\", \"version\": \"v1\", \"appId\": \"2071280\"}]]",
		response_messages = get_response_from_scene_message(client_id, label, request_message, verbose, simple_server_state) or_return
    }
	ok = true
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
	ok: bool,
) {
	#partial switch message.msg_id {
	case System_Request_Id.Set_Metadata:
//  "sent": ["860005008fb073746f726d616e6365722e7061727479ac323032322d30362d30392e31a776657273696f6ea0ab7365727665722e6e616d65a964742d6c6976652d31a774696d656f7574a435303030ae7365727665722e76657273696f6ea7392e332e302e32b773746f726d616e6365722e70617274792e706c7567696eac323032302d30382d32312e31ba73746f726d616e6365722e70617274796d616e6167656d656e74ac323032302d30352d32302e31d92673746f726d616e6365722e706c7567696e732e67616d6566696e6465722e70726f746f636f6ca9323032303036303931a7706c7567696e73d9d452504328312e302e30293b20557365727328312e302e30293b20506172747928323032302d30382d32312e31293b2050617274794d657267696e6728312e302e30293b2047616d6546696e64657228323032303036303931293b2047616d6553657373696f6e28312e302e30293b2047616d6556657273696f6e28312e302e30293b20467269656e647328322e302e30293b20506c617965725265706f72747328312e302e30293b204461726b54616c65732e47616d6553657373696f6e7328312e302e30293b20537465616d28312e302e3029ab73657269616c697a657273ad6d73677061636b2f6172726179a97472616e73706f7274a672616b6e6574a8706c6174666f726da557696e3634a870726f746f636f6ca134a474797065a6736572766572aa73657269616c697a6572ad6d73677061636b2f6172726179"],
//   "sent_human_readable": "System_Request msg_id=Set_Metadata req=5 args=Set_Metadata {stormancer.party=\"2022-06-09.1\", version=\"\", server.name=\"dt-live-1\", timeout=\"5000\", server.version=\"9.3.0.2\", stormancer.party.plugin=\"2020-08-21.1\", stormancer.partymanagement=\"2020-05-20.1\", stormancer.plugins.gamefinder.protocol=\"202006091\", plugins=\"RPC(1.0.0); Users(1.0.0); Party(2020-08-21.1); PartyMerging(1.0.0); GameFinder(202006091); GameSession(1.0.0); GameVersion(1.0.0); Friends(2.0.0); PlayerReports(1.0.0); DarkTales.GameSessions(1.0.0); Steam(1.0.0)\", serializers=\"msgpack/array\", transport=\"raknet\", platform=\"Win64\", protocol=\"4\", type=\"server\", serializer=\"msgpack/array\"}",
		args := message.args.(Set_Metadata_Args) or_return
 		simple_server_state.set_metadata_args = args
		append(
			&response_messages,
			Response_Complete{
                req_id = message.req_id,
                has_values = false,
            },
		)
	case System_Request_Id.Get_Session_Token:
// "sent_human_readable": "System_Request msg_id=Get_Session_Token req=1 args=(none)",
// "real_human_readable": "Response_Msg req=1 data=Session_Token sid=\"mK3b_FfCGU6pNfjn4w8Pxg\" jwt=JWT{header={\"alg\":\"none\",\"typ\":\"JWT\",\"clusterId\":\"passtech-live\"} payload={\"Stormancer/sessionId\":\"mK3b_FfCGU6pNfjn4w8Pxg\",\"nbf\":1780707829,\"exp\":1780794229,\"iat\":1780707829,\"iss\":\"passtech-live\"} sig=0B} | Response_Complete req=1 has_values=true",
		simple_server_state.no_args = No_Args{}
        append(
			&response_messages,
			Response_Msg{
                req_id = message.req_id,
                data = Session_Token {
                    jwt = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIiwiY2x1c3RlcklkIjoicGFzc3RlY2gtbGl2ZSJ9.eyJTdG9ybWFuY2VyL3Nlc3Npb25JZCI6Im1LM2JfRmZDRVU2cE5fjn4w8PxgIiwibmJmIjoxNzgwNzA3ODI5LCJleHAiOjE3ODA3OTQyMjksImlhdCI6MTc4MDcwNzgyOSwiaXNzIjoicGFzc3RlY2gtbGl2ZSJ9.",
                    session_id = "mK3b_FfCGU6pNfjn4w8Pxg",
                },
            },
            Response_Complete{
                req_id = message.req_id,
                has_values = true,
            },
		)

	case System_Request_Id.Scene_Ready, System_Request_Id.Scene_Ready2:
//   "sent_human_readable": "System_Request msg_id=Scene_Ready2 req=9 args=Scene_Ready handle=141",
//   "real_human_readable": "Response_Msg req=9 data=Bool_Result v=true | Scene_Message handle=141 route=3(gameVersion.update) [\"bot,1.05.*\"] | Response_Complete req=9 has_values=true | Response_Complete req=12 has_values=true",
		args := message.args.(Scene_Ready_Args) or_return
		simple_server_state.scene_ready_args = args
		append(&response_messages, Response_Msg{req_id = message.req_id, data = Bool_Result{value = true}})
		if simple_server_state.scene_ready_args.sent_game_version_update == false {
			append(
				&response_messages,
				Scene_Message {
					scene_handle = u8(args.scene_handle),
					route_handle = get_route_num_from_handle(simple_server_state, args.scene_handle, "gameVersion.update"),
						body = GameVersion_Update_Body{accepted_version="bot,1.05.*"},
				},
			)
			simple_server_state.scene_ready_args.sent_game_version_update = true
		}
		append(&response_messages, Response_Complete{req_id = message.req_id, has_values = true})
	case System_Request_Id.Connect_To_Scene:
//  "sent_human_readable": "System_Request msg_id=Connect_To_Scene req=7 args=Connect token=449B routes=[stormancer.rpc.completed#0, stormancer.rpc.next#0, gameVersion.update#0, stormancer.rpc.cancel#0, sendRequest#0, stormancer.rpc.error#0, serverVersion.update#0, users.renewCredentials#0] scene_meta={stormancer.plugins.rpc=\"1.1.0\", stormancer.plugins.nintendo=\"enabled\", Stormancer.plugins.XBLServices.useModernGamerTag=\"false\", stormancer.plugins.steam=\"4.2.1.42\", appId=\"live-1-05-00\", accountId=\"darktales\", stormancer.gameVersion=\"default\", stormancer.plugins.psn=\"202006171\"} conn_meta={stormancer.party=\"2022-06-09.1\", version=\"\", server.name=\"dt-live-1\", timeout=\"5000\", server.version=\"9.3.0.2\", stormancer.party.plugin=\"2020-08-21.1\", stormancer.partymanagement=\"2020-05-20.1\", stormancer.plugins.gamefinder.protocol=\"202006091\", plugins=\"RPC(1.0.0); Users(1.0.0); Party(2020-08-21.1); PartyMerging(1.0.0); GameFinder(202006091); GameSession(1.0.0); GameVersion(1.0.0); Friends(2.0.0); PlayerReports(1.0.0); DarkTales.GameSessions(1.0.0); Steam(1.0.0)\", serializers=\"msgpack/array\", transport=\"raknet\", platform=\"Win64\", protocol=\"4\", type=\"server\", serializer=\"msgpack/array\"}",
//   "real_human_readable": "Response_Msg req=7 data=Scene_Connection_Result handle=141 routes=[stormancer.rpc.completed#1, stormancer.rpc.next#2, gameVersion.update#3, stormancer.rpc.cancel#4, sendRequest#5, stormancer.rpc.error#6, serverVersion.update#7, users.renewCredentials#8] | Response_Complete req=7 has_values=true",
		args := message.args.(Connect_To_Scene_Args) or_return
        simple_server_state.connect_to_scene_args = args

        append(&response_messages, Response_Msg {
            req_id = message.req_id,
            data = Scene_Connection_Result {
				scene_handle = u64(len(simple_server_state.scenes) + SCENE_HANDLE_MIN),
                routes = args.routes,
            },
        })
		append(&simple_server_state.scenes, args.routes)

	case System_Request_Id.Get_Scene_Infos:
// "sent_human_readable": "System_Request msg_id=Get_Scene_Infos req=2 args=Get_Scene_Infos token=449B metadata={stormancer.party=\"2022-06-09.1\", version=\"\", server.name=\"dt-live-1\", timeout=\"5000\", server.version=\"9.3.0.2\", stormancer.party.plugin=\"2020-08-21.1\", stormancer.partymanagement=\"2020-05-20.1\", stormancer.plugins.gamefinder.protocol=\"202006091\", plugins=\"RPC(1.0.0); Users(1.0.0); Party(2020-08-21.1); PartyMerging(1.0.0); GameFinder(202006091); GameSession(1.0.0); GameVersion(1.0.0); Friends(2.0.0); PlayerReports(1.0.0); DarkTales.GameSessions(1.0.0); Steam(1.0.0)\", serializers=\"msgpack/array\", transport=\"raknet\", platform=\"Win64\", protocol=\"4\", type=\"server\"}",
//   "real_human_readable": "Response_Msg req=2 data=Scene_Infos shard=0 scene=\"authenticator\" serializer=\"msgpack/array\" meta={stormancer.plugins.nintendo=\"enabled\", stormancer.plugins.steam=\"4.2.1.42\", stormancer.gameVersion=\"default\", stormancer.plugins.rpc=\"1.1.0\", stormancer.plugins.psn=\"202006171\", accountId=\"darktales\", appId=\"live-1-05-00\", Stormancer.plugins.XBLServices.useModernGamerTag=\"false\"} routes=[stormancer.rpc.next#0, stormancer.rpc.cancel#1, stormancer.rpc.error#2, stormancer.rpc.completed#3, Authentication.GetMetadata#4, Authentication.Register#5, Authentication.Login#6, Authentication.GetStatus#7, Authentication.Unlink#8, sendRequest#9, sceneauthorization.gettoken#10, UserSession.GetAuthenticatedUsersCountPublic#11, UserSession.CreateUserBearerToken#12, UserSession.GetUserIdFromBearerToken#13, UserSession.GetUserOptions#14, UserSession.UpdateUserOptions#15, NX.GetAdvertisedParties#16, Steam.QueryUserIds#17, Steam.DecodePartyDataBearerTokens#18, Locator.GetSceneConnectionToken#19] | Response_Complete req=2 has_values=true",

//   "sent_human_readable": "System_Request msg_id=Get_Scene_Infos req=17 args=Get_Scene_Infos token=1049B metadata={stormancer.party=\"2022-06-09.1\", version=\"\", server.name=\"dt-live-1\", timeout=\"5000\", server.version=\"9.3.0.2\", stormancer.party.plugin=\"2020-08-21.1\", stormancer.partymanagement=\"2020-05-20.1\", stormancer.plugins.gamefinder.protocol=\"202006091\", plugins=\"RPC(1.0.0); Users(1.0.0); Party(2020-08-21.1); PartyMerging(1.0.0); GameFinder(202006091); GameSession(1.0.0); GameVersion(1.0.0); Friends(2.0.0); PlayerReports(1.0.0); DarkTales.GameSessions(1.0.0); Steam(1.0.0)\", serializers=\"msgpack/array\", transport=\"raknet\", platform=\"Win64\", protocol=\"4\", type=\"server\", serializer=\"msgpack/array\"}",
//   "real_human_readable": "Response_Msg req=17 data=Scene_Infos shard=0 scene=\"friends\" serializer=\"msgpack/array\" meta={stormancer.friends=\"enabled\", stormancer.plugins.rpc=\"1.1.0\"} routes=[stormancer.rpc.next#0, stormancer.rpc.cancel#1, stormancer.rpc.error#2, stormancer.rpc.completed#3, Friends.UpdateFriendList#4, Friends.Subscribe#5, Friends.RefreshSubscription#6, friends.invitefriend#7, friends.acceptfriendinvitation#8, friends.removefriend#9, friends.setstatus#10, Friends.Block#11, Friends.Unblock#12, Friends.GetBlockedList#13, Friends.Get#14] | Response_Complete req=17 has_values=true",
		args := message.args.(Get_Scene_Infos_Args) or_return
  
        if args.token.scene_id == "authenticator" {
            simple_server_state.get_scene_infos_args = args
                append(
                    &response_messages,
					Response_Msg{
                        req_id = message.req_id,
                        data = Scene_Infos {
							shard_id = 0,
							scene_id = "authenticator",
							selected_serializer = "msgpack/array",
                            stormancer_plugins_nintendo = "enabled",
                            stormancer_plugins_steam = "4.2.1.42",
							stormancer_game_version = "default",
                            stormancer_plugins_rpc = "1.1.0",
                            stormancer_plugins_psn = "202006171",
							account_id = "darktales",
							app_id = "live-1-05-00",
							stormancer_plugins_xbl_use_modern_gamertag = "false",
							routes = Routes {
								"stormancer.rpc.next",
								"stormancer.rpc.cancel",
								"stormancer.rpc.error",
								"stormancer.rpc.completed",
								"Authentication.GetMetadata",
								"Authentication.Register",
								"Authentication.Login",
								"Authentication.GetStatus",
								"Authentication.Unlink",
								"sendRequest",
								"sceneauthorization.gettoken",
								"UserSession.GetAuthenticatedUsersCountPublic",
								"UserSession.CreateUserBearerToken",
								"UserSession.GetUserIdFromBearerToken",
								"UserSession.GetUserOptions",
								"UserSession.UpdateUserOptions",
								"NX.GetAdvertisedParties",
								"Steam.QueryUserIds",
								"Steam.DecodePartyDataBearerTokens",
								"Locator.GetSceneConnectionToken",
                            }
                        }
                    }
                )
                append(&response_messages, Response_Complete{req_id = message.req_id, has_values = true})
		} else if args.token.scene_id == "friends" {
            //   "sent_human_readable": "System_Request msg_id=Get_Scene_Infos req=17 args=Get_Scene_Infos token=1049B metadata={stormancer.party=\"2022-06-09.1\", version=\"\", server.name=\"dt-live-1\", timeout=\"5000\", server.version=\"9.3.0.2\", stormancer.party.plugin=\"2020-08-21.1\", stormancer.partymanagement=\"2020-05-20.1\", stormancer.plugins.gamefinder.protocol=\"202006091\", plugins=\"RPC(1.0.0); Users(1.0.0); Party(2020-08-21.1); PartyMerging(1.0.0); GameFinder(202006091); GameSession(1.0.0); GameVersion(1.0.0); Friends(2.0.0); PlayerReports(1.0.0); DarkTales.GameSessions(1.0.0); Steam(1.0.0)\", serializers=\"msgpack/array\", transport=\"raknet\", platform=\"Win64\", protocol=\"4\", type=\"server\", serializer=\"msgpack/array\"}",
            //  "real_human_readable": "Response_Msg req=17 data=Scene_Infos shard=0 scene=\"friends\" serializer=\"msgpack/array\" meta={stormancer.friends=\"enabled\", stormancer.plugins.rpc=\"1.1.0\"} routes=[stormancer.rpc.next#0, stormancer.rpc.cancel#1, stormancer.rpc.error#2, stormancer.rpc.completed#3, Friends.UpdateFriendList#4, Friends.Subscribe#5, Friends.RefreshSubscription#6, friends.invitefriend#7, friends.acceptfriendinvitation#8, friends.removefriend#9, friends.setstatus#10, Friends.Block#11, Friends.Unblock#12, Friends.GetBlockedList#13, Friends.Get#14] | Response_Complete req=17 has_values=true",
            simple_server_state.get_scene_infos_args = args
            append(
                &response_messages,
				Response_Msg{
                    req_id = message.req_id,
                    data = Scene_Infos {                         
						shard_id = 0,
						scene_id = "friends",
						selected_serializer = "msgpack/array",
                        stormancer_friends = "enabled",
                        stormancer_plugins_rpc = "1.1.0",
							routes = Routes {
								"stormancer.rpc.next",
								"stormancer.rpc.cancel",
								"stormancer.rpc.error",
								"stormancer.rpc.completed",
								"Friends.UpdateFriendList",
								"Friends.Subscribe",
								"Friends.RefreshSubscription",
								"friends.invitefriend",
								"friends.acceptfriendinvitation",
								"friends.removefriend",
								"friends.setstatus",
								"Friends.Block",
								"Friends.Unblock",
								"Friends.GetBlockedList",
								"Friends.Get",
                        }
                    }
                }
            )
            append(&response_messages, Response_Complete{req_id = message.req_id, has_values = true})
		} else if args.token.scene_id == "party" {
//             "sent_human_readable": "System_Request msg_id=Get_Scene_Infos req=18 args=Get_Scene_Infos token=1057B metadata={stormancer.party=\"2022-06-09.1\", version=\"\", server.name=\"dt-live-1\", timeout=\"5000\", server.version=\"9.3.0.2\", stormancer.party.plugin=\"2020-08-21.1\", stormancer.partymanagement=\"2020-05-20.1\", stormancer.plugins.gamefinder.protocol=\"202006091\", plugins=\"RPC(1.0.0); Users(1.0.0); Party(2020-08-21.1); PartyMerging(1.0.0); GameFinder(202006091); GameSession(1.0.0); GameVersion(1.0.0); Friends(2.0.0); PlayerReports(1.0.0); DarkTales.GameSessions(1.0.0); Steam(1.0.0)\", serializers=\"msgpack/array\", transport=\"raknet\", platform=\"Win64\", protocol=\"4\", type=\"server\", serializer=\"msgpack/array\"}",
//   "real_human_readable": "Response_Msg req=18 data=Scene_Infos shard=0 scene=\"party-manager\" serializer=\"msgpack/array\" meta={stormancer.partymanagement=\"2020-05-20.1\", stormancer.plugins.rpc=\"1.1.0\"} routes=[stormancer.rpc.next#0, stormancer.rpc.cancel#1, stormancer.rpc.error#2, stormancer.rpc.completed#3, partymanagement.createsession#4, PartyManagement.CreateConnectionTokenFromInvitationCode#5, PartyManagement.CreateConnectionTokenFromPartyId#6, PartyManagement.SearchParties#7] | Response_Complete req=18 has_values=true",
  
            simple_server_state.get_scene_infos_args = args
            append(
                &response_messages,
				Response_Msg{
                    req_id = message.req_id,
                    data = Scene_Infos {
						shard_id = 0,
						scene_id = "party-manager",
						selected_serializer = "msgpack/array",
                        stormancer_partymanagement = "2020-05-20.1",
                        stormancer_plugins_rpc = "1.1.0",
                            routes = Routes {
                                "stormancer.rpc.next",
                                "stormancer.rpc.cancel",
                                "stormancer.rpc.error",
                                "stormancer.rpc.completed",
                                "partymanagement.createsession",
                                "PartyManagement.CreateConnectionTokenFromInvitationCode",
                                "PartyManagement.CreateConnectionTokenFromPartyId",
                                "PartyManagement.SearchParties",
                            }
                    }
                }
            )
            append(&response_messages, Response_Complete{req_id = message.req_id, has_values = true})
        }
}
	ok = true
	return
}

get_response_from_scene_message :: proc(
	client_id: int,
	label: string,
	message: Scene_Message,
	verbose: bool,
	simple_server_state: ^Simple_Server_State,
) -> (
	response_messages: [dynamic; SIMPLE_MAX_RESPONSES]Decoded_Message,
	ok: bool,
) {
	route := simple_server_state.scenes[message.scene_handle - SCENE_HANDLE_MIN][message.route_handle]
	switch route {
	case "Authentication.Login":
		body := message.body.(Authentication_Login_Body) or_return
//         "sent_human_readable": "Scene_Message handle=141 route=6(Authentication.Login) rpc=1 [[\"steam\", {\"gameVersion.clientVersion\": \"1.05.00.05\", \"provider\": \"steam\", \"ticket\": \"140000004F316731E9C817C7BB9F0C0101001001C24E236A180000000100000005000000C7D1724E00372436898F5A0AB9000000B20000003200000004000000BB9F0C0101001001F09A1F00A7599BB88101010A00000000BC531B6A3C03376A010059C2100000000000BA6E72D9F085C7D5CD2628D22C0C0D67544C6D4C162CA664248F076E7D4D8A1CED297A86B596A9A28B2CAF53E1FC7E91B8D486F59399B96EC6C110FED6589A3B49E0846268CCC94B17B81FEAF04BB0B0DC23263FFEEA5B70A43A1FA6CC3427AF84EC70F53AFED224AE327149656DEB25CDA05E87CDF2677BA72EE53B8F905BA0\", \"version\": \"v1\", \"appId\": \"2071280\"}]]",
//   "real_human_readable": "Scene_Message handle=141 route=2(stormancer.rpc.next) rpc=1 [[nil, true, \"4168ffb24de245f88060d27c9580685e\", \"\", {\"steam\": \"steam:76561197977870267\"}, {}]] | Scene_Message handle=141 route=1(stormancer.rpc.completed) rpc=257 [0]",
  
		simple_server_state.authentication_login = body
		simple_server_state.steam_id = steam_id_from_login_ticket(body.ticket)
		simple_server_state.user_id = ""
		if id, ok := g_simple_user_ids_by_steam[simple_server_state.steam_id]; ok do simple_server_state.user_id = id
        if len(simple_server_state.user_id) == 0 {
            simple_server_state.user_id = fmt.aprintf("%032s", simple_server_state.steam_id)
        }
		steam_identity := fmt.aprintf("steam:%s", simple_server_state.steam_id)
		append(
            &response_messages,
            Scene_Message{
                scene_handle = message.scene_handle,
				route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.next"),
                body = Stormancer_Rpc_Next_Body { 
					kind = .Authentication_Login_Result,
					rpc_id = body.rpc_id, // or maybe hardcode 1 since we know that's what the client expects?
                    result_is_nil = true,
                    success = true,
                    user_id = simple_server_state.user_id,
                    error_message = "",
                    identity_count = 1,
                    steam_identity = steam_identity,
                    steam_id = simple_server_state.steam_id,
                    metadata_count = 0,
                },
            },
        )
        append(
            &response_messages,Scene_Message{
                scene_handle = message.scene_handle,
				route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
                body = Stormancer_Rpc_Completed_Body {
                    rpc_id = 257, // the client seems to expect this specific rpc_id for the completed message after login
                    message_sent = true,
                }
            }
        )

	case "Locator.GetSceneConnectionToken":
		body := message.body.(Locator_GetSceneConnectionToken_Body) or_return
		if body.scene_id == "stormancer.friends" {
           // "sent_human_readable": "Scene_Message handle=141 route=19(Locator.GetSceneConnectionToken) rpc=2 [\"stormancer.friends\", \"\"] 
            //   "real_human_readable": "Scene_Message handle=141 route=2(stormancer.rpc.next) rpc=2 [json:{\"token\":\"i6lBY2NvdW50SWSpZGFya3RhbGVzq0FwcGxpY2F0aW9urGxpdmUtMS0wNS0wMKZJc3N1ZWTX/\\u002BoV\\u002BgBqI3H7qkV4cGlyYXRpb27X/\\u002BoV\\u002B5BqI3MnqFVzZXJEYXRhxQHhAAAB3ZmSpXN0ZWFtsTc2NTYxMTk3OTc3ODcwMjY3mNkgNDE2OGZmYjI0ZGUyNDVmODgwNjBkMjdjOTU4MDY4NWWBpXN0ZWFtgadzdGVhbWlksTc2NTYxMTk3OTc3ODcwMjY3g6Zwc2V1ZG\\u002BqTWFqb3IgSG9mZqdvcHRpb25zgaljcm9zc3BsYXmBp2VuYWJsZWTDp3N0ZWFtaWSxNzY1NjExOTc5Nzc4NzAyNjfX/zgATcBqG1ZR1/84AE3AahtWUYClc3RlYW3AxBCYrdv8V8IZTqk1\\u002BOfjDw/GgaVzdGVhbbdzdGVhbTo3NjU2MTE5Nzk3Nzg3MDI2N4Krc3RlYW0uYXBwSWTEBPCaHwC5Z2FtZVZlcnNpb24uY2xpZW50VmVyc2lvbsQPAAAAC6oxLjA1LjAwLjA11//qW1yAaiNx\\u002Btmbc2NlbmU6L3Bhc3N0ZWNoLWxpdmUvL2Rhcmt0YWxlcy9saXZlLTEtMDUtMDAvMjU2NGQ4YmUtMmRiYi00OTY3LWI2YmItMGUxNTdhYTdmNjNmLzE/L2F1dGhlbnRpY2F0b3IjYXV0aGVudGljYXRvci8wKCspWzJlMDk1NmUxLTk0M2YtNGE0ZS1hMGIzLTFiODZkOTA2MDA5Yl3AAKtDb250ZW50VHlwZbZzdG9ybWFuY2VyL3VzZXJTZXNzaW9uqUVuZHBvaW50c8CnU2NlbmVJZNkzc2NlbmU6L3Bhc3N0ZWNoLWxpdmUvZGFya3RhbGVzL2xpdmUtMS0wNS0wMC9mcmllbmRzp1JvdXRpbmfArERlcGxveW1lbnRJZNkkMjU2NGQ4YmUtMmRiYi00OTY3LWI2YmItMGUxNTdhYTdmNjNmp1ZlcnNpb24C-X2GmCSkYfcmmsa79XgI9bfwZsbd9ipEovC1JNbF66co=\",\"endpoints\":{\"raknet\":[\"dt-live.passtechgames.com:30100\",\"dt-live-2.passtechgames.com:30100\"]},\"encryption\":{\"algorithm\":\"aes256\",\"mode\":\"GCM\",\"key\":\"B\\u002B9QpyQucI/bPhfQ65KwHUod9twmSBi6ZQGJgL6v2tg=\",\"token\":\"xBDnDQaJoyQZS435Ce47IdMpXHVJte40NO/G6cbGtYh4rDnqMYnuuQQqx419XKPtyW1hxFKALet6kgVn4kWmqnz4ebeLKIDqyt0=\"}}, 114, 109, 97, 110, 99, 101, 114, 46, 114, 112, 99, 46, 99, 111, 109, 112, 108, 101, 116, 101, 100, \"Handle\", 0, \"Metadata\", {}, {\"Name\": \"stormancer.rpc.next\", \"Handle\": 0, \"Metadata\": {}}, {\"Name\": \"stormancer.rpc.cancel\", \"Handle\": 0, \"Metadata\": {}}, {\"Name\": \"stormancer.rpc.error\", \"Handle\": 0, \"Metadata\": {}}, {\"Name\": \"gamefinder.update\", \"Handle\": 0, \"Metadata\": {}}, \"stormancer/userSession\", nil, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] 
            //  Scene_Message handle=141 route=1(stormancer.rpc.completed) rpc=513 [0]  
		append(
			&response_messages,
			Scene_Message{
				scene_handle = message.scene_handle,
				route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.next"),
				body = Stormancer_Rpc_Next_Body {
					rpc_id = body.rpc_id,
					kind = .Scene_Connection_Token,
					token_scene = "friends",
					token_json = scene_token_json("friends"),
				},
			}
		)
		append(&response_messages,
			Scene_Message{
                scene_handle = message.scene_handle,
                route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
                body = Stormancer_Rpc_Completed_Body {
                    rpc_id = 513, 
                    message_sent = true,
                },
            }
		)
		}
		if body.scene_id == "stormancer.plugins.partyManagement" {
        //  Scene_Message handle=141 route=19(Locator.GetSceneConnectionToken) rpc=3 [\"stormancer.plugins.partyManagement\", \"\"] 
        //  Scene_Message handle=141 route=2(stormancer.rpc.next) rpc=3 [json:{\"token\":\"i6lBY2NvdW50SWSpZGFya3RhbGVzq0FwcGxpY2F0aW9urGxpdmUtMS0wNS0wMKZJc3N1ZWTX/\\u002BtaRlBqI3H7qkV4cGlyYXRpb27X/\\u002BtaRlBqI3MnqFVzZXJEYXRhxQHhAAAB3ZmSpXN0ZWFtsTc2NTYxMTk3OTc3ODcwMjY3mNkgNDE2OGZmYjI0ZGUyNDVmODgwNjBkMjdjOTU4MDY4NWWBpXN0ZWFtgadzdGVhbWlksTc2NTYxMTk3OTc3ODcwMjY3g6Zwc2V1ZG\\u002BqTWFqb3IgSG9mZqdvcHRpb25zgaljcm9zc3BsYXmBp2VuYWJsZWTDp3N0ZWFtaWSxNzY1NjExOTc5Nzc4NzAyNjfX/zgATcBqG1ZR1/84AE3AahtWUYClc3RlYW3AxBCYrdv8V8IZTqk1\\u002BOfjDw/GgaVzdGVhbbdzdGVhbTo3NjU2MTE5Nzk3Nzg3MDI2N4Krc3RlYW0uYXBwSWTEBPCaHwC5Z2FtZVZlcnNpb24uY2xpZW50VmVyc2lvbsQPAAAAC6oxLjA1LjAwLjA11//qW1yAaiNx\\u002Btmbc2NlbmU6L3Bhc3N0ZWNoLWxpdmUvL2Rhcmt0YWxlcy9saXZlLTEtMDUtMDAvMjU2NGQ4YmUtMmRiYi00OTY3LWI2YmItMGUxNTdhYTdmNjNmLzE/L2F1dGhlbnRpY2F0b3IjYXV0aGVudGljYXRvci8wKCspWzJlMDk1NmUxLTk0M2YtNGE0ZS1hMGIzLTFiODZkOTA2MDA5Yl3AAKtDb250ZW50VHlwZbZzdG9ybWFuY2VyL3VzZXJTZXNzaW9uqUVuZHBvaW50c8CnU2NlbmVJZNk5c2NlbmU6L3Bhc3N0ZWNoLWxpdmUvZGFya3RhbGVzL2xpdmUtMS0wNS0wMC9wYXJ0eS1tYW5hZ2Vyp1JvdXRpbmfArERlcGxveW1lbnRJZNkkMjU2NGQ4YmUtMmRiYi00OTY3LWI2YmItMGUxNTdhYTdmNjNmp1ZlcnNpb24C-t\\u002BICAXrw3wUTPFnl6D39Jqe7\\u002BROYezleBqYMTcG5R3k=\",\"endpoints\":{\"raknet\":[\"dt-live.passtechgames.com:30100\",\"dt-live-2.passtechgames.com:30100\"]},\"encryption\":{\"algorithm\":\"aes256\",\"mode\":\"GCM\",\"key\":\"qNPJiED5pjKs764P0X2PKl4HcMlo\\u002BojmkQW4bxRgCZ0=\",\"token\":\"xBDnDQaJoyQZS435Ce47IdMpcML4NNNFWD75rdisPIIITL6zv2BzlxBifHyGHrExpp\\u002BWQfSVr\\u002B8\\u002BK8lD4QqhF8\\u002BZbm9QwY2go1w=\"}}, 121, 80, 120, 87, 65, 107, 122, 99, 52, 47, 57, 82, 84, 100, 101, 110, 119, 97, 114, 83, 67, 55, 119, 110, 107, 90, 78, 66, 122, 101, 66, 71, 111, 83, 113, 104, 48, 72, 79, 102, 71, 92, 117, 48, 48, 50, 66, 81, 102, 92, 117, 48, 48, 50, 66, 110, 90, 77, 110, 72, 83, 73, 107, 61, 34, 125, 125, 0, 0, 0, 25, 0, 1, 0, 0, 0, 0, 0, 7, 14, 103, 0, 0, 0, 56, 0, 0, 0, 2, 0, 1, 2, 3, 1, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] 
        //  Scene_Message handle=141 route=1(stormancer.rpc.completed) rpc=769 [0] 
		append(
			&response_messages,
			Scene_Message{
				scene_handle = message.scene_handle,
				route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.next"),
				body = Stormancer_Rpc_Next_Body {
					rpc_id = body.rpc_id,
					kind = .Scene_Connection_Token,
					token_scene = "party-manager",
					token_json = scene_token_json("party-manager"),
				},
			},
		)
		append(
			&response_messages,
			Scene_Message{
				scene_handle = message.scene_handle,
				route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
				body = Stormancer_Rpc_Completed_Body {
					rpc_id = 769,
					message_sent = true,
				},
			},
		)
		}

	case "UserSession.UpdateUserOptions":
		body := message.body.(UserSession_UpdateUserOptions_Body) or_return
        //  Scene_Message handle=141 route=15(UserSession.UpdateUserOptions) rpc=4 [\"crossplay\", {\"enabled\": true}]",
        //  Scene_Message handle=141 route=1(stormancer.rpc.completed) rpc=1024 [0]",
		simple_server_state.user_session_update_options = body
        append(&response_messages, Scene_Message {
            scene_handle = message.scene_handle,
			route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
            body = Stormancer_Rpc_Completed_Body {
                rpc_id = 1024, // the client seems to expect this specific rpc_id for the completed message after updating user options
                message_sent = true,
            }
        })
	}
	ok = true
	return
}

