package caleb_raknet

// MessagePack decoder for Stormancer payloads (System_Request.args, Response_Msg
// data, ConnectionData tokens, scene route maps). Stormancer RPC bodies are
// msgpack; RakNet itself never touches them.
//
// Representation is a flat node pool (Struct-of-handles), not a recursive value
// union: msgpack_decode walks the bytes once and appends nodes in PRE-ORDER DFS,
// so every node's whole subtree is one contiguous run [idx, idx+subtree). That
// makes "skip to next sibling" a single integer add (`subtree`) instead of a
// pointer chase, and keeps strings/bins as zero-copy slices into the source.
//
// Supported types: nil, bool, int/uint (8..64 + fixints), float32/64,
// str (fix/8/16/32), bin (8/16/32), array (fix/16/32), map (fix/16/32),
// ext (fix + 8/16/32, incl. timestamp ext -1). That is the full set seen on the
// wire plus the rest of the common spec, since it costs little extra.

import "core:encoding/base64"
import "core:fmt"
import "core:strings"

Msgpack_Kind :: enum u8 {
	Invalid = 0, // truncated / reserved 0xc1 / unknown
	Nil,
	Bool,
	Int, // signed; use when the wire type is an int family
	Uint, // unsigned; fixint and uint family
	Float,
	Str,
	Bin,
	Array,
	Map,
	Ext,
}

// A single decoded value. Containers (Array/Map) own a contiguous run of child
// nodes that follows immediately in the pool; `count` is the element count
// (Map: pair count, so the run holds 2*count nodes as k0,v0,k1,v1,...).
Msgpack_Node :: struct {
	kind:     Msgpack_Kind,
	subtree:  int, // nodes in this subtree incl. self (>=1); add to an index to skip the value
	count:    int, // Array: #elements; Map: #pairs; Str/Bin/Ext: byte length
	ext_type: i8, // Ext only
	b:        bool, // Bool
	i:        i64, // Int
	u:        u64, // Uint
	f:        f64, // Float
	str:      string, // Str: utf-8 slice into the source buffer
	bin:      []byte, // Bin / Ext payload: raw slice into the source buffer
}

Msgpack_Decoder :: struct {
	src: []byte,
	pos: int,
	pool: ^[dynamic]Msgpack_Node,
	ok:  bool,
}

// Decode one top-level msgpack value (plus its whole tree) from `src`.
// Returns the node pool (root at index 0) and ok=false if the bytes were
// truncated, contained a reserved/unknown type, or had trailing garbage.
// Caller owns `nodes` (delete it).
msgpack_decode :: proc(src: []byte, allocator := context.allocator) -> (nodes: [dynamic]Msgpack_Node, ok: bool) {
	pool := make([dynamic]Msgpack_Node, allocator)
	if len(src) == 0 do return pool, false
	d := Msgpack_Decoder{src = src, pool = &pool, ok = true}
	mp_value(&d)
	return pool, d.ok && d.pos == len(src)
}

