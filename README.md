# fx-harness — a minimal agent harness for the fx-linux guest

Derived from **vibe-runtime's LAYER 2** (`src/llm2/`), reduced to what the guest
can actually run.  One binary, one backend, one transport: a character device.

## Status (MEASURED)

Builds clean natively and runs the loop end-to-end **offline**:

```
$ make
$ cp <a recorded SSE stream> /tmp/fxch-sse
$ FX_CHARDEV=/tmp/fxch-sse VIBE_RUNTIME_CONFIG_DIR=$PWD/config \
    ./build/fx-agent -p "say hi" --agent fx --max-turns 1 --output text
hello
$ echo $?
0
```

and the checkpoint recorded the whole turn:

```
$ cat $VIBE_RUNTIME_DIR/sessions/<sid>/messages.jsonl
{"role":"user","content":"say hi"}
{"role":"assistant","content":"hello"}
```

The recorded stream used above is upstream's
`tests/fixtures/responses_simple.sse` (7,432 B, 21 SSE events).

`make test` runs two oracles: the resume oracle
(`tests/test_resume.sh`) — it kills the harness **mid-tool-dispatch** and then
asserts a `--resume` run picks the conversation back up — and the
observation-loop oracle (`tests/test_outcome.sh`), which asserts every verdict
of the rule below plus its fireability against a pre-fix build (`make blind`).
`make test` therefore builds `build/fx-agent` and `build/fx-agent-blind`; the
oracle builds `build/fx-verbs-server` (`tools/build.sh`) if it is not there yet,
because it drives the REAL tool server rather than a stub.

## Reboot-as-resume

A run must survive the guest rebooting *while it is in flight*.  Two things make
that work, and neither needs `agent_loop.c` to change:

* **Durable per-message flush.** The loop calls the transcript callback for every
  message it appends, and — MEASURED, this is the load-bearing ordering — it does
  so for an assistant message carrying tool calls **before** it dispatches those
  calls (`agent_loop.c:776` vs `:783`).  That callback now appends the message to
  `messages.jsonl` and `fsync`s it (`ckpt_append_line`, one `write(2)` per line so
  a crash mid-flush can only leave a prefix of a line), so the transcript is on
  disk **before** the tool call that reboots the guest can be dispatched.  The
  first successful append also `fsync`s the session directory, because a file's
  contents being durable does not make its new directory entry durable.
  `ckpt_save` still rewrites the whole file at end of run — that rewrite is now
  also the self-heal for a torn tail line (`ckpt_load` skips such a line
  fail-open, so the worst case is losing the newest message and re-answering).
* **The transcript is the resume seed.** `--resume <sid>` resolves a session
  directory under `$VIBE_RUNTIME_DIR/sessions/` (exact name, else a *unique*
  prefix — ambiguous or missing is a fail-closed error), `ckpt_load`s
  `messages.jsonl`, and passes those messages to the loop as its seed array
  instead of `-p` (still required by the CLI, ignored here — the loaded
  transcript already carries the original prompt).

Three details that are easy to get wrong, and are what the oracle tests:

* **The loaded messages are borrowed, not copied** — the loop's seed array points
  into them, so they are freed only *after* the final `ckpt_save`.
* **The on-disk messages must not be re-appended.** The loop re-notifies every
  seed, so the flush callback skips exactly the messages that were already on
  disk (a wrong count duplicates the seed line; the oracle measures this on an
  *unhealed* transcript, because the end-of-run `ckpt_save` would otherwise hide
  it).
* A transcript that ends on an unanswered tool call (the run died mid-dispatch)
  gets a synthesized `role=tool` result — `"(rebooted before the tool returned)"`
  — because the loop's invariant is that every assistant `tool_call` has a
  matching result.  Synthetics are not on disk, so they are not part of the skip
  count.

### Where it lives (durability)

`$VIBE_RUNTIME_DIR` (default `~/.local/share/vibe-runtime`) holds both the
runstore and `sessions/<sid>/`.  In the guest, the root is tmpfs: point
`VIBE_RUNTIME_DIR` at the persistent disk (e.g. `/fx/disk/vibe-runtime`) or the
transcript is lost exactly when the reboot happens.  `VIBE_MAX_RUNS` eviction
applies to runstore *run records*; `sessions/` is never evicted, so the
transcript outlives the run record that pointed at it.

## Why this tree exists

