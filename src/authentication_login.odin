package main

import "core:encoding/hex"
import "core:fmt"
import "core:strings"

// Decode/encode a Stormancer Authentication.Login scene message straight from its
// raw wire hex. The message is a single fixed shape (scene handle 141, route 6),
// so it is parsed directly rather than through a general msgpack reader.
//
// Wire layout (see pcaps/workingmulti_predict.json "sent"):
//   [sceneHandle:u8][routeHandle:u16 LE][rpcRequestId:u16 LE]
//   msgpack fixarray(2): [ provider:str, fixmap(5){
//       "gameVersion.clientVersion":str, "provider":str, "ticket":str,
//       "version":str, "appId":str } ]
// The array's leading provider and the map's "provider" are the same value.

Authentication_Login_Body :: struct {
	handle:         u8,     // scene handle (141)
	route:          u16,    // route handle (6 = Authentication.Login)
	rpc_id:         u16,    // Stormancer RPC request id
	provider:       string,            // auth provider, e.g. "steam"
	client_version: string,            // gameVersion.clientVersion, e.g. "1.05.00.05"
	ticket:         Steam_Auth_Ticket, // decoded steam auth ticket (see Steam_Auth_Ticket)
	version:        string,            // "v1"
	app_id:         string,            // "2071280"
}

Scene_Message_Type :: enum {
	Unknown,
	Authentication_Login,
}

// Stub for the stateful route table (handle/route -> route name), which is really
// learned from the GetSceneInfos / ConnectionResult traffic. Here we hard-code the
// one route this file models.
get_scene_message_type_from_handle_and_route :: proc(handle: u8, route: u16) -> Scene_Message_Type {
	if handle == 141 && route == 6 do return .Authentication_Login
	return .Unknown
}

decode_authentication_login :: proc(
	wire_hex: string,
	allocator := context.allocator,
) -> (Authentication_Login_Body, bool) {
	data, decode_ok := hex.decode(transmute([]byte)wire_hex, allocator)
	if !decode_ok || len(data) < 6 do return {}, false

	body: Authentication_Login_Body
	body.handle = data[0]
	body.route = read_u16_le(data, 1)
	body.rpc_id = read_u16_le(data, 3)

	pos := 5
	if data[pos] != 0x92 do return {}, false // fixarray(2)
	pos += 1

	provider, after_provider, provider_ok := mp_read_str(data, pos)
	if !provider_ok do return {}, false
	pos = after_provider
	body.provider = provider

	if pos >= len(data) || data[pos] != 0x85 do return {}, false // fixmap(5)
	pos += 1
	for _ in 0 ..< 5 {
		key, after_key, key_ok := mp_read_str(data, pos)
		if !key_ok do return {}, false
		value, after_value, value_ok := mp_read_str(data, after_key)
		if !value_ok do return {}, false
		pos = after_value
		switch key {
		case "gameVersion.clientVersion":
			body.client_version = value
		case "ticket":
			ticket, ticket_ok := decode_steam_ticket(value, allocator)
			if !ticket_ok do return {}, false
			body.ticket = ticket
		case "version":
			body.version = value
		case "appId":
			body.app_id = value
		case "provider": // already captured from the array head
		}
	}
	return body, pos == len(data)
}

encode_authentication_login :: proc(
	body: Authentication_Login_Body,
	allocator := context.allocator,
) -> string {
	out := make([dynamic]byte, allocator)
	append(&out, body.handle)
	write_u16_le(&out, body.route)
	write_u16_le(&out, body.rpc_id)

	append(&out, 0x92) // fixarray(2)
	mp_write_str(&out, body.provider)
	append(&out, 0x85) // fixmap(5)
	mp_write_str(&out, "gameVersion.clientVersion");	mp_write_str(&out, body.client_version)
	mp_write_str(&out, "provider");			mp_write_str(&out, body.provider)
	mp_write_str(&out, "ticket");			mp_write_str(&out, encode_steam_ticket(body.ticket, allocator))
	mp_write_str(&out, "version");			mp_write_str(&out, body.version)
	mp_write_str(&out, "appId");			mp_write_str(&out, body.app_id)

	return string(hex.encode(out[:], allocator))
}

