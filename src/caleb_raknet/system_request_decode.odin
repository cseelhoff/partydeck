package caleb_raknet

import "core:fmt"
import "core:strings"

Metadata_Entry :: struct {
	key:   string,
	value: string,
}

Connect_To_Scene_Args :: struct {
	token:                                             Connection_Token,
	routes:                                            Routes,
	scene_stormancer_plugins_rpc:                      string,
	scene_stormancer_plugins_nintendo:                 string,
	scene_stormancer_plugins_xbl_use_modern_gamertag:  string,
	scene_stormancer_plugins_steam:                    string,
	scene_app_id:                                      string,
	scene_account_id:                                  string,
	scene_stormancer_game_version:                     string,
	scene_stormancer_plugins_psn:                      string,
	connection_stormancer_party:                       string,
	connection_version:                                string,
	connection_server_name:                            string,
	connection_timeout:                                string,
	connection_server_version:                         string,
	connection_stormancer_party_plugin:                string,
	connection_stormancer_partymanagement:             string,
	connection_stormancer_plugins_gamefinder_protocol: string,
	connection_plugins:                                string,
	connection_serializers:                            string,
	connection_transport:                              string,
	connection_platform:                               string,
	connection_protocol:                               string,
	connection_type:                                   string,
	connection_serializer:                             string,
}

Get_Scene_Infos_Args :: struct {
	token:                                  Connection_Token,
	stormancer_party:                       string,
	version:                                string,
	server_name:                            string,
	timeout:                                string,
	server_version:                         string,
	stormancer_party_plugin:                string,
	stormancer_partymanagement:             string,
	stormancer_plugins_gamefinder_protocol: string,
	plugins:                                string,
	serializers:                            string,
	transport:                              string,
	platform:                               string,
	protocol:                               string,
	connection_type:                        string,
	serializer:                             string,
}

Set_Metadata_Args :: struct {
	stormancer_party:                       string,
	version:                                string,
	server_name:                            string,
	timeout:                                string,
	server_version:                         string,
	stormancer_party_plugin:                string,
	stormancer_partymanagement:             string,
	stormancer_plugins_gamefinder_protocol: string,
	plugins:                                string,
	serializers:                            string,
	transport:                              string,
	platform:                               string,
	protocol:                               string,
	connection_type:                        string,
	serializer:                             string,
}

Scene_Ready_Args :: struct {
	scene_handle:             u64,
	sent_game_version_update: bool,
}

Disconnect_From_Scene_Args :: struct {
	scene_handle: u64,
}

Ping_Args :: struct {
	clock: u64,
}

No_Args :: struct {}

Unparsed_Args :: struct {
	raw: []byte,
}

System_Request_Args :: union {
	Connect_To_Scene_Args,
	Get_Scene_Infos_Args,
	Set_Metadata_Args,
	Scene_Ready_Args,
	Disconnect_From_Scene_Args,
	Ping_Args,
	No_Args,
	Unparsed_Args,
}

