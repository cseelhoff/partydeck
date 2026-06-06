# 700ms Relay Capture Patterns

Latest source run: successful full multiplayer relay capture from 2026-06-05 around
22:37 (working raw-delay relay; C1 = laptop 10.1.1.117 / Elsie, C2 = desktop
10.1.1.129 / Major Hoff). Captured with `RELAY_RESP_WAIT_MS=700` (response-grouping
window). Note: `RELAY_GATE_MS` was 0 (no injected send delay) for this run, so the
700ms here is response-collection grouping, not send spacing.

Files examined:
- `/tmp/pdlog/probe/relay_capture.jsonl`
- `/tmp/pdlog/probe/predict_caleb.json`

Relay summary (pings/health already filtered out of transaction logs):
- Relay capture rows: 388 total.
- Prediction records: 140 total, 123 true and 17 false with the strict matcher.
- Peer record counts: C1 has 61 transactions, C2 has 79 transactions.
- The matcher is order-insensitive (multiset match), so none of the 17 failures are
  ordering issues -- every failure is a wrong/extra predicted message or a missing
  real message.

Earlier run (2026-06-05 ~18:35, pre-final relay): 201 records (141/60), or 146
(89/57) after also filtering Stormancer system pings. Kept for history only.

## Peer Identities

In this run, peer label order did not match the older canonical capture:

- `C1` is the first connected client, laptop / Elsie.
- `C2` is the second connected client, desktop / Major Hoff.

Do not infer identity from `C1` or `C2`. Peer labels are connection-order labels only. Identity should be learned from `Authentication.Login`, party userdata, SteamID, or EOS/user id fields.

Useful stable identities:
- Elsie: user id `9fe2fc1fa18643e2818bbd65198d4b00`, SteamID `76561199572083022`, EOS id `000239105cf443abbdf0238c827bd9e8`.
- Major Hoff: user id `4168ffb24de245f88060d27c9580685e`, SteamID `76561197977870267`, EOS id `0002ea2c70fa4f89a5d876065a55c786`.

### Identity decoupling fix (2026-06-05)

The two humans are always Elsie (identity `"C1"`) and Major Hoff (identity `"C2"`);
only their *connect order* swaps between runs. Therefore the hardcoded `"C1"`/`"C2"`
literals inside the body builders (`user_id_for_peer`, `party_userdata_json_template`,
etc.) are correct *identities*. The bug class on a connect-order-swapped run is only
where the predictor used the *connection label* `txn.label` as if it were the
identity.

Fix (live `predict_caleb_step` only):
- At the `Authentication.Login` site (route 6, handle 141) the canonical identity from
  the Steam ticket is now stored into `peer_identities` via `predict_caleb_set_identity`,
  so identity is known *early* (before any party userdata is sent).
- Self-identity body sites now translate `txn.label` -> canonical identity via
  `predict_caleb_identity_label`: `steam_create_lobby_body` (CreateLobby partyDataToken),
  the handle-144 self `party_memberdata_body_with_userdata`, the handle-146 rpc 2049
  `party_member_connected_body_with_userdata`, the handle-144 rpc 257 captured
  `party.memberConnected`, and `party_state_response_learned`/`party_state_response_raw`.
- `predict_caleb_userdata_for_label` now looks up learned userdata by *connection label*
  (the real client bytes) but falls back to the template by *identity*.

Left untranslated on purpose (role/join-sequence dependent, not pure self identity):
the hardcoded `"C2"`/`"C1"` literal `party_memberdata_body` calls at handle 145 and the
`party_memberdata_body("C2", 20, 13, ...)` at route 6. These encode a host/joiner join
sequence and must not be translated blind; they need live validation first.

The offline `predict_caleb` replay path is intentionally unchanged (it lacks the
early-login identity infrastructure and is an unreliable validator for gated captures).
Validate this fix against a fresh **live** `predict_caleb.json` only.

### Structural party member-status counter (2026-06-05)

`party.memberStatusUpdated` broadcasts (scene route 8) carry an `rpc_id` and a party
`version` that the real server assigns from a *single global monotonic counter*, in the
order members actually ready — **not** by peer label. In one live run the broadcasts form
a clean sequence: rpc `13,14,15,16,17,18` with `version` bumping every two broadcasts
(`10,10,11,11,12,12`). Each ready event is delivered to both connections (one broadcast
per scene), so each event consumes two consecutive `rpc_id`s sharing one `version`.

