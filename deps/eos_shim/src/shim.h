// shim.h -- shared infrastructure for the EOS proxy/shim DLL.
//
// This is a thin man-in-the-middle ("proxy DLL") that the game loads in place of
// the genuine EOSSDK-Win64-Shipping.dll. Most exports are zero-code loader
// forwards (see eos_shim.def); a small hooked set is implemented in
// trampolines_*.cpp to LOG calls and WRAP async delegates so we can observe the
// EOS lobby/connect control plane during an online join -- the blind spot the
// RakNet pcap reconciliation could not see into.
//
// It is purely observational: it forwards every call to the real SDK unchanged.
#pragma once

#include <cstdint>
#include <string>

#define EOS_BUILD_DLL 1
#include "eos_sdk/eos_common.h"
#include "eos_sdk/eos_init.h"
#include "eos_sdk/eos_connect.h"
#include "eos_sdk/eos_lobby.h"
#include "eos_sdk/eos_p2p.h"

// ---- real DLL access ---------------------------------------------------------
// Handle to the renamed genuine SDK (EOSSDK-Win64-Shipping.orig.dll).
void* shim_real_module();

// Resolve a symbol from the real SDK (cached by the caller via REAL()).
void* shim_resolve(const char* name);

// Cache + fetch a typed pointer to a real-SDK function exactly once.
#define REAL(fn) \
    ([]() -> decltype(&fn) { \
        static decltype(&fn) p = reinterpret_cast<decltype(&fn)>(shim_resolve(#fn)); \
        return p; \
    }())

// ---- logging -----------------------------------------------------------------
// Append one JSON object (one line) to the shim log. Thread-safe.
// `fields` is the already-formatted JSON body WITHOUT the surrounding braces,
// e.g.  shim_log("EOS_Lobby_DestroyLobby", "\"lobby\":\"abc\"");
void shim_log(const char* event, const std::string& fields);

// Convenience: JSON-escape a C string (handles null -> "null").
std::string shim_jstr(const char* s);

// Stringify an EOS_ProductUserId via the real SDK's ToString (or "null").
std::string shim_puid(EOS_ProductUserId id);

// Stringify an EOS_EResult via the real SDK's EOS_EResult_ToString.
std::string shim_result(EOS_EResult r);
