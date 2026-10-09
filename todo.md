# todo

Living list for **baliveau** — the self-modifying fixpoint-linux system. Design record:
[`docs/baliveau-self-plan.md`](docs/baliveau-self-plan.md). Plans, reviews and evidence live in the
agent memory store (node names are given per item).

Two repos are in play: **this one** (`fx-harness`) and **`../fx-init`** (PID 1, the boot/recovery lane).

---

## 0. Land what is already verified

- [ ] **Commit `fx-harness`.** Its working tree holds verified, reviewed work that is *not yet
      committed*: the B2 pin fix, the B2 evidence, the **observation loop** and its **fix round**
      (5 should-fix + 3 nice-to-have). Committing waits only on `REVIEW NEEDED = review` clearing
      (node `handoff-fx-harness-observe-review`; re-review `review-observe-fix`).
- [x] **`fx-init`** committed: `2feedf6` — the in-guest control fifo + the boot-recovery guardrail
      + their fix round. Clean-reviewed twice.

## 1. The oracle — the one thing that decides whether any of this is worth having

Everything below this line makes the substrate *observable, terminating and self-aware*. **Nothing
measures whether a change is BETTER.** The boot verdict certifies viability; `fxstore verify`
certifies coherence; neither says "improved".

- [ ] **Decide the sense of "amount" for the first oracle** (`osier-share`): **code share** vs
      **behaviour share** (§7.1). Code share is buildable now and fails visibly; behaviour share needs
      held-out machinery this repo does not have.
- [ ] **Build the `osier-share` measurement** — a host-side query over the *active generation's*
      provenance, NOT the source tree: `provides(pkg, store_dir)`, `install(target, origin, mode,
      genhash)`, `svc_bin`/`svc_argv`. Count only binaries the generation **actually runs**, and only
      as Osier if the **derivation's source tree** is Osier — that kills dead-code inflation and the
      wrapper loophole.
- [ ] **Prove the instrument discriminates**: a synthetic Osier-sourced component must move the
      number. A metric that reads 0 forever proves nothing.
- [ ] **Make it a tie-breaker, not an objective**: `boots ok` → `no drift` → *then* maximise.
- [ ] **Every oracle must be able to SEE capability changes.** A code-only oracle is blind to an
      agent quietly widening its own egress — and, per §7.1c, blind to *activity without progress*
      (the oscillator is the measured instance).

## 2. Measurements still owed

- [ ] **A recovery counter** (§7.2). The oscillator was invisible because nothing counts recoveries:
      every individual boot looks locally correct. Instrument it.
- [ ] **`.bootlog` growth**: unbounded, fully rescanned by `bootlog_last`/`bootlog_newest_ok_below` on
      every boot, and `fsync`'d per append. The guardrail bounds growth to real boots, so this is
      lower priority — but state the policy (rotate, cap, or index) rather than leaving it implicit.

## 3. Known defects, pre-existing, not hidden

