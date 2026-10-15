/*
 * openat2_shim.c v2 — LD_PRELOAD shim for Termux:
 * bun's install/build path calls openat2(437) / fchmodat2(452) which Termux
 * seccomp blocks. Termux seccomp ALSO requires the svc instruction to be
 * executed from libc's mapping (instruction-pointer check), so we must NOT
 * emit our own svc — instead translate to the plain openat(257)/fchmodat(268)
 * via the real libc wrappers (their svc runs inside libc -> allowed).
 * Default branch forwards to the real libc syscall() via dlsym(RTLD_NEXT).
 *
 * Build: clang -shared -fPIC -O2 -o openat2_shim.so openat2_shim.c
 * Use:   LD_PRELOAD=/path/openat2_shim.so <android-bun> install
 */
#define _GNU_SOURCE
#include <stdarg.h>
#include <stdint.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <errno.h>

#define SYS_openat2    437
#define SYS_fchmodat2  452

struct my_open_how {
    uint64_t flags;
    uint64_t mode;
    uint64_t resolve;
};

typedef long (*syscall_fn)(long, ...);
static syscall_fn real_syscall_fn;

/* Override libc syscall(). */
long syscall(long number, ...) {
    va_list ap;
    va_start(ap, number);

    if (number == SYS_openat2) {
        int dirfd = va_arg(ap, int);
        const char *path = va_arg(ap, const char *);
        const struct my_open_how *how = va_arg(ap, const struct open_how *);
        va_end(ap);
        /* Translate to libc openat(): its svc executes inside libc -> seccomp-ok.
         * open_how.resolve cannot be honored by plain openat; install paths are
         * project-local so RESOLVE flags are not load-bearing. */
        int fd = openat(dirfd, path, (int)(how ? how->flags : 0), (mode_t)(how ? how->mode : 0));
        return fd < 0 ? (long)-errno : (long)fd;
    }

    if (number == SYS_fchmodat2) {
        int dirfd = va_arg(ap, int);
        const char *path = va_arg(ap, const char *);
        uint64_t mode = va_arg(ap, uint64_t);
        int flags = va_arg(ap, int);
        va_end(ap);
        int r = fchmodat(dirfd, path, (mode_t)mode, flags & AT_SYMLINK_NOFOLLOW);
        return r < 0 ? (long)-errno : (long)r;
    }

    long a1 = va_arg(ap, long);
    long a2 = va_arg(ap, long);
    long a3 = va_arg(ap, long);
    long a4 = va_arg(ap, long);
    long a5 = va_arg(ap, long);
    long a6 = va_arg(ap, long);
    va_end(ap);
    if (!real_syscall_fn) {
        real_syscall_fn = (syscall_fn)dlsym(RTLD_NEXT, "syscall");
    }
    if (real_syscall_fn) {
        return real_syscall_fn(number, a1, a2, a3, a4, a5, a6);
    }
    /* Last resort: raw svc (Termux may trap it, but no crash). */
    register long x8 __asm__("x8") = number;
    register long x0 __asm__("x0") = a1;
    register long x1 __asm__("x1") = a2;
    register long x2 __asm__("x2") = a3;
    register long x3 __asm__("x3") = a4;
    register long x4 __asm__("x4") = a5;
    register long x5 __asm__("x5") = a6;
    __asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory");
    return x0;
}
/* ---- bionic compat: glibc-only pthread_tryjoin_np ----
 * bionic has no non-blocking join. Approximate glibc semantics:
 *   - thread alive (kill==0) -> EBUSY  (caller keeps polling)
 *   - thread gone (ESRCH)    -> join to reap exit status
 * A zombie may briefly read as "busy"; clipboard workers are short-lived,
 * this only delays reaping, never blocks the UI thread.
 */
#include <pthread.h>
int pthread_tryjoin_np(pthread_t t, void **retval) {
    int st = pthread_kill(t, 0);
    if (st == 0) return EBUSY;
    if (st == ESRCH) return pthread_join(t, retval);
    return st;
}
