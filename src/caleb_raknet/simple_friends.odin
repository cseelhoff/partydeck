package caleb_raknet

import "core:fmt"
import "core:mem"

Simple_Friend :: struct {
	steam_id:             string,
	stormancer_id:        string,
	pseudo:               string,
	category:             string,
	metadata_stormancer:  u64,
	crossplay_enabled:    bool,
}

Simple_Friends :: [dynamic]Simple_Friend

g_simple_friends_by_steam: map[string]Simple_Friends

simple_friends_rebuild :: proc(allocator: mem.Allocator) {
	g_simple_friends_by_steam = make(map[string]Simple_Friends, allocator)
	steam_ids := make([dynamic]string, allocator)
	for steam_id, _ in g_simple_user_ids_by_steam do append(&steam_ids, steam_id)
	simple_sort_strings(steam_ids[:])

	for user_steam_id in steam_ids {
		friends := make([dynamic]Simple_Friend, allocator)
		for friend_steam_id in steam_ids {
			if friend_steam_id == user_steam_id do continue
			friend_stormancer_id := g_simple_user_ids_by_steam[friend_steam_id]
			append(&friends, Simple_Friend {
				steam_id = friend_steam_id,
				stormancer_id = friend_stormancer_id,
				pseudo = simple_friend_pseudo(friend_steam_id),
				category = "recentlyMet",
				metadata_stormancer = simple_friend_metadata_stormancer(friend_steam_id),
				crossplay_enabled = true,
			})
		}
		g_simple_friends_by_steam[user_steam_id] = friends
	}
}

simple_friends_for_steam_id :: proc(steam_id: string) -> Simple_Friends {
	if g_simple_friends_by_steam == nil do return {}
	if friends, ok := g_simple_friends_by_steam[steam_id]; ok do return friends
	return {}
}

simple_sort_strings :: proc(values: []string) {
	for i in 1 ..< len(values) {
		j := i
		for j > 0 && values[j] < values[j - 1] {
			values[j], values[j - 1] = values[j - 1], values[j]
			j -= 1
		}
	}
}

simple_friend_pseudo :: proc(steam_id: string) -> string {
	switch steam_id {
	case "76561197977870267":
		return "Major Hoff"
	case "76561199572083022":
		return "elsie"
	}
	return steam_id
}

simple_friend_metadata_stormancer :: proc(steam_id: string) -> u64 {
	switch steam_id {
	case "76561199572083022":
		return 2
	}
	return 0
}

encode_friends_notification_body :: proc(
	body: Friends_Notification_Body,
	allocator := context.allocator,
) -> []byte {
	items := make([dynamic][]byte, allocator)
	timestamp := body.timestamp
	if timestamp == 0 do timestamp = server_time_ms()
	for friend in body.friends {
		append(&items, simple_friend_notification_value(friend, timestamp, allocator))
	}
	return mpe_array(items[:], allocator)
}

simple_friend_notification_value :: proc(
	friend: Simple_Friend,
	timestamp: u64,
	allocator := context.allocator,
) -> []byte {
	platforms := mpe_array(
		{
			mpe_array({mpe_str("stormancer", allocator), mpe_str(friend.stormancer_id, allocator)}, allocator),
			mpe_array({mpe_str("steam", allocator), mpe_str(friend.steam_id, allocator)}, allocator),
		},
		allocator,
	)
	profile_metadata := mpe_map(
		{mpe_str("stormancer", allocator), mpe_uint(friend.metadata_stormancer, allocator)},
		allocator,
	)
	categories := mpe_array({mpe_str(friend.category, allocator)}, allocator)
	details_json := mpe_str(simple_friend_details_json(friend, allocator), allocator)
	return mpe_array(
		{
			mpe_uint(0, allocator),
			mpe_array({platforms, profile_metadata, categories, details_json}, allocator),
			mpe_uint(timestamp, allocator),
		},
		allocator,
	)
}

simple_friend_details_json :: proc(friend: Simple_Friend, allocator := context.allocator) -> string {
	crossplay := friend.crossplay_enabled ? "true" : "false"
	return fmt.aprintf(
		"{\n  \"userId\": \"%s\",\n  \"lastPlatform\": \"steam\",\n  \"platforms\": {\n    \"steam\": {\n      \"steamid\": %s\n    }\n  },\n  \"crossplay\": {\n    \"Enabled\": %s\n  },\n  \"pseudo\": \"%s\"\n}",
		friend.stormancer_id,
		friend.steam_id,
		crossplay,
		friend.pseudo,
		allocator = allocator,
	)
}
