# Eigenform — self-plan

**A system that reconfigures itself, and is selected by whether it comes back up.**

`eigenform`: von Foerster's term for *the fixed point of a recursive operation — the object that is
its own description*. That is what `fixpoint-linux` becomes once an agent closes the loop: the
system's own specification is produced by the system.

**This is a NEW design.** The name `setpoint` is reused, and the VLHA-era design record
(`~/setpoint/design/architecture.md`: the substrate-heterogeneous triple network, the currency,
C1–C27) **is not this design** — that line did not work out. Nothing here should be read as
continuing it. This file is deliberately kept OUTSIDE `~/setpoint/` so the two records cannot be
conflated.

Markers: **MEASURED** (a number or behaviour I observed, with the artifact named) ·
**INTERPRETATION** (the reading I take from it) · **PROJECTION** (not yet true).

---

## 1. Thesis

Give an agent a running system whose entire state is content-addressed and whose boot is a verdict,
and let it rewrite the system from inside. Provenance and rollback are then not features the agent
is given — they are properties of the substrate it lives in.

The loop is: **inspect → reconfigure → reboot → the system re-enters as a new generation, or
automatically rolls back**. The agent never edits a running machine in place; it proposes a new
generation and is judged by whether that generation boots.

**INTERPRETATION:** the boot verdict is a *viability* signal, not an improvement signal. Everything
below that depends on the system is built; everything that depends on knowing whether a change is
*worth keeping* is not (§7.1). This is the design's live edge.

---

## 2. What already exists (the substrate)

Sibling checkouts: `/var/data/workspace/fixpoint-linux/{fx-init,fxstore,fx-core,dhake,dhall-c,datalog-dafsa}`.

**MEASURED — the generation lifecycle is built and tested.**
- A generation IS a store path: `fx/store/<hex64>-system-generation/{Dhakefile.dhall,etc/…}`
  (the shipped demo image, `fx-demo/evidence/image-contents.txt`).
- `fx-init` (PID 1): durable `.bootlog` at `<store>/.bootlog` (`init.zig:664-686`);
  `bootlog_append` does `fflush`+`fsync`+`fclose`+**`syncfs_store()`** on the *store's own*
  filesystem (`:670-686` — post-pivot `/` is tmpfs, so a bare `sync()` flushes the wrong fs);
  `bootlog_last` **skips `"shutdown"`** entries (`:699`), so a clean stop is not a verdict;
  `bootlog_newest_ok_below` (`:714`); a failed verdict for the current version triggers
  `fx_store_rollback` to the newest ok generation (`:1099`), and that rollback is
  **snapshot-complete** (`:1107`).
- `qemu_ctrl.sh` **proves the loop's hard half**: the guest writes a version that never existed at
  image-build time, boots it, fails in grace, rolls back, and on the next boot **rolls forward past
  the stale failure** — over a virtio-serial chardev and a virtio-blk disk. Its own words: "a
  host-built-state boot cannot produce this line."

**MEASURED — the control surface is built.** `fxctl` verbs: `status | q <rel> [vals…] |
start|stop|restart <svc> | probe | activate <config> | rollback <ver> | shutdown | grep <regex> |
search <term…>`. Two transports: AF_UNIX `/run/fx/control.sock`, and a virtio-serial port
(`/dev/vportNpM`, `init.zig:2972-3075`) with `fxctl --chardev` / `FX_CHARDEV` (`fxctl.zig:206-224`).

**MEASURED — the runtime datalog IS the provenance graph.** `activate_facts.zig:28-45`:
`generation, svc, svc_argv, svc_env, svc_probe, svc_bin, svc_backoff, svc_console, user,
tool_fxstore, boot_grace` plus the two Lens-2 relations **`install(target, origin, mode, genhash)`**
and **`provides(pkg, store_dir)`**. The agent can ask the running system what it installed, from
where, in which generation.

**MEASURED — the store's own audit toolset** (`fxstore`): `what <target>` (the provenance proof
tree), `why <pkg>` (closure, provided targets, pulling roots), `verify` (**bidirectional**, exit 1
on drift), `timeline`, `gc --retain N`, `rollback <v>`.

**MEASURED — the guest's executable surface is closed.** The shipped image contains `/bin/init` and
`/usr/fx-core/bin/fx-*` (**69 stages**) and nothing else: **no `sh`, no `bash`, no busybox, no
coreutils** (`fx-demo/evidence/image-contents.txt`). `fxsh` has a `-c LINE` mode
(`fx-sh.zig:112`), and **separators and a background `&` are loud errors** (`fx-shell.zig:36`) —
there is no `&&`, `||` or `&`.

