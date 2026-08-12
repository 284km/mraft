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
# Indexes are not compared directly, because a leader appends a no-op of its own on
# election (see mraft.mere) and so the numbering depends on how many elections
# happened. What is compared is the sequence of *client* commands, which is what a
# client can observe, while the invariants still cover every index including the
# no-ops.
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
  for f in "$TMP"/*.pid "$TMP"/chaos/*.pid "$TMP"/client/*.pid; do
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
  # Two nested subshells, both load-bearing:
  #
  # The inner one `cd`s to the temp directory (each node writes its write-ahead log
  # beside itself) and then **execs**, so the pid recorded is the node's own. Backing
  # a `cd X && cmd` compound into the background records the *subshell's* pid
  # instead, and killing that leaves the node running and holding its port — which
  # made the restarted node die with "could not listen", the SIGSTOP freeze a
  # different process entirely, and four checks fail for one reason.
  #
  # The outer one exits immediately, so this shell has no job to announce when a
  # node is stopped or killed on purpose below.
  ( ( cd "$TMP"; exec ./mraft "$1" "$2" "$P1" "$P2" "$P3" > "$TMP/n$1.log" 2>&1 ) &
    echo $! > "$TMP/n$1.pid" ) &
  wait $!
}

# A client sends `PROP <client-id> <seq> <command>` and waits for the answer. The
# `sleep` matters: with stdin closed the moment printf finishes, nc half-closes and
# exits before the reply arrives — which looked exactly like a server that does not
# reply, and is not.
ask() {          # ask <port> <client> <seq> <command> -> the reply line
  { printf 'PROP %s %s %s\n' "$2" "$3" "$4"; sleep 1; } \
    | nc -w 3 127.0.0.1 "$1" 2>/dev/null | head -1
}

# Fire and forget, for the phases that only care about the log.
propose() {      # propose <port> <command>
  seqno=$((${seqno:-0} + 1))
  ask "$1" 1 "$seqno" "$2" >/dev/null 2>&1 || true
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

# Kill a node outright and start it again. Its output is kept under another name so
# the invariants at the end still see what it did before. `wipe` also deletes its
# write-ahead log, which is the difference between a crash and a lost disk.
restart_node() {  # restart_node <id> <port> [wipe]
  kill -9 "$(cat "$TMP/n$1.pid")" 2>/dev/null || true
  sleep 0.4
  mv "$TMP/n$1.log" "$TMP/n$1-before$(date +%s%N 2>/dev/null || echo x).log"
  [ "$3" = wipe ] && rm -f "$TMP/mraft-$1.wal"
  start_node "$1" "$2"
}

restart_all() {   # kill every node and bring them all back from disk alone
  for i in 1 2 3; do kill -9 "$(cat "$TMP/n$i.pid")" 2>/dev/null || true; done
  sleep 0.8
  for i in 1 2 3; do mv "$TMP/n$i.log" "$TMP/n$i-run1.log"; done
  for i in 1 2 3; do start_node "$i" "$(port_of "$i")"; done
}

# The commands a client asked for, in the order they were applied, with the
# leaders' no-ops removed.
commands_of() {  # commands_of <id>
  applied_of "$1" | grep -v ' <noop>$' | cut -d" " -f3- | tr "\n" " "
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
  [ "$(commands_of "$i")" = "alpha beta gamma " ] && agreed=$((agreed + 1))
done
if [ "$agreed" = 3 ]; then
  ok "all three nodes applied alpha, beta, gamma in that order"
else
  bad "only $agreed of 3 nodes applied the same three commands"
  for i in 1 2 3; do echo "-- node $i: $(commands_of "$i")"; done
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
restart_node "$other" "$(port_of "$other")" wipe

i=0
while [ "$i" -lt 100 ]; do
  [ "$(commands_of "$other")" = "alpha beta gamma " ] && break
  sleep 0.1
  i=$((i + 1))
done
if [ "$(commands_of "$other")" = "alpha beta gamma " ]; then
  ok "a node whose disk was wiped is refilled with the same commands"
else
  bad "the wiped node was not brought back up to date: $(commands_of "$other")"
  tail -6 "$TMP/n$other.log"
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
if commands_of "$newleader" | grep -q 'alpha beta gamma'; then
  ok "the new leader already holds what was committed before it"
else
  bad "the new leader is missing committed commands: $(commands_of "$newleader")"
fi

# --- 6. the surviving majority still accepts new commands -------------------
for v in delta epsilon; do propose "$(port_of "$newleader")" "$v"; done

i=0
while [ "$i" -lt 80 ]; do
  case "$(commands_of "$newleader")" in *"delta epsilon "*) break;; esac
  sleep 0.1
  i=$((i + 1))
done
case "$(commands_of "$newleader")" in
  *"alpha beta gamma delta epsilon "*)
    ok "the surviving two commit two more commands with one node down" ;;
  *) bad "the survivors could not commit: $(commands_of "$newleader")" ;;
esac

# --- 7. the frozen node comes back and catches up ---------------------------
kill -CONT "$(cat "$TMP/n$leader.pid")"

i=0
while [ "$i" -lt 100 ]; do
  case "$(commands_of "$leader")" in *"delta epsilon "*) break;; esac
  sleep 0.1
  i=$((i + 1))
done
case "$(commands_of "$leader")" in
  *"delta epsilon "*) ok "the revived node catches up on its own" ;;
  *) bad "the revived node did not catch up: $(commands_of "$leader")" ;;
esac

if grep -q 'following' "$TMP/n$leader.log"; then
  ok "and it stepped down rather than staying leader of its old term"
else
  bad "the revived node never stepped down"
fi

# --- 8. the whole cluster dies, and comes back from disk alone ---------------
# Nothing survives in any process. Everything the cluster agreed to has to come
# back out of the three write-ahead logs, or it was never durable in the first
# place — which is the difference between a consensus algorithm and a rumour.
restart_all

i=0
while [ "$i" -lt 150 ]; do
  n=0
  for k in 1 2 3; do
    case "$(commands_of "$k")" in
      "alpha beta gamma delta epsilon ") n=$((n + 1)) ;;
    esac
  done
  [ "$n" = 3 ] && break
  sleep 0.1
  i=$((i + 1))
done

survived=0
for k in 1 2 3; do
  [ "$(commands_of "$k")" = "alpha beta gamma delta epsilon " ] && survived=$((survived + 1))
done
if [ "$survived" = 3 ]; then
  ok "all three nodes replayed the full sequence from disk after a total restart"
else
  bad "only $survived of 3 nodes recovered the sequence"
  for k in 1 2 3; do echo "-- node $k: $(commands_of "$k")"; done
fi

recovered=$(grep -hc 'recovered term' "$TMP"/n*.log 2>/dev/null | paste -sd+ - | bc 2>/dev/null || echo 0)
if [ "$recovered" -ge 3 ]; then
  ok "and each of them said what it recovered"
else
  bad "only $recovered nodes reported recovering"
fi

# A restarted cluster must not invent anything: the only entries beyond the client
# commands are leaders' no-ops.
strays=$(applied_all | grep -v ' <noop>$' | cut -d" " -f3- | sort -u \
         | grep -vxE 'alpha|beta|gamma|delta|epsilon' || true)
if [ -z "$strays" ]; then
  ok "and nothing was invented that no client asked for"
else
  bad "unexpected commands appeared: $strays"
fi

# --- 9. the same invariants, over a network that loses and reorders ----------
# Everything above ran over loopback TCP, which delivers in order, exactly once, or
# not at all. Raft is specified against a network that does none of that, and until
# now this program's tolerance of loss was a claim rather than a result.
#
# `--chaos 25` gives each outbound peer message an independent 25% chance of being
# dropped, of being duplicated, and of being held back to travel behind the next
# one. Client connections are untouched, so a proposal that is accepted was really
# accepted; it is the consensus traffic that is unreliable.
#
# What is asserted is what Raft actually promises: **the nodes agree**. Not
# exactly-once — a command sent to a cluster whose leader changes mid-send can be
# accepted twice, and de-duplicating that needs client ids and sequence numbers,
# which is a different feature at a different layer. So the checks are agreement,
# presence, and first-occurrence order.
CH="$TMP/chaos"
mkdir -p "$CH"
cp "$TMP/mraft" "$CH/mraft"

C1=$((BASE + 10))
C2=$((BASE + 11))
C3=$((BASE + 12))

start_chaos_node() {   # start_chaos_node <id> <port>
  ( ( cd "$CH"; exec ./mraft "$1" "$2" "$C1" "$C2" "$C3" --chaos 25 \
        > "$CH/c$1.log" 2>&1 ) &
    echo $! > "$CH/c$1.pid" ) &
  wait $!
}

chaos_commands_of() {  # chaos_commands_of <id>
  sed -n 's/^node [0-9]*: applied [0-9]* term=[0-9]* cmd=\(.*\)$/\1/p' \
    "$CH/c$1.log" 2>/dev/null | grep -v '^<noop>$' | tr "\n" " "
}

for i in 1 2 3; do start_chaos_node "$i" "$((BASE + 9 + i))"; done

i=0
while [ "$i" -lt 100 ]; do
  grep -qh 'became leader' "$CH"/c*.log 2>/dev/null && break
  sleep 0.1
  i=$((i + 1))
done
if grep -qh 'became leader' "$CH"/c*.log 2>/dev/null; then
  ok "a leader is elected even with a quarter of the messages misbehaving"
else
  bad "no leader under chaos after 10s"; cat "$CH"/c*.log
fi

# One command at a time, offered to every node — only the leader accepts — and then
# waited for, so the next one is proposed against a cluster that has settled.
for v in c1 c2 c3 c4 c5; do
  tries=0
  while [ "$tries" -lt 25 ]; do
    for k in 1 2 3; do
      ask "$((BASE + 9 + k))" 2 "$tries$k" "$v" >/dev/null 2>&1 || true
    done
    j=0
    while [ "$j" -lt 20 ]; do
      case "$(chaos_commands_of 1)$(chaos_commands_of 2)$(chaos_commands_of 3)" in
        *"$v"*) break ;;
      esac
      sleep 0.1
      j=$((j + 1))
    done
    case "$(chaos_commands_of 1)$(chaos_commands_of 2)$(chaos_commands_of 3)" in
      *"$v"*) break ;;
    esac
    tries=$((tries + 1))
  done
done

# Let replication catch up on whatever the last round dropped.
i=0
while [ "$i" -lt 150 ]; do
  a=$(chaos_commands_of 1); b=$(chaos_commands_of 2); c=$(chaos_commands_of 3)
  [ "$a" = "$b" ] && [ "$b" = "$c" ] && case "$a" in *c5*) break ;; esac
  sleep 0.1
  i=$((i + 1))
done

a=$(chaos_commands_of 1); b=$(chaos_commands_of 2); c=$(chaos_commands_of 3)
if [ "$a" = "$b" ] && [ "$b" = "$c" ]; then
  ok "all three nodes agree on the same sequence under chaos"
else
  bad "the nodes disagree under chaos"
  echo "  node 1: $a"; echo "  node 2: $b"; echo "  node 3: $c"
fi

missing=""
for v in c1 c2 c3 c4 c5; do
  case "$a" in *"$v"*) ;; *) missing="$missing $v" ;; esac
done
if [ -z "$missing" ]; then
  ok "every command that was accepted came through (c1..c5)"
else
  bad "commands never arrived:$missing  (sequence: $a)"
fi

# First occurrences in the order they were proposed. A duplicate later on is
# allowed; a reordering is not, because that is the one thing the log decides.
firsts=$(printf '%s\n' $a | awk '!seen[$0]++' | tr '\n' ' ')
if [ "$firsts" = "c1 c2 c3 c4 c5 " ]; then
  ok "and in the order they were proposed"
else
  bad "first occurrences are out of order: $firsts"
fi

# The invariant that matters, now against an adversarial transport.
cdupes=$(grep -h 'became leader for term' "$CH"/c*.log \
         | sed -n 's/.*term \([0-9]*\) .*/\1/p' | sort | uniq -d | tr '\n' ' ')
