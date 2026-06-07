package caleb_raknet

// Layer 4 (inverse): re-encode a Decoded_Message back into the exact RakNet_Message
// byte array it was decoded from. This is the encoder half of frames.odin's
// decode_message, and the round-trip property
//
//     encode_message(decode_message(bytes)) == bytes
//
// is what verify_roundtrip (main.odin) asserts over a whole capture. Byte-exactness
// is the proof that the decoder dropped nothing: every variant either rebuilds its
// body from the scalars it parsed (fixed-width frames) or carries the original blob
// verbatim (the raw / trailer / internal_list slices added in frames.odin).
//
// No OOP, no methods -- a switch over the same tagged union, writing into a caller-
// owned byte buffer. Output uses `allocator`; the caller owns the returned slice.

import "core:encoding/base64"
import "core:encoding/hex"
import "core:slice"

// Re-encode `message` into its on-the-wire bytes (leading id + body). The result is
// a fresh slice allocated with `allocator`. For variants that retained the original
// payload, the bytes are reproduced exactly; for fixed-layout frames they are
// rebuilt field by field in wire order.
encode_message :: proc(message: Decoded_Message, allocator := context.allocator) -> []byte {
	b := make([dynamic]byte, allocator)

	switch f in message {
	case Connected_Ping:
		append(&b, u8(Message_Id.Connected_Ping))
		write_u64_be(&b, f.clock)

	case Connected_Pong:
		append(&b, u8(Message_Id.Connected_Pong))
		write_u64_be(&b, f.echo_clock)
		write_u64_be(&b, f.clock)

	case Connection_Request:
		append(&b, u8(Message_Id.Connection_Request))
		write_u64_be(&b, f.guid)
		write_u64_be(&b, f.time)
		// guid+time are the first 16 body bytes; `trailer` is everything after them
		// (the security byte and any padding) kept verbatim so a present-but-zero
		// security byte round-trips distinctly from an absent one.
		append(&b, ..f.trailer)

	case Connection_Request_Accepted:
		append(&b, u8(Message_Id.Connection_Request_Accepted))
		encode_system_address(&b, f.remote)
		write_u16_be(&b, f.system_index)
		for k in 0 ..< MAX_INTERNAL_IDS {
			encode_system_address(&b, f.internal[k])
		}
		write_u64_be(&b, f.echo_time)
		write_u64_be(&b, f.server_time)

	case New_Incoming_Connection:
		append(&b, u8(Message_Id.New_Incoming_Connection))
		encode_system_address(&b, f.server)
		// The internal-address list has a non-fixed stride (IPv4/IPv6), so it was kept
		// as an opaque span rather than parsed -- write it back unchanged.
		append(&b, ..f.internal_list)
		write_u64_be(&b, f.ping_time)
		write_u64_be(&b, f.pong_time)

	case Disconnection_Notification:
		append(&b, u8(Message_Id.Disconnection_Notification))

	case System_Request:
		append(&b, u8(Message_Id.System_Request))
		append(&b, u8(f.msg_id))
		write_u16_le(&b, f.req_id)
		// The typed `args` normalizes map order and cannot reproduce the original
		// msgpack bytes; `raw_args` is that original args blob, written verbatim.
		append(&b, ..f.raw_args)

	case Response_Msg:
		append(&b, u8(Message_Id.Response_Msg))
		write_u16_le(&b, f.req_id)
		// `data` is a typed view; `raw` is the undecoded payload after req_id.
		// Decoded capture messages keep `raw` for byte-exact round-trip, while
		// simple_net responses are built as typed values and need fresh encoding.
		if len(f.raw) > 0 {
			append(&b, ..f.raw)
		} else {
			append(&b, ..encode_response_data(f.data, allocator))
		}

	case Response_Complete:
		append(&b, u8(Message_Id.Response_Complete))
		write_u16_le(&b, f.req_id)
		append(&b, f.has_values ? 1 : 0)

	case Response_Error:
		append(&b, u8(Message_Id.Response_Error))
		write_u16_le(&b, f.req_id)
		// decode_msgpack_field aliased the body after req_id into data.raw.
		append(&b, ..f.data.raw)

	case Connection_Result:
		append(&b, u8(Message_Id.Connection_Result))
		write_u64_le(&b, f.connection_id)

	case Scene_Message:
		// scene_handle is itself the leading id byte (>= SCENE_HANDLE_MIN).
		append(&b, f.scene_handle)
		write_u16_le(&b, f.route_handle)
		append(&b, ..encode_scene_message_body(f.body, f.raw_body, allocator))

	case Malformed_Message:
		// Could not be parsed; `raw` is the full original message (id included).
		append(&b, ..f.raw)

	case Unknown_Message:
		append(&b, f.id)
		append(&b, ..f.body)
	}

	return b[:]
}

