package caleb_raknet

// msgpack VALUE ENCODERS for the predictor (predict.py §A port). These build the
// msgpack byte payloads the broker emits (RPC replies, party DTOs, pushes). They
// are the inverse direction of msgpack.odin's decoder and intentionally separate:
// the decoder walks bytes into a node pool; these assemble bytes bottom-up the way
// predict.py's mp_* helpers do.
//
// Each builder returns a freshly allocated []byte (caller passes the allocator --
// the predictor uses a per-call temp arena). Container builders (mpe_array/
// mpe_map) take already-encoded child slices and concatenate them under a header,
// mirroring the Python `mp_array(items)` / `mp_map(pairs)` shape. This is
// allocation-heavy by design; it runs on temp memory reclaimed per predicted
// datagram, so the churn never escapes a single predict() call.
//
// Prefix is `mpe_` (msgpack-encode) to avoid colliding with the decoder's mp_*.

// Single-byte constant values, returned as fresh 1-byte slices so callers can mix
// them with built values uniformly.
MP_NIL :: byte(0xc0)
MP_TRUE :: byte(0xc3)
MP_FALSE :: byte(0xc2)
MP_EMPTY_MAP :: byte(0x80)

mpe_byte :: proc(v: byte, allocator := context.allocator) -> []byte {
	out := make([]byte, 1, allocator)
	out[0] = v
	return out
}

mpe_nil :: proc(allocator := context.allocator) -> []byte {return mpe_byte(MP_NIL, allocator)}
mpe_bool :: proc(b: bool, allocator := context.allocator) -> []byte {
	return mpe_byte(b ? MP_TRUE : MP_FALSE, allocator)
}

// fixstr / str8 / str16 (predict.py mp_str). UTF-8 bytes of `s`.
mpe_str :: proc(s: string, allocator := context.allocator) -> []byte {
	b := transmute([]byte)s
	n := len(b)
	out := make([dynamic]byte, allocator)
	switch {
	case n < 32:
		append(&out, byte(0xa0 | n))
	case n < 256:
		append(&out, 0xd9, byte(n))
	case:
		append(&out, 0xda, byte(n >> 8), byte(n))
	}
	append(&out, ..b)
	return out[:]
}

// positive fixint / uint8 / uint16 / uint32 / uint64 (predict.py mp_uint).
mpe_uint :: proc(n: u64, allocator := context.allocator) -> []byte {
	out := make([dynamic]byte, allocator)
	switch {
	case n < 0x80:
		append(&out, byte(n))
	case n < 0x100:
		append(&out, 0xcc, byte(n))
	case n < 0x10000:
		append(&out, 0xcd, byte(n >> 8), byte(n))
	case n < 0x1_0000_0000:
		append(&out, 0xce, byte(n >> 24), byte(n >> 16), byte(n >> 8), byte(n))
	case:
		append(
			&out, 0xcf,
			byte(n >> 56), byte(n >> 48), byte(n >> 40), byte(n >> 32),
			byte(n >> 24), byte(n >> 16), byte(n >> 8), byte(n),
		)
	}
	return out[:]
}

mpe_int :: proc(n: i64, allocator := context.allocator) -> []byte {
	if n >= 0 do return mpe_uint(u64(n), allocator)
	out := make([dynamic]byte, allocator)
	switch {
	case n >= -32:
		append(&out, byte(i8(n)))
	case n >= -128:
		append(&out, 0xd0, byte(i8(n)))
	case n >= -32768:
		v := u16(i16(n))
		append(&out, 0xd1, byte(v >> 8), byte(v))
	case n >= -2147483648:
		v := u32(i32(n))
		append(&out, 0xd2, byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v))
	case:
		v := u64(n)
		append(
			&out, 0xd3,
			byte(v >> 56), byte(v >> 48), byte(v >> 40), byte(v >> 32),
			byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v),
		)
	}
	return out[:]
}

// bin8 / bin16 / bin32 (predict.py mp_bin).
mpe_bin :: proc(data: []byte, allocator := context.allocator) -> []byte {
	n := len(data)
	out := make([dynamic]byte, allocator)
	switch {
	case n < 256:
		append(&out, 0xc4, byte(n))
	case n < 0x10000:
		append(&out, 0xc5, byte(n >> 8), byte(n))
	case:
		append(&out, 0xc6, byte(n >> 24), byte(n >> 16), byte(n >> 8), byte(n))
	}
	append(&out, ..data)
	return out[:]
}

// fixarray / array16 / array32 over already-encoded items (predict.py mp_array).
mpe_array :: proc(items: [][]byte, allocator := context.allocator) -> []byte {
	n := len(items)
	out := make([dynamic]byte, allocator)
	switch {
	case n < 16:
		append(&out, byte(0x90 | n))
	case n < 0x10000:
		append(&out, 0xdc, byte(n >> 8), byte(n))
	case:
		append(&out, 0xdd, byte(n >> 24), byte(n >> 16), byte(n >> 8), byte(n))
	}
	for it in items do append(&out, ..it)
	return out[:]
}

// fixmap / map16 over already-encoded key/value pairs (predict.py mp_map). `pairs`
// is a flat [k0,v0,k1,v1,...] slice; len must be even.
mpe_map :: proc(pairs: [][]byte, allocator := context.allocator) -> []byte {
	n := len(pairs) / 2
	out := make([dynamic]byte, allocator)
	if n < 16 {
		append(&out, byte(0x80 | n))
	} else {
		append(&out, 0xde, byte(n >> 8), byte(n))
	}
	for p in pairs do append(&out, ..p)
	return out[:]
}

// MessagePack reserved timestamp ext (fixext8, type -1/0xff) in timestamp64 layout
// (hi 30 bits nanos, lo 34 bits secs). predict.py mp_timestamp.
mpe_timestamp :: proc(unix_sec: u64, nanos: u64 = 0, allocator := context.allocator) -> []byte {
	v := ((nanos & 0x3fff_ffff) << 34) | (unix_sec & 0x3_ffff_ffff)
	out := make([]byte, 10, allocator)
	out[0] = 0xd7
	out[1] = 0xff
	out[2] = byte(v >> 56); out[3] = byte(v >> 48); out[4] = byte(v >> 40); out[5] = byte(v >> 32)
	out[6] = byte(v >> 24); out[7] = byte(v >> 16); out[8] = byte(v >> 8); out[9] = byte(v)
	return out
}

// Concatenate several encoded fragments into one slice (for values that are
// several msgpack values back to back, e.g. session-token = jwt-str + sid-str).
mpe_concat :: proc(parts: ..[]byte, allocator := context.allocator) -> []byte {
	total := 0
	for p in parts do total += len(p)
	out := make([]byte, total, allocator)
	off := 0
	for p in parts {
		copy(out[off:], p)
		off += len(p)
	}
	return out
}