parse_system_request_args :: proc(
	msg_id: System_Request_Id,
	args: Msgpack,
	allocator := context.allocator,
) -> System_Request_Args {
	n := args.nodes
	#partial switch msg_id {
	case .Connect_To_Scene:
		if !args.ok || len(n) == 0 || n[0].kind != .Map do return Unparsed_Args{args.raw}
		scene_metadata := collect_metadata(n, msgpack_map_get(n, 0, "SceneMetadata"), allocator)
		connection_metadata := collect_metadata(n, msgpack_map_get(n, 0, "ConnectionMetadata"), allocator)
		return Connect_To_Scene_Args {
			token = parse_connection_token(node_str(n, msgpack_map_get(n, 0, "Token")), allocator),
			routes = collect_routes(n, msgpack_map_get(n, 0, "Routes"), allocator),
			scene_stormancer_plugins_rpc = metadata_value(scene_metadata, "stormancer.plugins.rpc"),
			scene_stormancer_plugins_nintendo = metadata_value(scene_metadata, "stormancer.plugins.nintendo"),
			scene_stormancer_plugins_xbl_use_modern_gamertag = metadata_value(scene_metadata, "Stormancer.plugins.XBLServices.useModernGamerTag"),
			scene_stormancer_plugins_steam = metadata_value(scene_metadata, "stormancer.plugins.steam"),
			scene_app_id = metadata_value(scene_metadata, "appId"),
			scene_account_id = metadata_value(scene_metadata, "accountId"),
			scene_stormancer_game_version = metadata_value(scene_metadata, "stormancer.gameVersion"),
			scene_stormancer_plugins_psn = metadata_value(scene_metadata, "stormancer.plugins.psn"),
			connection_stormancer_party = metadata_value(connection_metadata, "stormancer.party"),
			connection_version = metadata_value(connection_metadata, "version"),
			connection_server_name = metadata_value(connection_metadata, "server.name"),
			connection_timeout = metadata_value(connection_metadata, "timeout"),
			connection_server_version = metadata_value(connection_metadata, "server.version"),
			connection_stormancer_party_plugin = metadata_value(connection_metadata, "stormancer.party.plugin"),
			connection_stormancer_partymanagement = metadata_value(connection_metadata, "stormancer.partymanagement"),
			connection_stormancer_plugins_gamefinder_protocol = metadata_value(connection_metadata, "stormancer.plugins.gamefinder.protocol"),
			connection_plugins = metadata_value(connection_metadata, "plugins"),
			connection_serializers = metadata_value(connection_metadata, "serializers"),
			connection_transport = metadata_value(connection_metadata, "transport"),
			connection_platform = metadata_value(connection_metadata, "platform"),
			connection_protocol = metadata_value(connection_metadata, "protocol"),
			connection_type = metadata_value(connection_metadata, "type"),
			connection_serializer = metadata_value(connection_metadata, "serializer"),
		}
	case .Get_Scene_Infos:
		if !args.ok || len(n) == 0 || n[0].kind != .Map do return Unparsed_Args{args.raw}
		metadata := collect_metadata(n, msgpack_map_get(n, 0, "Metadata"), allocator)
		return Get_Scene_Infos_Args {
			token = parse_connection_token(node_str(n, msgpack_map_get(n, 0, "Token")), allocator),
			stormancer_party = metadata_value(metadata, "stormancer.party"),
			version = metadata_value(metadata, "version"),
			server_name = metadata_value(metadata, "server.name"),
			timeout = metadata_value(metadata, "timeout"),
			server_version = metadata_value(metadata, "server.version"),
			stormancer_party_plugin = metadata_value(metadata, "stormancer.party.plugin"),
			stormancer_partymanagement = metadata_value(metadata, "stormancer.partymanagement"),
			stormancer_plugins_gamefinder_protocol = metadata_value(metadata, "stormancer.plugins.gamefinder.protocol"),
			plugins = metadata_value(metadata, "plugins"),
			serializers = metadata_value(metadata, "serializers"),
			transport = metadata_value(metadata, "transport"),
			platform = metadata_value(metadata, "platform"),
			protocol = metadata_value(metadata, "protocol"),
			connection_type = metadata_value(metadata, "type"),
			serializer = metadata_value(metadata, "serializer"),
		}
	case .Set_Metadata:
		if !args.ok || len(n) == 0 || n[0].kind != .Map do return Unparsed_Args{args.raw}
		metadata := collect_metadata(n, 0, allocator)
		return Set_Metadata_Args {
			stormancer_party = metadata_value(metadata, "stormancer.party"),
			version = metadata_value(metadata, "version"),
			server_name = metadata_value(metadata, "server.name"),
			timeout = metadata_value(metadata, "timeout"),
			server_version = metadata_value(metadata, "server.version"),
			stormancer_party_plugin = metadata_value(metadata, "stormancer.party.plugin"),
			stormancer_partymanagement = metadata_value(metadata, "stormancer.partymanagement"),
			stormancer_plugins_gamefinder_protocol = metadata_value(metadata, "stormancer.plugins.gamefinder.protocol"),
			plugins = metadata_value(metadata, "plugins"),
			serializers = metadata_value(metadata, "serializers"),
			transport = metadata_value(metadata, "transport"),
			platform = metadata_value(metadata, "platform"),
			protocol = metadata_value(metadata, "protocol"),
			connection_type = metadata_value(metadata, "type"),
			serializer = metadata_value(metadata, "serializer"),
		}
	case .Scene_Ready, .Scene_Ready2:
		if !args.ok || len(n) == 0 || n[0].kind != .Map do return Unparsed_Args{args.raw}
		return Scene_Ready_Args{scene_handle = node_uint(n, msgpack_map_get(n, 0, "SceneHandle"))}
	case .Disconnect_From_Scene:
		if !args.ok || len(n) == 0 do return Unparsed_Args{args.raw}
		return Disconnect_From_Scene_Args{scene_handle = node_uint(n, 0)}
	case .Ping:
		if len(args.raw) < 8 do return Unparsed_Args{args.raw}
		return Ping_Args{clock = read_u64_le(args.raw, 0)}
	case .Get_Session_Token:
		if len(args.raw) != 0 do return Unparsed_Args{args.raw}
		return No_Args{}
	}
	return Unparsed_Args{args.raw}
}