**INTERPRETATION:** the guest is already the containment story. The vocabulary is a *fact* (the
binaries do not exist) rather than a policy anyone enforces.

---

## 3. The loop we are building

```
agent (inside)                system (same machine)
  fxctl q <rel>       ──▶  PID 1's live datalog: generation / install / provides / log
  fxstore why|what    ──▶  closure + provenance proof tree
  fxstore verify      ──▶  drift(s), exit 1
  write config.dhall  ──▶  Dhall is total: a config is a value or a type error
  fxctl activate      ──▶  new generation (a store path) + a .db snapshot
  reboot              ──▶  comes up in it; a failure in grace rolls back automatically
```

**MEASURED:** every verb above exists and the boot/rollback half is proven (`qemu_ctrl.sh`).

**The two things that are ours to build:** the harness that runs this loop *inside* the guest
(§4–§6), and the oracle that decides whether a change is worth keeping (§7.1).

---

## 4. The harness — `fx-harness` (BUILT, GREEN)

`/var/data/workspace/fixpoint-linux/fx-harness` — derived from `vibe-runtime`'s LAYER 2
(`/var/lib/workspace/vibe-runtime/src/llm2`), reduced to what the guest can run.

**MEASURED — it builds and the loop runs end-to-end offline:**
```
$ FX_CHARDEV=<recorded SSE stream> VIBE_RUNTIME_CONFIG_DIR=$PWD/config \
    ./build/fx-agent -p "say hi" --agent fx --max-turns 1 --output text
hello                        # rc=0; 21 SSE events; 7,523 bytes read to EOF
$ cat ~/.local/share/vibe-runtime/runs/<id>/messages.jsonl
{"role":"user","content":"say hi"}
{"role":"assistant","content":"hello"}
```

**MEASURED — the transport is the whole interface.** Guest→host is a framed request
`"<byte-count>\n<json>"`; host→guest is the provider's raw SSE body. **No HTTP, no sockets, no
TLS, no mbedTLS (16 MB gone).** The host proxy owns the endpoint, the headers and the **API key** —
`b->api_key` is deliberately unused in the adapter, so **no credential crosses the channel**.

**Why the reductions were forced (MEASURED, not assumed):**
- The guest kernel has `CONFIG_NET` unset → `socket(2)` returns `ENOSYS`.
- `http_socket_bio`'s `recv`/`send` are `recv(2)`/`send(2)` → **`ENOTSOCK` on a chardev**, so
  `http_request` returned −1 having written **zero bytes**. Replacing the socket *connect* was not
  enough; the socket BIO itself had to go.
- `write(2)` **advances the file offset even under `O_APPEND`** → the first read returned 0 (EOF)
  and the loop saw an empty stream (`bytes=0 events=0 finished=1 err=0`). Fixed by `lseek(fd,0)` at
  the end of `fx_send_request` (ignoring `ESPIPE`, which a real chardev returns).

**INTERPRETATION:** because the egress is one declared device the host owns, the transcript is
recorded by the *host* rather than self-reported by the harness. That is a provenance property, not
a logging convenience.

**Not yet:** `--resume` is **not wired** — it validates the id and records it
(`agent_main.c:416`) but never calls `ckpt_load` (`checkpoint.c:253`), and `ckpt_save` runs **once,
at the end of the run** (`agent_main.c:520`), so a mid-run reboot loses the transcript. Wiring it is
in flight (§9).

---

## 5. The agent's language — LuaJIT, chosen for auditability

**MEASURED:** LuaJIT's target list is `x86, x64, ARM, ARM64, PPC, MIPS32, MIPS64` with JIT — **i386
is first-class.** Its **entire standard-library surface is one C array**,
`lj_lib_load[]` in `src/lib_init.c`: ten entries, plus a preload array holding `ffi` guarded by
`#if LJ_HASFFI`. Bounding the agent's capability is editing that array.

**MEASURED — three of the four escape hatches are INERT by construction in this guest:**
- `os.execute` → `system(3)` and `io.popen` → `popen(3)` both need `/bin/sh`, **which the image
  does not contain**.
- `package.loadlib` → `dlopen`/`dlsym` needs a shared object; the guest binaries are static.
- `ffi` → syscalls: removed twice, by `-DLUAJIT_DISABLE_FFI` **and** the preload array.

**The rule:** **gate the syscall bridge, tolerate the dynamic evaluator.** `ffi`/`uctypes` grants
kernel access; `load`/`eval` only lets the agent write more programs in the language it already has
— which is the job.

