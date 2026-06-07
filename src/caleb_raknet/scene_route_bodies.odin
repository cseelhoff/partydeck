package caleb_raknet

import "core:encoding/hex"
import "core:strings"

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
}

Stormancer_Rpc_Next_Kind :: enum u8 {
	Unknown,
	Authentication_Login_Result,
	Scene_Connection_Token,
	GameSession_P2PToken_Result,
}

Stormancer_Rpc_Next_Body :: struct {
	kind:           Stormancer_Rpc_Next_Kind,
	rpc_id:         u16,
	result_is_nil:  bool,
	success:        bool,
	user_id:        string,
	error_message:  string,
	identity_count: int,
	steam_identity: string,
	steam_id:       string,
	metadata_count: int,
	token_json:     string,
	token_scene:    string,
	token:          Connection_Token,
	token_raknet_endpoints: []string,
	encryption_algorithm: string,
	encryption_mode:      string,
	encryption_key:       string,
	encryption_token:     string,
	raw_tail:       []byte,
	tail_plugin:    string,
	tail_plugin_version: string,
	tail_routes:    []Stormancer_Rpc_Next_Tail_Route,
	tail_serializer: string,
	tail_unparsed:  []byte,
}

Stormancer_Rpc_Next_Tail_Route :: struct {
	name:     string,
	handle:   u64,
	metadata: []Metadata_Entry,
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
	friends:            Simple_Friends,
	timestamp:          u64,
	raw_tail:           []byte,
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
	raw_tail:   []byte,
}

Locator_GetSceneConnectionToken_Body :: struct {
	rpc_id:     u16,
	scene_type: string,
	scene_id:   string,
}

Party_CreateInvitationCode_Body :: struct {
	rpc_id: u16,
}

Party_CreateInvitationCode_Result_Body :: struct {
	rpc_id:          u16,
	invitation_code: string,
}

Party_GetPartyState2_Body :: struct {
	rpc_id: u16,
}

Party_State_Member :: struct {
	user_id:           string,
	connection_state:  u64,
	userdata_json:     string,
	userdata:          Party_Member_Userdata,
	session_token_hex: string,
	platforms:         []Scene_Platform_Identity,
	state:             u64,
}

Party_State_Response_Body :: struct {
	rpc_id:              u16,
	settings:            Scene_Party_Settings,
	leader_user_id:      string,
	members:             []Party_State_Member,
	revision:            u64,
	connection_metadata: Scene_Connection_Metadata_Trailer,
}

Scene_Connection_Metadata_Trailer :: struct {
	raw:                    []byte,
	plugin_suffix:          string,
	protocol:               string,
	server_name:            string,
	party_management:       string,
	server_version:         string,
	server_type:            string,
	serializers:            string,
	platform:               string,
	opaque_connection_data: []byte,
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
	server_status:      string,
	server_status_details: string,
	public_data:        string,
	party_id:           string,
}

Scene_Party_Member_Status :: struct {
	user_id: string,
	status:  u64,
}

Party_MemberData_Tail_Kind :: enum u8 {
	Nil,
	Bool,
	Int,
	Uint,
	Str,
	Bin,
}

Party_MemberData_Tail_Value :: struct {
	kind:       Party_MemberData_Tail_Kind,
	bool_value: bool,
	int_value:  i64,
	uint_value: u64,
	text:       string,
	bytes:      []byte,
}

Party_MemberConnected_Body :: struct {
	rpc_id:   u16,
	version:  u64,
	member:   Scene_Party_Member_Connected,
	raw_tail: []byte,
}

