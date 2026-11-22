#!/usr/bin/env bash
# SessionEnd — stop the tokenol server once the LAST Claude session has ended.
#
# WHY THIS EXISTS. tokenol only has work to do while Claude Code is writing
# transcripts. Left running it holds ~1.2 GB resident indefinitely. Its
# companion hook (tokenol_autostart.sh) brings it back on the next
# SessionStart, and a restart now costs ~17 s, so stopping is cheap.
#
# WHY IT IS SAFE. Nothing is lost. While no Claude session runs, no transcript
# is being written, so there is nothing to miss; and on the next start the
# server re-reads whatever changed. This is NOT the 2026-05-04 -> 08-27 gap,
# which happened because the writer was dead for MONTHS *while Claude Code was
# in daily use*. That cannot happen here: every session start restarts it.
#
# REMOTE SESSIONS (decision D9). Most sessions run on the DGX, mirrored here
# every 5 min by a remote-sync script, where no hook of ours fires. That
# script starts the server when new transcripts arrive and calls THIS hook on
# quiet ticks, so the server stops only when no local session is alive AND no
# mirrored transcript has changed for TOKENOL_REMOTE_IDLE_MINUTES (default 30).
#
# HOW A LIVE SESSION IS COUNTED. A process whose /proc/<pid>/exe resolves into
# the Claude install directory. NOT pgrep on a command-line pattern: that
# matches this script, any shell that mentions "claude", and the editor you
# have the file open in. Verified 2026-09-07 — exe symlinks gave exactly one
# match for one live session, where a name pattern gave several.
#
# THE SELF-EXCLUSION. At SessionEnd the ending session's own process is still
# alive and is our own ancestor, so it must be discounted or the server would
# never stop. We walk the parent chain to find it.
#
# FAILING SAFE. Every uncertain path leaves the server RUNNING. Leaving it up
# wastes memory; stopping it wrongly costs a 17 s restart and, if it happened
# mid-session, would pause recording. Wasting memory is the cheaper mistake.

set -u

CLAUDE_DIR_MATCH="/claude/versions/"
SETTLE_SECONDS="${TOKENOL_AUTOSTOP_SETTLE:-10}"
LOCKFILE="${TOKENOL_HISTORY_DIR:-$HOME/.tokenol}/.autostop.lock"
ACTIVITY_FILE="${TOKENOL_HISTORY_DIR:-$HOME/.tokenol}/.remote-activity"
REMOTE_IDLE_MINUTES="${TOKENOL_REMOTE_IDLE_MINUTES:-30}"

# --- Which claude process is OURS? ----------------------------------------
own_claude_pid() {
    local pid=$PPID exe
    for _ in 1 2 3 4 5 6 7 8; do
        [ -z "$pid" ] && return 1
        [ "$pid" = "0" ] || [ "$pid" = "1" ] && return 1
        exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
        case "$exe" in *"$CLAUDE_DIR_MATCH"*) echo "$pid"; return 0 ;; esac
        # PPid from /proc/<pid>/status, read by the shell. Not `awk` on
        # /proc/<pid>/stat: that forks a process per generation, and stat's
        # comm field can itself contain spaces and parentheses, which shifts
        # the positional field a naive parse would read.
        pid=$(while read -r k v _; do [ "$k" = "PPid:" ] && { echo "$v"; break; }; done < "/proc/$pid/status" 2>/dev/null)
        [ -n "$pid" ] || return 1
    done
    return 1
}

# --- How many OTHER Claude sessions are alive? ----------------------------
# $1 = pid to discount (may be empty, or already dead — both are fine).
count_other_sessions() {
    local self="${1:-}" pid n=0
    # One `find` matching on the SYMLINK TARGET, not a shell loop calling
    # readlink per process: this box runs ~700 processes, and the loop forked
    # once each for 1.2 s against 0.07 s here (measured 2026-09-07, same
    # answer both ways). A SessionEnd hook has no business costing a second.
    while read -r pid; do
        [ "$pid" = "$self" ] && continue
        n=$((n + 1))
    done < <(find /proc -maxdepth 2 -name exe -lname "*${CLAUDE_DIR_MATCH}*" -printf '%h\n' 2>/dev/null | sed 's|^/proc/||')
    echo "$n"
}

# --- Is a REMOTE machine still producing transcripts? ---------------------
# a remote-sync script touches this file whenever its mirror receives a
# changed transcript. Most sessions run on the DGX, where no hook of ours
# fires, so this is the only signal that Claude is in use there. A missing
# file reads as "no remote activity".
remote_active() {
    [ -n "$(find "$ACTIVITY_FILE" -mmin "-$REMOTE_IDLE_MINUTES" 2>/dev/null)" ]
}

SELF=$(own_claude_pid) || SELF=""
OTHERS=$(count_other_sessions "$SELF")

if [ -n "${TOKENOL_AUTOSTOP_DRYRUN:-}" ]; then
    remote_active && REMOTE=yes || REMOTE=no
    echo "self=${SELF:-none} other_live_sessions=$OTHERS remote_active_within_${REMOTE_IDLE_MINUTES}min=$REMOTE"
    [ "$OTHERS" -eq 0 ] && [ "$REMOTE" = no ] && echo "would stop tokenol" || echo "would leave tokenol running"
    exit 0
fi

# Another session is still working, here or remotely — leave the server alone.
[ "$OTHERS" -eq 0 ] || exit 0
remote_active && exit 0

command -v systemctl >/dev/null 2>&1 || exit 0

# One stopper at a time; a loser exits rather than queueing.
mkdir -p "$(dirname "$LOCKFILE")" 2>/dev/null || exit 0
exec 9>"$LOCKFILE" 2>/dev/null || exit 0
flock -n 9 2>/dev/null || exit 0

# Let the server's tick pick up the final turns of the session that just
# ended before we take it down. Not required for correctness — anything
# missed is re-read on the next start — but it keeps the common case tidy.
sleep "$SETTLE_SECONDS"

# Re-check: the user may have started a new session during the settle. Our own
# process is normally gone by now; passing it again is harmless either way.
[ "$(count_other_sessions "$SELF")" -eq 0 ] || exit 0

systemctl --user stop tokenol.service 2>/dev/null
exit 0
