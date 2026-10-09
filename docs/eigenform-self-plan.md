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

## 7. What is NOT designed

### 7.1 The oracle — first, and the one that decides whether this is worth building
Every remaining item below is a *build* problem with a working precedent. This is not. There is **no
design for what makes a change an improvement**: the boot verdict certifies *viability* (it booted,
it did not roll back), and `fxstore verify` certifies *coherence* (nothing drifted). Neither says a
change is better.

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

---

## 9. Build state and the queue

**GREEN (all orchestrator-verified on the committed tree):**
- `fx-harness` native build; the loop runs offline (§4).
- **Resume is wired** — `make test` 5 phases PASS, and the asymmetry is proven by mutation
  (`skip=0` → FAIL phase 3). Committed in `515fd14`.
- **The MCP tool server** — 10 verbs, 37-check smoke green, and its guest artifact is a real
  `ELF 32-bit LSB, Intel i386, statically linked` (§5).
- **The guest build of the HARNESS is green** — `make musl` produces a 1,686,488 B stripped i386
  static binary with zero `NEEDED`, and **that guest binary runs the offline arm on this host**
  (`hello`, rc=0). Committed in `80222c2`.
- Substrate (§2) built and tested by its own suites.

**DONE SINCE THIS RECORD WAS WRITTEN (corrections, appended — the record above is kept as written):**
1. ~~Resume wiring~~ → done, `515fd14`.
2. ~~`make musl` blocked by the vendored dafsa~~ → **the C copy was the wrong engine.** The sibling
   `datalog-dafsa` is the **Zig** engine and is what `fx-init`/`fxstore` already link; the C tree was
   only the copy `vibe-runtime` vendored, and the 64-byte assert exists *only* there. `80222c2`
   deletes it (47 files) and links the stack's engine: the sibling's `libdatalog.so` natively, and a
   **static `libdatalog.a` built on demand from the sibling's own `zig/build.zig`** for musl
   (`libdatalog.so` is incompatible with `elf_i386`). `DATALOG_DIR` fails loudly when the sibling is
   absent. **No source file needed editing** — the `dl.h` include is resolved by a
   `build/include` symlink shim. The tree no longer builds standalone; the sibling is required, as
   for the rest of the stack.
3. ~~The tool server~~ → done, 10 verbs, guest artifact builds (§5).
4. Guest artifacts must be built **stripped** — measured: the tool server is 2,406,552 B unstripped
   vs 325,336 B stripped (7.4×), against a 3,926,476 B total demo download.

**QUEUED:**
1. **Cross-build LuaJIT** (`HOST_CC="gcc -m32"`; the same pointer-size rule) and pin its stdlib to
   the `lj_lib_load` subset (§5).
2. **Wire the harness + tool server into the guest image**, and set the checkpoint's durable home
   (`VIBE_RUNTIME_DIR`) to the persistent disk — not the tmpfs root.
3. **The v86 disk** (§7.4): ATA in an i386 kernel + `/dev/hda` in `fx-init` + harness device wiring.
4. **The oracle** (§7.1) — design before building, because it shapes the loop.

**First end-to-end milestone:** a script that inspects the generation over the chardev, writes a
modified config, activates, reboots, reads the verdict, and runs `fxstore verify` — on **qemu**,
where every ingredient already works and no kernel work is needed.

---

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
