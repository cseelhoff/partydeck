// trampolines.cpp -- the hooked EOS exports.
//
// Each hooked function:  logs the inbound call, forwards UNCHANGED to the real
// SDK, and (for async ops) wraps the completion/notification delegate so we also
// log the result the game receives. Everything else in the SDK is a zero-code
// loader forward (see eos_shim.def); this file only touches the lobby/connect
// control plane that drives the join-by-code flow.
//
// NOTE on header version: the bundled SDK headers are 1.8.0, but the game ships
// EOS SDK 1.17.1.3. This is ABI-safe because:
//   * the hooked flat-API function SIGNATURES are identical across 1.8->1.17
//     (EOS only appends to Options structs + bumps ApiVersion; the call shape
//     (Handle, Options*, ClientData, Delegate) never changes);
//   * we only READ front-of-struct CallbackInfo fields (ResultCode, ClientData,
//     LobbyId, TargetUserId, CurrentStatus) whose offsets are version-stable
//     (append-only); and
//   * we never construct/forward a copy of a CallbackInfo (which would use the
//     stale 1.8.0 size). Instead each handler swaps ClientData IN PLACE -- whose
//     offset is stable (0 for notifies, 8 for completions) -- and forwards the
//     ORIGINAL full-size pointer the real SDK allocated, so the game still reads
//     every field of its own 1.17 struct correctly.
#include "shim.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <string>

