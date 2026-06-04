# RakNet / Stormancer Wire Dictionary (partydeck offline emulator)

Purpose: a single reference of every message type, frame, system request, scene,
and route the offline emulator (`raknet.py`) and the synchronous logger
(`sync-raknet.py`) can encounter, plus the **abbreviation scheme** used when
rendering a datagram to its `*_human_readable` string. Comparison is always on
the raw hex first; the human-readable string is a faithful, symbol-free,
abbreviated projection of that hex so a human can read a diff at a glance.

Scope note: this covers the Ravenswatch (`live-1-05-00`, dt-live cluster) login →
party → matchmaking → gamesession flow. Counts are bounded: ~25 RakNet/transport
frame ids, 7 system requests, ~6 scene kinds, ~110 named routes. Well under 500.

---

## 1. UDP datagram layer (RakNet ReliabilityLayer)

Every UDP packet begins with one flags byte. Bits (MSB→LSB):

| bit  | mask | meaning                                            |
|------|------|----------------------------------------------------|
| 7    | 0x80 | **isValid / online** (connected datagram). If clear → offline handshake packet. |
| 6    | 0x40 | **isACK**                                          |
| 5    | 0x20 | **isNAK**                                          |
| 4    | 0x10 | (packet-pair / continuous-send flags; ignored)     |

Datagram categories and how the logger treats them:

| category   | detection                         | recorded? | hr tag |
|------------|-----------------------------------|-----------|--------|
| offline    | bit7 == 0                         | no        | `OFF <id>` |
| ACK        | bit7 && bit6                      | **no**    | `ACK` |
| NAK        | bit7 && bit5                      | **no**    | `NAK` |
| online data| bit7, !bit6, !bit5                | **yes**   | (decoded) |

Online data datagram body: `[flags:1][datagramSeqNum:3 LE][ encapsulated msgs… ]`.
The logger parses from offset 4.

### 1.1 Encapsulated message header (per message inside a datagram)

```
[reliabilityByte:1][dataBitLength:2 BE]
  ( if reliable )            [reliableMessageNumber:3 LE]
  ( if sequenced )           [sequencingIndex:3 LE]
  ( if sequenced|ordered )   [orderingIndex:3 LE][orderingChannel:1]
  ( if hasSplit )            [splitPacketCount:4 BE][splitPacketId:2 BE][splitPacketIndex:4 BE]
[payload: ceil(dataBitLength/8) bytes]
```

`reliabilityByte`: `(reliability<<5) | (hasSplit<<4)`.

PacketReliability enum:

| val | name                  | abbr |
|-----|-----------------------|------|
| 0   | UNRELIABLE            | u    |
| 1   | UNRELIABLE_SEQUENCED  | us   |
| 2   | RELIABLE              | r    |
| 3   | RELIABLE_ORDERED      | ro   |
| 4   | RELIABLE_SEQUENCED    | rs   |

Split (fragmented) messages are reassembled per side by `splitPacketId` before
decoding; the hr string shows the reassembled payload, never fragments.

---

## 2. Offline (handshake) message IDs

First payload byte of an offline datagram. Not recorded as transactions but
listed for completeness.

| id   | name                          | abbr |
|------|-------------------------------|------|
| 0x01 | ID_UNCONNECTED_PING           | uping |
| 0x02 | ID_UNCONNECTED_PING_OPEN_CONN | upingo |
| 0x1C | ID_UNCONNECTED_PONG           | upong |
| 0x05 | ID_OPEN_CONNECTION_REQUEST_1  | ocr1 |
| 0x06 | ID_OPEN_CONNECTION_REPLY_1    | ocp1 |
| 0x07 | ID_OPEN_CONNECTION_REQUEST_2  | ocr2 |
| 0x08 | ID_OPEN_CONNECTION_REPLY_2    | ocp2 |
| 0x11 | ID_CONNECTION_ATTEMPT_FAILED  | caf |
| 0x14 | ID_NO_FREE_INCOMING_CONNECTIONS | nofree |
| 0x17 | ID_CONNECTION_BANNED          | banned |
| 0x12 | ID_ALREADY_CONNECTED          | already |
| 0x1A | ID_IP_RECENTLY_CONNECTED      | iprecent |

