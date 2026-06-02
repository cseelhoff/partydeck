# Ravenswatch co-op join — CURRENT partydeck / offline flow (where it hangs)

Same two-account join, but offline through partydeck (NEE EOS emu + Goldberg Steam + local
`raknet.py` Stormancer broker). Reconstructed from real captured logs of the failing run:

- JOIN engine log: `profiles/Elsie/…/Ravenswatch/_Logs/logs_2026-06-02_13h-24m-23s.txt`.
- EOS emu log: `profiles/Elsie/…/Ravenswatch/nemirtingassteamemu.log`.
- Broker decoded log: live `raknet.py` decode (C1 = Dad/HOST conn, C2 = Elsie/JOIN conn).

Compare against `flow_working_online.md`. **Phase A is reproduced correctly. Phase B's managed
continuation never starts — and the join does NOT fail instantly: the engine log goes completely
silent for ~19 minutes, then the idle RakNet link to the broker times out, every scene is torn
down, and a reconnect-failure loop runs forever.** The full network detail of that sequence is
below (it was previously mis-summarised as an "instant hang").

---

## Actors / planes (offline stand-ins)

| Symbol | Actor | Offline identity |
|--------|-------|------------------|
| **HOST** | Hosting client | Profile **Dad**, EOS PUID `d5a26726…6269`, code **705777** (this run) |
| **JOIN** | Joining client | Profile **Elsie**, EOS PUID `3b2ac1e8…e2f0`, own code **161837** |
| **EOSemu** | local NEE EOS emulator DLL | `EOSSDK-Win64-Shipping.dll` in each gamesave; logs `nemirtingassteamemu.log` |
| **STORM** | local Stormancer broker | `src/raknet.py` on UDP `127.0.0.1:30100` (C1=HOST conn, C2=JOIN conn) |
| **STEAM** | Goldberg Steam emu | `steamclient64.dll`; LAN-discovers the other instance |

---

## Phase A — JOIN boots and creates its own party  ✅ REPRODUCED

This matches the working flow step-for-step (just with local stand-ins).

| t | src → dst | plane | event (from logs) | meaning |
|---|-----------|-------|-------------------|---------|
| 0:00 | — | game | `Build version 1.05.00.05` / `EOS_P2P_SetRelayControl AllowRelays` | engine boot |
| 0:01 | JOIN → EOSemu | EOS | `EOS: Authenticating using external account` | emu auth (local) |
| 0:03 | JOIN → STEAM | STEAM | `Steam: GetAuthTicketForWebApi k_EResultOK` | Goldberg fake web ticket |
| 0:03 | JOIN → EOSemu | EOS | `EOS: Connected (external account)` PUID `3b2ac1e8…` | emu connect OK |
| 0:03 | JOIN → STORM | RakNet | `connecting to dt-live…:30100` → `ID_CONNECTION_REQUEST_ACCEPTED from 127.0.0.1:30100` | RakNet to **local broker** (C2) |
| 0:03 | JOIN → STORM | RakNet | `session id acquired [5pFChxA0…]` | broker issued session |
| 0:03 | JOIN ↔ STORM | RakNet | connect `authenticator`, `friends` scenes | broker scene handshakes |
| 0:05 | JOIN → EOSemu | EOS | `EOS_P2P_QueryNATType: EOS_NAT_Open` | emu P2P |
| 0:07 | — | game | `Lobby Host: true Enter StateHeroSelection` / `Party State | Creating with code` | JOIN hosts itself |
| 0:07 | JOIN ↔ STORM | RakNet | connect `party-manager`, `party-e271061d` (own party) | broker party scenes |
| 0:07 | JOIN → STEAM | STEAM | `Creating steam lobby [… metadata={partyDataToken=<b64>}]` | Goldberg lobby + token |
| 0:07 | STEAM → JOIN | STEAM | `Steam lobby created [109775242429132357]` | Goldberg lobby id |
| 0:08 | JOIN ↔ STORM | RakNet | connect `matchmaking`; broker assigns code | gamefinder register |
| 0:08 | STORM → JOIN | RakNet | `Party | Generated invitation code: 161837` | broker `CreateInvitationCode` |
| 0:08 | — | game | `Party State | Not ready` | JOIN idle in own party |
| 0:08 | — | game | `EOS: _OnLobbyCreated (eConnected)` | emu lobby create OK |
| 0:08 | JOIN → EOSemu | EOS | `ERROR EOS_Lobby_GetRTCRoomName : EOS_NotImplemented` | **no RTC room** (emu has no voice) — non-fatal, game continues |

