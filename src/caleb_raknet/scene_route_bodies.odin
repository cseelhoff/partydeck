package caleb_raknet

// Route-aware Scene_Message bodies. The low-level frame decoder can only see the
// numeric route handle, so it initially stores Scene_Raw_Body; once route_table
// resolves the route name, scene_message_with_route_body can replace that with the
// route-specific struct below while raw_body still preserves exact wire bytes.

Scene_Raw_Body :: struct {
	raw:     []byte,
	decoded: Scene_Body,
}

Stormancer_Rpc_Completed_Body :: struct {
	rpc_id:       u16,
	message_sent: bool,
	raw:          []byte,
}

Stormancer_Rpc_Next_Body :: struct {
	rpc_id:         u16,
	result_is_nil:  bool,
	success:        bool,
	user_id:        string,
	error_message:  string,
	identity_count: int,
	steam_identity: string,
	steam_id:       string,
	metadata_count: int,
}

Stormancer_Rpc_Error_Body :: struct {
	rpc_id:  u16,
	message: string,
	values:  Msgpack_Seq,
}

Authentication_Login_Body :: struct {
	rpc_id:         u16,
	provider:       string,
	client_version: string,
	ticket:         string,
	version:        string,
	app_id:         string,
}

Friends_Subscribe_Body :: struct {
	rpc_id: u16,
}

Friends_UpdateFriendList_Body :: struct {
	friends_count: int,
	values:        Msgpack_Seq,
}

Friends_Notification_Body :: struct {
	notification_count: int,
	values:             Msgpack_Seq,
}

GameSession_GetP2PToken_Body :: struct {
	rpc_id: u16,
	status: u64,
}

GameVersion_Update_Body :: struct {
	accepted_version: string,
}

Gamefinder_Update_Body :: struct {
	status:     u64,
	token_json: string,
	values:     Msgpack_Seq,
}

Locator_GetSceneConnectionToken_Body :: struct {
	rpc_id:     u16,
	scene_type: string,
	scene_id:   string,
}

Party_CreateInvitationCode_Body :: struct {
	rpc_id: u16,
}

Party_GetPartyState2_Body :: struct {
	rpc_id: u16,
}

Scene_Platform_Identity :: struct {
	provider:     string,
	user_id:      string,
	visibility:   string,
	platform_id:  string,
	extra:        string,
	extra_is_nil: bool,
	flags:        u64,
}

Scene_Party_Member_Data :: struct {
	user_id:       string,
	userdata_json: string,
	userdata:      Party_Member_Userdata,
	platforms:     []Scene_Platform_Identity,
	state:         u64,
}

Scene_Party_Member_Connected :: struct {
	user_id:          string,
	connection_state: u64,
	userdata_json:    string,
	userdata:         Party_Member_Userdata,
	session_token:    []byte,
	platforms:        []Scene_Platform_Identity,
	state:            u64,
}

Scene_Party_Settings :: struct {
	game_finder:        string,
	custom_data_json:   string,
	revision:           u64,
	only_leader_invite: bool,
	is_joinable:        bool,
	public_data:        string,
	party_id:           string,
}

Scene_Party_Member_Status :: struct {
	user_id: string,
	status:  u64,
}

Party_MemberConnected_Body :: struct {
	rpc_id:   u16,
	version:  u64,
	member:   Scene_Party_Member_Connected,
	raw_tail: []byte,
}

Party_MemberDataUpdated_Body :: struct {
	rpc_id:       u16,
	version:      u64,
	member:       Scene_Party_Member_Data,
	extra_values: int,
}

Party_MemberDisconnected_Body :: struct {
	rpc_id:  u16,
	version: u64,
	user_id: string,
	reason:  u64,
}

Party_MemberStatusUpdated_Body :: struct {
	rpc_id:  u16,
	version: u64,
	members: []Scene_Party_Member_Status,
}

Party_SettingsUpdated_Body :: struct {
	rpc_id:   u16,
	version:  u64,
	settings: Scene_Party_Settings,
}

