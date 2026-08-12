#!/bin/sh
# verify.sh — start two nodes, break one, and check that the other notices.
#
# Every other dogfood's test asks whether the right answer came back. This one
# asks whether the *absence* of an answer was detected, and within the time it
# was supposed to be detected in — so the subject is a failure, and the test has
# to cause it.
#
# The three ways a leader can stop being useful are not the same event, and the
# first thing this repository learned is that they arrive differently:
#
#   still running       data keeps coming            stay a follower
#   stopped (SIGSTOP)   silence, socket still open   election timeout
#   killed (SIGKILL)    the kernel sends FIN for it  an orderly close
#
# A crashed process is *not* a partition. Only the middle one is what an
# election timeout is for, which is why the timeout case has to be produced with
# SIGSTOP: `kill -9` tests a different code path, and a test that used it would
# pass while measuring nothing.
#
#   sh verify.sh
#
# MERE=/path/to/mere overrides the compiler.

set -e
MERE=${MERE:-mere}
PORT=${PORT:-7099}
ELECTION_MS=1000            # must match election_timeout_ms in mraft.mere
HEARTBEAT_MS=300            # must match heartbeat_ms

pass=0
fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

TMP=$(mktemp -d)
LEADER_PID=
FOLLOWER_PID=
cleanup() {
  [ -n "$LEADER_PID" ] && { kill -CONT "$LEADER_PID" 2>/dev/null; kill -9 "$LEADER_PID" 2>/dev/null; }
  [ -n "$FOLLOWER_PID" ] && kill -9 "$FOLLOWER_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

"$MERE" -c mraft.mere > "$TMP/m.c"
clang -O2 -w "$TMP/m.c" -o "$TMP/mraft"

# Start a follower and a leader talking to it. $1 names the log pair.
# Both nodes are started from a subshell that exits immediately, so this shell
# has no job to announce when they are killed on purpose further down — the
# results should read as results, not be interleaved with "Killed: 9".
spawn_node() {   # spawn_node <role> <port> <logfile> <pidfile>
  ( "$TMP/mraft" "$1" "$2" > "$3" 2>&1 & echo $! > "$4" ) &
  wait $!
  cat "$4"
}

start_pair() {
  PORT=$((PORT + 1))
  FOLLOWER_PID=$(spawn_node follower "$PORT" "$TMP/$1.follower" "$TMP/f.pid")
  sleep 0.4                                 # let it reach accept()
  LEADER_PID=$(spawn_node leader "$PORT" "$TMP/$1.leader" "$TMP/l.pid")
}

# Wait up to $2 tenths of a second for $1 to appear in file $3.
wait_for() {
  i=0
  while [ "$i" -lt "$2" ]; do
    grep -q "$1" "$3" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# --- 1. a live leader keeps the follower a follower -------------------------
start_pair live
sleep 1.5      # several heartbeats, and past the election timeout

if grep -q 'heartbeat 3' "$TMP/live.follower"; then
  ok "follower hears heartbeats from a live leader"
else
  bad "follower did not log 3 heartbeats"; cat "$TMP/live.follower"
fi

if grep -q 'no heartbeat for' "$TMP/live.follower"; then
  bad "follower timed out while the leader was still sending"
else
  ok "follower does not time out while the leader is alive"
fi

# --- 2. a stopped leader is silence, and silence is the election timeout -----
# SIGSTOP freezes the process without closing anything: the socket stays open,
# the kernel sends nothing, and the follower is left waiting — which is what a
# partition or a hung peer looks like from the other end.
kill -STOP "$LEADER_PID" || true
stopped_at=$(date +%s)

if wait_for 'no heartbeat for' 30 "$TMP/live.follower"; then
  ok "a stopped leader is noticed as an election timeout"
else
  bad "follower never timed out on a silent leader"; cat "$TMP/live.follower"
fi
noticed_at=$(date +%s)

reported=$(sed -n 's/.*no heartbeat for \([0-9]*\)ms.*/\1/p' "$TMP/live.follower" | head -1)
if [ -n "$reported" ]; then
  low=$((ELECTION_MS - HEARTBEAT_MS))
  high=$((ELECTION_MS * 2))
  if [ "$reported" -ge "$low" ] && [ "$reported" -le "$high" ]; then
    ok "the gap it measured (${reported}ms) is within [${low}, ${high}]ms"
  else
    bad "measured gap ${reported}ms is outside [${low}, ${high}]ms"
  fi
else
  bad "follower reported no gap length"
fi

elapsed=$((noticed_at - stopped_at))
if [ "$elapsed" -le 3 ]; then
  ok "noticed within ${elapsed}s of the leader going silent"
else
  bad "took ${elapsed}s to notice silence, expected under 3s"
fi

if grep -q 'would become a candidate' "$TMP/live.follower"; then
  ok "follower says what it would do next"
else
  bad "follower did not reach the candidate boundary"
fi

kill -CONT "$LEADER_PID" 2>/dev/null || true; kill -9 "$LEADER_PID" 2>/dev/null || true; LEADER_PID=
# The follower exits on its own after reporting, so killing it may well fail.
kill -9 "$FOLLOWER_PID" 2>/dev/null || true; FOLLOWER_PID=

# --- 3. a killed leader is a close, not a timeout ---------------------------
start_pair killed
if ! wait_for 'heartbeat 2' 30 "$TMP/killed.follower"; then
  bad "follower did not hear from the second leader"; cat "$TMP/killed.follower"
fi

kill -9 "$LEADER_PID" || true; LEADER_PID=

if wait_for 'closed the connection' 30 "$TMP/killed.follower"; then
  ok "a killed leader arrives as a close (the kernel sends FIN for it)"
else
  if grep -q 'no heartbeat for' "$TMP/killed.follower"; then
    bad "a killed leader was reported as an election timeout"
  else
    bad "follower said nothing about the killed leader"
  fi
  cat "$TMP/killed.follower"
fi

# It must not have waited an election timeout to find out: a close is immediate
# information, and treating it as silence would delay every crash by a timeout.
if grep -q 'no heartbeat for' "$TMP/killed.follower"; then
  bad "follower also reported a timeout for a close"
else
  ok "and it did not also call that a timeout"
fi

kill -9 "$FOLLOWER_PID" 2>/dev/null || true; FOLLOWER_PID=

echo "verify: $pass passed, $fail failed"
[ "$fail" = 0 ]
