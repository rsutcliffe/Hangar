#!/bin/bash
# Restarts each running Colima profile, one at a time, so its VM hands the memory it has accumulated back to macOS.
# (The Mac's virtualisation layer only partly supports ballooning: memory the VM frees is not returned until the VM restarts.)
#
# A profile with a job running is left alone: the script waits for the job to finish (WAIT_MINUTES, default 60) and skips
# that profile for the night if it is still busy. A runner can pick up a job in the moment between the check and the stop;
# the window is a second or two, and GitHub requeues a job whose runner disappears.
#
# Usage: colima-nightly-restart.sh [profile ...]     (no profiles: every running profile)
#        DRY_RUN=1 colima-nightly-restart.sh         (says what it would do; stops and starts nothing)
set -u
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"       # launchd starts with almost no PATH
WAIT_MINUTES=${WAIT_MINUTES:-60}
DRY_RUN=${DRY_RUN:-0}

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

profiles=("$@")
if [ ${#profiles[@]} -eq 0 ]; then
  while read -r p; do profiles+=("$p"); done < <(colima list 2>/dev/null | awk 'NR > 1 && $2 == "Running" { print $1 }')
fi
[ ${#profiles[@]} -gt 0 ] || { log "no running profiles"; exit 0; }

# Prints BUSY or IDLE. A failed colima ssh prints neither: "could not ask" is not the same as "idle", and every failure
# (a hung VM, a dropped connection) exits 1 just as pgrep's "no match" does, so the VM has to say the word itself.
# "[R]unner" keeps pgrep from matching the shell that colima ssh starts to run it.
state() { colima ssh -p "$1" -- sh -c 'pgrep -f "[R]unner.Worker" >/dev/null && echo BUSY || echo IDLE' 2>/dev/null | tail -n 1; }

failed=0
for p in "${profiles[@]}"; do
  # colima stop on a profile that does not exist succeeds ("not running"), and colima start would then create a new, empty VM.
  if ! colima list 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -qx "$p"; then log "$p: no such profile, skipped"; failed=1; continue; fi
  waited=0
  while s=$(state "$p"); [ "$s" = BUSY ] && [ "$waited" -lt "$WAIT_MINUTES" ] && [ "$DRY_RUN" != 1 ]; do
    [ "$waited" -eq 0 ] && log "$p: a job is running, waiting up to $WAIT_MINUTES minutes"
    sleep 60; waited=$((waited + 1))
  done
  case "$s" in
    IDLE) ;;
    BUSY) log "$p: a job is running, $([ "$DRY_RUN" = 1 ] && echo "would wait up to $WAIT_MINUTES minutes" || echo "skipped tonight")"; continue ;;
    *) log "$p: could not check for a running job, skipped"; failed=1; continue ;;
  esac
  if [ "$DRY_RUN" = 1 ]; then log "$p: would restart"; continue; fi
  log "$p: restarting"
  if colima stop -p "$p" && colima start -p "$p"; then log "$p: back up"
  else log "$p: FAILED to restart"; failed=1; fi
done
exit $failed