Party_UpdateGameFinderPlayerStatus_Body :: struct {
	rpc_id: u16,
	status: u64,
	reason: u64,
}

Party_UpdatePartySettings_Body :: struct {
	rpc_id:             u16,
	game_finder:        string,
	custom_data_json:   string,
	only_leader_invite: bool,
	is_joinable:        bool,
	public_data:        string,
	party_id:           string,
}

Party_UpdatePartyUserData2_Body :: struct {
	rpc_id:        u16,
	userdata_json: string,
	userdata:      Party_Member_Userdata,
	platforms:     []Scene_Platform_Identity,
}

PartyManagement_CreateConnectionTokenFromInvitationCode_Body :: struct {
	rpc_id:          u16,
	invitation_code: string,
	userdata_json:   string,
	userdata:        Party_Member_Userdata,
}

PartyManagement_CreateSession_Body :: struct {
	rpc_id:             u16,
	session_id:         string,
	game_finder:        string,
	scene_id:           string,
	is_public:          bool,
	is_joinable:        bool,
	allow_party_merger: bool,
	userdata_json:      string,
	userdata:           Party_Member_Userdata,
}

PartyMerging_GetMergerStatus_Body :: struct {
	rpc_id:    u16,
	algorithm: string,
}

Player_Update_Body :: struct {
	user_id: string,
	state:   u64,
	data:    string,
	ready:   bool,
}

Steam_CreateLobby_Body :: struct {
	rpc_id:                u16,
	lobby_type:            u64,
	max_members:           u64,
	joinable:              bool,
	party_data_token:      string,
	party_data_token_json: string,
}

Steam_JoinLobby_Body :: struct {
	rpc_id:   u16,
	lobby_id: u64,
}

Steam_UpdateLobbyJoinable_Body :: struct {
	rpc_id:   u16,
	lobby_id: u64,
	joinable: bool,
}

UserSession_UpdateUserOptions_Body :: struct {
	rpc_id:  u16,
	key:     string,
	enabled: bool,
}

Scene_Message_Body :: union {
	Scene_Raw_Body,
	Stormancer_Rpc_Completed_Body,
	Stormancer_Rpc_Next_Body,
	Stormancer_Rpc_Error_Body,
	Authentication_Login_Body,
	Friends_Subscribe_Body,
	Friends_UpdateFriendList_Body,
	Friends_Notification_Body,
	GameSession_GetP2PToken_Body,
	GameVersion_Update_Body,
	Gamefinder_Update_Body,
	Locator_GetSceneConnectionToken_Body,
	Party_CreateInvitationCode_Body,
	Party_GetPartyState2_Body,
	Party_MemberConnected_Body,
	Party_MemberDataUpdated_Body,
	Party_MemberDisconnected_Body,
	Party_MemberStatusUpdated_Body,
	Party_SettingsUpdated_Body,
	Party_UpdateGameFinderPlayerStatus_Body,
	Party_UpdatePartySettings_Body,
	Party_UpdatePartyUserData2_Body,
	PartyManagement_CreateConnectionTokenFromInvitationCode_Body,
	PartyManagement_CreateSession_Body,
	PartyMerging_GetMergerStatus_Body,
	Player_Update_Body,
	Steam_CreateLobby_Body,
	Steam_JoinLobby_Body,
	Steam_UpdateLobbyJoinable_Body,
	UserSession_UpdateUserOptions_Body,
}

