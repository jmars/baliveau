# Baliveau — self-plan

**A system that reconfigures itself, and is selected by whether it comes back up.**

The name is **silvicultural, and it is the design**. In a coppice, the underwood is cut on a rotation
and regrows from the stool every cycle — but the **baliveaux** are the young trees the woodsman
*deliberately leaves standing* through every cutting, so they grow into full standards while the wood
around them is taken and comes back. **The baliveau is the reserved generation: the thing you keep
while everything around it is cut and regrows.** It names the *persistence* rather than the process —
which is the thesis: provenance and rollback are properties of the substrate, not features granted to
the agent. (The user is in France and the audience is francophone, so the word costs nothing to
recall.)

**NAME CHANGED 2026-10-13, from `eigenform`.** Not for the usual reason: `eigenform` was *less*
crowded than `fixpoint` (18 GitHub repositories against 445, and free on PyPI where `fixpoint` is
taken) — a word being taken is normal here and already accepted. It was dropped because **one project
in the same field is actively developed**: `rdmontgomery/eigenform`, *"a local control surface over
Claude Code: context surgery on sessions (fork/rewind/edit/inject)…"*, Rust, pushed the day of the
decision, with a Homebrew tap. That is a *derivation* collision, not a namespace one, and it is the
only kind that matters here. The lesson, since it governs every future naming: **the bar is not "an
unused word" (unreachable — every ordinary word is on PyPI) but "no active project in the same
field."**

Availability of `baliveau` (CHECKED, 2026-10-13): **zero GitHub repositories**, and free on PyPI, npm
**and** crates.io; `fixpoint-linux/baliveau` free in the org. (French silvicultural vocabulary turns
out to dissolve the apt-but-taken vs free-but-opaque trade entirely, because that vocabulary is French
and English-language software does not use it. Rejected on collision: `heartwood` — also a
code-provenance project, `radicle-dev/heartwood`; `cambium` — 547★ occupant. Rejected on accents, since
a binary cannot carry them: `cépée`, the clump of shoots from one stool, which was semantically the
closest word of all. `éclaircie`, "thinning" — the operation that removes the weaker so the better
grow — survives unaccented and is a good name for the *selection* step, i.e. the oracle, rather than
for the project.)

**This is a NEW design.** The name `setpoint` is reused, and the VLHA-era design record
(that abandoned line's `architecture.md`: the substrate-heterogeneous triple network, the currency,
C1–C27) **is not this design** — that line did not work out. Nothing here should be read as
continuing it. This file is deliberately kept OUTSIDE that earlier tree so the two records cannot be
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

## 1a. A SECOND GOAL: observability sufficient for a third-party EU AI Act report (user, 2026-10-10)

> this system should provide enough observability for another tool to generate reports for the EU AI Act

**WHAT THE GOAL ASKS FOR, precisely, and what it does not.** It asks that the system RECORD ENOUGH, in a
form a separate tool can consume, for that tool to produce the reports. It does NOT ask baliveau to
write the reports, and it does not make anything compliant — **this section is an ENGINEERING READING of
a legal instrument, not legal advice, and the mapping would need counsel before anyone relied on it.**
Keeping the tool separate is the same move the project makes for the oracle: the thing that GRADES (or
here, DOCUMENTS) must not be authored by the thing being judged.

**THE OBLIGATIONS THAT ARE OBSERVABILITY-SHAPED** (INTERPRETATION, and the reason the goal is
tractable): Art. 12 + Art. 19 — automatic recording of events over the LIFETIME, including events
relevant to identifying situations that may present a risk or a **substantial modification**, and
retention of those logs; Art. 11 + Annex IV — technical documentation that includes the **changes made
through the lifecycle**; Art. 9/72/73 — risk management, post-market monitoring, **serious-incident
reporting**; Art. 14 — **human oversight** and the ability to intervene; Art. 17 — records of the
quality-management system. Every one of those is, in engineering terms, "an attributable, durable,
machine-readable record of what the system did, what changed, and who intervened."

