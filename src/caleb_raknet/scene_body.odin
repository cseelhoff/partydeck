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

write_raw_tail :: proc(sb: ^strings.Builder, tail: []byte) {
	preview := min(len(tail), 16)
	fmt.sbprintf(sb, " +%dB raw ", len(tail))
	for k in 0 ..< preview do fmt.sbprintf(sb, "%02x", tail[k])
	if len(tail) > preview do strings.write_string(sb, "...")
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
	fmt.sbprintf(b, "bin<%d>", len(data))
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