parse_scene_message_body :: proc(
	route_name: string,
	raw: []byte,
	decoded: Scene_Body,
	allocator := context.allocator,
) -> Scene_Message_Body {
	switch route_name {
	case "stormancer.rpc.completed":
		return parse_stormancer_rpc_completed_body(raw)
	case "stormancer.rpc.next":
		return parse_stormancer_rpc_next_body(decoded)
	case "stormancer.rpc.error":
		return parse_stormancer_rpc_error_body(decoded)
	case "Authentication.Login":
		return parse_authentication_login_body(decoded)
	case "Friends.Subscribe":
		return Friends_Subscribe_Body{rpc_id = decoded.rpc_id}
	case "Friends.UpdateFriendList":
		return parse_friends_update_friend_list_body(decoded)
	case "friends.notification":
		return parse_friends_notification_body(decoded)
	case "GameSession.GetP2PToken":
		return parse_gamesession_get_p2p_token_body(decoded)
	case "gameVersion.update":
		return parse_game_version_update_body(decoded)
	case "gamefinder.update":
		return parse_gamefinder_update_body(decoded)
	case "Locator.GetSceneConnectionToken":
		return parse_locator_get_scene_connection_token_body(decoded)
	case "Party.CreateInvitationCode":
		return Party_CreateInvitationCode_Body{rpc_id = decoded.rpc_id}
	case "party.getpartystate2":
		return Party_GetPartyState2_Body{rpc_id = decoded.rpc_id}
	case "party.memberConnected":
		return parse_party_member_connected_body(decoded, allocator)
	case "party.memberDataUpdated":
		return parse_party_member_data_updated_body(decoded, allocator)
	case "party.memberDisconnected":
		return parse_party_member_disconnected_body(decoded)
	case "party.memberStatusUpdated":
		return parse_party_member_status_updated_body(decoded, allocator)
	case "party.settingsUpdated":
		return parse_party_settings_updated_body(decoded)
	case "party.updategamefinderplayerstatus":
		return parse_party_update_gamefinder_player_status_body(decoded)
	case "party.updatepartysettings":
		return parse_party_update_party_settings_body(decoded)
	case "Party.UpdatePartyUserData2":
		return parse_party_update_party_user_data2_body(decoded, allocator)
	case "PartyManagement.CreateConnectionTokenFromInvitationCode":
		return parse_party_management_create_connection_token_from_invitation_code_body(decoded)
	case "partymanagement.createsession":
		return parse_party_management_create_session_body(decoded)
	case "PartyMerging.GetMergerStatus":
		return parse_party_merging_get_merger_status_body(decoded)
	case "player.update":
		return parse_player_update_body(decoded)
	case "Steam.CreateLobby":
		return parse_steam_create_lobby_body(decoded)
	case "Steam.JoinLobby":
		return parse_steam_join_lobby_body(decoded)
	case "Steam.UpdateLobbyJoinable":
		return parse_steam_update_lobby_joinable_body(decoded)
	case "UserSession.UpdateUserOptions":
		return parse_user_session_update_user_options_body(decoded)
	}
	return Scene_Raw_Body{raw = raw, decoded = decoded}
}

scene_message_with_route_body :: proc(
	message: Decoded_Message,
	route_name: string,
	allocator := context.allocator,
) -> Decoded_Message {
	if sm, ok := message.(Scene_Message); ok {
		sm.body = parse_scene_message_body(route_name, sm.raw_body, sm.decoded, allocator)
		return sm
	}
	return message
}

parse_stormancer_rpc_completed_body :: proc(raw: []byte) -> Stormancer_Rpc_Completed_Body {
	out := Stormancer_Rpc_Completed_Body {
		raw = raw,
	}
	if len(raw) >= 3 {
		out.message_sent = raw[0] != 0
		out.rpc_id = read_u16_le(raw, 1)
	}
	return out
}

parse_stormancer_rpc_next_body :: proc(body: Scene_Body) -> Stormancer_Rpc_Next_Body {
	nodes := body.values.nodes
	root := scene_seq_root(body, 0)
	identities := scene_array_child(nodes, root, 4)
	metadata := scene_array_child(nodes, root, 5)
	steam_identity := scene_map_string(nodes, identities, "steam")
	return Stormancer_Rpc_Next_Body {
		rpc_id = body.rpc_id,
		result_is_nil = scene_node_is_nil(nodes, scene_array_child(nodes, root, 0)),
		success = scene_node_bool(nodes, scene_array_child(nodes, root, 1)),
		user_id = scene_node_text(nodes, scene_array_child(nodes, root, 2)),
		error_message = scene_node_text(nodes, scene_array_child(nodes, root, 3)),
		identity_count = scene_node_count(nodes, identities),
		steam_identity = steam_identity,
		steam_id = steam_id_from_identity(steam_identity),
		metadata_count = scene_node_count(nodes, metadata),
	}
}

