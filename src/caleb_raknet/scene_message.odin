package caleb_raknet

import "core:fmt"

get_response_from_scene_message :: proc(
	client_id: int,
	label: string,
	raw_message: Scene_Message,
	verbose: bool,
	simple_server_state: ^Simple_Server_State,
) -> (
	response_messages: [dynamic; SIMPLE_MAX_RESPONSES]Decoded_Message,
	ok: bool,
) {
	scene, scene_ok := simple_scene_from_handle(simple_server_state, u64(raw_message.scene_handle))
	if !scene_ok do return
	route := simple_scene_client_route_name(scene, raw_message.route_handle)
	if route == "" do return
	typed_message := scene_message_with_route_body(raw_message, route)
	message := typed_message.(Scene_Message) or_return
	switch route {
	case "stormancer.rpc.completed":
		body := message.body.(Stormancer_Rpc_Completed_Body) or_return
		if simple_scene_is_party(scene) && body.rpc_id == stormancer_rpc_completed_id(1, true) {
			append(
				&response_messages,
				Scene_Message{
					scene_handle = message.scene_handle,
					route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "party.memberConnected"),
					body = simple_party_member_connected_body(2, simple_server_state, false),
				},
			)
		}
		if simple_scene_is_party(scene) &&
		   body.rpc_id == stormancer_rpc_completed_id(7, false) &&
		   simple_server_state.party_member_connected_after_settings_ack {
			simple_server_state.party_member_connected_after_settings_ack = false
			append(
				&response_messages,
				Scene_Message{
					scene_handle = message.scene_handle,
					route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "party.memberConnected"),
					body = simple_party_member_connected_body(10, simple_server_state, true),
				},
			)
		}
	case "stormancer.rpc.next":
