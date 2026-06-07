package caleb_raknet

import "core:encoding/hex"
import "core:fmt"
import "core:slice"
import "core:strings"

Simple_Scene :: struct {
	scene_id: string,
	routes:   Routes,
}

simple_scene_from_handle :: proc(
	simple_server_state: ^Simple_Server_State,
	scene_handle: u64,
) -> (Simple_Scene, bool) {
	if scene_handle < u64(SCENE_HANDLE_MIN) do return {}, false
	scene_index := scene_handle - u64(SCENE_HANDLE_MIN)
	if scene_index >= u64(len(simple_server_state.scenes)) do return {}, false
	return simple_server_state.scenes[scene_index], true
}

simple_scene_has_route :: proc(scene: Simple_Scene, route_name: string) -> bool {
	for route in scene.routes {
		if route == route_name do return true
	}
	return false
}

simple_scene_is_party :: proc(scene: Simple_Scene) -> bool {
	scene_id := scene_suffix(scene.scene_id)
	return scene_id != "party-manager" && len(scene_id) >= 6 && scene_id[:6] == "party-"
}

simple_first_party_scene_handle :: proc(simple_server_state: ^Simple_Server_State) -> (u64, bool) {
	for scene, scene_index in simple_server_state.scenes {
		if simple_scene_is_party(scene) do return u64(scene_index + SCENE_HANDLE_MIN), true
	}
	return 0, false
}

simple_joined_party_scene_handle :: proc(simple_server_state: ^Simple_Server_State) -> (u64, bool) {
	first_handle, first_ok := simple_first_party_scene_handle(simple_server_state)
	for scene, scene_index in simple_server_state.scenes {
		handle := u64(scene_index + SCENE_HANDLE_MIN)
		if simple_scene_is_party(scene) && (!first_ok || handle != first_handle) do return handle, true
	}
	return 0, false
}

simple_initial_matchmaking_scene_handle :: proc(simple_server_state: ^Simple_Server_State) -> (u64, bool) {
	first_party_handle, first_party_ok := simple_first_party_scene_handle(simple_server_state)
	for scene, scene_index in simple_server_state.scenes {
		handle := u64(scene_index + SCENE_HANDLE_MIN)
		if scene_suffix(scene.scene_id) == "matchmaking" && (!first_party_ok || handle > first_party_handle) do return handle, true
	}
	return 0, false
}

simple_joined_matchmaking_scene_handle :: proc(simple_server_state: ^Simple_Server_State) -> (u64, bool) {
	joined_party_handle, joined_party_ok := simple_joined_party_scene_handle(simple_server_state)
	for scene, scene_index in simple_server_state.scenes {
		handle := u64(scene_index + SCENE_HANDLE_MIN)
		if scene_suffix(scene.scene_id) == "matchmaking" && (!joined_party_ok || handle > joined_party_handle) do return handle, true
	}
	return 0, false
}

simple_gamesession_scene_handle :: proc(simple_server_state: ^Simple_Server_State) -> (u64, bool) {
	for scene, scene_index in simple_server_state.scenes {
		suffix := scene_suffix(scene.scene_id)
		if looks_uuid(suffix) || strings.has_prefix(suffix, "gamesession") do return u64(scene_index + SCENE_HANDLE_MIN), true
	}
	return 0, false
}

simple_scene_client_route_name :: proc(scene: Simple_Scene, route_handle: u16) -> string {
	routes := simple_scene_client_routes(scene_suffix(scene.scene_id))
	if route_handle >= u16(len(routes)) do return ""
	return routes[route_handle]
}