EOS emu confirms the lobby bookkeeping:
`CopyLobbyDetailsHandle wants LobbyId='161837' ; known lobbies=[161837 705777 ]`
→ both JOIN's own (161837) and HOST's (705777) lobbies are visible to the emu (Goldberg LAN
discovery surfaced the host's lobby).

**Difference vs online (benign):** online, lobby creation also builds an RTC voice room; offline the
emu returns `GetRTCRoomName = NotImplemented`, so JOIN's own lobby has **no RTC room**. The game
treats this as "no voice" and proceeds (it reached `Party State | Not ready` and ran 12 s further).

---

## Phase B — THE JOIN CLICK : enter HOST code 705777  ❌ MANAGED CONTINUATION NEVER RUNS

The boot RakNet handshake to the broker **succeeds** and all Phase-A scenes connect. The instant the
join coroutine fires `_OnLobbyDestroyed`, the managed (C#) `JoinByCode` continuation freezes — it
never issues the native Stormancer `DISCONNECT_FROM_SCENE`. ~19 minutes later the now-idle RakNet
link times out and the whole session unwinds.

### B0 — exact engine-log timeline (offline JOIN = Elsie)

| t (mm-ss) | src → dst | plane | event (verbatim) | meaning |
|-----------|-----------|-------|------------------|---------|
| 00-00-03 | JOIN → STORM | RakNet | `connecting rakpeer to dt-live…:30100` → `Received ID_CONNECTION_REQUEST_ACCEPTED from 127.0.0.1:30100` | **boot handshake to broker SUCCEEDS** ✅ |
| 00-00-03..08 | JOIN ↔ STORM | RakNet | `Connected to scene [authenticator]`, `[friends]`, `[party-manager]`, `[party-e271061d]` (own), `[matchmaking]` | all Phase-A scenes up ✅ |
| 00-00-20 | — | game | `Stormancer | Party State | Joining with code (705777)` | **join coroutine starts** |
| 00-00-20 | JOIN → EOSemu | EOS | `DestroyLobby erasing LobbyId='161837'` → `queued 1 CLOSED notif` → `Callback ready: EOS_Lobby_DestroyLobbyCallbackInfo` | own EOS lobby destroyed, callback delivered ✅ |
| 00-00-20 | — | game | `EOS: _OnLobbyDestroyed` | **managed destroy callback fired** |
| — | — | — | **⛔ ENGINE LOG EMITS ZERO LINES FOR ~19 MINUTES ⛔** | managed `JoinByCode` continuation is blocked |
| 00-19-19 | STORM → JOIN | RakNet | `RakNetTransport | Peer lost the connection [127.0.0.1:30100]` | **idle link times out** (no app traffic kept it alive) |
| 00-19-19 | — | game | `connection | Game connection state changed [0, reason : timeout]` | Stormancer marks the federation connection dead |
| 00-19-19 | — | game | `Scene destroyed [authenticator] / [friends] / [party-manager] / [matchmaking]` | all scenes torn down by the timeout |
| 00-19-19 | — | game | `authentication | Failed updating user options 'crossplay' [task_canceled]` | in-flight tasks cancelled |
| 00-19-19 | — | game | `RpcService | Failed to send rpc 'party.getpartystate2' [The scene is not connected]` | party state poll now fails |
| 00-19-19 | — | game | `oCStormancerSceneContext::_UpdatePartyMemberData / _UpdatePartyData - Exception Caught : task_canceled` | managed party context unwinds |
| 00-19-20 | — | game | `PartyService::syncPartyStateTaskWithRetries | … [Exception: The scene is not connected]` | retry loop begins |
| 00-19-20 | JOIN → STORM | RakNet | `connecting rakpeer to dt-live…:30100` → `Received ID_CONNECTION_ATTEMPT_FAILED from 127.0.0.1:30100` (**×52, forever**) | **post-timeout reconnect handshake now FAILS** ❌ |
| 00-19-20 | JOIN → STEAM | STEAM | `Steam | Leaving lobby [109775242429132357]` | leave own Goldberg lobby (during unwind) |

> **Key correction:** this is **not** an instant hang and **not** a missing RakNet *response*. JOIN
> never *sends* `DISCONNECT_FROM_SCENE`, so nothing inbound is awaited. The 19-minute gap is purely
> the RakNet idle-timeout of a connection the managed layer stopped driving. The first handshake
> (00-00-03) is **accepted**; only the *reconnect* after the timeout (00-19-20) is refused.

### What the three planes actually do during the 19-minute freeze

| plane | expected next (from working flow) | actually observed offline |
|-------|-----------------------------------|---------------------------|
| **EOS** | (own RTC teardown only — N/A offline) | EOS tick thread STAYS ALIVE: of 2807 emu-log lines, the 2582 after the destroy callback are **only** `on_lobby_update ENTRY/EXIT` (×568 — inbound P2P lobby broadcasts from Dad) + `process_udp type=5` heartbeats. **Zero game-initiated EOS calls.** No JoinLobby, no LobbySearch, no CopyLobbyDetailsHandle(705777). |
| **STORM** | `DISCONNECT_FROM_SCENE` ×2 → `0x8e :: 705777` → connect `[party-<HOST>]` | only `ID_PING` / `ID_CONNECTED_PING` on C1 and C2 until 00-19-19, then the timeout/teardown/reconnect-fail loop above. JOIN never sends `DISCONNECT_FROM_SCENE`, never `0x8e`. |
| **STEAM** | `Leaving lobby` (own) → `Join lobby` (host) | own lobby created at boot (`Steam lobby created [109775242429132357]`); host's lobby is **never seen** (no `Lobby data updated [host]`, no `Join lobby [host]`). Own lobby only left at 00-19-20 during the timeout unwind. |

Broker log during the freeze (both connections idle until the timeout):
```
[C2:JOIN]  ID_SYSTEM_REQUEST ID_PING reqId=… → RESPONSE ping        (every ~5s)
[C1:HOST]  ID_SYSTEM_REQUEST ID_PING reqId=… → RESPONSE ping        (every ~5s)
(… no 0x8e, no DISCONNECT_FROM_SCENE, no CreateConnectionTokenFromInvitationCode, ever …)
```

### Why EOS is NOT the blocker (evidence)

- The emu delivered **both** the `DestroyLobby` completion callback **and** the `CLOSED` member-status
  to a **registered** handler: `member_status deliver lobby='161837' member='3b2ac1e8…e2f0' status=5
  handlers=1`.
- Elsie's emu had **already discovered the host lobby**: `CopyLobbyDetailsHandle wants
  LobbyId='161837' ; known lobbies=[161837 705777 ]`. The data needed to join is present.
- The EOS callback dispatch (`callback_manager.cpp` `run_callbacks`, lines 171-220) holds
  `GLOBAL_LOCK` (a `std::recursive_mutex`, `helper_funcs.h:32-34`) while invoking the game's
  completion lambda inline — but a recursive mutex permits same-thread re-entry, and the tick thread
  keeps running `on_lobby_update` 568 times afterwards, so **EOS is not deadlocked**.
- Therefore EOS gave the managed layer everything it owed; the block is in the **game's managed
  `JoinByCode` coroutine**, waiting on something that is **not** an EOS callback.

---

## The precise divergence

| | Working (online) | Offline (partydeck) |
|---|---|---|
| `Joining with code` | fires | fires |
| destroy own EOS lobby → `_OnLobbyDestroyed` | ✅ | ✅ (emu delivers callback) |
| `Scene destroyed [own party]` (native Stormancer leave) | ✅ next | ❌ never |
| `DISCONNECT_FROM_SCENE` ×2 → server `COMPLETE` | ✅ | ❌ never sent |
| `0x8e :: <code>` → host-party connect token | ✅ | ❌ never sent |
| `Connected to scene [party-<HOST>]` | ✅ | ❌ never |
| `Party joined` | ✅ | ❌ never |
| EOS `_OnLobbyJoined` (voice, last) | ✅ | ❌ never |

**The stall is between `EOS: _OnLobbyDestroyed` and the native Stormancer
`Scene destroyed [own party]` / `Get private scene [host party]`** — i.e. before the joiner
contacts the broker at all. In the WORKING online log this continuation is **immediate** (same
`00-00-20` tick, no await gap): `_OnLobbyDestroyed` → `Scene destroyed [own party-59a029a1]`
(= wire `DISCONNECT_FROM_SCENE`) → `Steam | Leaving lobby [own]` → `Get private scene [host
party-81bfb94c]` → `Connecting/Connected` → `Steam | Join lobby [host]` → `Party joined`. Offline,
**none** of it runs. Because nothing is emitted on the wire, the broker upgrades
(`DISCONNECT_FROM_SCENE` ACK, `0x8e` resolver, merger status) are **correct but never exercised** —
they sit downstream of the freeze.

---

## Is JOIN waiting on a network response it never gets?

**Not on RakNet — but yes, the managed coroutine is blocked on *something* (just not an inbound
packet).** Verified against all three captures:

- **STORM:** JOIN never *sends* the next request (`DISCONNECT_FROM_SCENE` / `0x8e`), so it is not
  blocked awaiting a broker reply — there is no outstanding request. The boot handshake was
  *accepted*; the 19-minute silence is just the idle link timing out, not a pending round-trip.
- **EOS:** after `_OnLobbyDestroyed` there are **zero** further EOS calls and no pending EOS
  request; both the destroy callback (`DestroyLobbyCallbackInfo`) and the `CLOSED` member-status
  (`handlers=1`) were already delivered, and the EOS tick thread keeps running. EOS is not the gate.
- **STEAM:** offline JOIN never reaches the host's Steam lobby at all — but that is *downstream* of
  the freeze, not its cause.

So this is a **managed-side (C#) continuation that does not advance** from the EOS destroy callback
into the native Stormancer "leave own party → join host party by code" step. Earlier this was
mis-summarised as "not waiting on anything"; more precisely, the coroutine *is* awaiting a
continuation that, online, fires synchronously in the same tick — and offline never does.

---

## Candidate root causes to investigate next (ranked)

1. **Spurious self-`CLOSED` member-status from our deferred-notify destroy fix.** Our
   `eossdk_lobby.cpp` `DestroyLobby` queues a `CLOSED` member-status for **JOIN itself** (the lobby
   owner) when it destroys its *own* lobby (`member='3b2ac1e8…e2f0' status=5 handlers=1`). Real EOS
   normally gives the destroying owner only the `DestroyLobby` completion — *other* members get
   `CLOSED`. A self-`CLOSED` arriving mid-join could make the managed state machine treat itself as
   kicked and abort the continuation. **Cheapest decisive test:** suppress the self-member `CLOSED`
   (keep it only for other members) while still firing the destroy success callback; rebuild,
   redeploy, reproduce.
2. **A Goldberg Steam matchmaking gate.** Online, the continuation interleaves `Steam | Leaving
   lobby [own]` then `Steam | Join lobby [host]`; offline JOIN never sees the host's Steam lobby. If
   the managed `JoinByCode` awaits a Goldberg lobby callback/state (own leave done, or host-lobby
   discovery) before driving Stormancer, the release-build Goldberg may never satisfy it offline.
   Confirm whether Goldberg surfaces the host lobby to the joiner instance.
3. **The destroy callback shape/ordering does not satisfy the C# `await`.** `_OnLobbyDestroyed` ran,
   but verify the emu fires the *completion delegate the coroutine awaited* (not just a side
   notification), with `ResultCode = EOS_Success`, in the order the managed code expects relative to
   the `CLOSED` notification.
4. **RTC is a RED HERRING offline (deprioritised).** Online, the joiner *removes* the
   `EOS_RTC_DisconnectedCallbackInfo` handler (Id 47) **before** `RTCRoom LeaveRoom`, so it does
   **not** await the RTC disconnect; and offline there is no RTC room at all (`GetRTCRoomName =
   NotImplemented` at create → no `JoinRoom`). So the missing `Conference End` is unlikely to be the
   gate. Keep only as a fallback if (1)-(3) are disproven.

The fix is most likely in the **EOS emu** (`/home/caleb/epic_emu`) around lobby destroy/notify
delivery — but **not** by spontaneously firing `_OnLobbyJoined` (that is the trailing voice step and
would not produce Stormancer party membership). The objective is to get the managed coroutine to
advance so the native Stormancer client emits `DISCONNECT_FROM_SCENE` + `0x8e :: <code>` to the
broker, which is already prepared to answer them.
