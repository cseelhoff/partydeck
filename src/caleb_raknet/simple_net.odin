package caleb_raknet

// simple_net is a fresh, intentionally flat entrypoint for building the next
// network predictor/server shape. It listens locally, runs the plain dtlive HTTP
// token shim, reassembles client RakNet content datagrams into encoded messages,
// decodes each message into the typed unions, then dispatches through explicit
// switch cases. The cases are stubs for now.

import "core:encoding/hex"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:sys/posix"
import "core:time"

SIMPLE_DEFAULT_RAKNET_ENDPOINT :: "10.1.1.129:30100"
SIMPLE_DEFAULT_DTLIVE_PORT :: 8080

Simple_Server_State :: struct {
	client_id:                   uint,
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

client_list: map[net.Endpoint]uint
total_clients: uint
g_server_state: [dynamic]Simple_Server_State

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

	fmt.printfln(
		"simple_net listening on udp %s:%d; dtlive plain %s:%d; token raknet endpoint %s",
		LISTEN_HOST,
		LISTEN_PORT,
		LISTEN_HOST,
		http_port,
		raknet_endpoint,
	)

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
			simple_dtlive_handle_one(http_sock, log_scratch)
		}
		if !(.IN in polls[0].revents) do continue

		n, remote := net.recv_udp(sock, buf[:]) or_continue
		if n <= 0 do continue
		data := buf[:n]
		client_id, is_new_client := simple_net_client_id(remote)
		if is_new_client {
			fmt.printfln("simple client_id=%d -> %v", client_id, remote)
		}

		peer_count_before := len(live_peers)
		peer_index := live_peer_index(&live_peers, remote)
		label := live_peers[peer_index].label
		if len(live_peers) != peer_count_before {
			fmt.printfln("simple client %s -> %v", label, remote)
		}

		if live_predict_handle_health(sock, &wire, live_peers[peer_index].addr, data) do continue

		now := time.now()
		if !udp_datagram_push(dgrams, remote, now, data) {
			fmt.eprintfln("datagram store full, dropping %d bytes", n)
			continue
		}
		process_udp_datagram(dgrams, msgs, reasm, dgrams.count - 1)

		if live_predict_handle_offline(sock, &wire, live_peers[peer_index].addr, data, scratch) {
			continue
		}
		if !is_content_datagram(data) do continue

		net.send_udp(sock, make_ack(read_u24_le(data, 1), scratch), remote)

		ps := find_peer(&peers, label, &nidx)
		encoded_messages := filter_health_messages(
			reassemble_side(ps, .C2S, {data}, scratch),
			scratch,
		)
		for encoded_message in encoded_messages {
			decoded := decode_message(encoded_message, scratch)
			route_registry_observe(&ps.reg_real, ps.ep_client, decoded)
			if sm, ok := decoded.(Scene_Message); ok {
				route_name := route_registry_resolve(
					&ps.reg_real,
					ps.ep_client,
					sm.scene_handle,
					sm.route_handle,
				)
				decoded = scene_message_with_route_body(decoded, route_name, scratch)
			}
			simple_server_state := &g_server_state[int(client_id)]
			simple_apply_decoded_message(client_id, label, decoded, verbose, simple_server_state)
			response_messages := simple_dispatch_decoded_message(
				client_id,
				label,
				decoded,
				verbose,
				simple_server_state,
			)
			for response_message in response_messages {
				simple_apply_decoded_message(
					client_id,
					label,
					response_message,
					verbose,
					simple_server_state,
				)
			}
		}
	}
	return nil
}

simple_net_globals_init :: proc() {
	if client_list == nil do client_list = make(map[net.Endpoint]uint)
	if g_server_state == nil do g_server_state = make([dynamic]Simple_Server_State)
	if len(g_server_state) == 0 do append(&g_server_state, Simple_Server_State{})
}

simple_net_client_id :: proc(remote: net.Endpoint) -> (uint, bool) {
	if id, ok := client_list[remote]; ok do return id, false
	total_clients += 1
	client_id := total_clients
	client_list[remote] = client_id
	for len(g_server_state) <= int(client_id) do append(&g_server_state, Simple_Server_State{})
	g_server_state[int(client_id)] = Simple_Server_State {
		client_id = client_id,
		remote    = remote,
	}
	return client_id, true
}

