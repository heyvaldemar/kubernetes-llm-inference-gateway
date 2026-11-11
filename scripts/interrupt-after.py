#!/usr/bin/env python3
"""Run a command; past a time limit, interrupt it, and kill it if it does not stop.

    scripts/interrupt-after.py LIMIT GRACE -- COMMAND [ARG...]

LIMIT and GRACE are seconds, or a number with s, m or h after it. The command
runs in a process group of its own. Past LIMIT that group gets SIGINT, as
Ctrl-C would send it; if the command has not ended GRACE later, the group
gets SIGKILL. The exit status is the command's when it ends before LIMIT,
124 when it was interrupted and ended within GRACE, and 137 when it had to
be killed, as GNU timeout's are. A SIGINT or SIGTERM sent to this script goes
to the command's group and starts the same GRACE.

The GPU run's apply (gpu.yml) runs under it, so Terraform, interrupted before
its step's timeout, has GRACE to write what it made to the state and release
the state's lock. `timeout -s INT -k 3m 30m` did that until ubuntu-latest
became ubuntu-26.04, whose timeout is uutils': it sends SIGKILL a fraction of
a second after the SIGINT, whatever -k says (uutils/coreutils#15843 and
#15768). tests/interrupt-after.sh holds this script to the above.
"""
import os
import signal
import subprocess
import sys
import time

UNITS = {"s": 1, "m": 60, "h": 3600}


def seconds(text):
    number, unit = (text[:-1], UNITS[text[-1]]) if text[-1:] in UNITS else (text, 1)
    value = float(number) * unit
    if not value > 0:
        raise ValueError(text)
    return value


def main():
    args = sys.argv[1:]
    if len(args) < 4 or args[2] != "--":
        sys.exit(__doc__)
    try:
        limit, grace = seconds(args[0]), seconds(args[1])
    except ValueError:
        sys.exit("interrupt-after: LIMIT and GRACE are seconds above zero, or a number with s, m or h after it")
    cmd = args[3:]
    name = os.path.basename(cmd[0])
    child = None
    kill_at = None
    timed_out = killed = False

    def send(signum):
        try:
            os.killpg(child.pid, signum)
        except ProcessLookupError:
            pass

    def forward(signum, _frame):
        nonlocal kill_at
        if child is None:
            sys.exit(128 + signum)
        send(signum)
        if kill_at is None:
            kill_at = time.monotonic() + grace

    # Handled before the command starts, so it starts with SIGINT at its
    # default even when this script was started with SIGINT ignored, as a
    # shell does to a command it runs in the background.
    signal.signal(signal.SIGINT, forward)
    signal.signal(signal.SIGTERM, forward)
    child = subprocess.Popen(cmd, process_group=0)
    deadline = time.monotonic() + limit

    while True:
        try:
            status = child.wait(timeout=0.2)
            break
        except subprocess.TimeoutExpired:
            pass
        now = time.monotonic()
        if not timed_out and kill_at is None and now >= deadline:
            timed_out = True
            kill_at = now + grace
            print("interrupt-after: %s ran past %s: SIGINT, and SIGKILL in %s if it has not ended" % (name, args[0], args[1]), file=sys.stderr, flush=True)
            send(signal.SIGINT)
        elif not killed and kill_at is not None and now >= kill_at:
            killed = True
            print("interrupt-after: %s had not ended %s after SIGINT: SIGKILL" % (name, args[1]), file=sys.stderr, flush=True)
            send(signal.SIGKILL)

    if killed:
        return 137
    if timed_out:
        return 124
    return status if status >= 0 else 128 - status


if __name__ == "__main__":
    sys.exit(main())
