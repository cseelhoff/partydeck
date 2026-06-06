package caleb_raknet

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"

dtlive_try_listen :: proc(bind_addr: net.Address, port: int) -> (net.TCP_Socket, bool) {
	sock, err := net.listen_tcp(net.Endpoint{address = bind_addr, port = port})
	if err != nil {
		fmt.eprintfln("dtlive HTTP disabled on %s:%d -> %v", LISTEN_HOST, port, err)
		return {}, false
	}
	fmt.printfln("dtlive HTTP listening on %s:%d (plain)", LISTEN_HOST, port)
	return sock, true
}

dtlive_handle_one :: proc(sock: net.TCP_Socket, allocator := context.allocator) {
	free_all(allocator)
	client, remote, err := net.accept_tcp(sock)
	if err != nil do return
	defer net.close(client)

	buf: [16 * 1024]byte
	n, recv_err := net.recv_tcp(client, buf[:])
	if recv_err != nil || n <= 0 do return
	req := string(buf[:n])
	path := http_request_path(req)
	body, content_type := dtlive_response_body(path, allocator)
	resp := fmt.aprintf(
		"HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\nServer: Kestrel\r\nCache-Control: no-cache\r\nx-version: 3\r\nConnection: close\r\n\r\n%s",
		content_type,
		len(body),
		body,
		allocator = allocator,
	)
	fmt.printfln("dtlive %s from %v -> %dB", path, remote, len(body))
	net.send_tcp(client, transmute([]byte)resp)
}

simple_dtlive_handle_one :: proc(sock: net.TCP_Socket, allocator := context.allocator) {
	free_all(allocator)
	client, remote, err := net.accept_tcp(sock)
	if err != nil do return
	defer net.close(client)

	buf: [16 * 1024]byte
	n, recv_err := net.recv_tcp(client, buf[:])
	if recv_err != nil || n <= 0 do return
	req := string(buf[:n])
	path := http_request_path(req)
	body, content_type := simple_dtlive_response_body(path, allocator)
	resp := fmt.aprintf(
		"HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\nServer: Kestrel\r\nCache-Control: no-cache\r\nx-version: 3\r\nConnection: close\r\n\r\n%s",
		content_type,
		len(body),
		body,
		allocator = allocator,
	)
	fmt.printfln("simple dtlive %s from %v -> %dB", path, remote, len(body))
	net.send_tcp(client, transmute([]byte)resp)
}

http_request_path :: proc(req: string) -> string {
	sp1 := strings.index_byte(req, ' ')
	if sp1 < 0 do return "/"
	rest := req[sp1 + 1:]
	sp2 := strings.index_byte(rest, ' ')
	path := rest
	if sp2 >= 0 do path = rest[:sp2]
	if scheme := strings.index(path, "://"); scheme >= 0 {
		after := path[scheme + 3:]
		if slash := strings.index_byte(after, '/'); slash >= 0 {
			path = after[slash:]
		} else {
			path = "/"
		}
	}
	if path == "" do return "/"
	return path
}

dtlive_response_body :: proc(path: string, allocator := context.allocator) -> (string, string) {
	if path == "/_federation" {
		return "{\"current\":{\"id\":\"passtech-live\",\"adminEndpoints\":[\"https://dt-live.passtechgames.com\"],\"endpoints\":[\"https://dt-live.passtechgames.com\"],\"tags\":[]},\"clusters\":[{\"id\":\"passtech-live\",\"adminEndpoints\":null,\"endpoints\":[\"https://dt-live.passtechgames.com\"],\"tags\":[]}]}",
			"application/json"
	}
	if string_has_suffix(path, "/token") {
		raknet_endpoint := env_string("RAKNET_ENDPOINT", DEFAULT_RAKNET_ENDPOINT, allocator)
		if env_truthy("RAKNET_RELAY") {
			if body, ok := dtlive_relay_token_json(path, raknet_endpoint, allocator); ok {
				return body, "application/json; charset=utf-8"
			}
		}
		return scene_token_json_endpoint("authenticator", raknet_endpoint, allocator),
			"application/json; charset=utf-8"
	}
	if path == "/" {
		return "{\"name\":\"dt-live-1\",\"version\":\"9.3.0.2\",\"reportedStatus\":\"Leader\",\"leader\":{\"uid\":\"5w0GiaMkGUuN+QnuOyHTKQ\",\"name\":\"dt-live-1\",\"endpoint\":\"dt-live.passtechgames.com:40243\",\"cluster\":\"passtech-live\"},\"cluster\":\"passtech-live\",\"logLastCommittedEntryId\":19,\"logLastEntryId\":19,\"logLastSnapshot\":null,\"state\":\"Running\",\"id\":\"5w0GiaMkGUuN+QnuOyHTKQ\"}",
			"application/json"
	}
	return `{}`, "application/json"
}