parse_stormancer_rpc_error_body :: proc(body: Scene_Body) -> Stormancer_Rpc_Error_Body {
	message := ""
	if r := scene_seq_root(body, 0); r >= 0 do message = scene_node_text(body.values.nodes, r)
	return Stormancer_Rpc_Error_Body{rpc_id = body.rpc_id, message = message, values = body.values}
}

parse_authentication_login_body :: proc(body: Scene_Body) -> Authentication_Login_Body {
	nodes := body.values.nodes
	root := scene_seq_root(body, 0)
	meta := scene_array_child(nodes, root, 1)
	return Authentication_Login_Body {
		rpc_id = body.rpc_id,
		provider = scene_node_text(nodes, scene_array_child(nodes, root, 0)),
		client_version = scene_map_string(nodes, meta, "gameVersion.clientVersion"),
		ticket = scene_map_string(nodes, meta, "ticket"),
		version = scene_map_string(nodes, meta, "version"),
		app_id = scene_map_string(nodes, meta, "appId"),
	}
}

parse_friends_update_friend_list_body :: proc(body: Scene_Body) -> Friends_UpdateFriendList_Body {
	count := 0
	if r := scene_seq_root(body, 0); r >= 0 && body.values.nodes[r].kind == .Array do count = body.values.nodes[r].count
	return Friends_UpdateFriendList_Body{friends_count = count, values = body.values}
}

parse_friends_notification_body :: proc(body: Scene_Body) -> Friends_Notification_Body {
	count := 0
	if r := scene_seq_root(body, 0); r >= 0 && body.values.nodes[r].kind == .Array do count = body.values.nodes[r].count
	return Friends_Notification_Body{notification_count = count, values = body.values}
}

parse_gamesession_get_p2p_token_body :: proc(body: Scene_Body) -> GameSession_GetP2PToken_Body {
	return GameSession_GetP2PToken_Body{rpc_id = body.rpc_id, status = scene_root_uint(body, 0)}
}

parse_game_version_update_body :: proc(body: Scene_Body) -> GameVersion_Update_Body {
	return GameVersion_Update_Body{accepted_version = scene_root_text(body, 0)}
}

parse_gamefinder_update_body :: proc(body: Scene_Body) -> Gamefinder_Update_Body {
	token_json := ""
	if r := scene_seq_root(body, 1); r >= 0 do token_json = scene_node_text(body.values.nodes, r)
	return Gamefinder_Update_Body {
		status = scene_root_uint(body, 0),
		token_json = token_json,
		values = body.values,
	}
}

parse_locator_get_scene_connection_token_body :: proc(
	body: Scene_Body,
) -> Locator_GetSceneConnectionToken_Body {
	return Locator_GetSceneConnectionToken_Body {
		rpc_id = body.rpc_id,
		scene_type = scene_root_text(body, 0),
		scene_id = scene_root_text(body, 1),
	}
}

parse_party_member_connected_body :: proc(
	body: Scene_Body,
	allocator := context.allocator,
) -> Party_MemberConnected_Body {
	nodes := body.values.nodes
	return Party_MemberConnected_Body {
		rpc_id = body.rpc_id,
		version = scene_root_uint(body, 0),
		member = scene_parse_party_member_connected(nodes, scene_seq_root(body, 1), allocator),
		raw_tail = body.raw_tail,
	}
}

