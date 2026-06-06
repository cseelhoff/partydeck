package caleb_raknet

// Layer 5 (Stormancer system RPC responses): turn a Response_Msg's opaque msgpack
// `data` blob into a typed Response_Data -- a tagged union whose variant is chosen
// by the SHAPE of the reply. Unlike a System_Request (system_request.odin), whose
// shape is selected by a known msg_id, a Response_Msg only carries a req_id, so the
// originating RPC type is not known at this layer. Instead the variant is picked by
// which keys the decoded map carries -- the three reply shapes seen on the wire are
// structurally disjoint.
//
// Shapes observed in capture (relay_capture.caleb.jsonl):
//   Get_Scene_Infos reply   map {ShardId, SceneId, Metadata, Routes[], SelectedSerializer}
//   Connect_To_Scene reply  map {SceneHandle, RouteMappings: map<str,uint>}
//   Get_Session_Token reply  two concatenated msgpack strings: [jwt, sessionId]
//   Ping reply               16 raw bytes: server_clock(u64 LE) + echoed client clock(u64 LE)
//   bool acknowledgement     map {v: bool}
// Anything else (token blobs, raw clocks, future shapes) is kept whole as
// Other_Response -- nothing is dropped, a parse miss is an explicit value.
//
// Strings alias the source bytes (zero-copy); route slices are allocated with
// the caller's allocator (temp in the debug path).

import "core:fmt"
import "core:strings"

// Scene_Infos: the reply to Get_Scene_Infos (msg_id 136). Describes a scene before
// the client joins it -- its id, decoded metadata fields, the routes it exposes
// (reusing the Scene_Route shape registered on connect), and the negotiated serializer.
Scene_Infos :: struct {
	shard_id:                                      u64,
	scene_id:                                      string,
	account_id:                                    string,
	app_id:                                        string,
	darktales_gamesession:                         string,
	stormancer_friends:                            string,
	stormancer_gamesession:                        string,
	stormancer_game_version:                       string,
	stormancer_party:                              string,
	stormancer_partymanagement:                    string,
	stormancer_party_merging:                      string,
	stormancer_party_revision:                     string,
	stormancer_plugins_gamefinder:                 string,
	stormancer_plugins_gamefinder_protocol:        string,
	stormancer_plugins_nintendo:                   string,
	stormancer_plugins_psn:                        string,
	stormancer_plugins_rpc:                        string,
	stormancer_plugins_steam:                      string,
	stormancer_plugins_xbl_use_modern_gamertag:    string,
	routes:                                        []Scene_Route,
	selected_serializer:                           string,
}

SCENE_CONNECTION_RESULT_MAX_SCENES :: 8
SCENE_CONNECTION_RESULT_MAX_ROUTES :: 18

// Scene: one server->client route table. The containing Scene_Connection_Result
// index determines scene handle: scenes[0] is handle 141, scenes[1] is 142, etc.
// The route index determines route handle: routes[0] is handle 1, routes[1] is 2.
Scene :: struct {
	routes: [dynamic; SCENE_CONNECTION_RESULT_MAX_ROUTES]string,
}

// Scene_Connection_Result: the reply to Connect_To_Scene. RouteMappings is decoded
// into the scene slot implied by SceneHandle and routes are stored by handle index.
Scene_Connection_Result :: struct {
	scenes: [dynamic; SCENE_CONNECTION_RESULT_MAX_SCENES]Scene,
}

// Bool_Result: a bare {v: bool} acknowledgement (e.g. a Subscribe / SetStatus ok).
Bool_Result :: struct {
	value: bool,
}

// Session_Token: the reply to Get_Session_Token (msg_id 14). Two concatenated
// top-level msgpack strings -- the session JWT and the session id embedded in its
// body -- NOT a map, so the single-value msgpack decoder rejects it (ok=false).
// Decoded straight from the raw bytes here. Both strings alias the source buffer.
Session_Token :: struct {
	jwt:        string,
	session_id: string,
}