mp_value :: proc(d: ^Msgpack_Decoder) -> int {
	idx := len(d.pool)
	append(d.pool, Msgpack_Node{}) // reserve slot; rewritten at the end
	node := Msgpack_Node{}

	if d.pos >= len(d.src) {
		d.ok = false
		node.kind = .Invalid
		d.pool[idx] = node
		return idx
	}
	c := d.src[d.pos]
	d.pos += 1

	switch {
	case c <= 0x7f: // positive fixint
		node.kind = .Uint
		node.u = u64(c)
	case c >= 0xe0: // negative fixint
		node.kind = .Int
		node.i = i64(i8(c))
	case c >= 0xa0 && c <= 0xbf: // fixstr
		mp_take_str(d, &node, int(c & 0x1f))
	case c >= 0x90 && c <= 0x9f: // fixarray
		mp_array(d, &node, int(c & 0x0f))
	case c >= 0x80 && c <= 0x8f: // fixmap
		mp_map(d, &node, int(c & 0x0f))
	case:
		switch c {
		case 0xc0:
			node.kind = .Nil
		case 0xc2:
			node.kind = .Bool
			node.b = false
		case 0xc3:
			node.kind = .Bool
			node.b = true
		case 0xcc:
			node.kind = .Uint
			node.u = u64(mp_u8(d))
		case 0xcd:
			node.kind = .Uint
			node.u = u64(mp_u16(d))
		case 0xce:
			node.kind = .Uint
			node.u = u64(mp_u32(d))
		case 0xcf:
			node.kind = .Uint
			node.u = mp_u64(d)
		case 0xd0:
			node.kind = .Int
			node.i = i64(i8(mp_u8(d)))
		case 0xd1:
			node.kind = .Int
			node.i = i64(i16(mp_u16(d)))
		case 0xd2:
			node.kind = .Int
			node.i = i64(i32(mp_u32(d)))
		case 0xd3:
			node.kind = .Int
			node.i = i64(mp_u64(d))
		case 0xca:
			node.kind = .Float
			node.f = f64(transmute(f32)mp_u32(d))
		case 0xcb:
			node.kind = .Float
			node.f = transmute(f64)mp_u64(d)
		case 0xd9:
			mp_take_str(d, &node, int(mp_u8(d)))
		case 0xda:
			mp_take_str(d, &node, int(mp_u16(d)))
		case 0xdb:
			mp_take_str(d, &node, int(mp_u32(d)))
		case 0xc4:
			mp_take_bin(d, &node, int(mp_u8(d)))
		case 0xc5:
			mp_take_bin(d, &node, int(mp_u16(d)))
		case 0xc6:
			mp_take_bin(d, &node, int(mp_u32(d)))
		case 0xdc:
			mp_array(d, &node, int(mp_u16(d)))
		case 0xdd:
			mp_array(d, &node, int(mp_u32(d)))
		case 0xde:
			mp_map(d, &node, int(mp_u16(d)))
		case 0xdf:
			mp_map(d, &node, int(mp_u32(d)))
		case 0xd4:
			mp_take_ext(d, &node, 1)
		case 0xd5:
			mp_take_ext(d, &node, 2)
		case 0xd6:
			mp_take_ext(d, &node, 4)
		case 0xd7:
			mp_take_ext(d, &node, 8)
		case 0xd8:
			mp_take_ext(d, &node, 16)
		case 0xc7:
			mp_take_ext(d, &node, int(mp_u8(d)))
		case 0xc8:
			mp_take_ext(d, &node, int(mp_u16(d)))
		case 0xc9:
			mp_take_ext(d, &node, int(mp_u32(d)))
		case: // 0xc1 (never used) and anything unaccounted for
			node.kind = .Invalid
			d.ok = false
		}
	}

	node.subtree = len(d.pool) - idx
	d.pool[idx] = node
	return idx
}

mp_array :: proc(d: ^Msgpack_Decoder, node: ^Msgpack_Node, n: int) {
	node.kind = .Array
	node.count = n
	for _ in 0 ..< n {
		if !d.ok do return
		mp_value(d)
	}
}

mp_map :: proc(d: ^Msgpack_Decoder, node: ^Msgpack_Node, n: int) {
	node.kind = .Map
	node.count = n
	for _ in 0 ..< n {
		if !d.ok do return
		mp_value(d) // key
		mp_value(d) // value
	}
}

mp_take_str :: proc(d: ^Msgpack_Decoder, node: ^Msgpack_Node, n: int) {
	if n < 0 || d.pos + n > len(d.src) {
		d.ok = false
		node.kind = .Invalid
		return
	}
	node.kind = .Str
	node.count = n
	node.str = string(d.src[d.pos:d.pos + n])
	d.pos += n
}

mp_take_bin :: proc(d: ^Msgpack_Decoder, node: ^Msgpack_Node, n: int) {
	if n < 0 || d.pos + n > len(d.src) {
		d.ok = false
		node.kind = .Invalid
		return
	}
	node.kind = .Bin
	node.count = n
	node.bin = d.src[d.pos:d.pos + n]
	d.pos += n
}

mp_take_ext :: proc(d: ^Msgpack_Decoder, node: ^Msgpack_Node, n: int) {
	t := mp_u8(d) // ext type byte precedes the payload in every ext form
	if n < 0 || d.pos + n > len(d.src) {
		d.ok = false
		node.kind = .Invalid
		return
	}
	node.kind = .Ext
	node.ext_type = i8(t)
	node.count = n
	node.bin = d.src[d.pos:d.pos + n]
	d.pos += n
}

mp_u8 :: proc(d: ^Msgpack_Decoder) -> u8 {
	if d.pos + 1 > len(d.src) {
		d.ok = false
		return 0
	}
	v := d.src[d.pos]
	d.pos += 1
	return v
}

mp_u16 :: proc(d: ^Msgpack_Decoder) -> u16 {
	if d.pos + 2 > len(d.src) {
		d.ok = false
		return 0
	}
	v := read_u16_be(d.src, d.pos)
	d.pos += 2
	return v
}

mp_u32 :: proc(d: ^Msgpack_Decoder) -> u32 {
	if d.pos + 4 > len(d.src) {
		d.ok = false
		return 0
	}
	v := read_u32_be(d.src, d.pos)
	d.pos += 4
	return v
}

mp_u64 :: proc(d: ^Msgpack_Decoder) -> u64 {
	if d.pos + 8 > len(d.src) {
		d.ok = false
		return 0
	}
	v := read_u64_be(d.src, d.pos)
	d.pos += 8
	return v
}

