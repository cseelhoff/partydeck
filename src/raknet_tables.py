#!/usr/bin/env python3
"""raknet_tables.py — DATA ONLY lookup tables for the RakNet/Stormancer wire.

Source of truth: raknet-dictionary.md. No classes, no functions — only plain
dicts / sets / tuples the human-readable encoder (sync-raknet.py) and decoders
import. Every name here is abbreviated consistently so identical hex always
renders to an identical hr string and any hr diff implies a real hex diff.

Section numbers match raknet-dictionary.md.
"""

# =========================================================================
# §1  UDP datagram layer — flags byte bit masks
# =========================================================================
DG_FLAG_VALID = 0x80        # online (connected) datagram; clear => offline
DG_FLAG_ACK   = 0x40
DG_FLAG_NAK   = 0x20
DG_FLAG_PAIR  = 0x10        # packet-pair / continuous-send (ignored)

DG_HEADER_LEN = 4           # [flags:1][datagramSeqNum:3 LE]

# Datagram-category -> hr tag. (offline/ack/nak are NOT recorded as txns.)
DG_CATEGORY_TAG = {
    "offline": "off",
    "ack": "ack",
    "nak": "nak",
    "online": "",           # decoded inline
}

# =========================================================================
# §1.1  Encapsulated message reliability
# =========================================================================
RELIABILITY_ABBR = {
    0: "u",     # UNRELIABLE
    1: "us",    # UNRELIABLE_SEQUENCED
    2: "r",     # RELIABLE
    3: "ro",    # RELIABLE_ORDERED
    4: "rs",    # RELIABLE_SEQUENCED
}
RELIABLE_KINDS = frozenset({2, 3, 4})          # carry reliableMessageNumber
SEQUENCED_KINDS = frozenset({1, 4})            # carry sequencingIndex
ORDERED_KINDS = frozenset({1, 3, 4})           # carry orderingIndex + channel
SPLIT_HEADER_LEN = 10       # count(4 BE) + id(2 BE) + index(4 BE)

# =========================================================================
# §2  Offline (handshake) message IDs  (first payload byte, datagram bit7=0)
# =========================================================================
OFFLINE_IDS = {
    0x01: "uping",      # ID_UNCONNECTED_PING
    0x02: "upingo",     # ID_UNCONNECTED_PING_OPEN_CONN
    0x1C: "upong",      # ID_UNCONNECTED_PONG
    0x05: "ocr1",       # ID_OPEN_CONNECTION_REQUEST_1
    0x06: "ocp1",       # ID_OPEN_CONNECTION_REPLY_1
    0x07: "ocr2",       # ID_OPEN_CONNECTION_REQUEST_2
    0x08: "ocp2",       # ID_OPEN_CONNECTION_REPLY_2
    0x11: "caf",        # ID_CONNECTION_ATTEMPT_FAILED
    0x14: "nofree",     # ID_NO_FREE_INCOMING_CONNECTIONS
    0x17: "banned",     # ID_CONNECTION_BANNED
    0x12: "already",    # ID_ALREADY_CONNECTED
    0x1A: "iprecent",   # ID_IP_RECENTLY_CONNECTED
}

# =========================================================================
# §3  Connected-layer ("online") message IDs  (first payload byte < 0x80)
# =========================================================================
ONLINE_IDS = {
    0x00: "ping",       # ID_CONNECTED_PING        body = clock:8 (x1 or x2)
    0x03: "pong",       # ID_CONNECTED_PONG
    0x09: "creq",       # ID_CONNECTION_REQUEST
    0x10: "cacc",       # ID_CONNECTION_REQUEST_ACCEPTED
    0x13: "nic",        # ID_NEW_INCOMING_CONNECTION
    0x15: "disc",       # ID_DISCONNECTION_NOTIFICATION
}

# =========================================================================
# §4  Stormancer transport message IDs  (first payload byte >= 0x86)
# =========================================================================
TRANSPORT_IDS = {
    0x86: "sysreq",     # ID_SYSTEM_REQUEST          [msgId:1][reqId:2 LE][mp]
    0x89: "resp",       # ID_REQUEST_RESPONSE_MSG     [reqId:2 LE][mp]
    0x8A: "done",       # ID_REQUEST_RESPONSE_COMPLETE[reqId:2 LE][hasValues:1]
    0x8B: "err",        # ID_REQUEST_RESPONSE_ERROR   [reqId:2 LE][mp]
    0x8C: "connres",    # ID_CONNECTION_RESULT
}
SCENE_HANDLE_MIN = 0x8D     # payload[0] >= this => a scene data message

