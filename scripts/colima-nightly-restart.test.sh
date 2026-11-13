#!/bin/bash
# Checks colima-nightly-restart.sh against a stand-in colima: a profile is restarted only when its VM answers IDLE.
# Run: scripts/colima-nightly-restart.test.sh   (prints "ok" and exits 0, or says what went wrong)
set -u
here=$(cd "$(dirname "$0")" && pwd)
bin=$(mktemp -d); trap 'rm -rf "$bin"' EXIT
cat > "$bin/colima" <<'EOF'
#!/bin/bash
# $FAKE_SSH is what `colima ssh` prints (empty = it failed); stop and start are recorded in $FAKE_LOG.
case "$1" in
  list) printf 'PROFILE STATUS\nvm Running\n' ;;
  ssh) [ -n "$FAKE_SSH" ] && echo "$FAKE_SSH" || exit 1 ;;
  *) echo "$*" >> "$FAKE_LOG" ;;
esac
EOF
chmod +x "$bin/colima"
export FAKE_LOG="$bin/log"
run() { : > "$FAKE_LOG"; FAKE_SSH="$1" WAIT_MINUTES=0 PATH="$bin:$PATH" "$here/colima-nightly-restart.sh" vm > /dev/null; echo "exit=$? calls=$(tr '\n' ';' < "$FAKE_LOG")"; }
fail() { echo "FAIL: $1 (got: $2)"; exit 1; }
r=$(run IDLE); [ "$r" = "exit=0 calls=stop -p vm;start -p vm;" ] || fail "IDLE should restart" "$r"
r=$(run BUSY); [ "$r" = "exit=0 calls=" ] || fail "BUSY should skip quietly" "$r"
r=$(run "");   [ "$r" = "exit=1 calls=" ] || fail "an unreachable VM must be skipped, not treated as idle" "$r"
echo ok