Party_MemberDataUpdated_Body :: struct {
	rpc_id:      u16,
	version:     u64,
	member:      Scene_Party_Member_Data,
	tail_values: []Party_MemberData_Tail_Value,
	raw_tail:    []byte,
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
	raw_tail: []byte,
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

PartyMerging_Difficulty_Count :: struct {
	difficulty: string,
	count:      u64,
}

PartyMerging_GetMergerStatus_Result_Body :: struct {
	rpc_id:                     u16,
	status:                     u64,
	parties_count:              u64,
	algorithm:                  string,
	players_count:              u64,
	nb_parties_by_difficulty:   []PartyMerging_Difficulty_Count,
	nb_players_by_difficulty:   []PartyMerging_Difficulty_Count,
}

Player_Update_Body :: struct {
	user_id:  string,
	state:    u64,
	data:     string,
	ready:    bool,
	raw_tail: []byte,
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
	Party_CreateInvitationCode_Result_Body,
	Party_GetPartyState2_Body,
	Party_State_Response_Body,
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
	PartyMerging_GetMergerStatus_Result_Body,
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
		if scene_body_is_party_state_response(decoded) do return parse_party_state_response_body(decoded, allocator)
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
		if len(sm.raw_body) == 0 {
			if _, is_raw := sm.body.(Scene_Raw_Body); !is_raw do return sm
		}
		sm.body = parse_scene_message_body(route_name, sm.raw_body, sm.decoded, allocator)
		return sm
	}
	return message
}

parse_stormancer_rpc_completed_body :: proc(raw: []byte) -> Stormancer_Rpc_Completed_Body {
	out := Stormancer_Rpc_Completed_Body{}
	if len(raw) >= 2 {
		out.rpc_id = read_u16_le(raw, 0)
		out.message_sent = (out.rpc_id & 1) != 0
	}
	return out
}

parse_stormancer_rpc_next_body :: proc(body: Scene_Body) -> Stormancer_Rpc_Next_Body {
	nodes := body.values.nodes
	root := scene_seq_root(body, 0)
	if root >= 0 && root < len(nodes) && nodes[root].kind == .Str {
		raw_tail := body.raw_tail
		if end, ok := msgpack_value_end(body.values.raw, 0); ok && end < len(body.values.raw) {
			split_tail := body.values.raw[end:]
			if len(body.raw_tail) == 0 || bytes_equal(split_tail, body.raw_tail) {
				raw_tail = split_tail
			} else {
				raw_tail = scene_concat_raw_tail(split_tail, body.raw_tail, context.allocator)
			}
		}
		tail_routes, tail_plugin, tail_plugin_version, tail_serializer, tail_unparsed := parse_stormancer_rpc_next_tail(raw_tail, context.allocator)
		token := parse_stormancer_rpc_next_token_json(nodes[root].str, context.allocator)
		token_scene := ""
		if token.token.ok do token_scene = scene_suffix(token.token.scene_id)
		return Stormancer_Rpc_Next_Body {
			kind = .Scene_Connection_Token,
			rpc_id = body.rpc_id,
			token_json = nodes[root].str,
			token_scene = token_scene,
			token = token.token,
			token_raknet_endpoints = token.raknet_endpoints,
			encryption_algorithm = token.encryption_algorithm,
			encryption_mode = token.encryption_mode,
			encryption_key = token.encryption_key,
			encryption_token = token.encryption_token,
			raw_tail = raw_tail,
			tail_plugin = tail_plugin,
			tail_plugin_version = tail_plugin_version,
			tail_routes = tail_routes,
			tail_serializer = tail_serializer,
			tail_unparsed = tail_unparsed,
		}
	}
	identities := scene_array_child(nodes, root, 4)
	metadata := scene_array_child(nodes, root, 5)
	steam_identity := scene_map_string(nodes, identities, "steam")
	tail_routes, tail_plugin, tail_plugin_version, tail_serializer, tail_unparsed := parse_stormancer_rpc_next_tail(body.raw_tail, context.allocator)
	return Stormancer_Rpc_Next_Body {
		kind = .Authentication_Login_Result,
		rpc_id = body.rpc_id,
		result_is_nil = scene_node_is_nil(nodes, scene_array_child(nodes, root, 0)),
		success = scene_node_bool(nodes, scene_array_child(nodes, root, 1)),
		user_id = scene_node_text(nodes, scene_array_child(nodes, root, 2)),
		error_message = scene_node_text(nodes, scene_array_child(nodes, root, 3)),
		identity_count = scene_node_count(nodes, identities),
		steam_identity = steam_identity,
		steam_id = steam_id_from_identity(steam_identity),
		metadata_count = scene_node_count(nodes, metadata),
		raw_tail = body.raw_tail,
		tail_plugin = tail_plugin,
		tail_plugin_version = tail_plugin_version,
		tail_routes = tail_routes,
		tail_serializer = tail_serializer,
		tail_unparsed = tail_unparsed,
	}
}