encode_response_data :: proc(data: Response_Data, allocator := context.allocator) -> []byte {
	#partial switch d in data {
	case Scene_Infos:
		return encode_scene_infos_response(d, allocator)
	case Scene_Connection_Result:
		return encode_scene_connection_result_response(d, allocator)
	case Bool_Result:
		return mpe_map({mpe_str("v", allocator), mpe_bool(d.value, allocator)}, allocator)
	case Session_Token:
		return mpe_concat(mpe_str(d.jwt, allocator), mpe_str(d.session_id, allocator), allocator = allocator)
	case Ping_Response:
		out := make([dynamic]byte, allocator)
		write_u64_le(&out, d.server_clock)
		write_u64_le(&out, d.echo_clock)
		return out[:]
	case Other_Response:
		return d.data.raw
	}
	return {}
}

encode_scene_infos_response :: proc(info: Scene_Infos, allocator := context.allocator) -> []byte {
	metadata := make([dynamic][]byte, allocator)
	encode_scene_infos_metadata_pair(&metadata, "accountId", info.account_id, allocator)
	encode_scene_infos_metadata_pair(&metadata, "appId", info.app_id, allocator)
	encode_scene_infos_metadata_pair(&metadata, "darktales.gamesession", info.darktales_gamesession, allocator)
	encode_scene_infos_metadata_pair(&metadata, "stormancer.friends", info.stormancer_friends, allocator)
	encode_scene_infos_metadata_pair(&metadata, "stormancer.gamesession", info.stormancer_gamesession, allocator)
	encode_scene_infos_metadata_pair(&metadata, "stormancer.gameVersion", info.stormancer_game_version, allocator)
	encode_scene_infos_metadata_pair(&metadata, "stormancer.party", info.stormancer_party, allocator)
	encode_scene_infos_metadata_pair(&metadata, "stormancer.partymanagement", info.stormancer_partymanagement, allocator)
	encode_scene_infos_metadata_pair(&metadata, "stormancer.partyMerging", info.stormancer_party_merging, allocator)
	encode_scene_infos_metadata_pair(&metadata, "stormancer.party.revision", info.stormancer_party_revision, allocator)
	encode_scene_infos_metadata_pair(&metadata, "stormancer.plugins.gamefinder", info.stormancer_plugins_gamefinder, allocator)
	encode_scene_infos_metadata_pair(&metadata, "stormancer.plugins.gamefinder.protocol", info.stormancer_plugins_gamefinder_protocol, allocator)
	encode_scene_infos_metadata_pair(&metadata, "stormancer.plugins.nintendo", info.stormancer_plugins_nintendo, allocator)
	encode_scene_infos_metadata_pair(&metadata, "stormancer.plugins.psn", info.stormancer_plugins_psn, allocator)
	encode_scene_infos_metadata_pair(&metadata, "stormancer.plugins.rpc", info.stormancer_plugins_rpc, allocator)
	encode_scene_infos_metadata_pair(&metadata, "stormancer.plugins.steam", info.stormancer_plugins_steam, allocator)
	encode_scene_infos_metadata_pair(&metadata, "Stormancer.plugins.XBLServices.useModernGamerTag", info.stormancer_plugins_xbl_use_modern_gamertag, allocator)

	routes := make([dynamic][]byte, allocator)
	for route_name, route_index in info.routes {
		append(&routes, mpe_map(
			{
				mpe_str("Name", allocator),
				mpe_str(route_name, allocator),
				mpe_str("Handle", allocator),
				mpe_uint(u64(route_index), allocator),
				mpe_str("Metadata", allocator),
				mpe_byte(MP_EMPTY_MAP, allocator),
			},
			allocator,
		))
	}

	return mpe_map(
		{
			mpe_str("ShardId", allocator),
			mpe_uint(info.shard_id, allocator),
			mpe_str("SceneId", allocator),
			mpe_str(info.scene_id, allocator),
			mpe_str("Metadata", allocator),
			mpe_map(metadata[:], allocator),
			mpe_str("Routes", allocator),
			mpe_array(routes[:], allocator),
			mpe_str("SelectedSerializer", allocator),
			mpe_str(info.selected_serializer, allocator),
		},
		allocator,
	)
}

