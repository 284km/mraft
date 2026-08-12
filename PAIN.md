# Pain

What writing this in [Mere](https://merelang.org/) cost, in the order it was
found. The point of the repository is this file: `mraft` exists to be a program
whose correctness is about *time* and *partial failure*, because no earlier Mere
program was, and to find out what the language does about that.

Fixed items name the version that fixed them.

---

## P1 — the reserved-name warning does not look at type names

`type wait = ...` compiles to C containing `typedef struct wait wait;`, which
collides with `union wait` in `<sys/wait.h>`:

```
error: use of 'wait' with tag type that does not match previous declaration
```

The compiler already has a list of libc and C-keyword names and warns when a
**top-level `let`** collides with one (`docs/patterns.md` §5). The check never
runs for `type` declarations, so a type name gets no warning and the failure
surfaces from clang instead — the same "documented builtin failing at the wrong
layer" shape as the `print_int` bug in v0.1.190.

`wait` is also not on the list, which is a second, smaller thing: the list covers
`<stdlib.h>`, `<math.h>`, `<time.h>` and POSIX I/O, but not `<sys/wait.h>`.

**Status:** open. Worked around by not naming a type `wait`, which is a fine
thing to do and a poor thing to have to know.

---

## P2 — a killed process is not a partition (not a language problem)

The first version of `verify.sh` killed the leader with `kill -9` and expected
the follower to report an election timeout. It reported a *close* instead, and it
was right: when a process dies its sockets are closed by the kernel, so the peer
receives a FIN and `read` returns 0. That is information, and it arrives
immediately.

Silence — the thing an election timeout is actually for — is what a partition, a
hung process, or a dropped network looks like: the socket stays open and nothing
comes. `SIGSTOP` produces it, which is why the timeout case in `verify.sh` is
produced that way.

Not a defect in anything. Recorded because the test that used `kill -9` passed
while measuring nothing, and a whole class of distributed-systems tests are wrong
in exactly this way.

---

## P3 — a long-running program's log was invisible (fixed in mere v0.1.221)

`print` lowered to `puts` and nothing in the runtime ever called `fflush`. With
stdout on a terminal that is invisible, because C line-buffers a tty. With stdout
redirected to a file or a pipe — which is how a server is run, and how any test
reads its output — C switches to full buffering, so **nothing appeared until the
process exited or 4KB accumulated**.

Every previous dogfood was a batch program: it printed and exited, and the exit
flushed. `mraft` is the first Mere program meant to be *watched while running*,
and it logged nothing at all.

Fixed upstream: the C backend now emits `setvbuf(stdout, NULL, _IOLBF, 0)` in
`main`, and the LLVM backend flushes after each `print`. A program's output no
longer depends on whether someone redirected it.

---

## P4 — one `int` cannot say why a read returned nothing

`tcp_read` returns what `read(2)` returned: a count, `0` at end of stream, and
`-1` for everything else. With `SO_RCVTIMEO` set, "everything else" covers both
*the deadline passed* and *the connection broke*, and those call for opposite
responses — the first starts an election, the second is a peer that needs
reconnecting.

The program tells them apart by reading the clock around the call and asking
whether the failure took as long as the deadline it was given. That works, and it
is a workaround: it infers a cause from a duration.

The shape that would not need it is a return type that says which happened —
`Heard of str | TimedOut | Gone | Failed of int`, which the language expresses
perfectly well. The FFI boundary is where it is lost: `extern fn` declarations are
C-shaped, so everything arrives as an `int` and the caller reconstructs a meaning
it should have been handed.

M1 does not hit this, because it does no timed reads at all: making time a message
removed every deadline from the socket layer, and a read either brings a message
or ends the connection. The question comes back when a node needs to tell a peer
that is *slow* from one that is *gone* — which is M2's problem, not M1's.

**Status:** open, and the most interesting item here. It is the general question
of how a capability reports *why* it failed, not just *that* it did.

---

## P5 — the Send check asks for a type that inference has not reached yet

Spawning a thread that captures a peer's port was refused:

```
type error: cannot capture `p` of unknown type across a thread boundary
    |     let _ = spawn (fn () -> sender p out buf (0 - 1)) in
```

`p` comes from `Cons (p, rest)` where the list is annotated two lines above, and
it is an `int`. The Send check runs before that annotation has propagated to the
pattern variable, so it sees an unresolved type variable and refuses rather than
waiting.

The message is honest about what happened, which is the good part: it says
"unknown type", not "not Send". But the fix is to write `let peer_port = (p : int)
in` and capture that instead — an ascription that carries no information the
program did not already have, added to satisfy the order two passes run in.

**Status:** open. Every capture in `mraft.mere` that a reader might think is
redundant is this.

---

## What the language had nothing to do with

Two bugs in M1 were mine, and both are worth recording because of *how* they were
caught rather than what they were.

**Votes were broadcast instead of addressed.** `on_request_vote` sent its
`RVR` to every peer, so in a three-node cluster every candidate in that term
counted a vote cast for somebody else as a vote for itself, and **two nodes became
leader of term 1**. The happy path looked perfect — the first cluster this program
ever ran elected one leader and held it — and the bug only appeared when two nodes
timed out close enough together to both be candidates. What caught it was the
invariant check in `verify.sh` ("no term was ever claimed by two leaders"), which
looks at the whole run instead of at a moment.

**The test read its own logs in the wrong order.** `grep -h ... "$TMP"/n*.log |
tail -1` walks the files in *filename* order, not in time order, so "the latest
term" was whatever node 3 happened to say last. The test then stopped the wrong
node and waited ten seconds for a leader that already existed. Reading several
logs as one timeline is a thing you have to do deliberately.

---

## What has not hurt

- **The type system.** A protocol whose states are `follower | candidate |
  leader` and whose messages are variants is what an ML-family language is for.
  Nothing has been fought yet.
- **Nothing about expressing the protocol.** The election rules are five
  functions from a state and an event to a state, and they read like the paper.
- **`tcp_set_timeout`.** The one capability M0 was expected to need turned out to
  already exist (added for the `mdns` dogfood). The bounded wait was there; what
  is missing is the vocabulary to describe its outcome (P4).
- **Making time a message.** `channel_recv` waits forever and there is no timed
  receive, which sounded like the blocking problem for M1. It was not: a ticker
  thread that sends `Tick` into the same inbox removes the need for one entirely,
  and leaves the election rules as ordinary functions from a state and an event to
  a state. The missing feature turned out to be a feature nobody needs.
- **Records and variants for protocol state.** A node is a record, a role is a
  three-way variant, an event is a four-way one, and the compiler checks that
  every arm is handled. This is what an ML-family language is for and it has cost
  nothing.

## Not yet known

- **Memory under sustained load.** `mkv` wrapped each request in a `region` block
  so that per-request garbage was reclaimed, and measured the result flat. M1 does
  not: the actor loop allocates a state record and some strings per event and
  relies on the general collector. Nothing has measured a node that has been
  running for an hour, so nothing is claimed about it.