extern "C" {

// ---- small enum stringifiers -------------------------------------------------
static const char* member_status_str(EOS_ELobbyMemberStatus s) {
    switch (s) {
        case EOS_ELobbyMemberStatus::EOS_LMS_JOINED: return "JOINED";
        case EOS_ELobbyMemberStatus::EOS_LMS_LEFT: return "LEFT";
        case EOS_ELobbyMemberStatus::EOS_LMS_DISCONNECTED: return "DISCONNECTED";
        case EOS_ELobbyMemberStatus::EOS_LMS_KICKED: return "KICKED";
        case EOS_ELobbyMemberStatus::EOS_LMS_PROMOTED: return "PROMOTED";
        case EOS_ELobbyMemberStatus::EOS_LMS_CLOSED: return "CLOSED";
        default: return "?";
    }
}

static const char* reliability_str(EOS_EPacketReliability r) {
    switch (r) {
        case EOS_EPacketReliability::EOS_PR_UnreliableUnordered: return "UU";
        case EOS_EPacketReliability::EOS_PR_ReliableUnordered: return "RU";
        case EOS_EPacketReliability::EOS_PR_ReliableOrdered: return "RO";
        default: return "?";
    }
}

// Hex-encode up to `cap` bytes of a buffer as a JSON string (with quotes). The
// cap keeps the per-packet log line bounded while still exposing the message
// header/opcode bytes needed to reverse the P2P wire protocol.
static std::string shim_hex(const void* data, uint32_t len, uint32_t cap = 64) {
    static const char H[] = "0123456789abcdef";
    const uint8_t* p = static_cast<const uint8_t*>(data);
    std::string s;
    if (!p) return std::string("null");
    uint32_t n = (len < cap) ? len : cap;
    s.reserve(static_cast<size_t>(n) * 2 + 2);
    s.push_back('"');
    for (uint32_t i = 0; i < n; ++i) {
        s.push_back(H[p[i] >> 4]);
        s.push_back(H[p[i] & 0x0f]);
    }
    s.push_back('"');
    return s;
}

// =====================================================================
//  Connect
// =====================================================================

// One-shot completion contexts carry the game's real delegate + ClientData so we
// can restore them before forwarding the callback.
struct OneShotCtx {
    void* realDelegate;
    void* realClient;
};

static void EOS_CALL on_connect_login(const EOS_Connect_LoginCallbackInfo* Data) {
    auto* ctx = static_cast<OneShotCtx*>(Data->ClientData);
    shim_log("cb:EOS_Connect_Login",
             "\"result\":" + shim_result(Data->ResultCode) +
                 ",\"localUser\":" + shim_puid(Data->LocalUserId) +
                 ",\"hasContinuance\":" +
                 (Data->ContinuanceToken ? "true" : "false"));
    auto* d = const_cast<EOS_Connect_LoginCallbackInfo*>(Data);
    d->ClientData = ctx->realClient;
    auto cb = reinterpret_cast<EOS_Connect_OnLoginCallback>(ctx->realDelegate);
    delete ctx;
    if (cb) cb(d);
}

EOS_DECLARE_FUNC(void)
EOS_Connect_Login(EOS_HConnect Handle, const EOS_Connect_LoginOptions* Options,
                  void* ClientData,
                  const EOS_Connect_OnLoginCallback CompletionDelegate) {
    int credType = -1;
    bool hasToken = false;
    if (Options && Options->Credentials) {
        credType = static_cast<int>(Options->Credentials->Type);
        hasToken = Options->Credentials->Token != nullptr;
    }
    // Never log the token value itself (it's a real Epic/Steam auth secret).
    shim_log("call:EOS_Connect_Login",
             "\"credType\":" + std::to_string(credType) + ",\"hasToken\":" +
                 (hasToken ? "true" : "false"));
    auto* ctx = new OneShotCtx{reinterpret_cast<void*>(CompletionDelegate), ClientData};
    REAL(EOS_Connect_Login)(Handle, Options, ctx, on_connect_login);
}

static void EOS_CALL
on_login_status(const EOS_Connect_LoginStatusChangedCallbackInfo* Data) {
    auto* ctx = static_cast<OneShotCtx*>(Data->ClientData);
    shim_log("cb:EOS_Connect_LoginStatusChanged",
             "\"localUser\":" + shim_puid(Data->LocalUserId) + ",\"prev\":" +
                 std::to_string(static_cast<int>(Data->PreviousStatus)) +
                 ",\"cur\":" +
                 std::to_string(static_cast<int>(Data->CurrentStatus)));
    auto* d = const_cast<EOS_Connect_LoginStatusChangedCallbackInfo*>(Data);
    d->ClientData = ctx->realClient;
    auto cb = reinterpret_cast<EOS_Connect_OnLoginStatusChangedCallback>(
        ctx->realDelegate);
    if (cb) cb(d);  // persistent: keep ctx alive (leak; few registrations)
}

EOS_DECLARE_FUNC(EOS_NotificationId)
EOS_Connect_AddNotifyLoginStatusChanged(
    EOS_HConnect Handle,
    const EOS_Connect_AddNotifyLoginStatusChangedOptions* Options,
    void* ClientData, const EOS_Connect_OnLoginStatusChangedCallback Notification) {
    shim_log("call:EOS_Connect_AddNotifyLoginStatusChanged", "");
    auto* ctx = new OneShotCtx{reinterpret_cast<void*>(Notification), ClientData};
    return REAL(EOS_Connect_AddNotifyLoginStatusChanged)(Handle, Options, ctx,
                                                         on_login_status);
}

// =====================================================================
//  Lobby
// =====================================================================

static void EOS_CALL on_create_lobby(const EOS_Lobby_CreateLobbyCallbackInfo* Data) {
    auto* ctx = static_cast<OneShotCtx*>(Data->ClientData);
    shim_log("cb:EOS_Lobby_CreateLobby",
             "\"result\":" + shim_result(Data->ResultCode) + ",\"lobby\":" +
                 shim_jstr(Data->LobbyId));
    auto* d = const_cast<EOS_Lobby_CreateLobbyCallbackInfo*>(Data);
    d->ClientData = ctx->realClient;
    auto cb = reinterpret_cast<EOS_Lobby_OnCreateLobbyCallback>(ctx->realDelegate);
    delete ctx;
    if (cb) cb(d);
}

EOS_DECLARE_FUNC(void)
EOS_Lobby_CreateLobby(EOS_HLobby Handle, const EOS_Lobby_CreateLobbyOptions* Options,
                      void* ClientData,
                      const EOS_Lobby_OnCreateLobbyCallback CompletionDelegate) {
    shim_log("call:EOS_Lobby_CreateLobby",
             "\"localUser\":" +
                 (Options ? shim_puid(Options->LocalUserId) : std::string("null")) +
                 ",\"maxMembers\":" +
                 std::to_string(Options ? Options->MaxLobbyMembers : 0));
    auto* ctx = new OneShotCtx{reinterpret_cast<void*>(CompletionDelegate), ClientData};
    REAL(EOS_Lobby_CreateLobby)(Handle, Options, ctx, on_create_lobby);
}

static void EOS_CALL on_join_lobby(const EOS_Lobby_JoinLobbyCallbackInfo* Data) {
    auto* ctx = static_cast<OneShotCtx*>(Data->ClientData);
    shim_log("cb:EOS_Lobby_JoinLobby",
             "\"result\":" + shim_result(Data->ResultCode) + ",\"lobby\":" +
                 shim_jstr(Data->LobbyId));
    auto* d = const_cast<EOS_Lobby_JoinLobbyCallbackInfo*>(Data);
    d->ClientData = ctx->realClient;
    auto cb = reinterpret_cast<EOS_Lobby_OnJoinLobbyCallback>(ctx->realDelegate);
    delete ctx;
    if (cb) cb(d);
}

EOS_DECLARE_FUNC(void)
EOS_Lobby_JoinLobby(EOS_HLobby Handle, const EOS_Lobby_JoinLobbyOptions* Options,
                    void* ClientData,
                    const EOS_Lobby_OnJoinLobbyCallback CompletionDelegate) {
    shim_log("call:EOS_Lobby_JoinLobby",
             "\"localUser\":" +
                 (Options ? shim_puid(Options->LocalUserId) : std::string("null")));
    auto* ctx = new OneShotCtx{reinterpret_cast<void*>(CompletionDelegate), ClientData};
    REAL(EOS_Lobby_JoinLobby)(Handle, Options, ctx, on_join_lobby);
}

static void EOS_CALL on_destroy_lobby(const EOS_Lobby_DestroyLobbyCallbackInfo* Data) {
    auto* ctx = static_cast<OneShotCtx*>(Data->ClientData);
    shim_log("cb:EOS_Lobby_DestroyLobby",
             "\"result\":" + shim_result(Data->ResultCode) + ",\"lobby\":" +
                 shim_jstr(Data->LobbyId));
    auto* d = const_cast<EOS_Lobby_DestroyLobbyCallbackInfo*>(Data);
    d->ClientData = ctx->realClient;
    auto cb = reinterpret_cast<EOS_Lobby_OnDestroyLobbyCallback>(ctx->realDelegate);
    delete ctx;
    if (cb) cb(d);
}

EOS_DECLARE_FUNC(void)
EOS_Lobby_DestroyLobby(EOS_HLobby Handle,
                       const EOS_Lobby_DestroyLobbyOptions* Options,
                       void* ClientData,
                       const EOS_Lobby_OnDestroyLobbyCallback CompletionDelegate) {
    shim_log("call:EOS_Lobby_DestroyLobby",
             "\"lobby\":" +
                 (Options ? shim_jstr(Options->LobbyId) : std::string("null")) +
                 ",\"localUser\":" +
                 (Options ? shim_puid(Options->LocalUserId) : std::string("null")));
    auto* ctx = new OneShotCtx{reinterpret_cast<void*>(CompletionDelegate), ClientData};
    REAL(EOS_Lobby_DestroyLobby)(Handle, Options, ctx, on_destroy_lobby);
}

static void EOS_CALL on_leave_lobby(const EOS_Lobby_LeaveLobbyCallbackInfo* Data) {
    auto* ctx = static_cast<OneShotCtx*>(Data->ClientData);
    shim_log("cb:EOS_Lobby_LeaveLobby",
             "\"result\":" + shim_result(Data->ResultCode) + ",\"lobby\":" +
                 shim_jstr(Data->LobbyId));
    auto* d = const_cast<EOS_Lobby_LeaveLobbyCallbackInfo*>(Data);
    d->ClientData = ctx->realClient;
    auto cb = reinterpret_cast<EOS_Lobby_OnLeaveLobbyCallback>(ctx->realDelegate);
    delete ctx;
    if (cb) cb(d);
}

EOS_DECLARE_FUNC(void)
EOS_Lobby_LeaveLobby(EOS_HLobby Handle, const EOS_Lobby_LeaveLobbyOptions* Options,
                     void* ClientData,
                     const EOS_Lobby_OnLeaveLobbyCallback CompletionDelegate) {
    shim_log("call:EOS_Lobby_LeaveLobby",
             "\"lobby\":" +
                 (Options ? shim_jstr(Options->LobbyId) : std::string("null")) +
                 ",\"localUser\":" +
                 (Options ? shim_puid(Options->LocalUserId) : std::string("null")));
    auto* ctx = new OneShotCtx{reinterpret_cast<void*>(CompletionDelegate), ClientData};
    REAL(EOS_Lobby_LeaveLobby)(Handle, Options, ctx, on_leave_lobby);
}

// THE crown jewel: the member-status notification that drives the managed
// JoinByCode coroutine (the suspected spurious self-CLOSED on DestroyLobby).
static void EOS_CALL
on_member_status(const EOS_Lobby_LobbyMemberStatusReceivedCallbackInfo* Data) {
    auto* ctx = static_cast<OneShotCtx*>(Data->ClientData);
    shim_log("cb:EOS_Lobby_LobbyMemberStatusReceived",
             "\"lobby\":" + shim_jstr(Data->LobbyId) + ",\"target\":" +
                 shim_puid(Data->TargetUserId) + ",\"status\":\"" +
                 member_status_str(Data->CurrentStatus) + "\",\"statusRaw\":" +
                 std::to_string(static_cast<int>(Data->CurrentStatus)));
    auto* d = const_cast<EOS_Lobby_LobbyMemberStatusReceivedCallbackInfo*>(Data);
    d->ClientData = ctx->realClient;
    auto cb = reinterpret_cast<EOS_Lobby_OnLobbyMemberStatusReceivedCallback>(
        ctx->realDelegate);
    if (cb) cb(d);  // persistent
}

EOS_DECLARE_FUNC(EOS_NotificationId)
EOS_Lobby_AddNotifyLobbyMemberStatusReceived(
    EOS_HLobby Handle,
    const EOS_Lobby_AddNotifyLobbyMemberStatusReceivedOptions* Options,
    void* ClientData,
    const EOS_Lobby_OnLobbyMemberStatusReceivedCallback NotificationFn) {
    shim_log("call:EOS_Lobby_AddNotifyLobbyMemberStatusReceived", "");
    auto* ctx = new OneShotCtx{reinterpret_cast<void*>(NotificationFn), ClientData};
    return REAL(EOS_Lobby_AddNotifyLobbyMemberStatusReceived)(Handle, Options, ctx,
                                                             on_member_status);
}

// =====================================================================
//  LobbySearch (join-by-code lookup)
// =====================================================================

EOS_DECLARE_FUNC(EOS_EResult)
EOS_LobbySearch_SetLobbyId(EOS_HLobbySearch Handle,
                           const EOS_LobbySearch_SetLobbyIdOptions* Options) {
    // Options->LobbyId here is the join-by-code target -- the most useful single
    // value to correlate with the RakNet 0x8e code-submit.
    shim_log("call:EOS_LobbySearch_SetLobbyId",
             "\"lobbyId\":" +
                 (Options ? shim_jstr(Options->LobbyId) : std::string("null")));
    return REAL(EOS_LobbySearch_SetLobbyId)(Handle, Options);
}

static void EOS_CALL on_search_find(const EOS_LobbySearch_FindCallbackInfo* Data) {
    auto* ctx = static_cast<OneShotCtx*>(Data->ClientData);
    shim_log("cb:EOS_LobbySearch_Find",
             "\"result\":" + shim_result(Data->ResultCode));
    auto* d = const_cast<EOS_LobbySearch_FindCallbackInfo*>(Data);
    d->ClientData = ctx->realClient;
    auto cb = reinterpret_cast<EOS_LobbySearch_OnFindCallback>(ctx->realDelegate);
    delete ctx;
    if (cb) cb(d);
}

EOS_DECLARE_FUNC(void)
EOS_LobbySearch_Find(EOS_HLobbySearch Handle,
                     const EOS_LobbySearch_FindOptions* Options, void* ClientData,
                     const EOS_LobbySearch_OnFindCallback CompletionDelegate) {
    shim_log("call:EOS_LobbySearch_Find",
             "\"localUser\":" +
                 (Options ? shim_puid(Options->LocalUserId) : std::string("null")));
    auto* ctx = new OneShotCtx{reinterpret_cast<void*>(CompletionDelegate), ClientData};
    REAL(EOS_LobbySearch_Find)(Handle, Options, ctx, on_search_find);
}

// =====================================================================
//  P2P notifications (peer connection request / closed)
// =====================================================================

static void EOS_CALL
on_p2p_request(const EOS_P2P_OnIncomingConnectionRequestInfo* Data) {
    auto* ctx = static_cast<OneShotCtx*>(Data->ClientData);
    const char* sock = (Data->SocketId ? Data->SocketId->SocketName : nullptr);
    shim_log("cb:EOS_P2P_PeerConnectionRequest",
             "\"local\":" + shim_puid(Data->LocalUserId) + ",\"remote\":" +
                 shim_puid(Data->RemoteUserId) + ",\"socket\":" + shim_jstr(sock));
    auto* d = const_cast<EOS_P2P_OnIncomingConnectionRequestInfo*>(Data);
    d->ClientData = ctx->realClient;
    auto cb = reinterpret_cast<EOS_P2P_OnIncomingConnectionRequestCallback>(
        ctx->realDelegate);
    if (cb) cb(d);  // persistent
}

EOS_DECLARE_FUNC(EOS_NotificationId)
EOS_P2P_AddNotifyPeerConnectionRequest(
    EOS_HP2P Handle, const EOS_P2P_AddNotifyPeerConnectionRequestOptions* Options,
    void* ClientData,
    const EOS_P2P_OnIncomingConnectionRequestCallback ConnectionRequestHandler) {
    shim_log("call:EOS_P2P_AddNotifyPeerConnectionRequest", "");
    auto* ctx =
        new OneShotCtx{reinterpret_cast<void*>(ConnectionRequestHandler), ClientData};
    return REAL(EOS_P2P_AddNotifyPeerConnectionRequest)(Handle, Options, ctx,
                                                       on_p2p_request);
}

static void EOS_CALL
on_p2p_closed(const EOS_P2P_OnRemoteConnectionClosedInfo* Data) {
    auto* ctx = static_cast<OneShotCtx*>(Data->ClientData);
    const char* sock = (Data->SocketId ? Data->SocketId->SocketName : nullptr);
    shim_log("cb:EOS_P2P_PeerConnectionClosed",
             "\"local\":" + shim_puid(Data->LocalUserId) + ",\"remote\":" +
                 shim_puid(Data->RemoteUserId) + ",\"socket\":" + shim_jstr(sock) +
                 ",\"reason\":" + std::to_string(static_cast<int>(Data->Reason)));
    auto* d = const_cast<EOS_P2P_OnRemoteConnectionClosedInfo*>(Data);
    d->ClientData = ctx->realClient;
    auto cb =
        reinterpret_cast<EOS_P2P_OnRemoteConnectionClosedCallback>(ctx->realDelegate);
    if (cb) cb(d);  // persistent
}

EOS_DECLARE_FUNC(EOS_NotificationId)
EOS_P2P_AddNotifyPeerConnectionClosed(
    EOS_HP2P Handle, const EOS_P2P_AddNotifyPeerConnectionClosedOptions* Options,
    void* ClientData,
    const EOS_P2P_OnRemoteConnectionClosedCallback ConnectionClosedHandler) {
    shim_log("call:EOS_P2P_AddNotifyPeerConnectionClosed", "");
    auto* ctx =
        new OneShotCtx{reinterpret_cast<void*>(ConnectionClosedHandler), ClientData};
    return REAL(EOS_P2P_AddNotifyPeerConnectionClosed)(Handle, Options, ctx,
                                                      on_p2p_closed);
}

// =====================================================================
//  P2P data plane (SendPacket / ReceivePacket / Accept / Close)
// =====================================================================
// These are synchronous forwarded-then-logged calls -- the genuine SDK does NOT
// invoke a delegate, so we log inline. This is the wire data plane the emu must
// reproduce byte-for-byte; we capture peer/socket/channel/reliability/length and
// a capped hex prefix of every packet. ReceivePacket is logged ONLY on Success
// to avoid flooding the log with the game's per-frame idle-poll misses.
static unsigned long long g_send_seq = 0;
static unsigned long long g_recv_seq = 0;

EOS_DECLARE_FUNC(EOS_EResult)
EOS_P2P_SendPacket(EOS_HP2P Handle, const EOS_P2P_SendPacketOptions* Options) {
    if (Options) {
        const char* sock =
            (Options->SocketId ? Options->SocketId->SocketName : nullptr);
        shim_log("call:EOS_P2P_SendPacket",
                 "\"seq\":" + std::to_string(g_send_seq++) + ",\"local\":" +
                     shim_puid(Options->LocalUserId) + ",\"remote\":" +
                     shim_puid(Options->RemoteUserId) + ",\"socket\":" +
                     shim_jstr(sock) + ",\"channel\":" +
                     std::to_string(static_cast<int>(Options->Channel)) +
                     ",\"rel\":\"" + reliability_str(Options->Reliability) +
                     "\",\"len\":" + std::to_string(Options->DataLengthBytes) +
                     ",\"data\":" + shim_hex(Options->Data, Options->DataLengthBytes));
    }
    return REAL(EOS_P2P_SendPacket)(Handle, Options);
}

EOS_DECLARE_FUNC(EOS_EResult)
EOS_P2P_ReceivePacket(EOS_HP2P Handle, const EOS_P2P_ReceivePacketOptions* Options,
                      EOS_ProductUserId* OutPeerId, EOS_P2P_SocketId* OutSocketId,
                      uint8_t* OutChannel, void* OutData,
                      uint32_t* OutBytesWritten) {
    EOS_EResult r = REAL(EOS_P2P_ReceivePacket)(Handle, Options, OutPeerId,
                                                OutSocketId, OutChannel, OutData,
                                                OutBytesWritten);
    if (r == EOS_EResult::EOS_Success) {
        const char* sock = (OutSocketId ? OutSocketId->SocketName : nullptr);
        uint32_t len = (OutBytesWritten ? *OutBytesWritten : 0);
        shim_log("call:EOS_P2P_ReceivePacket",
                 "\"seq\":" + std::to_string(g_recv_seq++) + ",\"remote\":" +
                     shim_puid(OutPeerId ? *OutPeerId : nullptr) + ",\"socket\":" +
                     shim_jstr(sock) + ",\"channel\":" +
                     std::to_string(OutChannel ? static_cast<int>(*OutChannel) : -1) +
                     ",\"len\":" + std::to_string(len) + ",\"data\":" +
                     shim_hex(OutData, len));
    }
    return r;
}

EOS_DECLARE_FUNC(EOS_EResult)
EOS_P2P_AcceptConnection(EOS_HP2P Handle,
                         const EOS_P2P_AcceptConnectionOptions* Options) {
    if (Options) {
        const char* sock =
            (Options->SocketId ? Options->SocketId->SocketName : nullptr);
        shim_log("call:EOS_P2P_AcceptConnection",
                 "\"local\":" + shim_puid(Options->LocalUserId) + ",\"remote\":" +
                     shim_puid(Options->RemoteUserId) + ",\"socket\":" +
                     shim_jstr(sock));
    }
    return REAL(EOS_P2P_AcceptConnection)(Handle, Options);
}

EOS_DECLARE_FUNC(EOS_EResult)
EOS_P2P_CloseConnection(EOS_HP2P Handle,
                        const EOS_P2P_CloseConnectionOptions* Options) {
    if (Options) {
        const char* sock =
            (Options->SocketId ? Options->SocketId->SocketName : nullptr);
        shim_log("call:EOS_P2P_CloseConnection",
                 "\"local\":" + shim_puid(Options->LocalUserId) + ",\"remote\":" +
                     shim_puid(Options->RemoteUserId) + ",\"socket\":" +
                     shim_jstr(sock));
    }
    return REAL(EOS_P2P_CloseConnection)(Handle, Options);
}

// =====================================================================
//  Platform lifecycle (log-only, forwarded unchanged)
// =====================================================================

EOS_DECLARE_FUNC(EOS_EResult)
EOS_Initialize(const EOS_InitializeOptions* Options) {
    const char* product = (Options ? Options->ProductName : nullptr);
    shim_log("call:EOS_Initialize", "\"product\":" + shim_jstr(product));
    return REAL(EOS_Initialize)(Options);
}

EOS_DECLARE_FUNC(EOS_EResult) EOS_Shutdown(void) {
    shim_log("call:EOS_Shutdown", "");
    return REAL(EOS_Shutdown)();
}

}  // extern "C"
