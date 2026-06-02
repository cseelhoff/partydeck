# Ravenswatch co-op join — WORKING / DESIRED flow (real online, 2 Steam accounts)

This is the **ground-truth** sequence of a successful "join by code" between two real Steam
accounts over the internet, reconstructed from:

- Engine log: `Ravenswatch/_Logs/logs_2026-06-02_04h-34m-34s.txt` (JOINER side, full).
- Wire capture decode: `relay.joiner_bycode.jsonl` → `JOINER_REFERENCE_DECODED.md`
  (RakNet/Stormancer plaintext msgpack, same session).

The goal of the offline partydeck work is to reproduce **this** sequence with local stand-ins.

---

## Actors / planes

| Symbol | Actor | Working (online) identity | Offline stand-in |
|--------|-------|----------------------------|------------------|
| **HOST** | Hosting client (creates party, owns the code) | user's **2nd Steam account**, steam `76561199572083022`, userId `9fe2fc1f…4b00` | Profile **Dad** |
| **JOINER** | Joining client (enters the code) | user's **1st Steam account** "Major Hoff", steam `76561197977870267`, userId `4168ffb2…685e`, EOS `0002…786` | Profile **Elsie** |
| **EOSsrv** | Epic Online Services backend | `api.epicgames.dev` (HTTPS + WSS) | NEE EOS emu (local DLL) |
| **STORM** | Stormancer / RakNet federation | `dt-live.passtechgames.com:30100` (UDP, plaintext msgpack) | `raknet.py` broker `:30100` |
| **STEAM** | Steam matchmaking / lobby | Real Steam backend | Goldberg (LAN broadcast :47584) |

> **Identity note:** all names/ids here come from the **wire capture decode**, not machine names.

Codes for this capture: JOINER's own party code = **396879**; HOST's code that JOINER enters = **325496**.
HOST party GUID = `party-81bfb94c-67ba-4070-8702-35268412bee9` (leader steam `76561199572083022`).
JOINER party GUID = `party-59a029a1-670b-4106-a624-4efa5ef804ca` (leader steam `76561197977870267`).

Route bytes (this build): `0x8e` = gamefinder join-by-code submit + token reply;
`0x90` = matchmaking registration / merger-status poll; `0x8f` = party advertisement;
`0x92` = gamesession scene. `DISCONNECT_FROM_SCENE` / `CONNECT_TO_SCENE` = RakNet system requests.

---

## Phase A — JOINER boots and creates its OWN party (00:00–00:08)

Status column = does the **partydeck (EOS-emu + Goldberg + raknet.py)** build do the same thing?
✅ match · ⚠️ works with a benign difference · ❌ divergence (see notes `[Dn]`).

