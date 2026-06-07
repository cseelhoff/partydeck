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

simple_invitation_client_id :: proc(invitation_code: string) -> (int, bool) {
	client_id := 0
	if invitation_code == "" do return 0, false
	for ch in transmute([]byte)invitation_code {
		if ch < '0' || ch > '9' do return 0, false
		client_id = client_id * 10 + int(ch - '0')
	}
	if client_id <= 0 || client_id >= len(g_server_state) do return 0, false
	return client_id, true
}

simple_state_for_user_id :: proc(user_id: string) -> (^Simple_Server_State, bool) {
	if user_id == "" || g_simple_client_id_by_user_id == nil do return nil, false
	client_id, ok := g_simple_client_id_by_user_id[user_id]
	if !ok || client_id <= 0 || client_id >= len(g_server_state) do return nil, false
	return &g_server_state[client_id], true
}

simple_state_for_party_scene :: proc(party_scene: string) -> (^Simple_Server_State, bool) {
	if party_scene == "" do return nil, false
	for client_id in 1 ..< len(g_server_state) {
		state := &g_server_state[client_id]
		if party_handle, ok := simple_first_party_scene_handle(state); ok {
			party, _ := simple_scene_from_handle(state, party_handle)
			if scene_suffix(party.scene_id) == party_scene do return state, true
		}
	}
	return nil, false
}

simple_party_scene_for_client :: proc(
	client_id: int,
	simple_server_state: ^Simple_Server_State,
	allocator := context.allocator,
) -> string {
	if simple_server_state.user_id != "" && len(simple_server_state.user_id) >= 32 {
		user_id := simple_server_state.user_id
		return strings.concatenate(
			{
				"party-",
				user_id[0:8], "-",
				user_id[8:12], "-",
				user_id[12:16], "-",
				user_id[16:20], "-",
				user_id[20:32],
			},
			allocator,
		)
	}
	return fmt.aprintf("party-%08d-0000-4000-8000-%012d", client_id, client_id, allocator = allocator)
}

simple_party_owner_for_invitation_code :: proc(
	invitation_code: string,
	requester: ^Simple_Server_State,
) -> string {
	if invitation_code != "" && g_simple_party_owner_by_invite != nil {
		if owner_id, ok := g_simple_party_owner_by_invite[invitation_code]; ok && owner_id != "" do return owner_id
	}
	if owner_client_id, ok := simple_invitation_client_id(invitation_code); ok {
		owner_state := &g_server_state[owner_client_id]
		if owner_state.user_id != "" do return owner_state.user_id
	}
	if g_simple_client_id_by_user_id != nil {
		owners := make([dynamic]string, context.temp_allocator)
		for user_id, _ in g_simple_client_id_by_user_id {
			if user_id != "" && user_id != requester.user_id do append(&owners, user_id)
		}
		simple_sort_strings(owners[:])
		if len(owners) > 0 do return owners[0]
	}
	return ""
}

simple_party_scene_for_invitation_code :: proc(
	invitation_code: string,
	requester: ^Simple_Server_State,
	allocator := context.allocator,
) -> string {
	if invitation_code != "" && g_simple_party_scene_by_invite != nil {
		if party_scene, ok := g_simple_party_scene_by_invite[invitation_code]; ok && party_scene != "" do return party_scene
	}
	owner_id := simple_party_owner_for_invitation_code(invitation_code, requester)
	if owner_id != "" {
		if owner_state, ok := simple_state_for_user_id(owner_id); ok {
			if party_handle, party_ok := simple_first_party_scene_handle(owner_state); party_ok {
				party, _ := simple_scene_from_handle(owner_state, party_handle)
				return scene_suffix(party.scene_id)
			}
		}
	}
	if owner_client_id, ok := simple_invitation_client_id(invitation_code); ok {
		return simple_party_scene_for_client(owner_client_id, &g_server_state[owner_client_id], allocator)
	}
	return ""
}