if [ -z "$cdupes" ]; then
  ok "no term had two leaders under chaos either"
else
  bad "two leaders under chaos in term(s): $cdupes"
fi

cconf=$( sed -n 's/^node [0-9]*: applied \([0-9]*\) term=\([0-9]*\) cmd=\(.*\)$/\1 \2 \3/p' \
           "$CH"/c*.log 2>/dev/null | sort -u \
         | awk '{ idx = $1; $1 = ""; if (idx in seen && seen[idx] != $0)
                    print "index" idx ":" seen[idx] " vs" $0; seen[idx] = $0 }' )
if [ -z "$cconf" ]; then
  ok "and no index was applied with two different commands"
else
  bad "chaos produced disagreement: $cconf"
fi

for i in 1 2 3; do kill -9 "$(cat "$CH/c$i.pid")" 2>/dev/null || true; done

# --- 10. what a client is told ----------------------------------------------
# Until M5 `PROP` got no reply at all, so a client could not tell a committed command
# from one accepted by a leader that died before replicating it. Everything a client
# can be told is now said out loud, and each of these is a different answer:
#
#   OK <index>          committed; it is in the log of a majority and will not move
#   DUP <seq>           this exact request was already applied, once
#   NOTLEADER <id>      ask that one instead
#   LOST <index>        the leader that accepted it stepped down; ask again
CL="$TMP/client"
mkdir -p "$CL"
cp "$TMP/mraft" "$CL/mraft"