The route-9 (`party.updategamefinderplayerstatus`) handler emits the *self*-broadcast (the
member being told its own ready registered). Those two self-broadcasts get the middle
values `rpc 14 / v 10` (first member to ready) and `rpc 15 / v 11` (second). The old code
hardcoded them by handle (`144 -> rpc 15`, `146 -> rpc 14`), which is backwards whenever
the ready order differs from the assumed order — the exact `idx96`/`idx100` symmetric swap.

Fix: a monotonic `ready_status_seq` counter (field on `Predict_Caleb_Live`; a local in the
offline path) assigns `rpc 14+seq` / `version 10+seq` in arrival order. The matcher passes
route 8 on `rpc_id` alone (dynamic party route), so correcting the `rpc_id` ordering is
sufficient to flip `idx96`/`idx100` to match. Expected: live `137/112/25 -> 137/114/23`.

NOT fixed (deliberately, would require window-attribution overfitting): the *cross*-peer
deliveries of the same events (`idx95/99/101/102`) — which 700ms window the broadcast of
the *other* peer's ready lands in is timing-governed, not a counter problem. Validate the
counter against a fresh **live** `predict_caleb.json`.

Validated 2026-06-05 (swapped-order live run with one user retry, 165/132/33): the
version-drift class dropped from 5 failures to 1, and the self-broadcast now matches in the
opposite ready order (`idx123` C2/Elsie readied first → `rpc14/v10`, predicted correctly).
The route-9 gate was then generalized from the hardcoded `scene_handle == 144 || 146` to
`scene_handle >= 144 && route_name == "party.updategamefinderplayerstatus"` so the same
counter also covers a **retry**-allocated party scene handle (e.g. `148`) without misfiring
on a non-party scene. The remaining failures in that run are retry artifacts (extra async
re-join pushes; a create-vs-join role confusion where the host re-creates the lobby on
retry), not counter problems.

## Scene Handle Patterns

Scene handles are per-peer and order-dependent. They cannot be treated as global constants.

Observed C1 / Elsie sequence:
- `141`: authenticator
- `142`: friends
- `143`: party-manager
- `144`: own party scene, host party `party-c63bee61-4cfd-4a12-adc9-7e27d44f564e`
- `145`: matchmaking / gamefinder
- `146`: gamesession

Observed C2 / Major Hoff sequence:
- `141`: authenticator
- `142`: party-manager
- `143`: friends
- `144`: own party scene, pre-join party `party-3f8f7c53-59e2-4737-84dc-78889f71e3f6`
- `145`: own matchmaking / gamefinder before join
- `146`: joined host party scene, host party `party-c63bee61-4cfd-4a12-adc9-7e27d44f564e`
- `147`: matchmaking / gamefinder after joining host party
- `148`: gamesession

Implications:
- `142` is friends for C1 but party-manager for C2.
- `143` is party-manager for C1 but friends for C2.
- `144` means each peer's original own party, not necessarily the final shared party.
- C2 joins C1's host party on a new handle, `146` in this run.
- Current Odin behavior should resolve by learned route name and scene token / scene suffix, not by fixed handle numbers.

## Invite Codes

Invite codes are dynamic and must be learned from the real `Party.CreateInvitationCode` response.

Observed codes:
- C1 / Elsie host party code: `050320`.
- C2 / Major Hoff own pre-join party code: `532934`.

The predictor still emits older hardcoded codes such as `075726` and `707203`. This is now honestly exposed by the stricter matcher.

Required behavior:
- When `Party.CreateInvitationCode` returns a six-digit code, store it per party scene / party id.
- Reuse the stored code in later `party.settingsUpdated`, `party.getpartystate2`, and joined-party state responses.
- Do not derive the code from peer label.

## Party Creation

`partymanagement.createsession` returns a token for a per-run party scene. The scene suffix and token data are dynamic.

Observed:
- C1 creates host party `party-c63bee61-4cfd-4a12-adc9-7e27d44f564e`.
- C2 creates own pre-join party `party-3f8f7c53-59e2-4737-84dc-78889f71e3f6`.

Incorrect current assumptions:
- Fixed party scene IDs such as `party-b3d2...` and `party-70e...` are wrong for live relay-derived behavior.
- Party state snapshots should not be built from fixed peer labels and fixed party ids.

Needed behavior:
- Track party scene suffix returned by `partymanagement.createsession` per peer.
- Track which party scene becomes the shared host party after join-by-code.
- Build party state and partyDataToken values from the learned party id and learned identity.