simple_dtlive_handle_one :: proc(sock: net.TCP_Socket, allocator := context.allocator) {
	free_all(allocator)
	client, remote, err := net.accept_tcp(sock)
	if err != nil do return
	defer net.close(client)

	buf: [16 * 1024]byte
	n, recv_err := net.recv_tcp(client, buf[:])
	if recv_err != nil || n <= 0 do return
	req := string(buf[:n])
	path := http_request_path(req)
	body, content_type := simple_dtlive_response_body(path, allocator)
	resp := fmt.aprintf(
		"HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\nServer: Kestrel\r\nCache-Control: no-cache\r\nx-version: 3\r\nConnection: close\r\n\r\n%s",
		content_type,
		len(body),
		body,
		allocator = allocator,
	)
	fmt.printfln("simple dtlive %s from %v -> %dB", path, remote, len(body))
	net.send_tcp(client, transmute([]byte)resp)
}

simple_dtlive_response_body :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	string,
	string,
) {
	if path == "/_federation" {
		return "{\"current\":{\"id\":\"passtech-live\",\"adminEndpoints\":[\"https://dt-live.passtechgames.com\"],\"endpoints\":[\"https://dt-live.passtechgames.com\"],\"tags\":[]},\"clusters\":[{\"id\":\"passtech-live\",\"adminEndpoints\":null,\"endpoints\":[\"https://dt-live.passtechgames.com\"],\"tags\":[]}]}",
			"application/json"
	}
	if string_has_suffix(path, "/token") {
		raknet_endpoint := env_string("RAKNET_ENDPOINT", SIMPLE_DEFAULT_RAKNET_ENDPOINT, allocator)
		return scene_token_json_endpoint("authenticator", raknet_endpoint, allocator),
			"application/json; charset=utf-8"
	}
	if path == "/" {
		return "{\"name\":\"dt-live-1\",\"version\":\"9.3.0.2\",\"reportedStatus\":\"Leader\",\"leader\":{\"uid\":\"5w0GiaMkGUuN+QnuOyHTKQ\",\"name\":\"dt-live-1\",\"endpoint\":\"dt-live.passtechgames.com:40243\",\"cluster\":\"passtech-live\"},\"cluster\":\"passtech-live\",\"logLastCommittedEntryId\":19,\"logLastEntryId\":19,\"logLastSnapshot\":null,\"state\":\"Running\",\"id\":\"5w0GiaMkGUuN+QnuOyHTKQ\"}",
			"application/json"
	}
	return `{}`, "application/json"
}

simple_net_stub :: proc(label, name: string, verbose: bool) {
	if verbose do fmt.printfln("simple %s -> %s", label, name)
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

steam_identity_for_peer :: proc(peer: string) -> string {
	if peer == "C2" do return "steam:76561197977870267"
	return "steam:76561199572083022"
}

steam_id_from_login_ticket :: proc(ticket: string, allocator := context.allocator) -> string {
	data, ok := hex.decode(transmute([]byte)ticket, allocator)
	if !ok || len(data) < 20 do return ""
	defer delete(data, allocator)
	return fmt.aprintf("%d", read_u64_le(data, 12), allocator = allocator)
}

user_id_from_steam_id :: proc(steam_id: string) -> string {
	switch steam_id {
	case "76561197977870267":
		return "4168ffb24de245f88060d27c9580685e"
	case "76561199572083022":
		return "9fe2fc1fa18643e2818bbd65198d4b00"
	}
	return ""
}

simple_apply_decoded_message :: proc(
	client_id: uint,
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
		simple_dispatch_scene_message(client_id, label, m, verbose, simple_server_state)
	case Malformed_Message:
		simple_server_state.malformed_message = m
		simple_net_stub(label, "Malformed_Message", verbose)
	case Unknown_Message:
		simple_server_state.unknown_message = m
		simple_net_stub(label, "Unknown_Message", verbose)
	}
}

