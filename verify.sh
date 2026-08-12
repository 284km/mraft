#!/bin/sh
# verify.sh — run a three-node cluster, break it, and check what it agreed.
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
# The two checks that earn their place are the invariants, asserted over the whole
# run rather than at a moment:
#
#   * no term was ever claimed by two leaders
#   * no index was ever applied with two different commands
#
# The first caught a real bug in this program that the happy path hid completely.
# The second is the property the whole protocol exists to provide.
#
#   sh verify.sh
#
# MERE=/path/to/mere overrides the compiler.

set -e

MERE=${MERE:-mere}
BASE=${BASE:-7510}

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
port_of() { echo $((BASE + $1 - 1)); }

# Started from a subshell that exits immediately, so this shell has no job to
# announce when a node is stopped or killed on purpose below.
start_node() {   # start_node <id> <port>
  ( "$TMP/mraft" "$1" "$2" "$P1" "$P2" "$P3" > "$TMP/n$1.log" 2>&1 &
    echo $! > "$TMP/n$1.pid" ) &
  wait $!
}

propose() {      # propose <port> <command>
  printf 'PROP %s\n' "$2" | nc -w 1 127.0.0.1 "$1" >/dev/null 2>&1 || true
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

wait_in() {      # wait_in <file> <pattern> <tenths>
  i=0
  while [ "$i" -lt "$3" ]; do
    grep -q "$2" "$1" 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# The highest term any node has claimed. Not the last line: grep over several
# files walks them in filename order, not in time order, so `tail -1` returns
# whatever node 3 said last rather than what happened last — which made an earlier
# version of this test stop the wrong node.
max_term() {
  grep -h 'became leader for term' "$TMP"/n*.log 2>/dev/null \
    | sed -n 's/.*term \([0-9]*\) .*/\1/p' | sort -n | tail -1
}

leader_of() {    # leader_of <term>
  grep -h "became leader for term $1 " "$TMP"/n*.log 2>/dev/null \
    | sed -n 's/^node \([0-9]*\):.*/\1/p'
}

applied_of() {   # applied_of <id> -> "index term cmd" per line
  sed -n 's/^node [0-9]*: applied \([0-9]*\) term=\([0-9]*\) cmd=\(.*\)$/\1 \2 \3/p' \
    "$TMP/n$1.log" 2>/dev/null
}

# Every application by anyone, across every log this run produced — including the
# logs of processes that were killed and restarted, whose history still counts.
applied_all() {
  sed -n 's/^node [0-9]*: applied \([0-9]*\) term=\([0-9]*\) cmd=\(.*\)$/\1 \2 \3/p' \
    "$TMP"/n*.log 2>/dev/null
}

# Kill a node outright and start it again. Its log file is kept under another name
# so the invariants at the end still see what it did before.
restart_node() {  # restart_node <id> <port>
  kill -9 "$(cat "$TMP/n$1.pid")" 2>/dev/null || true
  sleep 0.4
  mv "$TMP/n$1.log" "$TMP/n$1-before.log"
  start_node "$1" "$2"
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

sleep 1.2     # let the term settle and heartbeats flow

term=$(max_term)
leader=$(leader_of "$term")
count=$(printf '%s\n' "$leader" | grep -c '[0-9]' || true)
if [ "$count" = 1 ]; then
  ok "exactly one node claimed term $term (node $leader)"
else
  bad "$count nodes claimed term $term"
fi

lport=$(port_of "$leader")

# --- 2. what the cluster is for: the same commands, in the same order --------
for v in alpha beta gamma; do propose "$lport" "$v"; done

if wait_in "$TMP/n$leader.log" 'applied 3 ' 60; then
  ok "the leader commits three proposals"
else
  bad "the leader did not commit three proposals"; cat "$TMP/n$leader.log"
fi

sleep 0.8     # give the followers their heartbeat
agreed=0
for i in 1 2 3; do
  got=$(applied_of "$i" | head -3 | tr '\n' '|')
  [ "$got" = "1 1 alpha|2 1 beta|3 1 gamma|" ] && agreed=$((agreed + 1))
done
if [ "$agreed" = 3 ]; then
  ok "all three nodes applied alpha, beta, gamma in that order"
else
  bad "only $agreed of 3 nodes applied the same first three entries"
  for i in 1 2 3; do echo "-- node $i"; applied_of "$i"; done
fi

# --- 3. a follower will not accept a proposal -------------------------------
# It has no way to know whether its own view is current, so appending would be
# inventing history that no majority agreed to.
other=1
for i in 1 2 3; do [ "$i" != "$leader" ] && other=$i; done
propose "$(port_of "$other")" "should-be-refused"

if wait_in "$TMP/n$other.log" 'rejected a proposal' 30; then
  ok "a follower refuses a proposal and names the leader"
else
  bad "a follower did not refuse a proposal"; tail -3 "$TMP/n$other.log"
fi
if grep -q 'should-be-refused' "$TMP"/n*.log 2>/dev/null; then
  bad "the refused command was applied somewhere anyway"
else
  ok "and the refused command was never applied anywhere"
fi

# --- 4. a node killed outright comes back with nothing and is refilled --------
# This is the only thing that exercises the leader walking `next index` backwards:
# the restarted node has an empty log, so every AppendEntries is refused until the
# leader has backed off to index 1. It also shows what M3 is for — a killed node
# loses its entire log, because nothing is written down yet.
restart_node "$other" "$(port_of "$other")"

if wait_in "$TMP/n$other.log" 'applied 3 ' 100; then
  ok "a node restarted from an empty log is refilled to index 3"
else
  bad "the restarted node was not brought back up to date"
  tail -6 "$TMP/n$other.log"
fi

if applied_of "$other" | head -3 | tr '\n' '|' \
   | grep -q '^1 1 alpha|2 1 beta|3 1 gamma|$'; then
  ok "and it received them in the original order"
else
  bad "the refilled log is not the original sequence"; applied_of "$other"
fi

# --- 5. the leader goes silent; the survivors carry on -----------------------
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

# The new leader must already hold what was committed before it was elected —
# this is what the election restriction is for.
if applied_of "$newleader" | grep -q '^3 1 gamma$'; then
  ok "the new leader already holds what was committed before it (index 3)"
else
  bad "the new leader is missing committed entry 3"; applied_of "$newleader"
fi

# --- 6. the surviving majority still accepts new commands -------------------
for v in delta epsilon; do propose "$(port_of "$newleader")" "$v"; done

if wait_in "$TMP/n$newleader.log" 'applied 5 ' 60; then
  ok "the surviving two commit two more (indexes 4 and 5)"
else
  bad "the survivors could not commit with one node down"
  tail -5 "$TMP/n$newleader.log"
fi

# --- 7. the frozen node comes back and catches up ---------------------------
kill -CONT "$(cat "$TMP/n$leader.pid")"

if wait_in "$TMP/n$leader.log" 'applied 5 ' 80; then
  ok "the revived node catches up to index 5 on its own"
else
  bad "the revived node did not catch up"; tail -6 "$TMP/n$leader.log"
fi

if grep -q 'following' "$TMP/n$leader.log"; then
  ok "and it stepped down rather than staying leader of its old term"
else
  bad "the revived node never stepped down"
fi

# --- 8. the invariants, over the whole run ----------------------------------
dupes=$(grep -h 'became leader for term' "$TMP"/n*.log \
        | sed -n 's/.*term \([0-9]*\) .*/\1/p' | sort | uniq -d | tr '\n' ' ')
if [ -z "$dupes" ]; then
  ok "no term was ever claimed by two leaders"
else
  bad "two leaders in term(s): $dupes"
  grep -h 'became leader for term' "$TMP"/n*.log
fi

# Agreement: every node that applied an index applied the same thing there. This
# is the property the protocol exists to provide, and no single node can observe
# it — it only exists across the logs.
conflicts=$( applied_all | sort -u \
             | awk '{ idx = $1; $1 = ""; if (idx in seen && seen[idx] != $0)
                        print "index" idx ":" seen[idx] " vs" $0;
                      seen[idx] = $0 }' )
if [ -z "$conflicts" ]; then
  ok "no index was ever applied with two different commands"
else
  bad "nodes disagree: $conflicts"
fi

# And nobody skipped: what is applied is a prefix, 1..n with no holes.
holes=""
for i in 1 2 3; do
  expected=1
  for idx in $(applied_of "$i" | cut -d' ' -f1); do
    [ "$idx" = "$expected" ] || holes="$holes node$i(saw $idx wanted $expected)"
    expected=$((idx + 1))
  done
done
if [ -z "$holes" ]; then
  ok "every node applied a gapless prefix"
else
  bad "gaps in the applied sequence:$holes"
fi

echo "verify: $pass passed, $fail failed"
[ "$fail" = 0 ]
