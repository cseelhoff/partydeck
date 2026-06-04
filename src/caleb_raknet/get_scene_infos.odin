package caleb_raknet

// Layer 6 (Stormancer connection token): decode the `Token` string carried by a
// Get_Scene_Infos / Connect_To_Scene request into a typed Connection_Token.
//
// The token is two standard-base64 segments joined by '-':
//   base64(ConnectionData msgpack) "-" base64(signature)
// ConnectionData is an 11-field msgpack map the auth server minted (see
// stoken.py build_connection_data, cross-checked against a captured token):
//   AccountId    str        Issued       timestamp(ext -1)
//   Application  str        Expiration   timestamp(ext -1)
//   UserData     bin        ContentType  str
//   Endpoints    nil|map    SceneId      str   <- the scene this token authorizes
//   Routing      nil|map    DeploymentId str
//   Version      uint
// The signature is server-side only (we never verify it here) -- its length is
// kept so the token round-trips informationally.
//
// Decoded strings alias the base64-DECODED buffer (allocated with the caller's
// allocator), so the Connection_Token is valid only while that allocation lives
// -- in the debug path that is temp, reclaimed per message.

import "core:encoding/base64"
import "core:fmt"
import "core:strings"

// A parsed Stormancer connection token. `ok` is false when the token was empty,
// not base64, or not the expected ConnectionData map; `raw` always holds the
// original token text so nothing is lost on a parse miss.
Connection_Token :: struct {
	account_id:    string,
	application:   string,
	scene_id:      string,
	deployment_id: string,
	content_type:  string,
	issued:        u64, // unix seconds (msgpack timestamp64, low 34 bits)
	expiration:    u64, // unix seconds
	version:       u64,
	user_data:     []byte, // UserData bin (usually empty)
	signature_len: int, // bytes of the base64 signature segment after '-'
	raw:           string, // the original "<b64>-<b64>" token text
	ok:            bool,
}

// Decode a Stormancer connection token string into a Connection_Token. The
// ConnectionData segment is base64-decoded then msgpack-decoded; both use
// `allocator`. Returns ok=false (with `raw` retained) on any malformed input.
parse_connection_token :: proc(token: string, allocator := context.allocator) -> Connection_Token {
	result := Connection_Token {
		raw = token,
	}
	if len(token) == 0 do return result

	// Split on the first '-': standard base64 never contains '-', so it can only
	// be the ConnectionData/signature separator.
	dash := strings.index_byte(token, '-')
	cd_b64 := token
	if dash >= 0 {
		cd_b64 = token[:dash]
		result.signature_len = len(token) - dash - 1
	}

	decoded, derr := base64.decode(cd_b64, base64.DEC_TABLE, allocator)
	if derr != nil do return result

	nodes, mok := msgpack_decode(decoded, allocator)
	if !mok || len(nodes) == 0 || nodes[0].kind != .Map do return result
	n := nodes[:]

	result.account_id = node_str(n, msgpack_map_get(n, 0, "AccountId"))
	result.application = node_str(n, msgpack_map_get(n, 0, "Application"))
	result.content_type = node_str(n, msgpack_map_get(n, 0, "ContentType"))
	result.scene_id = node_str(n, msgpack_map_get(n, 0, "SceneId"))
	result.deployment_id = node_str(n, msgpack_map_get(n, 0, "DeploymentId"))
	result.version = node_uint(n, msgpack_map_get(n, 0, "Version"))
	result.issued = node_timestamp_seconds(n, msgpack_map_get(n, 0, "Issued"))
	result.expiration = node_timestamp_seconds(n, msgpack_map_get(n, 0, "Expiration"))
	result.user_data = node_bin(n, msgpack_map_get(n, 0, "UserData"))
	result.ok = true
	return result
}

// Read a msgpack timestamp64 (fixext8, type -1) as unix seconds. The 8-byte
// big-endian payload packs 30-bit nanoseconds in the high bits and 34-bit
// seconds in the low bits; we keep the seconds.
@(private = "file")
node_timestamp_seconds :: proc(nodes: []Msgpack_Node, idx: int) -> u64 {
	if idx < 0 || idx >= len(nodes) do return 0
	node := nodes[idx]
	if node.kind != .Ext || node.ext_type != -1 || len(node.bin) < 8 do return 0
	return read_u64_be(node.bin, 0) & 0x3_FFFF_FFFF
}

@(private = "file")
node_bin :: proc(nodes: []Msgpack_Node, idx: int) -> []byte {
	if idx < 0 || idx >= len(nodes) do return nil
	if nodes[idx].kind != .Bin do return nil
	return nodes[idx].bin
}

// Write a one-line summary of a connection token into `sb`. Falls back to the
// raw byte length when the token did not parse.
write_connection_token :: proc(sb: ^strings.Builder, t: Connection_Token) {
	if !t.ok {
		fmt.sbprintf(sb, "<token %dB unparsed>", len(t.raw))
		return
	}
	fmt.sbprintf(
		sb,
		"{{scene=%q account=%q app=%q deploy=%q ver=%d issued=%d exp=%d sig=%dB}}",
		t.scene_id,
		t.account_id,
		t.application,
		t.deployment_id,
		t.version,
		t.issued,
		t.expiration,
		t.signature_len,
	)
}