| t | src → dst | plane | event (decoded) | meaning | partydeck |
|---|-----------|-------|-----------------|---------|:--------:|
| 0:01 | JOINER → EOSsrv | EOS | `GetPlatformConfigRoute` / `TokenGrant` HTTP 200 | EOS auth (external/Steam account) | ⚠️ `[D1]` |
| 0:02 | JOINER → STEAM | STEAM | `GetAuthTicketForWebApi k_EResultOK` | Steam web ticket for Stormancer auth | ✅ |
| 0:02 | JOINER → EOSsrv | EOS | `EOS: Connected (external account)`, PUID `0002…786` | EOS connect login OK | ✅ |
| 0:02 | JOINER → STORM | RakNet | `connecting to dt-live.passtechgames.com:30100 id='passtech-live'` | open RakNet to federation | ✅ `[D2]` |
| 0:03 | STORM → JOINER | RakNet | `ID_CONNECTION_REQUEST_ACCEPTED` / `ID_CONNECTION_RESULT` | RakNet connected | ✅ |
| 0:03 | JOINER → STORM | RakNet | `session id acquired [EwQsXi74…]` | Stormancer session established | ✅ |
| 0:04 | JOINER ↔ STORM | RakNet | connect scene `…/authenticator` | auth scene | ✅ |
| 0:05 | JOINER → EOSsrv | EOS | `EOS_P2P_QueryNATType: EOS_NAT_Moderate` | P2P NAT probe | ⚠️ `[D3]` |
| 0:06 | — | game | `Lobby Host: true Enter StateHeroSelection` / `Party State Creating with code` | JOINER starts as a host-of-itself | ✅ |
| 0:07 | JOINER ↔ STORM | RakNet | connect `party-manager`, `friends` scenes | party plumbing | ✅ |
| 0:08 | JOINER ↔ STORM | RakNet | connect `party-59a029a1` (JOINER's own party scene) | own party created | ✅ |
| 0:09 | JOINER → STEAM | STEAM | `Creating steam lobby [joinable=1,maxMembers=4,lobbyType=friendsOnly, metadata={partyDataToken=<b64>}]` | Steam lobby carries `{PartyId, LeaderUserId, LeaderSteamId}` | ✅ |
| 0:09 | STEAM → JOINER | STEAM | `Steam lobby created [109775242660981344]` | own Steam lobby id | ✅ |
| 0:10 | JOINER ↔ STORM | RakNet | connect `matchmaking` (gamefinder) scene; `0x90 :: matchmaking {InvitationCode:""}` | register with gamefinder | ✅ |
| 0:10 | STORM → JOINER | RakNet | `0x90 :: 396879` then `Party Generated invitation code: 396879` | server assigns JOINER's own code | ✅ |
| 0:10 | — | game | `Party State Not ready` | JOINER idle in its own party | ✅ |

### EOS lobby + RTC voice room for JOINER's own party (00:10–00:12)

| t | src → dst | plane | event | meaning | partydeck |
|---|-----------|-------|-------|---------|:--------:|
| 0:10 | JOINER → EOSsrv | EOS | `Room Creation with Local RTC Options set` / `Creating lobby with RTC Room enabled` | EOS lobby + voice | ❌ `[D4]` |
| 0:10 | JOINER → EOSsrv | EOS(WSS) | `Opening Lobby Socket To wss://api.epicgames.dev/lobby/v1/<dep>/lobbies/connect` | EOS lobby websocket | ❌ `[D4]` |
| 0:11 | JOINER → EOSsrv | EOS(WSS) | `SendMessage Type: create` | create EOS lobby record | ⚠️ `[D4]` |
| 0:11 | EOSsrv → JOINER | EOS | `Lobby RTC Room info set. LobbyId=[396879] RoomName=[conf+1514391690]` | EOS lobby id == party code; RTC room name | ❌ `[D4]` |
| 0:11 | JOINER → EOSsrv | EOS(RTC) | `RTCRoom JoinRoom MsUrl=[wss://signaling-service-prod…]` → ICE → `Connection State: Connected` | WebRTC voice conference up | ❌ `[D4]` |
| 0:11 | — | game | `EOS: _OnLobbyCreated (eConnected)` | **managed: own EOS lobby ready** | ✅ `[D4]` |

**State after Phase A:** JOINER sits in its own party (code 396879), with an EOS lobby + live RTC
voice conference (`conf+1514391690`), registered on gamefinder, advertised via a Steam lobby.
**Offline:** identical EXCEPT no RTC voice room exists (the emu returns `GetRTCRoomName =
NotImplemented`); the game treats this as "no voice" and proceeds normally. Phase A is otherwise ✅.

---

## Phase B — *** THE JOINER CLICK *** : enter HOST code 325496 (00:19–00:22)

This is the segment the offline build fails to reproduce. The managed `Party State | Joining with
code` command drives **three planes in parallel**: tear down JOINER's own EOS lobby+RTC, leave JOINER's
own Stormancer party, and connect to the HOST's party scene.

### B1 — managed kicks off, tears down JOINER's OWN EOS lobby + RTC (00:19–00:20)

| t | src → dst | plane | event | meaning | partydeck |
|---|-----------|-------|-------|---------|:--------:|
| 0:19 | — | game | `Stormancer Party State Joining with code (325496)` | **join coroutine STARTS** | ✅ |
| 0:19 | JOINER | EOS(RTC) | RTCRoom Notifications `[48][49]` removed (own room) | begin own-room teardown | ❌ `[D4]` |
| 0:19 | JOINER → EOSsrv | EOS(WSS) | `SendMessage Type: delete` / `SendWebSocketMessage` | delete own EOS lobby | ⚠️ `[D5]` |
| 0:20 | JOINER → EOSsrv | EOS | `EOSSDK.DestroyLobby`, `LobbyConnectionClosed` | own EOS lobby closing | ✅ `[D5]` |
| 0:20 | — | game | `EOS: _OnLobbyDestroyed` | **managed destroy callback fired** | ✅ `[D5]` |
| 0:20 | JOINER → EOSsrv | EOS(RTC) | `RTCRoom LeaveRoom` → … → `RTCRoom Conference End. ResultCode=[EOS_Success] Details=[Successful Disconnect]` | WebRTC voice torn down — **fire-and-forget** (the `EOS_RTC_DisconnectedCallbackInfo` handler Id 47 is *removed* just before `LeaveRoom`, so the join is NOT gated on this) | ❌ `[D6]` |

> **⛔ THE HANG IS HERE (offline).** Offline, `_OnLobbyDestroyed` fires (✅) and the managed join
> coroutine then freezes — it never advances to B2. **Online, B2 starts in the SAME `00-00-20` tick
> as `_OnLobbyDestroyed`, with no await gap** (`_OnLobbyDestroyed` → `Scene destroyed [own party]`
> immediately). So the offline block is a managed continuation that runs synchronously online but
> never runs offline. Everything below this line is what a WORKING join does next and what the
> offline build FAILS to do (`[D7]`).

### B2 — *** native Stormancer leaves own party, JOINERS HOST party *** (00:20–00:22)

| t | src → dst | plane | event (engine ↔ wire) | meaning | partydeck |
|---|-----------|-------|------------------------|---------|:--------:|
| 0:20 | JOINER → STORM | RakNet | wire: `ID_SYSTEM_REQUEST DISCONNECT_FROM_SCENE` ×2 (reqId 33,34) | leave own gamefinder/party scenes | ❌ `[D7]` |
| 0:20 | STORM → JOINER | RakNet | wire: `REQUEST_RESPONSE_MSG`+`COMPLETE` for reqId 33,34 | **server ACKs the disconnects** | ❌ `[D7]` `[D8]` |
| 0:20 | — | game | `Scene destroyed [party-59a029a1]` (own party) | own party scene gone | ❌ `[D7]` |
| 0:20 | JOINER → STEAM | STEAM | `Steam Leaving lobby [109775242660981344]` | leave own Steam lobby | ❌ `[D7]` |
| 0:20 | — | game | `Scene destroyed [matchmaking]` | left own gamefinder | ❌ `[D7]` |
| 0:20 | JOINER → STORM | RakNet | wire: `0x8e :: 325496` [392B] (submit HOST code on gamefinder) | **enter the code** | ❌ `[D7]` `[D8]` |
| 0:20 | STORM → JOINER | RakNet | wire: `0x8e :: {"token":"<scene-connect token>","endpoints":…}` | **server resolves code → HOST party connect token** | ❌ `[D7]` `[D8]` |
| 0:20 | — | game | `Client Get private scene [party-81bfb94c…]` (HOST party) | use token to target host party | ❌ `[D7]` |
| 0:20 | JOINER ↔ STORM | RakNet | `PartyService Protocol version …`, `Connecting to scene [party-81bfb94c…]` → `Connected to scene` | **JOINER connected to HOST party scene** | ❌ `[D7]` |
| 0:21 | STEAM → JOINER | STEAM | `Lobby data updated [lobby=109775242660736055]`, `Join lobby`, `Joined steam lobby` | join HOST's Steam lobby | ❌ `[D7]` `[D9]` |
| 0:21 | JOINER → STORM | RakNet | get gamefinder/matchmaking token (now for HOST party) | re-register on host's gamefinder | ❌ `[D7]` |
| 0:22 | — | game | `Tunnel: client created: 127.0.0.1:52523` | RakNet P2P tunnel to host | ❌ `[D7]` |
| 0:22 | — | game | `Party Party joined (325496)` / `Party State Not ready` | **PARTY JOINERED — membership complete** | ❌ `[D7]` |

**At this point the join is functionally DONE.** Everything below (B3) is voice-only.

### B3 — EOS re-join HOST lobby for VOICE only (00:22, AFTER party join)

| t | src → dst | plane | event | meaning | partydeck |
|---|-----------|-------|-------|---------|:--------:|
| 0:22 | JOINER → EOSsrv | EOS(HTTP) | `GetLobby GET …/lobbies/325496` → 200 | look up host's EOS lobby (id == host code) | ❌ `[D7]` |
| 0:22 | JOINER → EOSsrv | EOS(WSS) | `Opening Lobby Socket`, `SendMessage Type: join` | join host's EOS lobby record | ❌ `[D7]` |
| 0:22 | EOSsrv → JOINER | EOS | `Lobby RTC Room info set. LobbyId=[325496] RoomName=[conf+1507893467]` | host's voice room | ❌ `[D4]` `[D7]` |
| 0:22 | JOINER → EOSsrv | EOS(RTC) | `RTCRoom JoinRoom …` → ICE → Connected | join host's WebRTC voice | ❌ `[D4]` `[D7]` |
| 0:22 | — | game | `EOS: _OnLobbyJoined (eConnected)` | **EOS voice join — LAST step** | ❌ `[D7]` |
| 0:23 | EOSsrv → JOINER | EOS(RTC) | `Participant connected … ParticipantId=[000…9e8]` | host's voice participant appears | ❌ `[D4]` `[D7]` |
| 0:22 | JOINER ↔ STORM | RakNet | reconnect `matchmaking` scene | shared gamefinder for the merged party | ❌ `[D7]` |

---

## Divergence notes (partydeck EOS-emu + Goldberg build)

- **`[D1]` EOS auth is local, not HTTP.** Online does real `api.epicgames.dev` `TokenGrant` HTTP 200;
  offline the NEE emu satisfies auth locally (`EOS: Authenticating using external account` →
  `Connected`). Functionally equivalent (game proceeds identically). ⚠️ benign.
- **`[D2]` RakNet target is the local broker.** Online connects to `dt-live.passtechgames.com:30100`;
  offline the same hostname resolves to `127.0.0.1:30100` (our `raknet.py`). Same wire protocol. ✅.
- **`[D3]` NAT type differs harmlessly.** Online `EOS_NAT_Moderate`; offline emu reports
  `EOS_NAT_Open`. No effect on join. ⚠️ benign.
- **`[D4]` No EOS RTC / voice room offline.** The emu has no RTC implementation
  (`EOS_Lobby_GetRTCRoomName → EOS_NotImplemented`, `GetRTCInterface → nullptr`). So every
  `RTCRoom*` / `conf+…` / WebRTC step is absent. The game tolerates this ("no voice") and still
  reaches `Party State | Not ready` and `_OnLobbyCreated`. **Voice will never work offline, but it is
  not required for the join.** ❌ for the literal RTC steps, but non-blocking.
- **`[D5]` Own-lobby destroy works offline.** The emu logs `DestroyLobby erasing LobbyId='161837'` →
  `queued 1 CLOSED notif` → `Callback ready: EOS_Lobby_DestroyLobbyCallbackInfo`, and the game logs
  `EOS: _OnLobbyDestroyed`. The destroy itself is NOT the problem. (No real WSS `delete` — the emu
  tears down locally; ⚠️ on the websocket line, ✅ on the callback.)
- **`[D6]` No RTC `Conference End` offline — now believed a RED HERRING** (consequence of `[D4]`).
  Online, destroy also triggers `RTCRoom LeaveRoom → Conference End (Successful Disconnect)`, and
  offline that completion never comes. **However**, the wire/engine evidence shows the joiner
  *removes* the `EOS_RTC_DisconnectedCallbackInfo` handler (Id 47) **immediately before** `LeaveRoom`,
  i.e. it does **not** await the RTC disconnect; and the online continuation to B2 fires in the same
  `00-00-20` tick as `_OnLobbyDestroyed`, before any RTC completion. Offline there is no RTC room at
  all. So the missing RTC completion is **unlikely** to be the gate. Deprioritised — keep only as a
  fallback if the managed/EOS-notify suspects are disproven.
- **`[D7]` ⛔ THE CORE FAILURE: B2/B3 never start.** After `_OnLobbyDestroyed`, the offline build
  emits **nothing** on any plane — verified in all three captures:
  - STORM (broker): both connections send only `ID_PING`/`ID_CONNECTED_PING`; never
    `DISCONNECT_FROM_SCENE`, never `0x8e`.
  - EOS emu: only idle `on_lobby_update` + P2P `type=5` heartbeats; no `JoinLobby`, no further calls.
  - STEAM: no `Leaving lobby`, no `Join lobby`.
  The managed (C#) join coroutine does not advance from the EOS destroy callback into the native
  Stormancer "leave own party → `0x8e :: <code>` → connect host party" step. **This is the one bug to
  fix.** It is NOT a missing network response (JOINER never sends the next request), so the fix is in
  getting the managed continuation to run. Offline this is **not an instant abort**: the engine log
  goes silent for ~19 min, then the idle RakNet link times out (`Peer lost the connection` /
  `state changed [0, reason: timeout]`), all scenes are destroyed, and a reconnect-fail loop
  (`ID_CONNECTION_ATTEMPT_FAILED` ×52) runs forever. Leading suspect: a spurious self-`CLOSED`
  member-status our deferred-notify destroy emits for the lobby owner (see
  `flow_offline_current.md`).
- **`[D8]` Broker is READY but never exercised.** `raknet.py` already implements
  `SR_DISCONNECT_FROM_SCENE` ACK (`REQUEST_RESPONSE_MSG`+`COMPLETE`), the `0x8e`
  `CreateConnectionTokenFromInvitationCode` resolver, and the real `0x90 :: default` merger-status
  shape. These are correct but sit downstream of `[D7]`, so they never fire. Once `[D7]` is fixed
  these should carry the join.
- **`[D9]` Goldberg cross-join is unverified.** Online, the joiner joins the host's Steam lobby
  (`Join lobby [109775242660736055]`). Offline both instances share the host net namespace and
  Goldberg LAN-discovers the other's lobby (the emu already lists `known lobbies=[161837 705777]`),
  but the actual `Join lobby` step is never reached (blocked by `[D7]`), so Goldberg lobby-join across
  instances has not yet been proven end-to-end. To watch once `[D7]` clears.

---

## Critical ordering facts (for the offline fix)

1. **Party membership lives in STORMANCER, not EOS.** The actual join is
   `0x8e :: <code>` → host-party scene-connect token → `Connected to scene [party-<HOST>]`.
2. **EOS `_OnLobbyJoined` is the LAST step and is voice-only.** It happens *after* `Party joined`.
   Spontaneously firing it offline would NOT create party membership.
3. The trigger order inside "Joining with code" is:
   `_OnLobbyDestroyed (own EOS lobby)` → **`DISCONNECT_FROM_SCENE` ×2 (+server ACK)** →
   **`0x8e :: <code>` (+token)** → `Connect to [host party]` → `Party joined` → (voice) `_OnLobbyJoined`.
4. The server ACKs (`COMPLETE` for the disconnect reqIds, and the `0x8e` token reply) are the
   continuations the native client awaits before advancing. A broker that does not ACK these will
   stall the joiner exactly where the offline build stalls.

See `flow_offline_current.md` for where the partydeck build diverges.
