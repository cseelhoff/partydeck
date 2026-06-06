package caleb_raknet

// Layer 7 (scene route resolution): turn a Scene_Message's numeric route handle
// into the route NAME it stands for (e.g. handle=144 route=2 -> "party.getpartystate2").
//
// A route handle is meaningless on its own: each scene assigns its own small
// integers, and a handle's meaning DIFFERS BY DIRECTION. The two halves are
// announced earlier in the same stream, so this layer learns them as it goes and
// is therefore stateful -- unlike every layer below it, which is a pure per-message
// transform:
//   * client -> server (RPC invocations): the route table is the Routes list in a
//     Get_Scene_Infos reply (Scene_Infos.routes, response.odin). Keyed by SceneId.
//   * server -> client (pushes / RPC replies): the route table is the scene slot
//     in a Connect_To_Scene reply (Scene_Connection_Result.scenes). Keyed by the
//     RakNet scene-handle byte the connect assigned.
// The connect reply carries only the handle, not the SceneId, so the SceneId is
// recovered by correlating the reply's req_id back to the Connect_To_Scene request's
// token (parse_connection_token, get_scene_infos.odin).
//
// Direction of a given scene message is inferred from its sender's role: an endpoint
// that sends System_Request / Connection_Request is a client; one that sends
// Response_* / Connection_Result is the server. (A capture only records `from`, not
// the destination, so this is the only signal available.)
//
// CAVEAT: RakNet scene handles are REUSED over a session (handle 146 is one client's
// party scene early on and a gamesession later). The registry is therefore
// latest-wins per handle for the server->client side; with two concurrent clients
// reusing the same handle, a server->client name can occasionally resolve to the
// most-recent binding rather than the intended one. Client->server resolution is
// stable: it is keyed by SceneId, which is unique per scene. Static-scene handles
// (authenticator/friends/party-manager) never change table, so they never alias.
//
// All stored strings (route names, SceneIds) alias the RakNet_Message_Store byte
// pool, which lives for the whole run -- except token-derived SceneIds, which are
// cloned into the registry allocator because they alias a transient decode buffer.

import "core:mem"
import "core:net"
import "core:strings"

// Inferred role of an endpoint, used to pick which route table applies to a scene
// message it sent. Unknown until the endpoint sends a role-revealing message.
Endpoint_Role :: enum u8 {
	Unknown = 0,
	Client,
	Server,
}

// One learned routeHandle -> name binding for the client->server direction, scoped
// to a scene by its SceneId (route handles are unique only within a scene).
Server_Route :: struct {
	scene: string,
	route: u16,
	name:  string,
}

// One learned routeHandle -> name binding for the server->client direction, scoped
// to the RakNet scene-handle byte the connect assigned.
Client_Route :: struct {
	handle: u8,
	route:  u16,
	name:   string,
}

// Stateful route knowledge accumulated over a stream. The maps key small scalars
// (endpoint role, req->scene, handle->scene); the route tables are tiny flat lists
// scanned linearly -- a scene exposes at most a few dozen routes and the tables are
// built only a handful of times, so a hash index would not pay for itself.
Route_Registry :: struct {
	allocator:     mem.Allocator,
	roles:         map[net.Endpoint]Endpoint_Role,
	req_scene:     map[u16]string, // connect req_id -> scene suffix (cloned)
	handle_scene:  map[u8]string, // scene handle -> scene suffix (cloned)
	server_routes: [dynamic]Server_Route, // client->server, keyed by scene suffix
	client_routes: [dynamic]Client_Route, // server->client, keyed by scene handle
}

route_registry_init :: proc(reg: ^Route_Registry, allocator := context.allocator) {
	reg.allocator = allocator
	reg.roles = make(map[net.Endpoint]Endpoint_Role, allocator)
	reg.req_scene = make(map[u16]string, allocator)
	reg.handle_scene = make(map[u8]string, allocator)
	reg.server_routes = make([dynamic]Server_Route, allocator)
	reg.client_routes = make([dynamic]Client_Route, allocator)
}

route_registry_destroy :: proc(reg: ^Route_Registry) {
	delete(reg.roles)
	delete(reg.req_scene)
	delete(reg.handle_scene)
	delete(reg.server_routes)
	delete(reg.client_routes)
}

