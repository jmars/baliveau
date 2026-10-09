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

`make test` runs the resume oracle (`tests/test_resume.sh`): it kills the
harness **mid-tool-dispatch** and then asserts a `--resume` run picks the
conversation back up.

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
4. **No tool server yet.** Upstream takes its tools from `mcp_servers[0]` over
   stdio (`mcp_client.c`, `execvpe` with a scrubbed env — works without
   sockets).  The guest's verb table (a Lua module over the fx verbs) is not
   written.  The one used by the oracle is deliberately trivial:
   `tests/fixtures/kill_parent.sh`.
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
