// dllmain.cpp -- shim bootstrap: load the renamed builtin winhttp, set up
// logging + config, expose shim_real_module()/shim_resolve()/shim_log() and the
// redirected-handle tracking used by the trampolines.
#include "shim.h"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <set>
#include <string>

// Proton's builtin winhttp is shipped renamed alongside the shim. DOT-FREE name
// (so the PE forwarders in winhttp_shim.def resolve: the loader appends '.dll'
// only when the module name has no extension).
static const wchar_t* kRealDllName = L"winhttp_real.dll";

static std::atomic<void*> g_real{nullptr};
static std::mutex g_log_mtx;
static FILE* g_log = nullptr;

// ---- real DLL ---------------------------------------------------------------
static void load_real() {
    if (g_real.load()) return;
    HMODULE h = GetModuleHandleW(kRealDllName);
    if (!h) h = LoadLibraryW(kRealDllName);
    g_real.store(reinterpret_cast<void*>(h));
    if (!h) {
        shim_log("shim_error",
                 "\"msg\":\"failed to load winhttp_real.dll\",\"gle\":" +
                     std::to_string(GetLastError()));
    } else {
        shim_log("shim_loaded_real", "\"dll\":\"winhttp_real.dll\"");
    }
}

void* shim_real_module() {
    if (!g_real.load()) load_real();
    return g_real.load();
}

void* shim_resolve(const char* name) {
    HMODULE h = reinterpret_cast<HMODULE>(shim_real_module());
    if (!h) return nullptr;
    void* p = reinterpret_cast<void*>(GetProcAddress(h, name));
    if (!p) shim_log("shim_resolve_miss", "\"fn\":" + shim_jstr(name));
    return p;
}

// ---- logging ----------------------------------------------------------------
static void open_log() {
    std::lock_guard<std::mutex> lk(g_log_mtx);
    if (g_log) return;
    char path[1024] = {0};
    DWORD n = GetEnvironmentVariableA("WINHTTP_SHIM_LOG", path, sizeof(path) - 1);
    const char* p = (n > 0 && n < sizeof(path)) ? path : "winhttp_shim.jsonl";
    g_log = fopen(p, "ab");
}

static std::string now_iso() {
    SYSTEMTIME st;
    GetSystemTime(&st);
    char buf[64];
    snprintf(buf, sizeof(buf), "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", st.wYear,
             st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
    return buf;
}

void shim_log(const char* event, const std::string& fields) {
    std::lock_guard<std::mutex> lk(g_log_mtx);
    if (!g_log) {
        char path[1024] = {0};
        DWORD n = GetEnvironmentVariableA("WINHTTP_SHIM_LOG", path, sizeof(path) - 1);
        const char* p = (n > 0 && n < sizeof(path)) ? path : "winhttp_shim.jsonl";
        g_log = fopen(p, "ab");
        if (!g_log) return;
    }
    std::string line = "{\"t\":\"" + now_iso() + "\",\"tid\":" +
                       std::to_string(GetCurrentThreadId()) + ",\"ev\":\"" + event +
                       "\"";
    if (!fields.empty()) line += "," + fields;
    line += "}\n";
    fwrite(line.data(), 1, line.size(), g_log);
    fflush(g_log);
}

// ---- string helpers ---------------------------------------------------------
std::string shim_jstr(const char* s) {
    if (!s) return "null";
    std::string out = "\"";
    for (const char* c = s; *c; ++c) {
        unsigned char ch = static_cast<unsigned char>(*c);
        switch (ch) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (ch < 0x20) {
                    char buf[8];
                    snprintf(buf, sizeof(buf), "\\u%04x", ch);
                    out += buf;
                } else {
                    out += static_cast<char>(ch);
                }
        }
    }
    out += "\"";
    return out;
}

std::string shim_jwstr(const wchar_t* s) {
    if (!s) return "null";
    // Narrow UTF-16 -> UTF-8 for logging (hostnames/paths are ASCII in practice).
    int len = WideCharToMultiByte(CP_UTF8, 0, s, -1, nullptr, 0, nullptr, nullptr);
    if (len <= 0) return "\"<wbad>\"";
    std::string narrow(static_cast<size_t>(len), '\0');
    WideCharToMultiByte(CP_UTF8, 0, s, -1, &narrow[0], len, nullptr, nullptr);
    if (!narrow.empty() && narrow.back() == '\0') narrow.pop_back();
    return shim_jstr(narrow.c_str());
}

