# Ravenswatch.exe import map — shim feasibility

Generated with `deps/eos_shim/pe_imports.py` against the retail
`Ravenswatch.exe` (23 MB, 30 May build) in the Steam install dir.

## DLLs imported by the game (IAT)

| DLL | funcs | relevant? |
|-----|------:|-----------|
| EOSSDK-Win64-Shipping.dll | 82 | **YES — our shim target** |
| WS2_32.dll | 19 | **YES — the RakNet/Stormancer UDP transport** |
| WINHTTP.dll | 17 | Stormancer HTTP (federation/auth/token), TLS |
| WININET.dll | 7 | secondary http |
| KERNEL32 / USER32 / ADVAPI32 / GDI32 / SHELL32 / ole32 / OLEAUT32 | — | OS |
| CRYPT32 / bcrypt / SETUPAPI / VERSION-ish | — | crypto/util |
| d3d12 / dxgi | 3 | render |
| fmod / fmodstudio / xaudio | — | audio |
| DINPUT8 / XINPUT9_1_0 / libScePad | — | input |
| MFPlat / MFReadWrite | 5 | media foundation (video) |
| IPHLPAPI | 1 | adapter enum |

**NOT in the IAT:** `steam_api64.dll`. The game does **not** statically link
Steam. (`steam_api64.dll` is present in the dir but only gets loaded — if at all —
dynamically by Stormancer's Steam plugin via `LoadLibrary`.)

## Architectural reality (from exe string table)

Stormancer is **statically compiled into `Ravenswatch.exe`** — the binary
contains full C++ class symbols:

- `Stormancer::Party::Party_Impl`, `PartyService::sendInvitation`, `AdvertisedParty`
- `Stormancer::Steam::details::SteamImpl::{initialize,createLobby,onJoinLobbyAsync,onCreateLobbyAsync}`
- `Stormancer::web::http::http_response`, `Stormancer::json::value`, `Federation`, `SceneEndpoint`

So **RakNet is NOT a separate DLL** — it is inside the exe and reaches the
network through `WS2_32.dll` (UDP by ordinal). There is no RakNet/Stormancer
DLL to proxy.

## WS2_32.dll imports (the RakNet/Stormancer transport seam)

By ordinal (standard ws2_32 ordinals) + by name:

| ordinal | function | note |
|--------:|----------|------|
| 2 | bind | |
| 3 | closesocket | |
| 6 | getsockname | |
| 7 | getsockopt | |
| 8 | htonl | |
| 9 | htons | |
| 10 | ioctlsocket | non-blocking |
| 15 | ntohs | |
| **17** | **recvfrom** | **inbound RakNet datagrams** |
| **20** | **sendto** | **outbound RakNet datagrams** |
| 21 | setsockopt | |
| 23 | socket | |
| 57 | WSARecv | |
| 111 | WSAGetLastError | |
| 115 | WSAStartup | |
| 116 | WSACleanup | |
| — | getaddrinfo / freeaddrinfo / getnameinfo | DNS resolve of dt-live |

`sendto`/`recvfrom` carry the entire RakNet/Stormancer UDP flow — the same bytes
the pcap captures. A ws2_32 proxy would only add value if it sees plaintext
*before* RakNet encrypts; Stormancer's transport to dt-live is already decodable
from pcap by `src/raknet.py`, so a winsock shim is largely redundant with the
existing capture.

## Shim plan (revised by these facts)

1. **EOS shim — expand (primary).** The IAT binds 82 EOS funcs; our proxy
   already covers them all (hooked set logged, rest forwarded). Grow the HOOKED
   set to the full join control plane: `EOS_Lobby_CreateLobbySearch`,
   `EOS_Lobby_CopyLobbyDetailsHandle`, `EOS_LobbySearch_{SetLobbyId,Find,
   GetSearchResultCount,CopySearchResultByIndex}`, `EOS_LobbyDetails_*`,
   `EOS_Lobby_GetRTCRoomName`, the P2P open/close notifies, and `EOS_Auth_Login`.
   Everything else stays a zero-code forward.

2. **Steam shim — conditional.** Only useful if the Stormancer Steam plugin is
   actually active online (the active identity provider appears to be EOS, not
   Steam). Confirm at runtime whether `steam_api64.dll` is loaded during an
   online join before investing; if loaded, a flat-C + ordinal-forwarding proxy
   logging `SteamMatchmaking::{CreateLobby,JoinLobby,SetLobbyData,...}` is doable.

3. **RakNet shim — not a DLL.** Replaced by either (a) the existing pcap +
   `src/raknet.py` decode (recommended; already authoritative), or (b) a
   `ws2_32.dll` proxy hooking `sendto`/`recvfrom` if a pre-wire view is wanted.