// Ping_Response: the reply to a Ping system request (msg_id 2). 16 raw bytes (NOT
// msgpack): the responder's clock followed by the client's echoed clock, both
// little-endian u64. `echo_clock` should match the originating Ping's clock.
Ping_Response :: struct {
	server_clock: u64,
	echo_clock:   u64,
}

// Other_Response: any reply this layer does not model -- non-msgpack token/clock
// blobs and unrecognized maps. The full Msgpack is retained so nothing is lost and
// the debug renderer can still show the decoded tree or the raw byte length.
Other_Response :: struct {
	data: Msgpack,
}

// The typed payload of a Response_Msg: exactly one variant, chosen by shape.
Response_Data :: union {
	Scene_Infos,
	Scene_Connection_Result,
	Bool_Result,
	Session_Token,
	Ping_Response,
	Other_Response,
}

// Interpret a Response_Msg's decoded msgpack `data` as a typed reply, dispatching
// on which keys the top-level map carries. Returns Other_Response when the payload
// is not msgpack or is a map shape this layer does not model.
parse_response_data :: proc(data: Msgpack, allocator := context.allocator) -> Response_Data {
	n := data.nodes
	if !data.ok || len(n) == 0 || n[0].kind != .Map {
		// A Get_Session_Token reply is two concatenated msgpack strings, which the
		// single-value decoder leaves as !ok -- recover it from the raw bytes.
		if st, ok := parse_session_token(data.raw); ok do return st
		// A Ping reply is a bare 16-byte clock pair, not msgpack.
		if len(data.raw) == 16 {
			return Ping_Response {
				server_clock = read_u64_le(data.raw, 0),
				echo_clock   = read_u64_le(data.raw, 8),
			}
		}
		return Other_Response{data}
	}

	if msgpack_map_get(n, 0, "SceneId") >= 0 && msgpack_map_get(n, 0, "Routes") >= 0 {
		metadata := collect_metadata(n, msgpack_map_get(n, 0, "Metadata"), allocator)
		return Scene_Infos {
			shard_id                                   = node_uint(n, msgpack_map_get(n, 0, "ShardId")),
			scene_id                                   = node_str(n, msgpack_map_get(n, 0, "SceneId")),
			account_id                                 = metadata_value(metadata, "accountId"),
			app_id                                     = metadata_value(metadata, "appId"),
			darktales_gamesession                      = metadata_value(metadata, "darktales.gamesession"),
			stormancer_friends                         = metadata_value(metadata, "stormancer.friends"),
			stormancer_gamesession                     = metadata_value(metadata, "stormancer.gamesession"),
			stormancer_game_version                    = metadata_value(metadata, "stormancer.gameVersion"),
			stormancer_party                           = metadata_value(metadata, "stormancer.party"),
			stormancer_partymanagement                 = metadata_value(metadata, "stormancer.partymanagement"),
			stormancer_party_merging                   = metadata_value(metadata, "stormancer.partyMerging"),
			stormancer_party_revision                  = metadata_value(metadata, "stormancer.party.revision"),
			stormancer_plugins_gamefinder              = metadata_value(metadata, "stormancer.plugins.gamefinder"),
			stormancer_plugins_gamefinder_protocol     = metadata_value(metadata, "stormancer.plugins.gamefinder.protocol"),
			stormancer_plugins_nintendo                = metadata_value(metadata, "stormancer.plugins.nintendo"),
			stormancer_plugins_psn                     = metadata_value(metadata, "stormancer.plugins.psn"),
			stormancer_plugins_rpc                     = metadata_value(metadata, "stormancer.plugins.rpc"),
			stormancer_plugins_steam                   = metadata_value(metadata, "stormancer.plugins.steam"),
			stormancer_plugins_xbl_use_modern_gamertag = metadata_value(metadata, "Stormancer.plugins.XBLServices.useModernGamerTag"),
			routes                                     = collect_routes(n, msgpack_map_get(n, 0, "Routes"), allocator),
			selected_serializer                        = node_str(n, msgpack_map_get(n, 0, "SelectedSerializer")),
		}
	}

	if msgpack_map_get(n, 0, "SceneHandle") >= 0 && msgpack_map_get(n, 0, "RouteMappings") >= 0 {
		return collect_scene_connection_result(
			node_uint(n, msgpack_map_get(n, 0, "SceneHandle")),
			n,
			msgpack_map_get(n, 0, "RouteMappings"),
		)
	}

	if v := msgpack_map_get(n, 0, "v"); v >= 0 && n[v].kind == .Bool {
		return Bool_Result{value = n[v].b}
	}

	return Other_Response{data}
}