---

## 3. Connected-layer ("online") message IDs

First payload byte of an encapsulated message on an online datagram, when < 0x80.

| id   | name                           | abbr | direction |
|------|--------------------------------|------|-----------|
| 0x00 | ID_CONNECTED_PING              | ping | both |
| 0x03 | ID_CONNECTED_PONG              | pong | both |
| 0x09 | ID_CONNECTION_REQUEST          | creq | c→s |
| 0x10 | ID_CONNECTION_REQUEST_ACCEPTED | cacc | s→c |
| 0x13 | ID_NEW_INCOMING_CONNECTION     | nic  | c→s |
| 0x15 | ID_DISCONNECTION_NOTIFICATION  | disc | both |

ID_CONNECTED_PING / PONG body = `RakNetTime:8 (one or two int64 timestamps)`.
hr: `ping t=<clock>` / `pong t=<clock>`.

---

## 4. Stormancer transport message IDs (user packets ≥ 0x86)

First payload byte ≥ 0x86. Scene data messages use the **SceneHandle** byte
(≥ 0x8D dynamically) as the id, so anything ≥ 0x8D is a scene message, not one of
these fixed ids.

| id   | name                         | abbr | body |
|------|------------------------------|------|------|
| 0x86 | ID_SYSTEM_REQUEST            | sysreq | `[msgId:1][reqId:2 LE][mp data]` |
| 0x89 | ID_REQUEST_RESPONSE_MSG      | resp | `[reqId:2 LE][mp data]` (an RPC `next`/result value) |
| 0x8A | ID_REQUEST_RESPONSE_COMPLETE | done | `[reqId:2 LE][hasValues:1]` |
| 0x8B | ID_REQUEST_RESPONSE_ERROR    | err  | `[reqId:2 LE][mp error]` |
| 0x8C | ID_CONNECTION_RESULT         | connres | server assigns the connection id |
| 0x8D+| ID_SCENES (SceneHandle base) | scene | see §6/§7 |

`reqId` correlates a system request with its `resp`/`done`/`err` reply.

---

## 5. System request msgIds (inside ID_SYSTEM_REQUEST)

Second byte of an ID_SYSTEM_REQUEST frame.

| msgId | name                     | abbr | request body | reply |
|-------|--------------------------|------|--------------|-------|
| 0     | ID_SET_METADATA          | setmeta | mp map of ConnectionMetadata | `done` |
| 1     | ID_SCENE_READY           | ready1 | mp `{SceneHandle}` | `done` |
| 2     | ID_PING                  | sping | `int64 clock` | `resp` `[serverClock, clientClock]` |
| 14    | ID_GET_SESSION_TOKEN     | gettok | empty | `resp [sessionJWT, sessionId]` + `done` |
| 16    | ID_SCENE_READY2          | ready2 | mp `{SceneHandle}` | `resp {v:true}` |
| 134   | ID_CONNECT_TO_SCENE      | connscene | mp `{Token, Routes[], ConnectionMetadata, SceneMetadata}` | `resp {SceneHandle, RouteMappings, …}` |
| 135   | ID_DISCONNECT_FROM_SCENE | discscene | mp `{SceneHandle}` | `done` |
| 136   | ID_GET_SCENE_INFOS       | sceneinfos | mp `{Token, …}` | `resp` SceneInfosDto |

hr render of a system request: `sysreq <abbr>#<reqId> <key-fields>`.

---

## 6. Scenes (kinds, static handles, classification)