Stormancer_Rpc_Next_Token_JSON :: struct {
	token:                Connection_Token,
	raknet_endpoints:     []string,
	encryption_algorithm: string,
	encryption_mode:      string,
	encryption_key:       string,
	encryption_token:     string,
}

parse_stormancer_rpc_next_token_json :: proc(
	token_json: string,
	allocator := context.allocator,
) -> Stormancer_Rpc_Next_Token_JSON {
	out: Stormancer_Rpc_Next_Token_JSON
	if token := json_string_value_decoded(token_json, "token", allocator); token != "" {
		out.token = parse_connection_token(token, allocator)
	}
	out.raknet_endpoints = stormancer_token_raknet_endpoints(token_json, allocator)
	encryption := json_object_section(token_json, "encryption")
	out.encryption_algorithm = json_string_value_decoded(encryption, "algorithm", allocator)
	out.encryption_mode = json_string_value_decoded(encryption, "mode", allocator)
	out.encryption_key = json_string_value_decoded(encryption, "key", allocator)
	out.encryption_token = json_string_value_decoded(encryption, "token", allocator)
	return out
}

json_string_value_decoded :: proc(s, key: string, allocator := context.allocator) -> string {
	needle := strings.concatenate({`"`, key, `":`}, context.temp_allocator)
	start := strings.index(s, needle)
	if start < 0 do return ""
	p := start + len(needle)
	for p < len(s) && s[p] == ' ' do p += 1
	value, _, ok := json_string_at(s, p, allocator)
	if !ok do return ""
	return value
}

stormancer_token_raknet_endpoints :: proc(token_json: string, allocator := context.allocator) -> []string {
	needle := `"raknet":[`
	start := strings.index(token_json, needle)
	if start < 0 do return nil
	p := start + len(needle)
	out := make([dynamic]string, allocator)
	for p < len(token_json) {
		for p < len(token_json) && (token_json[p] == ' ' || token_json[p] == ',') do p += 1
		if p >= len(token_json) || token_json[p] == ']' do break
		value, next, ok := json_string_at(token_json, p, allocator)
		if !ok do break
		append(&out, strings.clone(value, allocator))
		p = next
	}
	return out[:]
}

json_object_section :: proc(s, key: string) -> string {
	needle := strings.concatenate({`"`, key, `":{`}, context.temp_allocator)
	defer free_all(context.temp_allocator)
	start := strings.index(s, needle)
	if start < 0 do return ""
	open := start + len(needle) - 1
	depth := 0
	in_string := false
	escaped := false
	for i in open ..< len(s) {
		ch := s[i]
		if in_string {
			if escaped do escaped = false
			else if ch == '\\' do escaped = true
			else if ch == '"' do in_string = false
			continue
		}
		if ch == '"' do in_string = true
		else if ch == '{' do depth += 1
		else if ch == '}' {
			depth -= 1
			if depth == 0 do return s[open:i + 1]
		}
	}
	return ""
}

json_string_at :: proc(s: string, off: int, allocator := context.allocator) -> (string, int, bool) {
	if off < 0 || off >= len(s) || s[off] != '"' do return "", off, false
	p := off + 1
	out := strings.builder_make(allocator)
	escaped := false
	for p < len(s) {
		ch := s[p]
		if escaped {
			if ch == 'u' && p + 4 < len(s) {
				if decoded, ok := json_hex_escape_byte(s[p + 1:p + 5]); ok {
					strings.write_byte(&out, decoded)
					p += 4
				} else {
					strings.write_byte(&out, ch)
				}
			} else {
				strings.write_byte(&out, ch)
			}
			escaped = false
		} else if ch == '\\' {
			escaped = true
		} else if ch == '"' {
			return strings.to_string(out), p + 1, true
		} else {
			strings.write_byte(&out, ch)
		}
		p += 1
	}
	return "", off, false
}

json_hex_escape_byte :: proc(hex_text: string) -> (byte, bool) {
	if len(hex_text) != 4 || hex_text[0] != '0' || hex_text[1] != '0' do return 0, false
	hi, ok_hi := json_hex_nibble(hex_text[2])
	lo, ok_lo := json_hex_nibble(hex_text[3])
	if !ok_hi || !ok_lo do return 0, false
	return byte(hi << 4 | lo), true
}