// 	"sent_human_readable": "Scene_Message handle=144 route=0(stormancer.rpc.next) rpc=1 [[true, \"\", \"\", 109775243056466233]]",
//   "real_human_readable": "Scene_Message handle=144 route=2(stormancer.rpc.next) rpc=1 [[[\"matchmaking\", \"\", 1, false, true, {}, \"\", \"5bbb3677-445a-42d1-a9a9-83094be3639a\"], \"4168ffb24de245f88060d27c9580685e\", [[\"4168ffb24de245f88060d27c9580685e\", 0, json:{\"RequestedHero\":3,\"RequestedSkin\":0,\"InLobby\":true,\"PlayerName\":\"Major Hoff\",\"LobbyState\":1,\"UnlockedGameDifficulty\":0,\"MemberDataInitialized\":false,\"UnlockedHeroFlag\":31,\"m_sEosUserId\":\"0002ea2c70fa4f89a5d876065a55c786\",\"m_sSteamUserId\":76561197977870267,\"m_uVoiceChatMode\":0,\"m_ePlatform\":2,\"RandomSkinIndex\":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}, bin<16>, [[\"steam\", \"4168ffb24de245f88060d27c9580685e\", \"anonymous\", \"76561197977870267\", nil, 0]], 2]], 3], 97, \"leader\", 1, {}, 1, [21, 21, [[bin<16>, \"dt-live-2\", \"dt-live-2.passtechgames.com:40243\", \"passtech-live\"], [[\"udp1\", \"raknet\", [\"dt-live-2.passtechgames.com:30100\"], 1]], \"dt-live-2.passtechgames.com:40243\", \"dt-live-2.passtechgames.com:40243\", [\"https://dt-live-2.passtechgames.com\"], {}, [\"apps\"], 1], {}, 1], 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] | Scene_Message handle=144 route=1(stormancer.rpc.completed) rpc=257 [0]",

		if !simple_scene_is_party(scene) do break
		append(
			&response_messages,
			Scene_Message{
				scene_handle = message.scene_handle,
				route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.next"),
				body = simple_party_state_response(message.decoded.rpc_id, simple_server_state, scene),
			},
		)
		append(
			&response_messages,
			Scene_Message{
				scene_handle = message.scene_handle,
				route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
				body = Stormancer_Rpc_Completed_Body{
					rpc_id = stormancer_rpc_completed_id(message.decoded.rpc_id, true),
					message_sent = true,
				},
			},
		)
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
					rpc_id = stormancer_rpc_completed_id(body.rpc_id, true),
                    message_sent = true,
                }
            }
        )

	case "Locator.GetSceneConnectionToken":
		body := message.body.(Locator_GetSceneConnectionToken_Body) or_return
		if body.scene_type == "stormancer.friends" {
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
					rpc_id = stormancer_rpc_completed_id(body.rpc_id, true),
                    message_sent = true,
                },
            }
		)
		} else if body.scene_type == "stormancer.plugins.partyManagement" {
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
					rpc_id = stormancer_rpc_completed_id(body.rpc_id, true),
					message_sent = true,
				},
			},
		)
		} else if body.scene_type == "stormancer.plugins.gamefinder" && body.scene_id == "matchmaking" {
			//  "sent_human_readable": "Scene_Message handle=141 route=19(Locator.GetSceneConnectionToken) rpc=5 [\"stormancer.plugins.gamefinder\", \"matchmaking\"]",
 // "real_human_readable": "Scene_Message handle=141 route=2(stormancer.rpc.next) body=2045B rpc=5 [json:{\"token\":\"i6lBY2NvdW50SWSpZGFya3RhbGVzq0FwcGxpY2F0aW9urGxpdmUtMS0wNS0wMKZJc3N1ZWTX/7pMI4BqI3IFqkV4cGlyYXRpb27X/7pMJqBqI3MxqFVzZXJEYXRhxQITAAACD5mSpXN0ZWFtsTc2NTYxMTk3OTc3ODcwMjY3mNkgNDE2OGZmYjI0ZGUyNDVmODgwNjBkMjdjOTU4MDY4NWWBpXN0ZWFtgadzdGVhbWlksTc2NTYxMTk3OTc3ODcwMjY3g6Zwc2V1ZG\\u002BqTWFqb3IgSG9mZqdvcHRpb25zgaljcm9zc3BsYXmBp2VuYWJsZWTDp3N0ZWFtaWSxNzY1NjExOTc5Nzc4NzAyNjfX/zgATcBqG1ZR1/84AE3AahtWUYClc3RlYW3AxBCYrdv8V8IZTqk1\\u002BOfjDw/GgaVzdGVhbbdzdGVhbTo3NjU2MTE5Nzk3Nzg3MDI2N4Orc3RlYW0uYXBwSWTEBPCaHwC5Z2FtZVZlcnNpb24uY2xpZW50VmVyc2lvbsQPAAAAC6oxLjA1LjAwLjA1pXBhcnR5xCoAAAAm2SQ1YmJiMzY3Ny00NDVhLTQyZDEtYTlhOS04MzA5NGJlMzYzOWHX/\\u002BpbXIBqI3H62ZtzY2VuZTovcGFzc3RlY2gtbGl2ZS8vZGFya3RhbGVzL2xpdmUtMS0wNS0wMC8yNTY0ZDhiZS0yZGJiLTQ5NjctYjZiYi0wZTE1N2FhN2Y2M2YvMT8vYXV0aGVudGljYXRvciNhdXRoZW50aWNhdG9yLzAoKylbMmUwOTU2ZTEtOTQzZi00YTRlLWEwYjMtMWI4NmQ5MDYwMDliXcAAq0NvbnRlbnRUeXBltnN0b3JtYW5jZXIvdXNlclNlc3Npb26pRW5kcG9pbnRzwKdTY2VuZUlk2TdzY2VuZTovcGFzc3RlY2gtbGl2ZS9kYXJrdGFsZXMvbGl2ZS0xLTA1LTAwL21hdGNobWFraW5np1JvdXRpbmfArERlcGxveW1lbnRJZNkkMjU2NGQ4YmUtMmRiYi00OTY3LWI2YmItMGUxNTdhYTdmNjNmp1ZlcnNpb24C-4OD/uqf6iqFl4oIJ3e5l9Is0YjTESBzihVngy3/U5Fg=\",\"endpoints\":{\"raknet\":[\"dt-live.passtechgames.com:30100\",\"dt-live-2.passtechgames.com:30100\"]},\"encryption\":{\"algorithm\":\"aes256\",\"mode\":\"GCM\",\"key\":\"9lAzhMAh8cjPz99dZe0hawuiLagVBjBrvLolpaeCzws=\",\"token\":\"xBDnDQaJoyQZS435Ce47IdMpHtTrAW6/UdhGQt8o2OGRk50wiW\\u002BsdHxQ7bgq1qw0uTiEgdXl4edJtoxWJkurEjEU9UjD6ygSFXw=\"}}] +579B raw 000000d033c06ff07f0000e005a265b3... | Scene_Message handle=141 route=1(stormancer.rpc.completed) rpc=1281 [0]",
			append(
				&response_messages,
				Scene_Message{
					scene_handle = message.scene_handle,
					route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.next"),
					body = Stormancer_Rpc_Next_Body{
						rpc_id = body.rpc_id,
						kind = .Scene_Connection_Token,
						token_scene = "matchmaking",
						token_json = scene_token_json("matchmaking"),
					},
				},
			)
			append(
				&response_messages,
				Scene_Message{
					scene_handle = message.scene_handle,
					route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
					body = Stormancer_Rpc_Completed_Body{
						rpc_id = stormancer_rpc_completed_id(body.rpc_id, true),
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
				rpc_id = stormancer_rpc_completed_id(body.rpc_id, false),
                message_sent = true,
            }
        })

	case "Party.UpdatePartyUserData2":
		body := message.body.(Party_UpdatePartyUserData2_Body) or_return
		simple_server_state.party_update_user_data2 = body
		append(
			&response_messages,
			Scene_Message{
				scene_handle = message.scene_handle,
				route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
				body = Stormancer_Rpc_Completed_Body{
					rpc_id = stormancer_rpc_completed_id(body.rpc_id, false),
					message_sent = true,
				},
			},
		)

	case "party.updatepartysettings":
		body := message.body.(Party_UpdatePartySettings_Body) or_return
		simple_server_state.party_update_settings = body
		emit_settings_updated := body.rpc_id == 6 && simple_server_state.scene_ready_args.scene_handle == 145
		if emit_settings_updated {
			append(
				&response_messages,
				Scene_Message{
					scene_handle = message.scene_handle,
					route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "party.settingsUpdated"),
					body = simple_party_settings_updated_body(
						body.rpc_id + 1,
						u64(body.rpc_id + 1),
						u64(body.rpc_id - 1),
						body,
						scene,
					),
				},
			)
		}
		append(
			&response_messages,
			Scene_Message{
				scene_handle = message.scene_handle,
				route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
				body = Stormancer_Rpc_Completed_Body{
					rpc_id = stormancer_rpc_completed_id(body.rpc_id, false),
					message_sent = true,
				},
			},
		)
		if emit_settings_updated {
			append(
				&response_messages,
				Scene_Message{
					scene_handle = message.scene_handle,
					route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "party.settingsUpdated"),
					body = simple_party_settings_updated_body(
						body.rpc_id + 2,
						u64(body.rpc_id + 2),
						u64(body.rpc_id + 1),
						body,
						scene,
					),
				},
			)
		}
		if emit_settings_updated do simple_server_state.scene_ready_args.scene_handle = 0

	case "PartyMerging.GetMergerStatus":
		body := message.body.(PartyMerging_GetMergerStatus_Body) or_return
		simple_server_state.party_merging_status = body
		append(
			&response_messages,
			Scene_Message{
				scene_handle = message.scene_handle,
				route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.next"),
				body = simple_party_merging_status_result(body.rpc_id),
			},
		)
		append(
			&response_messages,
			Scene_Message{
				scene_handle = message.scene_handle,
				route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
				body = Stormancer_Rpc_Completed_Body{
					rpc_id = stormancer_rpc_completed_id(body.rpc_id, true),
					message_sent = true,
				},
			},
		)

	case "Party.CreateInvitationCode":
		body := message.body.(Party_CreateInvitationCode_Body) or_return
		simple_server_state.party_create_invitation = body
		invitation_code := simple_invitation_code(client_id)
		if g_simple_party_scene_by_invite != nil {
			if party_handle, ok := simple_first_party_scene_handle(simple_server_state); ok {
				party, _ := simple_scene_from_handle(simple_server_state, party_handle)
				g_simple_party_scene_by_invite[invitation_code] = scene_suffix(party.scene_id)
			}
		}
		append(
			&response_messages,
			Scene_Message{
				scene_handle = message.scene_handle,
				route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.next"),
				body = Party_CreateInvitationCode_Result_Body{
					rpc_id = body.rpc_id,
					invitation_code = invitation_code,
				},
			},
		)
		append(
			&response_messages,
			Scene_Message{
				scene_handle = message.scene_handle,
				route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
				body = Stormancer_Rpc_Completed_Body{
					rpc_id = stormancer_rpc_completed_id(body.rpc_id, true),
					message_sent = true,
				},
			},
		)


	case "Friends.Subscribe":
		body := message.body.(Friends_Subscribe_Body) or_return
		simple_server_state.friends_subscribe = body
