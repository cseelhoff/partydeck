package caleb_raknet

// Layer 6 (Stormancer scene messages): decode a Scene_Message body -- the bytes
// addressed to a scene route -- into a structured Scene_Body.
//
// On the wire a scene message is [sceneHandle:1][routeHandle:2 LE][body] (see
// frames.odin Scene_Message; `body` here is everything after the route handle).
// The body's framing is set by the Stormancer RPC plugin (predict.py
// _send_scene_msg / _on_scene_message):
//   * an RPC invocation / streamed reply (rpc.next) / error carries
//     [rpcRequestId:2 LE] followed by ONE OR MORE concatenated msgpack values --
//     the serializer writes top-level values back-to-back, not wrapped in an array.
//   * control routes carry only ids (rpc.cancel = [reqId:2], rpc.completed =
//     [messageSent:1][reqId:2]).
//   * a few fire-and-forget pushes carry raw msgpack with no leading id.
// Which one applies is decided by the route NAME, which needs the per-scene route
// table -- a higher, stateful layer. So we decode the universal shape: try the
// rpc-framed form (strip the u16 id, decode the rest as a msgpack value list); if
// that leaves trailing garbage, fall back to decoding the whole body as a value
// list. Either way the msgpack structure -- and the strings inside it -- surface.
//
// Two Stormancer conventions hide further structure inside those strings: JSON
// ({...}/[...]) and base64 of a JSON/text token. write_scene_body expands both, so
// a value like "eyJQYXJ0eUlk..." shows its decoded {"PartyId":...} inline.

import "core:encoding/base64"
import "core:fmt"
import "core:strings"

// The decoded form of a Scene_Message body: an optional leading RPC request id
// plus the trailing list of msgpack values. `values.ok` is false when the bytes
// were not a clean value sequence (a control frame or an unmodeled push shape).
// `raw_tail` holds the bytes past the structured value list when the body is a
// msgpack prefix followed by a non-msgpack blob (an RPC reply whose payload is a
// game struct of raw pointers, say); it is empty for a clean body.
Scene_Body :: struct {
	rpc_id:     u16,
	has_rpc_id: bool,
	values:     Msgpack_Seq,
	raw_tail:   []byte,
}

// Decode a scene route payload. Both readings are tried -- rpc-framed ([reqId:2] +
// values) and whole-body (raw concatenated msgpack) -- because the route handle
// alone cannot say which applies. The reading with FEWER top-level values wins: a
// wrong framing splits one value's bytes into a run of stray fixints, so the right
// one is almost always the shorter list. Ties favour the rpc-framed reading, which
// is the common case. A reading is only eligible if it consumed every byte cleanly.
//
// A body that is a clean msgpack prefix trailed by a non-msgpack blob (e.g. the
// Authentication.Login reply: a session-token JSON string followed by a game
// struct full of raw pointers) decodes neither way -- the trailing bytes turn into
// a flood of bare fixints. When the winning reading did not consume cleanly we
// re-decode it with the loose-tail guard, which stops the value list at the opaque
// blob and surfaces that blob as `raw_tail` instead of hundreds of stray scalars.
decode_scene_body :: proc(body: []byte, allocator := context.allocator) -> Scene_Body {
	whole := msgpack_decode_seq(body, allocator = allocator)
	if len(body) >= 2 {
		framed := msgpack_decode_seq(body[2:], allocator = allocator)
		if framed.ok && (!whole.ok || len(framed.roots) <= len(whole.roots)) {
			return Scene_Body{rpc_id = read_u16_le(body, 0), has_rpc_id = true, values = framed}
		}
		// Neither reading was clean: prefer the rpc framing (strip the request id)
		// when its structured prefix is no longer fragmented than the whole-body one
		// AND, allowing for the 2-byte id it dropped, it explained essentially the
		// same span. The second test rejects a non-rpc push (no leading id) whose
		// 2-byte shift would shatter msgpack alignment and stop consuming far short
		// of the whole-body reading. The opaque remainder becomes raw_tail.
		if !framed.ok && !whole.ok {
			fp := msgpack_decode_seq(body[2:], stop_at_loose_tail = true, allocator = allocator)
			wp := msgpack_decode_seq(body, stop_at_loose_tail = true, allocator = allocator)
			if len(fp.roots) <= len(wp.roots) && fp.consumed + 2 >= wp.consumed {
				return Scene_Body {
					rpc_id = read_u16_le(body, 0),
					has_rpc_id = true,
					values = fp,
					raw_tail = body[2:][fp.consumed:],
				}
			}
			return Scene_Body{values = wp, raw_tail = body[wp.consumed:]}
		}
	}
	return Scene_Body{values = whole}
}

// --- debug rendering --------------------------------------------------------

// Write a one-line summary of a decoded scene body into `sb`: the rpc id (when the
// rpc-framed reading held) and the bracketed value list, with embedded JSON/base64
// strings expanded. A non-empty `raw_tail` (a msgpack prefix trailed by an opaque
// blob) is reported as its byte length plus a short hex preview rather than decoded;
// a body that simply ran out mid-value is flagged `<trailing>`.
write_scene_body :: proc(sb: ^strings.Builder, body: Scene_Body) {
	if body.has_rpc_id do fmt.sbprintf(sb, "rpc=%d ", body.rpc_id)
	strings.write_byte(sb, '[')
	for root, i in body.values.roots {
		if i > 0 do strings.write_string(sb, ", ")
		write_scene_value(sb, body.values.nodes, root)
	}
	strings.write_byte(sb, ']')
	if len(body.raw_tail) > 0 {
		write_raw_tail(sb, body.raw_tail)
	} else if !body.values.ok {
		strings.write_string(sb, " <trailing>")
	}
}