vibe-runtime targets *hosts*: it reaches the model over a TCP socket, optionally
wrapped in mbedTLS, and it carries four provider backends plus a socket-RPC
supervisor.  The fx-linux guest has none of that available:

| upstream dependency | why it cannot be used in the guest |
|---|---|
| `socket(2)` / `connect(2)` | the guest kernel has `CONFIG_NET` unset, so `socket(2)` returns `ENOSYS` |
| `recv(2)` / `send(2)` (the socket BIO) | MEASURED: return `ENOTSOCK` on a chardev, so `http_request` wrote ZERO bytes and the loop reported `backend/loop error` |
| mbedTLS (16 MB vendored) | no TLS: there is no socket to wrap, and the guest must not hold a credential |
| `http_client.c` (HTTP/1.1 framing + chunked/CL body parsing) | an envelope with nothing to carry — the host proxy speaks HTTP to the provider, the guest speaks SSE to the host |
| `daemon.c` (LAYER 1, 6.3 kLOC) | Unix-socket RPC; the guest has no sockets. Already dropped upstream |

## The transport

One declared device.  Nothing else.

```
guest -> host   "<byte-count>\n" then exactly that many bytes of request JSON
host  -> guest  the provider's raw SSE body, verbatim
```

* `src/llm2/fx_transport.c` — the whole transport (open, frame, read).
* The **host owns the endpoint, the headers and the API key**.  `fx_backend.c`
  never transmits a key, and the adapter leaves `b->api_key` unused: no
  credential crosses the channel.
* Every request and every response is a byte stream on a device the host owns,
  so the transcript is recorded by the host rather than self-reported.

Path: `$FX_CHARDEV`, default `/dev/vport0p1`.

### Offline arm

Point `FX_CHARDEV` at a regular file holding a **recorded SSE stream** (no HTTP
envelope).  `O_APPEND` puts the framed request past the canned bytes, and
`fx_send_request` seeks back to offset 0 so reads start at the stream and run to
a real EOF.  No proxy, no network, deterministic.

> MEASURED gotcha: `write(2)` advances the file offset **even under
> `O_APPEND`**, so without that seek the first read returns 0 (EOF) and the loop
> sees an empty stream.

## Deviations from upstream

| change | file |
|---|---|
| TCP connect → chardev open | `src/llm2/fx_transport.c` (+ `openai_responses.c` call site) |
| socket BIO + TLS BIO → direct `read(2)`/`write(2)` | `src/llm2/fx_transport.c` |
| HTTP envelope removed; SSE read raw | `src/llm2/openai_responses.c` |
| four backends → one | `src/llm2/fx_backend.c` (replaces `backend_select.c`) |
| `tls.h`, `http_client.{c,h}` deleted | — |
| TLS default-verify block + `file_readable` deleted | `src/llm2/agent_main.c` |
| `tcgetwinsize(3)` → `ioctl(TIOCGWINSZ)` | `src/llm2/tui.c` — `tcgetwinsize` is glibc≥2.36/POSIX-2024 and **absent from musl**, the libc every fx guest binary uses |

