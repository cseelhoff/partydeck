package caleb_raknet

import "core:encoding/hex"
import "core:fmt"
import "core:slice"

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
	return len(scene.scene_id) >= 6 && scene.scene_id[:6] == "party-"
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
	assert(false, "route not found")
	return 0
}

simple_party_data_token_json :: proc(simple_server_state: ^Simple_Server_State, scene: Simple_Scene, allocator := context.allocator) -> string {
	party_id := scene.scene_id
	if len(party_id) >= 6 && party_id[:6] == "party-" do party_id = party_id[6:]
	return fmt.aprintf(
		`{"PartyId":"%s","LeaderUserId":"%s","LeaderSteamId":%s}`,
		party_id,
		simple_server_state.user_id,
		simple_server_state.steam_id,
		allocator = allocator,
	)
}

stormancer_rpc_completed_id :: proc(rpc_id: u16, sent_next: bool) -> u16 {
	return (rpc_id << 8) + (sent_next ? u16(1) : u16(0))
}

simple_party_state_response :: proc(
	rpc_id: u16,
	simple_server_state: ^Simple_Server_State,
	scene: Simple_Scene,
	allocator := context.allocator,
) -> Party_State_Response_Body {
	party_id := scene.scene_id
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

simple_party_session_token :: proc(simple_server_state: ^Simple_Server_State, allocator := context.allocator) -> []byte {
	out := make([]byte, 16, allocator)
	seed: u8 = 0x11
	if len(simple_server_state.steam_id) > 0 do seed = simple_server_state.steam_id[len(simple_server_state.steam_id) - 1]
	for i in 0 ..< len(out) do out[i] = seed + u8(i)
	return out
}

simple_party_userdata_json :: proc(
	simple_server_state: ^Simple_Server_State,
	initialized: bool,
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
	return fmt.aprintf(
		`{"RequestedHero":%d,"RequestedSkin":0,"InLobby":true,"PlayerName":"%s","LobbyState":1,"UnlockedGameDifficulty":0,"MemberDataInitialized":%s,"UnlockedHeroFlag":%d,"m_sEosUserId":"%s","m_sSteamUserId":%s,"m_uVoiceChatMode":0,"m_ePlatform":2,"RandomSkinIndex":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}`,
		hero,
		player_name,
		initialized ? "true" : "false",
		unlocked_hero_flag,
		eos_user_id,
		simple_server_state.steam_id,
		allocator = allocator,
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
