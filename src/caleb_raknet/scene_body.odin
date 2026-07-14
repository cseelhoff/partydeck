package caleb_raknet

import "core:encoding/base64"
import "core:fmt"
import "core:strings"

Scene_Body :: struct {
	rpc_id:     u16,
	has_rpc_id: bool,
	values:     Msgpack_Seq,
	raw_tail:   []byte,
}

decode_scene_body :: proc(body: []byte, allocator := context.allocator) -> Scene_Body {
	whole := msgpack_decode_seq(body, allocator = allocator)
	if len(body) >= 2 {
		framed := msgpack_decode_seq(body[2:], allocator = allocator)
		if framed.ok && (!whole.ok || len(framed.roots) <= len(whole.roots)) {
			return Scene_Body{rpc_id = read_u16_le(body, 0), has_rpc_id = true, values = framed}
		}
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

write_scene_body :: proc(sb: ^strings.Builder, body: Scene_Body) {
	if scene_body_first_root_has_token(body) {
		write_stormancer_rpc_next_body(sb, parse_stormancer_rpc_next_body(body))
		return
	}
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
		trailing := body.values.raw[body.values.consumed:]
		if len(trailing) > 0 {
			write_quoted_printable_tail(sb, trailing)
		} else {
			strings.write_string(sb, " tail={bytes=0, quoted_printable=quoted_printable<0> \"\"}")
		}
	}
}

scene_body_first_root_has_token :: proc(body: Scene_Body) -> bool {
	if len(body.values.roots) == 0 do return false
	root := body.values.roots[0]
	if root < 0 || root >= len(body.values.nodes) do return false
	node := body.values.nodes[root]
	return node.kind == .Str && json_string_value(node.str, "token") != ""
}

write_raw_tail :: proc(sb: ^strings.Builder, tail: []byte) {
	if len(tail) == 0 do return
	if write_msgpack_tail(sb, tail) do return
	fmt.sbprintf(sb, " tail={{bytes=%d", len(tail))
	write_tail_text_fragments(sb, tail)
	strings.write_string(sb, ", raw_bytes=")
	write_byte_values(sb, tail)
	strings.write_byte(sb, '}')
}

write_msgpack_tail :: proc(sb: ^strings.Builder, tail: []byte) -> bool {
	decoded := msgpack_decode_seq(tail, allocator = context.temp_allocator)
	if !decoded.ok || len(decoded.roots) == 0 do return false
	fmt.sbprintf(sb, " tail={{bytes=%d, msgpack=[", len(tail))
	for root, i in decoded.roots {
		if i > 0 do strings.write_string(sb, ", ")
		write_scene_value(sb, decoded.nodes, root)
	}
	strings.write_string(sb, "]}")
	return true
}

write_tail_text_fragments :: proc(sb: ^strings.Builder, tail: []byte) {
	wrote_header := false
	written := 0
	for i := 0; i < len(tail); {
		for i < len(tail) && !tail_byte_is_printable(tail[i]) do i += 1
		start := i
		for i < len(tail) && tail_byte_is_printable(tail[i]) do i += 1
		if i - start < 8 do continue
		if !wrote_header {
			strings.write_string(sb, ", text=[")
			wrote_header = true
		} else {
			strings.write_string(sb, ", ")
		}
		fragment := string(tail[start:i])
		if len(fragment) > 96 do fragment = fragment[:96]
		fmt.sbprintf(sb, "%q", fragment)
		written += 1
		if written >= 3 do break
	}
	if wrote_header do strings.write_byte(sb, ']')
}

tail_byte_is_printable :: proc(c: byte) -> bool {
	return c >= 0x20 && c <= 0x7e
}

write_byte_values :: proc(sb: ^strings.Builder, data: []byte) {
	strings.write_byte(sb, '[')
	for value, i in data {
		if i > 0 do strings.write_string(sb, ", ")
		fmt.sbprintf(sb, "%d", value)
	}
	strings.write_byte(sb, ']')
}

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
			j = write_scene_value(b, nodes, j)
			if j >= len(nodes) do break
			strings.write_string(b, ": ")
			j = write_scene_value(b, nodes, j)
		}
		strings.write_byte(b, '}')
		return j
	}
	return mp_write(b, nodes, i)
}

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

write_scene_bin :: proc(b: ^strings.Builder, data: []byte) {
	if is_printable_text(data) {
		write_scene_string(b, string(data))
		return
	}
	if len(data) == 16 {
		write_hex_bytes(b, data)
		return
	}
	write_quoted_printable_bytes(b, data)
}

is_json_like :: proc(s: string) -> bool {
	if len(s) < 2 do return false
	a, z := s[0], s[len(s) - 1]
	return (a == '{' && z == '}') || (a == '[' && z == ']')
}

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

is_printable_text :: proc(data: []byte) -> bool {
	if len(data) == 0 do return false
	for c in data {
		if c == '\t' || c == '\n' || c == '\r' do continue
		if c < 0x20 || c > 0x7e do return false
	}
	return true
}
