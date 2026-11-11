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
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
WAIT_MINUTES=${WAIT_MINUTES:-60}
DRY_RUN=${DRY_RUN:-0}

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

profiles=("$@")
if [ ${#profiles[@]} -eq 0 ]; then
  while read -r p; do profiles+=("$p"); done < <(colima list 2>/dev/null | awk 'NR > 1 && $2 == "Running" { print $1 }')
fi
[ ${#profiles[@]} -gt 0 ] || { log "no running profiles"; exit 0; }

# "[R]unner" keeps pgrep from matching the shell that colima ssh starts to run it.
busy() { colima ssh -p "$1" -- pgrep -f '[R]unner.Worker' > /dev/null 2>&1; }

failed=0
for p in "${profiles[@]}"; do
  # colima stop on a profile that does not exist succeeds ("not running"), and colima start would then create a new, empty VM.
  if ! colima list 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -qx "$p"; then log "$p: no such profile, skipped"; failed=1; continue; fi
  waited=0
  while busy "$p" && [ "$waited" -lt "$WAIT_MINUTES" ]; do
    [ "$waited" -eq 0 ] && log "$p: a job is running, waiting up to $WAIT_MINUTES minutes"
    [ "$DRY_RUN" = 1 ] && break
    sleep 60; waited=$((waited + 1))
  done
  if busy "$p"; then log "$p: still busy, skipped tonight"; continue; fi
  if [ "$DRY_RUN" = 1 ]; then log "$p: would restart"; continue; fi
  log "$p: restarting"
  if colima stop -p "$p" && colima start -p "$p"; then log "$p: back up"
  else log "$p: FAILED to restart"; failed=1; fi
done
exit $failed