// 		  "sent_human_readable": "Scene_Message handle=142 route=5(Friends.Subscribe) rpc=1 []",
//   "real_human_readable": "Scene_Message handle=142 route=1(friends.notification) [[[0, [[[\"stormancer\", \"9fe2fc1fa18643e2818bbd65198d4b00\"], [\"steam\", \"76561199572083022\"]], {\"stormancer\": 0}, [\"recentlyMet\"], json:{\n  \"userId\": \"9fe2fc1fa18643e2818bbd65198d4b00\",\n  \"lastPlatform\": \"steam\",\n  \"platforms\": {\n    \"steam\": {\n      \"steamid\": 76561199572083022\n    }\n  },\n  \"crossplay\": {\n    \"Enabled\": true\n  },\n  \"pseudo\": \"elsie\"\n}], 1780707838914]], \"^#\\xe22:7,\\\"Rando\", 109, 83, 107, 105, 110, 73, 110, 100, 101, 120, 34, 58, 91, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 44, 48, 93, 125, [[\"xboxlive\", \"96bf824424eb4444b486e783f237e86f\", \"anonymous\", \"RETAIL:2535436566179448\", \"\", 0]], 2, 0, 97, 121, 0] | Scene_Message handle=142 route=2(stormancer.rpc.completed) rpc=256 [0]",
		friends := simple_friends_for_steam_id(simple_server_state.steam_id)
		append(
			&response_messages,
			Scene_Message{
				scene_handle = message.scene_handle,
				route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "friends.notification"),
				body = Friends_Notification_Body {
					friends = friends,
					timestamp = server_time_ms(),
				},
			},
		)
		append(&response_messages, Scene_Message {
			scene_handle = message.scene_handle,
			route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
			body = Stormancer_Rpc_Completed_Body {
				rpc_id = stormancer_rpc_completed_id(body.rpc_id, false),
				message_sent = true,
			}
		})

	case "partymanagement.createsession":
		body := message.body.(PartyManagement_CreateSession_Body) or_return
		simple_server_state.party_create_session = body
