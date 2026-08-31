"""Probe: does ConPTY inject a line break at the wrap point?

Runs `cmd /c echo <N chars>` inside a pseudoconsole of a known width and
reports where line breaks appear in the resulting VT stream.

Meant to be run on a real Windows host (see the conpty-probe workflow),
not locally on Linux.
"""

import sys

from winpty import PtyProcess

COLS = 80
ROWS = 25
FILL = 100  # > COLS, so the line must wrap once


def collect(proc):
    out = []
    while True:
        try:
            chunk = proc.read()
        except EOFError:
            break
        if not chunk:
            if not proc.isalive():
                break
            continue
        out.append(chunk)
    return "".join(out)


def hexdump(s, limit=512):
    data = s.encode("utf-8", errors="replace")[:limit]
    for off in range(0, len(data), 16):
        row = data[off:off + 16]
        hexpart = " ".join(f"{b:02x}" for b in row)
        txt = "".join(chr(b) if 32 <= b < 127 else "." for b in row)
        print(f"  {off:04x}  {hexpart:<47}  {txt}")


def main():
    import winpty

    print(f"pywinpty {getattr(winpty, '__version__', '?')}")
    print(f"python   {sys.version.split()[0]}")
    print(f"pty      {COLS}x{ROWS}, echoing {FILL} 'A'")
    print()

    proc = PtyProcess.spawn(
        f"cmd /c echo {'A' * FILL}",
        dimensions=(ROWS, COLS),
    )
    stream = collect(proc)

    print("--- raw stream ---")
    hexdump(stream)
    print()

    runs = [len(r) for r in stream.split("\r\n") if "A" in r]
    print("--- analysis ---")
    print(f"runs of text between CRLFs: {runs}")

    if any(n >= FILL for n in runs):
        print(f"VERDICT: long line passed through whole ({FILL} chars, no break)")
    elif COLS in runs:
        print(f"VERDICT: break injected at column {COLS}")
    else:
        print("VERDICT: unrecognised — see the dump above")

