# Carried SoLo patches

These patches are applied to the exact SoLo checkout recorded in
[`../solo.lock`](../solo.lock) before its archive is built. They are kept
separate from the far2l patches because they change the carried loader, not
far2l's source tree.

The host-executable patch teaches SoLo's global resolver about the dynamic
symbol table of the executable that carries it. This is required for any U
application whose modules resolve an ABI exported by that executable; it is
not a far2l-specific list of `WINPORT_*` symbols.

The workflow checks and applies every patch with `git apply --check` and
`git apply` against the pinned checkout. A changed SoLo revision therefore
fails before the archive is consumed instead of accepting stale context.
