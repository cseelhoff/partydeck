// trampolines.cpp -- the HOOKED winhttp exports.
//
// The shim has TWO modes (WINHTTP_SHIM_MODE, see shim.h):
//
//   REDIRECT (default) -- offline emu steering:
//     WinHttpConnect     -> rewrite federation hosts (dt-live*) / stale loopback
//                           literals (127.x.y.z) to the local backend
//                           (127.0.0.1:<port>); remember the handle.
//     WinHttpOpenRequest -> for remembered handles, clear WINHTTP_FLAG_SECURE so
//                           the request goes out as PLAIN HTTP (no TLS/cert/CA).
//
//   CAPTURE -- transparent tap for diffing the working online "config C" vs the
//     emu. NOTHING is redirected; every call forwards to winhttp_real untouched.
//     We log the full request (verb/url/headers/body) and response (status/
//     headers/body) per request handle, flushed on WinHttpCloseHandle. Because
//     the shim sits ABOVE TLS (winhttp_real does the real handshake against the
//     real cert), TLS/SPKI pinning cannot affect this capture.
//
// Hooked exports (keep in sync with generate_def.sh HOOKED):
//   WinHttpConnect, WinHttpOpenRequest, WinHttpAddRequestHeaders,
//   WinHttpSendRequest, WinHttpWriteData, WinHttpReceiveResponse,
//   WinHttpReadData, WinHttpCloseHandle.
// Every other winhttp symbol is a zero-code forward to winhttp_real.dll.
//
// All signatures match <winhttp.h>. We call the real implementation via REAL().
#include "shim.h"

#include <map>
#include <mutex>
#include <string>

namespace {

// ---- wide -> utf8 helpers (raw, for storing/building, not JSON) -------------
std::string w2u(const wchar_t* s) {
    if (!s) return std::string();
    int len = WideCharToMultiByte(CP_UTF8, 0, s, -1, nullptr, 0, nullptr, nullptr);
    if (len <= 0) return std::string();
    std::string out(static_cast<size_t>(len), '\0');
    WideCharToMultiByte(CP_UTF8, 0, s, -1, &out[0], len, nullptr, nullptr);
    if (!out.empty() && out.back() == '\0') out.pop_back();
    return out;
}

// Narrow a wide buffer of `wlen` chars; wlen==(DWORD)-1 means null-terminated.
std::string w2u_n(const wchar_t* s, DWORD wlen) {
    if (!s) return std::string();
    int cch = (wlen == static_cast<DWORD>(-1L) || wlen == 0) ? -1
                                                             : static_cast<int>(wlen);
    int len = WideCharToMultiByte(CP_UTF8, 0, s, cch, nullptr, 0, nullptr, nullptr);
    if (len <= 0) return std::string();
    std::string out(static_cast<size_t>(len), '\0');
    WideCharToMultiByte(CP_UTF8, 0, s, cch, &out[0], len, nullptr, nullptr);
    if (cch == -1 && !out.empty() && out.back() == '\0') out.pop_back();
    return out;
}

// ---- capture-mode per-handle context ----------------------------------------
struct ConnCtx {
    std::string host;
    int         port = 0;
};

struct ReqCtx {
    std::string host;
    int         port = 0;
    bool        secure = false;
    std::string verb;
    std::string object;
    std::string req_headers;
    std::string req_body;
    bool        req_body_truncated = false;
    long        status = 0;
    std::string resp_headers;
    std::string resp_body;
    bool        resp_body_truncated = false;
};

std::mutex                      g_cap_mtx;
std::map<HINTERNET, ConnCtx>    g_conns;   // connect handle -> host/port
std::map<HINTERNET, ReqCtx>     g_reqs;    // request handle -> exchange

// ---- async status-callback interception -------------------------------------
// cpprestsdk (the game's HTTP lib) drives winhttp in ASYNC mode: WinHttpReadData
// returns immediately with a NULL byte-count and the actual body bytes arrive
// later via the status callback (WINHTTP_CALLBACK_STATUS_READ_COMPLETE), so the
// synchronous WinHttpReadData hook below never sees them. To capture async
// response bodies we wrap WinHttpSetStatusCallback: install our own thunk,
// remember the app's callback, tap READ_COMPLETE, then forward unchanged.
std::mutex              g_cb_mtx;
WINHTTP_STATUS_CALLBACK g_app_cb = nullptr;   // app's real callback (cpprestsdk)

bool capture_mode() { return shim_config().mode == ShimMode::Capture; }

// Append up to capture_body_max bytes total into `dst`; set `trunc` if clipped.
void cap_append(std::string& dst, bool& trunc, const char* data, size_t len) {
    if (!data || len == 0) return;
    size_t cap = shim_config().capture_body_max;
    if (dst.size() >= cap) { trunc = true; return; }
    size_t room = cap - dst.size();
    size_t take = (len > room) ? room : len;
    dst.append(data, take);
    if (take < len) trunc = true;
}

// Emit one "capture" jsonl record for a finished request. Caller holds g_cap_mtx.
void cap_flush(const ReqCtx& r) {
    std::string scheme = r.secure ? "https" : "http";
    std::string url = scheme + "://" + r.host;
    if (r.port) url += ":" + std::to_string(r.port);
    url += r.object;
    std::string fields =
        "\"url\":" + shim_jstr(url.c_str()) +
        ",\"verb\":" + shim_jstr(r.verb.c_str()) +
        ",\"host\":" + shim_jstr(r.host.c_str()) +
        ",\"port\":" + std::to_string(r.port) +
        ",\"secure\":" + (r.secure ? "true" : "false") +
        ",\"status\":" + std::to_string(r.status) +
        ",\"req_headers\":" + shim_jbytes(r.req_headers.data(), r.req_headers.size()) +
        ",\"req_body\":" + shim_jbytes(r.req_body.data(), r.req_body.size()) +
        ",\"req_body_len\":" + std::to_string(r.req_body.size()) +
        ",\"req_body_truncated\":" + (r.req_body_truncated ? "true" : "false") +
        ",\"resp_headers\":" + shim_jbytes(r.resp_headers.data(), r.resp_headers.size()) +
        ",\"resp_body\":" + shim_jbytes(r.resp_body.data(), r.resp_body.size()) +
        ",\"resp_body_len\":" + std::to_string(r.resp_body.size()) +
        ",\"resp_body_truncated\":" + (r.resp_body_truncated ? "true" : "false");
    shim_log("capture", fields);
}

// Our status-callback thunk: tap async READ_COMPLETE bodies, forward everything
// to the app's real callback unchanged. Runs on winhttp's worker thread.
void CALLBACK shim_status_callback(HINTERNET hInternet, DWORD_PTR dwContext,
                                   DWORD dwInternetStatus,
                                   LPVOID lpvStatusInformation,
                                   DWORD dwStatusInformationLength) {
    if (dwInternetStatus == WINHTTP_CALLBACK_STATUS_READ_COMPLETE &&
        lpvStatusInformation && dwStatusInformationLength > 0) {
        // lpvStatusInformation points to the buffer passed to WinHttpReadData;
        // dwStatusInformationLength is the number of bytes actually read.
        std::lock_guard<std::mutex> lk(g_cap_mtx);
        auto it = g_reqs.find(hInternet);
        if (it != g_reqs.end()) {
            cap_append(it->second.resp_body, it->second.resp_body_truncated,
                       static_cast<const char*>(lpvStatusInformation),
                       dwStatusInformationLength);
        }
    }
    WINHTTP_STATUS_CALLBACK app;
    { std::lock_guard<std::mutex> lk(g_cb_mtx); app = g_app_cb; }
    if (app) {
        app(hInternet, dwContext, dwInternetStatus, lpvStatusInformation,
            dwStatusInformationLength);
    }
}

}  // namespace

