// windows side helper that runs inside the bottle and injects 3dmigoto the way xxmi launcher does:
// a global hook from 3dmloader.dll loads d3d11.dll into the target process when it starts.
// the game must not be a child of this process (the anti-cheat rejects that), so the launcher starts
// the game separately in the same wineserver while this keeps the hook alive.
// usage: asahiro-inject.exe <3dmloader.dll> <d3d11.dll> <process.exe> <timeout seconds>
// status lines go to stdout: hooked, injected, inject_timeout, error <what>
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

typedef int(__cdecl *hook_fn)(LPCWSTR, HHOOK *, HANDLE *);
typedef int(__cdecl *wait_fn)(LPCWSTR, LPCWSTR, int);
typedef int(__cdecl *unhook_fn)(HHOOK *, HANDLE *);

static void say(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vprintf(fmt, args);
    va_end(args);
    printf("\n");
    fflush(stdout);
}

int wmain(int argc, wchar_t **argv) {
    if (argc < 5) {
        say("error usage");
        return 2;
    }
    const wchar_t *loader_path = argv[1];
    const wchar_t *dll_path = argv[2];
    const wchar_t *process = argv[3];
    int timeout = _wtoi(argv[4]);

    HMODULE loader = LoadLibraryW(loader_path);
    if (!loader) {
        say("error load_loader %lu", GetLastError());
        return 3;
    }
    hook_fn hook_library = (hook_fn)GetProcAddress(loader, "HookLibrary");
    wait_fn wait_for_injection = (wait_fn)GetProcAddress(loader, "WaitForInjection");
    unhook_fn unhook_library = (unhook_fn)GetProcAddress(loader, "UnhookLibrary");
    if (!hook_library || !wait_for_injection || !unhook_library) {
        say("error loader_exports");
        return 3;
    }

    HHOOK hook = NULL;
    HANDLE mutex = NULL;
    int rc = hook_library(dll_path, &hook, &mutex);
    if (rc != 0) {
        say("error hook %d", rc);
        return 4;
    }
    say("hooked");

    // the hook only fires while this process is alive, so keep it until the dll shows up in the game
    int ok = wait_for_injection(dll_path, process, timeout) == 0;
    say(ok ? "injected" : "inject_timeout");
    unhook_library(&hook, &mutex);
    return ok ? 0 : 1;
}
