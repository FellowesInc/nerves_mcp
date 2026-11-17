"""A serial console held by `nbtty --wait-input`, for NervesMCP.Connection.UARTTest.

Opens a pty, prints the path of its device end, then plays the device on the other
end. Until a read carries a carriage return, input and output are dropped the way
nbtty drops them, and that read is dropped too. After it, each END marker is answered
with a firmware UUID the way IEx prints one. Nothing is echoed. Exits when stdin
closes.
"""

import os
import pty
import re
import select
import sys
import tty

END = re.compile(rb"([0-9A-F]{16})_END")
EOS = b"\x1b[999H"

master, device = pty.openpty()
tty.setraw(device)
print(os.ttyname(device), flush=True)

active = False
pending = b""

while True:
    readable, _, _ = select.select([master, sys.stdin], [], [])

    if sys.stdin in readable and not os.read(sys.stdin.fileno(), 1024):
        break

    if master not in readable:
        continue

    data = os.read(master, 4096)

    if not active:
        if b"\r" in data:
            active = True
            os.write(master, EOS + b"\r\n")
        continue

    pending += data
    matches = list(END.finditer(pending))
    for match in matches:
        marker = match.group(1)
        os.write(master, b'\r\n%s_START\r\n"0123abcd"\r\n%s_END\r\n' % (marker, marker))
    if matches:
        pending = pending[matches[-1].end() :]