encode_scene_infos_metadata_pair :: proc(
	pairs: ^[dynamic][]byte,
	key: string,
	value: string,
	allocator := context.allocator,
) {
	if len(value) == 0 do return
	append(pairs, mpe_str(key, allocator))
	append(pairs, mpe_str(value, allocator))
}

encode_scene_connection_result_response :: proc(
	result: Scene_Connection_Result,
	allocator := context.allocator,
) -> []byte {
	route_pairs := make([dynamic][]byte, allocator)
	for route_name, route_index in result.routes {
		if len(route_name) == 0 do continue
		append(&route_pairs, mpe_str(route_name, allocator))
		append(&route_pairs, mpe_uint(u64(route_index + 1), allocator))
	}
	return mpe_map(
		{
			mpe_str("SceneHandle", allocator),
			mpe_uint(result.scene_handle, allocator),
			mpe_str("RouteMappings", allocator),
			mpe_map(route_pairs[:], allocator),
		},
		allocator,
	)
}

encode_scene_message_body :: proc(
	body: Scene_Message_Body,
	fallback_raw_body: []byte,
	allocator := context.allocator,
) -> []byte {
	#partial switch b in body {
	case Scene_Raw_Body:
		return b.raw
	case Stormancer_Rpc_Completed_Body:
		out := make([dynamic]byte, allocator)
		write_u16_le(&out, b.rpc_id)
		append(&out, 0)
		return out[:]
	case Stormancer_Rpc_Next_Body:
		return encode_stormancer_rpc_next_body(b, allocator)
	case Party_CreateInvitationCode_Result_Body:
		return encode_party_create_invitation_code_result_body(b, allocator)
	case GameVersion_Update_Body:
		return mpe_str(b.accepted_version, allocator)
	case Friends_Notification_Body:
		if len(b.friends) > 0 do return encode_friends_notification_body(b, allocator)
	case Steam_CreateLobby_Body:
		return encode_steam_create_lobby_body(b, allocator)
	case Party_State_Response_Body:
		return encode_party_state_response_body(b, allocator)
	case Party_SettingsUpdated_Body:
		return encode_party_settings_updated_body(b, allocator)
	case Party_MemberDataUpdated_Body:
		return encode_party_member_data_updated_body(b, allocator)
	case PartyMerging_GetMergerStatus_Result_Body:
		return encode_party_merging_get_merger_status_result_body(b, allocator)
	case Party_MemberConnected_Body:
		return encode_party_member_connected_body(b, allocator)
	}
	return fallback_raw_body
}

encode_party_merging_get_merger_status_result_body :: proc(
	body: PartyMerging_GetMergerStatus_Result_Body,
	allocator := context.allocator,
) -> []byte {
	out := make([dynamic]byte, allocator)
	write_u16_le(&out, body.rpc_id)
	details := mpe_map(
		{
			mpe_str("nbPartiesByDifficulty", allocator),
			encode_party_merging_difficulty_counts(body.nb_parties_by_difficulty, allocator),
			mpe_str("nbPlayersByDifficulty", allocator),
			encode_party_merging_difficulty_counts(body.nb_players_by_difficulty, allocator),
		},
		allocator,
	)
	status := mpe_map(
		{
			mpe_str("partiesCount", allocator),
			mpe_uint(body.parties_count, allocator),
			mpe_str("algorithm", allocator),
			mpe_str(body.algorithm, allocator),
			mpe_str("playersCount", allocator),
			mpe_uint(body.players_count, allocator),
			mpe_str("details", allocator),
			details,
		},
		allocator,
	)
	append(&out, ..mpe_array({mpe_uint(body.status, allocator), status}, allocator))
	return out[:]
}

encode_party_merging_difficulty_counts :: proc(
	counts: []PartyMerging_Difficulty_Count,
	allocator := context.allocator,
) -> []byte {
	pairs := make([dynamic][]byte, allocator)
	for count in counts {
		append(&pairs, mpe_str(count.difficulty, allocator))
		append(&pairs, mpe_uint(count.count, allocator))
	}
	return mpe_map(pairs[:], allocator)
}

encode_party_settings_updated_body :: proc(
	body: Party_SettingsUpdated_Body,
	allocator := context.allocator,
) -> []byte {
	out := make([dynamic]byte, allocator)
	write_u16_le(&out, body.rpc_id)
	append(&out, ..mpe_uint(body.version, allocator))
	append(&out, ..encode_party_settings(body.settings, allocator))
	return out[:]
}