json_hex_nibble :: proc(c: byte) -> (u8, bool) {
	if c >= '0' && c <= '9' do return u8(c - '0'), true
	if c >= 'a' && c <= 'f' do return u8(c - 'a' + 10), true
	if c >= 'A' && c <= 'F' do return u8(c - 'A' + 10), true
	return 0, false
}

parse_stormancer_rpc_next_tail :: proc(
	raw: []byte,
	allocator := context.allocator,
) -> ([]Stormancer_Rpc_Next_Tail_Route, string, string, string, []byte) {
	out := make([dynamic]Stormancer_Rpc_Next_Tail_Route, allocator)
	if len(raw) == 0 do return out[:], "", "", "", nil
	if routes, plugin, plugin_version, serializer, rest, ok := parse_stormancer_rpc_next_msgpack_tail(raw, allocator); ok {
		return routes, plugin, plugin_version, serializer, rest
	}
	p := 0
	route_name := ""
	if handle_at := scene_tail_find_msgpack_str(raw, "Handle", 0); handle_at > 0 && scene_tail_bytes_printable(raw[:handle_at]) {
		route_name = string(raw[:handle_at])
		p = handle_at
	}
	for p < len(raw) {
		if route_name == "" {
			if route, next_pos, ok := scene_tail_read_route_map(raw, p, allocator); ok {
				append(&out, route)
				p = next_pos
				continue
			}
			key, next_pos, ok := scene_tail_read_msgpack_str(raw, p)
			if !ok || key != "Name" do break
			route_name, p, ok = scene_tail_read_msgpack_str(raw, next_pos)
			if !ok do break
		}
		key, next_pos, ok := scene_tail_read_msgpack_str(raw, p)
		if !ok || key != "Handle" do break
		handle, after_handle, handle_ok := scene_tail_read_msgpack_uint(raw, next_pos)
		if !handle_ok do break
		metadata_key, after_key, key_ok := scene_tail_read_msgpack_str(raw, after_handle)
		if !key_ok || metadata_key != "Metadata" do break
		metadata, meta_next, meta_ok := scene_tail_read_metadata(raw, after_key, allocator)
		if !meta_ok do break
		append(&out, Stormancer_Rpc_Next_Tail_Route{name = route_name, handle = handle, metadata = metadata})
		p = meta_next
		route_name = ""
	}
	serializer := ""
	if text, next_pos, ok := scene_tail_read_msgpack_str(raw, p); ok {
		serializer = text
		p = next_pos
	}
	return out[:], "", "", serializer, raw[p:]
}

parse_stormancer_rpc_next_msgpack_tail :: proc(
	raw: []byte,
	allocator := context.allocator,
) -> ([]Stormancer_Rpc_Next_Tail_Route, string, string, string, []byte, bool) {
	out := make([dynamic]Stormancer_Rpc_Next_Tail_Route, allocator)
	plugin_builder := strings.builder_make(allocator)
	p := 0
	for p < len(raw) {
		if raw[p] > 0x7f || raw[p] < 0x20 do break
		strings.write_byte(&plugin_builder, raw[p])
		p += 1
	}
	plugin := strings.to_string(plugin_builder)
	if plugin == "" do return nil, "", "", "", nil, false
	if plugin != "stormancer.plugins.rpc" do return nil, "", "", "", nil, false
	plugin_version, next_pos, ok := scene_tail_read_msgpack_str(raw, p)
	if !ok do return nil, "", "", "", nil, false
	p = next_pos
	for p < len(raw) {
		if selected, _, ok_selected := scene_tail_read_msgpack_str(raw, p); ok_selected && selected == "SelectedSerializer" do break
		route, route_next, route_ok := scene_tail_read_route_map(raw, p, allocator)
		if !route_ok do break
		append(&out, route)
		p = route_next
	}
	serializer := ""
	if selected, after_selected, ok_selected := scene_tail_read_msgpack_str(raw, p); ok_selected && selected == "SelectedSerializer" {
		if text, after_serializer, ok_serializer := scene_tail_read_msgpack_str(raw, after_selected); ok_serializer {
			serializer = text
			p = after_serializer
		}
	}
	return out[:], plugin, plugin_version, serializer, raw[p:], true
}