# =========================================================================
# §5  System request msgIds  (second byte of an ID_SYSTEM_REQUEST frame)
# =========================================================================
SYSREQ_IDS = {
    0:   "setmeta",     # ID_SET_METADATA
    1:   "ready1",      # ID_SCENE_READY
    2:   "sping",       # ID_PING            req clock:8 -> resp [srvClk, cliClk]
    14:  "gettok",      # ID_GET_SESSION_TOKEN -> resp [jwt, sessionId] + done
    16:  "ready2",      # ID_SCENE_READY2    {SceneHandle} -> resp {v:true}
    134: "connscene",   # ID_CONNECT_TO_SCENE
    135: "discscene",   # ID_DISCONNECT_FROM_SCENE
    136: "sceneinfos",  # ID_GET_SCENE_INFOS
}

# =========================================================================
# §6  Scene kinds — abbr + typical real handle + route fingerprint
# =========================================================================
SCENE_KIND_ABBR = {
    "authenticator": "auth",
    "friends":       "frnd",
    "party-manager": "pmgr",
    "party":         "pty",
    "matchmaking":   "mm",
    "gamesession":   "gs",
    "scene?":        "scn?",
}

# Typical sequential handle on the real cluster (informational; never keyed on).
SCENE_KIND_TYPICAL_HANDLE = {
    "authenticator": 141,
    "friends":       142,
    "party-manager": 143,
    "party":         144,
    "matchmaking":   145,
    "gamesession":   146,
}

# Route names that fingerprint a scene kind (handles vary, names don't).
# Ordered by specificity; first matching rule wins (see encoder).
SCENE_FINGERPRINT = (
    # (kind, frozenset_of_any_of_these_route_names)
    ("authenticator", frozenset({"users.renewCredentials"})),
    ("friends",       frozenset({"Steam.GetFriends", "friends.notification"})),
    ("matchmaking",   frozenset({"gamefinder.update", "gamefinder.cancel",
                                 "PartyMerging.GetMergerStatus",
                                 "GameFinder.GetPublicStatus"})),
    ("gamesession",   frozenset({"dt.p2p", "players.allReady", "player.update"})),
    ("party-manager", frozenset({"partymanagement.createsession"})),
    ("party",         frozenset({"party.memberConnected", "party.getpartystate",
                                 "party.settingsUpdated"})),
)

SCENE_ID_BASE = "scene:/passtech-live/darktales/live-1-05-00/"

# Service-name (Locator.GetSceneConnectionToken arg) -> scene suffix/kind.
SERVICE_TO_SCENE = {
    "stormancer.friends":                 "friends",
    "stormancer.plugins.partyManagement": "party-manager",
    "stormancer.plugins.gamefinder":      "matchmaking",
}

# =========================================================================
# §7.1  Universal RPC stream routes (present on every scene)
# =========================================================================
RPC_STREAM_ABBR = {
    "stormancer.rpc.next":      "rnext",
    "stormancer.rpc.completed": "rdone",
    "stormancer.rpc.error":     "rerr",
    "stormancer.rpc.cancel":    "rcanc",
}
# Routes whose body begins with [rpcReqId:2 LE] before the mp args.
RPC_STREAM_ROUTES = frozenset(RPC_STREAM_ABBR)

# =========================================================================
# §7.2 - §7.7  Named service routes per scene -> abbreviation
# =========================================================================
ROUTE_ABBR_AUTH = {
    "Authentication.Login":                          "login",
    "Authentication.GetStatus":                      "authstatus",
    "Authentication.GetMetadata":                    "authmeta",
    "Authentication.Register":                       "authreg",
    "Authentication.Unlink":                         "authunlink",
    "Locator.GetSceneConnectionToken":               "loctok",
    "UserSession.UpdateUserOptions":                 "setopts",
    "UserSession.GetUserOptions":                    "getopts",
    "UserSession.CreateUserBearerToken":             "mkbearer",
    "UserSession.GetUserIdFromBearerToken":          "bearer2uid",
    "UserSession.GetAuthenticatedUsersCountPublic":  "authcount",
    "users.renewCredentials":                        "renewcred",
    "gameVersion.update":                            "gvupd",
    "serverVersion.update":                          "svupd",
    "sceneauthorization.gettoken":                   "sagettok",
}