// --- Steam auth session ticket -------------------------------------------------
//
// The "ticket" field is a Steam GetAuthSessionTicket blob carried as ASCII hex --
// the standard layout produced by ISteamUser::GetAuthSessionTicket: a game-connect
// token, a session header, then a signed app-ownership ticket and its RSA-2048
// signature. Every scalar decodes; only the 128-byte signature stays opaque (it is
// signed by Steam, so we preserve the bytes rather than interpret them).
//
//   u32 gcTokenLen(=20) | u64 gcToken | u64 steamID | u32 tokenGenerated
//   u32 sessionLen(=24) | u32 unk1 | u32 unk2 | u32 externalIP | u32 filler
//                       | u32 connectionTimeMs | u32 connectionCount
//   u32 restLen (= ownLen + len(signature))
//   u32 ownLen | u32 version | u64 steamID | u32 appID | u32 externalIP
//              | u32 internalIP | u32 flags | u32 generated | u32 expires
//              | u16 licenseCount  | u32 license[licenseCount]
//              | u16 dlcCount      | { u32 appID | u16 n | u32 license[n] }[dlcCount]
//              | u16 reserved
//   byte signature[128]
// restLen and ownLen are both derivable from the content, so they are recomputed on
// encode rather than stored.

Steam_Dlc :: struct {
	app_id:   u32,
	licenses: []u32,
}

Steam_Auth_Ticket :: struct {
	// game-connect token (20 bytes)
	gc_token:        u64, // game-connect token
	steam_id:        u64, // SteamID64
	token_generated: u32, // gc token creation time (unix seconds)
	// session header (24 bytes)
	session_unknown_1:   u32, // observed = 1
	session_unknown_2:   u32, // observed = 5
	session_external_ip: u32, // client external IP
	session_filler:      u32, // filler (not validated by Steam)
	session_time_ms:     u32, // ms the client has been connected to Steam
	session_count:       u32, // times the client has connected to Steam
	// signed app-ownership ticket
	ownership_version:     u32,         // ownership ticket version (= 4)
	ownership_steam_id:    u64,         // SteamID64 (matches steam_id)
	ownership_app_id:      u32,         // owned app id (= 2071280)
	ownership_external_ip: u32,         // external IP in the ownership ticket
	ownership_internal_ip: u32,         // internal/LAN IP (e.g. 10.1.1.129)
	ownership_flags:       u32,         // ownership flags
	ownership_generated:   u32,         // issue time (unix seconds)
	ownership_expires:     u32,         // expiry time (unix seconds)
	licenses:              []u32,       // owning license (package) ids
	dlc:                   []Steam_Dlc, // per-DLC ownership entries
	ownership_reserved:    u16,         // trailing reserved u16 (= 0)
	signature:             []byte,      // 128-byte RSA-2048 signature (opaque, Steam-signed)
}

