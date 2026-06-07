package caleb_raknet

// Step 1 -- completeness audit: walk a Decoded_Message and report every place the
// decoder left content opaque. The project's rule is "nothing is dropped": a value
// is either decoded into a typed field or surfaced as an explicit not-decoded
// variant. This scanner makes that rule testable. It flags three kinds of remnant:
//
//   * undecoded byte arrays  -- a msgpack .Bin (or non-timestamp .Ext) still sitting
//                               as raw bytes inside a decoded tree, or a "give up"
//                               variant that kept only a raw []byte (Unparsed_Args,
//                               Other_Response on a non-msgpack blob, Unknown/
//                               Malformed messages).
//   * base64-encoded strings -- a string field whose contents are base64 of JSON /
//                               text that was never expanded (is_*/try_base64_text
//                               from scene_message.odin do the recognizing).
//   * json-encoded strings   -- a string field that is itself a JSON object/array
//                               literal still carried as one quoted blob.
//
// Deliberately NOT flagged: render-expanded tokens that ARE decoded at display time
// (a Session_Token JWT, expanded by mp_write_jwt) and inherently-opaque cryptographic
// material (a connection token's signature segment, a UserData bin). Those are not
// "undecoded" -- they are decoded as far as is meaningful.
//
// The scanner is a free function over the same tagged unions, collecting findings
// into a caller-owned slice (no per-node allocation, SoA-friendly). The @(test)
// harness below ingests the reference capture and asserts the count it expects.

import "core:fmt"
import "core:strings"

// What kind of leftover encoded content a finding represents.
Completeness_Kind :: enum u8 {
	Undecoded_Bytes, // a raw []byte / msgpack bin/ext never interpreted
	Base64_String, // a string that is base64 of JSON/text, not expanded
	Json_String, // a string that is a JSON object/array literal, not parsed
	Unmodeled_Variant, // a whole message/args/response the decoder could not type
}

// One leftover found in a decoded message. `field` is a human path to the field
// ("System_Request.args"/"Scene_Message.values[2]" etc.); `detail` adds the size
// or a short preview. Strings alias the source / temp text -- valid only while the
// decode's allocation lives.
Completeness_Issue :: struct {
	kind:   Completeness_Kind,
	field:  string,
	detail: string,
}

// Append every leftover encoded remnant in `message` to `sink`. Pure traversal --
// it reuses the same predicates the renderer uses (is_json_like / try_base64_text /
// is_printable_text) so "decoded for display" and "counts as decoded here" stay in
// lockstep. `allocator` is used for any sub-decode the scan must perform (e.g.
// parsing a connection token to confirm it decodes).
collect_completeness_issues :: proc(
	message: Decoded_Message,
	sink: ^[dynamic]Completeness_Issue,
	allocator := context.allocator,
) {
	switch f in message {
	case Connected_Ping, Connected_Pong, Connection_Request, Connection_Request_Accepted,
	     New_Incoming_Connection, Disconnection_Notification, Response_Complete,
	     Connection_Result:
	// Fully fixed-width frames: every byte maps to a scalar field. Nothing encoded
	// can remain, so there is nothing to scan.

	case System_Request:
		scan_system_request_args(f.args, sink, allocator)

	case Response_Msg:
		scan_response_data(f.data, sink, allocator)

	case Response_Error:
		// The error payload is kept as a raw msgpack tree -- scan it like any tree.
		scan_msgpack(f.data, "Response_Error.data", sink)

	case Scene_Message:
		scan_msgpack_seq(f.decoded.values, "Scene_Message.values", sink)

	case Unknown_Message:
		append(sink, Completeness_Issue {
			kind = .Unmodeled_Variant,
			field = "Unknown_Message",
			detail = fmt.tprintf("id=0x%02x body=%dB", f.id, len(f.body)),
		})

	case Malformed_Message:
		append(sink, Completeness_Issue {
			kind = .Unmodeled_Variant,
			field = "Malformed_Message",
			detail = fmt.tprintf("id=0x%02x got=%dB want=%dB", f.id, f.body_len, f.expected),
		})
	}
}

// --- per-variant scanners ---------------------------------------------------

scan_system_request_args :: proc(
	args: System_Request_Args,
	sink: ^[dynamic]Completeness_Issue,
	allocator := context.allocator,
) {
	switch a in args {
	case Connect_To_Scene_Args:
		scan_token(a.token, "Connect_To_Scene.Token", sink, allocator)
		scan_routes(a.routes, "Connect_To_Scene.Routes", sink)
		scan_connect_to_scene_args(a, sink)
	case Get_Scene_Infos_Args:
		scan_connection_token(a.token, "Get_Scene_Infos.Token", sink)
	case Set_Metadata_Args:
		scan_set_metadata_args(a, sink)
	case Scene_Ready_Args, Disconnect_From_Scene_Args, Ping_Args, No_Args:
	// Pure scalar / empty args -- nothing encoded remains.
	case Unparsed_Args:
		append(sink, Completeness_Issue {
			kind = .Unmodeled_Variant,
			field = "System_Request.args",
			detail = fmt.tprintf("Unparsed_Args %dB", len(a.raw)),
		})
	}
}