simple_apply_system_request :: proc(
	client_id: uint,
	label: string,
	message: System_Request,
	verbose: bool,
	simple_server_state: ^Simple_Server_State,
) {
	switch args in message.args {
	case Connect_To_Scene_Args:
		simple_server_state.connect_to_scene_args = args
		simple_net_stub(label, "System_Request.Connect_To_Scene", verbose)
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
	client_id: uint,
	label: string,
	message: Decoded_Message,
	verbose: bool,
	simple_server_state: ^Simple_Server_State,
) -> (
	response_messages: [dynamic; 3]Decoded_Message,
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
		//   "real_human_readable": "Response_Msg req=1 data=Session_Token sid=\"la1AFGj1KUerZTS8aegRXw\" jwt=JWT{header={\"alg\":\"none\",\"typ\":\"JWT\",\"clusterId\":\"passtech-live\"} payload={\"Stormancer/sessionId\":\"la1AFGj1KUerZTS8aegRXw\",\"nbf\":1780707835,\"exp\":1780794235,\"iat\":1780707835,\"iss\":\"passtech-live\"} sig=0B} | Response_Complete req=1 has_values=true",

        append(&response_messages, Decoded_Message(Response_Msg {
            req_id = m.req_id,
            data = Session_Token {
                jwt = "",
                session_id = "la1AFGj1KUerZTS8aegRXw",
            },
        }))
        append(&response_messages, Decoded_Message(Response_Complete {
            req_id = m.req_id,
            has_values = true,
        }))
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
		simple_net_stub(label, "Scene_Message", verbose)
	case Malformed_Message:
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Malformed_Message", verbose)
	case Unknown_Message:
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Unknown_Message", verbose)
	}
	return
}