extern "C" {

// ---- WinHttpConnect ---------------------------------------------------------
HINTERNET WINAPI WinHttpConnect(HINTERNET hSession, LPCWSTR pswzServerName,
                                INTERNET_PORT nServerPort, DWORD dwReserved) {
    auto real = REAL(WinHttpConnect);
    if (!real) {
        SetLastError(ERROR_PROC_NOT_FOUND);
        return nullptr;
    }

    if (capture_mode()) {
        HINTERNET h = real(hSession, pswzServerName, nServerPort, dwReserved);
        shim_log("WinHttpConnect",
                 "\"host\":" + shim_jwstr(pswzServerName) +
                     ",\"port\":" + std::to_string(nServerPort) +
                     ",\"mode\":\"capture\"");
        if (h) {
            std::lock_guard<std::mutex> lk(g_cap_mtx);
            g_conns[h] = ConnCtx{w2u(pswzServerName), static_cast<int>(nServerPort)};
        }
        return h;
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

    if (capture_mode()) {
        HINTERNET h = real(hConnect, pwszVerb, pwszObjectName, pwszVersion,
                           pwszReferrer, ppwszAcceptTypes, dwFlags);
        if (h) {
            std::lock_guard<std::mutex> lk(g_cap_mtx);
            ReqCtx r;
            auto it = g_conns.find(hConnect);
            if (it != g_conns.end()) {
                r.host = it->second.host;
                r.port = it->second.port;
            }
            r.secure = (dwFlags & WINHTTP_FLAG_SECURE) != 0;
            r.verb = pwszVerb ? w2u(pwszVerb) : std::string("GET");
            r.object = pwszObjectName ? w2u(pwszObjectName) : std::string("/");
            g_reqs[h] = std::move(r);
        }
        return h;
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

// ---- WinHttpAddRequestHeaders -----------------------------------------------
BOOL WINAPI WinHttpAddRequestHeaders(HINTERNET hRequest, LPCWSTR lpszHeaders,
                                     DWORD dwHeadersLength, DWORD dwModifiers) {
    auto real = REAL(WinHttpAddRequestHeaders);
    if (!real) {
        SetLastError(ERROR_PROC_NOT_FOUND);
        return FALSE;
    }
    BOOL ok = real(hRequest, lpszHeaders, dwHeadersLength, dwModifiers);
    if (capture_mode() && lpszHeaders) {
        std::string hh = w2u_n(lpszHeaders, dwHeadersLength);
        std::lock_guard<std::mutex> lk(g_cap_mtx);
        auto it = g_reqs.find(hRequest);
        if (it != g_reqs.end()) {
            it->second.req_headers += hh;
            it->second.req_headers += "\r\n";
        }
    }
    return ok;
}

// ---- WinHttpSendRequest -----------------------------------------------------
BOOL WINAPI WinHttpSendRequest(HINTERNET hRequest, LPCWSTR lpszHeaders,
                               DWORD dwHeadersLength, LPVOID lpOptional,
                               DWORD dwOptionalLength, DWORD dwTotalLength,
                               DWORD_PTR dwContext) {
    auto real = REAL(WinHttpSendRequest);
    if (!real) {
        SetLastError(ERROR_PROC_NOT_FOUND);
        return FALSE;
    }

    if (capture_mode()) {
        std::lock_guard<std::mutex> lk(g_cap_mtx);
        auto it = g_reqs.find(hRequest);
        if (it != g_reqs.end()) {
            if (lpszHeaders && dwHeadersLength != 0) {
                it->second.req_headers += w2u_n(lpszHeaders, dwHeadersLength);
                it->second.req_headers += "\r\n";
            }
            if (lpOptional && dwOptionalLength > 0) {
                cap_append(it->second.req_body, it->second.req_body_truncated,
                           static_cast<const char*>(lpOptional), dwOptionalLength);
            }
        }
    } else {
        shim_log("WinHttpSendRequest",
                 "\"hdr_len\":" + std::to_string(dwHeadersLength) +
                     ",\"opt_len\":" + std::to_string(dwOptionalLength) +
                     ",\"total_len\":" + std::to_string(dwTotalLength));
    }
    return real(hRequest, lpszHeaders, dwHeadersLength, lpOptional,
                dwOptionalLength, dwTotalLength, dwContext);
}

// ---- WinHttpWriteData (streamed request body) -------------------------------
BOOL WINAPI WinHttpWriteData(HINTERNET hRequest, LPCVOID lpBuffer,
                             DWORD dwNumberOfBytesToWrite,
                             LPDWORD lpdwNumberOfBytesWritten) {
    auto real = REAL(WinHttpWriteData);
    if (!real) {
        SetLastError(ERROR_PROC_NOT_FOUND);
        return FALSE;
    }
    BOOL ok = real(hRequest, lpBuffer, dwNumberOfBytesToWrite,
                   lpdwNumberOfBytesWritten);
    if (ok && capture_mode() && lpBuffer) {
        DWORD wrote = lpdwNumberOfBytesWritten ? *lpdwNumberOfBytesWritten
                                               : dwNumberOfBytesToWrite;
        std::lock_guard<std::mutex> lk(g_cap_mtx);
        auto it = g_reqs.find(hRequest);
        if (it != g_reqs.end()) {
            cap_append(it->second.req_body, it->second.req_body_truncated,
                       static_cast<const char*>(lpBuffer), wrote);
        }
    }
    return ok;
}

// ---- WinHttpReceiveResponse (capture status + response headers) -------------
BOOL WINAPI WinHttpReceiveResponse(HINTERNET hRequest, LPVOID lpReserved) {
    auto real = REAL(WinHttpReceiveResponse);
    if (!real) {
        SetLastError(ERROR_PROC_NOT_FOUND);
        return FALSE;
    }
    BOOL ok = real(hRequest, lpReserved);
    if (ok && capture_mode()) {
        long        status = 0;
        std::string resp_headers;
        auto qh = REAL(WinHttpQueryHeaders);
        if (qh) {
            DWORD st = 0, sz = sizeof(st);
            if (qh(hRequest, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                   WINHTTP_HEADER_NAME_BY_INDEX, &st, &sz, WINHTTP_NO_HEADER_INDEX)) {
                status = static_cast<long>(st);
            }
            DWORD hsz = 0;
            qh(hRequest, WINHTTP_QUERY_RAW_HEADERS_CRLF, WINHTTP_HEADER_NAME_BY_INDEX,
               nullptr, &hsz, WINHTTP_NO_HEADER_INDEX);
            if (GetLastError() == ERROR_INSUFFICIENT_BUFFER && hsz > 0) {
                std::wstring wbuf(hsz / sizeof(wchar_t) + 1, L'\0');
                if (qh(hRequest, WINHTTP_QUERY_RAW_HEADERS_CRLF,
                       WINHTTP_HEADER_NAME_BY_INDEX, &wbuf[0], &hsz,
                       WINHTTP_NO_HEADER_INDEX)) {
                    resp_headers = w2u(wbuf.c_str());
                }
            }
        }
        std::lock_guard<std::mutex> lk(g_cap_mtx);
        auto it = g_reqs.find(hRequest);
        if (it != g_reqs.end()) {
            it->second.status = status;
            it->second.resp_headers = std::move(resp_headers);
        }
    }
    return ok;
}

// ---- WinHttpReadData (streamed response body, SYNC path) --------------------
// NOTE: in async mode (cpprestsdk) the byte-count pointer is NULL and the data
// arrives via WINHTTP_CALLBACK_STATUS_READ_COMPLETE instead -- captured in
// shim_status_callback. This hook only catches the synchronous case, so the two
// never double-count.
BOOL WINAPI WinHttpReadData(HINTERNET hRequest, LPVOID lpBuffer,
                            DWORD dwNumberOfBytesToRead,
                            LPDWORD lpdwNumberOfBytesRead) {
    auto real = REAL(WinHttpReadData);
    if (!real) {
        SetLastError(ERROR_PROC_NOT_FOUND);
        return FALSE;
    }
    BOOL ok = real(hRequest, lpBuffer, dwNumberOfBytesToRead,
                   lpdwNumberOfBytesRead);
    if (ok && capture_mode() && lpBuffer && lpdwNumberOfBytesRead &&
        *lpdwNumberOfBytesRead > 0) {
        std::lock_guard<std::mutex> lk(g_cap_mtx);
        auto it = g_reqs.find(hRequest);
        if (it != g_reqs.end()) {
            cap_append(it->second.resp_body, it->second.resp_body_truncated,
                       static_cast<const char*>(lpBuffer), *lpdwNumberOfBytesRead);
        }
    }
    return ok;
}

// ---- WinHttpSetStatusCallback (wrap async callback to tap response bodies) ---
WINHTTP_STATUS_CALLBACK WINAPI WinHttpSetStatusCallback(
    HINTERNET hInternet, WINHTTP_STATUS_CALLBACK lpfnInternetCallback,
    DWORD dwNotificationFlags, DWORD_PTR dwReserved) {
    auto real = REAL(WinHttpSetStatusCallback);
    if (!real) {
        SetLastError(ERROR_PROC_NOT_FOUND);
        return WINHTTP_INVALID_STATUS_CALLBACK;
    }
    if (!capture_mode()) {
        return real(hInternet, lpfnInternetCallback, dwNotificationFlags,
                    dwReserved);
    }
    // Remember the app's callback and install our thunk in its place. Forward
    // the app's exact notification flags so we never deliver notifications the
    // app didn't request (cpprestsdk asks for ALL_COMPLETIONS -> READ_COMPLETE).
    WINHTTP_STATUS_CALLBACK prev_app;
    {
        std::lock_guard<std::mutex> lk(g_cb_mtx);
        prev_app = g_app_cb;
        g_app_cb = lpfnInternetCallback;
    }
    WINHTTP_STATUS_CALLBACK installed =
        lpfnInternetCallback ? shim_status_callback : nullptr;
    WINHTTP_STATUS_CALLBACK r =
        real(hInternet, installed, dwNotificationFlags, dwReserved);
    if (r == WINHTTP_INVALID_STATUS_CALLBACK) {
        // restore on failure
        std::lock_guard<std::mutex> lk(g_cb_mtx);
        g_app_cb = prev_app;
        return r;
    }
    // Return the previous APP callback (not our thunk) so the app sees expected
    // semantics.
    return prev_app;
}

// ---- WinHttpCloseHandle -----------------------------------------------------
BOOL WINAPI WinHttpCloseHandle(HINTERNET hInternet) {
    auto real = REAL(WinHttpCloseHandle);
    if (!real) {
        SetLastError(ERROR_PROC_NOT_FOUND);
        return FALSE;
    }
    if (capture_mode()) {
        std::lock_guard<std::mutex> lk(g_cap_mtx);
        auto it = g_reqs.find(hInternet);
        if (it != g_reqs.end()) {
            cap_flush(it->second);   // one full request/response record
            g_reqs.erase(it);
        }
        g_conns.erase(hInternet);    // safe even if not a connect handle
    } else {
        shim_clear_redirected(hInternet);  // safe even if not tracked
    }
    return real(hInternet);
}

}  // extern "C"