decode_steam_ticket :: proc(
	ticket_hex: string,
	allocator := context.allocator,
) -> (Steam_Auth_Ticket, bool) {
	data, decode_ok := hex.decode(transmute([]byte)ticket_hex, allocator)
	if !decode_ok || len(data) < 102 do return {}, false // 56 header + 46-byte minimal ownership ticket
	if read_u32_le(data, 0) != 20 do return {}, false  // gc token length
	if read_u32_le(data, 24) != 24 do return {}, false // session header length

	ticket: Steam_Auth_Ticket
	ticket.gc_token = read_u64_le(data, 4)
	ticket.steam_id = read_u64_le(data, 12)
	ticket.token_generated = read_u32_le(data, 20)

	ticket.session_unknown_1 = read_u32_le(data, 28)
	ticket.session_unknown_2 = read_u32_le(data, 32)
	ticket.session_external_ip = read_u32_le(data, 36)
	ticket.session_filler = read_u32_le(data, 40)
	ticket.session_time_ms = read_u32_le(data, 44)
	ticket.session_count = read_u32_le(data, 48)

	// Offset 52 holds the length of everything that follows it (ownership ticket +
	// signature); the ownership ticket then length-prefixes itself again at offset 56.
	rest_len := int(read_u32_le(data, 52))
	if 56 + rest_len != len(data) do return {}, false

	ownership_offset := 56
	ownership_len := int(read_u32_le(data, ownership_offset)) // includes this 4-byte length field
	signature_offset := ownership_offset + ownership_len
	if ownership_len < 46 || signature_offset > len(data) do return {}, false
	ticket.signature = data[signature_offset:] // 0 or 128 bytes (RSA-2048 over the ownership ticket)

	ticket.ownership_version = read_u32_le(data, ownership_offset + 4)
	ticket.ownership_steam_id = read_u64_le(data, ownership_offset + 8)
	ticket.ownership_app_id = read_u32_le(data, ownership_offset + 16)
	ticket.ownership_external_ip = read_u32_le(data, ownership_offset + 20)
	ticket.ownership_internal_ip = read_u32_le(data, ownership_offset + 24)
	ticket.ownership_flags = read_u32_le(data, ownership_offset + 28)
	ticket.ownership_generated = read_u32_le(data, ownership_offset + 32)
	ticket.ownership_expires = read_u32_le(data, ownership_offset + 36)

	pos := ownership_offset + 40
	if pos + 2 > signature_offset do return {}, false
	license_count := int(read_u16_le(data, pos)); pos += 2
	licenses := make([dynamic]u32, allocator)
	for _ in 0 ..< license_count {
		if pos + 4 > signature_offset do return {}, false
		append(&licenses, read_u32_le(data, pos)); pos += 4
	}
	ticket.licenses = licenses[:]

	if pos + 2 > signature_offset do return {}, false
	dlc_count := int(read_u16_le(data, pos)); pos += 2
	dlc_entries := make([dynamic]Steam_Dlc, allocator)
	for _ in 0 ..< dlc_count {
		if pos + 6 > signature_offset do return {}, false
		dlc: Steam_Dlc
		dlc.app_id = read_u32_le(data, pos); pos += 4
		dlc_license_count := int(read_u16_le(data, pos)); pos += 2
		dlc_licenses := make([dynamic]u32, allocator)
		for _ in 0 ..< dlc_license_count {
			if pos + 4 > signature_offset do return {}, false
			append(&dlc_licenses, read_u32_le(data, pos)); pos += 4
		}
		dlc.licenses = dlc_licenses[:]
		append(&dlc_entries, dlc)
	}
	ticket.dlc = dlc_entries[:]

	if pos + 2 != signature_offset do return {}, false // reserved u16 must end exactly at the signature
	ticket.ownership_reserved = read_u16_le(data, pos)
	return ticket, true
}

encode_steam_ticket :: proc(ticket: Steam_Auth_Ticket, allocator := context.allocator) -> string {
	out := make([dynamic]byte, allocator)
	// game-connect token
	write_u32_le(&out, 20) // gc token length
	write_u64_le(&out, ticket.gc_token)
	write_u64_le(&out, ticket.steam_id)
	write_u32_le(&out, ticket.token_generated)
	// session header
	write_u32_le(&out, 24) // session header length
	write_u32_le(&out, ticket.session_unknown_1)
	write_u32_le(&out, ticket.session_unknown_2)
	write_u32_le(&out, ticket.session_external_ip)
	write_u32_le(&out, ticket.session_filler)
	write_u32_le(&out, ticket.session_time_ms)
	write_u32_le(&out, ticket.session_count)

	// Assemble the ownership ticket body (everything after its own length field) so
	// both length prefixes can be computed from it.
	ownership_body := make([dynamic]byte, allocator)
	write_u32_le(&ownership_body, ticket.ownership_version)
	write_u64_le(&ownership_body, ticket.ownership_steam_id)
	write_u32_le(&ownership_body, ticket.ownership_app_id)
	write_u32_le(&ownership_body, ticket.ownership_external_ip)
	write_u32_le(&ownership_body, ticket.ownership_internal_ip)
	write_u32_le(&ownership_body, ticket.ownership_flags)
	write_u32_le(&ownership_body, ticket.ownership_generated)
	write_u32_le(&ownership_body, ticket.ownership_expires)
	write_u16_le(&ownership_body, u16(len(ticket.licenses)))
	for license in ticket.licenses do write_u32_le(&ownership_body, license)
	write_u16_le(&ownership_body, u16(len(ticket.dlc)))
	for dlc in ticket.dlc {
		write_u32_le(&ownership_body, dlc.app_id)
		write_u16_le(&ownership_body, u16(len(dlc.licenses)))
		for license in dlc.licenses do write_u32_le(&ownership_body, license)
	}
	write_u16_le(&ownership_body, ticket.ownership_reserved)

	ownership_len := 4 + len(ownership_body)
	write_u32_le(&out, u32(ownership_len + len(ticket.signature))) // rest length
	write_u32_le(&out, u32(ownership_len))                         // ownership ticket length
	append(&out, ..ownership_body[:])
	append(&out, ..ticket.signature)

	// The ticket travels as upper-case ASCII hex; hex.encode emits lower-case.
	return strings.to_upper(string(hex.encode(out[:], allocator)), allocator)
}