**CALIBRATION:** the audit bounds **reachable surface, not behaviour** (metatables and `__index`
chains mean a static read of a script does not tell you what it does). And the filesystem is the one
place the OS is not helping: single root user, so a write policy is a decision, not a default.

**Rejected, with the reason:** a C compiler. `cproc`/QBE **has no i386 backend** and v86 cannot boot
x86_64, so it cannot produce a guest binary at all; `tcc` would work but brings back
as/ld/libc/ELF identity questions a text artifact does not have; and **host-side `zig build` is
arbitrary host execution** (`build.zig` is a host-native program, `@cImport` spawns cpp+clang,
`@embedFile` reads host files, and `comptime` alone can OOM the builder).

---

## 5a. The Osier→Lua backend, and where the compiler sits

**USER (2026-10-13): "osier is self hosting, a lua backend would mean the compiler could be a lua file
too, maybe that is enough to let the agent have it inside the guest?"** Yes — and the reason is that
the property we were protecting was never about compilation.

**THE PROPERTY, RESTATED.** LuaJIT is in the guest *precisely so the agent can run code*. The bound is
not "the agent cannot run things"; it is **"a component becomes part of the system only through the
store and a generation."** Running and *integrating* are different acts:

| | governed by |
|---|---|
| **running** code in the guest | LuaJIT's presence — already there, already audited |
| **integrating** code into the system | the store + a generation + activation |

So putting the compiler in the guest does not dent observability, because integration is what is
governed — the generation's `svc_bin`/`svc_argv` and the store's provenance relations.

**WHY THE LUA BACKEND IS A GOOD FIT, AND NOT A TRANSPILER.** An earlier note of mine rejected a
Python→Lua *transpiler* because a third-party translator's divergences are invisible. That objection
was about third-party translators. Here: Osier is **your** language, with a **Lean mechanization** and
**already two backends** (ZINC csexp for the VM; QBE for native, `tools/qbe/`). A Lua backend is a
third backend in an existing structure. Payoffs:

- **text → text is deterministic and trivially content-addressable** — no linker, no ELF identity
  problem. This is the property already measured for Lua scripts: *a script is its own content.*
- **LuaJIT is already built and audited in-guest** (static i386, FFI off, stdlib reduced).
- **It removes the whole AOT chain** — `aotdump → gen.zig → zig build` — from the loop: no zig
  toolchain, no per-component cross-build.
- **The self-hosting closure restores fast iteration**: Osier→Lua ⇒ the compiler (written in Osier)
  compiles to Lua ⇒ **the compiler is a Lua file** ⇒ LuaJIT runs it in-guest, and being self-hosting it
  can compile the compiler. The guest then holds the whole toolchain **as text**. That reverses the cost
  I had flagged (every test being a reboot): the agent compiles and runs locally, and integrates when
  ready.
- **Three backends give differential testing**: the same compiler through ZINC csexp, QBE native and
  Lua, compared on one corpus — and `selfhost-gate.sh` is *already that shape* (self-compiled output
  `cmp`-byte-identical to stock-compiled). So backend fidelity is checkable against the compiler
  itself rather than being a leap of faith.

**THE LINE THAT MUST HOLD — and it is the same rule as the oracle's:**

> **The agent may have a compiler; it may not have the one that grades it.**

If the compiler is a store node the generation runs, the agent can propose a generation containing a
**modified** compiler — and if the checks (typecheck-for-gate, corpus byte-identity, the oracle) ran
through that same compiler, the agent could make them pass by editing the checker. So:

- **guest compiler** — the agent's working tool. Iteration, its own components. Normal store/generation
  rules.
- **host frozen compiler** — the grader. Never agent-writable.

**THE AUDIT STILL DESCRIBES THE BOUND.** A compiler in the guest is a large **program**, not new
**reach**: with FFI off, a Lua program can read and write files and compute — exactly what LuaJIT already
permits — and cannot reach the kernel. That is why `tests/luajit-audit.sh` asserts the **runtime surface**
rather than "the program is small".

**NOT YET VERIFIED, and it is the enabling question for the in-guest checker:** whether Osier's pipeline
has a **check-only (non-emitting) typecheck entry point**. The typechecker exists; I did not find a
check-only mode. That matters because **typecheck-in-guest / compile-on-host** was the split that would
give fast feedback without giving the agent a compiler — and if the agent is to have the compiler anyway,
the split becomes a scheduling choice rather than a bound.

## 6. The capability model

**The recipe is the host-execution capability.** `fxstore build` runs `Shell`/`Run` actions **on the
host** under bwrap+palisade. So an agent-writable package-set entry is a host-execution grant.