scan_response_data :: proc(
	data: Response_Data,
	sink: ^[dynamic]Completeness_Issue,
	allocator := context.allocator,
) {
	switch d in data {
	case Scene_Infos:
		scan_string(d.scene_id, "Scene_Infos.SceneId", sink)
		scan_scene_infos_metadata(d, sink)
		scan_routes(d.routes, "Scene_Infos.Routes", sink)
	case Scene_Connection_Result:
	// scene_handle + name->handle mappings are all scalars/short names.
	case Bool_Result:
	// a single bool.
	case Session_Token:
		// jwt is decoded for display (mp_write_jwt); session_id is an opaque id.
		// Neither is a leftover *encoding* this layer failed to handle.
	case Ping_Response:
	// two clocks.
	case Other_Response:
		// The catch-all reply: a msgpack tree we did not match a shape for, or a
		// non-msgpack blob. Scan the tree; flag a non-msgpack blob as undecoded bytes.
		if d.data.ok {
			scan_msgpack(d.data, "Other_Response.data", sink)
		} else if len(d.data.raw) > 0 {
			append(sink, Completeness_Issue {
				kind = .Undecoded_Bytes,
				field = "Other_Response.data",
				detail = fmt.tprintf("%dB non-msgpack", len(d.data.raw)),
			})
		}
	}
}

// A Stormancer connection token must decode to a ConnectionData map. Parse it to
// confirm; flag only a parse failure. The signature segment and UserData bin are
// intentionally left opaque (cryptographic), so a clean parse is "complete" even
// though those bytes are never interpreted.
scan_token :: proc(
	token: string,
	field: string,
	sink: ^[dynamic]Completeness_Issue,
	allocator := context.allocator,
) {
	if len(token) == 0 do return
	t := parse_connection_token(token, allocator)
	if t.ok do return
	append(sink, Completeness_Issue {
		kind = .Base64_String,
		field = field,
		detail = fmt.tprintf("token %dB did not decode", len(token)),
	})
}

scan_connection_token :: proc(
	token: Connection_Token,
	field: string,
	sink: ^[dynamic]Completeness_Issue,
) {
	if len(token.raw) == 0 || token.ok do return
	append(sink, Completeness_Issue {
		kind = .Base64_String,
		field = field,
		detail = fmt.tprintf("token %dB did not decode", len(token.raw)),
	})
}

scan_metadata :: proc(meta: []Metadata_Entry, field: string, sink: ^[dynamic]Completeness_Issue) {
	for e in meta {
		scan_string(e.value, field, sink)
	}
}

scan_scene_infos_metadata :: proc(d: Scene_Infos, sink: ^[dynamic]Completeness_Issue) {
	scan_string(d.account_id, "Scene_Infos.Metadata.accountId", sink)
	scan_string(d.app_id, "Scene_Infos.Metadata.appId", sink)
	scan_string(d.darktales_gamesession, "Scene_Infos.Metadata.darktales.gamesession", sink)
	scan_string(d.stormancer_friends, "Scene_Infos.Metadata.stormancer.friends", sink)
	scan_string(d.stormancer_gamesession, "Scene_Infos.Metadata.stormancer.gamesession", sink)
	scan_string(d.stormancer_game_version, "Scene_Infos.Metadata.stormancer.gameVersion", sink)
	scan_string(d.stormancer_party, "Scene_Infos.Metadata.stormancer.party", sink)
	scan_string(d.stormancer_partymanagement, "Scene_Infos.Metadata.stormancer.partymanagement", sink)
	scan_string(d.stormancer_party_merging, "Scene_Infos.Metadata.stormancer.partyMerging", sink)
	scan_string(d.stormancer_party_revision, "Scene_Infos.Metadata.stormancer.party.revision", sink)
	scan_string(d.stormancer_plugins_gamefinder, "Scene_Infos.Metadata.stormancer.plugins.gamefinder", sink)
	scan_string(
		d.stormancer_plugins_gamefinder_protocol,
		"Scene_Infos.Metadata.stormancer.plugins.gamefinder.protocol",
		sink,
	)
	scan_string(d.stormancer_plugins_nintendo, "Scene_Infos.Metadata.stormancer.plugins.nintendo", sink)
	scan_string(d.stormancer_plugins_psn, "Scene_Infos.Metadata.stormancer.plugins.psn", sink)
	scan_string(d.stormancer_plugins_rpc, "Scene_Infos.Metadata.stormancer.plugins.rpc", sink)
	scan_string(d.stormancer_plugins_steam, "Scene_Infos.Metadata.stormancer.plugins.steam", sink)
	scan_string(
		d.stormancer_plugins_xbl_use_modern_gamertag,
		"Scene_Infos.Metadata.Stormancer.plugins.XBLServices.useModernGamerTag",
		sink,
	)
}

