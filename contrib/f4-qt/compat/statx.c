/*
 * statx() compatibility shim for a glibc-2.27 baseline built with zig cc.
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
 * Scope: this is a 2.27-baseline workaround for one known upstream
 * pattern, not a general "polyfill anything newer" library. The full
 * glibc 2.27 -> 2.28 symbol delta is seven names (fcntl64, renameat2,
 * statx, thrd_current, thrd_equal, thrd_sleep, thrd_yield); of those,
 * only statx is live for this build. If that ever changes, add the
 * specific symbol here with the same standard of evidence -- do not
 * turn this into a speculative compatibility layer.
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
