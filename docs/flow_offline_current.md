# Ravenswatch co-op join — CURRENT partydeck / offline flow (where it hangs)

> **These are working notes, NOT the authoritative record.** The packet captures and their CSV
> decodes in `pcaps/` (`join_offline_*.csv`, `join_fwd_*.csv`, `join_online_*.csv`) are ground
> truth for what actually went on the wire; engine/emu/broker text logs corroborate. Where this
> note disagrees with a capture, the capture wins. Claims below have been revised across several
> runs — superseded hypotheses are kept and marked `~~struck / SUPERSEDED~~` so we don't re-test them.

Same two-account join, but offline through partydeck (NEE EOS emu + Goldberg Steam + local
`raknet.py` Stormancer broker). Reconstructed from real captured logs across multiple failing runs
(the symptom is identical every time):

- JOIN engine logs: `profiles/Elsie/…/Ravenswatch/_Logs/logs_*.txt` (identify the run by mtime).
- EOS emu log: `profiles/Elsie/…/Ravenswatch/nemirtingassteamemu.log`.
- Broker decoded log + capture: live `raknet.py` decode (C1 = Dad/HOST conn, C2 = Elsie/JOIN conn)
  and `pcaps/join_fwd_*.csv` / `join_offline_*.csv`.

Compare against `flow_working_online.md`. **Phase A is reproduced correctly. Phase B's managed
continuation never starts.** After `_OnLobbyDestroyed` the engine log goes completely silent and
JOIN sends nothing but keep-alive pings to the broker. If left alone the idle RakNet link
eventually times out (~19 min in the original capture) and a reconnect-failure loop runs forever;
in later runs the silence simply lasts until the broker is shut down manually (~80–90 s) — **the
trailing timeout/teardown is just shutdown noise, not part of the bug.** The hang itself is the
open-ended silence after the EOS destroy callback.

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
| 0:08 | JOIN → EOSemu | EOS | `EOS_Lobby_GetRTCRoomName -> 'conf+partydeck' (EOS_Success)` | emu now returns a stub RTC room name (parity with online) |

EOS emu lobby bookkeeping (current build):
`CopyLobbyDetailsHandle wants LobbyId='161837' ; known lobbies=[161837 ]`
→ **own lobby only.** Earlier builds also pre-registered the HOST's lobby here
(`known lobbies=[161837 705777 ]`) because the two co-located emu instances cross-announce their
EOS lobbies over the emu UDP net. `on_lobby_update` now **IGNOREs** unsolicited remote announces, so
JOIN's `_lobbies` matches the online reference (own-only) at join time. **The hang is unchanged**
with or without the host pre-registered → that pollution was a red herring (see candidates below).

**RTC (was flagged as a benign difference, now PARITY):** the emu's `GetRTCRoomName` previously
returned `NotImplemented`; it now returns `conf+partydeck (EOS_Success)`. This made no difference to
the hang — online the joiner *removes* the RTC disconnect handler before leaving the room, so the
join is not gated on RTC anyway.

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
| 00-00-20 | JOIN → EOSemu | EOS | `DestroyLobby erasing LobbyId='161837'` → `queued 0 CLOSED notif(s) (self skipped)` → `Callback ready: EOS_Lobby_DestroyLobbyCallbackInfo` | own EOS lobby destroyed, callback delivered ✅ |
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

- **Decisive:** the EOS emu trace now matches the WORKING Config C run (`docs/captures_configC/`)
  step-for-step — same `CreateLobby` → `CopyLobbyDetailsHandle(own)` → `DestroyLobby` →
  `DestroyLobbyCallbackInfo` delivered — and the join **still hangs**. Config C uses the SAME emu
  with a REAL backend and WORKS; offline uses the broker and hangs. So the divergence is downstream
  of EOS.
- The emu delivered the `DestroyLobby` completion callback. (Earlier builds also queued a self
  `CLOSED` member-status to `handlers=1`; that is now **skipped** — `queued 0 CLOSED (self skipped)`
  — and Config C, which also skips it, works. The self-`CLOSED` theory is disproven.)
- The data needed to join is present either way; pre-registering the host lobby is no longer done
  (`known lobbies=[161837 ]`, own-only) and the hang is unchanged.
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

## Candidate root causes (ranked, with what the captures have RULED OUT)

1. ~~**Spurious self-`CLOSED` member-status from the deferred-notify destroy fix.**~~ **SUPERSEDED /
   DISPROVEN.** `DestroyLobby` now skips the self `CLOSED` (`queued 0 CLOSED (self skipped)`), and the
   WORKING Config C run also skips it — yet offline still hangs and Config C works. Not the gate.
2. ~~**EOS host-lobby pre-registration pollutes `_lobbies`.**~~ **SUPERSEDED / DISPROVEN.**
   `on_lobby_update` now IGNOREs unsolicited remote announces, so `_lobbies` is own-only at join time
   (matches online). Hang unchanged. Not the gate (it only mattered at search time, which never runs).
