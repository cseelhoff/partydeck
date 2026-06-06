package caleb_raknet

// Layer 5 (Stormancer system RPC args): turn a System_Request's opaque msgpack
// `args` blob into a typed System_Request_Args -- a tagged union whose variant is
// selected by the System_Request_Id. Each system request carries a *different*
// argument shape on the wire; modelling them as one union (instead of a generic
// Msgpack value) is what makes the decoded request self-describing.
//
// Shapes observed in capture (relay_capture.caleb.jsonl), cross-checked against
// the project's predict.py system-request handlers:
//   Connect_To_Scene (134)     map {Token, Routes[], SceneMetadata, ConnectionMetadata}
//   Get_Scene_Infos  (136)     map {Token, Metadata}
//   Set_Metadata     (0)       flat map<str,str> (the metadata bag, no wrapper)
//   Scene_Ready/2    (1/16)    map {SceneHandle: uint}
//   Disconnect_From_Scene(135) bare msgpack uint (the scene handle)
//   Ping             (2)       raw little-endian u64 clock (NOT msgpack)
//   Get_Session_Token(14)      empty
//
// Strings alias the source bytes (zero-copy); the metadata/route slices are
// allocated with the caller's allocator (temp in the debug path).

import "core:fmt"
import "core:strings"

// One key/value pair of a Stormancer metadata bag. Both alias the source buffer.
Metadata_Entry :: struct {
	key:   string,
	value: string,
}

// One entry of the route table a client registers when connecting to a scene.
Scene_Route :: struct {
	name:     string,
	handle:   u16,
	metadata: []Metadata_Entry,
}

// Connect_To_Scene (134): join a scene, registering the client's own route table
// and metadata. `token` authenticates/identifies the target scene.
Connect_To_Scene_Args :: struct {
	token:               string,
	routes:              []Scene_Route,
	scene_metadata:      []Metadata_Entry,
	connection_metadata: []Metadata_Entry,
}

