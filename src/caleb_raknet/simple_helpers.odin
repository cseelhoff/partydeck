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

steam_id_from_login_ticket :: proc(ticket: string, allocator := context.allocator) -> string {
	data, ok := hex.decode(transmute([]byte)ticket, allocator)
	if !ok || len(data) < 20 do return ""
	defer delete(data, allocator)
	return fmt.aprintf("%d", read_u64_le(data, 12), allocator = allocator)
}
