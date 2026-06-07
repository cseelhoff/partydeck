package caleb_raknet

import "core:encoding/hex"
import "core:fmt"
import "core:slice"

get_route_num_from_handle :: proc(
	simple_server_state: ^Simple_Server_State,
	scene_handle: u64,
	route_name_query: string,
) -> u16 {
	assert(scene_handle >= u64(SCENE_HANDLE_MIN))
	scene_index := scene_handle - u64(SCENE_HANDLE_MIN)
	scene := simple_server_state.scenes[scene_index]
	route_index, found := slice.linear_search(scene[:], route_name_query)
	if found do return u16(route_index + 1)
	assert(false, "route not found")
	return 0
}

steam_id_from_login_ticket :: proc(ticket: string, allocator := context.allocator) -> string {
	data, ok := hex.decode(transmute([]byte)ticket, allocator)
	if !ok || len(data) < 20 do return ""
	defer delete(data, allocator)
	return fmt.aprintf("%d", read_u64_le(data, 12), allocator = allocator)
}