scan_set_metadata_args :: proc(a: Set_Metadata_Args, sink: ^[dynamic]Completeness_Issue) {
	scan_string(a.stormancer_party, "Set_Metadata.Metadata.stormancer.party", sink)
	scan_string(a.version, "Set_Metadata.Metadata.version", sink)
	scan_string(a.server_name, "Set_Metadata.Metadata.server.name", sink)
	scan_string(a.timeout, "Set_Metadata.Metadata.timeout", sink)
	scan_string(a.server_version, "Set_Metadata.Metadata.server.version", sink)
	scan_string(a.stormancer_party_plugin, "Set_Metadata.Metadata.stormancer.party.plugin", sink)
	scan_string(a.stormancer_partymanagement, "Set_Metadata.Metadata.stormancer.partymanagement", sink)
	scan_string(
		a.stormancer_plugins_gamefinder_protocol,
		"Set_Metadata.Metadata.stormancer.plugins.gamefinder.protocol",
		sink,
	)
	scan_string(a.plugins, "Set_Metadata.Metadata.plugins", sink)
	scan_string(a.serializers, "Set_Metadata.Metadata.serializers", sink)
	scan_string(a.transport, "Set_Metadata.Metadata.transport", sink)
	scan_string(a.platform, "Set_Metadata.Metadata.platform", sink)
	scan_string(a.protocol, "Set_Metadata.Metadata.protocol", sink)
	scan_string(a.connection_type, "Set_Metadata.Metadata.type", sink)
	scan_string(a.serializer, "Set_Metadata.Metadata.serializer", sink)
}

scan_connect_to_scene_args :: proc(a: Connect_To_Scene_Args, sink: ^[dynamic]Completeness_Issue) {
	scan_string(a.scene_stormancer_plugins_rpc, "Connect_To_Scene.SceneMetadata.stormancer.plugins.rpc", sink)
	scan_string(a.scene_stormancer_plugins_nintendo, "Connect_To_Scene.SceneMetadata.stormancer.plugins.nintendo", sink)
	scan_string(
		a.scene_stormancer_plugins_xbl_use_modern_gamertag,
		"Connect_To_Scene.SceneMetadata.Stormancer.plugins.XBLServices.useModernGamerTag",
		sink,
	)
	scan_string(a.scene_stormancer_plugins_steam, "Connect_To_Scene.SceneMetadata.stormancer.plugins.steam", sink)
	scan_string(a.scene_app_id, "Connect_To_Scene.SceneMetadata.appId", sink)
	scan_string(a.scene_account_id, "Connect_To_Scene.SceneMetadata.accountId", sink)
	scan_string(a.scene_stormancer_game_version, "Connect_To_Scene.SceneMetadata.stormancer.gameVersion", sink)
	scan_string(a.scene_stormancer_plugins_psn, "Connect_To_Scene.SceneMetadata.stormancer.plugins.psn", sink)
	scan_string(a.connection_stormancer_party, "Connect_To_Scene.ConnectionMetadata.stormancer.party", sink)
	scan_string(a.connection_version, "Connect_To_Scene.ConnectionMetadata.version", sink)
	scan_string(a.connection_server_name, "Connect_To_Scene.ConnectionMetadata.server.name", sink)
	scan_string(a.connection_timeout, "Connect_To_Scene.ConnectionMetadata.timeout", sink)
	scan_string(a.connection_server_version, "Connect_To_Scene.ConnectionMetadata.server.version", sink)
	scan_string(
		a.connection_stormancer_party_plugin,
		"Connect_To_Scene.ConnectionMetadata.stormancer.party.plugin",
		sink,
	)
	scan_string(
		a.connection_stormancer_partymanagement,
		"Connect_To_Scene.ConnectionMetadata.stormancer.partymanagement",
		sink,
	)
	scan_string(
		a.connection_stormancer_plugins_gamefinder_protocol,
		"Connect_To_Scene.ConnectionMetadata.stormancer.plugins.gamefinder.protocol",
		sink,
	)
	scan_string(a.connection_plugins, "Connect_To_Scene.ConnectionMetadata.plugins", sink)
	scan_string(a.connection_serializers, "Connect_To_Scene.ConnectionMetadata.serializers", sink)
	scan_string(a.connection_transport, "Connect_To_Scene.ConnectionMetadata.transport", sink)
	scan_string(a.connection_platform, "Connect_To_Scene.ConnectionMetadata.platform", sink)
	scan_string(a.connection_protocol, "Connect_To_Scene.ConnectionMetadata.protocol", sink)
	scan_string(a.connection_type, "Connect_To_Scene.ConnectionMetadata.type", sink)
	scan_string(a.connection_serializer, "Connect_To_Scene.ConnectionMetadata.serializer", sink)
}