simple_scene_client_routes :: proc(scene_id: string) -> Routes {
	if scene_id == "authenticator" {
		return Routes{
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
	if scene_id == "friends" {
		return Routes{
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
	if scene_id == "party-manager" || scene_id == "party" {
		return Routes{
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
	if scene_id == "matchmaking" {
		return Routes{
			"stormancer.rpc.next",
			"stormancer.rpc.cancel",
			"stormancer.rpc.error",
			"stormancer.rpc.completed",
			"gamefinder.cancel",
			"GameFinder.GetPublicStatus",
		}
	}
	if looks_uuid(scene_id) || strings.has_prefix(scene_id, "gamesession") {
		return Routes{
			"stormancer.rpc.next",
			"stormancer.rpc.cancel",
			"stormancer.rpc.error",
			"stormancer.rpc.completed",
			"player.ready",
			"player.faulted",
			"DtGameSession.GetConnectionInfosForPlayer",
			"gamesession.postresults",
			"GameSession.GetP2PToken",
			"gamesession.reset",
			"gamesession.updateshutdownmode",
			"gamesession.getgamesessionsettings",
			"GameSession.GetGameSessionConnectionUrl",
			"GameSession.GetTeams",
			"GameSession.CreateP2PToken",
		}
	}
	if len(scene_id) >= 6 && scene_id[:6] == "party-" {
		return Routes{
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
	}
	return {}
}

get_route_num_from_handle :: proc(
	simple_server_state: ^Simple_Server_State,
	scene_handle: u64,
	route_name_query: string,
) -> u16 {
	scene, ok := simple_scene_from_handle(simple_server_state, scene_handle)
	assert(ok, "scene not found")
	for route, route_index in scene.routes {
		if route == route_name_query do return u16(route_index + 1)
	}
	fmt.eprintfln("route not found scene=%s handle=%d route=%s", scene.scene_id, scene_handle, route_name_query)
	assert(false, "route not found")
	return 0
}

simple_party_data_token_json :: proc(simple_server_state: ^Simple_Server_State, scene: Simple_Scene, allocator := context.allocator) -> string {
	party_id := scene_suffix(scene.scene_id)
	if len(party_id) >= 6 && party_id[:6] == "party-" do party_id = party_id[6:]
	return strings.concatenate(
		{
			`{"PartyId":"`,
			party_id,
			`","LeaderUserId":"`,
			simple_server_state.user_id,
			`","LeaderSteamId":`,
			simple_server_state.steam_id,
			`}`,
		},
		allocator,
	)
}

stormancer_rpc_completed_id :: proc(rpc_id: u16, sent_next: bool) -> u16 {
	return (rpc_id << 8) + (sent_next ? u16(1) : u16(0))
}

simple_invitation_code :: proc(client_id: int, allocator := context.allocator) -> string {
	return fmt.aprintf("%06d", client_id, allocator = allocator)
}

simple_party_state_response :: proc(
	rpc_id: u16,
	simple_server_state: ^Simple_Server_State,
	scene: Simple_Scene,
	allocator := context.allocator,
) -> Party_State_Response_Body {
	party_id := scene_suffix(scene.scene_id)
	if len(party_id) >= 6 && party_id[:6] == "party-" do party_id = party_id[6:]
	members := make([dynamic]Party_State_Member, allocator)
	append(&members, simple_party_member(simple_server_state, false, allocator))
	return Party_State_Response_Body {
		rpc_id = rpc_id,
		settings = Scene_Party_Settings {
			game_finder = "matchmaking",
			custom_data_json = "",
			revision = 1,
			only_leader_invite = false,
			is_joinable = true,
			public_data = "",
			party_id = party_id,
		},
		leader_user_id = simple_server_state.user_id,
		members = members[:],
		revision = 3,
	}
}

simple_party_state_known_members_response :: proc(
	rpc_id: u16,
	simple_server_state: ^Simple_Server_State,
	scene: Simple_Scene,
	allocator := context.allocator,
) -> Party_State_Response_Body {
	party_id := scene_suffix(scene.scene_id)
	if len(party_id) >= 6 && party_id[:6] == "party-" do party_id = party_id[6:]
	custom_data_json := simple_server_state.party_update_settings.custom_data_json
	if custom_data_json == "" && simple_server_state.party_conn_token_from_code.invitation_code != "" {
		custom_data_json = simple_party_settings_custom_json(simple_server_state.party_conn_token_from_code.invitation_code, allocator)
	}
	members := make([dynamic]Party_State_Member, allocator)
	if g_simple_state_by_user_id != nil {
		others := make([dynamic]string, allocator)
		for user_id, _ in g_simple_state_by_user_id {
			if user_id != "" && user_id != simple_server_state.user_id do append(&others, user_id)
		}
		simple_sort_strings(others[:])
		for user_id in others {
			if member, ok := simple_known_party_member(user_id, true, allocator); ok do append(&members, member)
		}
	}
	if len(members) == 0 && g_simple_user_ids_by_steam != nil {
		fallback := make([dynamic]string, allocator)
		for _, user_id in g_simple_user_ids_by_steam {
			if user_id != "" && user_id != simple_server_state.user_id do append(&fallback, user_id)
		}
		simple_sort_strings(fallback[:])
		for user_id in fallback {
			if member, ok := simple_known_party_member(user_id, true, allocator); ok do append(&members, member)
		}
	}
	if simple_server_state.user_id != "" do append(&members, simple_party_member(simple_server_state, false, allocator))
	if len(members) == 0 do append(&members, simple_party_member(simple_server_state, false, allocator))
	return Party_State_Response_Body{
		rpc_id = rpc_id,
		settings = Scene_Party_Settings{
			game_finder = "matchmaking",
			custom_data_json = custom_data_json,
			revision = 5,
			only_leader_invite = false,
			is_joinable = true,
			public_data = "",
			party_id = party_id,
		},
		leader_user_id = simple_server_state.user_id,
		members = members[:],
		revision = 11,
	}
}

simple_joined_party_state_response :: proc(
	rpc_id: u16,
	simple_server_state: ^Simple_Server_State,
	scene: Simple_Scene,
	allocator := context.allocator,
) -> Party_State_Response_Body {
	invitation_code := simple_server_state.party_conn_token_from_code.invitation_code
	custom_data_json := ""
	if invitation_code != "" do custom_data_json = simple_party_settings_custom_json(invitation_code, allocator)

	owner_id := ""
	if invitation_code != "" && g_simple_party_owner_by_invite != nil {
		if known_owner, ok := g_simple_party_owner_by_invite[invitation_code]; ok do owner_id = known_owner
	}
	if owner_id == "" && g_simple_state_by_user_id != nil {
		for known_user_id, _ in g_simple_state_by_user_id {
			if known_user_id != simple_server_state.user_id {
				owner_id = known_user_id
				break
			}
		}
	}
	if owner_id == "" do owner_id = simple_other_known_user_id(simple_server_state.user_id)
	if owner_id == "" do owner_id = simple_server_state.user_id

	members := make([dynamic]Party_State_Member, allocator)
	owner_appended := false
	if owner_id != "" && g_simple_state_by_user_id != nil {
		if owner_state, ok := g_simple_state_by_user_id[owner_id]; ok {
			append(&members, simple_party_member(owner_state, false, allocator))
			owner_appended = true
		}
	}
	if !owner_appended && owner_id != "" {
		if owner_member, ok := simple_known_party_member(owner_id, true, allocator); ok {
			append(&members, owner_member)
			owner_appended = true
		}
	}
	if simple_server_state.user_id != owner_id do append(&members, simple_party_member(simple_server_state, false, allocator))
	if len(members) == 0 do append(&members, simple_party_member(simple_server_state, false, allocator))

	party_id := scene_suffix(scene.scene_id)
	if len(party_id) >= 6 && party_id[:6] == "party-" do party_id = party_id[6:]
	return Party_State_Response_Body {
		rpc_id = rpc_id,
		settings = Scene_Party_Settings {
			game_finder = "matchmaking",
			custom_data_json = custom_data_json,
			revision = 5,
			only_leader_invite = false,
			is_joinable = true,
			public_data = "",
			party_id = party_id,
		},
		leader_user_id = owner_id,
		members = members[:],
		revision = 8,
	}
}

simple_other_known_user_id :: proc(user_id: string) -> string {
	if g_simple_state_by_user_id != nil {
		known := make([dynamic]string, context.temp_allocator)
		for known_user_id, _ in g_simple_state_by_user_id {
			if known_user_id != "" && known_user_id != user_id do append(&known, known_user_id)
		}
		simple_sort_strings(known[:])
		if len(known) > 0 do return known[0]
	}
	if g_simple_user_ids_by_steam != nil {
		known := make([dynamic]string, context.temp_allocator)
		for _, known_user_id in g_simple_user_ids_by_steam {
			if known_user_id != "" && known_user_id != user_id do append(&known, known_user_id)
		}
		simple_sort_strings(known[:])
		if len(known) > 0 do return known[0]
	}
	return ""
}

simple_known_party_member :: proc(
	user_id: string,
	initialized: bool,
	allocator := context.allocator,
) -> (Party_State_Member, bool) {
	return simple_known_party_member_with_lobby_state(user_id, initialized, 1, allocator)
}

simple_known_party_member_with_lobby_state :: proc(
	user_id: string,
	initialized: bool,
	lobby_state: int,
	allocator := context.allocator,
) -> (Party_State_Member, bool) {
	steam_id := simple_steam_id_for_user_id(user_id)
	if steam_id == "" do return {}, false
	userdata_json := simple_party_userdata_json_for_steam_lobby_state(steam_id, initialized, lobby_state, allocator)
	platforms := make([dynamic]Scene_Platform_Identity, allocator)
	append(&platforms, Scene_Platform_Identity {
		provider = "steam",
		user_id = user_id,
		visibility = "anonymous",
		platform_id = steam_id,
		extra = "",
		extra_is_nil = true,
		flags = 0,
	})
	session_token := simple_party_session_token_for_steam(steam_id, allocator)
	return Party_State_Member {
		user_id = user_id,
		connection_state = 0,
		userdata_json = userdata_json,
		userdata = parse_party_member_userdata(userdata_json),
		session_token_hex = string(hex.encode(session_token, allocator)),
		platforms = platforms[:],
		state = 2,
	}, true
}

simple_steam_id_for_user_id :: proc(user_id: string) -> string {
	if g_simple_user_ids_by_steam != nil {
		for steam_id, known_user_id in g_simple_user_ids_by_steam {
			if known_user_id == user_id do return steam_id
		}
	}
	return ""
}

simple_party_session_token_for_steam :: proc(steam_id: string, allocator := context.allocator) -> []byte {
	out := make([]byte, 16, allocator)
	seed: u8 = 0x11
	if len(steam_id) > 0 do seed = steam_id[len(steam_id) - 1]
	for i in 0 ..< len(out) do out[i] = seed + u8(i)
	return out
}

simple_party_userdata_json_for_steam :: proc(
	steam_id: string,
	initialized: bool,
	allocator := context.allocator,
) -> string {
	return simple_party_userdata_json_for_steam_lobby_state(steam_id, initialized, 1, allocator)
}

simple_party_userdata_json_for_steam_lobby_state :: proc(
	steam_id: string,
	initialized: bool,
	lobby_state: int,
	allocator := context.allocator,
) -> string {
	hero := 1
	player_name := simple_friend_pseudo(steam_id)
	unlocked_hero_flag := simple_unlocked_hero_flag(steam_id)
	eos_user_id := simple_eos_user_id(steam_id)
	hero_text := fmt.aprintf("%d", hero, allocator = allocator)
	flag_text := fmt.aprintf("%d", unlocked_hero_flag, allocator = allocator)
	lobby_state_text := fmt.aprintf("%d", lobby_state, allocator = allocator)
	return strings.concatenate(
		{
			`{"RequestedHero":`,
			hero_text,
			`,"RequestedSkin":0,"InLobby":true,"PlayerName":"`,
			player_name,
			`","LobbyState":`,
			lobby_state_text,
			`,"UnlockedGameDifficulty":0,"MemberDataInitialized":`,
			initialized ? "true" : "false",
			`,"UnlockedHeroFlag":`,
			flag_text,
			`,"m_sEosUserId":"`,
			eos_user_id,
			`","m_sSteamUserId":`,
			steam_id,
			`,"m_uVoiceChatMode":0,"m_ePlatform":2,"RandomSkinIndex":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}`,
		},
		allocator,
	)
}

simple_party_settings_updated_snapshot :: proc(
	rpc_id: u16,
	version: u64,
	settings_revision: u64,
	custom_data_json: string,
	scene: Simple_Scene,
) -> Party_SettingsUpdated_Body {
	party_id := scene_suffix(scene.scene_id)
	if len(party_id) >= 6 && party_id[:6] == "party-" do party_id = party_id[6:]
	return Party_SettingsUpdated_Body {
		rpc_id = rpc_id,
		version = version,
		settings = Scene_Party_Settings {
			game_finder = "matchmaking",
			custom_data_json = custom_data_json,
			revision = settings_revision,
			only_leader_invite = false,
			is_joinable = true,
			public_data = "",
			party_id = party_id,
		},
	}
}

simple_party_settings_updated_gamesession_body :: proc(
	rpc_id: u16,
	version: u64,
	settings_revision: u64,
	simple_server_state: ^Simple_Server_State,
	scene: Simple_Scene,
) -> Party_SettingsUpdated_Body {
	party_id := scene_suffix(scene.scene_id)
	if len(party_id) >= 6 && party_id[:6] == "party-" do party_id = party_id[6:]
	invitation_code := ""
	if g_simple_party_scene_by_invite != nil {
		candidates := make([dynamic]string, context.temp_allocator)
		for code, party_scene in g_simple_party_scene_by_invite {
			known_party_id := scene_suffix(party_scene)
			if len(known_party_id) >= 6 && known_party_id[:6] == "party-" do known_party_id = known_party_id[6:]
			if known_party_id == party_id do append(&candidates, code)
		}
		simple_sort_strings(candidates[:])
		if len(candidates) > 0 do invitation_code = candidates[0]
	}
	if invitation_code == "" do invitation_code = json_string_value(simple_server_state.party_update_settings.custom_data_json, "InvitationCode")
	if invitation_code == "" do invitation_code = simple_server_state.party_conn_token_from_code.invitation_code
	custom_data_json := ""
	if invitation_code != "" do custom_data_json = simple_party_settings_custom_json(invitation_code)
	if custom_data_json == "" do custom_data_json = simple_server_state.party_update_settings.custom_data_json
	game_session_id := ""
	if gamesession_handle, ok := simple_gamesession_scene_handle(simple_server_state); ok {
		if gamesession_scene, scene_ok := simple_scene_from_handle(simple_server_state, gamesession_handle); scene_ok {
			game_session_id = scene_suffix(gamesession_scene.scene_id)
		}
	}
	return Party_SettingsUpdated_Body{
		rpc_id = rpc_id,
		version = version,
		settings = Scene_Party_Settings{
			game_finder = "matchmaking",
			custom_data_json = custom_data_json,
			revision = settings_revision,
			only_leader_invite = false,
			is_joinable = false,
			server_status = "gamesession",
			server_status_details = game_session_id,
			public_data = "",
			party_id = party_id,
		},
	}
}

simple_party_settings_custom_json :: proc(invitation_code: string, allocator := context.allocator) -> string {
	return strings.concatenate(
		{
			`{"InvitationCode":"`,
			invitation_code,
			`","GameMode":0,"GameDifficulty":0,"GameModifiers":[],"MergerDifficulty":0}`,
		},
		allocator,
	)
}

simple_party_member_data_updated_body :: proc(
	rpc_id: u16,
	version: u64,
	simple_server_state: ^Simple_Server_State,
	initialized: bool,
	allocator := context.allocator,
) -> Party_MemberDataUpdated_Body {
	state_member := simple_party_member(simple_server_state, true, allocator)
	if initialized {
		state_member.userdata_json = simple_party_userdata_json(simple_server_state, true, allocator)
		state_member.userdata = parse_party_member_userdata(state_member.userdata_json)
	}
	return Party_MemberDataUpdated_Body {
		rpc_id = rpc_id,
		version = version,
		member = Scene_Party_Member_Data {
			user_id = state_member.user_id,
			userdata_json = state_member.userdata_json,
			userdata = state_member.userdata,
			platforms = state_member.platforms,
			state = state_member.state,
		},
	}
}

simple_party_member_data_updated_body_with_lobby_state :: proc(
	rpc_id: u16,
	version: u64,
	simple_server_state: ^Simple_Server_State,
	initialized: bool,
	lobby_state: int,
	tail_zero_count: int,
	allocator := context.allocator,
) -> Party_MemberDataUpdated_Body {
	state_member := simple_party_member(simple_server_state, true, allocator)
	state_member.userdata_json = simple_party_userdata_json_with_lobby_state(simple_server_state, initialized, lobby_state, allocator)
	state_member.userdata = parse_party_member_userdata(state_member.userdata_json)
	return simple_party_member_data_updated_from_state(rpc_id, version, state_member, tail_zero_count, allocator)
}

simple_party_member_data_updated_body_for_user :: proc(
	rpc_id: u16,
	version: u64,
	user_id: string,
	initialized: bool,
	lobby_state: int,
	tail_zero_count: int,
	allocator := context.allocator,
) -> Party_MemberDataUpdated_Body {
	member, ok := simple_known_party_member_with_lobby_state(user_id, initialized, lobby_state, allocator)
	if !ok do return Party_MemberDataUpdated_Body{rpc_id = rpc_id, version = version}
	return simple_party_member_data_updated_from_state(rpc_id, version, member, tail_zero_count, allocator)
}

simple_party_member_data_updated_from_state :: proc(
	rpc_id: u16,
	version: u64,
	state_member: Party_State_Member,
	tail_zero_count: int,
	allocator := context.allocator,
) -> Party_MemberDataUpdated_Body {
	return Party_MemberDataUpdated_Body {
		rpc_id = rpc_id,
		version = version,
		member = Scene_Party_Member_Data {
			user_id = state_member.user_id,
			userdata_json = state_member.userdata_json,
			userdata = state_member.userdata,
			platforms = state_member.platforms,
			state = state_member.state,
		},
		tail_values = simple_member_data_zero_tail(tail_zero_count, allocator),
	}
}

simple_member_data_zero_tail :: proc(count: int, allocator := context.allocator) -> []Party_MemberData_Tail_Value {
	values := make([dynamic]Party_MemberData_Tail_Value, allocator)
	for _ in 0 ..< count do append(&values, Party_MemberData_Tail_Value{kind = .Uint, uint_value = 0})
	return values[:]
}

simple_party_settings_updated_body :: proc(
	rpc_id: u16,
	version: u64,
	settings_revision: u64,
	update: Party_UpdatePartySettings_Body,
	scene: Simple_Scene,
) -> Party_SettingsUpdated_Body {
	party_id := scene_suffix(scene.scene_id)
	if len(party_id) >= 6 && party_id[:6] == "party-" do party_id = party_id[6:]
	return Party_SettingsUpdated_Body {
		rpc_id = rpc_id,
		version = version,
		settings = Scene_Party_Settings {
			game_finder = update.game_finder,
			custom_data_json = update.custom_data_json,
			revision = settings_revision,
			only_leader_invite = false,
			is_joinable = update.is_joinable,
			public_data = update.public_data,
			party_id = party_id,
		},
	}
}

simple_party_merging_status_result :: proc(
	rpc_id: u16,
	allocator := context.allocator,
) -> PartyMerging_GetMergerStatus_Result_Body {
	party_counts := make([dynamic]PartyMerging_Difficulty_Count, allocator)
	append(&party_counts, PartyMerging_Difficulty_Count{difficulty = "2", count = 2})
	append(&party_counts, PartyMerging_Difficulty_Count{difficulty = "3", count = 1})

	player_counts := make([dynamic]PartyMerging_Difficulty_Count, allocator)
	append(&player_counts, PartyMerging_Difficulty_Count{difficulty = "2", count = 6})
	append(&player_counts, PartyMerging_Difficulty_Count{difficulty = "3", count = 1})

	return PartyMerging_GetMergerStatus_Result_Body {
		rpc_id = rpc_id,
		status = 1,
		parties_count = 3,
		algorithm = "DtPartyMergerAlgorithm",
		players_count = 7,
		nb_parties_by_difficulty = party_counts[:],
		nb_players_by_difficulty = player_counts[:],
	}
}

simple_party_member :: proc(
	simple_server_state: ^Simple_Server_State,
	platform_committed: bool,
	allocator := context.allocator,
) -> Party_State_Member {
	userdata_json := simple_server_state.party_create_session.userdata_json
	if len(userdata_json) == 0 do userdata_json = simple_party_userdata_json(simple_server_state, false, allocator)
	platforms := make([dynamic]Scene_Platform_Identity, allocator)
	append(&platforms, Scene_Platform_Identity {
		provider = "steam",
		user_id = simple_server_state.user_id,
		visibility = "anonymous",
		platform_id = simple_server_state.steam_id,
		extra = "",
		extra_is_nil = !platform_committed,
		flags = 0,
	})
	session_token := simple_party_session_token(simple_server_state, allocator)
	return Party_State_Member {
		user_id = simple_server_state.user_id,
		connection_state = 0,
		userdata_json = userdata_json,
		userdata = parse_party_member_userdata(userdata_json),
		session_token_hex = string(hex.encode(session_token, allocator)),
		platforms = platforms[:],
		state = 2,
	}
}

simple_party_member_connected_body :: proc(
	rpc_id: u16,
	simple_server_state: ^Simple_Server_State,
	initialized: bool,
	allocator := context.allocator,
) -> Party_MemberConnected_Body {
	state_member := simple_party_member(simple_server_state, false, allocator)
	if initialized {
		state_member.userdata_json = simple_party_userdata_json(simple_server_state, true, allocator)
		state_member.userdata = parse_party_member_userdata(state_member.userdata_json)
	}
	return Party_MemberConnected_Body {
		rpc_id = rpc_id,
		version = 2,
		member = Scene_Party_Member_Connected {
			user_id = state_member.user_id,
			connection_state = state_member.connection_state,
			userdata_json = state_member.userdata_json,
			userdata = state_member.userdata,
			session_token = simple_party_session_token(simple_server_state, allocator),
			platforms = state_member.platforms,
			state = state_member.state,
		},
	}
}

simple_party_member_status_updated_body :: proc(
	rpc_id: u16,
	version: u64,
	user_id: string,
	status: u64,
	allocator := context.allocator,
) -> Party_MemberStatusUpdated_Body {
	members := make([dynamic]Scene_Party_Member_Status, allocator)
	append(&members, Scene_Party_Member_Status{user_id = user_id, status = status})
	return Party_MemberStatusUpdated_Body{
		rpc_id = rpc_id,
		version = version,
		members = members[:],
	}
}

simple_party_member_status_pair_updated_body :: proc(
	rpc_id: u16,
	version: u64,
	user_a: string,
	status_a: u64,
	user_b: string,
	status_b: u64,
	allocator := context.allocator,
) -> Party_MemberStatusUpdated_Body {
	members := make([dynamic]Scene_Party_Member_Status, allocator)
	append(&members, Scene_Party_Member_Status{user_id = user_a, status = status_a})
	append(&members, Scene_Party_Member_Status{user_id = user_b, status = status_b})
	return Party_MemberStatusUpdated_Body{
		rpc_id = rpc_id,
		version = version,
		members = members[:],
	}
}

simple_party_member_status_known_members_body :: proc(
	rpc_id: u16,
	version: u64,
	simple_server_state: ^Simple_Server_State,
	status: u64,
	allocator := context.allocator,
) -> Party_MemberStatusUpdated_Body {
	user_ids := make([dynamic]string, allocator)
	if simple_server_state.user_id != "" do append(&user_ids, simple_server_state.user_id)
	if g_simple_state_by_user_id != nil {
		others := make([dynamic]string, allocator)
		for user_id, _ in g_simple_state_by_user_id {
			if user_id != "" && user_id != simple_server_state.user_id do append(&others, user_id)
		}
		simple_sort_strings(others[:])
		for user_id in others do append(&user_ids, user_id)
	}
	if len(user_ids) < 2 && g_simple_user_ids_by_steam != nil {
		fallback := make([dynamic]string, allocator)
		for _, user_id in g_simple_user_ids_by_steam {
			if user_id != "" && !simple_string_in_slice(user_id, user_ids[:]) do append(&fallback, user_id)
		}
		simple_sort_strings(fallback[:])
		for user_id in fallback {
			if !simple_string_in_slice(user_id, user_ids[:]) do append(&user_ids, user_id)
		}
	}

	members := make([dynamic]Scene_Party_Member_Status, allocator)
	for user_id in user_ids do append(&members, Scene_Party_Member_Status{user_id = user_id, status = status})
	return Party_MemberStatusUpdated_Body{
		rpc_id = rpc_id,
		version = version,
		members = members[:],
	}
}

simple_string_in_slice :: proc(needle: string, values: []string) -> bool {
	for value in values {
		if value == needle do return true
	}
	return false
}

simple_party_session_token :: proc(simple_server_state: ^Simple_Server_State, allocator := context.allocator) -> []byte {
	return simple_party_session_token_for_steam(simple_server_state.steam_id, allocator)
}

simple_party_userdata_json :: proc(
	simple_server_state: ^Simple_Server_State,
	initialized: bool,
	allocator := context.allocator,
) -> string {
	return simple_party_userdata_json_with_lobby_state(simple_server_state, initialized, 1, allocator)
}

simple_party_userdata_json_with_lobby_state :: proc(
	simple_server_state: ^Simple_Server_State,
	initialized: bool,
	lobby_state: int,
	allocator := context.allocator,
) -> string {
	userdata := simple_server_state.party_create_session.userdata
	hero := userdata.requested_hero
	if hero == 0 do hero = 1
	player_name := userdata.player_name
	if len(player_name) == 0 do player_name = simple_friend_pseudo(simple_server_state.steam_id)
	unlocked_hero_flag := userdata.unlocked_hero_flag
	if unlocked_hero_flag == 0 do unlocked_hero_flag = simple_unlocked_hero_flag(simple_server_state.steam_id)
	eos_user_id := userdata.eos_user_id
	if len(eos_user_id) == 0 do eos_user_id = simple_eos_user_id(simple_server_state.steam_id)
	hero_text := fmt.aprintf("%d", hero, allocator = allocator)
	flag_text := fmt.aprintf("%d", unlocked_hero_flag, allocator = allocator)
	lobby_state_text := fmt.aprintf("%d", lobby_state, allocator = allocator)
	return strings.concatenate(
		{
			`{"RequestedHero":`,
			hero_text,
			`,"RequestedSkin":0,"InLobby":true,"PlayerName":"`,
			player_name,
			`","LobbyState":`,
			lobby_state_text,
			`,"UnlockedGameDifficulty":0,"MemberDataInitialized":`,
			initialized ? "true" : "false",
			`,"UnlockedHeroFlag":`,
			flag_text,
			`,"m_sEosUserId":"`,
			eos_user_id,
			`","m_sSteamUserId":`,
			simple_server_state.steam_id,
			`,"m_uVoiceChatMode":0,"m_ePlatform":2,"RandomSkinIndex":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}`,
		},
		allocator,
	)
}

simple_unlocked_hero_flag :: proc(steam_id: string) -> int {
	if steam_id == "76561199572083022" do return 15
	return 31
}

simple_eos_user_id :: proc(steam_id: string) -> string {
	if steam_id == "76561199572083022" do return "000239105cf443abbdf0238c827bd9e8"
	return "0002ea2c70fa4f89a5d876065a55c786"
}

steam_id_from_login_ticket :: proc(ticket: string, allocator := context.allocator) -> string {
	data, ok := hex.decode(transmute([]byte)ticket, allocator)
	if !ok || len(data) < 20 do return ""
	defer delete(data, allocator)
	return fmt.aprintf("%d", read_u64_le(data, 12), allocator = allocator)
}
