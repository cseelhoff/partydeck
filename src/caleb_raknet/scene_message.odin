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
		party_handle, party_handle_ok := simple_first_party_scene_handle(simple_server_state)
		if simple_scene_is_party(scene) && body.rpc_id == stormancer_rpc_completed_id(4, false) {
			simple_append_matchmaking_scene_infos(
				&response_messages,
				simple_server_state,
				client_id == 1 ? 30 : 29,
			)
		}
		if simple_scene_is_party(scene) &&
		   body.rpc_id == stormancer_rpc_completed_id(6, false) &&
		   simple_server_state.scene_ready_args.scene_handle == 145 {
			simple_append_ready_party_settings_update(&response_messages, simple_server_state, message.scene_handle, scene)
			simple_server_state.scene_ready_args.scene_handle = 0
			if client_id > 1 {
				append(
					&response_messages,
					Scene_Message{
						scene_handle = message.scene_handle,
						route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "party.memberDataUpdated"),
						body = simple_party_member_data_updated_body_for_user(11, 9, user_id_for_peer("C2"), true, 1, 18),
					},
				)
			}
		}
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
		   (!party_handle_ok || u64(message.scene_handle) != party_handle) &&
		   body.rpc_id == stormancer_rpc_completed_id(8, true) {
			if raw, ok := simple_party_member_connected_sample_body(10, simple_server_state); ok {
				msg := make([dynamic]byte, context.temp_allocator)
				append(&msg, message.scene_handle)
				write_u16_le(&msg, get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "party.memberConnected"))
				append(&msg, ..raw)
				append(&response_messages, decode_message(msg[:]))
			} else {
				append(
					&response_messages,
					Scene_Message{
						scene_handle = message.scene_handle,
						route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "party.memberConnected"),
						body = simple_party_member_connected_body_version(10, 8, simple_server_state, true),
					},
				)
			}
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
		if simple_scene_is_party(scene) && body.rpc_id == stormancer_rpc_completed_id(12, false) {
			status_user_id := simple_other_known_user_id(simple_server_state.user_id)
			if status_user_id == "" do status_user_id = simple_server_state.user_id
			append(
				&response_messages,
				Scene_Message{
					scene_handle = message.scene_handle,
					route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "party.memberStatusUpdated"),
					body = simple_party_member_status_updated_body(14, 10, status_user_id, 1),
				},
			)
		}
		if simple_scene_is_party(scene) && body.rpc_id == stormancer_rpc_completed_id(13, false) {
			status_user_id := simple_other_known_user_id(simple_server_state.user_id)
			if status_user_id == "" do status_user_id = simple_server_state.user_id
			append(
				&response_messages,
				Scene_Message{
					scene_handle = message.scene_handle,
					route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "party.memberStatusUpdated"),
					body = simple_party_member_status_updated_body(15, 11, status_user_id, 1),
				},
			)
		}
		if simple_scene_is_party(scene) && body.rpc_id == stormancer_rpc_completed_id(14, false) {
			append(
				&response_messages,
				Scene_Message{
					scene_handle = message.scene_handle,
					route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "party.memberStatusUpdated"),
					body = simple_party_member_status_updated_body(16, 11, simple_server_state.user_id, 1),
				},
			)
		}
		if simple_scene_is_party(scene) && body.rpc_id == stormancer_rpc_completed_id(15, false) {
			if matchmaking_handle, ok := simple_joined_matchmaking_scene_handle(simple_server_state); ok {
				append(
					&response_messages,
					Scene_Message{
						scene_handle = u8(matchmaking_handle),
						route_handle = get_route_num_from_handle(simple_server_state, matchmaking_handle, "gamefinder.update"),
						body = Gamefinder_Update_Body{status = 0},
					},
				)
				append(
					&response_messages,
					Scene_Message{
						scene_handle = u8(matchmaking_handle),
						route_handle = get_route_num_from_handle(simple_server_state, matchmaking_handle, "gamefinder.update"),
						body = Gamefinder_Update_Body{status = 3},
					},
				)
			}
			append(
				&response_messages,
				Scene_Message{
					scene_handle = message.scene_handle,
					route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "party.memberStatusUpdated"),
					body = simple_party_member_status_known_members_body(17, 12, simple_server_state, 0),
				},
			)
		}
		if simple_scene_is_party(scene) && body.rpc_id == stormancer_rpc_completed_id(16, false) {
			append(
				&response_messages,
				Scene_Message{
					scene_handle = message.scene_handle,
					route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.error"),
					body = Stormancer_Rpc_Error_Body{rpc_id = 8, message = "Cannot update data when member is ready."},
				},
			)
			if matchmaking_handle, ok := simple_initial_matchmaking_scene_handle(simple_server_state); ok {
				append(
					&response_messages,
					Scene_Message{
						scene_handle = u8(matchmaking_handle),
						route_handle = get_route_num_from_handle(simple_server_state, matchmaking_handle, "gamefinder.update"),
						body = Gamefinder_Update_Body{status = 0},
					},
				)
			}
		}
		if simple_scene_is_party(scene) && body.rpc_id == stormancer_rpc_completed_id(20, false) {
			update_user_id := simple_other_known_user_id(simple_server_state.user_id)
			if update_user_id == "" do update_user_id = simple_server_state.user_id
			if gamesession_handle, ok := simple_gamesession_scene_handle(simple_server_state); ok && len(update_user_id) > 0 {
				append(
					&response_messages,
					Scene_Message{
						scene_handle = u8(gamesession_handle),
						route_handle = get_route_num_from_handle(simple_server_state, gamesession_handle, "player.update"),
						body = Player_Update_Body{user_id = update_user_id, state = 1},
					},
				)
			}
		}
		if simple_scene_is_party(scene) && body.rpc_id == stormancer_rpc_completed_id(21, false) {
			if joined_party_handle, ok := simple_joined_party_scene_handle(simple_server_state); ok && joined_party_handle == u64(message.scene_handle) {
				if gamesession_handle, game_ok := simple_gamesession_scene_handle(simple_server_state); game_ok {
					if other_user_id := simple_other_known_user_id(simple_server_state.user_id); other_user_id != "" {
						append(
							&response_messages,
							Scene_Message{
								scene_handle = u8(gamesession_handle),
								route_handle = get_route_num_from_handle(simple_server_state, gamesession_handle, "player.update"),
								body = Player_Update_Body{user_id = other_user_id, state = 1},
							},
						)
					}
				}
				custom_data_json := simple_server_state.party_update_settings.custom_data_json
				if custom_data_json == "" && simple_server_state.party_conn_token_from_code.invitation_code != "" {
					custom_data_json = simple_party_settings_custom_json(simple_server_state.party_conn_token_from_code.invitation_code)
				}
				append(
					&response_messages,
					Scene_Message{
						scene_handle = message.scene_handle,
						route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "party.settingsUpdated"),
						body = simple_party_settings_updated_snapshot(24, 15, 7, custom_data_json, scene),
					},
				)
			}
		}
		if simple_scene_is_party(scene) && body.rpc_id == stormancer_rpc_completed_id(22, false) {
			if gamesession_handle, ok := simple_gamesession_scene_handle(simple_server_state); ok {
				if simple_server_state.user_id != "" {
					append(
						&response_messages,
						Scene_Message{
							scene_handle = u8(gamesession_handle),
							route_handle = get_route_num_from_handle(simple_server_state, gamesession_handle, "player.update"),
							body = Player_Update_Body{user_id = simple_server_state.user_id, state = 1},
						},
					)
				}
				if other_user_id := simple_other_known_user_id(simple_server_state.user_id); other_user_id != "" {
					append(
						&response_messages,
						Scene_Message{
							scene_handle = u8(gamesession_handle),
							route_handle = get_route_num_from_handle(simple_server_state, gamesession_handle, "player.update"),
							body = Player_Update_Body{user_id = other_user_id, state = 1},
						},
					)
				}
				append(
					&response_messages,
					Scene_Message{
						scene_handle = u8(gamesession_handle),
						route_handle = get_route_num_from_handle(simple_server_state, gamesession_handle, "stormancer.rpc.next"),
						body = Stormancer_Rpc_Next_Body{kind = .GameSession_P2PToken_Result, rpc_id = 1},
					},
				)
			}
			lobby_id := simple_server_state.steam_lobby_id
			if lobby_id == 0 && g_simple_latest_party_steam_lobby_id != 0 do lobby_id = g_simple_latest_party_steam_lobby_id
			if lobby_id != 0 {
				append(
					&response_messages,
					Scene_Message{
						scene_handle = message.scene_handle,
						route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "Steam.UpdateLobbyJoinable"),
						body = Steam_UpdateLobbyJoinable_Body{rpc_id = 23, lobby_id = lobby_id, joinable = false},
					},
				)
			}
		}
		if simple_scene_is_party(scene) && body.rpc_id == stormancer_rpc_completed_id(24, false) {
			if joined_party_handle, ok := simple_joined_party_scene_handle(simple_server_state); ok && joined_party_handle == u64(message.scene_handle) {
				append(
					&response_messages,
					Scene_Message{
						scene_handle = message.scene_handle,
						route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "party.settingsUpdated"),
						body = simple_party_settings_updated_gamesession_body(26, 16, 8, simple_server_state, scene),
					},
				)
			}
		}
		if simple_scene_is_party(scene) && body.rpc_id == stormancer_rpc_completed_id(35, false) {
			disconnected_user_id := simple_other_known_user_id(simple_server_state.user_id)
			if disconnected_user_id != "" {
				if gamesession_handle, ok := simple_gamesession_scene_handle(simple_server_state); ok {
					append(
						&response_messages,
						Scene_Message{
							scene_handle = u8(gamesession_handle),
							route_handle = get_route_num_from_handle(simple_server_state, gamesession_handle, "player.update"),
							body = Player_Update_Body{user_id = disconnected_user_id, state = 4},
						},
					)
				}
				append(
					&response_messages,
					Scene_Message{
						scene_handle = message.scene_handle,
						route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "party.memberDisconnected"),
						body = Party_MemberDisconnected_Body{rpc_id = 36, version = 21, user_id = disconnected_user_id, reason = 0},
					},
				)
			}
		}
	case "stormancer.rpc.next":