simple_dispatch_system_request :: proc(
	client_id: uint,
	label: string,
	message: System_Request,
	verbose: bool,
	simple_server_state: ^Simple_Server_State,
) -> (
	response_messages: [dynamic; 3]Decoded_Message,
) {
	switch args in message.args {
	case Connect_To_Scene_Args:
		// predict_caleb sent_human_readable t=2026-06-06T01:03:52.313899701Z line=  "sent_human_readable": "System_Request msg_id=Connect_To_Scene req=7 args=Connect token=449B routes=[stormancer.rpc.completed#0, stormancer.rpc.next#0, gameVersion.update#0, stormancer.rpc.cancel#0, sendRequest#0, stormancer.rpc.error#0, serverVersion.update#0, users.renewCredentials#0] scene_meta={stormancer.plugins.rpc=\"1.1.0\", stormancer.plugins.nintendo=\"enabled\", Stormancer.plugins.XBLServices.useModernGamerTag=\"false\", stormancer.plugins.steam=\"4.2.1.42\", appId=\"live-1-05-00\", accountId=\"darktales\", stormancer.gameVersion=\"default\", stormancer.plugins.psn=\"202006171\"} conn_meta={stormancer.party=\"2022-06-09.1\", version=\"\", server.name=\"dt-live-1\", timeout=\"5000\", server.version=\"9.3.0.2\", stormancer.party.plugin=\"2020-08-21.1\", stormancer.partymanagement=\"2020-05-20.1\", stormancer.plugins.gamefinder.protocol=\"202006091\", plugins=\"RPC(1.0.0); Users(1.0.0); Party(2020-08-21.1); PartyMerging(1.0.0); GameFinder(202006091); GameSession(1.0.0); GameVersion(1.0.0); Friends(2.0.0); PlayerReports(1.0.0); DarkTales.GameSessions(1.0.0); Steam(1.0.0)\", serializers=\"msgpack/array\", transport=\"raknet\", platform=\"Win64\", protocol=\"4\", type=\"server\", serializer=\"msgpack/array\"}",
		scene_handle := u64(SCENE_HANDLE_MIN + len(simple_server_state.scene_connection_result.scenes))
		result := simple_server_state.scene_connection_result
		for route, route_index in args.routes {
			scene_connection_result_set_route(&result, scene_handle, u64(route_index + 1), route.name)
		}
		response_msg := Response_Msg {
			req_id = message.req_id,
			data   = result,
		}
		response_complete := Response_Complete {
			req_id     = message.req_id,
			has_values = true,
		}
		append(&response_messages, Decoded_Message(response_msg), Decoded_Message(response_complete))
	case Get_Scene_Infos_Args:
		// predict_caleb sent_human_readable t=2026-06-06T01:03:50.428809511Z line=  "sent_human_readable": "System_Request msg_id=Get_Scene_Infos req=2 args=Get_Scene_Infos token=449B metadata={stormancer.party=\"2022-06-09.1\", version=\"\", server.name=\"dt-live-1\", timeout=\"5000\", server.version=\"9.3.0.2\", stormancer.party.plugin=\"2020-08-21.1\", stormancer.partymanagement=\"2020-05-20.1\", stormancer.plugins.gamefinder.protocol=\"202006091\", plugins=\"RPC(1.0.0); Users(1.0.0); Party(2020-08-21.1); PartyMerging(1.0.0); GameFinder(202006091); GameSession(1.0.0); GameVersion(1.0.0); Friends(2.0.0); PlayerReports(1.0.0); DarkTales.GameSessions(1.0.0); Steam(1.0.0)\", serializers=\"msgpack/array\", transport=\"raknet\", platform=\"Win64\", protocol=\"4\", type=\"server\"}",
		response_msg := Response_Msg {
            req_id = message.req_id,
            //   "real_human_readable": "Response_Msg req=2 data=Scene_Infos shard=0 scene=\"authenticator\" serializer=\"msgpack/array\" meta={stormancer.plugins.nintendo=\"enabled\", stormancer.plugins.steam=\"4.2.1.42\", stormancer.gameVersion=\"default\", stormancer.plugins.rpc=\"1.1.0\", stormancer.plugins.psn=\"202006171\", accountId=\"darktales\", appId=\"live-1-05-00\", Stormancer.plugins.XBLServices.useModernGamerTag=\"false\"} routes=[stormancer.rpc.next#0, stormancer.rpc.cancel#1, stormancer.rpc.error#2, stormancer.rpc.completed#3, Authentication.GetMetadata#4, Authentication.Register#5, Authentication.Login#6, Authentication.GetStatus#7, Authentication.Unlink#8, sendRequest#9, sceneauthorization.gettoken#10, UserSession.GetAuthenticatedUsersCountPublic#11, UserSession.CreateUserBearerToken#12, UserSession.GetUserIdFromBearerToken#13, UserSession.GetUserOptions#14, UserSession.UpdateUserOptions#15, NX.GetAdvertisedParties#16, Steam.QueryUserIds#17, Steam.DecodePartyDataBearerTokens#18, Locator.GetSceneConnectionToken#19] | Response_Complete req=2 has_values=true",
            data = Scene_Infos {
                shard_id = 0,
                scene_id = "authenticator",
				account_id = "darktales",
				app_id = "live-1-05-00",
                darktales_gamesession = "",
                stormancer_friends = "",
                stormancer_gamesession = "",
				stormancer_game_version = "default",
                stormancer_party = "",
                stormancer_partymanagement = "",
                stormancer_party_merging = "",
                stormancer_party_revision = "",
                stormancer_plugins_gamefinder = "",
                stormancer_plugins_gamefinder_protocol = "",
                stormancer_plugins_nintendo = "enabled",
				stormancer_plugins_psn = "202006171",
				stormancer_plugins_rpc = "1.1.0",
				stormancer_plugins_steam = "4.2.1.42",
				stormancer_plugins_xbl_use_modern_gamertag = "false",
				routes = []Scene_Route {
					Scene_Route{name = "stormancer.rpc.next", handle = 0},
					Scene_Route{name = "stormancer.rpc.cancel", handle = 1},
					Scene_Route{name = "stormancer.rpc.error", handle = 2},
					Scene_Route{name = "stormancer.rpc.completed", handle = 3},
					Scene_Route{name = "Authentication.GetMetadata", handle = 4},
					Scene_Route{name = "Authentication.Register", handle = 5},
					Scene_Route{name = "Authentication.Login", handle = 6},
					Scene_Route{name = "Authentication.GetStatus", handle = 7},
					Scene_Route{name = "Authentication.Unlink", handle = 8},
					Scene_Route{name = "sendRequest", handle = 9},
					Scene_Route{name = "sceneauthorization.gettoken", handle = 10},
					Scene_Route{name = "UserSession.GetAuthenticatedUsersCountPublic", handle = 11},
					Scene_Route{name = "UserSession.CreateUserBearerToken", handle = 12},
					Scene_Route{name = "UserSession.GetUserIdFromBearerToken", handle = 13},
					Scene_Route{name = "UserSession.GetUserOptions", handle = 14},
					Scene_Route{name = "UserSession.UpdateUserOptions", handle = 15},
					Scene_Route{name = "NX.GetAdvertisedParties", handle = 16},
					Scene_Route{name = "Steam.QueryUserIds", handle = 17},
					Scene_Route{name = "Steam.DecodePartyDataBearerTokens", handle = 18},
					Scene_Route{name = "Locator.GetSceneConnectionToken", handle = 19},
				},
				selected_serializer = "msgpack/array",
            },
        }
		response_complete := Response_Complete {
            req_id     = message.req_id,
            has_values = true,
        }
		append(&response_messages, Decoded_Message(response_msg), Decoded_Message(response_complete))
	case Set_Metadata_Args:
		response_complete := Response_Complete {
            req_id     = message.req_id,
            has_values = false,
        }
		append(&response_messages, Decoded_Message(response_complete))
	case Scene_Ready_Args:
        //  "real_human_readable": "Response_Msg req=9 data=Bool_Result v=true | Scene_Message handle=141 route=3(gameVersion.update) [\"bot,1.05.*\"] | Response_Complete req=9 has_values=true | Response_Complete req=12 has_values=true",
		response_msg := Response_Msg {
            req_id = message.req_id,
			data   = Bool_Result{value = true},
        }
		append(&response_messages, Decoded_Message(response_msg))
        if simple_server_state.scene_ready_args.sent_game_version_update == false {
			scene_message := Scene_Message {
                scene_handle = u8(args.scene_handle),
				route_handle = get_route_from_handle(simple_server_state, args.scene_handle, "gameVersion.update"),
                body = GameVersion_Update_Body {
					accepted_version = "bot,1.05.*",
                },
            }
			append(&response_messages, Decoded_Message(scene_message))
        }
		response_complete := Response_Complete {
            req_id     = message.req_id,
            has_values = true,
        }
		append(&response_messages, Decoded_Message(response_complete))
	case Disconnect_From_Scene_Args:
		// predict_caleb sent_human_readable t=2026-06-06T01:04:26.261603647Z line=  "sent_human_readable": "System_Request msg_id=Disconnect_From_Scene req=36 args=Disconnect handle=144",
		simple_net_stub(label, "System_Request.Disconnect_From_Scene", verbose)
	case Ping_Args:
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "System_Request.Ping", verbose)
	case No_Args:
		// predict_caleb sent_human_readable t=2026-06-06T01:03:49.582001573Z line=  "sent_human_readable": "System_Request msg_id=Get_Session_Token req=1 args=(none)",
		response_msg := Response_Msg {
			req_id = message.req_id,
			data = Session_Token {
				jwt = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIiwiY2x1c3RlcklkIjoicGFzc3RlY2gtbGl2ZSJ9.eyJTdG9ybWFuY2VyL3Nlc3Npb25JZCI6ImJYMkZOMVdhS1Vxb3VCY2JVNTlWbVEiLCJuYmYiOjE3ODA1MzcyMTIsImV4cCI6MTc4MDYyMzYxMiwiaWF0IjoxNzgwNTM3MjEyLCJpc3MiOiJwYXNzdGVjaC1saXZlIn0.",
				session_id = "bX2FN1WaKUqouBcbU59VmQ",
			},
		}
		response_complete := Response_Complete {
			req_id     = message.req_id,
			has_values = true,
		}
		append(&response_messages, Decoded_Message(response_msg), Decoded_Message(response_complete))
		simple_net_stub(label, "System_Request.No_Args", verbose)
		return
	case Unparsed_Args:
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "System_Request.Unparsed_Args", verbose)
	}
	return
}

