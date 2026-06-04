package caleb_raknet

// caleb_raknet — a standalone, data-oriented clean-room of sync-raknet.py.
//
// Layer 1: bind a UDP socket and listen. Every received UDP datagram is appended
// to a struct-of-arrays UDP_Datagram_Store: its metadata goes into parallel arrays
// indexed by datagram number, and its bytes are copied into one shared pool.
//
// Layer 2: on startup open a caleb-raknet-<timestamp>.jsonl file and append one
// JSON object per UDP datagram as it is stored.
//
// Layer 3 (messages.odin): turn raw datagrams into atomic application messages --
// unframing, ACK/NAK filtering and split-packet reassembly into a RakNet_Message_Store.
//
// Replay: passing a .jsonl capture path as a command-line argument ingests that
// recorded stream into the same stores instead of listening on the socket.

import "core:fmt"
import "core:net"
import "core:os"
import "core:mem"
import "core:time"
import "core:strings"
import "core:encoding/hex"
import "core:encoding/json"

LISTEN_HOST :: "0.0.0.0"
LISTEN_PORT :: 30100          // matches raknet.py HOST/PORT
MAX_UDP_SIZE :: 65535         // largest a single UDP datagram can be
MAX_UDP_DATAGRAMS :: 4096     // capacity of one UDP_Datagram_Store
MAX_RAKNET_MESSAGES :: 4096   // capacity of one RakNet_Message_Store
BYTE_POOL_SIZE :: 4 * 1024 * 1024

Error :: union #shared_nil {
	net.Network_Error,
	os.Error,
}

UDP_Datagram_Store :: struct {
	froms:      [MAX_UDP_DATAGRAMS]net.Endpoint, // sender address + port
	recv_times: [MAX_UDP_DATAGRAMS]time.Time,    // when each datagram was received
	starts:     [MAX_UDP_DATAGRAMS]int,          // byte offset of datagram i in pool
	lengths:    [MAX_UDP_DATAGRAMS]int,          // byte length of datagram i
	count:      int,                             // number of datagrams stored
	pool:       [BYTE_POOL_SIZE]byte,            // all datagram bytes, back to back
}

Jsonl_Record :: struct {
	t:    string, // rfc3339 receive time
	from: string, // sender "ip:port"
	len:  int,    // datagram byte length
	hex:  string, // datagram bytes, hex-encoded
}

// One in-flight fragmented message, collected by split_id until all `count`
// fragments arrive, then concatenated in index order. Fragment payloads are
// slices into the datagram store's append-only pool, which stays stable, so no
// copy happens until the message is complete.
Split_Buffer :: struct {
	active: bool,
	from:   net.Endpoint,
	id:     u16,
	count:  u32,
	have:   u32,
	frags:  [MAX_FRAGMENTS][]byte,
}

Reassembly :: struct {
	splits: [MAX_SPLITS]Split_Buffer,
}

main :: proc() {
	dgrams := new(UDP_Datagram_Store)
	defer free(dgrams)
	msgs := new(RakNet_Message_Store)
	defer free(msgs)
	reasm := new(Reassembly)
	defer free(reasm)

	args := os.args
	err: Error
	if len(args) > 1 {
		err = replay(dgrams, msgs, reasm, args[1])
	} else {
		err = net_listen(dgrams, msgs, reasm)
	}
	if err != nil {
		fmt.eprintfln("caleb_raknet exited with error -> %v", err)
	}
}

net_listen :: proc(dgrams: ^UDP_Datagram_Store, msgs: ^RakNet_Message_Store, reasm: ^Reassembly) -> Error {
	bind_addr := net.parse_address(LISTEN_HOST)
	sock := net.make_bound_udp_socket(bind_addr, LISTEN_PORT) or_return
	defer net.close(sock)

	log := open_log() or_return
	defer os.close(log)

	scratch_backing := make([]byte, MAX_UDP_SIZE * 4 + 512)
	defer delete(scratch_backing)
	scratch_arena: mem.Arena
	mem.arena_init(&scratch_arena, scratch_backing)
	scratch := mem.arena_allocator(&scratch_arena)

	fmt.printfln("caleb_raknet listening on %s:%d", LISTEN_HOST, LISTEN_PORT)
	buf: [MAX_UDP_SIZE]byte
	for {
		n, remote := net.recv_udp(sock, buf[:]) or_continue
		if n <= 0 do continue
		now := time.now()
		if !udp_datagram_push(dgrams, remote, now, buf[:n]) {
			fmt.eprintfln("datagram store full, dropping %d bytes", n)
			continue
		}
		log_datagram(log, scratch, remote, now, buf[:n])
		process_udp_datagram(dgrams, msgs, reasm, dgrams.count - 1)
		// fmt.printfln("stored %d bytes from %v (datagrams %d, messages %d)", n, remote, dgrams.count, msgs.count)
	}
	return nil
}

