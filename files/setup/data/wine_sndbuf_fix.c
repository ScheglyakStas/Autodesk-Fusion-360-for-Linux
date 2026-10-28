/*
 * LD_PRELOAD shim for wineserver: fixes slow Autodesk Fusion uploads under Wine.
 *
 * Wine's ws2_32 answers SIO_IDEAL_SEND_BACKLOG_QUERY with a fixed 64 KB, and
 * Windows libcurl (used by Fusion's uploader) feeds that value into SO_SNDBUF.
 * On Linux an explicit SO_SNDBUF locks the send buffer at that size. Wine also
 * wakes a blocked writer only about once per second, so each connection ends up
 * sending one 64 KB buffer per second (~90 KB/s).
 *
 * This shim raises SO_SNDBUF requests on TCP/IP sockets to SNDBUF_SIZE (the
 * kernel caps it at net.core.wmem_max), so a full second of data fits in the
 * buffer and the per-second wakeup no longer limits throughput.
 *
 * Wine starts wineserver from its own bin directory (WINESERVER is not
 * honoured), so the shim is preloaded into the whole Wine process tree and
 * only acts inside wineserver, which is where Windows SO_SNDBUF is applied.
 *
 * It also makes Wine's NtYieldExecution (SwitchToThread) cheaper: Wine wraps every
 * sched_yield() in two getrusage(RUSAGE_THREAD) calls only to report whether a yield
 * happened. Fusion's TBB worker threads yield thousands of times per second while
 * waiting for work, so those calls cost noticeable kernel time. getrusage() from
 * ntdll.so with RUSAGE_THREAD fails fast here, and Wine then reports a plain success.
 *
 * Finally, it keeps Fusion's right-click "Marking Menu" visible. The Fusion Wine build
 * forces the Qt window classes in WINE_X11_MANAGED_CLASSES to be managed by the window
 * manager, and treats layered tool windows of those classes as "overlays" that cannot
 * take focus and swallow mouse presses. The marking menu is such a window, so GNOME
 * stacks it below Fusion's main window and it never shows. When winex11.so asks for the
 * class name of a window titled "Marking Menu", this shim alters the name so it no longer
 * matches the list, and Wine shows the menu as a normal unmanaged popup, as on stock Wine.
 *
 * Build: gcc -O2 -Wall -shared -fPIC -o wine_sndbuf_fix.so wine_sndbuf_fix.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <link.h>
#include <errno.h>
#include <string.h>
#include <netinet/in.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <X11/Xlib.h>

#ifndef SNDBUF_SIZE
#define SNDBUF_SIZE (4 * 1024 * 1024)
#endif

int setsockopt(int fd, int level, int optname, const void *optval, socklen_t optlen)
{
    static int (*real_setsockopt)(int, int, int, const void *, socklen_t);

    if (!real_setsockopt)
        real_setsockopt = dlsym(RTLD_NEXT, "setsockopt");

    if (level == SOL_SOCKET && optname == SO_SNDBUF &&
        !strcmp(program_invocation_short_name, "wineserver") &&
        optlen >= sizeof(int) && *(const int *)optval < SNDBUF_SIZE)
    {
        int domain = 0, type = 0;
        socklen_t len = sizeof(int);

        if (!getsockopt(fd, SOL_SOCKET, SO_DOMAIN, &domain, &len) &&
            (len = sizeof(int), !getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &len)) &&
            (domain == AF_INET || domain == AF_INET6) && type == SOCK_STREAM)
        {
            int size = SNDBUF_SIZE;
            return real_setsockopt(fd, level, optname, &size, sizeof(size));
        }
    }
    return real_setsockopt(fd, level, optname, optval, optlen);
}

/* Is caller inside the shared library with the given file name? *base caches its load address. */
static int called_from(const void *caller, const char *lib, const void **base)
{
    Dl_info info;
    const char *name;

    if (*base) return dladdr(caller, &info) && info.dli_fbase == *base;
    if (!dladdr(caller, &info) || !info.dli_fname) return 0;
    name = strrchr(info.dli_fname, '/') ? strrchr(info.dli_fname, '/') + 1 : info.dli_fname;
    if (strcmp(name, lib)) return 0;
    *base = info.dli_fbase;
    return 1;
}

static int called_from_ntdll(const void *caller)
{
    static const void *ntdll_base;
    return called_from(caller, "ntdll.so", &ntdll_base);
}

int getrusage(__rusage_who_t who, struct rusage *usage)
{
    static int (*real_getrusage)(__rusage_who_t, struct rusage *);

    if (who == RUSAGE_THREAD && called_from_ntdll(__builtin_return_address(0)))
    {
        errno = ENOSYS;
        return -1;
    }
    if (!real_getrusage)
        real_getrusage = dlsym(RTLD_NEXT, "getrusage");
    return real_getrusage(who, usage);
}

#ifndef NO_MARKING_MENU_FIX
/* win32u.so's Unix-side exports use the normal System V calling convention (not ms_abi). */
typedef uint16_t WCHAR16;
typedef struct { uint16_t Length; uint16_t MaximumLength; WCHAR16 *Buffer; } UNICODE_STRING16;
typedef int (*get_class_name_fn)(void *hwnd, int real, UNICODE_STRING16 *name);
typedef int (*get_window_text_fn)(void *hwnd, WCHAR16 *text, int count);