// --- msgpack string + little-endian scalar helpers -----------------------------

// Read a msgpack string (fixstr / str8 / str16 / str32). The returned string
// aliases the source buffer.
mp_read_str :: proc(data: []byte, offset: int) -> (string, int, bool) {
	if offset >= len(data) do return "", offset, false
	lead_byte := data[offset]
	pos := offset + 1
	length: int
	switch {
	case lead_byte >= 0xa0 && lead_byte <= 0xbf:
		length = int(lead_byte & 0x1f)
	case lead_byte == 0xd9:
		if pos + 1 > len(data) do return "", offset, false
		length = int(data[pos]); pos += 1
	case lead_byte == 0xda:
		if pos + 2 > len(data) do return "", offset, false
		length = int(data[pos]) << 8 | int(data[pos + 1]); pos += 2
	case lead_byte == 0xdb:
		if pos + 4 > len(data) do return "", offset, false
		length = int(data[pos]) << 24 | int(data[pos + 1]) << 16 | int(data[pos + 2]) << 8 | int(data[pos + 3]); pos += 4
	case:
		return "", offset, false
	}
	if pos + length > len(data) do return "", offset, false
	return string(data[pos : pos + length]), pos + length, true
}

// Write a msgpack string in its shortest form, matching how the client encodes it.
mp_write_str :: proc(buffer: ^[dynamic]byte, text: string) {
	length := len(text)
	switch {
	case length <= 31:
		append(buffer, 0xa0 | u8(length))
	case length <= 0xff:
		append(buffer, 0xd9, u8(length))
	case length <= 0xffff:
		append(buffer, 0xda, u8(length >> 8), u8(length))
	case:
		append(buffer, 0xdb, u8(length >> 24), u8(length >> 16), u8(length >> 8), u8(length))
	}
	append(buffer, ..transmute([]byte)text)
}

read_u16_le :: proc(data: []byte, offset: int) -> u16 {
	return u16(data[offset]) | u16(data[offset + 1]) << 8
}

read_u32_le :: proc(data: []byte, offset: int) -> u32 {
	return u32(data[offset]) | u32(data[offset + 1]) << 8 | u32(data[offset + 2]) << 16 | u32(data[offset + 3]) << 24
}

read_u64_le :: proc(data: []byte, offset: int) -> u64 {
	value: u64
	for byte_index in 0 ..< 8 do value |= u64(data[offset + byte_index]) << uint(8 * byte_index)
	return value
}

write_u16_le :: proc(buffer: ^[dynamic]byte, value: u16) {
	append(buffer, u8(value), u8(value >> 8))
}

write_u32_le :: proc(buffer: ^[dynamic]byte, value: u32) {
	append(buffer, u8(value), u8(value >> 8), u8(value >> 16), u8(value >> 24))
}