D1=$((BASE + 20))
D2=$((BASE + 21))
D3=$((BASE + 22))

start_client_node() {   # start_client_node <id> <port>
  ( ( cd "$CL"; exec ./mraft "$1" "$2" "$D1" "$D2" "$D3" > "$CL/d$1.log" 2>&1 ) &
    echo $! > "$CL/d$1.pid" ) &
  wait $!
}

for i in 1 2 3; do start_client_node "$i" "$((BASE + 19 + i))"; done

i=0
while [ "$i" -lt 80 ]; do
  grep -qh 'became leader' "$CL"/d*.log 2>/dev/null && break
  sleep 0.1
  i=$((i + 1))
done
dleader=$(grep -h 'became leader' "$CL"/d*.log 2>/dev/null \
          | sed -n 's/^node \([0-9]*\):.*/\1/p' | tail -1)
dother=1
for i in 1 2 3; do [ "$i" != "$dleader" ] && dother=$i; done

reply=$(ask "$((BASE + 19 + dleader))" 9 1 "committed-please")
case "$reply" in
  OK*) ok "the leader answers a client with $reply, after the entry commits" ;;
  *)   bad "expected OK from the leader, got '$reply'" ;;
esac

# The index it named must be one the leader actually applied — the reply is not a
# promise about the future.
idx=$(printf '%s' "$reply" | sed -n 's/^OK \([0-9]*\)$/\1/p')
if [ -n "$idx" ] && grep -q "applied $idx term=" "$CL/d$dleader.log"; then
  ok "and index $idx is one it had applied by then"