A "scene" is a logical service the client connects to. The real cluster assigns
each a numeric **SceneHandle** sequentially in connect order from 141; the
emulator bakes statics at 141.. and allocates dynamics from 160. Handles differ
across runs, so scenes are keyed by **kind** (route-name fingerprint), never by
the raw handle.

| kind         | abbr | real handle (typical) | route fingerprint |
|--------------|------|-----------------------|-------------------|
| authenticator| auth | 141 | `users.renewCredentials` |
| friends      | frnd | 142 | `Steam.GetFriends` / `friends.notification` |
| party-manager| pmgr | 143 | `partymanagement.createsession` |
| party        | pty  | 144 | `party.*` / `memberConnected` |
| matchmaking  | mm   | 145 | `gamefinder.*` / `PartyMerging.*` / `gf.*` |
| gamesession  | gs   | 146+ | `dt.p2p` / `players.allReady` / `player.update` |
| (unknown)    | scn? | —   | none matched |

Scene id base: `scene:/passtech-live/darktales/live-1-05-00/<suffix>`.

---

## 7. Routes (per scene)

A scene's connect reply carries `RouteMappings: {routeName -> routeHandle}`. A
scene data message is `[sceneHandle:1][routeHandle:2 LE][body]`. The logger
resolves `(sceneHandle→kind, routeHandle→routeName)` from the learned mappings.

### 7.1 Universal RPC stream routes (every scene)

These wrap request/response RPCs. Body starts with `[rpcReqId:2 LE]` then mp args.

| route                    | abbr | meaning |
|--------------------------|------|---------|
| stormancer.rpc.next      | rnext | one streamed RPC value (or the single result) |
| stormancer.rpc.completed | rdone | RPC finished |
| stormancer.rpc.error     | rerr  | RPC failed (body = error string) |
| stormancer.rpc.cancel    | rcanc | caller cancelled |

### 7.2 authenticator (auth)

| route                       | abbr |
|-----------------------------|------|
| Authentication.Login        | login |
| Authentication.GetStatus    | authstatus |
| Authentication.GetMetadata  | authmeta |
| Authentication.Register     | authreg |
| Authentication.Unlink       | authunlink |
| Locator.GetSceneConnectionToken | loctok |
| UserSession.UpdateUserOptions | setopts |
| UserSession.GetUserOptions  | getopts |
| UserSession.CreateUserBearerToken | mkbearer |
| UserSession.GetUserIdFromBearerToken | bearer2uid |
| UserSession.GetAuthenticatedUsersCountPublic | authcount |
| users.renewCredentials      | renewcred |
| gameVersion.update          | gvupd |
| serverVersion.update        | svupd |
| sceneauthorization.gettoken | sagettok |

### 7.3 friends (frnd)

| route                         | abbr |
|-------------------------------|------|
| Steam.GetFriends              | steamfriends |
| Steam.QueryUserIds            | steamquids |
| Steam.GetLobbyOwner           | steamlobbyowner |
| Steam.Invite                  | steaminvite |
| Friends.Get                   | frget |
| Friends.Subscribe             | frsub |
| Friends.RefreshSubscription   | frrefresh |
| Friends.UpdateFriendList      | frupdlist |
| Friends.Block                 | frblock |
| Friends.Unblock               | frunblock |
| Friends.GetBlockedList        | frblocked |
| friends.notification          | frnotif |
| friends.setstatus             | frsetstatus |
| friends.invitefriend          | frinvite |
| friends.acceptfriendinvitation| fraccept |
| friends.removefriend          | frremove |

### 7.4 party-manager (pmgr)

| route                                              | abbr |
|----------------------------------------------------|------|
| partymanagement.createsession                      | mkparty |
| PartyManagement.CreateConnectionTokenFromInvitationCode | tokfromcode |
| PartyManagement.CreateConnectionTokenFromPartyId   | tokfrompid |
| PartyManagement.SearchParties                      | searchparties |
| partyMerging.connectionToken                       | mergetoken |

### 7.5 party (pty)