## Join-By-Code Flow

C2 / Major Hoff joins C1 / Elsie's host party.

Observed sequence:
- C2 has its own party first and receives own code `532934`.
- C2 polls `PartyMerging.GetMergerStatus` on its own party.
- C2 sends `PartyManagement.CreateConnectionTokenFromInvitationCode` on party-manager handle `142`, route `5`, with host code `050320` and C2 userdata.
- Real backend returns a token for C1's host party scene `party-c63bee61-4cfd-4a12-adc9-7e27d44f564e`.
- C2 fetches scene infos for that host party.
- C2 connects that host party as handle `146`.
- On `Scene_Ready2` for handle `146`, real backend sends `Steam.JoinLobby` with C1's Steam lobby id, then party member/data pushes.

Implications:
- `joiner_label` should be learned from the `CreateConnectionTokenFromInvitationCode` request.
- Host label should be the peer that owns the party code supplied in that request, not simply the other connected peer when more peers or stale state exist.
- Shared party state after join must use the host party id/code, not the joiner's original own party id/code.

## Friends Scene Patterns

Friends and party-manager handles can swap between peers. Route-name resolution is mandatory.

Observed:
- C1: friends is handle `142`.
- C2: friends is handle `143`.
- C2 receives large Steam friends-list notification data and later shorter update/echo notifications.

Current predictor issue:
- It sometimes emits captured friends notification samples at the wrong time or with the wrong sample body.

Needed behavior:
- Select friends notification samples by learned SteamID / body content, not peer label.
- Do not assume `friends.notification` always means the same static payload index.
- Treat `Friends.UpdateFriendList` body shape as important: some real responses echo/update a small body, not the large initial friends list.

## Party Scene RPC Behavior

Several party scene routes currently trigger wrong predictor responses.

Important observed corrections:
- `party.updatepartysettings` route `4` on a party scene usually returns `stormancer.rpc.completed`; it is not a scene-token response.
- The current broad fallback that emits token responses for route `4` with any RPC id is wrong outside party-manager `partymanagement.createsession`.
- `Party.UpdatePartyUserData2` route `6` returns `stormancer.rpc.completed`, often followed by state pushes; it should not mint new party scene tokens.
- `party.getpartystate2` returns the current party state with the actual party id, actual code, actual leader, and actual members.
- `party.updategamefinderplayerstatus` can trigger `party.memberStatusUpdated`, completion, and later gamefinder/game-session pushes.

## Match Start / Gamesession Patterns

After both peers join and ready/update status, real backend emits game-start related pushes.

Observed:
- C1 matchmaking / gamefinder handle: `145`.
- C2 post-join matchmaking / gamefinder handle: `147`.
- Real backend emits `gamefinder.update` first with a status/progress value, then with match token/session data.
- C1 gamesession handle: `146`.
- C2 gamesession handle: `148`.
- On gamesession scene ready, real backend sends `player.update` pushes for both players.
- `GameSession.GetP2PToken` real response is `stormancer.rpc.next` with `[nil, false, nil]`; player updates usually happen around scene ready or nearby async pushes, not necessarily as the direct response to every P2P token request.

Needed behavior:
- Track matchmaking handle per peer after join; it may differ from the pre-join matchmaking handle.
- Generate gamefinder/game-session pushes from shared party readiness state, not from fixed handles.
- Avoid over-emitting player.update on every `GameSession.GetP2PToken`.

## Grouping Observations With 700ms Window

The gated relay made grouping much clearer but not perfectly one-message-per-transaction.

Stats before removing Stormancer system pings:
- C1: 98 prediction records, 10 records where the client sent multiple decoded messages in one transaction, 21 records with no real response, real response bursts range from 0 to 14 messages.
- C2: 103 prediction records, 11 multi-sent records, 17 empty-real records, real response bursts range from 0 to 18 messages.

Interpretation:
- The relay window is useful for grouping server response bursts.
- Some client datagrams still contain multiple decoded messages; this is client-side batching inside one RakNet datagram and will not be fixed by timing alone.
- Some server-initiated pushes still appear in windows opened by pings or completions. These are real async backend pushes and should be modeled as state-driven pending/cross pushes, not assumed to be direct RPC replies.

## 1:N Message Grouping Patterns

This section uses the cleaned import where RakNet health and Stormancer system pings are filtered out.