else
  bad "the reply named index '$idx', which the leader had not applied"
fi

reply=$(ask "$((BASE + 19 + dother))" 9 2 "wrong-node")
case "$reply" in
  "NOTLEADER $dleader") ok "a follower answers NOTLEADER and names node $dleader" ;;
  *) bad "expected 'NOTLEADER $dleader' from a follower, got '$reply'" ;;
esac

# The same (client, seq) again: answered, not applied a second time. This is what a
# retry after a lost reply looks like, and it is the only reason the sequence number
# is carried through the log.
reply=$(ask "$((BASE + 19 + dleader))" 9 1 "committed-please")
case "$reply" in
  DUP*) ok "a repeat of client 9 seq 1 is answered $reply rather than applied again" ;;
  *)    bad "expected DUP for a repeated request, got '$reply'" ;;
esac

# Count applications only. The leader also logs an `accepted` line for the same
# command, and counting both would call one application two.
applied_twice=$(grep -h 'applied .*cmd=committed-please' "$CL"/d*.log | wc -l | tr -d ' ')
if [ "$applied_twice" = 3 ]; then
  ok "and the command appears once per node, not twice"
else
  bad "committed-please was applied $applied_twice times across 3 nodes"
  grep -h 'committed-please' "$CL"/d*.log
fi