// Look up string `key` in the map at `map_idx`; return the value's node index,
// or -1 if missing or not a map. Uses `subtree` to skip over each entry without
// recursing -- the common "pull SceneId/Token out of a request map" pattern.
msgpack_map_get :: proc(nodes: []Msgpack_Node, map_idx: int, key: string) -> int {
	if map_idx < 0 || map_idx >= len(nodes) do return -1
	m := nodes[map_idx]
	if m.kind != .Map do return -1
	j := map_idx + 1
	for _ in 0 ..< m.count {
		k := nodes[j]
		v := j + k.subtree
		if v >= len(nodes) do return -1
		if k.kind == .Str && k.str == key do return v
		j = v + nodes[v].subtree
	}
	return -1
}

// Msgpack is a decoded payload stored in a frame in place of opaque bytes:
// `nodes` is the value tree (root at index 0) when `ok`; otherwise the blob was
// not valid msgpack (e.g. a raw 8/16-byte clock) and only `raw` is meaningful.
// `raw` always aliases the source bytes, so nothing is lost either way.
Msgpack :: struct {
	nodes: []Msgpack_Node,
	raw:   []byte,
	ok:    bool,
}

// A sequence of concatenated top-level msgpack values. Stormancer's serializer
// writes several values back-to-back (no wrapping array), so a scene-message body
// is a forest, not one tree. `roots` holds each value's root index into the shared
// `nodes` pool; `ok` is true only if every byte decoded into a clean value.
// `consumed` is how many source bytes the roots span; src[consumed:] is whatever
// was left undecoded (the loose/opaque tail of a body that is not pure msgpack).
Msgpack_Seq :: struct {
	nodes:    []Msgpack_Node,
	roots:    []int,
	raw:      []byte,
	consumed: int,
	ok:       bool,
}

// Decode `src` as zero or more concatenated msgpack values. Stops at the first
// malformed value but returns every value decoded so far; ok=false then signals
// the bytes were not a clean value sequence. Pool and roots use `allocator`.
//
// `stop_at_loose_tail` guards against a body that is a msgpack value (or two)
// followed by a non-msgpack blob -- e.g. an RPC reply whose payload is a JSON
// string trailed by a game struct full of raw pointers. Without it the trailing
// bytes decode one-by-one into a flood of bare fixints; with it the walk stops at
// the first top-level scalar that follows an already-emitted structured value
// (Str/Bin/Array/Map), leaving src[consumed:] as the opaque tail.
msgpack_decode_seq :: proc(src: []byte, stop_at_loose_tail := false, allocator := context.allocator) -> Msgpack_Seq {
	pool := make([dynamic]Msgpack_Node, allocator)
	roots := make([dynamic]int, allocator)
	d := Msgpack_Decoder{src = src, pool = &pool, ok = true}
	saw_structured := false
	for d.pos < len(d.src) && d.ok {
		if stop_at_loose_tail && saw_structured && mp_is_scalar_lead(d.src[d.pos]) do break
		root := mp_value(&d)
		#partial switch pool[root].kind {
		case .Str, .Bin, .Array, .Map:
			saw_structured = true
		}
		append(&roots, root)
	}
	return Msgpack_Seq {
		nodes = pool[:],
		roots = roots[:],
		raw = src,
		consumed = d.pos,
		ok = d.ok && d.pos == len(src),
	}
}

// True when a msgpack lead byte begins a self-contained scalar (no length-prefixed
// payload and no child values): fixints, nil, bool, the int/uint/float families,
// and fixext/ext (fixed-size tagged scalars). Str/Bin/Array/Map are NOT scalars.
mp_is_scalar_lead :: proc(c: byte) -> bool {
	if c <= 0x7f || c >= 0xe0 do return true // fixint (positive / negative)
	switch c {
	case 0xc0, 0xc2, 0xc3: // nil, false, true
		return true
	case 0xca, 0xcb: // float32/64
		return true
	case 0xcc ..= 0xd3: // uint8..64, int8..64
		return true
	case 0xd4 ..= 0xd8: // fixext1..16
		return true
	}
	return false
}

// Decode a msgpack blob carried by a frame into a Msgpack value. An empty or
// non-msgpack blob yields ok=false with `raw` retained (no error -- some bodies
// are raw clocks, not msgpack). `nodes` is allocated with `allocator`.
decode_msgpack_field :: proc(blob: []byte, allocator := context.allocator) -> Msgpack {
	if len(blob) == 0 do return Msgpack{raw = blob}
	nodes, ok := msgpack_decode(blob, allocator)
	return Msgpack{nodes = nodes[:], raw = blob, ok = ok}
}