write_u64_le :: proc(buffer: ^[dynamic]byte, value: u64) {
	for byte_index in 0 ..< 8 do append(buffer, u8(value >> uint(8 * byte_index)))
}

// Format a u32 IP (stored most-significant octet first) as dotted-quad.
ipv4_string :: proc(address: u32) -> string {
	return fmt.tprintf("%d.%d.%d.%d", (address >> 24) & 0xff, (address >> 16) & 0xff, (address >> 8) & 0xff, address & 0xff)
}

// --- demo ----------------------------------------------------------------------

SAMPLE_HEX :: "8d0600010092a5737465616d85b967616d6556657273696f6e2e636c69656e7456657273696f6eaa312e30352e30302e3035a870726f7669646572a5737465616da67469636b6574da01d4313430303030303036444637314133373342463345333331424239463043303130313030313030313939463532353641313830303030303030313030303030303035303030303030383334433232313336364445324245323832353535333134363030313030303042323030303030303332303030303030303430303030303042423946304330313031303031303031463039413146303041373539394242383831303130313041303030303030303042433533314236413343303333373641303130303539433231303030303030303030303042413645373244394630383543374435434432363238443232433043304436373534344336443443313632434136363432343846303736453744344438413143454432393741383642353936413941323842324341463533453146433745393142384434383646353933393942393645433643313130464544363538394133423439453038343632363843434339344231374238314645414630344242304230444332333236334646454541354237304134334131464136434333343237414638344543373046353341464544323234414533323731343936353644454232354344413035453837434446323637374241373245453533423846393035424130a776657273696f6ea27631a56170704964a732303731323830"

main :: proc() {
	body, decode_ok := decode_authentication_login(SAMPLE_HEX)
	if !decode_ok {
		fmt.eprintln("decode failed")
		return
	}

	fmt.printfln("type           = %v", get_scene_message_type_from_handle_and_route(body.handle, body.route))
	fmt.printfln("handle         = %d", body.handle)
	fmt.printfln("route          = %d", body.route)
	fmt.printfln("rpc_id         = %d", body.rpc_id)
	fmt.printfln("provider       = %q", body.provider)
	fmt.printfln("client_version = %q", body.client_version)
	fmt.printfln("version        = %q", body.version)
	fmt.printfln("app_id         = %q", body.app_id)

	fmt.printfln("roundtrip      = %v", encode_authentication_login(body) == SAMPLE_HEX)

	ticket := body.ticket
	fmt.println("--- steam ticket ---")
	fmt.printfln("  gc_token            = 0x%016x", ticket.gc_token)
	fmt.printfln("  steam_id            = %d", ticket.steam_id)
	fmt.printfln("  token_generated     = %d", ticket.token_generated)
	fmt.printfln("  session external_ip = %s", ipv4_string(ticket.session_external_ip))
	fmt.printfln("  session time_ms     = %d", ticket.session_time_ms)
	fmt.printfln("  session count       = %d", ticket.session_count)
	fmt.printfln("  ownership version   = %d", ticket.ownership_version)
	fmt.printfln("  ownership app_id    = %d", ticket.ownership_app_id)
	fmt.printfln("  ownership ext ip    = %s", ipv4_string(ticket.ownership_external_ip))
	fmt.printfln("  ownership int ip    = %s", ipv4_string(ticket.ownership_internal_ip))
	fmt.printfln("  ownership flags     = 0x%08x", ticket.ownership_flags)
	fmt.printfln("  ownership generated = %d", ticket.ownership_generated)
	fmt.printfln("  ownership expires   = %d", ticket.ownership_expires)
	fmt.printfln("  licenses            = %v", ticket.licenses)
	fmt.printfln("  dlc count           = %d", len(ticket.dlc))
	fmt.printfln("  signature           = %d bytes", len(ticket.signature))

	rebuilt_hex := encode_authentication_login(body)
	fmt.println("--- rebuilt ---")
	fmt.printfln("hex            = %s", rebuilt_hex)
	fmt.printfln("matches input  = %v", rebuilt_hex == SAMPLE_HEX)
}