| route                              | abbr |
|------------------------------------|------|
| party.getpartystate                | getstate |
| party.getPartyStateResponse        | stateresp |
| party.memberConnected              | mconn |
| party.memberDisconnected           | mdisc |
| party.memberDataUpdated            | mdata |
| party.memberStatusUpdated          | mstatus |
| party.settingsUpdated              | setupd |
| party.updatepartysettings          | updsettings |
| party.updatepartyuserdata          | upduserdata |
| party.updategamefinderplayerstatus | updgfstatus |
| party.UpdatePartyUserData          | upduserdata2 |
| party.leaderChanged                | leaderchg |
| party.promoteleader                | promote |
| party.kickplayer                   | kick |
| party.sendinvitation               | sendinvite |
| party.gameFinderFailed             | gffailed |
| Party.CreateInvitationCode         | mkcode |
| Party.CancelInvitationCode         | cancelcode |
| Party.UpdatePartyUserData          | partyuserdata |
| Steam.CreateLobby                  | mklobby |
| Steam.JoinLobby                    | joinlobby |
| Steam.UpdateLobbyJoinable          | lobbyjoinable |
| Steam.GetLobbyOwner                | lobbyowner |
| Steam.DecodePartyDataBearerTokens  | decptoken |
| SteamParty.CreatePartyDataBearerToken | mkptoken |
| NX.GetAdvertisedParties            | nxads |

### 7.6 matchmaking (mm)

| route                          | abbr |
|--------------------------------|------|
| PartyMerging.GetMergerStatus   | mergerstatus |
| PartyMerging.Start             | mergestart |
| PartyMerging.Stop              | mergestop |
| GameFinder.GetPublicStatus     | gfpublic |
| gamefinder.update              | gfupd |
| gamefinder.cancel              | gfcancel |

### 7.7 gamesession (gs)

| route                                          | abbr |
|------------------------------------------------|------|
| players.allReady                               | allready |
| player.update                                  | pupd |
| player.ready                                   | pready |
| player.faulted                                 | pfault |
| dt.p2p                                          | p2p |
| DtGameSession.GetConnectionInfosForPlayer      | gsconninfo |
| GameSession.GetGameSessionConnectionUrl        | gsurl |
| GameSession.CreateP / GameSession.GetP         | gscreatep / gsgetp |
| GameSession.GetTeams                           | gsteams |
| gamesession.getgamesessionsettings             | gssettings |
| gamesession.postresults                        | gsresults |
| gamesession.reset                              | gsreset |
| gamesession.updateshutdownmode                 | gsshutdown |
| JoinGameParty.RequestReservationInCurrentGamesession | gsreserve |
| sceneauthorization.gettoken                    | sagettok |

---

## 8. Recurring msgpack payload schemas

These are the long, mostly-static structures. The hr encoder collapses each to a
compact, symbol-free signature that still surfaces the field(s) that actually
vary. "vary" = the field whose change implies a different hex.

### 8.1 ConnectionMetadata (in setmeta + connscene)
Static-ish map (platform, plugins, serializer, server.name/version, timeout,
transport, type, version). hr: `cmeta plat=<Win64> proto=<n> ver=<x>` — only the
fields that ever change between messages are emitted.

### 8.2 ConnectTokenScene Routes[] (in connscene)
Array of `{Name, Handle, Metadata}`. Handles are all 0 on the request. hr:
`routes n=<count> <abbr,abbr,…>` — the route abbreviations in order; the count and
ordered set are what distinguish two requests.

### 8.3 ConnectionResult (connscene reply)
`{SceneHandle, RouteMappings{name->handle}, …}`. The **SceneHandle int is
allocation noise** (differs real vs emu) — hr renders it as `h=*` (wildcard) and
emits the route map as `rm <kind> <name:handle,…sorted by name>`; what matters is
the route set + handle assignment WITHIN the scene, not the scene handle itself.

