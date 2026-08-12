# mraft

Raft, written in [Mere](https://merelang.org/), one failure at a time.

```sh
mere -c mraft.mere > m.c && clang -O2 m.c -o mraft

./mraft follower 7001          # in one shell
./mraft leader 7001            # in another
kill -STOP <the leader's pid>  # in a third
```

```
follower: listening on :7001
follower: leader connected
follower: heartbeat 1 <- heartbeat term=1 n=0
follower: heartbeat 2 <- heartbeat term=1 n=1
follower: heartbeat 3 <- heartbeat term=1 n=2
follower: no heartbeat for 1001ms (election timeout 1000ms) after 3 heartbeats
follower: would become a candidate here (M1)
```

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

**M0 — a wait that can end without an answer.** Two nodes, one heartbeat
stream, and a follower that reports silence. No election, no log, no terms. What
M0 establishes is the failure vocabulary the rest is built on: the difference
between *heard*, *timed out*, and *gone*.

Next: M1 (leader election with randomised timeouts and a majority), M2 (log
replication and a commit index), M3 (a durable log that survives a crash), M4
(message loss and reordering, injected on purpose).

## Testing a failure

```sh
sh verify.sh
```

The test kills a process on purpose, and the first thing this repository learned
is that *how* you kill it decides what you are testing:

| what happens to the leader | what the follower sees | what it means |
|---|---|---|
| still running | heartbeats keep arriving | stay a follower |
| stopped (`SIGSTOP`) | silence, socket still open | election timeout |
| killed (`SIGKILL`) | the kernel sends FIN for it | an orderly close |

**A crashed process is not a partition.** Only the middle row is what an election
timeout exists for; a crash is immediate information and reacting to it with a
timeout would delay every real crash by a full timeout. The first version of the
test used `kill -9`, passed, and measured nothing.

## Building

Requires `mere` (v0.1.221 or later — earlier versions buffer the log away) and a
C compiler. Native only: the program is TCP and a monotonic clock, both of which
reach the outside world through the C backend's FFI.
