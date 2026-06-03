// dllmain.cpp -- shim bootstrap: load the real SDK, set up logging, expose
// shim_real_module()/shim_resolve()/shim_log() used by the trampolines.
#include "shim.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <mutex>
#include <string>

// The genuine SDK is shipped renamed alongside the shim. The name is DOT-FREE
// (hyphen, not '.orig') so PE forwarders in eos_shim.def resolve correctly --
// the loader would otherwise treat '.orig' as an extension and fail to append
// '.dll', crashing the process at load time.
static const wchar_t* kRealDllName = L"EOSSDK-Win64-Shipping-orig.dll";

static std::atomic<void*> g_real{nullptr};
static std::mutex g_log_mtx;
static FILE* g_log = nullptr;

// ---- real DLL ----------------------------------------------------------------
static void load_real() {
    if (g_real.load()) return;
    // Prefer an already-loaded handle: the .def forwarders force the loader to
    // map the real SDK at import time, so by the time any trampoline runs it is
    // already present. Fall back to LoadLibrary if not.
    HMODULE h = GetModuleHandleW(kRealDllName);
    if (!h) h = LoadLibraryW(kRealDllName);
    g_real.store(reinterpret_cast<void*>(h));
    if (!h) {
        shim_log("shim_error",
                 "\"msg\":\"failed to load real EOS SDK\",\"gle\":" +
                     std::to_string(GetLastError()));
    } else {
        shim_log("shim_loaded_real", "\"dll\":\"EOSSDK-Win64-Shipping-orig.dll\"");
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
    if (!p) {
        shim_log("shim_resolve_miss", "\"fn\":" + shim_jstr(name));
    }
    return p;
}

// ---- logging -----------------------------------------------------------------
static void open_log() {
    std::lock_guard<std::mutex> lk(g_log_mtx);
    if (g_log) return;
    // Path precedence: EOS_SHIM_LOG env, else CWD\eos_shim.jsonl.
    char path[1024] = {0};
    DWORD n = GetEnvironmentVariableA("EOS_SHIM_LOG", path, sizeof(path) - 1);
    const char* p = (n > 0 && n < sizeof(path)) ? path : "eos_shim.jsonl";
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
        DWORD n = GetEnvironmentVariableA("EOS_SHIM_LOG", path, sizeof(path) - 1);
        const char* p = (n > 0 && n < sizeof(path)) ? path : "eos_shim.jsonl";
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

// ---- string helpers ----------------------------------------------------------
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

std::string shim_puid(EOS_ProductUserId id) {
    if (!id) return "null";
    auto fn = REAL(EOS_ProductUserId_ToString);
    if (!fn) return "\"<no-tostring>\"";
    char buf[EOS_PRODUCTUSERID_MAX_LENGTH + 1] = {0};
    int32_t len = sizeof(buf);
    if (fn(id, buf, &len) != EOS_EResult::EOS_Success) return "\"<bad-puid>\"";
    return shim_jstr(buf);
}

std::string shim_result(EOS_EResult r) {
    auto fn = REAL(EOS_EResult_ToString);
    if (!fn) return std::to_string(static_cast<int>(r));
    return shim_jstr(fn(r));
}

// ---- entry point -------------------------------------------------------------
BOOL APIENTRY DllMain(HMODULE, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        open_log();
        shim_log("shim_attach", "\"pid\":" + std::to_string(GetCurrentProcessId()));
        // Do NOT LoadLibrary here -- doing real work under the loader lock is
        // risky. The real SDK is lazily resolved on first trampoline call via
        // shim_resolve()/load_real(); the forwarders already mapped it anyway.
    } else if (reason == DLL_PROCESS_DETACH) {
        shim_log("shim_detach", "");
    }
    return TRUE;
}