// Read a msgpack RouteMappings map into the scene slot implied by `scene_handle`.
collect_scene_connection_result :: proc(
	scene_handle: u64,
	nodes: []Msgpack_Node,
	map_idx: int,
) -> (result: Scene_Connection_Result) {
	if map_idx < 0 || map_idx >= len(nodes) || nodes[map_idx].kind != .Map do return
	count := nodes[map_idx].count
	j := map_idx + 1
	for _ in 0 ..< count {
		k := nodes[j]
		v := j + k.subtree
		if v >= len(nodes) do break
		scene_connection_result_set_route(
			&result,
			scene_handle,
			node_uint(nodes, v),
			node_str(nodes, j),
		)
		j = v + nodes[v].subtree
	}
	return
}

scene_connection_result_set_route :: proc(
	result: ^Scene_Connection_Result,
	scene_handle: u64,
	route_handle: u64,
	route_name: string,
) {
	if scene_handle < u64(SCENE_HANDLE_MIN) do return
	scene_index := int(scene_handle - u64(SCENE_HANDLE_MIN))
	if scene_index < 0 || scene_index >= SCENE_CONNECTION_RESULT_MAX_SCENES do return
	if route_handle == 0 || route_handle > u64(SCENE_CONNECTION_RESULT_MAX_ROUTES) do return

	for len(result.scenes) <= scene_index do append(&result.scenes, Scene{})
	scene := &result.scenes[scene_index]
	route_index := int(route_handle - 1)
	for len(scene.routes) <= route_index do append(&scene.routes, "")
	scene.routes[route_index] = route_name
}

scene_connection_result_handle :: proc(result: Scene_Connection_Result) -> u64 {
	for scene, scene_index in result.scenes {
		if len(scene.routes) > 0 do return u64(SCENE_HANDLE_MIN + scene_index)
	}
	return 0
}

// Decode the Get_Session_Token reply: exactly two back-to-back top-level msgpack
// strings (jwt, sessionId) filling `raw`. Returns ok=false if `raw` is not that
// shape. Both returned strings alias `raw` (zero-copy).
parse_session_token :: proc(raw: []byte) -> (Session_Token, bool) {
	jwt, off, ok := read_msgpack_str(raw, 0)
	if !ok do return {}, false
	sid, end, ok2 := read_msgpack_str(raw, off)
	if !ok2 || end != len(raw) do return {}, false
	return Session_Token{jwt = jwt, session_id = sid}, true
}

// Read one msgpack string (fixstr / str8 / str16 / str32) at byte offset `off`.
// Returns the string (aliasing `b`) and the offset just past it; ok=false if the
// byte at `off` is not a string header or the payload runs past the end.
read_msgpack_str :: proc(b: []byte, off: int) -> (s: string, next: int, ok: bool) {
	if off < 0 || off >= len(b) do return
	c := b[off]
	p := off + 1
	n: int
	switch {
	case c >= 0xa0 && c <= 0xbf:
		n = int(c & 0x1f)
	case c == 0xd9:
		if p + 1 > len(b) do return
		n = int(b[p]);p += 1
	case c == 0xda:
		if p + 2 > len(b) do return
		n = int(read_u16_be(b, p));p += 2
	case c == 0xdb:
		if p + 4 > len(b) do return
		n = int(read_u32_be(b, p));p += 4
	case:
		return
	}
	if p + n > len(b) do return
	return string(b[p:p + n]), p + n, true
}

// --- debug rendering --------------------------------------------------------