### 8.4 SceneInfosDto (sceneinfos reply)
Big static blob describing a scene's routes + metadata. hr: `sceneinfos
kind=<kind> nroutes=<n>`.

### 8.5 Session token (gettok reply)
`[jwt, sessionId]`. Both are per-session identity — shown VERBATIM (a diff here is
real: different session). hr: `token sid=<sessionId>` plus the jwt verbatim.

### 8.6 PartyState (party.getPartyStateResponse / getpartystate2)
`[settings[8], leaderUserId, members[], version]`. hr: `state v=<version>
leader=<uid> nmemb=<n> memb=<uid:status,…>`.

### 8.7 PartyMember (full, 6-elt) / slim (4-elt)
full = `[userId, connectId, dataBin, routeBin, [[platform,id,name,extra,?,0]],
2]`. hr: `memb <uid> <name> st=<n>`.

### 8.8 party.memberStatusUpdated
`[ver, 0, statusSeq] + member`. hr: `mstatus v=<ver> seq=<n> <uid> st=<n>`.

### 8.9 gamefinder.update (the ~4093B match push)
Carries the gamesession scene-connection token + endpoints + encryption. hr:
`gfupd gstok=<sessionId-or-len> ep=<host:port>`.

### 8.10 PartyMerging.GetMergerStatus reply
`[[status, {partiesCount, algorithm, playersCount, details{…}}]]`. hr:
`mergerstatus parties=<n> players=<n>`.

---

## 9. Human-readable rendering rules (symbol-free, abbreviated, deterministic)

Goal: a single lowercase string per datagram-burst, no JSON punctuation
(`{}[]":,` are forbidden), built deterministically so identical hex → identical
hr and any hr diff ⇒ a real hex diff. Same function for real and pred.

Rules:
1. **No structural symbols.** Replace nesting/separators with spaces and fixed
   keywords. Messages in a burst are joined by ` then `. Fields are `key=value`.
2. **Abbreviate known names** via the tables above (route abbr, scene-kind abbr,
   sysreq abbr). Unknown names pass through lowercased with dots kept.
3. **Identity is shown, never masked.** session ids, user ids, tokens, names,
   lobby ids, party guids: emit verbatim (truncation only for >64-char opaque
   blobs, rendered as `<first16>~<len>` so length+prefix still diff).
4. **Allocation noise is normalized, not hidden.** The scene-handle scalar in a
   ConnectionResult is rendered `h=*`; route-handle assignments WITHIN the scene
   are kept (they are real). This is the ONLY normalization and it is symmetric.
5. **Static boilerplate is collapsed to its variable fields** per §8; if a schema
   has a known mostly-empty shape, emit only the field(s) that can change.
6. **Numbers verbatim**; booleans as `t`/`f`; nil as `nil`; binary as
   `bin<len>:<first8hex>`; msgpack ext as `ext<type>:<hex>`.
7. **Maps are emitted key-sorted**; arrays in order. This guarantees determinism
   so the real/pred comparison is stable.

Worked example (session token, currently `match:false`):
```
real: resp#1 token sid=bX2FN1WaKUqouBcbU59VmQ jwt=eyJhbGci~233 then done#1 hasv=t
pred: resp#1 token sid=LA7CWgu_IjK_cPamybSKXw jwt=eyJhbGci~219 then done#1 hasv=t
```
The `sid=` and `jwt=` differ → a real, legible divergence (different session),
exactly what we want surfaced.

---

## 10. Message-type census (bound check)

- datagram categories: 4 (offline, ACK, NAK, online)
- offline ids: 12
- connected-layer ids: 6
- transport ids: 6 (+ scene-handle family)
- system request msgIds: 7
- scene kinds: 6 (+ unknown)
- RPC stream routes: 4
- named service routes: ~95 across all scenes

Total enumerated symbols: well under 200. The space is bounded and fully
enumerable; this file is the source of truth for the hr encoder in
`sync-raknet.py`.
