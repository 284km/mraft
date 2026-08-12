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

**Status:** open. Worked around by naming the type `recv_outcome`.

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
`Heard of str | TimedOut | Gone | Failed of int` — which the language can express
perfectly well (`recv_outcome` in `mraft.mere` is that type, reconstructed on the
outside). The FFI boundary is where it is lost: `extern fn` declarations are
C-shaped, so everything arrives as an `int`.

**Status:** open, and the most interesting item here. It is the general question
of how a capability reports *why* it failed, not just *that* it did.

---

## What has not hurt

- **The type system.** A protocol whose states are `follower | candidate |
  leader` and whose messages are variants is what an ML-family language is for.
  Nothing has been fought yet.
- **Regions.** Per-message allocation inside a `region` block is the same
  discipline `mkv` used, and it carried over without thought.
- **`tcp_set_timeout`.** The one capability M0 was expected to need turned out to
  already exist (added for the `mdns` dogfood). The bounded wait was there; what
  is missing is the vocabulary to describe its outcome (P4).