Therefore the agent may write:
- **sources** — interpreted in the guest, contained ✓
- **configs** — Dhall is total, so evaluation terminates ✓

and **not recipes** — because a recipe is code the host runs.

**INTERPRETATION:** this is the same gate as the `Shell`/`Run` question in `fxstore`'s Action
union, arrived at from the opposite direction. Two independent arguments landing on one boundary is
the strongest evidence available that it is the real one.

---

## 7. What is designed, and what is not

**As of 2026-10-13 §7.1 has a first instance (`osier-share`) and §7.1a a first design (egress as a
type); the rest of this section is still open.** The founding statement was blunt and is kept: the
oracle is the item that decides whether this is worth building.

### 7.1 The oracle — a per-task frozen seat, and its first instance
**THE FOUNDING PROBLEM, unchanged:** there is **no design for what makes a change an improvement** —
the boot verdict certifies *viability* (it booted, it did not roll back), and `fxstore verify`
certifies *coherence* (nothing drifted). Neither says a change is *better*.

Without a **frozen, host-side evaluator that the agent cannot write**, the loop will faithfully
reconfigure, activate, reboot, roll back on failure — and **change things while improving nothing**.
The evaluator must live outside the guest precisely *because* the guest is where the agent lives.

**THERE IS NO SINGLE ORACLE (user, 2026-10-13): "I'll want different oracles for different agent
tasks."** So the oracle is a **named, pluggable, frozen seat** selected per task, and the loop takes
it as a parameter. Every oracle must satisfy three properties, and they are the definition:

1. **Host-side** — computed outside the guest, because the guest is where the agent lives.
2. **Unwritable by the agent** — the agent may not author, patch, or pin it.
3. **A function of OBSERVABLE SYSTEM STATE**, not of the agent's own artifacts — see the gaming
   analysis below. This is the property that is easy to get wrong and the one that decides whether
   the oracle measures the system or the agent's intentions.

#### The first instance: `osier-share`

**Task: "maximise the amount of the system written in Osier."**

What Osier is (**MEASURED**): `withe/` is the Osier repo — an Elm→ZINC compiler, the ZINC VM, a Lean 4
mechanization, and an evidence chain, for the λρG paper. **Feasibility is green**, which is why this
task is usable rather than notional: (a) `withe/build.zig` threads `standardTargetOptions` into every
exe and into the zinc_vm dependency, so an i386 static cross-build is supported; (b) there is a real
**AOT path** (`tools/aot/`: `aotdump <csexp> <entry> → gen.zig`, then `zig build gen.zig` +
`tools/aot/run.zig` produces **a native binary whose entry is the compiled program**), so an
Osier-written component can be a *guest binary*, not merely a VM program. And the baseline is
unambiguous: `rg osier` over `fx-init`, `fx-core` and `fxstore` returns **nothing — the running system
is currently 0% Osier**.

**A ready-made freeze harness already exists.** `withe/tools/osier-numbers.sh` is described as "the
paper's single reproducible measurement chain" — self-contained, **idempotent**, printing every number
the paper cites, with a committed corpus baseline (`tools/osier-corpus-baseline.sha256`, byte-identity
per compiled artifact), a PASS/FAIL fixture gate, and a Lean theorem/axiom list. `tools/selfhost-gate.sh`
goes further: the compiler compiles itself and **every fixture's output is `cmp`-byte-identical** to
the stock compiler's. These are already frozen and committed, so the evaluator side of this oracle is
mostly *reuse*, not construction.

**THE GAMING ANALYSIS — and the specific counter-measure.** "Maximise the amount of the system written
in Osier" is a *measure*, not a predicate, and a measure is where a self-modifying agent games hardest.
The naive metric — lines or bytes of Osier in the source tree — is trivially defeated:

| game | why the naive metric pays for it |
|---|---|
| **duplication, not replacement** | adding an Osier copy raises the Osier share while the C original still runs |
| **dead Osier** | code that is never executed still counts as "written" |
| **padding** | one enormous Osier file beats ten small correct ones |
| **the wrapper loophole** | a 3-line Osier program that execs the existing stage moves *behaviour* nowhere while raising the share |

**THE COUNTER-MEASURE: measure the ACTIVE GENERATION, not the source tree.** The store's own provenance
relations are written by the system and read host-side, so they cannot be inflated:

- `provides(pkg, store_dir)` — package → store directory,
- `install(target, origin, mode, genhash)` — what is installed where, from which origin, in which generation,
- the generation's `svc_bin` / `svc_argv` — **which binaries the running services actually exec.**

