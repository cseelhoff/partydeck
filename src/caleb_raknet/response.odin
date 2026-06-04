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
//   bool acknowledgement     map {v: bool}
// Anything else (token blobs, raw clocks, future shapes) is kept whole as
// Other_Response -- nothing is dropped, a parse miss is an explicit value.
//
// Strings alias the source bytes (zero-copy); the metadata/route slices are
// allocated with the caller's allocator (temp in the debug path).

import "core:fmt"
import "core:strings"

// Scene_Infos: the reply to Get_Scene_Infos (msg_id 136). Describes a scene before
// the client joins it -- its id, metadata bag, the routes it exposes (reusing the
// Scene_Route shape registered on connect), and the negotiated serializer.
Scene_Infos :: struct {
	shard_id:            u64,
	scene_id:            string,
	metadata:            []Metadata_Entry,
	routes:              []Scene_Route,
	selected_serializer: string,
}

// Route_Mapping: one route-name -> runtime handle binding from a Connect_To_Scene
// reply's RouteMappings map. The handle is what the client tags scene messages with.
Route_Mapping :: struct {
	name:   string,
	handle: u16,
}

// Scene_Connection_Result: the reply to Connect_To_Scene. `scene_handle` is the
// runtime handle assigned to the joined scene; `route_mappings` binds each route
// name to the small handle used on the wire thereafter.
Scene_Connection_Result :: struct {
	scene_handle:   u64,
	route_mappings: []Route_Mapping,
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
		return Other_Response{data}
	}

	if msgpack_map_get(n, 0, "SceneId") >= 0 && msgpack_map_get(n, 0, "Routes") >= 0 {
		return Scene_Infos {
			shard_id            = node_uint(n, msgpack_map_get(n, 0, "ShardId")),
			scene_id            = node_str(n, msgpack_map_get(n, 0, "SceneId")),
			metadata            = collect_metadata(n, msgpack_map_get(n, 0, "Metadata"), allocator),
			routes              = collect_routes(n, msgpack_map_get(n, 0, "Routes"), allocator),
			selected_serializer = node_str(n, msgpack_map_get(n, 0, "SelectedSerializer")),
		}
	}

	if msgpack_map_get(n, 0, "SceneHandle") >= 0 && msgpack_map_get(n, 0, "RouteMappings") >= 0 {
		return Scene_Connection_Result {
			scene_handle   = node_uint(n, msgpack_map_get(n, 0, "SceneHandle")),
			route_mappings = collect_route_mappings(n, msgpack_map_get(n, 0, "RouteMappings"), allocator),
		}
	}

	if v := msgpack_map_get(n, 0, "v"); v >= 0 && n[v].kind == .Bool {
		return Bool_Result{value = n[v].b}
	}

	return Other_Response{data}
}

// Read a msgpack map<str, uint> at `map_idx` into name/handle pairs (the
// RouteMappings shape). Non-string keys / non-uint values render as ""/0.
collect_route_mappings :: proc(
	nodes: []Msgpack_Node,
	map_idx: int,
	allocator := context.allocator,
) -> []Route_Mapping {
	if map_idx < 0 || map_idx >= len(nodes) || nodes[map_idx].kind != .Map do return nil
	count := nodes[map_idx].count
	out := make([dynamic]Route_Mapping, 0, count, allocator)
	j := map_idx + 1
	for _ in 0 ..< count {
		k := nodes[j]
		v := j + k.subtree
		if v >= len(nodes) do break
		append(&out, Route_Mapping{name = node_str(nodes, j), handle = u16(node_uint(nodes, v))})
		j = v + nodes[v].subtree
	}
	return out[:]
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
		write_metadata(sb, d.metadata)
		strings.write_string(sb, " routes=")
		write_routes(sb, d.routes)
	case Scene_Connection_Result:
		fmt.sbprintf(sb, "Scene_Connection_Result handle=%d routes=", d.scene_handle)
		write_route_mappings(sb, d.route_mappings)
	case Bool_Result:
		fmt.sbprintf(sb, "Bool_Result v=%v", d.value)
	case Session_Token:
		fmt.sbprintf(sb, "Session_Token sid=%q jwt=", d.session_id)
		if !mp_write_jwt(sb, d.jwt) {
			fmt.sbprintf(sb, "%dB", len(d.jwt))
		}
	case Other_Response:
		strings.write_string(sb, msgpack_field_string(d.data))
	case:
		strings.write_string(sb, "(nil)")
	}
}

write_route_mappings :: proc(sb: ^strings.Builder, rm: []Route_Mapping) {
	strings.write_byte(sb, '[')
	for r, i in rm {
		if i > 0 do strings.write_string(sb, ", ")
		fmt.sbprintf(sb, "%s#%d", r.name, r.handle)
	}
	strings.write_byte(sb, ']')
}