// Write a one-line summary of a typed Response_Msg payload into `sb`.
write_response_data :: proc(sb: ^strings.Builder, data: Response_Data) {
	switch d in data {
	case Scene_Infos:
		fmt.sbprintf(
			sb,
			"Scene_Infos shard=%d scene=%q serializer=%q meta=",
			d.shard_id,
			d.scene_id,
			d.selected_serializer,
		)
		write_scene_infos_metadata(sb, d)
		strings.write_string(sb, " routes=")
		write_routes(sb, d.routes)
	case Scene_Connection_Result:
		fmt.sbprintf(sb, "Scene_Connection_Result handle=%d routes=", scene_connection_result_handle(d))
		write_scene_connection_result_routes(sb, d)
	case Bool_Result:
		fmt.sbprintf(sb, "Bool_Result v=%v", d.value)
	case Session_Token:
		fmt.sbprintf(sb, "Session_Token sid=%q jwt=", d.session_id)
		if !mp_write_jwt(sb, d.jwt) {
			fmt.sbprintf(sb, "%dB", len(d.jwt))
		}
	case Ping_Response:
		fmt.sbprintf(sb, "Ping_Response server=%d echo=%d", d.server_clock, d.echo_clock)
	case Other_Response:
		strings.write_string(sb, msgpack_field_string(d.data))
	case:
		strings.write_string(sb, "(nil)")
	}
}

write_scene_infos_metadata :: proc(sb: ^strings.Builder, d: Scene_Infos) {
	wrote := false
	strings.write_byte(sb, '{')
	write_metadata_field(sb, &wrote, "accountId", d.account_id)
	write_metadata_field(sb, &wrote, "appId", d.app_id)
	write_metadata_field(sb, &wrote, "darktales.gamesession", d.darktales_gamesession)
	write_metadata_field(sb, &wrote, "stormancer.friends", d.stormancer_friends)
	write_metadata_field(sb, &wrote, "stormancer.gamesession", d.stormancer_gamesession)
	write_metadata_field(sb, &wrote, "stormancer.gameVersion", d.stormancer_game_version)
	write_metadata_field(sb, &wrote, "stormancer.party", d.stormancer_party)
	write_metadata_field(sb, &wrote, "stormancer.partymanagement", d.stormancer_partymanagement)
	write_metadata_field(sb, &wrote, "stormancer.partyMerging", d.stormancer_party_merging)
	write_metadata_field(sb, &wrote, "stormancer.party.revision", d.stormancer_party_revision)
	write_metadata_field(sb, &wrote, "stormancer.plugins.gamefinder", d.stormancer_plugins_gamefinder)
	write_metadata_field(
		sb,
		&wrote,
		"stormancer.plugins.gamefinder.protocol",
		d.stormancer_plugins_gamefinder_protocol,
	)
	write_metadata_field(sb, &wrote, "stormancer.plugins.nintendo", d.stormancer_plugins_nintendo)
	write_metadata_field(sb, &wrote, "stormancer.plugins.psn", d.stormancer_plugins_psn)
	write_metadata_field(sb, &wrote, "stormancer.plugins.rpc", d.stormancer_plugins_rpc)
	write_metadata_field(sb, &wrote, "stormancer.plugins.steam", d.stormancer_plugins_steam)
	write_metadata_field(
		sb,
		&wrote,
		"Stormancer.plugins.XBLServices.useModernGamerTag",
		d.stormancer_plugins_xbl_use_modern_gamertag,
	)
	strings.write_byte(sb, '}')
}

write_metadata_field :: proc(sb: ^strings.Builder, wrote: ^bool, key, value: string) {
	if len(value) == 0 do return
	if wrote^ do strings.write_string(sb, ", ")
	fmt.sbprintf(sb, "%s=%q", key, value)
	wrote^ = true
}

write_scene_connection_result_routes :: proc(sb: ^strings.Builder, result: Scene_Connection_Result) {
	strings.write_byte(sb, '[')
	wrote := false
	for scene in result.scenes {
		for route_name, route_index in scene.routes {
			if len(route_name) == 0 do continue
			if wrote do strings.write_string(sb, ", ")
			fmt.sbprintf(sb, "%s#%d", route_name, route_index + 1)
			wrote = true
		}
	}
	strings.write_byte(sb, ']')
}