simple_party_state_response :: proc(
	rpc_id: u16,
	simple_server_state: ^Simple_Server_State,
	scene: Simple_Scene,
	allocator := context.allocator,
) -> Party_State_Response_Body {
	if len(simple_server_state.user_id) > 0 {
		members := simple_announced_party_members(simple_server_state, allocator)
		if len(members) > 1 {
			return simple_party_state_response_from_members(rpc_id, simple_server_state, scene, members, 8, 5, allocator)
		}
	}
	party_id := scene_suffix(scene.scene_id)
	if len(party_id) >= 6 && party_id[:6] == "party-" do party_id = party_id[6:]
	members := make([dynamic]Party_State_Member, allocator)
	append(&members, simple_party_member(simple_server_state, false, allocator))
	return simple_party_state_response_from_members(rpc_id, simple_server_state, scene, members[:], 3, 1, allocator)
}

simple_party_state_response_from_members :: proc(
	rpc_id: u16,
	simple_server_state: ^Simple_Server_State,
	scene: Simple_Scene,
	members: []Party_State_Member,
	party_revision: u64,
	settings_revision: u64,
	allocator := context.allocator,
) -> Party_State_Response_Body {
	party_id := scene_suffix(scene.scene_id)
	if len(party_id) >= 6 && party_id[:6] == "party-" do party_id = party_id[6:]
	custom_data_json := simple_server_state.party_update_settings.custom_data_json
	return Party_State_Response_Body {
		rpc_id = rpc_id,
		settings = Scene_Party_Settings {
			game_finder = "matchmaking",
			custom_data_json = custom_data_json,
			revision = settings_revision,
			only_leader_invite = false,
			is_joinable = true,
			public_data = "",
			party_id = party_id,
		},
		leader_user_id = simple_server_state.user_id,
		members = members,
		revision = party_revision,
	}
}