#ifndef EXEMPT_TITLE
#define EXEMPT_TITLE "Marking Menu"
#endif

/* Wine loads win32u.so, winex11.so and libX11 with dlopen() into a local scope, so
 * dlsym(RTLD_NEXT) cannot see them; look the real functions up in the loaded library. */
struct lib_lookup { const char *name; void *handle; };

static int find_lib(struct dl_phdr_info *info, size_t size, void *data)
{
    struct lib_lookup *lookup = data;
    const char *slash = strrchr(info->dlpi_name, '/');

    if (slash && !strcmp(slash + 1, lookup->name))
    {
        lookup->handle = dlopen(info->dlpi_name, RTLD_NOW | RTLD_NOLOAD);
        return 1;
    }
    return 0;
}

static void *lib_sym(const char *lib, void **handle, const char *name)
{
    if (!*handle)
    {
        struct lib_lookup lookup = { lib, NULL };
        dl_iterate_phdr(find_lib, &lookup);
        *handle = lookup.handle;
    }
    return *handle ? dlsym(*handle, name) : dlsym(RTLD_NEXT, name);
}

static void *win32u_handle, *x11_handle;

static void shim_trace(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void shim_trace(const char *fmt, ...)
{
    static FILE *out;
    static int init;
    va_list args;

    if (!init)
    {
        const char *path = getenv("FUSION_SHIM_TRACE");
        init = 1;
        if (path && *path) out = fopen(path, "a");
        if (out) setvbuf(out, NULL, _IOLBF, 0);
    }
    if (!out) return;
    va_start(args, fmt);
    vfprintf(out, fmt, args);
    va_end(args);
}

static int window_title_is(void *hwnd, const char *title)
{
    static get_window_text_fn get_text;
    WCHAR16 buf[64];
    int i, len;

    if (!get_text && !(get_text = (get_window_text_fn)lib_sym("win32u.so", &win32u_handle, "NtUserInternalGetWindowText")))
        return 0;
    len = get_text(hwnd, buf, sizeof(buf) / sizeof(buf[0]));
    if (len != (int)strlen(title)) return 0;
    for (i = 0; i < len; i++) if (buf[i] != (unsigned char)title[i]) return 0;
    return 1;
}

/* Keeps the menu out of the Fusion build's "forced managed overlay" handling, which swallows
 * mouse presses on it. Only winex11.so sees the altered class name; Fusion and Qt never do. */
int NtUserGetClassName(void *hwnd, int real, UNICODE_STRING16 *name)
{
    static get_class_name_fn real_get_class_name;
    static const void *winex11_base;
    void *caller = __builtin_return_address(0);
    int ret;

    if (!real_get_class_name &&
        !(real_get_class_name = (get_class_name_fn)lib_sym("win32u.so", &win32u_handle, "NtUserGetClassName")))
        return 0;
    ret = real_get_class_name(hwnd, real, name);
    if (ret <= 0 || !name || !name->Buffer || !called_from(caller, "winex11.so", &winex11_base)) return ret;

    if (window_title_is(hwnd, EXEMPT_TITLE))
    {
        name->Buffer[0] = '~';
        shim_trace("class name of %p exempted (title \"%s\")\n", hwnd, EXEMPT_TITLE);
    }
    return ret;
}

/* Wine decides whether a window is managed when it is created, before Fusion sets the menu's
 * title, so the menu still ends up managed and GNOME stacks it below the main window. Turn it
 * into an override-redirect window right before winex11.so maps it, so it shows on top. */
int XMapWindow(Display *display, Window window)
{
    static int (*real_map)(Display *, Window);
    static Status (*fetch_name)(Display *, Window, char **);
    static int (*change_attributes)(Display *, Window, unsigned long, XSetWindowAttributes *);
    static int (*x_free)(void *);
    static const void *winex11_base;
    void *caller = __builtin_return_address(0);
    char *title = NULL;

    if (!real_map)
    {
        fetch_name = lib_sym("libX11.so.6", &x11_handle, "XFetchName");
        change_attributes = lib_sym("libX11.so.6", &x11_handle, "XChangeWindowAttributes");
        x_free = lib_sym("libX11.so.6", &x11_handle, "XFree");
        real_map = lib_sym("libX11.so.6", &x11_handle, "XMapWindow");
    }
    if (!real_map) return 0;

    if (fetch_name && change_attributes && x_free && called_from(caller, "winex11.so", &winex11_base) &&
        fetch_name(display, window, &title) && title)
    {
        int match = !strcmp(title, EXEMPT_TITLE);
        shim_trace("map 0x%lx \"%s\"%s\n", (unsigned long)window, title, match ? " -> override-redirect" : "");
        if (match)
        {
            XSetWindowAttributes attr = { .override_redirect = True };
            change_attributes(display, window, CWOverrideRedirect, &attr);
        }
        x_free(title);
    }
    return real_map(display, window);
}
#endif