**WHAT ALREADY EXISTS BY CONSTRUCTION, which is why this is a goal and not a rewrite.** The substrate
records, without being asked to:
  - **a generation IS a store path** with a snapshot version, `install`/`provides`/`src_of` facts, and a
    Dhakefile — content-addressed, so the system's states are enumerable and distinguishable;
  - **`.bootlog`** — a durable per-boot verdict history (ok / failed / in-progress / shutdown);
  - **`.recovery`** — a durable journal of AUTOMATIC roll-forwards, **which deliberately distinguishes
    them from deliberate operator rollbacks and ordinary boots** (a distinction the Act's "who
    intervened" question needs and that most systems do not make);
  - **the runtime datalog** — `rt_effect`/`rt_control` record activations, rollbacks and shutdowns;
  - **the oracle** — a per-generation, HOST-side measurement that a change is an improvement;
  - **`fx-audit`** — machine-readable findings about the integrity of the record itself.
So the observability is largely a matter of SURFACING what the substrate already holds, and the
reporter is the third member of a family with the same three properties (`§7.1`): **host-side,
agent-unwritable, a function of observable system state — it READS the substrate, it does not become a
source of truth.**

**AND THE TWO GOALS REINFORCE EACH OTHER, which is not a coincidence.** A log the subject can rewrite is
not a log for a regulator. `§6b`'s stance (audit, not proof; the VM is the boundary; the host observes
what the guest cannot change) is exactly what makes these records EVIDENTIALLY USABLE rather than merely
present — the nonce-bound `.bootlog`, the host's previous-observation comparison, and the rule that
**the harness's own `attempts.jsonl` is a self-report and never evidence** were built to stop an agent
cheating its own guardrail; they are also what a third party would need in order to believe the record.

**THE GAPS — the honest list, and the first is already carried in this record.** MEASURED unless noted:
  1. **A generation cannot answer "which config produced me"** (§8.3): `generation(genhash, buildfile,
     dhake, epoch)` and `genhash` is the canonical serialization of the FACTS, so the config's store
     path is not a term. For "the changes made through the lifecycle" this is the direct gap: the chain
     of generations exists, but the *input* of each step is not recorded with it.
  2. **No change record as such.** The generation chain IS the substrate's change record, but nothing
     states a change's INTENT or SEMANTICS (what was attempted and why) — only the resulting state.
  3. **No risk/incident classification.** A failed boot, a refused activation, a rolled-back
     generation and an audit incoherence are all candidate "situations that may present a risk" or
     "substantial modifications"; nothing classifies them as such or links them to an affected
     generation. (The raw events are recorded; the taxonomy is not.)
  4. **Retention is unpoliced.** `.bootlog` / `.recovery` / `src_of` growth has no stated policy (§2),
     and the RUNTIME log (`log.db`) lives under `/run/fx` — tmpfs, so it does not survive a reboot,
     while the store's own files do. Art. 19's retention question therefore has a real answer for some
     records and none for others, and that difference must be stated rather than assumed.
  5. **Nothing distinguishes a record's READER from its WRITER** at the reporting boundary yet: the
     reporter must be host-side for the same reason the oracle is, and that has to be a property of its
     seat, not a convention.

**WHAT THIS CHANGES ABOUT THE ROADMAP.** It adds no new subsystem — it promotes existing records to
LOAD-BEARING and adds three small things: the config→generation link (gap 1), a change/incident record
with a stated taxonomy (gaps 2-3), and a retention policy (gap 4). It also makes one existing rule
non-negotiable rather than merely prudent: **the reportable record must be the substrate's, never the
agent's self-report.**

---

## 2. What already exists (the substrate)

Sibling checkouts — separate repositories in the same workspace: `{fx-init,fxstore,fx-core,dhake,dhall-c,datalog-dafsa}`.

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

This tree (`src/agent/`) — a reduced port of the host-side agent runtime, cut to what the
guest can run.