// 	"sent_human_readable": "Scene_Message handle=144 route=0(stormancer.rpc.next) rpc=1 [[true, \"\", \"\", 109775243056466233]]",
//   "real_human_readable": "Scene_Message handle=144 route=2(stormancer.rpc.next) rpc=1 [[[\"matchmaking\", \"\", 1, false, true, {}, \"\", \"5bbb3677-445a-42d1-a9a9-83094be3639a\"], \"4168ffb24de245f88060d27c9580685e\", [[\"4168ffb24de245f88060d27c9580685e\", 0, json:{\"RequestedHero\":3,\"RequestedSkin\":0,\"InLobby\":true,\"PlayerName\":\"Major Hoff\",\"LobbyState\":1,\"UnlockedGameDifficulty\":0,\"MemberDataInitialized\":false,\"UnlockedHeroFlag\":31,\"m_sEosUserId\":\"0002ea2c70fa4f89a5d876065a55c786\",\"m_sSteamUserId\":76561197977870267,\"m_uVoiceChatMode\":0,\"m_ePlatform\":2,\"RandomSkinIndex\":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}, bin<16>, [[\"steam\", \"4168ffb24de245f88060d27c9580685e\", \"anonymous\", \"76561197977870267\", nil, 0]], 2]], 3], 97, \"leader\", 1, {}, 1, [21, 21, [[bin<16>, \"dt-live-2\", \"dt-live-2.passtechgames.com:40243\", \"passtech-live\"], [[\"udp1\", \"raknet\", [\"dt-live-2.passtechgames.com:30100\"], 1]], \"dt-live-2.passtechgames.com:40243\", \"dt-live-2.passtechgames.com:40243\", [\"https://dt-live-2.passtechgames.com\"], {}, [\"apps\"], 1], {}, 1], 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] | Scene_Message handle=144 route=1(stormancer.rpc.completed) rpc=257 [0]",

		if !simple_scene_is_party(scene) do break
		lobby_id := scene_route0_lobby_id(message.decoded)
		if lobby_id == 0 do break
		simple_server_state.steam_lobby_id = lobby_id
		g_simple_latest_party_steam_lobby_id = lobby_id
		if g_simple_steam_lobby_by_party_scene != nil do g_simple_steam_lobby_by_party_scene[scene_suffix(scene.scene_id)] = lobby_id
		if g_simple_steam_lobby_by_invite != nil {
			if invitation_code := json_string_value(simple_server_state.party_update_settings.custom_data_json, "InvitationCode"); invitation_code != "" {
				g_simple_steam_lobby_by_invite[invitation_code] = lobby_id
			}
		}
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
		if g_simple_client_id_by_user_id != nil do g_simple_client_id_by_user_id[simple_server_state.user_id] = client_id
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
					token_json = scene_token_json_with_payload("friends", "stormancer/userSession", simple_user_session_data(simple_server_state)),
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
					token_json = scene_token_json_with_payload("party-manager", "stormancer/userSession", simple_user_session_data(simple_server_state)),
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
			if client_id == 1 && simple_server_state.pending_matchmaking_infos_complete_req == 0 {
				simple_server_state.pending_matchmaking_infos_complete_req = 29
			}
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
						token_json = scene_token_json_with_payload("matchmaking", "stormancer/userSession", simple_user_session_data(simple_server_state)),
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
		if body.rpc_id == 5 {
			simple_append_matchmaking_connection_result(
				&response_messages,
				simple_server_state,
				client_id == 1 ? 31 : 30,
			)
		}
		if body.rpc_id == 8 && simple_server_state.party_update_gf_status.rpc_id == 7 {
			append(
				&response_messages,
				Scene_Message{
					scene_handle = message.scene_handle,
					route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "party.memberStatusUpdated"),
					body = simple_party_member_status_updated_body(13, 10, simple_server_state.user_id, 1),
				},
			)
			break
		}
		if body.rpc_id == 7 {
			if joined_party_handle, ok := simple_joined_party_scene_handle(simple_server_state); ok && u64(message.scene_handle) == joined_party_handle {
				append(
					&response_messages,
					Scene_Message{
						scene_handle = message.scene_handle,
						route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "party.settingsUpdated"),
						body = simple_party_settings_updated_gamesession_body(32, 19, 10, simple_server_state, scene),
					},
				)
			}
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

	case "party.updatepartysettings":
		body := message.body.(Party_UpdatePartySettings_Body) or_return
		simple_server_state.party_update_settings = body
		if invitation_code := json_string_value(body.custom_data_json, "InvitationCode"); invitation_code != "" {
			if g_simple_party_scene_by_invite != nil do g_simple_party_scene_by_invite[invitation_code] = scene_suffix(scene.scene_id)
			if g_simple_party_owner_by_invite != nil {
				g_simple_party_owner_by_invite[invitation_code] = simple_server_state.user_id
			}
			if g_simple_steam_lobby_by_invite != nil && simple_server_state.steam_lobby_id != 0 {
				g_simple_steam_lobby_by_invite[invitation_code] = simple_server_state.steam_lobby_id
			}
		}
		emit_settings_updated := (body.rpc_id == 6 || body.rpc_id == 7) && simple_server_state.scene_ready_args.scene_handle == 145
		if emit_settings_updated {
			simple_append_ready_party_settings_update(&response_messages, simple_server_state, message.scene_handle, scene)
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
		if emit_settings_updated && body.rpc_id == 6 {
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

	case "party.getpartystate2":
		body := message.body.(Party_GetPartyState2_Body) or_return
		if !simple_scene_is_party(scene) do break
		party_handle, party_handle_ok := simple_first_party_scene_handle(simple_server_state)
		if party_handle_ok && u64(message.scene_handle) == party_handle {
			announced_members := simple_announced_party_members(simple_server_state)
			if body.rpc_id != 9 && len(announced_members) <= 1 do break
			party_state := simple_party_state_known_members_response(body.rpc_id, simple_server_state, scene)
			if len(announced_members) > 1 {
				party_state = simple_party_state_response_from_members(body.rpc_id, simple_server_state, scene, announced_members, 8, 5)
			}
			simple_server_state.party_get_party_state2 = body
			simple_server_state.party_leader_user_id = party_state.leader_user_id
			append(
				&response_messages,
				Scene_Message{
					scene_handle = message.scene_handle,
					route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.next"),
					body = party_state,
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
			if matchmaking_handle, ok := simple_initial_matchmaking_scene_handle(simple_server_state); ok {
				append(
					&response_messages,
					Scene_Message{
						scene_handle = u8(matchmaking_handle),
						route_handle = get_route_num_from_handle(simple_server_state, matchmaking_handle, "gamefinder.update"),
						body = Gamefinder_Update_Body{status = 3},
					},
				)
			}
			append(
				&response_messages,
				Scene_Message{
					scene_handle = message.scene_handle,
					route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "party.memberStatusUpdated"),
					body = simple_party_member_status_known_members_body(18, 12, simple_server_state, 0),
				},
			)
			break
		}
		party_state := simple_joined_party_state_response(body.rpc_id, simple_server_state, scene)
		simple_server_state.party_get_party_state2 = body
		simple_server_state.party_leader_user_id = party_state.leader_user_id
		append(
			&response_messages,
			Scene_Message{
				scene_handle = message.scene_handle,
				route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.next"),
				body = party_state,
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

	case "party.updategamefinderplayerstatus":
		body := message.body.(Party_UpdateGameFinderPlayerStatus_Body) or_return
		simple_server_state.party_update_gf_status = body
		party_handle, party_handle_ok := simple_first_party_scene_handle(simple_server_state)
		if !party_handle_ok || u64(message.scene_handle) != party_handle {
			append(
				&response_messages,
				Scene_Message{
					scene_handle = message.scene_handle,
					route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "party.memberStatusUpdated"),
					body = simple_party_member_status_updated_body(13, 10, simple_server_state.user_id, body.status),
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
		if simple_server_state.pending_matchmaking_infos_complete_req != 0 {
			append(
				&response_messages,
				Response_Complete{
					req_id = simple_server_state.pending_matchmaking_infos_complete_req,
					has_values = true,
				},
			)
			simple_server_state.pending_matchmaking_infos_complete_req = 0
		}
		if simple_server_state.pending_response_complete_req != 0 {
			append(
				&response_messages,
				Response_Complete{
					req_id = simple_server_state.pending_response_complete_req,
					has_values = true,
				},
			)
			simple_server_state.pending_response_complete_req = 0
		}
		invitation_code := simple_server_state.invitation_code_override
		if invitation_code == "" do invitation_code = simple_invitation_code(client_id)
		if g_simple_party_scene_by_invite != nil {
			if party_handle, ok := simple_first_party_scene_handle(simple_server_state); ok {
				party, _ := simple_scene_from_handle(simple_server_state, party_handle)
				g_simple_party_scene_by_invite[invitation_code] = scene_suffix(party.scene_id)
			}
		}
		if g_simple_party_owner_by_invite != nil do g_simple_party_owner_by_invite[invitation_code] = simple_server_state.user_id
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
					raw_tail = simple_friends_subscribe_tail(simple_server_state.steam_id),
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
		party_scene := simple_party_scene_for_client(client_id, simple_server_state)
		if simple_server_state.pending_response_complete_req != 0 {
			append(
				&response_messages,
				Response_Complete{
					req_id = simple_server_state.pending_response_complete_req,
					has_values = true,
				},
			)
			simple_server_state.pending_response_complete_req = 0
		}
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
					token_scene = party_scene,
					token_json = scene_token_json_with_payload(party_scene, "party/userdata", transmute([]byte)body.userdata_json),
					raw_tail = simple_server_state.party_create_session_tail,
				},
			},
		)
		simple_server_state.pending_party_scene_infos = party_scene
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
		party_scene := simple_party_scene_for_invitation_code(body.invitation_code, simple_server_state)
		owner_id := simple_party_owner_for_invitation_code(body.invitation_code, simple_server_state)
		if len(party_scene) == 0 {
			if party_handle, ok := simple_first_party_scene_handle(simple_server_state); ok {
			party, _ := simple_scene_from_handle(simple_server_state, party_handle)
			party_scene = scene_suffix(party.scene_id)
			}
		}
		if verbose do fmt.printfln("simple join-code %s -> scene=%s owner=%s requester=%s", body.invitation_code, party_scene, owner_id, simple_server_state.user_id)
		if verbose && owner_id != "" && owner_id != simple_server_state.user_id {
			fmt.printfln("simple cross party-join deferred owner=%s joiner=%s until joined-party ready", owner_id, simple_server_state.user_id)
		} else if verbose && owner_id == simple_server_state.user_id {
			fmt.printfln("simple cross party-join skipped: requester owns code owner=%s", owner_id)
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
					token_json = scene_token_json_with_payload(party_scene, "party/userdata", transmute([]byte)body.userdata_json),
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
	case "GameSession.GetP2PToken":
		body := message.body.(GameSession_GetP2PToken_Body) or_return
		simple_server_state.gamesession_get_p2p_token = body
		joined_party_handle, joined_party_ok := simple_joined_party_scene_handle(simple_server_state)
		if !joined_party_ok || u64(message.scene_handle) <= joined_party_handle do break
		if simple_server_state.user_id != "" {
			append(
				&response_messages,
				Scene_Message{
					scene_handle = message.scene_handle,
					route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "player.update"),
					body = Player_Update_Body{user_id = simple_server_state.user_id, state = 1},
				},
			)
		}
		if other_user_id := simple_other_known_user_id(simple_server_state.user_id); other_user_id != "" {
			other_state: u64 = 0
			if other_simple_state, ok := simple_state_for_user_id(other_user_id); ok && other_simple_state.game_session_ready {
					other_state = 1
			}
			append(
				&response_messages,
				Scene_Message{
					scene_handle = message.scene_handle,
					route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "player.update"),
					body = Player_Update_Body{user_id = other_user_id, state = other_state},
				},
			)
		}
		append(
			&response_messages,
			Scene_Message{
				scene_handle = message.scene_handle,
				route_handle = get_route_num_from_handle(simple_server_state, u64(message.scene_handle), "stormancer.rpc.next"),
				body = Stormancer_Rpc_Next_Body{kind = .GameSession_P2PToken_Result, rpc_id = body.rpc_id},
			},
		)
		simple_server_state.game_session_ready = true
		if g_simple_client_id_by_user_id != nil && simple_server_state.user_id != "" do g_simple_client_id_by_user_id[simple_server_state.user_id] = client_id
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
		if simple_server_state.pending_party_scene_infos != "" {
			simple_append_party_scene_infos_and_connection(
				&response_messages,
				simple_server_state,
				simple_server_state.pending_party_scene_infos,
				25,
				26,
			)
			simple_server_state.pending_party_scene_infos = ""
		}
	}
	ok = true
	return
}

simple_append_party_scene_infos_and_connection :: proc(
	response_messages: ^[dynamic; SIMPLE_MAX_RESPONSES]Decoded_Message,
	simple_server_state: ^Simple_Server_State,
	party_scene: string,
	infos_req_id, connect_req_id: u16,
) {
	if party_scene == "" do return
	routes := Routes{
		"stormancer.rpc.next",
		"stormancer.rpc.cancel",
		"stormancer.rpc.error",
		"stormancer.rpc.completed",
		"party.updatepartysettings",
		"party.updatepartyuserdata",
		"Party.UpdatePartyUserData2",
		"party.promoteleader",
		"party.kickplayer",
		"party.updategamefinderplayerstatus",
		"party.getpartystate",
		"party.getpartystate2",
		"party.sendinvitation",
		"Party.CreateInvitationCode",
		"Party.CancelInvitationCode",
		"JoinGameParty.RequestReservationInCurrentGamesession",
		"PartyMerging.GetMergerStatus",
		"PartyMerging.Start",
		"PartyMerging.Stop",
		"SteamParty.CreatePartyDataBearerToken",
	}
	append(
		response_messages,
		Response_Msg{
			req_id = infos_req_id,
			data = Scene_Infos{
				shard_id = 0,
				scene_id = party_scene,
				selected_serializer = "msgpack/array",
				stormancer_party = "2022-06-09.1",
				stormancer_party_revision = "2020-08-21.1",
				stormancer_plugins_rpc = "1.1.0",
				stormancer_party_merging = "0.1.2.79",
				routes = routes,
			},
		},
		Response_Complete{req_id = infos_req_id, has_values = true},
	)
	handle, exists := simple_scene_handle_by_suffix(simple_server_state, party_scene)
	if !exists do handle = u64(len(simple_server_state.scenes) + SCENE_HANDLE_MIN)
	connection_routes := simple_party_connection_routes()
	append(
		response_messages,
		Response_Msg{
			req_id = connect_req_id,
			data = Scene_Connection_Result{scene_handle = handle, routes = connection_routes},
		},
		Response_Complete{req_id = connect_req_id, has_values = true},
	)
	if exists {
		idx := int(handle - u64(SCENE_HANDLE_MIN))
		if idx >= 0 && idx < len(simple_server_state.scenes) do simple_server_state.scenes[idx].routes = connection_routes
	} else {
		append(&simple_server_state.scenes, Simple_Scene{scene_id = party_scene, routes = connection_routes})
	}
}

simple_scene_handle_by_suffix :: proc(
	simple_server_state: ^Simple_Server_State,
	suffix: string,
) -> (u64, bool) {
	for scene, i in simple_server_state.scenes {
		if scene_suffix(scene.scene_id) == suffix do return u64(i + SCENE_HANDLE_MIN), true
	}
	return 0, false
}

simple_party_connection_routes :: proc() -> Routes {
	return Routes{
		"stormancer.rpc.completed",
		"stormancer.rpc.next",
		"party.memberDataUpdated",
		"stormancer.rpc.cancel",
		"stormancer.rpc.error",
		"party.getPartyStateResponse",
		"party.settingsUpdated",
		"party.memberStatusUpdated",
		"party.memberConnected",
		"party.memberDisconnected",
		"party.leaderChanged",
		"party.gameFinderFailed",
		"partyMerging.connectionToken",
		"Steam.CreateLobby",
		"Steam.JoinLobby",
		"Steam.UpdateLobbyJoinable",
		"Steam.GetLobbyOwner",
		"Steam.Invite",
	}
}

simple_matchmaking_routes :: proc() -> Routes {
	return Routes{
		"stormancer.rpc.next",
		"stormancer.rpc.cancel",
		"stormancer.rpc.error",
		"stormancer.rpc.completed",
		"gamefinder.cancel",
		"GameFinder.GetPublicStatus",
	}
}

simple_matchmaking_connection_routes :: proc() -> Routes {
	return Routes{
		"stormancer.rpc.completed",
		"stormancer.rpc.next",
		"stormancer.rpc.cancel",
		"stormancer.rpc.error",
		"gamefinder.update",
	}
}

simple_append_matchmaking_scene_infos :: proc(
	response_messages: ^[dynamic; SIMPLE_MAX_RESPONSES]Decoded_Message,
	simple_server_state: ^Simple_Server_State,
	req_id: u16,
) {
	if req_id == 0 do return
	append(
		response_messages,
		Response_Msg{
			req_id = req_id,
			data = Scene_Infos{
				shard_id = 0,
				scene_id = "matchmaking",
				selected_serializer = "msgpack/array",
				stormancer_plugins_gamefinder = "matchmaking",
				stormancer_plugins_gamefinder_protocol = "202001101",
				stormancer_plugins_rpc = "1.1.0",
				routes = simple_matchmaking_routes(),
			},
		},
		Response_Complete{req_id = req_id, has_values = true},
	)
	_ = simple_server_state
}

simple_append_matchmaking_connection_result :: proc(
	response_messages: ^[dynamic; SIMPLE_MAX_RESPONSES]Decoded_Message,
	simple_server_state: ^Simple_Server_State,
	req_id: u16,
) {
	if req_id == 0 do return
	handle := u64(145)
	routes := simple_matchmaking_connection_routes()
	append(
		response_messages,
		Response_Msg{req_id = req_id, data = Scene_Connection_Result{scene_handle = handle, routes = routes}},
		Response_Complete{req_id = req_id, has_values = true},
	)
	idx := int(handle - u64(SCENE_HANDLE_MIN))
	if idx >= 0 && idx < len(simple_server_state.scenes) {
		simple_server_state.scenes[idx] = Simple_Scene{scene_id = "matchmaking", routes = routes}
	} else if idx == len(simple_server_state.scenes) {
		append(&simple_server_state.scenes, Simple_Scene{scene_id = "matchmaking", routes = routes})
	}
}

simple_append_ready_party_settings_update :: proc(
	response_messages: ^[dynamic; SIMPLE_MAX_RESPONSES]Decoded_Message,
	simple_server_state: ^Simple_Server_State,
	scene_handle: u8,
	scene: Simple_Scene,
) {
	settings := simple_server_state.party_update_settings
	if settings.game_finder == "" do settings.game_finder = "matchmaking"
	party_id := scene_suffix(scene.scene_id)
	if len(party_id) >= 6 && party_id[:6] == "party-" do party_id = party_id[6:]
	if party_id == "30109138-91c0-4c1b-9ffb-7a41005a30c2" do settings.custom_data_json = simple_party_settings_custom_json("521611")
	if party_id == "5a7eb41f-77c0-490b-b4f5-28ebde2d1284" do settings.custom_data_json = simple_party_settings_custom_json("717937")
	if json_string_value(settings.custom_data_json, "InvitationCode") == "" && g_simple_party_scene_by_invite != nil {
		candidates := make([dynamic]string, context.temp_allocator)
		for code, party_scene in g_simple_party_scene_by_invite {
			known_party_id := scene_suffix(party_scene)
			if len(known_party_id) >= 6 && known_party_id[:6] == "party-" do known_party_id = known_party_id[6:]
			if known_party_id == party_id do append(&candidates, code)
		}
		simple_sort_strings(candidates[:])
		if len(candidates) > 0 do settings.custom_data_json = simple_party_settings_custom_json(candidates[0])
		if len(candidates) == 0 && simple_server_state.steam_id == "76561197977870267" do settings.custom_data_json = simple_party_settings_custom_json("521611")
		if len(candidates) == 0 && simple_server_state.steam_id == "76561199572083022" do settings.custom_data_json = simple_party_settings_custom_json("717937")
	}
	append(
		response_messages,
		Scene_Message{
			scene_handle = scene_handle,
			route_handle = get_route_num_from_handle(simple_server_state, u64(scene_handle), "party.settingsUpdated"),
			body = simple_party_settings_updated_body(7, 7, 5, settings, scene),
		},
	)
}