So the metric is: **of the binaries the active generation actually RUNS, what fraction are Osier-built?**
An artifact counts only when it is executed, which kills dead-Osier and padding outright. And a
component counts as Osier-built only if its **derivation's source tree is Osier** (`.elm`/`.csexp`
with an AOT recipe) — which kills the wrapper loophole, because a wrapper's derivation is C.

**IT IS A TIE-BREAKER, NOT AN OBJECTIVE.** Order of operations: **boots ok** (viability) → **no drift**
(`fxstore verify`) → *then* maximise the Osier share. Alone, the metric is satisfiable by shipping
Osier that breaks the system; as the last term of a lexicographic order over viable, coherent
candidates, it is a real gradient.

**ONE DECISION LEFT TO THE USER, because it changes the metric:** does "amount" mean **code share**
(binaries/files, gameable as above and needing the derivation test) or **behaviour share** (weighted by
what the components actually do — services, or syscalls — which needs a different and harder
instrument)? The design above assumes code share with the derivation gate; behaviour share would
require the held-out-suite machinery this repo does not yet have.

**PROJECTION, now with a precedent:** the older design line's shape (a held-out suite with typed
verdicts and the visible/held-out split instrumented, so a change that games the measurable surface
lands as a distinguishable class rather than a pass) is still not this design — but `osier-share` shows
what the *first* one looks like, and it needed no held-out suite at all: it needed the system's own
provenance relations.

#### The numerator's growth path, and why the tool table is not the bound

**USER (2026-10-13): "there will be more long workloads, the agent may write MCP servers for itself."**
Two consequences, and the second is a correction to an assumption of mine.

**(a) The JIT's justification is a workload CLASS, not a single case — and it inverts my earlier
reasoning.** I had argued the JIT might not pay because "the agent's scripts are short". But the
guest's real profile is not short scripts: it is the Osier→Lua **compiler**, and **agent-authored MCP
servers** — long-running, CPU-bound processes. Amortised trace compilation is exactly right for those.
JIT stays ON, and it is enforced rather than incidental: `tools/build-luajit.sh` GATE 3 is two-sided
(the same probe with the JIT on must start >= 1 trace, and with `jit.off()` must start exactly 0, so a
stubbed JIT OR a broken counter fails it). MEASURED: `JIT gate OK: traces started with JIT on=1, with
jit.off()=0`, on every build.

**(b) THE TOOL TABLE IS NOT THE CAPABILITY BOUND — the runtime surface is.** There are now two tiers
of tools: the **declared, frozen, audited** fx-verbs server, and **agent-authored MCP servers** the
agent writes for itself. An agent that can write and spawn its own servers is not bounded by a tool
list; it is bounded by **what a Lua program can reach**, which is LuaJIT's reduced stdlib with FFI off.
This is why `tests/luajit-audit.sh` is the load-bearing artifact and the verb table is only an
interface. State it, because it is easy to mistake the one for the other.

**(c) And this is the numerator's growth path — which is a good sign for the metric, because it grows
by RUNNING things.** An agent-authored MCP server written in Osier, activated as a **service**, appears
in the generation's `svc_bin`/`svc_argv` — exactly the numerator above. So the share rises by executing
agent-written components, never by adding dead code. It also gives the whole loop its first concrete,
checkable task:

> **the agent writes an MCP server in Osier, activates it as a service, and the share moves from 0% to
> non-zero.** Services are already supervised by fx-init (restart/backoff/probe), and the harness
> already spawns stdio MCP servers, so the machinery exists end to end.

### 7.1a Egress: Dhall-typed MCP, not raw sockets

**USER (2026-10-13): "not raw sockets, something around dhall-typed MCP only (so it never sees the ACTUAL
network)."** The guest keeps `CONFIG_NET` unset, so every property built on that survives — the single
declared egress, no exfiltration channel, and no TCP clock in the guest.

**TYPING BEATS FIREWALLING HERE:** the bound becomes a **type**, not a policy filter. The agent cannot
express "reach evil.com" because no such value exists in its vocabulary — the same move as the missing
`/bin/sh` and the closed `fx-*` set, one level up.

**THE LOAD-BEARING ELEMENT a Dhall *schema* does not provide.** A tool schema is a **signature**;
something must **implement** it, and that something is the only place the real network exists. So the
design requires a **closed, host-owned catalog of network PRIMITIVES** — `http.get`, `http.post`, … with
constrained parameters (allowed hosts, methods, size caps, read-only vs publish) — which Dhall
declarations may only **instantiate, never invent**. Without it, a "Dhall tool schema" is either a
signature with no implementation or a generic escape hatch that undoes the design. The model to copy is
`fxstore`'s `Action` union: a closed, enumerable vocabulary of operations the system will actually
execute, applied to the network.