// Append the opaque trailing blob as `+<n>B raw <hex...>`: its length plus the
// first few bytes in hex, enough to recognise it without dumping the whole struct.
write_raw_tail :: proc(sb: ^strings.Builder, tail: []byte) {
	preview := min(len(tail), 16)
	fmt.sbprintf(sb, " +%dB raw ", len(tail))
	for k in 0 ..< preview {
		fmt.sbprintf(sb, "%02x", tail[k])
	}
	if len(tail) > preview do strings.write_string(sb, "...")
}

// Render one msgpack value, recursing through arrays/maps so embedded strings are
// reached at any depth. Only the Str case differs from the generic mp_write (it
// expands JSON / base64 tokens); every other kind defers to mp_write unchanged.
// Bounds-checked at every step: a truncated body (values.ok == false) leaves
// containers whose declared count outruns the pool, so the walk must stop short
// rather than index past the end.
write_scene_value :: proc(b: ^strings.Builder, nodes: []Msgpack_Node, i: int) -> int {
	if i < 0 || i >= len(nodes) do return i
	n := nodes[i]
	#partial switch n.kind {
	case .Str:
		write_scene_string(b, n.str)
		return i + 1
	case .Bin:
		write_scene_bin(b, n.bin)
		return i + 1
	case .Array:
		strings.write_byte(b, '[')
		j := i + 1
		for k in 0 ..< n.count {
			if j >= len(nodes) do break
			if k > 0 do strings.write_string(b, ", ")
			j = write_scene_value(b, nodes, j)
		}
		strings.write_byte(b, ']')
		return j
	case .Map:
		strings.write_byte(b, '{')
		j := i + 1
		for k in 0 ..< n.count {
			if j >= len(nodes) do break
			if k > 0 do strings.write_string(b, ", ")
			j = write_scene_value(b, nodes, j) // key
			if j >= len(nodes) do break
			strings.write_string(b, ": ")
			j = write_scene_value(b, nodes, j) // value
		}
		strings.write_byte(b, '}')
		return j
	}
	return mp_write(b, nodes, i) // scalars / bin / ext: identical to the generic render
}

// Render a string value, decoding one layer deeper when it is an encoded payload:
// JSON is shown verbatim (already human text); a base64 token is shown decoded.
// A plain string is quoted as usual.
write_scene_string :: proc(b: ^strings.Builder, s: string) {
	if is_json_like(s) {
		fmt.sbprintf(b, "json:%s", s)
		return
	}
	if decoded, ok := try_base64_text(s); ok {
		fmt.sbprintf(b, "b64:%q", decoded)
		return
	}
	fmt.sbprintf(b, "%q", s)
}

// Render a msgpack `bin` payload, decoding it one layer deeper when it carries
// text. Stormancer wraps a PartyMember's userdata JSON document in a `bin` just as
// often as it carries a random 16-byte session id or a binary P2P token, so a
// printable payload is shown like a string (json:/b64:/quoted) while anything
// genuinely binary stays summarized as bin<n>.
write_scene_bin :: proc(b: ^strings.Builder, data: []byte) {
	if is_printable_text(data) {
		write_scene_string(b, string(data))
		return
	}
	fmt.sbprintf(b, "bin<%d>", len(data))
}

// A string is JSON-like when it is a non-trivial object or array literal -- enough
// to skip the generic quoting and show it as the structured text it already is.
is_json_like :: proc(s: string) -> bool {
	if len(s) < 2 do return false
	a, z := s[0], s[len(s) - 1]
	return (a == '{' && z == '}') || (a == '[' && z == ']')
}

// Try to read `s` (or its first dot-separated segment, for JWT-style tokens) as
// base64 of printable text -- e.g. a token whose payload is JSON. Returns the
// decoded text only when the charset is clean and the result is fully printable,
// so random hex ids and binary tokens are left encoded. Uses the temp allocator.
try_base64_text :: proc(s: string) -> (string, bool) {
	seg := s
	if dot := strings.index_byte(s, '.'); dot > 0 do seg = s[:dot]
	if len(seg) < 8 || len(seg) % 4 != 0 do return "", false
	for i in 0 ..< len(seg) {
		c := seg[i]
		clean :=
			(c >= 'A' && c <= 'Z') ||
			(c >= 'a' && c <= 'z') ||
			(c >= '0' && c <= '9') ||
			c == '+' ||
			c == '/' ||
			c == '='
		if !clean do return "", false
	}
	decoded, err := base64.decode(seg, base64.DEC_TABLE, context.temp_allocator)
	if err != nil || !is_printable_text(decoded) do return "", false
	return string(decoded), true
}

// All bytes printable ASCII or common whitespace, with at least one byte -- the
// gate that keeps base64-of-binary (session tokens, raw ids) from being "decoded".
is_printable_text :: proc(data: []byte) -> bool {
	if len(data) == 0 do return false
	for c in data {
		if c == '\t' || c == '\n' || c == '\r' do continue
		if c < 0x20 || c > 0x7e do return false
	}
	return true
}
