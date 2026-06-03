// Minimal winhttp shim smoke test. Loads winhttp (via the shim if the override
// is active), opens a session, connects to a redirect host, opens a request,
// and sends it -- exercising every hooked path. Prints results to stdout so we
// can see exactly where it fails.
#include <windows.h>
#include <winhttp.h>
#include <stdio.h>

int wmain(void) {
    wprintf(L"[test] WinHttpOpen...\n"); fflush(stdout);
    HINTERNET hSession = WinHttpOpen(L"shimtest/1.0",
                                     WINHTTP_ACCESS_TYPE_NO_PROXY,
                                     WINHTTP_NO_PROXY_NAME,
                                     WINHTTP_NO_PROXY_BYPASS, 0);
    wprintf(L"[test] hSession=%p gle=%lu\n", hSession, GetLastError()); fflush(stdout);
    if (!hSession) return 1;

    wprintf(L"[test] WinHttpConnect dt-live.passtechgames.com:443...\n"); fflush(stdout);
    HINTERNET hConn = WinHttpConnect(hSession, L"dt-live.passtechgames.com",
                                     INTERNET_DEFAULT_HTTPS_PORT, 0);
    wprintf(L"[test] hConn=%p gle=%lu\n", hConn, GetLastError()); fflush(stdout);
    if (!hConn) return 2;

    wprintf(L"[test] WinHttpOpenRequest GET /_federation (SECURE)...\n"); fflush(stdout);
    HINTERNET hReq = WinHttpOpenRequest(hConn, L"GET", L"/_federation",
                                        NULL, WINHTTP_NO_REFERER,
                                        WINHTTP_DEFAULT_ACCEPT_TYPES,
                                        WINHTTP_FLAG_SECURE);
    wprintf(L"[test] hReq=%p gle=%lu\n", hReq, GetLastError()); fflush(stdout);
    if (!hReq) return 3;

    wprintf(L"[test] WinHttpSendRequest...\n"); fflush(stdout);
    BOOL ok = WinHttpSendRequest(hReq, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                                 WINHTTP_NO_REQUEST_DATA, 0, 0, 0);
    wprintf(L"[test] send ok=%d gle=%lu\n", ok, GetLastError()); fflush(stdout);

    if (ok) {
        ok = WinHttpReceiveResponse(hReq, NULL);
        wprintf(L"[test] recv ok=%d gle=%lu\n", ok, GetLastError()); fflush(stdout);
        DWORD status = 0, len = sizeof(status);
        WinHttpQueryHeaders(hReq,
            WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            WINHTTP_HEADER_NAME_BY_INDEX, &status, &len, WINHTTP_NO_HEADER_INDEX);
        wprintf(L"[test] HTTP status=%lu\n", status); fflush(stdout);
    }

    WinHttpCloseHandle(hReq);
    WinHttpCloseHandle(hConn);
    WinHttpCloseHandle(hSession);
    wprintf(L"[test] done\n"); fflush(stdout);
    return 0;
}