simple_announced_party_members :: proc(
	simple_server_state: ^Simple_Server_State,
	allocator := context.allocator,
) -> []Party_State_Member {
	members := make([dynamic]Party_State_Member, allocator)
	if simple_server_state.user_id != "" do append(&members, simple_party_member(simple_server_state, false, allocator))
	if g_simple_party_join_announced != nil && simple_server_state.user_id != "" {
		joiners := make([dynamic]string, allocator)
		prefix := strings.concatenate({simple_server_state.user_id, "|"}, allocator)
		for key, announced in g_simple_party_join_announced {
			if !announced || !strings.has_prefix(key, prefix) do continue
			joiner_id := key[len(prefix):]
			if joiner_id != "" do append(&joiners, joiner_id)
		}
		simple_sort_strings(joiners[:])
		for joiner_id in joiners {
			if joiner_state, ok := simple_state_for_user_id(joiner_id); ok {
				append(&members, simple_party_member(joiner_state, false, allocator))
			} else if member, known := simple_known_party_member(joiner_id, true, allocator); known {
				append(&members, member)
			}
		}
	}
	return members[:]
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
	if g_simple_client_id_by_user_id != nil {
		others := make([dynamic]string, allocator)
		for user_id, _ in g_simple_client_id_by_user_id {
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
	if owner_id == "" && g_simple_client_id_by_user_id != nil {
		for known_user_id, _ in g_simple_client_id_by_user_id {
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
	if owner_id != "" {
		if owner_state, ok := simple_state_for_user_id(owner_id); ok {
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
	if g_simple_client_id_by_user_id != nil {
		known := make([dynamic]string, context.temp_allocator)
		for known_user_id, _ in g_simple_client_id_by_user_id {
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

simple_member_data_join_tail :: proc(allocator := context.allocator) -> []Party_MemberData_Tail_Value {
	values := make([dynamic]Party_MemberData_Tail_Value, allocator)
	code := "6561198839422336"
	for ch in transmute([]byte)code {
		append(&values, Party_MemberData_Tail_Value{kind = .Uint, uint_value = u64(ch)})
	}
	append(&values, Party_MemberData_Tail_Value{kind = .Str, text = ""})
	append(&values, Party_MemberData_Tail_Value{kind = .Uint, uint_value = 0})
	return values[:]
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
	return simple_party_member_connected_body_version(rpc_id, 2, simple_server_state, initialized, allocator)
}

simple_party_member_connected_body_version :: proc(
	rpc_id: u16,
	version: u64,
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
		version = version,
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

simple_party_member_connected_sample_body :: proc(
	rpc_id: u16,
	simple_server_state: ^Simple_Server_State,
	allocator := context.allocator,
) -> ([]byte, bool) {
	if g_simple_raknet_samples_text == "" || simple_server_state.steam_id == "" do return nil, false
	body, ok := simple_captured_push_sample_for_steam(
		g_simple_raknet_samples_text,
		"party/party.memberConnected",
		simple_server_state.steam_id,
		allocator,
	)
	if !ok || len(body) < 2 do return nil, false
	decoded := decode_scene_body(body, allocator)
	sample_connected := parse_party_member_connected_body(decoded, allocator)
	version := scene_root_uint(decoded, 0)
	if version == 0 do version = 8
	connected := simple_party_member_connected_body_version(rpc_id, version, simple_server_state, true, allocator)
	if len(sample_connected.member.session_token) > 0 {
		connected.member.session_token = sample_connected.member.session_token
	}
	dynamic_body := encode_party_member_connected_body(
		connected,
		allocator,
	)
	if len(decoded.raw_tail) > 0 {
		out := make([dynamic]byte, allocator)
		append(&out, ..dynamic_body)
		append(&out, ..decoded.raw_tail)
		return out[:], true
	}
	return dynamic_body, true
}

simple_party_join_announce_key :: proc(
	owner_id, joiner_id: string,
	allocator := context.allocator,
) -> string {
	return strings.concatenate({owner_id, "|", joiner_id}, allocator)
}

simple_queue_owner_party_join_messages :: proc(
	owner_state: ^Simple_Server_State,
	joiner_state: ^Simple_Server_State,
	owner_party_handle: u64,
	include_snapshot := true,
) {
	if owner_state == nil || joiner_state == nil || owner_state.remote.port == 0 do return
	owner_party_scene, _ := simple_scene_from_handle(owner_state, owner_party_handle)
	member_connected_body := simple_party_member_connected_body_version(9, 8, joiner_state, true)
	member_connected_raw, member_connected_raw_ok := simple_party_member_connected_sample_body(9, joiner_state)
	joiner_member_update := simple_party_member_data_updated_body_with_lobby_state(11, 9, joiner_state, true, 1, 18)
	simple_queue_cross_message(
		owner_state.remote,
		Scene_Message{
			scene_handle = u8(owner_party_handle),
			route_handle = get_route_num_from_handle(owner_state, owner_party_handle, "party.memberDataUpdated"),
			body = joiner_member_update,
		},
	)
	if member_connected_raw_ok {
		member_connected_decoded := decode_scene_body(member_connected_raw)
		simple_queue_cross_message(
			owner_state.remote,
			Scene_Message{
				scene_handle = u8(owner_party_handle),
				route_handle = get_route_num_from_handle(owner_state, owner_party_handle, "party.memberConnected"),
				body = Scene_Raw_Body{raw = member_connected_raw, decoded = member_connected_decoded},
				raw_body = member_connected_raw,
				decoded = member_connected_decoded,
			},
		)
	} else {
		simple_queue_cross_message(
			owner_state.remote,
			Scene_Message{
				scene_handle = u8(owner_party_handle),
				route_handle = get_route_num_from_handle(owner_state, owner_party_handle, "party.memberConnected"),
				body = member_connected_body,
			},
		)
	}
	if g_simple_party_join_announced != nil && owner_state.user_id != "" && joiner_state.user_id != "" {
		g_simple_party_join_announced[simple_party_join_announce_key(owner_state.user_id, joiner_state.user_id)] = true
	}
	if include_snapshot {
		simple_queue_cross_message(
			owner_state.remote,
			Scene_Message{
				scene_handle = u8(owner_party_handle),
				route_handle = get_route_num_from_handle(owner_state, owner_party_handle, "party.getPartyStateResponse"),
				body = simple_party_state_response(23, owner_state, owner_party_scene),
			},
		)
	}
}

simple_queue_owner_party_join_ready_messages :: proc(joiner_state: ^Simple_Server_State) -> bool {
	if joiner_state == nil || joiner_state.user_id == "" do return false
	invitation_code := joiner_state.party_conn_token_from_code.invitation_code
	if invitation_code == "" do return false
	owner_id := simple_party_owner_for_invitation_code(invitation_code, joiner_state)
	if owner_id == "" || owner_id == joiner_state.user_id do return false
	ready_key := simple_party_join_announce_key(owner_id, joiner_state.user_id)
	if g_simple_party_join_ready_announced != nil {
		if announced, ok := g_simple_party_join_ready_announced[ready_key]; ok && announced do return false
	}
	party_scene := simple_party_scene_for_invitation_code(invitation_code, joiner_state)
	owner_state, owner_ok := simple_state_for_user_id(owner_id)
	if !owner_ok || owner_state.remote.port == 0 {
		owner_state, owner_ok = simple_state_for_party_scene(party_scene)
	}
	if !owner_ok || owner_state.remote.port == 0 do return false
	owner_party_handle, owner_party_ok := simple_first_party_scene_handle(owner_state)
	if !owner_party_ok do return false
	simple_queue_owner_party_join_messages(owner_state, joiner_state, owner_party_handle, false)
	if g_simple_party_join_ready_announced != nil do g_simple_party_join_ready_announced[ready_key] = true
	return true
}

simple_captured_push_sample_for_steam :: proc(
	text, key, steam_id: string,
	allocator := context.allocator,
) -> ([]byte, bool) {
	key_needle := fmt.aprintf("\"%s\"", key, allocator = allocator)
	start := strings.index(text, key_needle)
	if start < 0 do return nil, false
	section := text[start:]
	section = section[:next_push_key_offset(section)]
	samples_pos := strings.index(section, "\"samples\"")
	if samples_pos < 0 do return nil, false
	section = section[samples_pos:]

	best_hex := ""
	steam_needle := fmt.aprintf("\"steamId\": \"%s\"", steam_id, allocator = allocator)
	for {
		hex_key := strings.index(section, "\"hex\"")
		if hex_key < 0 do break
		section = section[hex_key:]
		hex_quote := strings.index(section, "\"")
		if hex_quote < 0 do break
		section = section[hex_quote + 1:]
		hex_quote = strings.index(section, "\"")
		if hex_quote < 0 do break
		section = section[hex_quote + 1:]
		hex_value_quote := strings.index(section, "\"")
		if hex_value_quote < 0 do break
		section = section[hex_value_quote + 1:]
		hex_end := strings.index(section, "\"")
		if hex_end < 0 do break
		hex_text := section[:hex_end]
		after_hex := section[hex_end + 1:]
		next_hex := strings.index(after_hex, "\"hex\"")
		sample_section := after_hex
		if next_hex >= 0 do sample_section = after_hex[:next_hex]
		if strings.contains(sample_section, steam_needle) {
			best_hex = hex_text
		}
		section = after_hex
	}
	if best_hex == "" do return nil, false
	body, ok := hex.decode(transmute([]byte)best_hex, allocator)
	if !ok do return nil, false
	return body, true
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
	if g_simple_client_id_by_user_id != nil {
		others := make([dynamic]string, allocator)
		for user_id, _ in g_simple_client_id_by_user_id {
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