parse_party_member_data_updated_body :: proc(
	body: Scene_Body,
	allocator := context.allocator,
) -> Party_MemberDataUpdated_Body {
	return Party_MemberDataUpdated_Body {
		rpc_id = body.rpc_id,
		version = scene_root_uint(body, 0),
		member = scene_parse_party_member_data(
			body.values.nodes,
			scene_seq_root(body, 1),
			allocator,
		),
		extra_values = max(len(body.values.roots) - 2, 0),
	}
}

parse_party_member_disconnected_body :: proc(body: Scene_Body) -> Party_MemberDisconnected_Body {
	nodes := body.values.nodes
	member := scene_seq_root(body, 1)
	return Party_MemberDisconnected_Body {
		rpc_id = body.rpc_id,
		version = scene_root_uint(body, 0),
		user_id = scene_node_text(nodes, scene_array_child(nodes, member, 0)),
		reason = scene_node_uint(nodes, scene_array_child(nodes, member, 1)),
	}
}

parse_party_member_status_updated_body :: proc(
	body: Scene_Body,
	allocator := context.allocator,
) -> Party_MemberStatusUpdated_Body {
	members := make([dynamic]Scene_Party_Member_Status, allocator)
	scene_collect_member_statuses(body.values.nodes, scene_seq_root(body, 1), &members)
	return Party_MemberStatusUpdated_Body {
		rpc_id = body.rpc_id,
		version = scene_root_uint(body, 0),
		members = members[:],
	}
}

parse_party_settings_updated_body :: proc(body: Scene_Body) -> Party_SettingsUpdated_Body {
	return Party_SettingsUpdated_Body {
		rpc_id = body.rpc_id,
		version = scene_root_uint(body, 0),
		settings = scene_parse_party_settings(body.values.nodes, scene_seq_root(body, 1)),
	}
}

parse_party_update_gamefinder_player_status_body :: proc(
	body: Scene_Body,
) -> Party_UpdateGameFinderPlayerStatus_Body {
	nodes := body.values.nodes
	root := scene_seq_root(body, 0)
	return Party_UpdateGameFinderPlayerStatus_Body {
		rpc_id = body.rpc_id,
		status = scene_node_uint(nodes, scene_array_child(nodes, root, 0)),
		reason = scene_node_uint(nodes, scene_array_child(nodes, root, 1)),
	}
}

parse_party_update_party_settings_body :: proc(
	body: Scene_Body,
) -> Party_UpdatePartySettings_Body {
	nodes := body.values.nodes
	root := scene_seq_root(body, 0)
	return Party_UpdatePartySettings_Body {
		rpc_id = body.rpc_id,
		game_finder = scene_node_text(nodes, scene_array_child(nodes, root, 0)),
		custom_data_json = scene_node_text(nodes, scene_array_child(nodes, root, 1)),
		only_leader_invite = scene_node_bool(nodes, scene_array_child(nodes, root, 2)),
		is_joinable = scene_node_bool(nodes, scene_array_child(nodes, root, 3)),
		public_data = scene_node_text(nodes, scene_array_child(nodes, root, 4)),
		party_id = scene_node_text(nodes, scene_array_child(nodes, root, 5)),
	}
}

parse_party_update_party_user_data2_body :: proc(
	body: Scene_Body,
	allocator := context.allocator,
) -> Party_UpdatePartyUserData2_Body {
	json := scene_root_text(body, 0)
	return Party_UpdatePartyUserData2_Body {
		rpc_id = body.rpc_id,
		userdata_json = json,
		userdata = parse_party_member_userdata(json),
		platforms = scene_parse_platforms(body.values.nodes, scene_seq_root(body, 1), allocator),
	}
}

parse_party_management_create_connection_token_from_invitation_code_body :: proc(
	body: Scene_Body,
) -> PartyManagement_CreateConnectionTokenFromInvitationCode_Body {
	json := scene_root_text(body, 1)
	return PartyManagement_CreateConnectionTokenFromInvitationCode_Body {
		rpc_id = body.rpc_id,
		invitation_code = scene_root_text(body, 0),
		userdata_json = json,
		userdata = parse_party_member_userdata(json),
	}
}