encode_party_member_data_updated_body :: proc(
	body: Party_MemberDataUpdated_Body,
	allocator := context.allocator,
) -> []byte {
	out := make([dynamic]byte, allocator)
	write_u16_le(&out, body.rpc_id)
	append(&out, ..mpe_uint(body.version, allocator))
	append(&out, ..encode_party_member_data(body.member, allocator))
	for _ in 0 ..< body.extra_values do append(&out, ..mpe_uint(0, allocator))
	return out[:]
}

encode_party_member_data :: proc(member: Scene_Party_Member_Data, allocator := context.allocator) -> []byte {
	platforms := make([dynamic][]byte, allocator)
	for platform in member.platforms do append(&platforms, encode_scene_platform_identity(platform, allocator))
	return mpe_array(
		{
			mpe_str(member.user_id, allocator),
			mpe_bin(transmute([]byte)member.userdata_json, allocator),
			mpe_array(platforms[:], allocator),
			mpe_uint(member.state, allocator),
		},
		allocator,
	)
}

encode_party_create_invitation_code_result_body :: proc(
	body: Party_CreateInvitationCode_Result_Body,
	allocator := context.allocator,
) -> []byte {
	out := make([dynamic]byte, allocator)
	write_u16_le(&out, body.rpc_id)
	append(&out, ..mpe_str(body.invitation_code, allocator))
	return out[:]
}

encode_party_member_connected_body :: proc(
	body: Party_MemberConnected_Body,
	allocator := context.allocator,
) -> []byte {
	out := make([dynamic]byte, allocator)
	write_u16_le(&out, body.rpc_id)
	append(&out, ..mpe_uint(body.version, allocator))
	append(&out, ..encode_party_connected_member(body.member, allocator))
	append(&out, ..body.raw_tail)
	return out[:]
}

encode_party_connected_member :: proc(member: Scene_Party_Member_Connected, allocator := context.allocator) -> []byte {
	platforms := make([dynamic][]byte, allocator)
	for platform in member.platforms do append(&platforms, encode_scene_platform_identity(platform, allocator))
	return mpe_array(
		{
			mpe_str(member.user_id, allocator),
			mpe_uint(member.connection_state, allocator),
			mpe_bin(transmute([]byte)member.userdata_json, allocator),
			mpe_bin(member.session_token, allocator),
			mpe_array(platforms[:], allocator),
			mpe_uint(member.state, allocator),
		},
		allocator,
	)
}

encode_party_state_response_body :: proc(
	body: Party_State_Response_Body,
	allocator := context.allocator,
) -> []byte {
	out := make([dynamic]byte, allocator)
	write_u16_le(&out, body.rpc_id)
	members := make([dynamic][]byte, allocator)
	for member in body.members do append(&members, encode_party_state_member(member, allocator))
	append(
		&out,
		..mpe_array(
			{
				encode_party_settings(body.settings, allocator),
				mpe_str(body.leader_user_id, allocator),
				mpe_array(members[:], allocator),
				mpe_uint(body.revision, allocator),
			},
			allocator,
		),
	)
	return out[:]
}

encode_party_settings :: proc(settings: Scene_Party_Settings, allocator := context.allocator) -> []byte {
	return mpe_array(
		{
			mpe_str(settings.game_finder, allocator),
			mpe_str(settings.custom_data_json, allocator),
			mpe_uint(settings.revision, allocator),
			mpe_bool(settings.only_leader_invite, allocator),
			mpe_bool(settings.is_joinable, allocator),
			mpe_byte(MP_EMPTY_MAP, allocator),
			mpe_str(settings.public_data, allocator),
			mpe_str(settings.party_id, allocator),
		},
		allocator,
	)
}

encode_party_state_member :: proc(member: Party_State_Member, allocator := context.allocator) -> []byte {
	platforms := make([dynamic][]byte, allocator)
	for platform in member.platforms do append(&platforms, encode_scene_platform_identity(platform, allocator))
	session_token, ok := hex.decode(transmute([]byte)member.session_token_hex, allocator)
	if !ok do session_token = {}
	return mpe_array(
		{
			mpe_str(member.user_id, allocator),
			mpe_uint(member.connection_state, allocator),
			mpe_bin(transmute([]byte)member.userdata_json, allocator),
			mpe_bin(session_token, allocator),
			mpe_array(platforms[:], allocator),
			mpe_uint(member.state, allocator),
		},
		allocator,
	)
}

