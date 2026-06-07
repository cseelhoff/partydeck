package caleb_raknet

import "core:encoding/hex"
import "core:fmt"
import "core:strings"

Stormancer_Timestamp :: struct {
	seconds:     u64,
	nanoseconds: u32,
}

User_Session_Profile :: struct {
	pseudo:            string,
	steam_id:          string,
	crossplay_enabled: bool,
	has_crossplay:     bool,
}

User_Session_User :: struct {
	user_id:        string,
	steam_id:       string,
	profile:        User_Session_Profile,
	created:        Stormancer_Timestamp,
	updated:        Stormancer_Timestamp,
	metadata_count: int,
	provider:       string,
	reserved_nil:   bool,
}

User_Session_Metadata :: struct {
	steam_app_id:     u32,
	has_steam_app_id: bool,
	client_version:   string,
}

User_Session_Data :: struct {
	ok:                  bool,
	raw:                 []byte,
	payload_len:         int,
	login_provider:      string,
	login_provider_id:   string,
	user:                User_Session_User,
	session_id:          []byte,
	steam_identity:      string,
	metadata:            User_Session_Metadata,
	expiration:          Stormancer_Timestamp,
	authenticator_scene: string,
	reserved_nil:        bool,
	flags:               u64,
	tail:                []byte,
}

parse_user_session_data :: proc(data: []byte, allocator := context.allocator) -> User_Session_Data {
	out := User_Session_Data{raw = data}
	if len(data) < 4 do return out
	out.payload_len = int(read_u32_be(data, 0))
	if out.payload_len != len(data) - 4 do return out
	seq := msgpack_decode_seq(data[4:], allocator = allocator)
	if !seq.ok || len(seq.roots) == 0 do return out
	root := seq.roots[0]
	if root < 0 || root >= len(seq.nodes) || seq.nodes[root].kind != .Array || seq.nodes[root].count < 9 do return out
	nodes := seq.nodes
	login_provider := scene_array_child(nodes, root, 0)
	out.login_provider = scene_node_text(nodes, scene_array_child(nodes, login_provider, 0))
	out.login_provider_id = scene_node_text(nodes, scene_array_child(nodes, login_provider, 1))
	out.user = parse_user_session_user(nodes, scene_array_child(nodes, root, 1))
	out.session_id = scene_node_bin(nodes, scene_array_child(nodes, root, 2))
	out.steam_identity = scene_map_string(nodes, scene_array_child(nodes, root, 3), "steam")
	out.metadata = parse_user_session_metadata(nodes, scene_array_child(nodes, root, 4))
	out.expiration = user_session_timestamp(nodes, scene_array_child(nodes, root, 5))
	out.authenticator_scene = scene_node_text(nodes, scene_array_child(nodes, root, 6))
	out.reserved_nil = scene_node_is_nil(nodes, scene_array_child(nodes, root, 7))
	out.flags = scene_node_uint(nodes, scene_array_child(nodes, root, 8))
	out.ok = true
	return out
}

parse_user_session_user :: proc(nodes: []Msgpack_Node, idx: int) -> User_Session_User {
	return User_Session_User{
		user_id = scene_node_text(nodes, scene_array_child(nodes, idx, 0)),
		steam_id = scene_map_string(nodes, msgpack_map_get(nodes, scene_array_child(nodes, idx, 1), "steam"), "steamid"),
		profile = parse_user_session_profile(nodes, scene_array_child(nodes, idx, 2)),
		created = user_session_timestamp(nodes, scene_array_child(nodes, idx, 3)),
		updated = user_session_timestamp(nodes, scene_array_child(nodes, idx, 4)),
		metadata_count = scene_node_count(nodes, scene_array_child(nodes, idx, 5)),
		provider = scene_node_text(nodes, scene_array_child(nodes, idx, 6)),
		reserved_nil = scene_node_is_nil(nodes, scene_array_child(nodes, idx, 7)),
	}
}