parse_party_management_create_session_body :: proc(
	body: Scene_Body,
) -> PartyManagement_CreateSession_Body {
	nodes := body.values.nodes
	root := scene_seq_root(body, 0)
	json := scene_node_text(nodes, scene_array_child(nodes, root, 7))
	return PartyManagement_CreateSession_Body {
		rpc_id = body.rpc_id,
		session_id = scene_node_text(nodes, scene_array_child(nodes, root, 0)),
		game_finder = scene_node_text(nodes, scene_array_child(nodes, root, 1)),
		scene_id = scene_node_text(nodes, scene_array_child(nodes, root, 2)),
		is_public = scene_node_bool(nodes, scene_array_child(nodes, root, 4)),
		is_joinable = scene_node_bool(nodes, scene_array_child(nodes, root, 5)),
		allow_party_merger = scene_node_bool(nodes, scene_array_child(nodes, root, 6)),
		userdata_json = json,
		userdata = parse_party_member_userdata(json),
	}
}

parse_party_merging_get_merger_status_body :: proc(
	body: Scene_Body,
) -> PartyMerging_GetMergerStatus_Body {
	return PartyMerging_GetMergerStatus_Body {
		rpc_id = body.rpc_id,
		algorithm = scene_root_text(body, 0),
	}
}

parse_player_update_body :: proc(body: Scene_Body) -> Player_Update_Body {
	nodes := body.values.nodes
	root := scene_seq_root(body, 0)
	return Player_Update_Body {
		user_id = scene_node_text(nodes, scene_array_child(nodes, root, 0)),
		state = scene_node_uint(nodes, scene_array_child(nodes, root, 1)),
		data = scene_node_text(nodes, scene_array_child(nodes, root, 2)),
		ready = scene_node_bool(nodes, scene_array_child(nodes, root, 3)),
	}
}

parse_steam_create_lobby_body :: proc(body: Scene_Body) -> Steam_CreateLobby_Body {
	nodes := body.values.nodes
	root := scene_seq_root(body, 0)
	meta := scene_array_child(nodes, root, 3)
	token := scene_map_string(nodes, meta, "partyDataToken")
	token_json := ""
	if decoded, ok := try_base64_text(token); ok do token_json = decoded
	return Steam_CreateLobby_Body {
		rpc_id = body.rpc_id,
		lobby_type = scene_node_uint(nodes, scene_array_child(nodes, root, 0)),
		max_members = scene_node_uint(nodes, scene_array_child(nodes, root, 1)),
		joinable = scene_node_bool(nodes, scene_array_child(nodes, root, 2)),
		party_data_token = token,
		party_data_token_json = token_json,
	}
}

parse_steam_join_lobby_body :: proc(body: Scene_Body) -> Steam_JoinLobby_Body {
	nodes := body.values.nodes
	root := scene_seq_root(body, 0)
	return Steam_JoinLobby_Body {
		rpc_id = body.rpc_id,
		lobby_id = scene_node_uint(nodes, scene_array_child(nodes, root, 0)),
	}
}

parse_steam_update_lobby_joinable_body :: proc(
	body: Scene_Body,
) -> Steam_UpdateLobbyJoinable_Body {
	nodes := body.values.nodes
	root := scene_seq_root(body, 0)
	return Steam_UpdateLobbyJoinable_Body {
		rpc_id = body.rpc_id,
		lobby_id = scene_node_uint(nodes, scene_array_child(nodes, root, 0)),
		joinable = scene_node_bool(nodes, scene_array_child(nodes, root, 1)),
	}
}

parse_user_session_update_user_options_body :: proc(
	body: Scene_Body,
) -> UserSession_UpdateUserOptions_Body {
	nodes := body.values.nodes
	meta := scene_seq_root(body, 1)
	return UserSession_UpdateUserOptions_Body {
		rpc_id = body.rpc_id,
		key = scene_root_text(body, 0),
		enabled = scene_node_bool(nodes, msgpack_map_get(nodes, meta, "enabled")),
	}
}

