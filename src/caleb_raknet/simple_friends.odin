package caleb_raknet

import "core:encoding/hex"
import "core:mem"
import "core:strings"

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
	case "76561197977870267":
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
	out := make([dynamic]byte, allocator)
	append(&out, ..mpe_array(items[:], allocator))
	if len(body.raw_tail) > 0 do append(&out, ..body.raw_tail)
	return out[:]
}

simple_friends_subscribe_tail :: proc(
	local_steam_id: string,
	allocator := context.allocator,
) -> []byte {
	tail_hex := ""
	switch local_steam_id {
	case "76561197977870267":
		tail_hex = "6e646578223a5b322c342c342c312c332c342c332c322c332c342c342c302c302c302c302c302c302c302c302c302c302c302c302c302c302c302c302c302c302c302c302c305d7d9196a5737465616dd9203033396234313166666233663435666539653165616462623837363037393631a9616e6f6e796d6f7573b13736353631313938313139383137323039a00034353135333036a000023631313939313134383431333834a000617900"
	case "76561199572083022":
		tail_hex = "6c7b22496e7669746174696f6e436f6465223a22363530303339222c2247616d654d6f6465223a302c2247616d65446966666963756c7479223a302c2247616d654d6f64696669657273223a5b352c382c31322c31345d2c224d6572676572446966666963756c7479223a307dc3c2a0a066303764653533353736633939a9616e6f6e796d6f7573b13736353631313938303236393236383531a0000231313938383434323038383931a000000002027902"
	}
	if tail_hex == "" do return nil
	decoded, ok := hex.decode(transmute([]byte)tail_hex, allocator)
	if !ok do return nil
	return decoded
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
	return strings.concatenate(
		{
			"{\n  \"userId\": \"",
			friend.stormancer_id,
			"\",\n  \"lastPlatform\": \"steam\",\n  \"platforms\": {\n    \"steam\": {\n      \"steamid\": ",
			friend.steam_id,
			"\n    }\n  },\n  \"crossplay\": {\n    \"Enabled\": ",
			crossplay,
			"\n  },\n  \"pseudo\": \"",
			friend.pseudo,
			"\"\n}",
		},
		allocator,
	)
}