# --- 11. a reply that must not come -----------------------------------------
# Freeze both followers. The leader can still accept, but it cannot commit without a
# majority — so `OK` must not arrive. This is the check that the reply waits for
# commit rather than for the append; before M5 there was nothing to wait.
for i in 1 2 3; do
  [ "$i" = "$dleader" ] || kill -STOP "$(cat "$CL/d$i.pid")" 2>/dev/null || true
done
sleep 0.3

reply=$(ask "$((BASE + 19 + dleader))" 9 3 "no-majority")
if [ -z "$reply" ]; then
  ok "with the majority frozen, no OK comes back at all"
else
  bad "got '$reply' for an entry no majority could have stored"
fi

if grep -q 'accepted .*cmd=no-majority' "$CL/d$dleader.log"; then
  ok "though the leader did accept and log it (uncommitted, unanswered)"
else
  bad "the leader never even accepted the entry"
fi

for i in 1 2 3; do
  [ "$i" = "$dleader" ] || kill -CONT "$(cat "$CL/d$i.pid")" 2>/dev/null || true
done

# What happens to that entry now is *not* guaranteed, and asserting that it commits
# was this test being wrong twice before being right once. A frozen process's
# monotonic clock keeps running, so both followers wake up believing they have heard
# nothing for seconds and immediately stand for election; the old leader steps down,
# and an accepted-but-uncommitted entry may legitimately be discarded by whoever
# wins. That is precisely what the missing `OK` meant.
#
# So what is checked is the guarantee that does exist: the cluster works again, and
# the doubtful entry ends up either everywhere or nowhere.
# Liveness is an "eventually", so the check has to be one too: keep asking, with a
# deadline, rather than once. Two nodes that just thawed both stand for election
# immediately (their clocks ran while they were stopped, so they believe they have
# heard nothing for seconds), and a cluster mid-election has nobody who can commit.
#
# Every attempt carries the same client id and sequence number — which is what a real
# client does after a lost reply, and what makes the retries safe: the log can end up
# holding the request twice, and the state machine applies it once.
got=
round=0
while [ -z "$got" ] && [ "$round" -lt 6 ]; do
  for k in 1 2 3; do
    r=$(ask "$((BASE + 19 + k))" 9 4 "after-thaw")
    case "$r" in OK*|DUP*) got=$r ;; esac
    [ -n "$got" ] && break
  done
  round=$((round + 1))
done
if [ -n "$got" ]; then
  ok "the cluster commits again once the majority is back ($got, round $round)"
else
  bad "nothing could be committed in 6 rounds after the followers returned"
fi

# The retries above may well have been logged more than once. Applied once is the
# claim, and it is the sequence number that makes it true.
thaw_applied=$(grep -h 'applied .*cmd=after-thaw' "$CL"/d*.log | wc -l | tr -d ' ')
thaw_skipped=$(grep -hc 'already applied' "$CL"/d*.log 2>/dev/null \
               | paste -sd+ - | bc 2>/dev/null || echo 0)
if [ "$thaw_applied" -le 3 ]; then
  ok "and the retried command was applied at most once per node ($thaw_applied, $thaw_skipped skipped as duplicates)"
else
  bad "after-thaw was applied $thaw_applied times across 3 nodes"
fi

holders=$(grep -hc 'applied .*cmd=no-majority' "$CL"/d*.log 2>/dev/null \
          | paste -sd+ - | bc 2>/dev/null || echo 0)
if [ "$holders" = 0 ] || [ "$holders" = 3 ]; then
  ok "the entry no client was promised is on every node or on none ($holders of 3)"
else
  bad "the doubtful entry is on $holders of 3 nodes"
  grep -h 'no-majority' "$CL"/d*.log
fi

for i in 1 2 3; do kill -9 "$(cat "$CL/d$i.pid")" 2>/dev/null || true; done

# --- 12. the invariants, over the whole run ---------------------------------
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