scene_tail_read_route_map :: proc(
	data: []byte,
	off: int,
	allocator := context.allocator,
) -> (Stormancer_Rpc_Next_Tail_Route, int, bool) {
	end, ok := msgpack_value_end(data, off)
	if !ok do return {}, off, false
	seq := msgpack_decode_seq(data[off:end], allocator = allocator)
	if !seq.ok || len(seq.roots) == 0 do return {}, off, false
	root := seq.roots[0]
	if root < 0 || root >= len(seq.nodes) || seq.nodes[root].kind != .Map do return {}, off, false
	name := scene_map_string(seq.nodes, root, "Name")
	handle := scene_node_uint(seq.nodes, msgpack_map_get(seq.nodes, root, "Handle"))
	metadata_idx := msgpack_map_get(seq.nodes, root, "Metadata")
	metadata := collect_metadata(seq.nodes, metadata_idx, allocator)
	if name == "" do return {}, off, false
	return Stormancer_Rpc_Next_Tail_Route{name = name, handle = handle, metadata = metadata}, end, true
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

parse_friends_notification_body :: proc(
	body: Scene_Body,
	allocator := context.allocator,
) -> Friends_Notification_Body {
	values := body.values
	raw_tail := body.raw_tail
	if end, ok := msgpack_value_end(body.values.raw, 0); ok && end < len(body.values.raw) {
		values = msgpack_decode_seq(body.values.raw[:end], allocator = allocator)
		raw_tail = scene_concat_raw_tail(body.values.raw[end:], body.raw_tail, allocator)
	}
	count := 0
	if r := scene_seq_root(Scene_Body{values = values}, 0); r >= 0 && values.nodes[r].kind == .Array do count = values.nodes[r].count
	return Friends_Notification_Body{notification_count = count, values = values, raw_tail = raw_tail}
}

scene_concat_raw_tail :: proc(a, b: []byte, allocator := context.allocator) -> []byte {
	if len(a) == 0 do return b
	if len(b) == 0 do return a
	out := make([]byte, len(a) + len(b), allocator)
	copy(out[:len(a)], a)
	copy(out[len(a):], b)
	return out
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
		raw_tail = body.raw_tail,
	}
}

parse_locator_get_scene_connection_token_body :: proc(
	body: Scene_Body,
) -> Locator_GetSceneConnectionToken_Body {
	scene_type := scene_root_text(body, 0)
	scene_id := scene_root_text(body, 1)
	if (scene_type == "" || scene_id == "") && body.has_rpc_id {
		if text, next, ok := scene_tail_read_msgpack_str(body.values.raw, 0); ok {
			scene_type = text
			if text2, _, ok2 := scene_tail_read_msgpack_str(body.values.raw, next); ok2 do scene_id = text2
		}
	}
	return Locator_GetSceneConnectionToken_Body {
		rpc_id = body.rpc_id,
		scene_type = scene_type,
		scene_id = scene_id,
	}
}