// One-line rendering of a decoded field for debug output: the JSON-ish tree, an
// "(empty)" marker, or "<n>B raw" when the bytes were not msgpack. Uses temp.
msgpack_field_string :: proc(m: Msgpack) -> string {
	if len(m.raw) == 0 do return "(empty)"
	if !m.ok do return fmt.tprintf("%dB raw", len(m.raw))
	return msgpack_to_string(m.nodes, context.temp_allocator)
}

// Render the value tree rooted at `nodes[0]` as a compact JSON-ish string.
// Binary/ext payloads are summarized (length + ext type) rather than dumped.
// Caller owns the returned string.
msgpack_to_string :: proc(nodes: []Msgpack_Node, allocator := context.allocator) -> string {
	if len(nodes) == 0 do return strings.clone("<empty>", allocator)
	b := strings.builder_make(allocator)
	mp_write(&b, nodes, 0)
	return strings.to_string(b)
}

mp_write :: proc(b: ^strings.Builder, nodes: []Msgpack_Node, i: int) -> int {
	n := nodes[i]
	switch n.kind {
	case .Nil:
		strings.write_string(b, "nil")
		return i + 1
	case .Bool:
		strings.write_string(b, n.b ? "true" : "false")
		return i + 1
	case .Int:
		fmt.sbprintf(b, "%d", n.i)
		return i + 1
	case .Uint:
		fmt.sbprintf(b, "%d", n.u)
		return i + 1
	case .Float:
		fmt.sbprintf(b, "%g", n.f)
		return i + 1
	case .Str:
		if !mp_write_jwt(b, n.str) {
			fmt.sbprintf(b, "%q", n.str)
		}
		return i + 1
	case .Bin:
		fmt.sbprintf(b, "bin<%d>", n.count)
		return i + 1
	case .Ext:
		fmt.sbprintf(b, "ext(%d)<%d>", n.ext_type, n.count)
		return i + 1
	case .Array:
		strings.write_byte(b, '[')
		j := i + 1
		for k in 0 ..< n.count {
			if k > 0 do strings.write_string(b, ", ")
			j = mp_write(b, nodes, j)
		}
		strings.write_byte(b, ']')
		return j
	case .Map:
		strings.write_byte(b, '{')
		j := i + 1
		for k in 0 ..< n.count {
			if k > 0 do strings.write_string(b, ", ")
			j = mp_write(b, nodes, j) // key
			strings.write_string(b, ": ")
			j = mp_write(b, nodes, j) // value
		}
		strings.write_byte(b, '}')
		return j
	case .Invalid:
		strings.write_string(b, "<invalid>")
		return i + 1
	}
	return i + 1
}

// If `s` is a JSON Web Token (base64url(header).base64url(payload).sig), expand
// it into the decoded header + payload JSON text so no opaque encoded string is
// left in the output; return false (leave it to the caller to quote) otherwise.
// Stormancer mints these as the get-session-token reply value. Conservative: a
// JWT always starts with "eyJ" (base64url of `{"`) and both segments must
// base64url-decode to JSON objects.
mp_write_jwt :: proc(b: ^strings.Builder, s: string) -> bool {
	if !strings.has_prefix(s, "eyJ") do return false
	dot := strings.index_byte(s, '.')
	if dot <= 0 do return false
	rest := s[dot + 1:]
	dot2 := strings.index_byte(rest, '.')
	payload_seg := rest
	sig_len := 0
	if dot2 >= 0 {
		payload_seg = rest[:dot2]
		sig_len = len(rest) - dot2 - 1
	}

	header, hok := b64url_to_json(s[:dot], context.temp_allocator)
	if !hok do return false
	payload, pok := b64url_to_json(payload_seg, context.temp_allocator)
	if !pok do return false

	fmt.sbprintf(b, "JWT{{header=%s payload=%s sig=%dB}}", header, payload, sig_len)
	return true
}

// base64url-decode `seg` (JWT segments are unpadded) and return the bytes as a
// string iff they look like a JSON object ('{' ... '}'). ok=false on a decode
// failure or non-JSON payload, so mp_write_jwt only fires on a genuine token.
b64url_to_json :: proc(seg: string, allocator := context.allocator) -> (string, bool) {
	padded := seg
	if rem := len(seg) % 4; rem != 0 {
		pb := strings.builder_make(allocator)
		strings.write_string(&pb, seg)
		for _ in 0 ..< (4 - rem) do strings.write_byte(&pb, '=')
		padded = strings.to_string(pb)
	}
	decoded, err := base64.decode(padded, base64.DEC_URL_TABLE, allocator)
	if err != nil || len(decoded) == 0 || decoded[0] != '{' do return "", false
	return string(decoded), true
}

