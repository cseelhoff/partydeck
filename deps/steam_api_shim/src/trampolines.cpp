// trampolines.cpp -- the HOOKED steam_api64 exports (observational tap).
//
// Five high-value Steamworks flat-API functions are intercepted to LOG the
// Steam-side identity/auth plane of the working online "config C": the SteamID,
// persona name, game language, and -- most importantly -- the auth tickets the
// game mints to authenticate to the passtech/nacon backends (the same tickets
// that ride the winhttp POST .../login/steam we already capture). Every other
// Steamworks symbol is a zero-code forward to steam_api64_real.dll.
//
// All hooks forward to the real implementation via REAL() and only observe.
#include "shim.h"

#include <cstdint>
#include <cstdio>
#include <cstring>

extern "C" {

// ---- minimal Steamworks flat-API prototypes (subset we hook) ----------------
// The interface "self" handle is opaque to us; treat as void*. HAuthTicket is
// uint32. Signatures match steam_api_flat.h.
uint64_t SteamAPI_ISteamUser_GetSteamID(void* self);
const char* SteamAPI_ISteamFriends_GetPersonaName(void* self);
const char* SteamAPI_ISteamApps_GetCurrentGameLanguage(void* self);
uint32_t SteamAPI_ISteamUser_GetAuthSessionTicket(void* self, void* pTicket,
                                                  int cbMaxTicket,
                                                  uint32_t* pcbTicket,
                                                  const void* pIdentity);
uint32_t SteamAPI_ISteamUser_GetAuthTicketForWebApi(void* self,
                                                    const char* pchIdentity);

// Interface-creation entry points. Ravenswatch resolves C++ vtable interfaces
// (SteamClient020 / SteamUser023 / SteamFriends017 / ...) through these, then
// calls methods via the vtable -- bypassing the flat wrappers above. Logging the
// REQUESTED version strings here records exactly which interface versions the
// online "config C" uses, so the offline goldberg emu can be made to expose the
// same set. (Capturing individual vtable method calls would require per-version
// vtable interception -- a separate, version-fragile follow-up.)
void* SteamInternal_CreateInterface(const char* ver);
void* SteamInternal_FindOrCreateUserInterface(int hSteamUser, const char* ver);
void* SteamInternal_FindOrCreateGameServerInterface(int hSteamUser,
                                                    const char* ver);

// ---- SteamInternal_CreateInterface ------------------------------------------
void* SteamInternal_CreateInterface(const char* ver) {
    auto real = REAL(SteamInternal_CreateInterface);
    if (!real) return nullptr;
    void* iface = real(ver);
    char buf[32];
    snprintf(buf, sizeof(buf), "%p", iface);
    shim_log("SteamInternal_CreateInterface",
             "\"version\":" + shim_jstr(ver) + ",\"iface\":\"" + buf + "\"");
    return iface;
}

// ---- SteamInternal_FindOrCreateUserInterface --------------------------------
void* SteamInternal_FindOrCreateUserInterface(int hSteamUser, const char* ver) {
    auto real = REAL(SteamInternal_FindOrCreateUserInterface);
    if (!real) return nullptr;
    void* iface = real(hSteamUser, ver);
    char buf[32];
    snprintf(buf, sizeof(buf), "%p", iface);
    shim_log("SteamInternal_FindOrCreateUserInterface",
             "\"hSteamUser\":" + std::to_string(hSteamUser) +
                 ",\"version\":" + shim_jstr(ver) + ",\"iface\":\"" + buf + "\"");
    // The lobby control plane rides this interface's vtable; tap it so we capture
    // SetLobbyData/GetLobbyData/partyDataToken etc. (the goldberg-emulated plane).
    if (ver && strncmp(ver, "SteamMatchMaking", 16) == 0) shim_hook_matchmaking(iface);
    return iface;
}

// ---- SteamInternal_FindOrCreateGameServerInterface --------------------------
void* SteamInternal_FindOrCreateGameServerInterface(int hSteamUser,
                                                    const char* ver) {
    auto real = REAL(SteamInternal_FindOrCreateGameServerInterface);
    if (!real) return nullptr;
    void* iface = real(hSteamUser, ver);
    char buf[32];
    snprintf(buf, sizeof(buf), "%p", iface);
    shim_log("SteamInternal_FindOrCreateGameServerInterface",
             "\"hSteamUser\":" + std::to_string(hSteamUser) +
                 ",\"version\":" + shim_jstr(ver) + ",\"iface\":\"" + buf + "\"");
    return iface;
}

// ---- ISteamUser::GetSteamID -------------------------------------------------
uint64_t SteamAPI_ISteamUser_GetSteamID(void* self) {
    auto real = REAL(SteamAPI_ISteamUser_GetSteamID);
    if (!real) return 0;
    uint64_t id = real(self);
    shim_log("ISteamUser_GetSteamID", "\"steamid\":\"" + std::to_string(id) + "\"");
    return id;
}

// ---- ISteamFriends::GetPersonaName ------------------------------------------
const char* SteamAPI_ISteamFriends_GetPersonaName(void* self) {
    auto real = REAL(SteamAPI_ISteamFriends_GetPersonaName);
    if (!real) return "";
    const char* name = real(self);
    shim_log("ISteamFriends_GetPersonaName", "\"name\":" + shim_jstr(name));
    return name;
}

// ---- ISteamApps::GetCurrentGameLanguage -------------------------------------
const char* SteamAPI_ISteamApps_GetCurrentGameLanguage(void* self) {
    auto real = REAL(SteamAPI_ISteamApps_GetCurrentGameLanguage);
    if (!real) return "";
    const char* lang = real(self);
    shim_log("ISteamApps_GetCurrentGameLanguage", "\"lang\":" + shim_jstr(lang));
    return lang;
}

// ---- ISteamUser::GetAuthSessionTicket ---------------------------------------
// Fills pTicket synchronously; we capture the ticket bytes + length here.
uint32_t SteamAPI_ISteamUser_GetAuthSessionTicket(void* self, void* pTicket,
                                                  int cbMaxTicket,
                                                  uint32_t* pcbTicket,
                                                  const void* pIdentity) {
    auto real = REAL(SteamAPI_ISteamUser_GetAuthSessionTicket);
    if (!real) return 0;
    uint32_t handle = real(self, pTicket, cbMaxTicket, pcbTicket, pIdentity);
    uint32_t len = (pcbTicket ? *pcbTicket : 0);
    shim_log("ISteamUser_GetAuthSessionTicket",
             "\"handle\":" + std::to_string(handle) +
                 ",\"ticket_len\":" + std::to_string(len) +
                 ",\"ticket\":" + shim_jhex(pTicket, len));
    return handle;
}

// ---- ISteamUser::GetAuthTicketForWebApi -------------------------------------
// The ticket bytes arrive later via GetTicketForWebApiResponse_t callback; here
// we log the CALL + identity + returned handle. The resulting web ticket is what
// the game POSTs to nacon/passtech (captured by the winhttp tap).
uint32_t SteamAPI_ISteamUser_GetAuthTicketForWebApi(void* self,
                                                    const char* pchIdentity) {
    auto real = REAL(SteamAPI_ISteamUser_GetAuthTicketForWebApi);
    if (!real) return 0;
    uint32_t handle = real(self, pchIdentity);
    shim_log("ISteamUser_GetAuthTicketForWebApi",
             "\"identity\":" + shim_jstr(pchIdentity) +
                 ",\"handle\":" + std::to_string(handle));
    return handle;
}

}  // extern "C"