Vendored in-tree: `dhall-c` (config evaluated **in-process**, so a config can be
typechecked before it is activated), `yyjson`, `tomlc99`.  The `datalog-dafsa`
engine (the run store + checkpoint backend, the same engine fx-init and fxstore
use) is NOT vendored: it is linked from the SIBLING Zig checkout
`../datalog-dafsa` (override with `DATALOG_DIR=<path>`), so this tree cannot
build standalone — the rest of the fx stack has the same requirement.  The
legacy C copy this tree used to vendor is gone (its `dafsa_internal.h`
64-byte cache-line static assert cannot hold on 32-bit x86-musl, where
`sizeof(State)` is 60; the stack's real engine is the Zig port).  Native
links the sibling's prebuilt `zig-out/lib/libdatalog.so` (rpath baked);
the musl guest target links a STATIC `libdatalog.a` that make builds from
the sibling's own `zig/build.zig` for `x86-linux-musl` into
`build/datalog-musl/lib/` (a glibc-built `.so` is incompatible with
`elf_i386`, and a dynamic link would defeat the static goal).

## Running it

Config: Dhall, at `$VIBE_RUNTIME_CONFIG_DIR/config.dhall` (default
`~/.config/vibe-runtime/`).  The minimum is an agent:

```dhall
{ agents = [ { name = "fx", agent_type = "agent" } ] }
```

```
-p <prompt> --agent <name> --max-turns N [--resume <short8>]
[--workdir <cwd>] --output text [--auto-approve]
```

## The loop, closed in the guest (B2)

`tests/qemu-agent-b2.sh` runs the whole loop INSIDE qemu, agent-driven and
offline: the harness is driven by a RECORDED SSE stream (no model, no network)
and, through its own MCP tool server (`fx-verbs-server`, spawned by the agent
from `mcp_servers[0]`), it

1. **inspects** the running system — `fx_ls /fx/disk/store`, `fx_read /etc/hostname`;
2. **rewrites its own config** — `fx_write /fx/disk/agent-config.dhall` (the
   Dhall text travels in the recorded tool call, so the file that lands on the
   virtio disk is byte-identical to the fixture's — asserted with `cmp`);
3. **applies it** — `fx_activate /fx/disk/agent-config.dhall`, which publishes a
   generation the HOST never created;

and then the machine is **restarted on the same disk** and comes back up in the
generation the agent authored: `disk store mounted (current vN)` + `boot-ok vN`
+ the agent-authored service's own heartbeat on the console, with the restarted
machine's own `fx_store_verify` call as the verdict.

Three arms, all asserted in one run:

| arm | what it shows |
|---|---|
| 1 | the change SURVIVES: v_A1 (image) → vN (the agent's, hash changed) → post-restart boot-ok vN with the agent's service running |
| 2 | the change FAILS and rolls back: a crasher config → `boot-FAILED vB` + `vB failed` in the disk `.bootlog` → the next boot `stale failed for vB; rolling forward to vA2` → boot-ok, crasher's generation not booted.  (The roll-forward lands on the BRACKET — the generation that carries the agent service — so the agent runs again there; since the observation-loop unit it reads its own record and REFUSES to re-apply the crasher rather than re-creating the failure: see *the observation loop* below.) |
| control | payload withheld (empty ROOTDIR, same store): NOTHING is activated, the generation does not change, every asserted string is absent |

MEASURED properties worth keeping in mind:

* **"Reboot" = restart the VM on the same disk.** fx-init has no `reboot(2)`:
  `do_shutdown()` returns and PID 1 exits — a halt.  The persistence the test
  asserts lives in the store (`/fx/disk/store`) and in `VIBE_RUNTIME_DIR`
  (`/fx/disk/agent-data`), both on the virtio disk.
* **An agent-driven activation is durable but NOT hot-applied.** `fx_activate`
  execs the running root's `/bin/fx-activate` directly, which publishes the
  generation in the store; it does not go through PID 1's channel handler, so
  the RUNNING system is not re-materialized and PID 1 does not re-arm its boot
  decision (the boot verdict inside the agent's own boot is still the OLD
  generation's, and the agent's new services start at the restart).  The
  alternative — `fxctl` — has no transport in the guest at all: `CONFIG_NET` is
  unset (`socket(2)` = ENOSYS, no `control.sock`), and the virtio control port
  has ONE input queue which PID 1 itself reads, so a second in-guest reader
  races PID 1 for the request bytes.
* **`fxstore verify` reports 5 pre-existing drifts on a stock guest root**, all
  of the shape `/bin/X: link_target: symlink points at <store>/<dir>/<binary> !=
  store path <store>/<dir>` with the SAME `<hash>-<pkg>` dir on both sides of
  the `!=`: fx-init's `install` fact records the package DIR
  for a `/bin` link while its own buildfile makes the symlink point at the
  BINARY (`activate.zig` BinLink `from`).  The test PINS that SET — count == 5,
  every line that exact shape, and exactly those five `/bin` names — not merely
  its class, because a
  class-only pin (the unanchored `... != store path ...` pattern, count checked
  only against the line count, no name set) passes an agent-caused drift of the
  same class: a repointed `/bin` link, a 6th drift, the same drift on a
  non-`/bin` path, or a different `/bin` link drifting in place of a pinned one.
  The pin's fireability is proven in-gate: four mutants of the real report
  (repointed link / 6th drift / non-/bin path / renamed link) are each shown
  PASSING the pre-fix assertion and FAILING the pinned one.

## The observation loop: the agent reads the outcome of its own activation (B3)

A never-settling OSCILLATOR was MEASURED on B2's arm 2 (`tests/evidence/qemu-agent-b2/boot-b3-bootlog.txt`):
the agent activates a crasher, the boot fails, fx-init recovers by republishing
older good content **as a new, higher version** (content goes back, the version
number goes up), and — because the agent service lives in the **restored
bracket** — it re-runs, re-reads its FIXED fixture and re-creates the failure:
versions ratchet ~+2/cycle and `<store>/.bootlog` gains a failed line per cycle,
forever.  The agent is *supposed* to look at the roll-forward, see what went
wrong and not do it again.  This unit **mechanises that step**, so the machinery
cannot re-act blindly even when what drives it is a canned fixture (a model can
supply judgement later; the mechanism must not need one).

**THE RULE** (`src/llm2/outcome.h`), applied at the start of every run — an
explicit `--resume` excepted, because that is the operator saying "continue":

> *if the generation I am running in is not the one I activated, my activation
> failed — do not repeat it.*

made precise against the store's own two plain files, because "current ≠ mine"
alone cannot tell a FAILED activation from one that took and was later
superseded:

| A = the generation the harness's record says it activated, C = `<store>/.db/snapshots/CURRENT` | verdict |
|---|---|
| no activation on record, task not completed | **RUN** (ordinary first boot) |
| no activation on record, task completed | **ALREADY_DONE** — do not re-run |
| `A` failed in `<store>/.bootlog` | **ACTIVATION_FAILED** — report, do not repeat |
| `A` ok in the bootlog **and** `done` on record | **ALREADY_DONE** (it took; a later activation moved on) |
| `A` ok in the bootlog, **no** `done` on record | **SUPERSEDED** — it booted, but nothing on record says the *task* finished: report honestly, do not claim a completion the record does not hold |
| `C == A` | **RUN** if unfinished, else **ALREADY_DONE** |
| `A` never judged **and** `done` on record | **ALREADY_DONE** — a *later* run of the task completed, which is the record's strongest evidence |
| `A` never judged, no `done` | **UNRESOLVED** — report, do not repeat |

A refusal **reports and exits 0**, and *why that is safe is a property of the
deployment, not of the code*: fx-init pins `failed` for a service that exits
during the grace window **only when that service is non-console**, and it ignores
the exit status entirely — a service declared `console = Some "console"` is
**exempt** whatever it exits with.  Both payloads declare the agent service
console **and assert it** (`console_pin` in `tests/qemu-agent-observe.sh` and
`tests/qemu-agent-b2.sh`, with a non-console mutant shown to be rejected): a
non-console agent would turn every refusal into a **new** roll-forward
oscillator — the refusal pins `v_C failed` on the healthy rolled-forward
generation, the next boot rolls forward again, the agent refuses again.

**THE WAY OUT, named in every stop report.** A record is settled only by a
**later completed run of the same task** (which writes `done`), so the report
names both escapes: re-run with `--reconsider` (an **operator** flag — a run that
completes then settles the task), or remove this task's lines from
`<data-dir>/attempts.jsonl`.  There is deliberately **no model-facing verb** that
clears the record: an agent that could erase the evidence of its own failed
activation could re-issue it blindly, which is the oscillator this unit exists to
stop.

**`done` MEANS "THE TASK FINISHED", and a turn-limited run does not.** `rc == 0`
only says the loop returned cleanly; a run that exhausts `--max-turns` ends with
the model still wanting tool calls that are never dispatched
(`agent_loop_run_delta_ex`'s `*out_exhausted`), so it records **no** `done` and
warns on stderr.  Recording one would mark an unfinished task **permanently
complete** — the next boot would print "TASK ALREADY COMPLETE" and refuse to
continue work that never happened.

A verdict that needs the store and cannot read it fails
loudly (`exit 2`, naming the path) — the store is **never guessed**; `--store`
names it explicitly (and an explicit `--store` must exist), the default is the
guest's `/fx/disk/store`, and a run with nothing to observe never reads it at all.

**WHERE THE CAUSAL LINK LIVES, and why that is not a convenience.** An
agent-driven activation execs `/bin/fx-activate` directly: it writes **no**
`rt_effect("activate")` and updates **no** runtime relation, so the correlation
"the thing that broke was the thing I just did" **cannot come from the system**.
The harness's own durable record is the only link, and it is on the **disk**:

```
$VIBE_RUNTIME_DIR/attempts.jsonl          # in the guest: /fx/disk/agent-data/…
<epoch> <task> <step> <session> <run> <version> <config>
```

`step=attempt` is written **before** the tool call is dispatched (the loop
notifies the transcript hook before dispatch — the same ordering *Reboot-as-resume*
relies on), `step=result` when the verb's reply names the generation, `step=done`
when the task **finished** (see above: a turn-limited run records none), and
`step=agent` **once per task**, binding the task id to the agent that owns it.
Every field is written through a CR/LF-replacing sanitiser, because the config
argument comes from the model and a newline in it would otherwise forge a whole
extra record line (e.g. a `done` line for the very task the model is working on).
A record line is only read when it **ends with a newline**: a crash mid-write
leaves a prefix, and a prefix cut inside the version token parses as a version —
which used to be adopted, deciding `ALREADY_DONE` from a corrupt record.

`task` is `FNV-1a-64(agent "\x1f" prompt)` — the **prompt**, not the session id,
because every boot of a service creates a new session, so a session id cannot
name "the same task being repeated".  **That makes the prompt
load-bearing**: anything boot-varying in it (a timestamp, a hostname, "boot #N")
makes every boot a **new** task, the record never matches, and the loop is
**silently inert** — every boot re-runs and nothing says why.  Hence the
`step=agent` binding: a boot that computes a **different** task id for an agent
already on record (and has no record of its own) says so loudly
(`TASK IDENTITY DRIFT`).  The invariant is also ASSERTED on the real guest
payload: `tests/qemu-agent-observe.sh` requires the refusing boot's report to
name the **same** task id the disk record holds, which it could not do if the
prompt had drifted.  A `--resume` neither re-binds the task (its `-p` is ignored
by the loop) nor re-records the seed's own activation — the seed is already on
the record, so re-notifying it would write a duplicate attempt stamped with the
**resumed** session/run.

**THE READ SIDE.** `fx_outcome` and `fx_generation`
(`tools/fx-verbs-server.c`, native, store-scoped, no store argument) let a model
read the same two files: `fx_outcome` prints `current <N>`, `last <v> ok|failed`,
`boots <n>` and then every `<store>/.bootlog` line; `fx_generation` prints the
current generation alone.  Both go through the **same reader** as the harness's
boot-time consume (`src/llm2/outcome.c`, linked into both binaries), so the two
cannot drift; an unreadable `CURRENT` is reported as `current UNREADABLE:` with
`exit=1`, never as a guess.

**THE TEST, AND THE DIFFERENCE IS THE POINT** (`tests/qemu-agent-observe.sh`,
one store, one fixture, two payloads whose **only** difference is the harness
binary — the real one vs `make blind`, i.e. built with
`-DFX_HARNESS_NO_OBSERVE`; four boots per arm, separate disks, no control
channel: every assertion is the console or a read-back off the virtio disk):

| boot | ARM OBSERVING (MEASURED) | ARM BLIND (MEASURED) |
|---|---|---|
| 1 | bracket v3 boots ok; the agent reads fx_outcome (`current 3`), writes + activates the crasher → **v5**, recorded durably at `/agent-data/attempts.jsonl` (with its task↔agent binding and **no** `done`: the replayed stream is turn-limited, so the task did not finish) | identical → v5 |
| 2 | v5 boots and FAILS → `boot-FAILED v5`, `5 failed` in the disk `.bootlog` | identical |
| 3 | roll forward to **v7**; the restored bracket re-runs the agent service, which reads its own record, **reports** *"THE ACTIVATION THIS HARNESS RECORDED FAILED"* and issues **no** activation (no new session; the fixture is never dispatched → its text marker is ABSENT) | roll forward to v7 and the blind agent **re-activates** → **v9 > v7** |
| 4 | v7 again: the same report, still nothing created → **SETTLED: max version v7, exactly 1 failed line, 1 session** | v9 boots and FAILS again → **RATCHETED: max version v9, 2 failed lines, 4 generations** |

Both arms are asserted in one run, and the arms are required to differ
(`blind max > observing max`, `blind failed lines > observing failed lines`,
`blind generations > observing generations`): if the blind arm did not ratchet,
the observing arm would be measuring nothing; if the observing arm still
ratcheted, the loop would not be closed.  `tests/test_outcome.sh` (`make test`)
is the rule's own oracle — RUN / C==A / ACTIVATION_FAILED / SUPERSEDED /
ALREADY_DONE / UNRESOLVED / half-recorded attempt / torn (unterminated) line /
unaccounted-then-completed / `--reconsider` / prompt drift / forged newline in the
config / `--resume` seed duplication / worst-case record sizes / unreadable store,
each asserted, and the ACTIVATION_FAILED case shown to **fail** against the blind
build (which re-runs the very task the real one refuses).  Every phase whose
defect was **silent** was shown failing against a pre-fix reconstruction of the
tree (all eight guards reverted, `fail()` allowed to continue): the turn-limited
`done`, the `A ok` completion claim, the torn line deciding `ALREADY_DONE`, the
settle-by-completion rule, `--reconsider`, the drift warning, the forged `done`
record, the resumed duplicate and the oversized record each FAILED there and pass
here.

## Known gaps

1. **The guest-side *reboot* itself is untested here.** The harness half is done
   and gated (`make test` kills a run mid-dispatch and resumes it), but the guest
   half — `fx-init` restarting the run after a real reboot — is not wired, and no
   run is currently started from a supervisor that would re-`exec` it.
2. **The checkpoint must live on the persistent disk**, not the guest's tmpfs
   root, or it is lost exactly when the reboot happens.  It is a single env knob
   now (`VIBE_RUNTIME_DIR`, see *Where it lives*); setting it is the deployer's
   job, and nothing yet *enforces* that the path is not tmpfs.
3. **The datalog engine comes from the SIBLING checkout.** The legacy C copy
   this tree vendored is removed (MEASURED — its
   `vendor/dafsa_internal.h:72` `_Static_assert(sizeof(State) == 64)` failed
   as `60 == 64` on 32-bit x86-musl, reproducing on that vendor file alone).
   The tree now links the fx stack's Zig-built `libdatalog` from
   `../datalog-dafsa` (native: the prebuilt `.so`; musl: a static `.a`
   built by the sibling's own `zig/build.zig`), like fx-init and fxstore.
   Consequence: **this tree cannot build standalone** —
   `make` fails loudly when `../datalog-dafsa/zig-out/lib/libdatalog.so`
   is absent; point it elsewhere with `DATALOG_DIR=<path>`.
4. **The tool server EXISTS (`tools/fx-verbs-server.c`) and the guest one runs
   the loop** (`tests/qemu-agent-b2.sh`, `tests/qemu-agent-observe.sh`): 12
   verbs, MCP stdio, spawned from `mcp_servers[0]`, no sockets anywhere.  What is
   still missing is the Lua module that would present this table to a model in
   the guest, and the in-guest control-plane reads: `fx_query`/`fx_status`/
   `fx_rollback` still go through `fxctl`, which has no transport in the guest
   (see *the loop, closed in the guest* above), so the in-guest-usable verbs
   today are `fx_read`, `fx_ls`, `fx_write`, `fx_activate`, `fx_store_verify`
   (given a `fxstore` staged under `/usr/fx-core/bin`), and the two outcome
   verbs `fx_outcome` / `fx_generation`.  Rules the table now enforces: command
   lookup searches `<root>/bin` FIRST (the running generation's own binaries,
   which fx-init's activation materializes into the store dir its install fact
   names) and only then the `mkinitramfs -b` staging dir `/usr/fx-core/bin` — a
   staged copy must never shadow the binary the running system itself uses; and
   every row that names the persistent store (`fx_activate`, `fx_store_verify`,
   and the native `fx_outcome`/`fx_generation`) is STORE-SCOPED — with no
   `/fx/disk/store` (a diskless guest, where PID 1 falls back to the initramfs
   ramfs) they refuse with a message naming the path rather than reading a stale
   snapshot, exec'ing into a confusing downstream error, or guessing another
   store.
5. **`ToolPolicy`** already exists (`tool_policy.c`) and is built from the
   agent's `enabled_tools`/`disabled_tools` — the capability bound is a config
   field the host controls, not something the agent writes.
6. **A run that dies leaves its runstore record at `status=running` forever.**
   The transcript is fine and resumable, but nothing sweeps the orphan
   (`RS_STATUS_ORPHANED`) or stamps `last_turn_at` per turn.  Follow-up, not part
   of the resume unit.

## Build

```
make          # build/fx-agent (native)
make test     # the resume oracle (needs upstream's recorded SSE fixtures)
make musl     # build/fx-agent.musl (static i386-musl, the guest target) — needs ../datalog-dafsa, see gap 3
make clean
```