// Get_Scene_Infos (136): ask for a scene's route/serializer info before joining.
// Same `token` as Connect plus the client's connection metadata fields.
Get_Scene_Infos_Args :: struct {
	token:                                  string,
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

// Set_Metadata (0): (re)declare the connection metadata fields. The args ARE
// the flat map -- there is no wrapper object.
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

// Scene_Ready / Scene_Ready2 (1 / 16): confirm a scene finished wiring up,
// identified by its runtime-assigned handle. Wire shape {SceneHandle: uint}.
Scene_Ready_Args :: struct {
	scene_handle: u64,
}

// Disconnect_From_Scene (135): leave a scene, identified by handle. The args are
// a bare msgpack uint -- no map wrapper.
Disconnect_From_Scene_Args :: struct {
	scene_handle: u64,
}

// Ping (2): a raw little-endian u64 client clock to be echoed. NOT msgpack.
Ping_Args :: struct {
	clock: u64,
}

// Get_Session_Token (14): no arguments (empty payload).
No_Args :: struct {}

// An args payload that did not match the shape expected for its msg_id (wrong
// type, truncated, or an unmodeled request id). `raw` is the undecoded blob, so
// nothing is dropped -- a parse miss is an explicit value, not a silent default.
Unparsed_Args :: struct {
	raw: []byte,
}

// The typed arguments of a System_Request: exactly one variant, chosen by msg_id.
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

// Interpret a System_Request's decoded msgpack `args` as the typed argument shape
// for `msg_id`. Returns Unparsed_Args when the payload does not match.
parse_system_request_args :: proc(
	msg_id: System_Request_Id,
	args: Msgpack,
	allocator := context.allocator,
) -> System_Request_Args {
	n := args.nodes

	#partial switch msg_id {
	case .Connect_To_Scene:
		if !args.ok || len(n) == 0 || n[0].kind != .Map do return Unparsed_Args{args.raw}
		return Connect_To_Scene_Args {
			token               = node_str(n, msgpack_map_get(n, 0, "Token")),
			routes              = collect_routes(n, msgpack_map_get(n, 0, "Routes"), allocator),
			scene_metadata      = collect_metadata(n, msgpack_map_get(n, 0, "SceneMetadata"), allocator),
			connection_metadata = collect_metadata(n, msgpack_map_get(n, 0, "ConnectionMetadata"), allocator),
		}

	case .Get_Scene_Infos:
		if !args.ok || len(n) == 0 || n[0].kind != .Map do return Unparsed_Args{args.raw}
		metadata := collect_metadata(n, msgpack_map_get(n, 0, "Metadata"), allocator)
		return Get_Scene_Infos_Args {
			token                                  = node_str(n, msgpack_map_get(n, 0, "Token")),
			stormancer_party                       = metadata_value(metadata, "stormancer.party"),
			version                                = metadata_value(metadata, "version"),
			server_name                            = metadata_value(metadata, "server.name"),
			timeout                                = metadata_value(metadata, "timeout"),
			server_version                         = metadata_value(metadata, "server.version"),
			stormancer_party_plugin                = metadata_value(metadata, "stormancer.party.plugin"),
			stormancer_partymanagement             = metadata_value(metadata, "stormancer.partymanagement"),
			stormancer_plugins_gamefinder_protocol = metadata_value(metadata, "stormancer.plugins.gamefinder.protocol"),
			plugins                                = metadata_value(metadata, "plugins"),
			serializers                            = metadata_value(metadata, "serializers"),
			transport                              = metadata_value(metadata, "transport"),
			platform                               = metadata_value(metadata, "platform"),
			protocol                               = metadata_value(metadata, "protocol"),
			connection_type                        = metadata_value(metadata, "type"),
			serializer                             = metadata_value(metadata, "serializer"),
		}

	case .Set_Metadata:
		if !args.ok || len(n) == 0 || n[0].kind != .Map do return Unparsed_Args{args.raw}
		metadata := collect_metadata(n, 0, allocator)
		return Set_Metadata_Args {
			stormancer_party                       = metadata_value(metadata, "stormancer.party"),
			version                                = metadata_value(metadata, "version"),
			server_name                            = metadata_value(metadata, "server.name"),
			timeout                                = metadata_value(metadata, "timeout"),
			server_version                         = metadata_value(metadata, "server.version"),
			stormancer_party_plugin                = metadata_value(metadata, "stormancer.party.plugin"),
			stormancer_partymanagement             = metadata_value(metadata, "stormancer.partymanagement"),
			stormancer_plugins_gamefinder_protocol = metadata_value(metadata, "stormancer.plugins.gamefinder.protocol"),
			plugins                                = metadata_value(metadata, "plugins"),
			serializers                            = metadata_value(metadata, "serializers"),
			transport                              = metadata_value(metadata, "transport"),
			platform                               = metadata_value(metadata, "platform"),
			protocol                               = metadata_value(metadata, "protocol"),
			connection_type                        = metadata_value(metadata, "type"),
			serializer                             = metadata_value(metadata, "serializer"),
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

// --- msgpack node accessors (file-local) ------------------------------------

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

// Flatten a msgpack map at `map_idx` into key/value string pairs. Non-string
// values render empty (the Stormancer metadata bags are str->str throughout).
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

// Read an array of {Name, Handle, Metadata} route maps at `arr_idx`.
collect_routes :: proc(nodes: []Msgpack_Node, arr_idx: int, allocator := context.allocator) -> []Scene_Route {
	if arr_idx < 0 || arr_idx >= len(nodes) || nodes[arr_idx].kind != .Array do return nil
	count := nodes[arr_idx].count
	out := make([dynamic]Scene_Route, 0, count, allocator)
	j := arr_idx + 1
	for _ in 0 ..< count {
		append(
			&out,
			Scene_Route {
				name = node_str(nodes, msgpack_map_get(nodes, j, "Name")),
				handle = u16(node_uint(nodes, msgpack_map_get(nodes, j, "Handle"))),
				metadata = collect_metadata(nodes, msgpack_map_get(nodes, j, "Metadata"), allocator),
			},
		)
		j += nodes[j].subtree
	}
	return out[:]
}

// --- debug rendering --------------------------------------------------------

// Write a one-line summary of typed system-request args into `sb`.
write_system_request_args :: proc(sb: ^strings.Builder, args: System_Request_Args) {
	switch a in args {
	case Connect_To_Scene_Args:
		fmt.sbprintf(sb, "Connect token=%dB routes=", len(a.token))
		write_routes(sb, a.routes)
		strings.write_string(sb, " scene_meta=")
		write_metadata(sb, a.scene_metadata)
		strings.write_string(sb, " conn_meta=")
		write_metadata(sb, a.connection_metadata)
	case Get_Scene_Infos_Args:
		fmt.sbprintf(
			sb,
			"Get_Scene_Infos token=%dB metadata={stormancer.party=%q, version=%q, server.name=%q, timeout=%q, server.version=%q, stormancer.party.plugin=%q, stormancer.partymanagement=%q, stormancer.plugins.gamefinder.protocol=%q, plugins=%q, serializers=%q, transport=%q, platform=%q, protocol=%q, type=%q, serializer=%q}",
			len(a.token),
			a.stormancer_party,
			a.version,
			a.server_name,
			a.timeout,
			a.server_version,
			a.stormancer_party_plugin,
			a.stormancer_partymanagement,
			a.stormancer_plugins_gamefinder_protocol,
			a.plugins,
			a.serializers,
			a.transport,
			a.platform,
			a.protocol,
			a.connection_type,
			a.serializer,
		)
	case Set_Metadata_Args:
		fmt.sbprintf(
			sb,
			"Set_Metadata {stormancer.party=%q, version=%q, server.name=%q, timeout=%q, server.version=%q, stormancer.party.plugin=%q, stormancer.partymanagement=%q, stormancer.plugins.gamefinder.protocol=%q, plugins=%q, serializers=%q, transport=%q, platform=%q, protocol=%q, type=%q, serializer=%q}",
			a.stormancer_party,
			a.version,
			a.server_name,
			a.timeout,
			a.server_version,
			a.stormancer_party_plugin,
			a.stormancer_partymanagement,
			a.stormancer_plugins_gamefinder_protocol,
			a.plugins,
			a.serializers,
			a.transport,
			a.platform,
			a.protocol,
			a.connection_type,
			a.serializer,
		)
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

write_routes :: proc(sb: ^strings.Builder, routes: []Scene_Route) {
	strings.write_byte(sb, '[')
	for r, i in routes {
		if i > 0 do strings.write_string(sb, ", ")
		fmt.sbprintf(sb, "%s#%d", r.name, r.handle)
	}
	strings.write_byte(sb, ']')
}