scan_routes :: proc(routes: Routes, field: string, sink: ^[dynamic]Completeness_Issue) {
	for route_name in routes {
		scan_string(route_name, field, sink)
	}
}

// --- generic msgpack-tree scan ----------------------------------------------

// Scan a single decoded msgpack value (root at nodes[0]).
scan_msgpack :: proc(m: Msgpack, field: string, sink: ^[dynamic]Completeness_Issue) {
	if !m.ok || len(m.nodes) == 0 do return
	scan_msgpack_nodes(m.nodes, field, sink)
}

// Scan a forest of concatenated msgpack values (a scene-message body).
scan_msgpack_seq :: proc(seq: Msgpack_Seq, field: string, sink: ^[dynamic]Completeness_Issue) {
	if len(seq.nodes) == 0 do return
	scan_msgpack_nodes(seq.nodes, field, sink)
}

// Walk every node in a pool once (pre-order layout means a flat scan reaches all
// children). Flags each .Bin/.Ext that still holds raw bytes and each .Str that is
// still an encoded token. Pre-order DFS is contiguous, so a single linear pass over
// the pool visits the whole forest -- no recursion needed.
scan_msgpack_nodes :: proc(nodes: []Msgpack_Node, field: string, sink: ^[dynamic]Completeness_Issue) {
	for n, i in nodes {
		#partial switch n.kind {
		case .Str:
			scan_string_at(n.str, field, i, sink)
		case .Bin:
			// A bin that is printable text (JSON/base64/plain) is content the renderer
			// expands -- treat a still-encoded one as a finding; an opaque binary blob
			// (session id, P2P token) is genuinely undecodable, so flag it as raw bytes.
			if len(n.bin) == 0 do continue
			if is_printable_text(n.bin) {
				scan_string_at(string(n.bin), field, i, sink)
			} else {
				append(sink, Completeness_Issue {
					kind = .Undecoded_Bytes,
					field = field,
					detail = fmt.tprintf("bin[%d] %dB", i, len(n.bin)),
				})
			}
		case .Ext:
			// timestamp ext (-1) is decoded to seconds; any other ext is opaque bytes.
			if n.ext_type == -1 do continue
			append(sink, Completeness_Issue {
				kind = .Undecoded_Bytes,
				field = field,
				detail = fmt.tprintf("ext[%d] type=%d %dB", i, n.ext_type, len(n.bin)),
			})
		}
	}
}

// --- string remnant test ----------------------------------------------------

scan_string :: proc(s: string, field: string, sink: ^[dynamic]Completeness_Issue) {
	scan_string_at(s, field, -1, sink)
}

// Classify one string: JSON literal, base64-of-text, or fully decoded. `node`>=0
// adds the node index to the detail (for tree scans).
scan_string_at :: proc(s: string, field: string, node: int, sink: ^[dynamic]Completeness_Issue) {
	if is_json_like(s) {
		append(sink, Completeness_Issue {
			kind = .Json_String,
			field = field,
			detail = string_detail("json", s, node),
		})
		return
	}
	if _, ok := try_base64_text(s); ok {
		append(sink, Completeness_Issue {
			kind = .Base64_String,
			field = field,
			detail = string_detail("b64", s, node),
		})
	}
}

string_detail :: proc(tag: string, s: string, node: int) -> string {
	preview := s
	if len(preview) > 32 do preview = preview[:32]
	if node >= 0 do return fmt.tprintf("%s[%d] %q", tag, node, preview)
	return fmt.tprintf("%s %q", tag, preview)
}

// --- report -----------------------------------------------------------------

// Print a grouped summary of the findings (used by the replay path and the test on
// failure) so a non-zero count is actionable, not just a number.
print_completeness_report :: proc(issues: []Completeness_Issue) {
	if len(issues) == 0 {
		fmt.println("=== completeness: clean (no undecoded bytes / encoded strings remain) ===")
		return
	}
	fmt.printfln("=== completeness: %d leftover(s) ===", len(issues))
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	for it in issues {
		strings.builder_reset(&sb)
		fmt.sbprintf(&sb, "  [%v] %s -- %s", it.kind, it.field, it.detail)
		fmt.println(strings.to_string(sb))
	}
}
