# Carried far2l patches

The default is still an unmodified pinned far2l checkout. This directory is
non-empty only when a small, upstreamable fix is required for a supported
Static Everywhere profile and the pinned source cannot run without it.

`tools/build-far2l.sh` checks and applies patches in lexical order, without a
three-way merge or fuzz. A changed pinned source therefore fails before its
build starts instead of silently producing a different recipe.

The current patches make both optional path-translation hooks safe when
`dlsym(RTLD_DEFAULT, ...)` cannot see the main executable in a static carried
loader, and explicitly publish the SDL window after backend initialization so
X11 startup does not depend on deferred mapping. They are generated from the
exact far2l commit in `deps.lock` and are also suitable for proposing
upstream; the full failure analysis remains in [`../UPSTREAM.md`](../UPSTREAM.md).