**MEASURED — it builds and the loop runs end-to-end offline:**
```
$ FX_CHARDEV=<recorded SSE stream> FX_AGENT_CONFIG_DIR=$PWD/config \
    ./build/fx-agent -p "say hi" --agent fx --max-turns 1 --output text
hello                        # rc=0; 21 SSE events; 7,523 bytes read to EOF
$ cat ~/.local/share/fx-agent/runs/<id>/messages.jsonl
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

## 6a. AMENDMENT (2026-10-10, user decision) — the recipe IS admitted, as a composition over a fixed vocabulary

The conclusion above is right about an **unrestricted** recipe and wrong as a *boundary*. The user
moved it, in two steps:

> the agent is running in a generation, adds some lua files and updates the dhall config -> commits
> those changes to a new generation -> activates that generation (causing a reboot into it)

> theres no need for arbitrary shell in the recipes no? … that point is a perfect lever to control
> capabilities if we make it a fixed set of actions we control

So: **the agent MAY declare packages, a package carries a recipe, and the recipe is a composition
over a HOST-FROZEN Action subset — the subset IS the capability.** This is the build-time twin of the
runtime rule settled twice already (`648984f`: the write surface is a closed host-declared set;
`500fc68`: the agent service is named by a REQUIRED config field). Inside the machine the vocabulary
is a **fact**, and the substrate **REFUSES** rather than documents.

**WHY THE BOUNDARY MOVES, and what the old argument got right.** §6's reason — "a recipe is code the
host runs" — is an argument about an *unbounded* recipe: an unrestricted `Shell` genuinely is a
host-execution grant with nothing behind it. But **our use case needs no shell at all**: the
Osier→Lua compile step is a pinned argv —

    Run { argv = [ "/usr/fx-agent/bin/luajit", "/usr/fx-agent/bin/osier-lua.lua",
                   "<src>/Mcp.elm", "-o", "mcp.lua" ] }

— so the restriction costs the first task nothing, and the boundary can be drawn at the vocabulary
instead of at the agent.

**A. THE VOCABULARY LEVER.** MEASURED, the union is eleven actions (`m3/package-set.dhall:42-54`):
`Shell | Copy | Mkdir | Rm | Touch | Move | Symlink | Chmod | Echo | Env | Run`. `Shell` is
implemented as `shell_bin() -c <text>` (`fxstore zig/src/build.zig:810-813`) — **one action that
dissolves every other bound**, and it is excluded from the agent-authorable subset. Host-frozen sets
keep it (the m3 sets use it for real `cosmocc` / `cp -a` recipes); the split is the same one the
runtime table already makes: the vocabulary is a fact for the agent, and the host's own recipes are
trusted.

**B. `Run` MUST BE ABSOLUTE-ARGV.** MEASURED: `.run` → `run_sandboxed(…, a.argv)` →
`execvp(argv[0], argv)` (`build.zig:926-931`, `:728`), so `Run` is PATH-RESOLVED — and recipes
control the environment (`.env` does `setenv` in the build process, `:917-925`; the child prepends to
`PATH`). `Run` is therefore the remaining exec lever: it can name a binary the agent supplied. **The
code already applies exactly this discipline to itself** — "execvp('bwrap') searches the CURRENT
PATH, which recipes control. The child execs this ABSOLUTE path (no PATH search)" (`:351-354`). Apply
it to `Run`: **absolute `argv[0]`, no PATH search** — then a recipe can only name binaries that
already exist.

**C. THE REACH BOUND — CORRECTED 2026-10-10, the user is right and my first version was wrong.**
I wrote that the fix was to route the `bwrap`-absent fallback "so it still goes through
stage3/landlock". MEASURED against the PINNED GUEST KERNEL (`fx-init/.kernel-cache/kernel/config`),
that is not available and never could be:

    # CONFIG_SECURITY is not set        -> no LSM framework => NO LANDLOCK
    # CONFIG_SECCOMP is not set         -> and palisade's `n` (its syscall whitelist, stage3.c) is
                                          cosmocc pledge, i.e. seccomp
    # CONFIG_NAMESPACES is not set      -> bwrap is MADE of namespaces, so bwrap cannot exist in the
                                          guest at all: not "unstaged", not "would need porting"

So **stage3's two enforcement halves are both unavailable in the guest, and no kernel sandbox
primitive of any kind exists there.** (Note `CONFIG_LSM="landlock,lockdown,yama,…"` at `:1784` — the
default ORDERING string, inert with `CONFIG_SECURITY` off: a config line that LOOKS like a capability
and is not. The project's most repeated pattern, now found in the kernel config itself.)

**Requiring bwrap/palisade in the guest was the wrong layer, and the user's framing is the right one:
THE VM IS THE BOUNDARY.** The guest is where containment starts — §2 already says it ("the guest is
already the containment story"): the vocabulary there is a *fact* because the binaries do not exist,
not because anything enforces it. What I conflated with "the agent escaping" was never escape; it was
**the agent reaching its own guardrail's state through a door we had not counted** — the same class as
the hole `648984f` closed. That is a much narrower concern, and it does not need a sandbox.

**WHAT (C) BECOMES.** The actions are OURS — we define the vocabulary and we implement each action —
so the bound belongs in `fxstore`'s action runner, IN USERSPACE: a `Copy`/`Rm`/`Mkdir`/`Symlink`/…
is refused when its path is outside the build's own workdir and the path it is installing. That costs
a path check per action, needs no kernel feature, and is the SAME lever as the vocabulary: we define
the action, so we define what it may touch.

**THE LAYERS, stated honestly, because expecting a sandbox that cannot exist is how a bound becomes
decorative:**
  1. **the VM** — everything the agent does happens inside it; that is where containment starts and
     where it ends. Nothing in-guest can reach the host.
  2. **the userspace action bound** — a recipe's writes confined to its build workdir + output.
  3. **the substrate's own guardrail** — fx-init's hold-at-current backstop if a cycle does start.
  4. **the oracle, which is HOST-side** — so no amount of in-guest tampering reaches the thing that
     grades the work.
**AND THE RESIDUAL, stated rather than implied:** the harness's record (`attempts.jsonl`) is a
SELF-REPORT living inside the guest, and with no kernel bound a recipe can reach it. The damage is
bounded — it lets the agent mislead its OWN loop (wasting cycles toward the oscillator) and NOT the
substrate, whose boot verdict and roll-forward belong to fx-init, nor the oracle, which is host-side.
If the loop's guarantee must hold against a MALICIOUS recipe rather than a cooperative agent, the
answer is to make the record **tamper-EVIDENT** (content-addressed or hash-chained) rather than
tamper-proof: a fact rather than a policy, which is the same conclusion this record keeps reaching.


**D. THE REFUSAL IS AT ACTIVATION, AND IT IS LOUD.** An out-of-subset action must be **refused by
name** where the config is validated — the `agentService` pattern (`500fc68`), same place, same
loudness. "The vocabulary is a fact" means the substrate rejects it; this project has already paid
twice for a bound that was right in the small and inert beyond a limit.

**E. PACKAGES LIVE IN THE CONFIG — the agent's EXISTING write surface, not a widened one.**
`fx-activate` merges the config's inline packages into the package set *before* computing the
closure, so no new file becomes agent-writable and no bridge is created. **Why packages and not
files:** MEASURED, the config can ALREADY ship arbitrary file content — `extraEtc : List {path,
content}` → `/etc/<path>` (`activate.zig:1358-1367`) — so "add some lua files" is expressible today.
But such a file has **no `provides` and no `src_of`**, so it is not a *component* of the generation
and the oracle cannot attribute it. A **package** gets a source artifact, and `src_of` binds it to
the generation — that is what makes the agent's work *provable*, which is the entire point of the
first task. The pre-declared SLOT (`fx-init e825d52`) is the degenerate case of this: one package
whose `src` is agent-writable and whose recipe is frozen. It stays as the proven ground.

**CONSEQUENCES, and two facts the agent's route currently hides.**

- **NO bridge between the two timelines is needed.** `fx-core`'s `concept.md` is explicit that the
  FS-mutation log and the store's generation timeline "must not be conflated"; root-diffing would
  have required a bridge, and inline packages need none — the config is already the unit a generation
  is derived from. That is why this shape is right and the general one is not.
- **THE COMMIT EXISTS, AND THE AGENT IS ON THE WRONG SIDE OF IT.** MEASURED (`fx-init
  zig/src/init.zig:3218-3395`): PID 1's `activate` forks `fx-activate` (config → closure →
  per-generation Dhakefile → generation facts → snapshot → CURRENT), re-reads the store's facts,
  re-arms the boot decision, then **`run_dhake()` MATERIALIZES the new generation onto the RUNNING
  root** — the hot-apply — and records `rt_effect("activate")`. A direct exec of `/bin/fx-activate`
  reaches **step 1 only**: no commit, no re-arm, no service restart, no runtime record. The harness
  routes the agent that way on the strength of a half-wrong finding this project already flagged
  ("the 'fxctl is unusable in-guest' relay was half-wrong"): `fxctl` is a **pure client** (imports
  only `std`, opens no store or DB) and it has a **fifo transport added as the in-guest transport**
  (`fxctl.zig:45-53`) over `/run/fx/control.in` + `control.out`. The DB lock that made the relay
  plausible belongs to `fxstore`, which does open the store DB — a property of a neighbour, applied
  to the object.
- **NO IN-GUEST REBOOT.** The control protocol carries `status | log | activate | rollback |
  shutdown` and **no reboot** (`init.zig:3098-3228`), and the guest tests pass qemu `-no-reboot`
  (`qemu-agent-observe.sh:648`) with the HOST restarting the VM. So "activate ... (causing a reboot
  into it)" needs a reboot the machine can perform on its own; today the change becomes live by
  hot-apply and takes effect at boot only because the next boot reads CURRENT.

**STATUS: DESIGNED, NOT BUILT.** The five elements above, in dependency order: **(C) the userspace
reach bound in `fxstore`'s action runner** — *not* a sandbox, which cannot exist in this kernel — then
(D) the activation-time refusal, then (A)+(B) the subset and the absolute-argv rule, then (E) the
config's inline packages and the merge in `fx-activate`. The rebuild of `fxstore` for the guest
(static, musl, against a static libdatalog) is a prerequisite of any of it, because the builder must
be able to run where the agent does — **and that prerequisite is now DONE** (`fx-harness 3b7dacc` +
`fxstore 23a293f`: the loop runs in-guest, one image and one disk, run-set share 0.000000 → 0.100376).

**CORRECTION (appended 2026-10-13, MEASURED from the source, not from the text above): THE STATUS
PARAGRAPH IS STALE — ELEMENTS (A), (B), (D) AND (E) ARE BUILT.** `fx-init 4c5803d` landed
`inlinePackages` as a real config field and the four activation-time refusals, refused BY NAME:
`Shell` (`zig/src/config.zig:965-966`, *"one action that dissolves every other bound"*), a relative
`Run` argv[0] (`:980`, `execvp` with a recipe-controlled PATH), `Fetch` as a src, and non-empty
`deps` — gated by corpus fixtures (`zig/corpus/inline-good.dhall`, `inline-reject-shell.dhall`,
`inline-reject-fetch.dhall`, `activate/inline-closure|collide|inert.dhall`) and a zig test at
`config.zig:1437`. The config's packages are merged by `fx-activate` (`activate.zig:1930`), so (E)'s
"no new file becomes agent-writable" holds as designed. **What actually remains is element (C) ONLY**
— the userspace reach bound in `fxstore`'s action runner (`zig/src/build.zig:167-174`: `resolve_path`
concatenates and refuses nothing outside the workdir + install target) — and §6b downgraded it to
optional defence-in-depth, so the paragraph's stated build ORDER is no longer the live queue. The one
place it still bites is the in-guest build path, which falls back to PLAIN EXEC in the workdir
(`build.zig:700-760`, the sanctioned LOUD bwrap-absent fallback): an agent-authored recipe's `Copy`
can therefore reach the harness's own record (`/fx/disk/agent-data/attempts.jsonl`). That is bounded,
not closed, and the bound is the one §6b already states — the record is a SELF-REPORT and never
evidence, the substrate's guardrail is fx-init's, and the host-side seats are unreachable from
in-guest. Two other §6a-adjacent items stay open and are DECISIONS as much as builds: there is **no
in-guest reboot**, and the agent's direct-exec activation writes **no `rt_effect`** (the runtime-record
gap).


---

## 6b. The stance: AUDITING, NOT PROOFING (user decision, 2026-10-10)

> auditing, not proofing, let it try to cheat, but we should be able to see it and stop it -> rollback

This settles how §6a's elements are weighted, and it demotes the one I had made load-bearing.

**WHY IT FITS THE THESIS.** A bound built by *preventing* a write is a POLICY — something we grant or
withhold, and something whose violation we can only hope we enumerated. Provenance and rollback are
supposed to be properties of the SUBSTRATE, not permissions granted to the agent. So the agent is
allowed to try, the attempt is made VISIBLE, and the response is a ROLLBACK. That is the same move the
project makes everywhere else: the oracle is not a rule the agent follows, it is a seat the agent
cannot write; the boot verdict is not the agent's self-assessment, it is fx-init's.

**CONSEQUENCE FOR §6a.** Element **(C) is DOWNGRADED from load-bearing to optional defence-in-depth.**
The load-bearing pair becomes the **DETECTOR** and the **ROLLBACK TRIGGER** — because with no kernel
sandbox primitive in the guest (§8.14) and the VM as the boundary, *nothing in-guest can be proofed
against the agent anyway*. What can be done is to make what it does leave a mark, and to act on the
mark. (B) — the absolute-argv rule — and (D) — the activation-time refusal — stay: they are cheap,
they are the SAME lever as the vocabulary, and they remove whole classes of accident rather than
adversaries.

**WHAT THE AUDIT READS — and WHY THE RECORDS ARE INDEPENDENT.** The detector is not one file: it is
several records written by DIFFERENT WRITERS AT DIFFERENT TIMES, which is what makes incoherence
detectable without a sandbox. One doctored file cannot make them agree:

| record | written by | what it says |
|---|---|---|
| `<store>/.bootlog` | fx-init, per boot | the verdict of each generation that booted |
| `<store>/.recovery` | fx-init, per automatic roll-forward | that a generation was republished, and from which |
| `install` / `provides` / `src_of` / `store` facts | fx-activate, in the activation txn | what this generation installed, from where |
| `<store>/.db/snapshots/CURRENT` | fxstore | which generation is current |
| `fxstore verify` | fxstore, on demand | the rootfs against the facts — **exit 1 on drift** |
| the oracle | the HOST | whether the change is an improvement |

**THE HARNESS'S OWN `attempts.jsonl` IS A SELF-REPORT AND IS NEVER EVIDENCE.** The observation loop
may keep using it — it is the agent's efficiency layer, and it stops the agent wasting cycles on
something it already learned — but the SUBSTRATE's stop-and-roll-back must never depend on it. That
property already holds and is worth stating so it is not lost: fx-init's roll-forward reads
`.bootlog`, its guardrail reads the store's facts, and neither consults the harness's record.

**WHAT INCOHERENCE LOOKS LIKE** (each of these is a detector, and each reads two independent
records): a `.recovery` row with no matching `failed` in `.bootlog`; a rootfs file with no `install`
fact (`verify`'s drift); a generation whose facts name a store path that is not there; a version
chain that does not line up; an activation whose `src_of` binds a source hash whose artifact is gone.

**THE RESPONSE EXISTS; THE TRIGGER IS WHAT IS MISSING.** Rollback is built and proven — `fxstore
rollback [--hard] <v>`, the boot-failure roll-forward, and fx-init's hold-at-current backstop
(`2feedf6`). What does not exist is something that reads an incoherence and ACTS on it.

**WHERE THE DETECTOR MUST LIVE, and this is the load-bearing design point: HOST-SIDE.** The agent can
write any file in the guest, so an in-guest auditor is auditing a witness the suspect can edit —
cross-checks catch an INCOHERENT tamper, not a coherent one. The host is the one writer the agent
cannot reach, and it already reads the disk at every generation (that is how every gate in this repo
takes its evidence). So the audit belongs beside the oracle, on the same seat and the same principle:
**the host compares what it sees now against what it saw last**, and a generation that rewrote its own
history is visible as a DISAGREEMENT WITH THE PREVIOUS OBSERVATION — which no amount of coherent
in-guest rewriting can undo, because the previous observation is not on the disk.
**AND THE RESIDUAL, stated plainly:** an in-guest cross-check is defeated by a coherent tamper, and
this design does not claim otherwise. That is the honest bound of "auditing, not proofing", and it is
why the auditor is host-side rather than a second file inside the machine.

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

**BUILT (2026-10-13, orchestrator-verified): THE ORDER IS EXECUTED, NOT DESCRIBED — `fx-select`.** The
paragraph above was prose with nothing enforcing it: MEASURED this session, `fx-osier-share` was
invoked by TESTS ONLY (`tests/test_osier_share.sh`, the two slot gates) — no loop and no seat consumed
its number, which is this project's own named defect (*a seat that is never called is
indistinguishable from an absent seat*) applied to its most load-bearing seat. `tools/fx-select.c` is
a fourth host-side seat that computes the order over a store's published versions and can ACT on it:
**viability** from `<store>/.bootlog` (the LAST non-`shutdown` line naming the version; `failed`,
`in-progress`, `damaged`, `never-judged`, and a torn tail naming it, are each NOT viable and NAMED) →
**coherence** via `fxstore verify`, judged for CURRENT ONLY — every other candidate prints `not-live`
WITH its reason and is NOT disqualified, because the live rootfs corresponds to exactly one generation
and the seat refuses to claim a verification it did not run → *then* the **share**, the oracle's own
`run_set_share_fraction` shelled by subprocess (never re-derived; a candidate the oracle refuses is
EXCLUDED BY NAME, never counted as 0 %). Frozen TSV records with a `#` summary beside them, the
eight-step order and its bounds printed on every run, byte-deterministic. Decision `keep` | `revert-to`
| a named refusal; `--apply` drives the EXISTING **soft** `fxstore rollback` (the content returns and
the VERSION NUMBER GOES UP — the substrate's own roll-forward semantics, which keeps the timeline
append-only), and refuses with no mutation whenever the decision is not actionable (exit 3 = WITHHOLD,
ONE predicate shared by the record and the trigger). Gate `make test-select`: 22 arms, three
sed-mutants each shown blind on exactly its fixture (viability filter, coherence filter, tie clause).

