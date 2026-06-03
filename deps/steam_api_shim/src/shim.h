// shim.h -- shared infrastructure for the steam_api64 proxy/shim DLL.
//
// A thin man-in-the-middle ("proxy DLL") that the game loads in place of the
// genuine steam_api64.dll. The game resolves Steamworks flat-API functions
// dynamically (LoadLibrary("steam_api64.dll") + GetProcAddress), so MOST of our
// exports are zero-code loader FORWARDS to the renamed genuine DLL
// (steam_api64_real.dll, see generate_def.sh); a small HOOKED set is implemented
// in trampolines.cpp to LOG the high-value auth/identity calls (the blind spot
// our pcap + winhttp taps can't see: the Steam side of "config C").
//
// Purely observational: every call forwards to the real Steam API unchanged.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

// ---- real DLL access --------------------------------------------------------
// Handle to the renamed genuine Steam API (steam_api64_real.dll).
void* shim_real_module();

// Resolve a symbol from the real DLL (cached by the caller via REAL()).
void* shim_resolve(const char* name);

// Cache + fetch a typed pointer to a real-DLL function exactly once. Uses the
// function's own declared signature for the cast (declare the prototype first).
#define REAL(fn) \
    ([]() -> decltype(&fn) { \
        static decltype(&fn) p = reinterpret_cast<decltype(&fn)>(shim_resolve(#fn)); \
        return p; \
    }())

// ---- logging ----------------------------------------------------------------
// Append one JSON object (one line) to the shim log. Thread-safe.
// `fields` is the already-formatted JSON body WITHOUT the surrounding braces.
void shim_log(const char* event, const std::string& fields);

// JSON-escape a C string (handles null -> "null").
std::string shim_jstr(const char* s);

// Hex-encode a byte buffer into a JSON string ("null" if data is null). Used for
// auth ticket blobs.
std::string shim_jhex(const void* data, size_t len);

// ---- ISteamMatchmaking vtable tap (matchmaking.cpp) -------------------------
// Hot-patch the SteamMatchMaking009 interface vtable with logging thunks so the
// Steam lobby control plane (SetLobbyData/GetLobbyData/partyDataToken/member
// data) is observable. Passive: thunks call the original and return unchanged.
// Idempotent (patches the shared class vtable once). `iface` is the interface
// pointer returned by SteamInternal_FindOrCreateUserInterface.
void shim_hook_matchmaking(void* iface);
