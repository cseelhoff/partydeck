// shim.h -- shared infrastructure for the winhttp proxy/shim DLL.
//
// This is a thin man-in-the-middle ("proxy DLL") that the game loads in place of
// the builtin winhttp.dll (via WINEDLLOVERRIDES=winhttp=n,b). Most exports are
// zero-code loader forwards (see winhttp_shim.def) to the renamed builtin
// (winhttp_real.dll); a small HOOKED set is implemented in trampolines.cpp.
//
// Purpose: STEER the game's HTTPS to a local plain-HTTP backend (server.py) with
// NO TLS / NO cert / NO CA-in-prefix. It rewrites WinHttpConnect for our
// federation hosts (dt-live*) to 127.0.0.1:<port> and clears WINHTTP_FLAG_SECURE
// on those requests. Every other call forwards to the real winhttp unchanged.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>

// ---- real DLL access --------------------------------------------------------
// Handle to the renamed builtin winhttp (winhttp_real.dll).
void* shim_real_module();

// Resolve a symbol from the real DLL (cached by the caller via REAL()).
void* shim_resolve(const char* name);

// Cache + fetch a typed pointer to a real-DLL function exactly once.
#define REAL(fn) \
    ([]() -> decltype(&fn) { \
        static decltype(&fn) p = reinterpret_cast<decltype(&fn)>(shim_resolve(#fn)); \
        return p; \
    }())

// ---- logging ----------------------------------------------------------------
// Append one JSON object (one line) to the shim log. Thread-safe.
void shim_log(const char* event, const std::string& fields);

// JSON-escape a C string (handles null -> "null").
std::string shim_jstr(const char* s);
// JSON-escape a wide string (UTF-16 -> UTF-8-ish, null -> "null").
std::string shim_jwstr(const wchar_t* s);

// ---- config (read once from env) --------------------------------------------
struct ShimConfig {
    std::wstring target_host;            // default L"127.0.0.1"
    int          target_port;           // default 8080 (plain HTTP)
    // lowercase host suffixes to redirect (default dt-live*.passtechgames.com)
    // matched case-insensitively against the WinHttpConnect server name.
    std::vector<std::wstring> redirect_hosts;
    // Also redirect ANY 127.0.0.0/8 loopback IP literal (e.g. the stale
    // Stormancer scene endpoint 127.1.33.7 the game connects to) to the target
    // backend. Default true; disable with WINHTTP_SHIM_REDIRECT_LOOPBACK=0.
    bool         redirect_loopback;
};
const ShimConfig& shim_config();

// True if `server_name` (from WinHttpConnect) should be redirected.
bool shim_should_redirect(const wchar_t* server_name);

// True if `server_name` is a 127.0.0.0/8 loopback IPv4 literal (e.g. 127.1.33.7)
// that is NOT already the shim's own target backend (host+port).
bool shim_is_loopback_literal(const wchar_t* server_name, INTERNET_PORT port);

// ---- redirected-handle tracking ---------------------------------------------
// Record/test/erase HINTERNET connect handles we rewrote, so WinHttpOpenRequest
// knows to clear WINHTTP_FLAG_SECURE for them.
void  shim_mark_redirected(HINTERNET h);
bool  shim_is_redirected(HINTERNET h);
void  shim_clear_redirected(HINTERNET h);