**THE CANDIDATE SET IS BOUNDED, AND THAT IS THE DESIGN DECISION THIS SECTION OWES.** The seat
maximises over `{CURRENT} ∪ {the NEWEST published version below CURRENT whose `generation` fact
genhash differs}`, tie → CURRENT. Unbounded — over every version the store has ever published — the
third term stops being a tie-breaker and becomes a **global objective**: any strictly-lower-share
change is reverted forever (a non-Osier task could never be *kept*, which makes every task but this
one impossible), and each revert republishes the attractor at a higher version (MEASURED: 7 → 9), so
the store grows while the system oscillates between two states. That is precisely what "a tie-breaker,
not an objective" forbids, and "is the change worth keeping?" is a question about the change just made
against the generation it replaced. The bound also settles a measured property of the substrate: an
activation or a rollback publishes TWO snapshots, and the INTERMEDIATE one carries its PREDECESSOR's
system facts (`install`/`generation`/`svc_bin`/`svc_argv`/`provides` md5-identical) with a higher
version number — so an unbounded "greatest share, then highest version" rule prefers a HALF-PUBLISHED
snapshot. The bound makes it `not-candidate`, with its reason printed.

**AND ONE MEASURED HAZARD WORTH KEEPING, FOUND WHILE FIXING IT:** `--apply` rolled CURRENT 7 → 9, and
the very next run reverted back to 7 — **the seat undid its own rollback**, because a freshly
republished incumbent has no boot verdict yet and read as "not viable". It is now `current-not-judged`,
a withhold state (exit 3) alongside `current-unmeasured` and `current-verdict-unknown`, gated by arms
S8c/S8d. The general form, which outlives this seat: **an instrument that can undo its own action has
no settled point** — and a boot verdict arrives one boot LATER than the state it judges.

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
14. **"THE IN-GUEST BUILD NEEDS A SANDBOX" WAS THE WRONG LAYER — the VM is the boundary.** I wrote
    (§6a-C, first version) that the fix was to route the recipe's exec through stage3/landlock. The
    PINNED GUEST KERNEL has `# CONFIG_SECURITY is not set` (no LSM ⇒ **no landlock**),
    `# CONFIG_SECCOMP is not set` (and palisade's `n` IS seccomp, via cosmocc pledge), and
    `# CONFIG_NAMESPACES is not set` (**bwrap is made of namespaces**, so bwrap cannot exist there at
    all — not unstaged, not portable: impossible). So **no kernel sandbox primitive of any kind exists
    in the guest**, stage3's two enforcement halves are both unavailable to it, and the `stage3` the
    in-guest gate proves *executes* only proves its bare-usage path. **MEASURED.** And a config line
    that LOOKS like the capability is present: `CONFIG_LSM="landlock,lockdown,yama,…"` is the default
    ORDERING string and is inert with `CONFIG_SECURITY` off — the project's most repeated pattern,
    this time inside the kernel config. What replaces it is a USERSPACE bound in `fxstore`'s action
    runner (the actions are ours), with the residual stated: the harness's `attempts.jsonl` is a
    SELF-REPORT, so the answer for a malicious recipe is to make it tamper-EVIDENT rather than
    tamper-proof.

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
a **type** (§7.1a). 8. The compiler may live **in the guest** (§5a). 9. **THE ORDER IS EXECUTED, not
described** — `fx-select` computes §7.1's lexicographic order over a store's versions and can act on it
(§7.1; gate `make test-select`, 22 arms). 10. **THE GATES THAT SKIPPED NOW RUN** — the tree moved out
of the fx stack's workspace and every gate still resolved its siblings as `$REPO/..`, so they SKIPped
(or died at the Makefile's `DATALOG_DIR $(error)`) on a path that could never be right again; one
resolution policy now covers 14 sites in 11 files plus the Makefile's default, and
`test-osier-share` / `test-report` / `test-audit` / `test-sibling-paths` are all **0 with no env
override** (`8d7d8b9`, MEASURED by the orchestrator).

**QUEUED:**
1. **B2 — the full loop in the guest.** B1's boot has **no control channel by design** (fx-init says so:
   "no control channel … no virtio control port — fxctl cannot connect in this guest"), so B2 must
   attach `qemu_ctrl.sh`'s `-chardev socket … -device virtio-serial-pci -device
   virtserialport,chardev=fxctl0,name=fxctl0`. Then: inspect → write a config → `fxctl activate` →
   reboot → verdict → `fxstore verify`.
2. **THE FIRST SELF-MODIFICATION TASK**: the agent writes an **MCP server in Osier**, activates it as a
   **service**, and the `osier-share` share moves **0% → non-zero** (§7.1c). Every piece exists.
   **AMENDED 2026-10-10 (§6a):** the change is carried by the **store**, not by building an image —
   the agent is already inside the machine, so the loop is *make changes → apply → activate a new
   generation*, with the agent declaring PACKAGES in its config and composing recipes from a
   host-frozen Action subset (no `Shell`, absolute-argv `Run`, reach enforced in-guest). Two gaps sit
   between here and it: the agent's activation currently **bypasses PID 1's commit** (`run_dhake`'s
   hot-apply) because it direct-execs `fx-activate` instead of using the control channel, and there
   is **no in-guest reboot**. The pre-declared slot (`fx-init e825d52`) is the degenerate case of the
   inline-package form and stays as the proven ground.
   **UPDATED 2026-10-13: the first gap is CLOSED** (`fx-harness 2818813` + `fx-init f3f60fd` — the
   agent's activation now speaks PID 1's fifo line protocol natively, so the change is COMMITTED and
   hot-applied, and the service-table exemption stops the duplicate agent instance it exposed). The
   blocking item is no longer in this record: it is **the Osier→Lua backend (item 3 below)**, which is
   LATER in the OSIER repo's own sequence (its `plan.md` Phase 5, behind S5 monomorphisation, then
   positional records and a fresh non-moving collector) — so "every piece exists" above is true of
   everything EXCEPT the language backend, and nothing in THIS repo unblocks it.
3. **The Osier→Lua backend** (host-side) — and answer the check-only-typecheck question (§5a).
4. **The egress primitives**: the closed host-side catalog + the Dhall declaration extension (§7.1a).
5. ~~**The `osier-share` measurement** itself — host-side, over the generation's relations~~ → **DONE**
   (`tools/fx-osier-share.c`; gate `make test-osier-share`, exit 0 with no env override as of
   `8d7d8b9`; the closed host-owned catalog + a Dhall declaration extension, i.e. the DECLARED-REACH
   query, remain open under item 4).
6. **The v86 disk** (§7.4) — unchanged; the browser lane still needs a purpose-built i386 kernel.

## 10. Where the evidence lives

| what | where |
|---|---|
| this design's accumulated findings, corrections, and decisions | the design's own agent-memory record (rev ≥45) |
| the resume unit | the resume unit's own design record and live work channel |
| the tool-server unit | the tool-server unit's own design record and live work channel |
| the harness + deviations from upstream | this tree's `README.md` |
| the guest image's real contents | `fx-demo/evidence/image-contents.txt` |
| the loop's rollback proof | `fx-init/tests/qemu_ctrl.sh` |
| fxstore's audit surface | `fxstore/zig/src/main.zig` usage; `provenance.zig` (verify's two passes) |
| LuaJIT's audit surface | `LuaJIT/src/lib_init.c` (`lj_lib_load[]`) |