//   "sent_human_readable": "Scene_Message handle=143 route=4(partymanagement.createsession) rpc=1 [[\"\", \"matchmaking\", \"\", {}, true, true, false, json:{\"RequestedHero\":3,\"RequestedSkin\":0,\"InLobby\":true,\"PlayerName\":\"Major Hoff\",\"LobbyState\":1,\"UnlockedGameDifficulty\":0,\"MemberDataInitialized\":false,\"UnlockedHeroFlag\":31,\"m_sEosUserId\":\"0002ea2c70fa4f89a5d876065a55c786\",\"m_sSteamUserId\":76561197977870267,\"m_uVoiceChatMode\":0,\"m_ePlatform\":2,\"RandomSkinIndex\":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}]]",
//   "real_human_readable": "Scene_Message handle=143 route=2(stormancer.rpc.next) rpc=1 [json:{\"token\":\"i6lBY2NvdW50SWSpZGFya3RhbGVzq0FwcGxpY2F0aW9urGxpdmUtMS0wNS0wMKZJc3N1ZWTX/\\u002BwFPxBqI3H\\u002BqkV4cGlyYXRpb27X/\\u002BwFQKBqI3MqqFVzZXJEYXRhxQF6eyJSZXF1ZXN0ZWRIZXJvIjozLCJSZXF1ZXN0ZWRTa2luIjowLCJJbkxvYmJ5Ijp0cnVlLCJQbGF5ZXJOYW1lIjoiTWFqb3IgSG9mZiIsIkxvYmJ5U3RhdGUiOjEsIlVubG9ja2VkR2FtZURpZmZpY3VsdHkiOjAsIk1lbWJlckRhdGFJbml0aWFsaXplZCI6ZmFsc2UsIlVubG9ja2VkSGVyb0ZsYWciOjMxLCJtX3NFb3NVc2VySWQiOiIwMDAyZWEyYzcwZmE0Zjg5YTVkODc2MDY1YTU1Yzc4NiIsIm1fc1N0ZWFtVXNlcklkIjo3NjU2MTE5Nzk3Nzg3MDI2NywibV91Vm9pY2VDaGF0TW9kZSI6MCwibV9lUGxhdGZvcm0iOjIsIlJhbmRvbVNraW5JbmRleCI6WzAsMCwwLDAsMCwwLDAsMCwwLDAsMCwwLDAsMCwwLDAsMCwwLDAsMCwwLDAsMCwwLDAsMCwwLDAsMCwwLDAsMF19q0NvbnRlbnRUeXBlrnBhcnR5L3VzZXJkYXRhqUVuZHBvaW50c8CnU2NlbmVJZNlWc2NlbmU6L3Bhc3N0ZWNoLWxpdmUvZGFya3RhbGVzL2xpdmUtMS0wNS0wMC9wYXJ0eS01YmJiMzY3Ny00NDVhLTQyZDEtYTlhOS04MzA5NGJlMzYzOWGnUm91dGluZ8CsRGVwbG95bWVudElk2SQyNTY0ZDhiZS0yZGJiLTQ5NjctYjZiYi0wZTE1N2FhN2Y2M2anVmVyc2lvbgI=-y5VzHtKC\\u002BKnrwGogKxORjWH0KuOtxDJYnSr3D35g1xI=\",\"endpoints\":{\"raknet\":[\"dt-live.passtechgames.com:30100\",\"dt-live-2.passtechgames.com:30100\"]},\"encryption\":{\"algorithm\":\"aes256\",\"mode\":\"GCM\",\"key\":\"9Xn3Pg/Z/7oScHtjgghiAnhT3ii6UqtuahNh/fz6T4g=\",\"token\":\"xBDnDQaJoyQZS435Ce47IdMpGQsi4pQh/fpwMzemwvTzGy/LDzHe420pXA6uwY5jKuiKB2CFgUUeCD4P/GXM\\u002BEhyumPm5\\u002Bsxzbc=\"}}, 78, 97, 109, 101, \"UserSession.GetUserOptions\", \"Handle\", 14, \"Metadata\", {\"stormancer.plugins.rpc\": \"1.1.0\"}, {\"Name\": \"UserSession.UpdateUserOptions\", \"Handle\": 15, \"Metadata\": {\"stormancer.plugins.rpc\": \"1.1.0\"}}, {\"Name\": \"NX.GetAdvertisedParties\", \"Handle\": 16, \"Metadata\": {\"stormancer.plugins.rpc\": \"1.1.0\"}}, {\"Name\": \"Steam.QueryUserIds\", \"Handle\": 17, \"Metadata\": {\"stormancer.plugins.rpc\": \"1.1.0\"}}, {\"Name\": \"Steam.DecodePartyDataBearerTokens\", \"Handle\": 18, \"Metadata\": {\"stormancer.plugins.rpc\": \"1.1.0\"}}, {\"Name\": \"Locator.GetSceneConnectionToken\", \"Handle\": 19, \"Metadata\": {\"stormancer.plugins.rpc\": \"1.1.0\"}}, \"SelectedSerializer\", \"msgpack/array\", 97, 99, 53, 51, 102, 54, 48, 48, 100, 101, 56, 100, 52, 57, 51, 97, 56, 48, 53, 99, 99, 50, 57, 53, 54, 55, 98, 97, 97, 100, 51, 52, nil, -32, 24, -18, 98, \"\\u007f\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x18o\\x9el\\xf0\\u007f\\x00\\x00\", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -32, 111, [108, -16, 127, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], 0, 0, 0, 0, 0, 0, 0, 24, 88, \"f\\xf0\", 127, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 56, {[91, \"\\u007f\\x00\\x00\\x00\\x00\\x00\\x00\\x94\\x00\\x00\\x00\\x94\\x00\\x00\\x00\\x00\\x01\\x00\\x00\", 0, 0, 1, 0, 0, 0, 0]: 0, 0: 0, 0: 0, 0: 0, 0: 0}, 0, 0, 0, 0, 0, 0, 0, 0, -32, 23, 23, 103, -16, 127, 0, 0, ext(125)<16>, 0, 0, 0, 0, 0, 0, 72, 120, [91, \"\\u007f\\x00\\x00p\\x8e\\nh\\xb0\\u007f\\x00\\x00\\xf0x\\x99[\\xb3\\u007f\\x00\\x00\", 0, 0, 0, 0, 0, 0, 0], 0] | Scene_Message handle=143 route=1(stormancer.rpc.completed) rpc=257 [0]",
  
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
					rpc_id = stormancer_rpc_completed_id(body.rpc_id, true),
					message_sent = true,
				},
			},
		)
	case "PartyManagement.CreateConnectionTokenFromInvitationCode":
		body := message.body.(PartyManagement_CreateConnectionTokenFromInvitationCode_Body) or_return
		simple_server_state.party_conn_token_from_code = body
		party_scene := ""
		if g_simple_party_scene_by_invite != nil {
			if known_scene, ok := g_simple_party_scene_by_invite[body.invitation_code]; ok do party_scene = known_scene
		}
		if len(party_scene) == 0 {
			if party_handle, ok := simple_first_party_scene_handle(simple_server_state); ok {
			party, _ := simple_scene_from_handle(simple_server_state, party_handle)
			party_scene = scene_suffix(party.scene_id)
			}
		}
		append(
			&response_messages,
			Scene_Message{
				scene_handle = message.scene_handle,
				route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.next"),
				body = Stormancer_Rpc_Next_Body {
					rpc_id = body.rpc_id,
					kind = .Scene_Connection_Token,
					token_scene = party_scene,
					token_json = scene_token_json(party_scene),
				},
			},
		)
		append(
			&response_messages,
			Scene_Message{
				scene_handle = message.scene_handle,
				route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.completed"),
				body = Stormancer_Rpc_Completed_Body {
					rpc_id = stormancer_rpc_completed_id(body.rpc_id, true),
					message_sent = true,
				},
			},
		)
	case "Friends.UpdateFriendList":
		body := message.body.(Friends_UpdateFriendList_Body) or_return
		simple_server_state.friends_update_friend_list = body
		//   "sent_human_readable": "Scene_Message handle=142 route=4(Friends.UpdateFriendList) [[[0, [[[\"steam\", \"76561197977870267\"]], {\"steam\": 2}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Major Hoff\"},\"pseudo\":\"Major Hoff\"}], 1967872675680]]]",
		//   "real_human_readable": "Scene_Message handle=142 route=1(friends.notification) [[[0, [[[\"steam\", \"76561197977870267\"], [\"stormancer\", \"4168ffb24de245f88060d27c9580685e\"]], {\"stormancer\": 2, \"steam\": 2}, [\"steam\"], json:{ \"steam\":{ \"personaName\":\"Major Hoff\"},\"pseudo\":\"Major Hoff\"}], 1967872675680]]]",
		friends := simple_friends_for_steam_id(simple_server_state.steam_id)
		append(
			&response_messages,
			Scene_Message{
				scene_handle = message.scene_handle,
				route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "friends.notification"),
				body = Friends_Notification_Body {
					friends = friends,
					timestamp = server_time_ms(),
				},
			},
		)
	}
	ok = true
	return
}
