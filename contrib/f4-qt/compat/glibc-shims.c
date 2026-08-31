/*
 * Compatibility shims for a glibc-2.27 baseline built with zig cc.
 *
 * Why this file exists
 * --------------------
 * `zig cc -target x86_64-linux-gnu.<ver>` versions the *symbol stubs* it
 * links against, but not the *headers* it compiles against: the headers
 * always describe the newest glibc zig ships, whatever <ver> says. That
 * makes the target version a link-time contract only. Any library that
 * decides whether a newer-glibc function exists in the preprocessor --
 * rather than by a test that actually links -- therefore sees a glibc
 * newer than the one it will be linked against, emits the call, and
 * fails at link time.
 *
 * Qt 6 does exactly this for statx(), which entered glibc in 2.28:
 * qtbase/src/corelib/io/qfilesystemengine_unix.cpp guards the call with
 * a bare `#ifdef STATX_BASIC_STATS`, and that macro comes from the
 * kernel UAPI headers, which zig also ships unversioned. On a genuine
 * Ubuntu 18.04 the guard is correct -- glibc 2.27's own <sys/stat.h>
 * never pulls in <linux/stat.h>, so the macro is simply undefined. The
 * failure is specific to building against a synthesised old glibc:
 *
 *   [124/6627] Linking CXX executable qtbase/libexec/moc
 *   ld.lld: error: undefined symbol: statx
 *
 * Note that Qt's guard for renameat2() -- also a 2.28 symbol -- *is* a
 * link test, so it failed correctly and Qt disabled the feature itself.
 * The statx guard should be one too; that is filed upstream.
 *
 * What this provides
 * ------------------
 * The same thin syscall wrapper glibc itself is. Nothing clever, and
 * nothing that changes behaviour on a host whose glibc does have
 * statx(): this definition is only ever reached because the 2.27 stub
 * has no statx to bind to, and the syscall it makes is the same one
 * glibc 2.28+ would make.
 *
 * On a kernel too old to have SYS_statx (pre-4.11) the syscall returns
 * -ENOSYS, which this reports as -1/errno. Qt already copes: its own
 * `#else` branch returns -ENOSYS and every caller falls back to stat().
 * So the shim degrades exactly the way the unshimmed build would.
 *
 * Scope: a 2.27-baseline workaround for a known upstream pattern, added
 * one symbol at a time on evidence. NOT a speculative "polyfill anything
 * newer" layer -- every entry below exists because a real build failed
 * on it, and each carries the file and line that failed.
 *
 * How many more of these are there? Measure, do not guess. An earlier
 * note here claimed the risk was a closed set of seven names; that was
 * the 2.27 -> 2.28 delta only, and it was wrong as an answer to the
 * question being asked. The real 2.27 -> 2.39 delta is 396 symbols
 * (tools/glibc-baseline-delta.py computes it). Most are C23 maths,
 * <stdbit.h> and C11 threads that nothing here touches; the ones that
 * bite are thin syscall wrappers a library reaches for behind a
 * kernel-header #ifdef -- statx, close_range, closefrom, renameat2,
 * execveat, getdents64, gettid, pidfd_*, epoll_pwait2 and similar.
 */

#define _GNU_SOURCE

#include <errno.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

/*
 * Weak on purpose. This object is injected through a *linker flag*, and
 * a flag list is not guaranteed to be used only once: build systems that
 * assemble LDFLAGS from several sources replay the whole list verbatim.
 * openssl does exactly that -- its link line carried `-target ... -pie
 * <this object>` three times over -- and a repeated flag is harmless
 * while a repeated object file is a duplicate symbol definition. Weak
 * definitions collapse instead of colliding, so the shim survives being
 * linked in any number of times. It also means a real statx() from a
 * newer libc would win if one were ever present.
 */
__attribute__((weak))
int statx(int dirfd, const char *pathname, int flags,
          unsigned int mask, struct statx *statxbuf)
{
#ifdef SYS_statx
    return (int)syscall(SYS_statx, dirfd, pathname, flags, mask, statxbuf);
#else
    (void)dirfd;
    (void)pathname;
    (void)flags;
    (void)mask;
    (void)statxbuf;
    errno = ENOSYS;
    return -1;
#endif
}

/*
 * close_range() entered glibc in 2.34.
 *
 * Same shape as statx() exactly: Qt guards the call with `#ifdef
 * CLOSE_RANGE_CLOEXEC` (qtbase/src/corelib/io/qprocess_unix.cpp:860),
 * and CLOSE_RANGE_CLOEXEC is a *kernel* UAPI constant while
 * close_range() is a *glibc* function. Header says yes, 2.27 stub says
 * no:
 *
 *   ld.lld: error: undefined symbol: close_range
 *   >>> referenced by qprocess_unix.cpp:860
 *
 * Two things make the syscall the right implementation here rather than
 * merely an acceptable one. First, the call site runs in a vfork()ed
 * child, where Qt's own comment notes it cannot even use opendir()
 * because that allocates; a raw syscall is async-signal-safe and
 * allocates nothing. Second, Qt already expects this to fail at
 * runtime -- its comment says close_range fails with ENOSYS before
 * kernel 5.9 and EINVAL before 5.11 -- and the fallback immediately
 * below the call marks descriptors FD_CLOEXEC by hand. So on an old
 * kernel the shim returns -1 and Qt takes exactly the path it would
 * have taken with a real glibc 2.34.
 */
__attribute__((weak))
int close_range(unsigned int first, unsigned int last, int flags)
{
#ifdef SYS_close_range
    return (int)syscall(SYS_close_range, first, last, flags);
#else
    (void)first; (void)last; (void)flags;
    errno = ENOSYS;
    return -1;
#endif
}

 
#include <fcntl.h>
#include <stdarg.h>

/*
 * D-Bus is compiled with _FILE_OFFSET_BITS=64.  On glibc this redirects
 * its fcntl() calls to fcntl64(), which is not in the glibc 2.27 symbol
 * set, even though x86_64 has always used the same 64-bit fcntl syscall.
 * The affected D-Bus call sites all pass an int third argument (including
 * an explicit zero for F_GETFD/F_GETFL), so preserve exactly that ABI and
 * invoke the stable kernel interface directly.
 */
__attribute__((weak))
int fcntl64(int fd, int cmd, ...)
{
    va_list args;
    int arg;

    va_start(args, cmd);
    arg = va_arg(args, int);
    va_end(args);

#ifdef SYS_fcntl
    return (int)syscall(SYS_fcntl, fd, cmd, arg);
#else
    (void)fd;
    (void)cmd;
    (void)arg;
    errno = ENOSYS;
    return -1;
#endif
}
