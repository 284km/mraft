#!/bin/sh
# verify.sh — run a three-node cluster, break it, and check what it decides.
#
# Every other dogfood's test asks whether the right answer came back. This one
# asks what a cluster concludes when a message does not arrive, so the subject is
# a failure and the test has to cause it.
#
# How you break a node decides what you are testing, and the two are not the same
# event:
#
#   stopped (SIGSTOP)   silence, socket still open   election timeout
#   killed (SIGKILL)    the kernel sends FIN for it  an immediate close
#
# A crashed process is *not* a partition. Both eventually produce an election
# here, but only SIGSTOP produces one by way of the timeout that exists for it —
# a test that used `kill -9` would pass while measuring something else.
#
#   sh verify.sh
#
# MERE=/path/to/mere overrides the compiler.

set -e

MERE=${MERE:-mere}
BASE=${BASE:-7310}

pass=0
fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

TMP=$(mktemp -d)
cleanup() {
  for f in "$TMP"/*.pid; do
    [ -f "$f" ] || continue
    p=$(cat "$f")
    kill -CONT "$p" 2>/dev/null || true
    kill -9 "$p" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

"$MERE" -c mraft.mere > "$TMP/m.c"
clang -O2 -w "$TMP/m.c" -o "$TMP/mraft"

P1=$BASE
P2=$((BASE + 1))
P3=$((BASE + 2))

# Started from a subshell that exits immediately, so this shell has no job to
# announce when a node is stopped or killed on purpose below.
start_node() {   # start_node <id> <port>
  ( "$TMP/mraft" "$1" "$2" "$P1" "$P2" "$P3" > "$TMP/n$1.log" 2>&1 &
    echo $! > "$TMP/n$1.pid" ) &
  wait $!
}

wait_any() {     # wait_any <pattern> <tenths>
  i=0
  while [ "$i" -lt "$2" ]; do
    grep -qh "$1" "$TMP"/n*.log 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# The highest term any node has claimed. Not the last line: grep over several
# files walks them in filename order, not in time order, so `tail -1` returns
# whatever node 3 said last rather than what happened last — which made this
# test stop the wrong node and then wait 10s for a leader that already existed.
max_term() {
  grep -h 'became leader for term' "$TMP"/n*.log 2>/dev/null \
    | sed -n 's/.*term \([0-9]*\) .*/\1/p' | sort -n | tail -1
}

leader_of() {    # leader_of <term> -> the id(s) that claimed it
  grep -h "became leader for term $1 " "$TMP"/n*.log 2>/dev/null \
    | sed -n 's/^node \([0-9]*\):.*/\1/p'
}

start_node 1 "$P1"
start_node 2 "$P2"
start_node 3 "$P3"

# --- 1. a leader emerges, and only one --------------------------------------
if wait_any 'became leader' 60; then
  ok "the cluster elects a leader"
else
  bad "no leader after 6s"; cat "$TMP"/n*.log
fi

sleep 1.5     # let the term settle and heartbeats flow

term=$(max_term)
leader=$(leader_of "$term")
count=$(printf '%s\n' "$leader" | grep -c '[0-9]' || true)

if [ "$count" = 1 ]; then
  ok "exactly one node claimed term $term (node $leader)"
else
  bad "$count nodes claimed term $term: $(printf '%s' "$leader" | tr '\n' ' ')"
fi

followers=$(grep -h "following $leader in term $term" "$TMP"/n*.log | wc -l | tr -d ' ')
if [ "$followers" -ge 2 ]; then
  ok "the other two nodes follow node $leader in term $term"
else
  bad "only $followers node(s) followed node $leader"; cat "$TMP"/n*.log
fi

# --- 2. the leader goes silent; the survivors elect another ------------------
kill -STOP "$(cat "$TMP/n$leader.pid")"
stopped_at=$(date +%s)

i=0
newterm=
while [ "$i" -lt 80 ]; do
  newterm=$(max_term)
  [ -n "$newterm" ] && [ "$newterm" -gt "$term" ] && break
  sleep 0.1
  i=$((i + 1))
done
noticed_at=$(date +%s)

if [ -n "$newterm" ] && [ "$newterm" -gt "$term" ]; then
  ok "a silent leader is replaced (term $term -> $newterm)"
else
  bad "no new leader after the leader went silent"; cat "$TMP"/n*.log
fi

newleader=$(leader_of "$newterm")
if [ -n "$newleader" ] && [ "$newleader" != "$leader" ]; then
  ok "the new leader is a different node (node $newleader)"
else
  bad "new leader was '$newleader', expected someone other than $leader"
fi

elapsed=$((noticed_at - stopped_at))
if [ "$elapsed" -le 5 ]; then
  ok "replaced within ${elapsed}s of the leader going silent"
else
  bad "took ${elapsed}s to replace a silent leader"
fi

# --- 3. safety: no term ever has two leaders --------------------------------
# This is the property Raft exists to provide, and the first thing a bug in the
# term rules would break. It is checked over the whole run, not at a moment.
dupes=$(grep -h 'became leader for term' "$TMP"/n*.log \
        | sed -n 's/.*term \([0-9]*\) .*/\1/p' | sort | uniq -d | tr '\n' ' ')
if [ -z "$dupes" ]; then
  ok "no term was ever claimed by two leaders"
else
  bad "two leaders in term(s): $dupes"
  grep -h 'became leader for term' "$TMP"/n*.log
fi

# --- 4. the frozen leader comes back and finds it is stale ------------------
# It still believes it is leader of the old term. The first message from the new
# term has to make it step down: this is the rule that makes a healed partition
# converge instead of producing two leaders.
kill -CONT "$(cat "$TMP/n$leader.pid")"

i=0
while [ "$i" -lt 60 ]; do
  grep -q "following" "$TMP/n$leader.log" && break
  sleep 0.1
  i=$((i + 1))
done

if grep -q "following" "$TMP/n$leader.log"; then
  ok "the revived leader steps down and follows again"
else
  bad "the revived node did not step down"; tail -5 "$TMP/n$leader.log"
fi

# And it must not have carried on leading its old term: whatever it does next
# happens in a term at least as new as the one elected without it.
stale=$(grep -h "became leader for term $term " "$TMP/n$leader.log" | wc -l | tr -d ' ')
if [ "$stale" -le 1 ]; then
  ok "and it did not re-claim its old term"
else
  bad "the revived node claimed term $term again"
fi

echo "verify: $pass passed, $fail failed"
[ "$fail" = 0 ]