// ---- config -----------------------------------------------------------------
static std::wstring env_w(const char* name, const std::wstring& dflt) {
    char buf[2048] = {0};
    DWORD n = GetEnvironmentVariableA(name, buf, sizeof(buf) - 1);
    if (n == 0 || n >= sizeof(buf)) return dflt;
    int wlen = MultiByteToWideChar(CP_UTF8, 0, buf, -1, nullptr, 0);
    if (wlen <= 0) return dflt;
    std::wstring w(static_cast<size_t>(wlen), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, buf, -1, &w[0], wlen);
    if (!w.empty() && w.back() == L'\0') w.pop_back();
    return w;
}

static std::wstring lower_w(std::wstring s) {
    for (auto& c : s) c = static_cast<wchar_t>(towlower(c));
    return s;
}

const ShimConfig& shim_config() {
    static ShimConfig cfg = [] {
        ShimConfig c;
        c.target_host = env_w("WINHTTP_SHIM_TARGET_HOST", L"127.0.0.1");
        std::wstring portw = env_w("WINHTTP_SHIM_TARGET_PORT", L"8080");
        c.target_port = _wtoi(portw.c_str());
        if (c.target_port <= 0) c.target_port = 8080;
        std::wstring hosts = env_w(
            "WINHTTP_SHIM_REDIRECT_HOSTS",
            L"dt-live.passtechgames.com,dt-live-2.passtechgames.com,"
            L"dt-live-3.passtechgames.com");
        size_t start = 0;
        while (start < hosts.size()) {
            size_t comma = hosts.find(L',', start);
            std::wstring tok = hosts.substr(
                start, comma == std::wstring::npos ? std::wstring::npos : comma - start);
            // trim spaces
            while (!tok.empty() && (tok.front() == L' ')) tok.erase(tok.begin());
            while (!tok.empty() && (tok.back() == L' ')) tok.pop_back();
            if (!tok.empty()) c.redirect_hosts.push_back(lower_w(tok));
            if (comma == std::wstring::npos) break;
            start = comma + 1;
        }
        std::wstring lb = env_w("WINHTTP_SHIM_REDIRECT_LOOPBACK", L"1");
        c.redirect_loopback =
            !(lb == L"0" || lb == L"" || lb == L"false" || lb == L"no");
        return c;
    }();
    return cfg;
}

bool shim_should_redirect(const wchar_t* server_name) {
    if (!server_name) return false;
    std::wstring host = lower_w(server_name);
    for (const auto& h : shim_config().redirect_hosts) {
        if (host == h) return true;
    }
    return false;
}

bool shim_is_loopback_literal(const wchar_t* server_name, INTERNET_PORT port) {
    if (!server_name) return false;
    const auto& cfg = shim_config();
    if (!cfg.redirect_loopback) return false;
    // Must look like a dotted IPv4 literal 127.x.y.z (all-numeric octets).
    std::wstring h(server_name);
    if (h.rfind(L"127.", 0) != 0) return false;
    for (wchar_t ch : h) {
        if (ch != L'.' && (ch < L'0' || ch > L'9')) return false;
    }
    // Don't re-redirect our own backend (avoid a self-loop).
    if (h == cfg.target_host && static_cast<int>(port) == cfg.target_port) {
        return false;
    }
    return true;
}

// ---- redirected-handle tracking ---------------------------------------------
static std::mutex g_set_mtx;
static std::set<HINTERNET> g_redirected;

void shim_mark_redirected(HINTERNET h) {
    if (!h) return;
    std::lock_guard<std::mutex> lk(g_set_mtx);
    g_redirected.insert(h);
}

bool shim_is_redirected(HINTERNET h) {
    if (!h) return false;
    std::lock_guard<std::mutex> lk(g_set_mtx);
    return g_redirected.count(h) != 0;
}

void shim_clear_redirected(HINTERNET h) {
    if (!h) return;
    std::lock_guard<std::mutex> lk(g_set_mtx);
    g_redirected.erase(h);
}

// ---- entry point ------------------------------------------------------------
BOOL APIENTRY DllMain(HMODULE, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        open_log();
        shim_log("shim_attach", "\"pid\":" + std::to_string(GetCurrentProcessId()));
        const auto& c = shim_config();
        shim_log("shim_config",
                 "\"target_host\":" + shim_jwstr(c.target_host.c_str()) +
                     ",\"target_port\":" + std::to_string(c.target_port) +
                     ",\"redirect_count\":" + std::to_string(c.redirect_hosts.size()));
    } else if (reason == DLL_PROCESS_DETACH) {
        shim_log("shim_detach", "");
    }
    return TRUE;
}