simple_dispatch_response_msg :: proc(
	client_id: uint,
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
	client_id: uint,
	label: string,
	message: Scene_Message,
	verbose: bool,
	simple_server_state: ^Simple_Server_State,
) -> (
	response_messages: [dynamic; 3]Decoded_Message) {
	switch body in message.body {
	case Scene_Raw_Body:
		simple_server_state.scene_raw_body = body
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Scene_Message.Scene_Raw_Body", verbose)
	case Stormancer_Rpc_Completed_Body:
		simple_server_state.stormancer_rpc_completed = body
		// predict_caleb sent_human_readable t=2026-06-06T01:04:02.935732632Z line=  "sent_human_readable": "Scene_Message handle=144 route=3(stormancer.rpc.completed) rpc=257 [0]",
		simple_net_stub(label, "Scene_Message.Stormancer_Rpc_Completed", verbose)
	case Stormancer_Rpc_Next_Body:
		simple_server_state.stormancer_rpc_next = body
		// predict_caleb sent_human_readable t=2026-06-06T01:04:02.920778728Z line=  "sent_human_readable": "Scene_Message handle=144 route=0(stormancer.rpc.next) rpc=1 [[true, \"\", \"\", 109775243056466233]]",
		simple_net_stub(label, "Scene_Message.Stormancer_Rpc_Next", verbose)
	case Stormancer_Rpc_Error_Body:
		simple_server_state.stormancer_rpc_error = body
		// predict_caleb sent_human_readable: not found in sent_human_readable
		simple_net_stub(label, "Scene_Message.Stormancer_Rpc_Error", verbose)
	case Authentication_Login_Body:
		simple_server_state.authentication_login = body
		steam_id := steam_id_from_login_ticket(body.ticket)
		user_id := user_id_from_steam_id(steam_id)
		steam_identity := fmt.aprintf("steam:%s", steam_id)
		// "Scene_Message handle=141 route=2(stormancer.rpc.next) rpc=1 [[nil, true, \"4168ffb24de245f88060d27c9580685e\", \"\", {\"steam\": \"steam:76561197977870267\"}, {}]]"
		append(&response_messages, Decoded_Message(Scene_Message {
			scene_handle = message.scene_handle,
			route_handle = get_route_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.next"),
			body = Stormancer_Rpc_Next_Body {
				rpc_id         = 1,
				result_is_nil  = true,
				success        = true,
				user_id        = user_id,
				error_message  = "",
				identity_count = 1,
				steam_identity = steam_identity,
				steam_id       = steam_id,
				metadata_count = 0,
			},
		}))
        append(&response_messages, Decoded_Message(Scene_Message {
            scene_handle = message.scene_handle,
            route_handle = get_route_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
            body = Stormancer_Rpc_Completed_Body {
                rpc_id = 257,
                message_sent = false,
            },
        }))
	case Friends_Subscribe_Body:
		simple_server_state.friends_subscribe = body
		// predict_caleb sent_human_readable t=2026-06-06T01:03:58.633021004Z line=  "sent_human_readable": "Scene_Message handle=142 route=5(Friends.Subscribe) rpc=1 []",
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
		simple_net_stub(label, "Scene_Message.Locator_GetSceneConnectionToken", verbose)
	case Party_CreateInvitationCode_Body:
		simple_server_state.party_create_invitation = body
		// predict_caleb sent_human_readable t=2026-06-06T01:04:05.82094369Z line=  "sent_human_readable": "Scene_Message handle=144 route=13(Party.CreateInvitationCode) rpc=4 []",
		simple_net_stub(label, "Scene_Message.Party_CreateInvitationCode", verbose)
	case Party_GetPartyState2_Body:
		simple_server_state.party_get_party_state2 = body
		// predict_caleb sent_human_readable t=2026-06-06T01:04:03.832602873Z line=  "sent_human_readable": "Scene_Message handle=144 route=11(party.getpartystate2) rpc=1 [] | Scene_Message handle=144 route=3(stormancer.rpc.completed) rpc=512 [0]",
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
		simple_net_stub(label, "Scene_Message.Party_UpdateGameFinderPlayerStatus", verbose)
	case Party_UpdatePartySettings_Body:
		simple_server_state.party_update_settings = body
		// predict_caleb sent_human_readable t=2026-06-06T01:04:05.780613393Z line=  "sent_human_readable": "Scene_Message handle=144 route=6(Party.UpdatePartyUserData2) rpc=2 [json:{\"RequestedHero\":3,\"RequestedSkin\":0,\"InLobby\":true,\"PlayerName\":\"Major Hoff\",\"LobbyState\":1,\"UnlockedGameDifficulty\":0,\"MemberDataInitialized\":false,\"UnlockedHeroFlag\":31,\"m_sEosUserId\":\"0002ea2c70fa4f89a5d876065a55c786\",\"m_sSteamUserId\":76561197977870267,\"m_uVoiceChatMode\":0,\"m_ePlatform\":2,\"RandomSkinIndex\":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}, [[\"steam\", \"4168ffb24de245f88060d27c9580685e\", \"anonymous\", \"76561197977870267\", \"\", 0]]] | Scene_Message handle=144 route=4(party.updatepartysettings) rpc=3 [[\"matchmaking\", json:{\"InvitationCode\":\"\",\"GameMode\":0,\"GameDifficulty\":0,\"GameModifiers\":[],\"MergerDifficulty\":0}, true, true, \"\", \"\"]]",
		simple_net_stub(label, "Scene_Message.Party_UpdatePartySettings", verbose)
	case Party_UpdatePartyUserData2_Body:
		simple_server_state.party_update_user_data2 = body
		// predict_caleb sent_human_readable t=2026-06-06T01:04:05.780613393Z line=  "sent_human_readable": "Scene_Message handle=144 route=6(Party.UpdatePartyUserData2) rpc=2 [json:{\"RequestedHero\":3,\"RequestedSkin\":0,\"InLobby\":true,\"PlayerName\":\"Major Hoff\",\"LobbyState\":1,\"UnlockedGameDifficulty\":0,\"MemberDataInitialized\":false,\"UnlockedHeroFlag\":31,\"m_sEosUserId\":\"0002ea2c70fa4f89a5d876065a55c786\",\"m_sSteamUserId\":76561197977870267,\"m_uVoiceChatMode\":0,\"m_ePlatform\":2,\"RandomSkinIndex\":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}, [[\"steam\", \"4168ffb24de245f88060d27c9580685e\", \"anonymous\", \"76561197977870267\", \"\", 0]]] | Scene_Message handle=144 route=4(party.updatepartysettings) rpc=3 [[\"matchmaking\", json:{\"InvitationCode\":\"\",\"GameMode\":0,\"GameDifficulty\":0,\"GameModifiers\":[],\"MergerDifficulty\":0}, true, true, \"\", \"\"]]",
		simple_net_stub(label, "Scene_Message.Party_UpdatePartyUserData2", verbose)
	case PartyManagement_CreateConnectionTokenFromInvitationCode_Body:
		simple_server_state.party_conn_token_from_code = body
		// predict_caleb sent_human_readable t=2026-06-06T01:04:27.270107477Z line=  "sent_human_readable": "Scene_Message handle=143 route=5(PartyManagement.CreateConnectionTokenFromInvitationCode) rpc=2 [\"923100\", json:{\"RequestedHero\":3,\"RequestedSkin\":0,\"InLobby\":true,\"PlayerName\":\"Major Hoff\",\"LobbyState\":1,\"UnlockedGameDifficulty\":0,\"MemberDataInitialized\":true,\"UnlockedHeroFlag\":31,\"m_sEosUserId\":\"0002ea2c70fa4f89a5d876065a55c786\",\"m_sSteamUserId\":76561197977870267,\"m_uVoiceChatMode\":0,\"m_ePlatform\":2,\"RandomSkinIndex\":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}]",
		simple_net_stub(
			label,
			"Scene_Message.PartyManagement_CreateConnectionTokenFromInvitationCode",
			verbose,
		)
	case PartyManagement_CreateSession_Body:
		simple_server_state.party_create_session = body
		// predict_caleb sent_human_readable t=2026-06-06T01:03:58.819997978Z line=  "sent_human_readable": "Scene_Message handle=143 route=4(partymanagement.createsession) rpc=1 [[\"\", \"matchmaking\", \"\", {}, true, true, false, json:{\"RequestedHero\":3,\"RequestedSkin\":0,\"InLobby\":true,\"PlayerName\":\"Major Hoff\",\"LobbyState\":1,\"UnlockedGameDifficulty\":0,\"MemberDataInitialized\":false,\"UnlockedHeroFlag\":31,\"m_sEosUserId\":\"0002ea2c70fa4f89a5d876065a55c786\",\"m_sSteamUserId\":76561197977870267,\"m_uVoiceChatMode\":0,\"m_ePlatform\":2,\"RandomSkinIndex\":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}]]",
		simple_net_stub(label, "Scene_Message.PartyManagement_CreateSession", verbose)
	case PartyMerging_GetMergerStatus_Body:
		simple_server_state.party_merging_status = body
		// predict_caleb sent_human_readable t=2026-06-06T01:04:11.383956296Z line=  "sent_human_readable": "Scene_Message handle=144 route=16(PartyMerging.GetMergerStatus) rpc=7 [\"default\"] | Scene_Message handle=144 route=4(party.updatepartysettings) rpc=8 [[\"matchmaking\", json:{\"InvitationCode\":\"448157\",\"GameMode\":0,\"GameDifficulty\":0,\"GameModifiers\":[],\"MergerDifficulty\":0}, true, true, \"\", \"\"]]",
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
		simple_net_stub(label, "Scene_Message.UserSession_UpdateUserOptions", verbose)
	}
	return
}