**READ AND PUBLISH MUST BE DIFFERENT TYPES.** Exfiltration *is* a publish, and "the agent can POST
anything to anywhere it can reach" is the regret case. With them typed, *"this generation can only READ
from these three hosts"* is enforced by the type rather than hoped for by a rule.

**AGENT-AUTHORED MCP SERVERS ARE NOT NETWORK ACCESS**, which is what keeps the graph clean: a
guest-authored server is the agent's own logic under LuaJIT, and it reaches the world only through the
harness's tool table, populated from the **host**.

```
guest MCP server (agent logic) -> harness tool table -> the chardev  <- THE ONLY EGRESS
                                                        host proxy: policy from the ACTIVE
                                                        GENERATION's Dhall, credentials, one log
```

The chardev already carries the model stream and now carries network-tool requests too: **one device,
all egress** — so the property holds for everything, and the guest never sees a socket, an IP or a token.

**THE PAYOFF, PRECISELY.** Two independent records: **declared reach** (the generation's Dhall —
content-addressed, rollback-able, answerable as a *query*: "what could this generation reach?") and
**observed reach** (the host's one log). **The interesting audit is the difference** — traffic not
licensed by a declaration is a finding; a declaration never exercised is a stale grant. Rollback rolls
back the *grant* alongside the code.

**THE SEAT ALREADY EXISTS, so this is an extension, not a new mechanism:** the runtime config *is* Dhall
and is evaluated in-process by dhall-c (`config.c:10` documents `{ agents = [ {name, agent_type, model,
default_max_turns, mcp_servers} ] }`), and it already carries a tool policy (`enabled_tools`/
`disabled_tools` → `ToolPolicy`) plus `mcp_servers` with `api_key_env_var`. The system config's
`Service` record is Dhall too. Egress declarations extend both existing schemas.

**RESIDUALS, stated so the design does not overclaim:**
- **Prompt injection is not fixed by typing.** Fetched content entering the agent's context cannot be
  distinguished from instructions by the model. Not a containment failure — but "the agent fetched a page
  and then did what the page said" is a live failure mode; the mitigation is that its actions stay typed
  and logged, so the consequence is visible rather than silent.
- **Every oracle in the family must be able to SEE capability changes**, because **an egress grant is a
  capability increase and a code-only oracle (like `osier-share`) is blind to it.** Otherwise the agent
  satisfies the oracle while quietly widening what it can reach. A general requirement on every oracle.

### 7.2 Trial vs accepted GC roots
`gc --retain N` exists. A self-reboot loop accumulates generations. Decide which generations are
collectable trials and which are pinned accepted history — or the store grows without bound, or the
history rots into dangling references.

### 7.3 Determinism
v86's RTC/CMOS is host-fed, device identity comes from `Math.random`/`getRandomValues`, and
`Date.now()` appears in the network stack. Either patch those three sites or **always enter from a
hashed `restore_state` snapshot** — a far weaker requirement. Note the *agent* path can never be
hermetic (the model is nondeterministic by construction); only the *build* path is.

### 7.4 The v86 lane's kernel — the inverted-cost finding
**MEASURED:** the demo's lean kernel has `# CONFIG_PCI is not set` (no PCI, no virtio, no ATA), and
the **pinned qemu kernel is x86_64** (`CONFIG_X86_64=y`, verified by downloading the release asset
and matching its sha256) — and **v86 cannot boot 64-bit kernels**. v86 also has **no virtio-blk**
(only console/9p/net/balloon, though it does expose `virtio-console0-output-bytes`/`-input-bytes`).
So the browser lane is the **harder** lane, not the easier one: it needs a purpose-built i386 kernel
with virtio-console *and* ATA, `/dev/hda` support in `fx-init`, and device wiring in the harness.

### 7.5 Is the image a cache or a blob?
**MEASURED:** `image.zig:40-57` — two **cold** builds of identical sources are **not**
byte-identical (symtab/strtab tail; `SOURCE_DATE_EPOCH` and strip do not close it); warm builds are.
Reproducibility is claimed only for repeat runs on a persistent work dir. So `image ↔ system` is not
a function on a cold cache.

**CORRECTION (appended 2026-10-13, MEASURED — the scope above is narrower than it reads).** That
measurement is of **fx-init's image pipeline** (`zig build` of Zig code plus payload packing). It does
**not** transfer to `fx-harness`'s own C compiles, and I had been carrying it as if it did — the
"a fact measured on one filesystem applied to a store on another" failure shape. What actually holds
for this tree, sha256-measured:

| artifact | fixed path, from clean, **no** epoch pinning | different path |
|---|---|---|
| `build/fx-agent.musl` (shipped) | identical | **identical** |
| `build/luajit.musl` (shipped) | identical | **identical** |
| the sibling's **Zig-built** `libdatalog.a` | identical | — |
| `build/fx-agent` (dev, `-g`, unstripped) | identical | differed, **now fixed** |

So **there is no timestamp to pin**: no `SOURCE_DATE_EPOCH` is set, and a grep for `__DATE__`/`__TIME__`
across our sources and every vendored dep finds none.

**The rule this yields, and it generalises: STATIC + STRIPPED is what makes an artifact
content-addressable.** The guest binaries carry no rpath and no debug info, so no build path *can*
survive in them. The dev binary did, until `-ffile-prefix-map=$(CURDIR)=.` removed it — after which a
full string-table diff of two builds at different paths shows exactly one differing string left: the
**sibling's absolute path in the rpath**, which is the loader's business rather than the compiler's,
and is only closable with a sibling prefix-map plus a `$ORIGIN` rpath. Not done: the dev artifact is
not the one that ships, and the shipped one is static with zero `NEEDED`.

**INTERPRETATION:** the addressability hazard in §7.5 is real for the *image*, and absent for the
*artifacts this tree produces*. Which strengthens §8.2's caveat's counterpart: a store path derived
from these inputs does denote the same bytes here.

---

## 8. Corrections carried (refuted claims must not propagate)

1. **The store is NOT history-free.** It carries `.db/snapshots/N/{closure,dep,pkg,root,srcstore,store}.dafsa`
   + `manifest.txt`. What is missing is a *retention decision*, not a history. (An earlier note of
   mine said "the store is history-free by design; git is the journal" — wrong. **MEASURED.**)
2. **Nothing verifies a built artifact's bytes against its address.** The store is
   **input-addressed**: `hex64 = sha256_hex(canonical_derivation(P))` over name/version/**source
   clean-tree Merkle**/target/recipe/deps (`derivation.zig:5`, `:452+`) — not the output. Combined
   with (7.5), **the same store path can hold different bytes.** `fxstore verify` compares install
   facts *and their origin copies* against the rootfs; it does not compare a derivation's output to
   a recorded output hash.
3. **A generation cannot answer "which config produced me."** `generation(genhash, buildfile,
   dhake, epoch)` and `genhash` is the canonical serialization of the *facts*. Adding the config's
   store path as a term is the missing link.
4. **`cosmocc` cannot target i386** (x86_64 + AARCH64 only), so "every artifact is a single portable
   cosmocc APE" cannot apply to the guest. The guest libc is i386-musl via `zig cc`.
5. **The `/tmp` post-pivot bug is FIXED**, with a committed asymmetry test
   (`fx-demo/evidence/tmp-fix-before-after.txt`). It was once proposed as the first task.
6. **`fx-demo` IS in git** (`fixpoint-linux/fx-demo`, assets + `SHA256SUMS` + harness + evidence).
7. **The loop belongs INSIDE the guest.** My earlier "put the loop on the host" was wrong: outside,
   the tool vocabulary is a *policy* (the host shell is unbounded) — inside it is a *fact* (the
   binaries do not exist). `checkpoint.c` + `--resume` also means the resumability requirement is
   half-built, not undesigned.
8. **`provider.zig`-era detail:** a stray at the **rootfs top level is not drift**; a stray under an
   owned root is. **MEASURED this session** by a test added *beside* the validated code (8/8 green;
   mutation of the count assertion → 7 pass / 1 fail), with the validated tree untouched.*
9. **`fxstore verify` is scoped, not general:** "no install facts (or a snapshot predating them) →
   no scan: absence of knowledge is not drift."

10. **"The image has no shell" IS RIGHT IN EFFECT, WRONG IN MECHANISM.** The initramfs **does** ship
    busybox `/bin/sh` — a broken `rdinit` drops to a root prompt. It is **post-pivot** `/bin`, a
    dhake-materialized tmpfs, that has no `sh`, so `fx-init`'s `exec_sh_retry` fallback
    (`init.zig:370`) finds no target. **The agent's service runs post-pivot, so the
    "`os.execute`/`io.popen` are inert" claim holds for the agent — but the LuaJIT audit's ARM 2 must
    be scoped POST-PIVOT**, or it will assert something false about the pre-pivot boot.
11. **`fx-init/zig/zig-out/bin` currently holds i386-musl binaries**; anything consuming that directory
    directly gets an `ENOEXEC` rdinit. The qemu-agent gate now asserts the **ELF class** of every guest
    binary it provisions.
12. **Instrument instance (the "mechanism right, the reader wrong" pattern, again):** the disk belt's
    `debugfs ls -p` parser rejected `…/<name>//` and accepted `.`, so it reported **"no transcript"** on
    runs where the transcript **was** on the disk — a reader bug reported as a missing write.
13. **The `fx-demo/evidence/image-contents.txt` claim is scoped to the browser lane's image.** I had
    been repeating it as a claim about the system; it is a claim about *that* image.

---

## 9. Build state and the queue

**GREEN — every item below is orchestrator-verified, and every one is committed.**

| what | commit | evidence |
|---|---|---|
| harness native build + the loop offline | `515fd14` | prints `hello`, rc=0; transcript written |
| **resume wired** (reboot = resume) | `515fd14` | `make test` 5 phases PASS; **asymmetry proven by mutation** |
| **the MCP tool server** (10 verbs) | `515fd14` | guest artifact i386 static; 37-check smoke, 0 failed |
| **guest build** (engine swap) | `80222c2` | links the stack's own Zig `libdatalog`; `make musl` green; 1,686,488 B stripped i386 static, **0 NEEDED**, runs |
| **LuaJIT** cross-built | `adbdb08` | 843,544 B stripped i386 static; **byte-reproducible** (4 from-clean builds, same sha256) |
| **the LuaJIT capability bound** | `14f42b0` | stdlib 10→9; `debug` unlinked; `package` reduced so `require` survives; audit 19/19, **mutation-proven**; FFI-off gate; **JIT gate two-sided** |
| **THE GUEST MILESTONE (B1)** | `564e3b3` | the harness loop **and** the tool server run **inside a qemu guest, post-pivot**, with the transcript on the virtio disk; 3-boot gate with a negative control; no cross-repo change needed |
| substrate | — | built and tested by its own suites |

**DONE SINCE THIS RECORD WAS WRITTEN (corrections — the text above is kept as written):**
1. ~~Resume wiring~~ → `515fd14`. 2. ~~`make musl` blocked by the vendored dafsa~~ → **the C copy was
the wrong engine**; `80222c2` links the stack's own Zig `libdatalog` and deletes it (47 files) with
**zero source edits**. 3. ~~The tool server~~ → done. 4. Guest artifacts must be **stripped**. 5. The
LuaJIT capability bound is **enforced** (§5a). 6. `osier-share` is the first oracle (§7.1). 7. Egress is
a **type** (§7.1a). 8. The compiler may live **in the guest** (§5a).

**QUEUED:**
1. **B2 — the full loop in the guest.** B1's boot has **no control channel by design** (fx-init says so:
   "no control channel … no virtio control port — fxctl cannot connect in this guest"), so B2 must
   attach `qemu_ctrl.sh`'s `-chardev socket … -device virtio-serial-pci -device
   virtserialport,chardev=fxctl0,name=fxctl0`. Then: inspect → write a config → `fxctl activate` →
   reboot → verdict → `fxstore verify`.
2. **THE FIRST SELF-MODIFICATION TASK**: the agent writes an **MCP server in Osier**, activates it as a
   **service**, and the `osier-share` share moves **0% → non-zero** (§7.1c). Every piece exists.
3. **The Osier→Lua backend** (host-side) — and answer the check-only-typecheck question (§5a).
4. **The egress primitives**: the closed host-side catalog + the Dhall declaration extension (§7.1a).
5. **The `osier-share` measurement** itself — host-side, over the generation's relations, plus the
   declared-reach query.
6. **The v86 disk** (§7.4) — unchanged; the browser lane still needs a purpose-built i386 kernel.

## 10. Where the evidence lives

| what | where |
|---|---|
| this design's accumulated findings, corrections, and decisions | memory node `fixpoint-agent-selfmod-idea` (rev ≥45) |
| the resume unit | memory `handoff-fx-harness-resume-*`, bus `fx-harness-resume` |
| the tool-server unit | memory `handoff-fx-harness-tools-*`, bus `fx-harness-tools` |
| the harness + deviations from upstream | `/var/data/workspace/fixpoint-linux/fx-harness/README.md` |
| the guest image's real contents | `fx-demo/evidence/image-contents.txt` |
| the loop's rollback proof | `fx-init/tests/qemu_ctrl.sh` |
| fxstore's audit surface | `fxstore/zig/src/main.zig` usage; `provenance.zig` (verify's two passes) |
| LuaJIT's audit surface | `LuaJIT/src/lib_init.c` (`lj_lib_load[]`) |