parse_user_session_profile :: proc(nodes: []Msgpack_Node, idx: int) -> User_Session_Profile {
	options := msgpack_map_get(nodes, idx, "options")
	crossplay := msgpack_map_get(nodes, options, "crossplay")
	enabled_idx := msgpack_map_get(nodes, crossplay, "enabled")
	return User_Session_Profile{
		pseudo = scene_map_string(nodes, idx, "pseudo"),
		steam_id = scene_map_string(nodes, idx, "steamid"),
		crossplay_enabled = scene_node_bool(nodes, enabled_idx),
		has_crossplay = enabled_idx >= 0,
	}
}

parse_user_session_metadata :: proc(nodes: []Msgpack_Node, idx: int) -> User_Session_Metadata {
	out: User_Session_Metadata
	app_id := scene_node_bin(nodes, msgpack_map_get(nodes, idx, "steam.appId"))
	if len(app_id) == 4 {
		out.steam_app_id = u32(app_id[0]) | (u32(app_id[1]) << 8) | (u32(app_id[2]) << 16) | (u32(app_id[3]) << 24)
		out.has_steam_app_id = true
	}
	client_version := scene_node_bin(nodes, msgpack_map_get(nodes, idx, "gameVersion.clientVersion"))
	if len(client_version) >= 4 && int(read_u32_be(client_version, 0)) == len(client_version) - 4 {
		version_nodes, ok := msgpack_decode(client_version[4:], allocator = context.temp_allocator)
		if ok && len(version_nodes) > 0 && version_nodes[0].kind == .Str {
			out.client_version = version_nodes[0].str
		}
	}
	return out
}

user_session_timestamp :: proc(nodes: []Msgpack_Node, idx: int) -> Stormancer_Timestamp {
	if idx < 0 || idx >= len(nodes) do return {}
	node := nodes[idx]
	if node.kind != .Ext || node.ext_type != -1 || len(node.bin) != 8 do return {}
	v := read_u64_be(node.bin, 0)
	return Stormancer_Timestamp{
		seconds = v & 0x3_FFFF_FFFF,
		nanoseconds = u32(v >> 34),
	}
}

encode_user_session_data :: proc(data: User_Session_Data, allocator := context.allocator) -> []byte {
	if len(data.raw) > 0 do return data.raw
	profile_pairs := [][]byte{
		mpe_str("pseudo", allocator), mpe_str(data.user.profile.pseudo, allocator),
		mpe_str("options", allocator), mpe_map({mpe_str("crossplay", allocator), mpe_map({mpe_str("enabled", allocator), mpe_bool(data.user.profile.crossplay_enabled, allocator)}, allocator)}, allocator),
		mpe_str("steamid", allocator), mpe_str(data.user.profile.steam_id, allocator),
	}
	user_record := mpe_array(
		{
			mpe_str(data.user.user_id, allocator),
			mpe_map({mpe_str("steam", allocator), mpe_map({mpe_str("steamid", allocator), mpe_str(data.user.steam_id, allocator)}, allocator)}, allocator),
			mpe_map(profile_pairs, allocator),
			mpe_user_session_timestamp(data.user.created, allocator),
			mpe_user_session_timestamp(data.user.updated, allocator),
			mpe_map({}, allocator),
			mpe_str(data.user.provider, allocator),
			mpe_nil(allocator),
		},
		allocator,
	)
	metadata_pairs := [][]byte{
		mpe_str("steam.appId", allocator), mpe_bin(user_session_u32_le_bytes(data.metadata.steam_app_id, allocator), allocator),
		mpe_str("gameVersion.clientVersion", allocator), mpe_bin(user_session_prefixed_msgpack_str(data.metadata.client_version, allocator), allocator),
	}
	payload := mpe_array(
		{
			mpe_array({mpe_str(data.login_provider, allocator), mpe_str(data.login_provider_id, allocator)}, allocator),
			user_record,
			mpe_bin(data.session_id, allocator),
			mpe_map({mpe_str("steam", allocator), mpe_str(data.steam_identity, allocator)}, allocator),
			mpe_map(metadata_pairs, allocator),
			mpe_user_session_timestamp(data.expiration, allocator),
			mpe_str(data.authenticator_scene, allocator),
			mpe_nil(allocator),
			mpe_uint(data.flags, allocator),
		},
		allocator,
	)
	out := make([dynamic]byte, allocator)
	write_u32_be(&out, u32(len(payload)))
	append(&out, ..payload)
	return out[:]
}

