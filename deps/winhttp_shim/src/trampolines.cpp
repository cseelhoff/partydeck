// trampolines.cpp -- the HOOKED winhttp exports.
//
// Four functions are intercepted; every other winhttp symbol is a zero-code
// forward to winhttp_real.dll (see winhttp_shim.def / generate_def.sh).
//
//   WinHttpConnect     -> rewrite our federation hosts (dt-live*) to the local
//                         backend (127.0.0.1:<port>); remember the handle.
//   WinHttpOpenRequest -> for those remembered handles, clear WINHTTP_FLAG_SECURE
//                         so the request goes out as PLAIN HTTP (no TLS, no cert,
//                         no CA-in-prefix -- the whole point of the refactor).
//   WinHttpCloseHandle -> forget the handle (avoid stale reuse).
//   WinHttpSendRequest -> observational logging only (URL/divergence analysis).
//
// All signatures match <winhttp.h>. We call the real implementation via REAL().
#include "shim.h"

extern "C" {

// ---- WinHttpConnect ---------------------------------------------------------
HINTERNET WINAPI WinHttpConnect(HINTERNET hSession, LPCWSTR pswzServerName,
                                INTERNET_PORT nServerPort, DWORD dwReserved) {
    auto real = REAL(WinHttpConnect);
    if (!real) {
        SetLastError(ERROR_PROC_NOT_FOUND);
        return nullptr;
    }

    bool by_host = shim_should_redirect(pswzServerName);
    bool by_loopback = !by_host &&
                       shim_is_loopback_literal(pswzServerName, nServerPort);
    bool redirect = by_host || by_loopback;
    // Diagnostic: log EVERY connect so we can see exactly which hosts the game
    // uses (and catch near-misses like a trailing-dot FQDN that fail the match).
    shim_log("WinHttpConnect",
             "\"host\":" + shim_jwstr(pswzServerName) +
                 ",\"port\":" + std::to_string(nServerPort) +
                 ",\"redirect\":" + (redirect ? "true" : "false") +
                 ",\"reason\":\"" + (by_host ? "host" : (by_loopback ? "loopback" : "none")) + "\"");

    if (redirect) {
        const auto& cfg = shim_config();
        INTERNET_PORT newport = static_cast<INTERNET_PORT>(cfg.target_port);
        shim_log("WinHttpConnect.redirect",
                 "\"from_host\":" + shim_jwstr(pswzServerName) +
                     ",\"from_port\":" + std::to_string(nServerPort) +
                     ",\"to_host\":" + shim_jwstr(cfg.target_host.c_str()) +
                     ",\"to_port\":" + std::to_string(newport));
        HINTERNET h = real(hSession, cfg.target_host.c_str(), newport, dwReserved);
        if (h) shim_mark_redirected(h);
        return h;
    }

    return real(hSession, pswzServerName, nServerPort, dwReserved);
}

// ---- WinHttpOpenRequest -----------------------------------------------------
HINTERNET WINAPI WinHttpOpenRequest(HINTERNET hConnect, LPCWSTR pwszVerb,
                                    LPCWSTR pwszObjectName, LPCWSTR pwszVersion,
                                    LPCWSTR pwszReferrer, LPCWSTR* ppwszAcceptTypes,
                                    DWORD dwFlags) {
    auto real = REAL(WinHttpOpenRequest);
    if (!real) {
        SetLastError(ERROR_PROC_NOT_FOUND);
        return nullptr;
    }

    bool redirected = shim_is_redirected(hConnect);
    // Diagnostic: log every request's object/path + whether its connection is
    // one we redirected.
    shim_log("WinHttpOpenRequest",
             "\"verb\":" + shim_jwstr(pwszVerb) +
                 ",\"object\":" + shim_jwstr(pwszObjectName) +
                 ",\"secure\":" + ((dwFlags & WINHTTP_FLAG_SECURE) ? "true" : "false") +
                 ",\"redirected_conn\":" + (redirected ? "true" : "false"));

    if (redirected && (dwFlags & WINHTTP_FLAG_SECURE)) {
        DWORD cleared = dwFlags & ~static_cast<DWORD>(WINHTTP_FLAG_SECURE);
        shim_log("WinHttpOpenRequest.unsecure",
                 "\"verb\":" + shim_jwstr(pwszVerb) +
                     ",\"object\":" + shim_jwstr(pwszObjectName) +
                     ",\"flags_in\":" + std::to_string(dwFlags) +
                     ",\"flags_out\":" + std::to_string(cleared));
        return real(hConnect, pwszVerb, pwszObjectName, pwszVersion, pwszReferrer,
                    ppwszAcceptTypes, cleared);
    }

    return real(hConnect, pwszVerb, pwszObjectName, pwszVersion, pwszReferrer,
                ppwszAcceptTypes, dwFlags);
}

// ---- WinHttpCloseHandle -----------------------------------------------------
BOOL WINAPI WinHttpCloseHandle(HINTERNET hInternet) {
    auto real = REAL(WinHttpCloseHandle);
    if (!real) {
        SetLastError(ERROR_PROC_NOT_FOUND);
        return FALSE;
    }
    shim_clear_redirected(hInternet);  // safe even if not tracked
    return real(hInternet);
}

// ---- WinHttpSendRequest (observational) -------------------------------------
BOOL WINAPI WinHttpSendRequest(HINTERNET hRequest, LPCWSTR lpszHeaders,
                               DWORD dwHeadersLength, LPVOID lpOptional,
                               DWORD dwOptionalLength, DWORD dwTotalLength,
                               DWORD_PTR dwContext) {
    auto real = REAL(WinHttpSendRequest);
    if (!real) {
        SetLastError(ERROR_PROC_NOT_FOUND);
        return FALSE;
    }
    shim_log("WinHttpSendRequest",
             "\"hdr_len\":" + std::to_string(dwHeadersLength) +
                 ",\"opt_len\":" + std::to_string(dwOptionalLength) +
                 ",\"total_len\":" + std::to_string(dwTotalLength));
    return real(hRequest, lpszHeaders, dwHeadersLength, lpOptional,
                dwOptionalLength, dwTotalLength, dwContext);
}

}  // extern "C"
