#!/usr/bin/env bash
# SessionStart — ensure a `tokenol serve --persist` writer is running.
#
# WHY THIS EXISTS. The dashboard is started by hand in a screen session and
# nothing supervises it. With --persist that is not merely a missing dashboard:
# the WRITER dies too, and history stops being recorded while everything still
# looks normal. That exact silent-stop is what produced the 2026-05-04 ->
# 08-27 gap, which is unrecoverable — the JSONL was pruned before it was ever
# persisted. So the cost of a missed restart is permanent data loss, and the
# cost of this hook is ~2 ms.
#
# WHY IT IS FAST. Liveness is a pidfile read plus `kill -0`, a bash builtin:
# measured 1.8 ms per call, against 49 ms for `pgrep -f` (27x). The hook is
# also declared "async" in settings.json, so it never blocks session start at
# all. The pidfile is written ONLY by a --persist server (app.py calls
# write_pidfile only when config.persist), so its liveness answers exactly the
# question asked: "is a WRITER running?", not "is any tokenol running?".
#
# WHY NOT pgrep. A pattern like 'tokenol serve --persist' matches the hook's
# own command line and any shell that mentions it. That bit us on 2026-09-07:
# a wait loop matched itself and reported the server alive after it had exited.
#
# HOW IT STARTS. `systemctl --user start tokenol.service` — the unit at
# ~/.config/systemd/user/tokenol.service is the real supervisor
# (Restart=on-failure, MemoryMax, journald logging), so this hook no longer
# owns the process, it only nudges a stopped unit. `start` on an already active
# unit is a no-op. The screen path below survives only as a fallback for a
# machine where the unit is not installed.
#
# Silent by design: SessionStart stdout is injected into the model's context.

set -u

TOKENOL_DIR="${TOKENOL_HISTORY_DIR:-$HOME/.tokenol}"
PIDFILE="$TOKENOL_DIR/serve.pid"
LOCKFILE="$TOKENOL_DIR/.autostart.lock"
SCREEN_NAME="tokenol"

# --- Is a writer already alive? -------------------------------------------
alive() {
    local pid cmdline
    [[ -r $PIDFILE ]] || return 1
    # Read guarded by the -r test above: bash reports a missing-file redirect
    # on stderr regardless of a trailing 2>/dev/null on the assignment, and
    # SessionStart output reaches the model's context.
    pid=$(<"$PIDFILE")
    [[ -n $pid && $pid == "${pid//[!0-9]/}" ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    # Guard against PID reuse: a recycled pid passes kill -0 and would make us
    # skip a start that is actually needed. Require BOTH tokens — matching
    # "tokenol" alone also matches any shell whose command line merely mentions
    # it, this script included.
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || return 1
    [[ $cmdline == *tokenol* && $cmdline == *serve* ]]
}

alive && exit 0

# --- Not running. Start it, once. -----------------------------------------
command -v tokenol >/dev/null 2>&1 || exit 0
command -v screen  >/dev/null 2>&1 || exit 0

mkdir -p "$TOKENOL_DIR" 2>/dev/null || exit 0

# Non-blocking lock: several sessions can start at the same moment, and two
# writers would race for DuckDB's exclusive lock. The loser exits immediately
# rather than queueing, because this hook must never delay a session.
exec 9>"$LOCKFILE" 2>/dev/null || exit 0
flock -n 9 2>/dev/null || exit 0

# Re-check under the lock: another session may have just started it.
alive && exit 0

# The unit is the supervisor; the hook only nudges it. Falls through to screen
# only where the unit is not installed, so a machine without it still gets a
# server rather than silently none.
if systemctl --user start tokenol.service 2>/dev/null; then
    exit 0
fi

# Don't stack windows in an existing session of the same name.
if screen -ls 2>/dev/null | grep -q "[.]${SCREEN_NAME}[[:space:]]"; then
    screen -S "$SCREEN_NAME" -X stuff $'tokenol serve --persist\n' 2>/dev/null
else
    screen -dmS "$SCREEN_NAME" tokenol serve --persist 2>/dev/null
fi

exit 0