mpe_user_session_timestamp :: proc(value: Stormancer_Timestamp, allocator := context.allocator) -> []byte {
	return mpe_timestamp(value.seconds, u64(value.nanoseconds), allocator)
}

user_session_u32_le_bytes :: proc(value: u32, allocator := context.allocator) -> []byte {
	out := make([]byte, 4, allocator)
	out[0] = byte(value)
	out[1] = byte(value >> 8)
	out[2] = byte(value >> 16)
	out[3] = byte(value >> 24)
	return out
}

user_session_prefixed_msgpack_str :: proc(value: string, allocator := context.allocator) -> []byte {
	encoded := mpe_str(value, allocator)
	out := make([dynamic]byte, allocator)
	write_u32_be(&out, u32(len(encoded)))
	append(&out, ..encoded)
	return out[:]
}

user_session_id_from_user_id :: proc(user_id, steam_id: string, allocator := context.allocator) -> []byte {
	if len(user_id) >= 32 {
		decoded, ok := hex.decode(transmute([]byte)user_id[:32], allocator)
		if ok && len(decoded) == 16 do return decoded
	}
	out := make([]byte, 16, allocator)
	source := transmute([]byte)steam_id
	for i in 0 ..< len(out) {
		if len(source) > 0 do out[i] = source[i % len(source)]
	}
	return out
}

write_user_session_data :: proc(sb: ^strings.Builder, data: User_Session_Data) {
	if !data.ok {
		strings.write_string(sb, "userSession<unparsed>")
		return
	}
	fmt.sbprintf(sb, "userSession{{bytes=%d, payload_len=%d", len(data.raw), data.payload_len)
	fmt.sbprintf(sb, ", login_provider=[%q, %q]", data.login_provider, data.login_provider_id)
	fmt.sbprintf(sb, ", user={{id=%q, platforms={{steam={{steamid=%q}}}}, profile={{pseudo=%q, options={{crossplay={{enabled=%v}}}}, steamid=%q}}", data.user.user_id, data.user.steam_id, data.user.profile.pseudo, data.user.profile.crossplay_enabled, data.user.profile.steam_id)
	write_user_session_timestamp_field(sb, ", created=", data.user.created)
	write_user_session_timestamp_field(sb, ", updated=", data.user.updated)
	fmt.sbprintf(sb, ", metadata={{}}, provider=%q, reserved=nil}}", data.user.provider)
	strings.write_string(sb, ", session_id=hex:")
	hex_text := hex.encode(data.session_id, context.temp_allocator)
	strings.write_string(sb, string(hex_text))
	fmt.sbprintf(sb, ", identities={{steam=%q}}", data.steam_identity)
	fmt.sbprintf(sb, ", metadata={{steam.appId={{u32_le=%d}}, gameVersion.clientVersion={{u32be_msgpack=%q}}}}", data.metadata.steam_app_id, data.metadata.client_version)
	write_user_session_timestamp_field(sb, ", expiration=", data.expiration)
	fmt.sbprintf(sb, ", authenticator_scene=%q, reserved=nil, flags=%d}}", data.authenticator_scene, data.flags)
}

write_user_session_timestamp_field :: proc(sb: ^strings.Builder, name: string, value: Stormancer_Timestamp) {
	fmt.sbprintf(sb, "%s{{sec=%d, ns=%d}}", name, value.seconds, value.nanoseconds)
}