package caleb_raknet

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

	case System_Request_Id.Scene_Ready2:
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
				scene_handle = len(simple_server_state.scenes) + SCENE_HANDLE_MIN,
                routes = args.routes,
            },
        }, Response_Complete {
			req_id = message.req_id,
			has_values = true,
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