parse_party_state_response_body :: proc(
	body: Scene_Body,
	allocator := context.allocator,
) -> Party_State_Response_Body {
	nodes := body.values.nodes
	root := scene_seq_root(body, 0)
	members_idx := scene_array_child(nodes, root, 2)
	members := make([dynamic]Party_State_Member, allocator)
	child := members_idx + 1
	if members_idx >= 0 && members_idx < len(nodes) && nodes[members_idx].kind == .Array {
		for _ in 0 ..< nodes[members_idx].count {
			if child < 0 || child >= len(nodes) do break
			append(&members, scene_parse_party_state_member(nodes, child, allocator))
			child += nodes[child].subtree
		}
	}
	return Party_State_Response_Body {
		rpc_id = body.rpc_id,
		settings = scene_parse_party_settings(nodes, scene_array_child(nodes, root, 0)),
		leader_user_id = scene_node_text(nodes, scene_array_child(nodes, root, 1)),
		members = members[:],
		revision = scene_node_uint(nodes, scene_array_child(nodes, root, 3)),
		connection_metadata = scene_parse_connection_metadata_trailer(body.raw_tail),
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
		tail_values = scene_member_data_tail_values(body, 2, allocator),
		raw_tail = body.raw_tail,
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
		raw_tail = body.raw_tail,
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
		raw_tail = body.raw_tail,
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

scene_parse_party_state_member :: proc(
	nodes: []Msgpack_Node,
	idx: int,
	allocator := context.allocator,
) -> Party_State_Member {
	json := scene_node_text(nodes, scene_array_child(nodes, idx, 2))
	session_token := scene_node_bin(nodes, scene_array_child(nodes, idx, 3))
	return Party_State_Member {
		user_id = scene_node_text(nodes, scene_array_child(nodes, idx, 0)),
		connection_state = scene_node_uint(nodes, scene_array_child(nodes, idx, 1)),
		userdata_json = json,
		userdata = parse_party_member_userdata(json),
		session_token_hex = string(hex.encode(session_token, allocator)),
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
		server_status = scene_map_string(nodes, scene_array_child(nodes, idx, 5), "stormancer.partyStatus"),
		server_status_details = scene_map_string(nodes, scene_array_child(nodes, idx, 5), "stormancer.partyStatus.details"),
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

scene_body_is_party_state_response :: proc(body: Scene_Body) -> bool {
	nodes := body.values.nodes
	root := scene_seq_root(body, 0)
	if root < 0 || root >= len(nodes) || nodes[root].kind != .Array || nodes[root].count < 4 do return false
	settings := scene_array_child(nodes, root, 0)
	leader := scene_array_child(nodes, root, 1)
	members := scene_array_child(nodes, root, 2)
	return settings >= 0 && settings < len(nodes) && nodes[settings].kind == .Array && nodes[settings].count >= 8 &&
	       leader >= 0 && leader < len(nodes) && nodes[leader].kind == .Str &&
	       members >= 0 && members < len(nodes) && nodes[members].kind == .Array
}

scene_parse_connection_metadata_trailer :: proc(raw: []byte) -> Scene_Connection_Metadata_Trailer {
	out := Scene_Connection_Metadata_Trailer{raw = raw}
	if len(raw) == 0 do return out
	start := -1
	for i in 0 ..< len(raw) {
		key, _, ok := scene_tail_read_msgpack_str(raw, i)
		if ok && scene_connection_metadata_key_known(key) {
			start = i
			break
		}
	}
	if start < 0 {
		out.opaque_connection_data = raw
		return out
	}
	out.plugin_suffix = string(raw[:start])
	i := start
	for i < len(raw) {
		key, next, ok := scene_tail_read_msgpack_str(raw, i)
		if !ok || !scene_connection_metadata_key_known(key) do break
		value, value_next, value_ok := scene_tail_read_msgpack_str(raw, next)
		if !value_ok do break
		scene_connection_metadata_set(&out, key, value)
		i = value_next
	}
	if i < len(raw) do out.opaque_connection_data = raw[i:]
	return out
}

scene_connection_metadata_key_known :: proc(key: string) -> bool {
	switch key {
	case "protocol", "server.name", "stormancer.partymanagement", "server.version", "type", "serializers", "platform":
		return true
	}
	return false
}

scene_connection_metadata_set :: proc(out: ^Scene_Connection_Metadata_Trailer, key, value: string) {
	switch key {
	case "protocol":
		out.protocol = value
	case "server.name":
		out.server_name = value
	case "stormancer.partymanagement":
		out.party_management = value
	case "server.version":
		out.server_version = value
	case "type":
		out.server_type = value
	case "serializers":
		out.serializers = value
	case "platform":
		out.platform = value
	}
}

scene_tail_read_msgpack_str :: proc(data: []byte, off: int) -> (string, int, bool) {
	if off < 0 || off >= len(data) do return "", off, false
	c := data[off]
	p := off + 1
	n := 0
	switch {
	case c >= 0xa0 && c <= 0xbf:
		n = int(c & 0x1f)
	case c == 0xd9:
		if p >= len(data) do return "", off, false
		n = int(data[p]); p += 1
	case c == 0xda:
		if p + 2 > len(data) do return "", off, false
		n = int(read_u16_be(data, p)); p += 2
	case c == 0xdb:
		if p + 4 > len(data) do return "", off, false
		n = int(read_u32_be(data, p)); p += 4
	case:
		return "", off, false
	}
	if n < 0 || p + n > len(data) do return "", off, false
	return string(data[p:p + n]), p + n, true
}

scene_tail_find_msgpack_str :: proc(data: []byte, value: string, start: int) -> int {
	for i in start ..< len(data) {
		text, _, ok := scene_tail_read_msgpack_str(data, i)
		if ok && text == value do return i
	}
	return -1
}

scene_tail_bytes_printable :: proc(data: []byte) -> bool {
	if len(data) == 0 do return false
	for c in data {
		if c < 0x20 || c > 0x7e do return false
	}
	return true
}

scene_tail_read_msgpack_uint :: proc(data: []byte, off: int) -> (u64, int, bool) {
	if off < 0 || off >= len(data) do return 0, off, false
	c := data[off]
	p := off + 1
	switch {
	case c <= 0x7f:
		return u64(c), p, true
	case c == 0xcc:
		if p + 1 > len(data) do return 0, off, false
		return u64(data[p]), p + 1, true
	case c == 0xcd:
		if p + 2 > len(data) do return 0, off, false
		return u64(read_u16_be(data, p)), p + 2, true
	case c == 0xce:
		if p + 4 > len(data) do return 0, off, false
		return u64(read_u32_be(data, p)), p + 4, true
	}
	return 0, off, false
}

scene_tail_read_metadata :: proc(
	data: []byte,
	off: int,
	allocator := context.allocator,
) -> ([]Metadata_Entry, int, bool) {
	end, ok := msgpack_value_end(data, off)
	if !ok do return nil, off, false
	seq := msgpack_decode_seq(data[off:end], allocator = allocator)
	if !seq.ok || len(seq.roots) == 0 do return nil, off, false
	root := seq.roots[0]
	if root < 0 || root >= len(seq.nodes) || seq.nodes[root].kind != .Map do return nil, off, false
	out := make([dynamic]Metadata_Entry, allocator)
	j := root + 1
	for _ in 0 ..< seq.nodes[root].count {
		if j < 0 || j >= len(seq.nodes) do break
		key := scene_node_text(seq.nodes, j)
		j += seq.nodes[j].subtree
		if j < 0 || j >= len(seq.nodes) do break
		value := scene_node_text(seq.nodes, j)
		j += seq.nodes[j].subtree
		append(&out, Metadata_Entry{key, value})
	}
	return out[:], end, true
}

scene_root_text :: proc(body: Scene_Body, root_index: int) -> string {
	return scene_node_text(body.values.nodes, scene_seq_root(body, root_index))
}

scene_root_uint :: proc(body: Scene_Body, root_index: int) -> u64 {
	return scene_node_uint(body.values.nodes, scene_seq_root(body, root_index))
}

scene_member_data_tail_values :: proc(
	body: Scene_Body,
	start: int,
	allocator := context.allocator,
) -> []Party_MemberData_Tail_Value {
	out := make([dynamic]Party_MemberData_Tail_Value, allocator)
	for root_index in start ..< len(body.values.roots) {
		append(&out, scene_member_data_tail_value(body.values.nodes, scene_seq_root(body, root_index)))
	}
	return out[:]
}

scene_member_data_tail_value :: proc(nodes: []Msgpack_Node, idx: int) -> Party_MemberData_Tail_Value {
	if idx < 0 || idx >= len(nodes) do return Party_MemberData_Tail_Value{kind = .Nil}
	node := nodes[idx]
	#partial switch node.kind {
	case .Nil:
		return Party_MemberData_Tail_Value{kind = .Nil}
	case .Bool:
		return Party_MemberData_Tail_Value{kind = .Bool, bool_value = node.b}
	case .Int:
		return Party_MemberData_Tail_Value{kind = .Int, int_value = node.i}
	case .Uint:
		return Party_MemberData_Tail_Value{kind = .Uint, uint_value = node.u}
	case .Str:
		return Party_MemberData_Tail_Value{kind = .Str, text = node.str}
	case .Bin:
		return Party_MemberData_Tail_Value{kind = .Bin, bytes = node.bin}
	case:
		return Party_MemberData_Tail_Value{kind = .Nil}
	}
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