encode_scene_platform_identity :: proc(platform: Scene_Platform_Identity, allocator := context.allocator) -> []byte {
	extra := platform.extra_is_nil ? mpe_nil(allocator) : mpe_str(platform.extra, allocator)
	return mpe_array(
		{
			mpe_str(platform.provider, allocator),
			mpe_str(platform.user_id, allocator),
			mpe_str(platform.visibility, allocator),
			mpe_str(platform.platform_id, allocator),
			extra,
			mpe_uint(platform.flags, allocator),
		},
		allocator,
	)
}

encode_steam_create_lobby_body :: proc(
	body: Steam_CreateLobby_Body,
	allocator := context.allocator,
) -> []byte {
	out := make([dynamic]byte, allocator)
	write_u16_le(&out, body.rpc_id)
	token := body.party_data_token
	if len(token) == 0 && len(body.party_data_token_json) > 0 {
		encoded, err := base64.encode(transmute([]byte)body.party_data_token_json, base64.ENC_TABLE, allocator)
		if err == nil do token = string(encoded)
	}
	append(
		&out,
		..mpe_array(
			{
				mpe_uint(body.lobby_type, allocator),
				mpe_uint(body.max_members, allocator),
				mpe_bool(body.joinable, allocator),
				mpe_map({mpe_str("partyDataToken", allocator), mpe_str(token, allocator)}, allocator),
			},
			allocator,
		),
	)
	return out[:]
}

encode_stormancer_rpc_next_body :: proc(
	body: Stormancer_Rpc_Next_Body,
	allocator := context.allocator,
) -> []byte {
	out := make([dynamic]byte, allocator)
	write_u16_le(&out, body.rpc_id)
	#partial switch body.kind {
	case .Scene_Connection_Token:
		append(&out, ..mpe_str(body.token_json, allocator))
	case .Authentication_Login_Result:
		result := body.result_is_nil ? mpe_nil(allocator) : mpe_bool(false, allocator)
		identities := mpe_byte(MP_EMPTY_MAP, allocator)
		if len(body.steam_identity) > 0 {
			identities = mpe_map({mpe_str("steam", allocator), mpe_str(body.steam_identity, allocator)}, allocator)
		}
		append(
			&out,
			..mpe_array(
				{
					result,
					mpe_bool(body.success, allocator),
					mpe_str(body.user_id, allocator),
					mpe_str(body.error_message, allocator),
					identities,
					mpe_byte(MP_EMPTY_MAP, allocator),
				},
				allocator,
			),
		)
	case:
	}
	return out[:]
}

// True when `encode_message(decode_message(original))` reproduces `original`
// byte-for-byte. The decode uses `allocator` for its scratch trees; the re-encode
// allocates its output there too.
message_roundtrips :: proc(original: []byte, allocator := context.allocator) -> bool {
	decoded := decode_message(original, allocator)
	encoded := encode_message(decoded, allocator)
	return slice.equal(encoded, original)
}

// --- wire writers (inverses of the read_* helpers in frames.odin/messages.odin) --

write_u16_le :: proc(b: ^[dynamic]byte, v: u16) {
	append(b, u8(v), u8(v >> 8))
}

write_u16_be :: proc(b: ^[dynamic]byte, v: u16) {
	append(b, u8(v >> 8), u8(v))
}

write_u64_be :: proc(b: ^[dynamic]byte, v: u64) {
	append(
		b,
		u8(v >> 56),
		u8(v >> 48),
		u8(v >> 40),
		u8(v >> 32),
		u8(v >> 24),
		u8(v >> 16),
		u8(v >> 8),
		u8(v),
	)
}

write_u64_le :: proc(b: ^[dynamic]byte, v: u64) {
	append(
		b,
		u8(v),
		u8(v >> 8),
		u8(v >> 16),
		u8(v >> 24),
		u8(v >> 32),
		u8(v >> 40),
		u8(v >> 48),
		u8(v >> 56),
	)
}

// Inverse of decode_system_address: version(1) + one's-complemented IPv4(4) +
// port(2 BE). The octets are complemented on the wire, so re-complement on write.
encode_system_address :: proc(b: ^[dynamic]byte, a: System_Address) {
	append(b, a.version)
	append(b, ~a.ip[0], ~a.ip[1], ~a.ip[2], ~a.ip[3])
	write_u16_be(b, a.port)
}