System request patterns:
- `System_Request Get_Session_Token` -> `Response_Msg Session_Token` + `Response_Complete`.
- `System_Request Set_Metadata` -> `Response_Complete` only.
- `System_Request Get_Scene_Infos` for authenticator/friends/party-manager/party/matchmaking/gamesession -> normally `Response_Msg Scene_Infos` + `Response_Complete`.
- `System_Request Connect_To_Scene` for authenticator/friends/party-manager/party/matchmaking/gamesession -> normally `Response_Msg Scene_Connection_Result` + `Response_Complete`.
- `System_Request Disconnect_From_Scene` -> `Response_Msg Bool_Result` + `Response_Complete`.
- `System_Request Scene_Ready2` -> `Response_Msg Bool_Result` + `Response_Complete`, plus scene-specific server pushes listed below.

Scene-ready push patterns:
- Authenticator ready (`handle 141`) -> bool response/complete plus `gameVersion.update`. Order can be either `Bool_Result, gameVersion.update, Complete` or `gameVersion.update, Bool_Result, Complete`.
- Friends ready (`handle 142` or `143`, depending on peer) -> usually `Bool_Result` + `Response_Complete`.
- Own party ready (`handle 144`) -> `Steam.CreateLobby`, bool response/complete, then initial `party.settingsUpdated` and `party.memberDataUpdated` pushes.
- Matchmaking/gamefinder ready (`C1 handle 145`, C2 post-join handle 147`) -> bool response/complete, sometimes followed by party member status/data pushes if the shared party state changed.
- Joined host party ready (`C2 handle 146` in this run) -> `Steam.JoinLobby`, bool response/complete, then `party.memberDataUpdated`; later `party.memberConnected` / state snapshot pushes follow when client completes server RPCs.
- Gamesession ready (`C1 handle 146`, C2 handle 148`) -> `player.update` pushes for both members, bool response/complete, and sometimes party status/data pushes around the same window.

Party scene route patterns:
- `Party.CreateInvitationCode` route `13` -> `stormancer.rpc.next` with one 6-digit string + `stormancer.rpc.completed`.
- `party.getpartystate2` route `11` -> `stormancer.rpc.next` with party state + `stormancer.rpc.completed`; party state carries actual `InvitationCode`, party id, leader id, members, and version.
- `Party.UpdatePartyUserData2` route `6` -> `stormancer.rpc.completed`, sometimes followed by state pushes; it should not mint a scene token.
- `party.updatepartysettings` route `4` -> `stormancer.rpc.completed`, sometimes nearby `stormancer.rpc.cancel` async pushes; it should not mint a scene token.
- `party.updategamefinderplayerstatus` route `9` -> `party.memberStatusUpdated` + `stormancer.rpc.completed`, with later gamefinder/game-session pushes when both peers are ready.
- Client `stormancer.rpc.completed` for server RPCs usually produces no direct response, but can trigger async pushes such as `party.memberConnected`, `party.memberDataUpdated`, `Steam.UpdateLobbyJoinable`, `gamefinder.update`, `stormancer.rpc.error`, or `stormancer.rpc.cancel` depending on the server RPC being completed.

Party-manager and friends scene patterns:
- `partymanagement.createsession` route `4` -> `stormancer.rpc.next` with party scene token + `stormancer.rpc.completed`.
- `PartyManagement.CreateConnectionTokenFromInvitationCode` route `5` -> `stormancer.rpc.next` with host-party token + `stormancer.rpc.completed`.
- `Friends.Subscribe` route `5` -> `friends.notification` + `stormancer.rpc.completed`. In this capture one duplicate subscribe produced no real response after the first notification burst.
- `Friends.UpdateFriendList` route `4` -> `friends.notification`; if batched with party userdata, the same transaction can also include party completions.

Match start / gamesession route patterns:
- `gamefinder.update` appears as async pushes, often first `[0]`, then a large `[3, token, gameSessionInfo]` match payload.
- `GameSession.GetP2PToken` route `8` -> `stormancer.rpc.next` with `[nil, false, nil]`; do not treat every P2P token request as a reason to emit all `player.update` pushes.
- `player.update` pushes happen around gamesession connect/ready and some later completions; they are state-driven async pushes.

Grouping caveats:
- Some real response windows legitimately contain several pushes after one sent message.
- Some windows have zero direct real response because the sent message was a completion or a state update whose visible effect arrives later.
- Some client datagrams still contain multiple meaningful scene messages; the relay timing window cannot split a single RakNet datagram.
- With pings filtered, any remaining `Ping` / `Ping_Response` in `predict_caleb.json` should be treated as a bug in the filter.