- [ ] **`fxstore verify` reports 5 drifts on a STOCK system.** fx-init's `install` fact for a `/bin`
      link records the package **DIR** while its buildfile symlinks the **BINARY** (`activate.zig:616-621`,
      `:1372-1382`). The B2 test pins that class so it still discriminates — **and a pinned class can
      mask real drift** (that was the B2 review's first finding).
- [ ] **The prescribed fix is HALF-RIGHT.** Emitting `<hash>-<pkg>/<basename(from)>` repairs `verify`
      but **breaks `fxstore why`** (`provenance.zig:475` collects `provides_targets` by exact
      `origin == store_dir`, while `provides` emits `<hash>-<pkg>`, `activate.zig:1384-1393`). Needs a
      fix that satisfies both consumers.
- [ ] **The `+64` poll window sits on an UNBOUNDED service set.** `svc_name_cb` (`fx-init
      zig/src/init.zig:1085-1089`) grows `g_svc_cap` 16→32→64→128 with **no cap**, so a config with
      >64 services still silently starves the poll set — the exact class the new comment describes as
      closed. Pre-existing; the comment overclaims.
- [ ] **The `console_pin` is a text heuristic.** It asserts the agent service row is a console service
      and rejects a mutated non-console copy — but a config shape that passes the pin while shipping a
      NON-console agent re-creates the **roll-forward spiral** (§ below). Review priority #5 on
      `handoff-fx-harness-observe-review`.

## 4. Design items awaiting a decision

- [ ] **The runtime-record gap.** A direct exec of `/bin/fx-activate` writes **no `rt_effect("activate")`**,
      no runtime-DB update, no hot-apply. The agent's activation is recorded in the *store* but not in
      the *runtime record*. Accept "a cold activate, effective on next boot" — or record it? (Note the
      consequence: the *store* record and the agent's own checkpoint are then the only evidence, which
      is why the checkpoint is the causal link.)
- [ ] **Per-client reply fifos (fifo option (b))** — deferred, and the choice is **reversible** because
      it is additive (the request line gains a reply path). Chosen now: one request fifo + one reply
      fifo, **single-client by convention, not enforcement** (a second client's replies interleave).
- [ ] **Trial vs accepted GC roots** (§7.2) — re-scoped by the oscillator from a *retention* question
      to a *liveness* one: trials that are accepted-and-rolled-back are noise.
- [ ] **Is the image a cache or a blob?** (§7.5). Note the correction: `image.zig:40-57` measures
      fx-init's *image* pipeline; **fx-harness's own artifacts ARE byte-reproducible**, and the two
      shipped ones are path-independent. Static + stripped is what makes an artifact content-addressable.

## 5. The Osier lane (BLOCKED — the Lua backend is not ready)

- [ ] **The Osier→Lua backend** (§5a). Not ready. When it lands: the compiler (written in Osier,
      self-hosting) compiles to Lua ⇒ the compiler is **a Lua file** ⇒ LuaJIT runs it in-guest, and
      the guest holds the whole toolchain **as text** — no ELF, no zig, no AOT.
- [ ] **Answer the check-only question**: does Osier's pipeline have a non-emitting typecheck entry
      point? The typechecker exists; a check-only mode was not found. This decides whether an in-guest
      *checker* is possible.
- [ ] **THE LINE THAT MUST HOLD**: *the agent may have a compiler; it may not have the one that
      **grades** it.* Guest compiler = working tool; host frozen compiler = the grader.
- [ ] **THE FIRST SELF-MODIFICATION TASK**: the agent writes an **MCP server in Osier**, activates it
      as a **service**, and the `osier-share` numerator moves **0% → non-zero**. Every piece exists
      except the backend. This is the smallest change that demonstrates self-modification *with
      provenance*.
- [ ] **LuaJIT JIT on/off in the guest**: shipped ON and gated two-sidedly; the *compiler* and
      agent-authored MCP servers are the long-running workloads that justify it. Measure per lane.

## 6. Egress (§7.1a) — designed, not built

- [ ] **A closed, host-owned catalog of network PRIMITIVES** (`http.get`/`http.post` + allowed hosts,
      methods, size caps) that Dhall declarations may only **instantiate, never invent** — modelled on
      fxstore's `Action` union. Without it a "Dhall tool schema" is a signature with no implementation,
      or a generic escape hatch.
- [ ] **Read and publish as DIFFERENT TYPES** — exfiltration *is* a publish.
- [ ] **The extension of the existing Dhall schemas**: the runtime config already carries
      `mcp_servers` and a tool policy (`enabled_tools`/`disabled_tools` → `ToolPolicy`); the system
      config already declares a `Service` record. This extends both.
- [ ] **The broker over the chardev**, so `CONFIG_NET` stays unset and the audit is *declared reach
      (the generation's Dhall, queryable) vs observed reach (the host's one log)* — the difference is
      the finding.
- [ ] Residual, stated not solved: **prompt injection** is not fixed by typing. Visible and logged,
      not silently contained.

## 7. The v86 lane (the browser demo) — the HARDER lane

- [ ] **A purpose-built i386 kernel** with virtio-console *and* ATA: the lean demo kernel has
      `# CONFIG_PCI is not set`, and the pinned qemu kernel is **x86_64** while v86 cannot boot 64-bit.
      v86 also has **no virtio-blk** (only console/9p/net/balloon, though it does expose
      `virtio-console0-output-bytes`/`-input-bytes`).
- [ ] **`/dev/hda` in fx-init** alongside `/dev/vda`, plus harness device wiring in `drive.mjs`.
- [ ] **Determinism** (§7.3): v86's RTC is host-fed, device identity comes from
      `Math.random`/`getRandomValues`, and `Date.now()` appears in the network stack. Patch those three
      sites, or always enter from a hashed `restore_state` snapshot. The *agent* path can never be
      hermetic; only the *build* path can.

---

## House rules this session earned (each cost something real)

- **A bound or a comment that describes a protection must be checked for the range over which it
  actually holds, and its violation must be LOUD.** Four or five instances: the B2 drift "pin" that
  pinned a *class* not a *set*; the guardrail's oldest-256 scan that silently stopped protecting on
  exactly the long-flapping machine it exists for; the `version_exists` window that gates the walk;
  the `+64` poll window on an unbounded service set; the observation loop deciding `done` without the
  marker. The mechanism was right in the small and inert beyond a limit, silently.
- **Do not relay a subagent's claim about a property you have not checked.** The "fxctl is unusable
  in-guest, but inspection survives via fxstore" relay was half-wrong, and the check cost two greps.
- **Backticks inside a double-quoted shell string are command-substituted** — two instances, both
  silently eating content. Use a single-quoted heredoc.
- **`pkill -f` matches the whole command line**, including a lane's brief text — I killed a running
  lane with a pattern drawn from a filename quoted in its own "do not touch" clause. Run `pgrep -fa`
  first and read the result.
- **A detached process spawned inside a tool call dies when the call returns.** Use tracked background
  tasks; a zero-output "success" reads as one.
- **`del-obs` exits 0 and silently no-ops on a non-matching string**, and **`read` truncates
  observations for display** (431 of 900 bytes, measured) — get the full text from `query` via
  `obs(E,C) :- observation(E,C)`.
- **Memory writes need a retry** under concurrent lanes (the CLI reports a lock failure rather than
  waiting).
