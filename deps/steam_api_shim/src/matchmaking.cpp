// matchmaking.cpp -- ISteamMatchmaking (SteamMatchMaking009) vtable tap.
//
// Ravenswatch resolves the C++ ISteamMatchmaking interface (version
// "SteamMatchMaking009") via SteamInternal_FindOrCreateUserInterface and then
// calls its methods through the object's vtable -- so the flat-API hooks in
// trampolines.cpp never see them. This is the ONE plane we otherwise have no
// working-online reference for: the Steam LOBBY control plane (SetLobbyData /
// GetLobbyData / CreateLobby / JoinLobby / member data) that carries the
// Stormancer `partyDataToken` between host and joiner -- exactly what the
// offline goldberg emu reimplements.
//
// Strategy (passive, read-only): when the game obtains the SteamMatchMaking009
// interface, read its vtable pointer and hot-patch a small set of slots with
// logging thunks. Every thunk calls the ORIGINAL method and returns its result
// UNCHANGED -- we only observe. The vtable is the shared class vtable, so we
// patch exactly once (guarded by the vtable address) regardless of how many
// times the interface is requested.
//
// ABI: built for the Microsoft x64 calling convention (mingw x86_64-w64).
// `this` is the first explicit parameter (RCX). CSteamID and SteamAPICall_t are
// 8-byte trivially-copyable values -> passed/returned in a register, so we model
// them as uint64_t. The vtable slot indices below are the stable, well-known
// layout of ISteamMatchmaking v009 (isteammatchmaking.h).
#include "shim.h"

#include <cstdint>
#include <mutex>
#include <string>