scene_parse_party_member_data :: proc(
	nodes: []Msgpack_Node,
	idx: int,
	allocator := context.allocator,
) -> Scene_Party_Member_Data {
	json := scene_node_text(nodes, scene_array_child(nodes, idx, 1))
	return Scene_Party_Member_Data {
		user_id = scene_node_text(nodes, scene_array_child(nodes, idx, 0)),
		userdata_json = json,
		userdata = parse_party_member_userdata(json),
		platforms = scene_parse_platforms(nodes, scene_array_child(nodes, idx, 2), allocator),
		state = scene_node_uint(nodes, scene_array_child(nodes, idx, 3)),
	}
}

scene_parse_party_member_connected :: proc(
	nodes: []Msgpack_Node,
	idx: int,
	allocator := context.allocator,
) -> Scene_Party_Member_Connected {
	json := scene_node_text(nodes, scene_array_child(nodes, idx, 2))
	return Scene_Party_Member_Connected {
		user_id = scene_node_text(nodes, scene_array_child(nodes, idx, 0)),
		connection_state = scene_node_uint(nodes, scene_array_child(nodes, idx, 1)),
		userdata_json = json,
		userdata = parse_party_member_userdata(json),
		session_token = scene_node_bin(nodes, scene_array_child(nodes, idx, 3)),
		platforms = scene_parse_platforms(nodes, scene_array_child(nodes, idx, 4), allocator),
		state = scene_node_uint(nodes, scene_array_child(nodes, idx, 5)),
	}
}

scene_parse_party_settings :: proc(nodes: []Msgpack_Node, idx: int) -> Scene_Party_Settings {
	return Scene_Party_Settings {
		game_finder = scene_node_text(nodes, scene_array_child(nodes, idx, 0)),
		custom_data_json = scene_node_text(nodes, scene_array_child(nodes, idx, 1)),
		revision = scene_node_uint(nodes, scene_array_child(nodes, idx, 2)),
		only_leader_invite = scene_node_bool(nodes, scene_array_child(nodes, idx, 3)),
		is_joinable = scene_node_bool(nodes, scene_array_child(nodes, idx, 4)),
		public_data = scene_node_text(nodes, scene_array_child(nodes, idx, 6)),
		party_id = scene_node_text(nodes, scene_array_child(nodes, idx, 7)),
	}
}

scene_parse_platforms :: proc(
	nodes: []Msgpack_Node,
	idx: int,
	allocator := context.allocator,
) -> []Scene_Platform_Identity {
	if idx < 0 || idx >= len(nodes) || nodes[idx].kind != .Array do return nil
	out := make([dynamic]Scene_Platform_Identity, 0, nodes[idx].count, allocator)
	child := idx + 1
	for _ in 0 ..< nodes[idx].count {
		if child < 0 || child >= len(nodes) do break
		append(&out, scene_parse_platform(nodes, child))
		child += nodes[child].subtree
	}
	return out[:]
}

scene_parse_platform :: proc(nodes: []Msgpack_Node, idx: int) -> Scene_Platform_Identity {
	extra_idx := scene_array_child(nodes, idx, 4)
	extra_is_nil := extra_idx >= 0 && extra_idx < len(nodes) && nodes[extra_idx].kind == .Nil
	return Scene_Platform_Identity {
		provider = scene_node_text(nodes, scene_array_child(nodes, idx, 0)),
		user_id = scene_node_text(nodes, scene_array_child(nodes, idx, 1)),
		visibility = scene_node_text(nodes, scene_array_child(nodes, idx, 2)),
		platform_id = scene_node_text(nodes, scene_array_child(nodes, idx, 3)),
		extra = scene_node_text(nodes, extra_idx),
		extra_is_nil = extra_is_nil,
		flags = scene_node_uint(nodes, scene_array_child(nodes, idx, 5)),
	}
}