node_str :: proc(nodes: []Msgpack_Node, idx: int) -> string {
	if idx < 0 || idx >= len(nodes) do return ""
	if nodes[idx].kind != .Str do return ""
	return nodes[idx].str
}

node_uint :: proc(nodes: []Msgpack_Node, idx: int) -> u64 {
	if idx < 0 || idx >= len(nodes) do return 0
	#partial switch nodes[idx].kind {
	case .Uint:
		return nodes[idx].u
	case .Int:
		return u64(nodes[idx].i)
	}
	return 0
}

collect_metadata :: proc(nodes: []Msgpack_Node, map_idx: int, allocator := context.allocator) -> []Metadata_Entry {
	if map_idx < 0 || map_idx >= len(nodes) || nodes[map_idx].kind != .Map do return nil
	count := nodes[map_idx].count
	out := make([dynamic]Metadata_Entry, 0, count, allocator)
	j := map_idx + 1
	for _ in 0 ..< count {
		k := nodes[j]
		v := j + k.subtree
		if v >= len(nodes) do break
		append(&out, Metadata_Entry{node_str(nodes, j), node_str(nodes, v)})
		j = v + nodes[v].subtree
	}
	return out[:]
}

metadata_value :: proc(metadata: []Metadata_Entry, key: string) -> string {
	for entry in metadata {
		if entry.key == key do return entry.value
	}
	return ""
}

collect_routes :: proc(nodes: []Msgpack_Node, arr_idx: int, allocator := context.allocator) -> Routes {
	if arr_idx < 0 || arr_idx >= len(nodes) || nodes[arr_idx].kind != .Array do return {}
	count := nodes[arr_idx].count
	out := Routes{}
	j := arr_idx + 1
	for _ in 0 ..< count {
		append(&out, node_str(nodes, msgpack_map_get(nodes, j, "Name")))
		j += nodes[j].subtree
	}
	return out
}

write_system_request_args :: proc(sb: ^strings.Builder, args: System_Request_Args) {
	switch a in args {
	case Connect_To_Scene_Args:
		strings.write_string(sb, "Connect token=")
		write_connection_token(sb, a.token)
		strings.write_string(sb, " routes=")
		write_routes(sb, a.routes)
	case Get_Scene_Infos_Args:
		strings.write_string(sb, "Get_Scene_Infos token=")
		write_connection_token(sb, a.token)
	case Set_Metadata_Args:
		fmt.sbprintf(sb, "Set_Metadata {server.name=%q, platform=%q, type=%q}", a.server_name, a.platform, a.connection_type)
	case Scene_Ready_Args:
		fmt.sbprintf(sb, "Scene_Ready handle=%d", a.scene_handle)
	case Disconnect_From_Scene_Args:
		fmt.sbprintf(sb, "Disconnect handle=%d", a.scene_handle)
	case Ping_Args:
		fmt.sbprintf(sb, "Ping clock=%d", a.clock)
	case No_Args:
		strings.write_string(sb, "(none)")
	case Unparsed_Args:
		fmt.sbprintf(sb, "%dB raw", len(a.raw))
	case:
		strings.write_string(sb, "(nil)")
	}
}

write_metadata :: proc(sb: ^strings.Builder, md: []Metadata_Entry) {
	strings.write_byte(sb, '{')
	for e, i in md {
		if i > 0 do strings.write_string(sb, ", ")
		fmt.sbprintf(sb, "%s=%q", e.key, e.value)
	}
	strings.write_byte(sb, '}')
}

write_routes :: proc(sb: ^strings.Builder, routes: Routes) {
	strings.write_byte(sb, '[')
	for route_name, i in routes {
		if i > 0 do strings.write_string(sb, ", ")
		fmt.sbprintf(sb, "%s#%d", route_name, i)
	}
	strings.write_byte(sb, ']')
}
