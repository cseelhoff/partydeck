// dllmain.cpp -- proxy bootstrap + logging for the steam_api64 shim.
//
// Loads the renamed genuine Steam API (steam_api64_real.dll) and exposes a
// thread-safe JSONL logger reused by the hooked trampolines.
#include "shim.h"

#include <cstdio>
#include <mutex>

// ---- real DLL access --------------------------------------------------------
static std::mutex     g_mod_mtx;
static HMODULE        g_real = nullptr;

void* shim_real_module() {
    std::lock_guard<std::mutex> lk(g_mod_mtx);
    if (!g_real) {
        // DOT-FREE base name; the file is steam_api64_real.dll next to the game.
        g_real = LoadLibraryW(L"steam_api64_real.dll");
    }
    return g_real;
}

void* shim_resolve(const char* name) {
    HMODULE m = static_cast<HMODULE>(shim_real_module());
    if (!m) return nullptr;
    return reinterpret_cast<void*>(GetProcAddress(m, name));
}

// ---- logging ----------------------------------------------------------------
static std::mutex g_log_mtx;
static FILE*      g_log = nullptr;

static void open_log() {
    if (g_log) return;
    char path[1024] = {0};
    DWORD n = GetEnvironmentVariableA("STEAM_SHIM_LOG", path, sizeof(path) - 1);
    const char* p = (n > 0 && n < sizeof(path)) ? path : "steam_api_shim.jsonl";
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
        open_log();
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
                if (ch < 0x20 || ch >= 0x7f) {
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

std::string shim_jhex(const void* data, size_t len) {
    if (!data) return "null";
    static const char* hx = "0123456789abcdef";
    const unsigned char* p = static_cast<const unsigned char*>(data);
    std::string out = "\"";
    out.reserve(len * 2 + 2);
    for (size_t i = 0; i < len; ++i) {
        out += hx[p[i] >> 4];
        out += hx[p[i] & 0xf];
    }
    out += "\"";
    return out;
}

// ---- entry ------------------------------------------------------------------
BOOL APIENTRY DllMain(HMODULE, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        shim_log("shim_attach", "\"pid\":" + std::to_string(GetCurrentProcessId()) +
                                    ",\"dll\":\"steam_api64\"");
        if (!shim_real_module()) {
            shim_log("shim_error", "\"msg\":\"failed to load steam_api64_real.dll\"");
        }
    } else if (reason == DLL_PROCESS_DETACH) {
        shim_log("shim_detach", "");
    }
    return TRUE;
}
