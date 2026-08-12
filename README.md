# mraft

Raft, written in [Mere](https://merelang.org/), one failure at a time.

```sh
mere -c mraft.mere > m.c && clang -O2 m.c -o mraft

./mraft 1 7001 7001 7002 7003   # id, my port, then every port in the cluster
./mraft 2 7002 7001 7002 7003
./mraft 3 7003 7001 7002 7003
```

```
node 2: election timeout, standing for term 1
node 3: voted for 2 in term 1
node 1: voted for 2 in term 1
node 2: became leader for term 1 with 2 votes
node 1: following 2 in term 1 (was follower)
node 3: following 2 in term 1 (was follower)
```

Freeze the leader (`kill -STOP`) and the other two elect one of themselves in a
higher term. Thaw it (`kill -CONT`) and it discovers it is stale and follows.

## Why it exists

`mraft` is a dogfood: a real program built to push on something the language has
never been asked to do. Ten programs have been written in Mere this way — a
compressor, a grep, an HTTP server, a key-value server, a PNG codec, a kernel —
and **not one of them handles partial failure**. Every network program so far
assumes the other side answers. Each one is a function from input to output, and
its test asks whether the right answer came back.

Raft is the opposite. A follower waits for a heartbeat, and when none comes it
must *conclude* something and act. Correctness is about time: `heartbeat <<
election timeout << mean time between failures`. The interesting states are the
ones where a message did not arrive, or arrived late, or arrived twice, or
arrived from a leader that no longer exists.

So the question this repository asks is not "can Mere express Raft" — it is an
ML-family language with variants and pattern matching, and the answer is
obviously yes. The question is what the language does about **waiting, giving up,
and saying why**. [PAIN.md](PAIN.md) is the answer as it accumulates; it has
already sent one fix upstream.

## Where it is

**M0 — a wait that can end without an answer.** Two nodes and a follower that
reports silence, which established the failure vocabulary the rest is built on:
*heard*, *timed out*, *gone*, and the fact that those are three different events.

**M1 — leader election.** Terms, randomised election timeouts, RequestVote, a
majority, and the rule that a node seeing a greater term steps down. Three nodes
elect one leader, replace it when it goes silent, and never let two nodes hold the
same term.

Next: M2 (log replication and a commit index), M3 (a durable log that survives a
crash), M4 (message loss and reordering, injected on purpose).

## How it is built

A node has to serve peers that dial it, dial the peers it needs, keep its state
consistent, and notice that time has passed. Mere's `channel_recv` waits forever
and the only bounded wait in the runtime is a socket timeout, so rather than fight
that, **time is a message**: a ticker thread sends `Tick` into the same inbox as
every network event, and the node performs no timed wait at all.

```
ticker  ──Tick───────┐
reader ──RequestVote─┤
reader ──VoteGranted─┼──> inbox ──> node (owns all state, one thread)
reader ──Heartbeat───┘                │
                                      └──> per-peer outbox ──> sender ──> TCP
```

The missing feature turned out to be one nobody needs. With every input arriving
as an event, there is exactly one place where state changes — so the state needs
no lock and never crosses a thread boundary — and the election rules become five
ordinary functions from a state and an event to a state.

## Testing a failure

```sh
sh verify.sh
```

The test kills a process on purpose, and the first thing this repository learned
is that *how* you kill it decides what you are testing:

| what happens to the leader | what the others see | what it means |
|---|---|---|
| still running | heartbeats keep arriving | stay followers |
| stopped (`SIGSTOP`) | silence, socket still open | election timeout |
| killed (`SIGKILL`) | the kernel sends FIN for it | an immediate close |

**A crashed process is not a partition.** Only the middle row is what an election
timeout exists for; a crash is immediate information. The first version of the
test used `kill -9`, passed, and measured nothing.

The check that earns its place is the last one: **no term was ever claimed by two
leaders**, asserted over the whole run rather than at a moment. It is the property
Raft exists to provide, and it caught a real bug in this implementation that the
happy path hid completely — the first cluster this program ever ran elected one
leader and held it, while votes were being broadcast to every peer instead of to
the candidate. Two nodes only both won when they happened to become candidates
close enough together. [PAIN.md](PAIN.md) has the details.

## Building

Requires `mere` (v0.1.221 or later — earlier versions buffer the log away) and a
C compiler. Native only: the program is TCP, threads and a monotonic clock, which
reach the outside world through the C backend's FFI.

Node ids are positions in the cluster list, so `./mraft 2 7002 7001 7002 7003`
means "I am node 2, my port is 7002, and the cluster is those three ports in id
order". A node whose id and position disagree refuses to start.