namespace {

inline std::string u64(uint64_t v) { return "\"" + std::to_string(v) + "\""; }
inline const char* boolstr(bool b) { return b ? "true" : "false"; }

// ---- original method pointer types (x64 thiscall == free fn with self) ------
typedef uint64_t   (*CreateLobby_t)(void*, int, int);
typedef uint64_t   (*JoinLobby_t)(void*, uint64_t);
typedef void       (*LeaveLobby_t)(void*, uint64_t);
typedef bool       (*InviteUserToLobby_t)(void*, uint64_t, uint64_t);
typedef int        (*GetNumLobbyMembers_t)(void*, uint64_t);
typedef uint64_t   (*GetLobbyMemberByIndex_t)(void*, uint64_t, int);
typedef const char* (*GetLobbyData_t)(void*, uint64_t, const char*);
typedef bool       (*SetLobbyData_t)(void*, uint64_t, const char*, const char*);
typedef bool       (*GetLobbyDataByIndex_t)(void*, uint64_t, int, char*, int, char*, int);
typedef const char* (*GetLobbyMemberData_t)(void*, uint64_t, uint64_t, const char*);
typedef void       (*SetLobbyMemberData_t)(void*, uint64_t, const char*, const char*);
typedef bool       (*RequestLobbyData_t)(void*, uint64_t);
typedef uint64_t   (*GetLobbyOwner_t)(void*, uint64_t);
typedef bool       (*SetLobbyJoinable_t)(void*, uint64_t, bool);
typedef bool       (*SetLobbyType_t)(void*, uint64_t, int);

static CreateLobby_t            g_CreateLobby            = nullptr;
static JoinLobby_t              g_JoinLobby              = nullptr;
static LeaveLobby_t             g_LeaveLobby             = nullptr;
static InviteUserToLobby_t      g_InviteUserToLobby      = nullptr;
static GetNumLobbyMembers_t     g_GetNumLobbyMembers     = nullptr;
static GetLobbyMemberByIndex_t  g_GetLobbyMemberByIndex  = nullptr;
static GetLobbyData_t           g_GetLobbyData           = nullptr;
static SetLobbyData_t           g_SetLobbyData           = nullptr;
static GetLobbyDataByIndex_t    g_GetLobbyDataByIndex    = nullptr;
static GetLobbyMemberData_t     g_GetLobbyMemberData     = nullptr;
static SetLobbyMemberData_t     g_SetLobbyMemberData     = nullptr;
static RequestLobbyData_t       g_RequestLobbyData       = nullptr;
static GetLobbyOwner_t          g_GetLobbyOwner          = nullptr;
static SetLobbyJoinable_t       g_SetLobbyJoinable       = nullptr;
static SetLobbyType_t           g_SetLobbyType           = nullptr;

// ---- logging thunks (call original, observe, return unchanged) --------------
uint64_t h_CreateLobby(void* self, int eLobbyType, int cMaxMembers) {
    uint64_t call = g_CreateLobby(self, eLobbyType, cMaxMembers);
    shim_log("ISteamMatchmaking_CreateLobby",
             "\"lobbyType\":" + std::to_string(eLobbyType) +
                 ",\"maxMembers\":" + std::to_string(cMaxMembers) +
                 ",\"apiCall\":" + u64(call));
    return call;
}
uint64_t h_JoinLobby(void* self, uint64_t lobby) {
    uint64_t call = g_JoinLobby(self, lobby);
    shim_log("ISteamMatchmaking_JoinLobby",
             "\"lobby\":" + u64(lobby) + ",\"apiCall\":" + u64(call));
    return call;
}
void h_LeaveLobby(void* self, uint64_t lobby) {
    g_LeaveLobby(self, lobby);
    shim_log("ISteamMatchmaking_LeaveLobby", "\"lobby\":" + u64(lobby));
}
bool h_InviteUserToLobby(void* self, uint64_t lobby, uint64_t invitee) {
    bool r = g_InviteUserToLobby(self, lobby, invitee);
    shim_log("ISteamMatchmaking_InviteUserToLobby",
             "\"lobby\":" + u64(lobby) + ",\"invitee\":" + u64(invitee) +
                 ",\"ok\":" + boolstr(r));
    return r;
}
int h_GetNumLobbyMembers(void* self, uint64_t lobby) {
    int n = g_GetNumLobbyMembers(self, lobby);
    shim_log("ISteamMatchmaking_GetNumLobbyMembers",
             "\"lobby\":" + u64(lobby) + ",\"count\":" + std::to_string(n));
    return n;
}
uint64_t h_GetLobbyMemberByIndex(void* self, uint64_t lobby, int i) {
    uint64_t m = g_GetLobbyMemberByIndex(self, lobby, i);
    shim_log("ISteamMatchmaking_GetLobbyMemberByIndex",
             "\"lobby\":" + u64(lobby) + ",\"index\":" + std::to_string(i) +
                 ",\"member\":" + u64(m));
    return m;
}
const char* h_GetLobbyData(void* self, uint64_t lobby, const char* key) {
    const char* v = g_GetLobbyData(self, lobby, key);
    shim_log("ISteamMatchmaking_GetLobbyData",
             "\"lobby\":" + u64(lobby) + ",\"key\":" + shim_jstr(key) +
                 ",\"value\":" + shim_jstr(v));
    return v;
}
bool h_SetLobbyData(void* self, uint64_t lobby, const char* key, const char* val) {
    bool r = g_SetLobbyData(self, lobby, key, val);
    shim_log("ISteamMatchmaking_SetLobbyData",
             "\"lobby\":" + u64(lobby) + ",\"key\":" + shim_jstr(key) +
                 ",\"value\":" + shim_jstr(val) + ",\"ok\":" + boolstr(r));
    return r;
}
bool h_GetLobbyDataByIndex(void* self, uint64_t lobby, int idx, char* key,
                           int keyLen, char* val, int valLen) {
    bool r = g_GetLobbyDataByIndex(self, lobby, idx, key, keyLen, val, valLen);
    shim_log("ISteamMatchmaking_GetLobbyDataByIndex",
             "\"lobby\":" + u64(lobby) + ",\"index\":" + std::to_string(idx) +
                 ",\"key\":" + shim_jstr(r ? key : nullptr) +
                 ",\"value\":" + shim_jstr(r ? val : nullptr) +
                 ",\"ok\":" + boolstr(r));
    return r;
}
const char* h_GetLobbyMemberData(void* self, uint64_t lobby, uint64_t user,
                                 const char* key) {
    const char* v = g_GetLobbyMemberData(self, lobby, user, key);
    shim_log("ISteamMatchmaking_GetLobbyMemberData",
             "\"lobby\":" + u64(lobby) + ",\"user\":" + u64(user) +
                 ",\"key\":" + shim_jstr(key) + ",\"value\":" + shim_jstr(v));
    return v;
}
void h_SetLobbyMemberData(void* self, uint64_t lobby, const char* key,
                          const char* val) {
    g_SetLobbyMemberData(self, lobby, key, val);
    shim_log("ISteamMatchmaking_SetLobbyMemberData",
             "\"lobby\":" + u64(lobby) + ",\"key\":" + shim_jstr(key) +
                 ",\"value\":" + shim_jstr(val));
}
bool h_RequestLobbyData(void* self, uint64_t lobby) {
    bool r = g_RequestLobbyData(self, lobby);
    shim_log("ISteamMatchmaking_RequestLobbyData",
             "\"lobby\":" + u64(lobby) + ",\"ok\":" + boolstr(r));
    return r;
}
uint64_t h_GetLobbyOwner(void* self, uint64_t lobby) {
    uint64_t o = g_GetLobbyOwner(self, lobby);
    shim_log("ISteamMatchmaking_GetLobbyOwner",
             "\"lobby\":" + u64(lobby) + ",\"owner\":" + u64(o));
    return o;
}
bool h_SetLobbyJoinable(void* self, uint64_t lobby, bool joinable) {
    bool r = g_SetLobbyJoinable(self, lobby, joinable);
    shim_log("ISteamMatchmaking_SetLobbyJoinable",
             "\"lobby\":" + u64(lobby) + ",\"joinable\":" + boolstr(joinable) +
                 ",\"ok\":" + boolstr(r));
    return r;
}
bool h_SetLobbyType(void* self, uint64_t lobby, int eLobbyType) {
    bool r = g_SetLobbyType(self, lobby, eLobbyType);
    shim_log("ISteamMatchmaking_SetLobbyType",
             "\"lobby\":" + u64(lobby) + ",\"lobbyType\":" +
                 std::to_string(eLobbyType) + ",\"ok\":" + boolstr(r));
    return r;
}

// ---- vtable slot indices for ISteamMatchmaking v009 -------------------------
enum {
    SLOT_CreateLobby           = 13,
    SLOT_JoinLobby             = 14,
    SLOT_LeaveLobby            = 15,
    SLOT_InviteUserToLobby     = 16,
    SLOT_GetNumLobbyMembers    = 17,
    SLOT_GetLobbyMemberByIndex = 18,
    SLOT_GetLobbyData          = 19,
    SLOT_SetLobbyData          = 20,
    SLOT_GetLobbyDataByIndex   = 22,
    SLOT_GetLobbyMemberData    = 24,
    SLOT_SetLobbyMemberData    = 25,
    SLOT_RequestLobbyData      = 28,
    SLOT_SetLobbyType          = 33,
    SLOT_SetLobbyJoinable      = 34,
    SLOT_GetLobbyOwner         = 35,
    SLOT_MAX_TOUCHED           = 36,  // protect through here
};

std::mutex g_patch_mtx;
void**     g_patched_vtbl = nullptr;

#define SAVE_PATCH(SLOT, NAME)                                                  \
    do {                                                                        \
        g_##NAME = reinterpret_cast<NAME##_t>(vtbl[SLOT]);                      \
        vtbl[SLOT] = reinterpret_cast<void*>(&h_##NAME);                        \
    } while (0)

}  // namespace

// Called from the SteamInternal_FindOrCreateUserInterface hook when the game
// requests a "SteamMatchMaking*" interface. `iface` is the returned interface
// pointer; its first machine word is the vtable pointer.
void shim_hook_matchmaking(void* iface) {
    if (!iface) return;
    std::lock_guard<std::mutex> lk(g_patch_mtx);

    void** vtbl = *reinterpret_cast<void***>(iface);
    if (!vtbl || vtbl == g_patched_vtbl) return;  // already patched (shared vtbl)

    // Make the slots we touch writable (vtables live in read-only .rdata).
    SIZE_T region = sizeof(void*) * (SLOT_MAX_TOUCHED + 1);
    DWORD old = 0;
    if (!VirtualProtect(vtbl, region, PAGE_EXECUTE_READWRITE, &old)) {
        shim_log("ISteamMatchmaking_patch_error",
                 "\"msg\":\"VirtualProtect failed\",\"err\":" +
                     std::to_string(GetLastError()));
        return;
    }

    SAVE_PATCH(SLOT_CreateLobby,           CreateLobby);
    SAVE_PATCH(SLOT_JoinLobby,             JoinLobby);
    SAVE_PATCH(SLOT_LeaveLobby,            LeaveLobby);
    SAVE_PATCH(SLOT_InviteUserToLobby,     InviteUserToLobby);
    SAVE_PATCH(SLOT_GetNumLobbyMembers,    GetNumLobbyMembers);
    SAVE_PATCH(SLOT_GetLobbyMemberByIndex, GetLobbyMemberByIndex);
    SAVE_PATCH(SLOT_GetLobbyData,          GetLobbyData);
    SAVE_PATCH(SLOT_SetLobbyData,          SetLobbyData);
    SAVE_PATCH(SLOT_GetLobbyDataByIndex,   GetLobbyDataByIndex);
    SAVE_PATCH(SLOT_GetLobbyMemberData,    GetLobbyMemberData);
    SAVE_PATCH(SLOT_SetLobbyMemberData,    SetLobbyMemberData);
    SAVE_PATCH(SLOT_RequestLobbyData,      RequestLobbyData);
    SAVE_PATCH(SLOT_SetLobbyType,          SetLobbyType);
    SAVE_PATCH(SLOT_SetLobbyJoinable,      SetLobbyJoinable);
    SAVE_PATCH(SLOT_GetLobbyOwner,         GetLobbyOwner);

    DWORD tmp = 0;
    VirtualProtect(vtbl, region, old, &tmp);
    FlushInstructionCache(GetCurrentProcess(), vtbl, region);

    g_patched_vtbl = vtbl;
    char buf[32];
    snprintf(buf, sizeof(buf), "%p", reinterpret_cast<void*>(vtbl));
    shim_log("ISteamMatchmaking_patched", "\"vtable\":\"" + std::string(buf) +
                                              "\",\"slots\":15");
}