scene_collect_member_statuses :: proc(
	nodes: []Msgpack_Node,
	idx: int,
	sink: ^[dynamic]Scene_Party_Member_Status,
) {
	if idx < 0 || idx >= len(nodes) || nodes[idx].kind != .Array do return
	first := scene_array_child(nodes, idx, 0)
	second := scene_array_child(nodes, idx, 1)
	if first >= 0 && second >= 0 && nodes[first].kind == .Str {
		append(
			sink,
			Scene_Party_Member_Status {
				user_id = nodes[first].str,
				status = scene_node_uint(nodes, second),
			},
		)
		return
	}
	child := idx + 1
	for _ in 0 ..< nodes[idx].count {
		if child < 0 || child >= len(nodes) do break
		scene_collect_member_statuses(nodes, child, sink)
		child += nodes[child].subtree
	}
}

scene_seq_root :: proc(body: Scene_Body, root_index: int) -> int {
	if root_index < 0 || root_index >= len(body.values.roots) do return -1
	root := body.values.roots[root_index]
	if root < 0 || root >= len(body.values.nodes) do return -1
	return root
}

scene_root_text :: proc(body: Scene_Body, root_index: int) -> string {
	return scene_node_text(body.values.nodes, scene_seq_root(body, root_index))
}

scene_root_uint :: proc(body: Scene_Body, root_index: int) -> u64 {
	return scene_node_uint(body.values.nodes, scene_seq_root(body, root_index))
}

scene_array_child :: proc(nodes: []Msgpack_Node, array_idx, child_idx: int) -> int {
	if array_idx < 0 || array_idx >= len(nodes) do return -1
	if nodes[array_idx].kind != .Array || child_idx < 0 || child_idx >= nodes[array_idx].count do return -1
	j := array_idx + 1
	for _ in 0 ..< child_idx {
		if j < 0 || j >= len(nodes) do return -1
		j += nodes[j].subtree
	}
	if j < 0 || j >= len(nodes) do return -1
	return j
}

scene_map_string :: proc(nodes: []Msgpack_Node, map_idx: int, key: string) -> string {
	return scene_node_text(nodes, msgpack_map_get(nodes, map_idx, key))
}

scene_node_text :: proc(nodes: []Msgpack_Node, idx: int) -> string {
	if idx < 0 || idx >= len(nodes) do return ""
	#partial switch nodes[idx].kind {
	case .Str:
		return nodes[idx].str
	case .Bin:
		return string(nodes[idx].bin)
	}
	return ""
}

scene_node_bin :: proc(nodes: []Msgpack_Node, idx: int) -> []byte {
	if idx < 0 || idx >= len(nodes) do return nil
	if nodes[idx].kind == .Bin || nodes[idx].kind == .Ext do return nodes[idx].bin
	return nil
}

scene_node_uint :: proc(nodes: []Msgpack_Node, idx: int) -> u64 {
	if idx < 0 || idx >= len(nodes) do return 0
	#partial switch nodes[idx].kind {
	case .Uint:
		return nodes[idx].u
	case .Int:
		if nodes[idx].i > 0 do return u64(nodes[idx].i)
	}
	return 0
}

scene_node_count :: proc(nodes: []Msgpack_Node, idx: int) -> int {
	if idx < 0 || idx >= len(nodes) do return 0
	return nodes[idx].count
}

scene_node_is_nil :: proc(nodes: []Msgpack_Node, idx: int) -> bool {
	if idx < 0 || idx >= len(nodes) do return false
	return nodes[idx].kind == .Nil
}

scene_node_bool :: proc(nodes: []Msgpack_Node, idx: int) -> bool {
	if idx < 0 || idx >= len(nodes) do return false
	return nodes[idx].kind == .Bool && nodes[idx].b
}

steam_id_from_identity :: proc(identity: string) -> string {
	prefix :: "steam:"
	if len(identity) <= len(prefix) do return ""
	if identity[:len(prefix)] != prefix do return ""
	return identity[len(prefix):]
}
