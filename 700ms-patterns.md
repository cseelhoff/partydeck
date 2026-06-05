# 700ms Relay Capture Patterns

Source run: successful full multiplayer relay capture from 2026-06-05 around 18:35-18:37.

Files examined:
- `/tmp/pdlog/probe/relay_capture.jsonl`
- `/tmp/pdlog/probe/predict_caleb.json`

Relay summary before removing Stormancer system pings:
- Relay capture rows: 537 total, 237 c2s and 300 s2c.
- Prediction records: 201 total, 141 true and 60 false with the stricter matcher.
- Peer record counts: C1 has 98 transactions, C2 has 103 transactions.
- Transport health/control is no longer present in transaction logs.

After also filtering Stormancer `System_Request msg_id=Ping` and `Ping_Response`, the same capture imports as:
- Prediction records: 146 total, 89 true and 57 false.
- Ping/health records: 0.

## Peer Identities

In this run, peer label order did not match the older canonical capture:

- `C1` is the first connected client, laptop / Elsie.
- `C2` is the second connected client, desktop / Major Hoff.

Do not infer identity from `C1` or `C2`. Peer labels are connection-order labels only. Identity should be learned from `Authentication.Login`, party userdata, SteamID, or EOS/user id fields.

Useful stable identities:
- Elsie: user id `9fe2fc1fa18643e2818bbd65198d4b00`, SteamID `76561199572083022`, EOS id `000239105cf443abbdf0238c827bd9e8`.
- Major Hoff: user id `4168ffb24de245f88060d27c9580685e`, SteamID `76561197977870267`, EOS id `0002ea2c70fa4f89a5d876065a55c786`.

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

## Mismatch Buckets From This Run

With strict matching, current mismatch categories were roughly:
- Party state / invite code / dynamic identity and party id mismatches.
- Game session and match-start push mismatches.
- Scene-ready push burst mismatches.
- Friends notification sample/timing mismatches.
- One scene connection result mismatch.
- One merger status / live pool stats mismatch.

Do not hide these with matcher exceptions. They represent either dynamic state to learn or predictor behavior to correct.

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