3. ~~**RTC is a red herring / missing room.**~~ **SUPERSEDED.** Emu now returns
   `GetRTCRoomName = conf+partydeck (EOS_Success)` (parity); online removes the RTC disconnect handler
   before leaving, so the join is not gated on RTC. No effect on the hang.
4. **LEADING: the managed `JoinByCode` coroutine never advances to SUBMIT the code.** Authoritative (`pcaps/join_online_102258.csv` WORKS vs
   `pcaps/join_fwd_211504.csv` HANGS):
   - Online: `0x8e` has a **route-1** exchange (register/token) **and** a **route-2** exchange that
     submits the host code (`0x8e 0 | 2 | 0 | '631790' | {RequestedHero…}`) → reply carries the
     host-party connect token (`{"endpoints":{"raknet":[…]}}`). That route-2 submit IS the join.
   - Offline: `0x8e` has **only route-1** exchanges (×2), and the broker **completes each one**
     (`RAKNET->JOINER  SCENE h=0x8e 0 | 1 | 1 | 0`). There is **NO route-2 code submission at all.**
   So the broker completed every RPC the joiner actually sent — **the earlier "missing `route=1`
   completion" idea is refuted by the capture.** The real gap is upstream: the managed coroutine
   never reaches the point of emitting `DISCONNECT_FROM_SCENE` + the `0x8e` route-2 code submit.
   **Open question / next test:** is the offline route-1 *reply* (decoded as bare `0`) materially
   different from online's route-1 reply (which carries a token), and could that stall the coroutine
   before route-2? Inspect the raw route-1 payloads (`raw_hex` column) online vs offline next.

### What the authoritative captures have RULED OUT (do not re-test)

- **PartyMerging.GetMergerStatus counts are NOT the gate.** Our broker answers `partiesCount=1,
  playersCount=1`; the real backend's counts **vary as live-pool noise** (online capture showed
  `2/4`, `1/1`, `2/4`, `0/0` across one minute) and online even returned **`1/1`** (identical to
  offline) at t=28 and the join still worked. The count is informational ("X players searching" UI);
  the game does not gate a user's explicit join-by-code on it. Confirmed by `raknet.py`
  `build_merger_status` comment + `pcaps/join_online_102258.csv`.
- **Phase-A matchmaking scene is well replicated.** Offline (`pcaps/join_fwd_211504.csv`, handle
  `0xa0`) the broker pushes the full set: party state arrays, per-member `RequestedHero/PlayerName`
  userdata, `CreateInvitationCode` results, `partyDataToken`, and steady `GetMergerStatus` polls —
  matching the online matchmaking scene's shape. So the joiner reaches the same idle "registered in
  game finder" state online and offline before the click.
- **The hang has no server→client gate at the click.** In the online capture the post-destroy steps
  (`DISCONNECT_FROM_SCENE` ×2 → `0x8e` code submit) are all **client→server** with no inbound
  message required between `_OnLobbyDestroyed` and the first `DISCONNECT_FROM_SCENE` (same tick). So
  offline's failure to emit them is a **synchronous managed continuation that does not run** — caused
  by either (a) a state value our broker/Goldberg set during Phase A that makes the coroutine bail,
  or (b) a thrown exception (Proton `+seh` shows a C++ throw `0x20474343` near the click). Since the
  EOS emu is exonerated (Config C uses it with the real backend and works), the Phase-A state must
  come from the **broker or Goldberg**.

> **Reliability caveat for these CSV diffs:** Stormancer scene *handles* (the `h=0x8e`/`0x90`/`0xa0`
> byte) and *route numbers* are assigned per session, so they COLLIDE across captures (offline
> `0x8e` is a different scene than online `0x8e`). Compare by route **name** (the `RouteMappings`
> blocks and the broker's `rname` log), never by raw handle/route number across two runs.
5. **A Goldberg Steam matchmaking gate (NOW co-equal suspect, not a fallback).** **Config C only
   exonerates the EOS emu** — it ran our emu against the **REAL** Stormancer backend
   (`dt-live.passtechgames.com:30100`) **and REAL Steam** (its emu log shows `known lobbies=[own]`
   only, i.e. no co-located peer). Offline differs from Config C in **two** planes at once: the
   `raknet.py` broker **and** Goldberg (plus co-location side-effects on the emu's own UDP net). So
   raknet.py and Goldberg are **both** still suspects; "EOS ruled out" does **not** narrow to the
   broker. To isolate, change ONE plane vs Config C (real-Stormancer + Goldberg, or our-broker +
   real-Steam) and see which reintroduces the hang.

**Where the stall actually is (authoritative, from the captures):** in ALL offline captures there are
**zero** `DISCONNECT_FROM_SCENE` messages, and the merger-status polls **continue to end-of-capture**
(online they **stop** at the join click because the game leaves the matchmaking scene first). So the
game hangs **before** the first `DISCONNECT_FROM_SCENE`, while **still in its own matchmaking scene**.
The online teardown is driven **locally** off the join click (no inbound server message gates the
first disconnect), so offline the game is parked on a **local callback** owed by the emu or Goldberg
— not on a missing wire reply. The objective remains to get the coroutine to advance to the first
`DISCONNECT_FROM_SCENE`.
