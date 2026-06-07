package caleb_raknet

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
		// predict_caleb sent_human_readable t=2026-06-06T01:03:54.547386728Z line=  "sent_human_readable": "Scene_Message handle=141 route=6(Authentication.Login) rpc=1 [[\"steam\", {\"gameVersion.clientVersion\": \"1.05.00.05\", \"provider\": \"steam\", \"ticket\": \"140000004F316731E9C817C7BB9F0C0101001001C24E236A180000000100000005000000C7D1724E00372436898F5A0AB9000000B20000003200000004000000BB9F0C0101001001F09A1F00A7599BB88101010A00000000BC531B6A3C03376A010059C2100000000000BA6E72D9F085C7D5CD2628D22C0C0D67544C6D4C162CA664248F076E7D4D8A1CED297A86B596A9A28B2CAF53E1FC7E91B8D486F59399B96EC6C110FED6589A3B49E0846268CCC94B17B81FEAF04BB0B0DC23263FFEEA5B70A43A1FA6CC3427AF84EC70F53AFED224AE327149656DEB25CDA05E87CDF2677BA0\", \"version\": \"v1\", \"appId\": \"2071280\"}]]",
		response_messages = get_response_from_scene_message(client_id, label, request_message, verbose, simple_server_state) or_return
	}
	ok = true
	return
}
