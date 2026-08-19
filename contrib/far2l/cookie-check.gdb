# far2l-sdl exit segfault: compare the TLS pointer-guard cookie (%fs:0x30)
# at __cxa_atexit registration time (whichever thread registers it) against
# its value at the actual crash point (main thread, inside
# __run_exit_handlers). If these differ, that's the confirmed root cause.
#
# Usage: gdb -q -x cookie-check.gdb --args ./far2l
# Then use far2l normally and quit it the way that normally crashes.
# Paste back everything this prints, from first "[__cxa_atexit]" line to
# the final "[STOPPED]"/"[frame1]" lines. No rebuild needed -- read-only
# breakpoints and register/memory prints against the already-built binary.

set pagination off
set print thread-events off

break __cxa_atexit
commands
  silent
  printf "[__cxa_atexit] thread=%d cookie=%#lx caller=%p\n", \
      $_thread, *(long*)($fs_base+0x30), *(void**)$rsp
  continue
end

run

# Execution reaches here only by actually stopping -- either the real
# SIGSEGV (gdb's default behaviour is to stop on it, not continue), or
# (unexpectedly, given the reports so far) the program exiting cleanly.
printf "[STOPPED] thread=%d cookie=%#lx pc=%p\n", \
    $_thread, *(long*)($fs_base+0x30), $pc

# If this stopped on SIGSEGV inside __run_exit_handlers (frame 1), also
# dump frame 1's raw, still-mangled stored pointer for comparison against
# the demangled garbage in frame 0 -- rcx at frame 1 (after the earlier
# `mov 0x18(%rax),%rcx`) is that raw value before mangling/demangling.
frame 1
printf "[frame1] raw-stored-rcx=%#lx mangled-rax-before-call=%#lx\n", \
    $rcx, $rax
info registers rip rax rcx r8 r15
quit