ROUTE_ABBR_FRIENDS = {
    "Steam.GetFriends":               "steamfriends",
    "Steam.QueryUserIds":             "steamquids",
    "Steam.GetLobbyOwner":            "steamlobbyowner",
    "Steam.Invite":                   "steaminvite",
    "Friends.Get":                    "frget",
    "Friends.Subscribe":              "frsub",
    "Friends.RefreshSubscription":    "frrefresh",
    "Friends.UpdateFriendList":       "frupdlist",
    "Friends.Block":                  "frblock",
    "Friends.Unblock":                "frunblock",
    "Friends.GetBlockedList":         "frblocked",
    "friends.notification":           "frnotif",
    "friends.setstatus":              "frsetstatus",
    "friends.invitefriend":           "frinvite",
    "friends.acceptfriendinvitation": "fraccept",
    "friends.removefriend":           "frremove",
}

ROUTE_ABBR_PARTY_MANAGER = {
    "partymanagement.createsession":                          "mkparty",
    "PartyManagement.CreateConnectionTokenFromInvitationCode": "tokfromcode",
    "PartyManagement.CreateConnectionTokenFromPartyId":        "tokfrompid",
    "PartyManagement.SearchParties":                           "searchparties",
    "partyMerging.connectionToken":                            "mergetoken",
}

ROUTE_ABBR_PARTY = {
    "party.getpartystate":                "getstate",
    "party.getPartyStateResponse":        "stateresp",
    "party.memberConnected":              "mconn",
    "party.memberDisconnected":           "mdisc",
    "party.memberDataUpdated":            "mdata",
    "party.memberStatusUpdated":          "mstatus",
    "party.settingsUpdated":              "setupd",
    "party.updatepartysettings":          "updsettings",
    "party.updatepartyuserdata":          "upduserdata",
    "party.updategamefinderplayerstatus": "updgfstatus",
    "party.UpdatePartyUserData":          "upduserdata2",
    "party.leaderChanged":                "leaderchg",
    "party.promoteleader":                "promote",
    "party.kickplayer":                   "kick",
    "party.sendinvitation":               "sendinvite",
    "party.gameFinderFailed":             "gffailed",
    "Party.CreateInvitationCode":         "mkcode",
    "Party.CancelInvitationCode":         "cancelcode",
    "Party.UpdatePartyUserData":          "partyuserdata",
    "Steam.CreateLobby":                  "mklobby",
    "Steam.JoinLobby":                    "joinlobby",
    "Steam.UpdateLobbyJoinable":          "lobbyjoinable",
    "Steam.GetLobbyOwner":                "lobbyowner",
    "Steam.DecodePartyDataBearerTokens":  "decptoken",
    "SteamParty.CreatePartyDataBearerToken": "mkptoken",
    "NX.GetAdvertisedParties":            "nxads",
}

ROUTE_ABBR_MATCHMAKING = {
    "PartyMerging.GetMergerStatus": "mergerstatus",
    "PartyMerging.Start":           "mergestart",
    "PartyMerging.Stop":            "mergestop",
    "GameFinder.GetPublicStatus":   "gfpublic",
    "gamefinder.update":            "gfupd",
    "gamefinder.cancel":            "gfcancel",
}

ROUTE_ABBR_GAMESESSION = {
    "players.allReady":                                    "allready",
    "player.update":                                       "pupd",
    "player.ready":                                        "pready",
    "player.faulted":                                      "pfault",
    "dt.p2p":                                              "p2p",
    "DtGameSession.GetConnectionInfosForPlayer":           "gsconninfo",
    "GameSession.GetGameSessionConnectionUrl":             "gsurl",
    "GameSession.CreateP":                                 "gscreatep",
    "GameSession.GetP":                                    "gsgetp",
    "GameSession.GetTeams":                                "gsteams",
    "gamesession.getgamesessionsettings":                  "gssettings",
    "gamesession.postresults":                             "gsresults",
    "gamesession.reset":                                   "gsreset",
    "gamesession.updateshutdownmode":                      "gsshutdown",
    "JoinGameParty.RequestReservationInCurrentGamesession": "gsreserve",
    "sceneauthorization.gettoken":                         "sagettok",
}