// Update the registry from one decoded message, learning the sender's role, the
// req_id->scene correlation, and the two route tables. Must be called for every
// message in stream order so a binding is known before the messages that use it.
// `scratch` decodes the connect token; only the short SceneId is cloned to persist.
route_registry_observe :: proc(
	reg: ^Route_Registry,
	from: net.Endpoint,
	message: Decoded_Message,
	scratch := context.temp_allocator,
) {
	#partial switch f in message {
	case Connection_Request:
		reg.roles[from] = .Client
	case Connection_Request_Accepted:
		reg.roles[from] = .Server
	case Connection_Result:
		reg.roles[from] = .Server
	case Response_Complete:
		reg.roles[from] = .Server
	case Response_Error:
		reg.roles[from] = .Server
	case System_Request:
		reg.roles[from] = .Client
		if c, ok := f.args.(Connect_To_Scene_Args); ok {
			tok := parse_connection_token(c.token, scratch)
			if tok.ok {
				reg.req_scene[f.req_id] = strings.clone(scene_suffix(tok.scene_id), reg.allocator)
			}
		}
	case Response_Msg:
		reg.roles[from] = .Server
		#partial switch d in f.data {
		case Scene_Infos:
			learn_server_routes(reg, scene_suffix(d.scene_id), d.routes)
		case Scene_Connection_Result:
			learn_client_scenes(reg, f.req_id, d.scenes)
		}
	}
}

// Record a scene's client->server routes (from a Scene_Infos reply), keyed by its
// SceneId. Idempotent: a scene is announced once per client, so re-adds are skipped.
learn_server_routes :: proc(reg: ^Route_Registry, scene: string, routes: []Scene_Route) {
	for r in routes {
		exists := false
		for e in reg.server_routes {
			if e.scene == scene && e.route == r.handle {
				exists = true
				break
			}
		}
		if !exists do append(&reg.server_routes, Server_Route{scene = scene, route = r.handle, name = r.name})
	}
}

// Record scene handles' server->client routes (from a Connect reply). Latest-wins:
// handles may be reused for a different scene later, so any prior bindings for a
// populated handle are dropped first. Binds handle->scene when the connect's req_id
// is still known.
learn_client_scenes :: proc(
	reg: ^Route_Registry,
	req_id: u16,
	scenes: [dynamic; SCENE_CONNECTION_RESULT_MAX_SCENES]Scene,
) {
	for scene, scene_index in scenes {
		if len(scene.routes) == 0 do continue
		handle := u8(SCENE_HANDLE_MIN + scene_index)
		if scene_id, ok := reg.req_scene[req_id]; ok do reg.handle_scene[handle] = scene_id

		w := 0
		for e in reg.client_routes {
			if e.handle != handle {
				reg.client_routes[w] = e
				w += 1
			}
		}
		resize(&reg.client_routes, w)

		for route_name, route_index in scene.routes {
			if len(route_name) == 0 do continue
			append(
				&reg.client_routes,
				Client_Route{handle = handle, route = u16(route_index + 1), name = route_name},
			)
		}
	}
}

// Resolve a scene message's route handle to its route name, or "" if unknown. The
// sender's role picks the direction; on a miss the other direction is tried, so a
// misclassified endpoint still resolves when the handle is unambiguous.
route_registry_resolve :: proc(reg: ^Route_Registry, from: net.Endpoint, scene_handle: u8, route: u16) -> string {
	role := reg.roles[from]
	if role == .Server {
		if name, ok := find_client_route(reg, scene_handle, route); ok do return name
		if name, ok := find_server_route(reg, scene_handle, route); ok do return name
		return ""
	}
	if name, ok := find_server_route(reg, scene_handle, route); ok do return name
	if name, ok := find_client_route(reg, scene_handle, route); ok do return name
	return ""
}

find_server_route :: proc(reg: ^Route_Registry, scene_handle: u8, route: u16) -> (string, bool) {
	scene, ok := reg.handle_scene[scene_handle]
	if !ok do return "", false
	for e in reg.server_routes {
		if e.scene == scene && e.route == route do return e.name, true
	}
	return "", false
}

find_client_route :: proc(reg: ^Route_Registry, scene_handle: u8, route: u16) -> (string, bool) {
	for e in reg.client_routes {
		if e.handle == scene_handle && e.route == route do return e.name, true
	}
	return "", false
}

// The registry key for a scene: the suffix after the last '/'. A connect token
// carries the full SceneId (".../party-<guid>"); a Scene_Infos reply carries just
// the suffix ("party-<guid>"). Reducing both to the suffix makes them compare equal.
scene_suffix :: proc(s: string) -> string {
	if i := strings.last_index_byte(s, '/'); i >= 0 do return s[i + 1:]
	return s
}
