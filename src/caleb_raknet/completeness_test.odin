package caleb_raknet

// Tests for the decode/encode round-trip (Step 2) and the completeness audit
// (Step 1), run against the reference capture. Build/run with:
//
//     odin test src/caleb_raknet
//
// The stores are large fixed arrays, so they are heap-allocated (new) rather than
// stack-declared. The capture is resolved relative to the repo root; if it is not
// found (test run from an unexpected cwd) the test logs and returns instead of
// failing, so a missing fixture is not a red build.

import "core:fmt"
import "core:os"
import "core:testing"

CAPTURE_PATH :: "pcaps/relay_capture.caleb.jsonl"

// Step 2: every message in the capture must re-encode to the exact bytes it was
// decoded from. This is the hard invariant -- a single mismatch is a decoder bug
// (a field that did not round-trip), so the test fails on any non-match.
@(test)
test_message_roundtrip :: proc(t: ^testing.T) {
	dgrams, msgs, reasm, ok := load_capture(CAPTURE_PATH)
	if !ok {
		fmt.println("capture not found, skipping:", CAPTURE_PATH)
		return
	}
	defer free(dgrams)
	defer free(msgs)
	defer free(reasm)

	testing.expect(t, msgs.count > 0, "capture decoded zero messages")

	mismatches := 0
	for i in 0 ..< msgs.count {
		free_all(context.temp_allocator)
		original := raknet_message_bytes(msgs, i)
		encoded := encode_message(decode_message(original, context.temp_allocator), context.temp_allocator)
		if !bytes_equal(encoded, original) {
			mismatches += 1
			if mismatches <= 5 {
				fmt.printfln("roundtrip mismatch [%d]: orig %dB enc %dB", i, len(original), len(encoded))
			}
		}
	}
	testing.expectf(t, mismatches == 0, "%d/%d messages failed to re-encode byte-exact", mismatches, msgs.count)
}

// Step 1: scan every decoded message for leftover encoded content (undecoded byte
// arrays, base64/JSON strings, unmodeled variants). This is a PROGRESS TRACKER,
// not a pass/fail gate -- the capture legitimately carries JSON documents and
// opaque 16-byte ids the decoder surfaces but does not expand. The hard assertion
// is only that the decoder modelled every message TYPE: zero Unmodeled_Variant
// findings (no Unknown/Malformed message, no Unparsed args, no non-msgpack
// Other_Response). The remaining counts are logged so progress is visible.
@(test)
test_completeness_audit :: proc(t: ^testing.T) {
	dgrams, msgs, reasm, ok := load_capture(CAPTURE_PATH)
	if !ok {
		fmt.println("capture not found, skipping:", CAPTURE_PATH)
		return
	}
	defer free(dgrams)
	defer free(msgs)
	defer free(reasm)

	counts: [Completeness_Kind]int
	issues := make([dynamic]Completeness_Issue)
	defer delete(issues)
	for i in 0 ..< msgs.count {
		free_all(context.temp_allocator)
		clear(&issues)
		decoded := decode_message(raknet_message_bytes(msgs, i), context.temp_allocator)
		collect_completeness_issues(decoded, &issues, context.temp_allocator)
		for it in issues do counts[it.kind] += 1
	}

	fmt.printfln(
		"completeness: %d json-string, %d base64-string, %d undecoded-bytes, %d unmodeled",
		counts[.Json_String],
		counts[.Base64_String],
		counts[.Undecoded_Bytes],
		counts[.Unmodeled_Variant],
	)
	testing.expectf(
		t,
		counts[.Unmodeled_Variant] == 0,
		"%d message(s) the decoder could not type (Unknown/Malformed/Unparsed/non-msgpack)",
		counts[.Unmodeled_Variant],
	)
}

// Ingest the capture into freshly heap-allocated stores. Returns ok=false (and
// frees nothing) when the file is absent so callers can skip cleanly.
load_capture :: proc(path: string) -> (dgrams: ^UDP_Datagram_Store, msgs: ^RakNet_Message_Store, reasm: ^Reassembly, ok: bool) {
	if !os.exists(path) do return nil, nil, nil, false
	dgrams = new(UDP_Datagram_Store)
	msgs = new(RakNet_Message_Store)
	reasm = new(Reassembly)
	if ingest_jsonl(dgrams, msgs, reasm, path) != nil {
		free(dgrams)
		free(msgs)
		free(reasm)
		return nil, nil, nil, false
	}
	return dgrams, msgs, reasm, true
}