simple_dtlive_response_body :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	string,
	string,
) {
	if path == "/_federation" {
		return "{\"current\":{\"id\":\"passtech-live\",\"adminEndpoints\":[\"https://dt-live.passtechgames.com\"],\"endpoints\":[\"https://dt-live.passtechgames.com\"],\"tags\":[]},\"clusters\":[{\"id\":\"passtech-live\",\"adminEndpoints\":null,\"endpoints\":[\"https://dt-live.passtechgames.com\"],\"tags\":[]}]}",
			"application/json"
	}
	if string_has_suffix(path, "/token") {
		raknet_endpoint := env_string("RAKNET_ENDPOINT", SIMPLE_DEFAULT_RAKNET_ENDPOINT, allocator)
		return scene_token_json_endpoint("authenticator", raknet_endpoint, allocator),
			"application/json; charset=utf-8"
	}
	if path == "/" {
		return "{\"name\":\"dt-live-1\",\"version\":\"9.3.0.2\",\"reportedStatus\":\"Leader\",\"leader\":{\"uid\":\"5w0GiaMkGUuN+QnuOyHTKQ\",\"name\":\"dt-live-1\",\"endpoint\":\"dt-live.passtechgames.com:40243\",\"cluster\":\"passtech-live\"},\"cluster\":\"passtech-live\",\"logLastCommittedEntryId\":19,\"logLastEntryId\":19,\"logLastSnapshot\":null,\"state\":\"Running\",\"id\":\"5w0GiaMkGUuN+QnuOyHTKQ\"}",
			"application/json"
	}
	return `{}`, "application/json"
}

dtlive_relay_token_json :: proc(
	path, raknet_endpoint: string,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
	real_host := env_string("RELAY_REAL_HOST", DEFAULT_RELAY_REAL_HOST, allocator)
	fetch_path := path
	if fetch_path == "" || fetch_path[0] != '/' do fetch_path = REAL_AUTH_TOKEN_PATH
	url := fmt.aprintf("https://%s%s", real_host, fetch_path, allocator = allocator)
	command := []string {
		"curl",
		"-4",
		"-fsSL",
		"--max-time",
		"10",
		"-X",
		"POST",
		"-H",
		"Accept: application/json",
		"-H",
		"clientVersion: 1.05.00.05",
		"-H",
		"Content-Type: text/plain; charset=utf-8, application/msgpack",
		"-H",
		"devProduct: false",
		"-H",
		"platform: pc",
		"-H",
		"serverVersion: 2.0",
		"-H",
		"User-Agent: cpprestsdk/2.8.01",
		"-H",
		"x-version: 3",
		url,
	}
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{command = command}, allocator)
	if err != nil || !state.success || len(stdout) == 0 {
		fmt.eprintfln(
			"dtlive relay token fetch failed -> err=%v status=%d stderr=%s",
			err,
			state.exit_code,
			string(stderr),
		)
		return "", false
	}
	real_body := trim_ascii_space(string(stdout))
	if real_body == "" do return "", false
	if real_body[0] == '{' {
		if rewritten, ok := rewrite_raknet_endpoint(real_body, raknet_endpoint, allocator); ok {
			return rewritten, true
		}
		fmt.eprintfln(
			"dtlive relay token fetch returned JSON without endpoints.raknet; using local fallback",
		)
		return "", false
	}
	if real_body[0] != '"' {
		real_body = json_quote_ascii(real_body, allocator)
	}
	return relay_token_envelope_json(real_body, raknet_endpoint, allocator), true
}

relay_token_envelope_json :: proc(
	token_json, raknet_endpoint: string,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{"token":`)
	strings.write_string(&b, token_json)
	strings.write_string(&b, `,"endpoints":{"raknet":["`)
	strings.write_string(&b, raknet_endpoint)
	strings.write_string(
		&b,
		`"]},"encryption":{"algorithm":"aes256","mode":"GCM","key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","token":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}}`,
	)
	return strings.to_string(b)
}

rewrite_raknet_endpoint :: proc(
	body, raknet_endpoint: string,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
	needle := `"raknet":[`
	start := strings.index(body, needle)
	if start < 0 do return "", false
	array_start := start + len(needle)
	array_end := array_start
	in_string := false
	escaped := false
	for array_end < len(body) {
		ch := body[array_end]
		if escaped {
			escaped = false
		} else if ch == '\\' && in_string {
			escaped = true
		} else if ch == '"' {
			in_string = !in_string
		} else if ch == ']' && !in_string {
			break
		}
		array_end += 1
	}
	if array_end >= len(body) do return "", false
	b := strings.builder_make(allocator)
	strings.write_string(&b, body[:array_start])
	strings.write_string(&b, json_quote_ascii(raknet_endpoint, allocator))
	strings.write_string(&b, body[array_end:])
	return strings.to_string(b), true
}

trim_ascii_space :: proc(s: string) -> string {
	lo := 0
	hi := len(s)
	for lo < hi && is_ascii_space(s[lo]) do lo += 1
	for hi > lo && is_ascii_space(s[hi - 1]) do hi -= 1
	return s[lo:hi]
}

is_ascii_space :: proc(c: byte) -> bool {
	return c == ' ' || c == '\n' || c == '\r' || c == '\t'
}

json_quote_ascii :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '"')
	for c in s {
		if c == '"' || c == '\\' do strings.write_byte(&b, '\\')
		strings.write_rune(&b, c)
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

string_has_suffix :: proc(s, suffix: string) -> bool {
	return len(s) >= len(suffix) && s[len(s) - len(suffix):] == suffix
}