# Per-kind route tables, for resolving an abbr given (kind, routeName).
ROUTE_ABBR_BY_KIND = {
    "authenticator": ROUTE_ABBR_AUTH,
    "friends":       ROUTE_ABBR_FRIENDS,
    "party-manager": ROUTE_ABBR_PARTY_MANAGER,
    "party":         ROUTE_ABBR_PARTY,
    "matchmaking":   ROUTE_ABBR_MATCHMAKING,
    "gamesession":   ROUTE_ABBR_GAMESESSION,
}

# Flat union of every known route -> abbr (RPC stream + all services), for a
# kind-independent lookup. Built from the tables above (data, evaluated once).
ROUTE_ABBR_ALL = {
    **RPC_STREAM_ABBR,
    **ROUTE_ABBR_AUTH,
    **ROUTE_ABBR_FRIENDS,
    **ROUTE_ABBR_PARTY_MANAGER,
    **ROUTE_ABBR_PARTY,
    **ROUTE_ABBR_MATCHMAKING,
    **ROUTE_ABBR_GAMESESSION,
}

# =========================================================================
# §8  Recurring msgpack schemas — which field(s) actually vary, and the hr
#     keyword + the map keys that carry the variable value(s). DATA the encoder
#     consults to collapse a long static structure to its meaningful signature.
# =========================================================================
# hr_keyword -> tuple of msgpack map keys whose values are emitted (in order).
# An empty tuple means "emit a count/length signature only".
SCHEMA_VARIABLE_FIELDS = {
    # §8.1 ConnectionMetadata (setmeta + connscene)
    "cmeta":        ("platform", "protocol", "version"),
    # §8.3 ConnectionResult (connscene reply); SceneHandle normalized to '*'
    "connres":      ("SceneHandle", "RouteMappings"),
    # §8.4 SceneInfosDto (sceneinfos reply)
    "sceneinfos":   ("SceneId",),
    # §8.10 PartyMerging.GetMergerStatus reply
    "mergerstatus": ("partiesCount", "playersCount"),
}

# Map keys whose scalar value is allocation noise: rendered as the wildcard '*'
# (symmetric, the ONLY normalization). A diff on these is NOT a real divergence.
NOISE_KEYS = frozenset({"SceneHandle"})

# Identity keys: always emitted VERBATIM (never masked) — a diff here is real.
IDENTITY_KEYS = frozenset({
    "sessionId", "SessionId", "Token", "token", "userId", "UserId",
    "leaderUserId", "LeaderUserId", "partyId", "PartyId", "lobbyId",
    "invitationCode", "DeploymentId",
})

# =========================================================================
# §9  Human-readable rendering constants
# =========================================================================
HR_MSG_SEP = " then "       # between messages in one datagram-burst
HR_KV_SEP = " "             # between key=value fields
HR_FORBIDDEN_SYMBOLS = "{}[]\":,"   # must never appear in an hr string
HR_OPAQUE_MAX = 64          # strings longer than this are truncated...
HR_OPAQUE_TRUNC = 16        # ...to first N chars, rendered '<first16>~<len>'
HR_WILDCARD = "*"           # noise-key normalized value
# A msgpack array often carries an embedded UTF-8/JSON blob flattened into a run
# of byte-valued fixints (e.g. 110 100 111 109 ... = "ndom..."). A run of >=
# HR_BYTES_MIN consecutive ints in 0..255 that is >= HR_BYTES_PRINT_FRAC
# printable ASCII is coalesced into a single 'txt<len>_<ascii>' token instead of
# dozens of bare integers. Purely numeric runs (counts, zero padding) stay int.
HR_BYTES_MIN = 6
HR_BYTES_PRINT_FRAC = 0.75

HR_BOOL_TRUE = "t"
HR_BOOL_FALSE = "f"
HR_NIL = "nil"
# binary -> "bin<len>:<first8hex>"; msgpack ext -> "ext<type>:<hex>"
HR_BIN_PREFIX = "bin"
HR_EXT_PREFIX = "ext"