open_log :: proc() -> (^os.File, os.Error) {
	stamp_backing: [64]byte
	arena: mem.Arena
	mem.arena_init(&arena, stamp_backing[:])
	stamp, _ := time.time_to_rfc3339(time.now(), include_nanos = false, allocator = mem.arena_allocator(&arena))

	name_backing: [128]byte
	b := strings.builder_from_bytes(name_backing[:])
	fmt.sbprintf(&b, "caleb-raknet-%s.jsonl", stamp)
	return os.open(strings.to_string(b), {.Write, .Create, .Append})
}

udp_datagram_push :: proc(s: ^UDP_Datagram_Store, from: net.Endpoint, recv_time: time.Time, data: []byte) -> bool {
	if s.count >= MAX_UDP_DATAGRAMS do return false
	start := pool_end(s.starts[:], s.lengths[:], s.count)
	if start + len(data) > BYTE_POOL_SIZE do return false
	i := s.count
	copy(s.pool[start:][:len(data)], data)
	s.froms[i] = from
	s.recv_times[i] = recv_time
	s.starts[i] = start
	s.lengths[i] = len(data)
	s.count = i + 1
	return true
}

pool_end :: proc(starts, lengths: []int, count: int) -> int {
	if count == 0 do return 0
	return starts[count - 1] + lengths[count - 1]
}

log_datagram :: proc(log: ^os.File, scratch: mem.Allocator, from: net.Endpoint, recv_time: time.Time, bytes: []byte) {
	if log == nil do return
	free_all(scratch)

	rec: Jsonl_Record
	rec.t, _ = time.time_to_rfc3339(recv_time, allocator = scratch)
	rec.from = net.endpoint_to_string(from, scratch)
	rec.len = len(bytes)
	rec.hex = string(hex.encode(bytes, scratch))

	b := strings.builder_make_len_cap(0, MAX_UDP_SIZE * 2 + 256, scratch)
	opt: json.Marshal_Options
	if json.marshal_to_builder(&b, rec, &opt) != nil do return
	strings.write_byte(&b, '\n')

	os.write(log, transmute([]byte)strings.to_string(b))
}

replay :: proc(dgrams: ^UDP_Datagram_Store, msgs: ^RakNet_Message_Store, reasm: ^Reassembly, path: string) -> Error {
	data := os.read_entire_file_from_path(path, context.allocator) or_return
	defer delete(data)

	line_backing: [MAX_UDP_SIZE * 2 + 256]byte
	arena: mem.Arena
	mem.arena_init(&arena, line_backing[:])
	line_alloc := mem.arena_allocator(&arena)

	fmt.printfln("caleb_raknet replaying %s", path)
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if len(line) == 0 do continue
		free_all(line_alloc)

		rec: Jsonl_Record
		if json.unmarshal_string(line, &rec, allocator = line_alloc) != nil do continue

		decoded, ok := hex.decode(transmute([]byte)rec.hex, line_alloc)
		if !ok do continue

		from, _ := net.parse_endpoint(rec.from)
		recv_time, _ := time.rfc3339_to_time_utc(rec.t)
		if !udp_datagram_push(dgrams, from, recv_time, decoded) {
			fmt.eprintfln("datagram store full, stopping at %d datagrams", dgrams.count)
			break
		}
		process_udp_datagram(dgrams, msgs, reasm, dgrams.count - 1)
		// fmt.printfln("ingested %d bytes from %v (datagrams %d, messages %d)", len(decoded), from, dgrams.count, msgs.count)
	}
	print_all_messages(msgs)
	return nil
}