## Mismatch Buckets From The 22:37 Run (17 false of 140)

The 17 `match=false` records break down into three causes. Record indices are
0-based positions in `predict_caleb.json`.

### A. Unmodeled async state-driven server pushes (the majority)
The client sent a `stormancer.rpc.completed [0]` (or a ready/token request) and the
real backend answered with one or more async pushes the predictor does not emit, so
PRED is empty or missing trailing messages. These are inherently state/timing driven
(the doc's "pending/cross push" category) and cannot be matched by timing alone.
- idx 36 (C1): completed -> real `Response_Complete` + `party.memberConnected`; PRED empty.
- idx 99 (C2): `Scene_Ready2 h147` -> real adds `party.memberDataUpdated`; PRED has only bool+complete.
- idx 107 (C1): UpdatePartyUserData2 + updatepartysettings -> real adds `party.memberStatusUpdated`; PRED has only the two completions.
- idx 114 (C1): completed -> real `Steam.UpdateLobbyJoinable`; PRED empty.
- idx 115 (C2): completed -> real `player.update`; PRED empty.
- idx 117 (C1) / idx 119 (C2): `GameSession.GetP2PToken` -> real `rpc.next[[nil,false,nil]]` (matched) PLUS an async `player.update` / `party.settingsUpdated`; PRED has only the rpc.next.
- idx 132 (C2): completed -> real `party.settingsUpdated`; PRED empty.
- idx 135 (C1): completed -> real `party.memberDisconnected` + `player.update`; PRED empty.
- idx 70 (C2): `Scene_Ready2 h145` -> real has TWO `party.settingsUpdated` (rpc 7 and 8); PRED emits only rpc 7.

### B. Dynamic member/party state content we do not track exactly
PRED has the right message shapes but member-data fields (RequestedHero, LobbyState,
MemberDataInitialized), member ordering, or connection-status integers differ from
the live values. These need a real per-member state model.
- idx 20 (C1): own-party-ready burst; first `party.settingsUpdated` settings value and a trailing `memberDataUpdated` differ.
- idx 33 (C1): `Scene_Ready2 h145`; PRED emits a spurious leading `memberDataUpdated` and wrong RequestedHero values.
- idx 103 (C2): `party.getpartystate2`; member connection-status integers differ (real 0/1, PRED 0/0).
- idx 116 (C1) / idx 118 (C2): large `Scene_Ready2 h146/h148` bursts; many member-data and push diffs.

### C. Hardcoded per-session rpc_id push rules (FIXABLE)
The predictor keys several party pushes on hardcoded `rpc_id` constants
(`(counter<<8)`: 2049, 2816, 3584, 4096, 6400, 3840). The connect flow is
deterministic enough that 4 of 6 (`2049`, `2816`, `4096`, `6400`) still matched
True in this brand-new capture. Only two diverged, and they are a matched pair:
the "Cannot update data when member is ready." error actually occurred at idx 102
(C2, handle 146, rpc 3584) but the predictor emitted it at idx 105 (C1, handle 144,
rpc 3840) -- where the real response was `gamefinder.update`. Fix: emit the error
on the (146, 3584) rule (matches idx 102 exactly -> True) and drop it from the
(144, 3840) rule, keeping only the `gamefinder.update [0]` push there.

Do not hide the A/B buckets with matcher exceptions; they represent dynamic state to
model. Bucket C is a concrete predictor correction applied in main.odin.

## Concrete Odin Changes Suggested

1. Replace hardcoded invite codes with learned per-party codes.
2. Replace hardcoded party scene ids with learned scene suffixes from real/create-session tokens or generated live state.
3. Replace peer-label identity assumptions with learned identity records.
4. Use learned route names for every switch that currently depends on fixed handle/route combinations.
5. Remove broad fallback token responses for arbitrary route `4` scene messages; only party-manager `partymanagement.createsession` should mint a party scene token.
6. Model `Party.CreateInvitationCode`, `party.updatepartysettings`, and `Party.UpdatePartyUserData2` as party-state mutations that can trigger pushes.
7. Track party ownership and host-party join by invite code: code -> host party -> joiner connects host party -> host Steam lobby id.
8. Model gamefinder/game-session transition from shared party readiness instead of fixed transaction numbers.
9. Keep strict matcher behavior; use the log to expose wrong assumptions rather than masking dynamic routes.
