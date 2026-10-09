# todo

Living list for **baliveau** — the self-modifying fixpoint-linux system. Design record:
[`docs/baliveau-self-plan.md`](docs/baliveau-self-plan.md). Plans, reviews and evidence live in the
agent memory store (node names are given per item).

Two repos are in play: **this one** (`fx-harness`) and **`../fx-init`** (PID 1, the boot/recovery lane).

---

## 0. Land what is already verified

- [x] **`fx-harness` committed**: `7de7433` (the observation loop + the B2 pin fix + evidence),
      `648984f` (the write-surface fix — see §4), `e3eb984` (the first oracle — §1).
- [x] **`fxstore` committed**: `c79af4b` — `fxstore facts <relation> [--as-of N]`, the read-only,
      version-bound relation dump the oracle needed. `zig build test` exit 0, mutation-checked.
- [x] **`fx-init`** committed: `2feedf6` — the in-guest control fifo + the boot-recovery guardrail
      + their fix round. Clean-reviewed twice.
- [ ] **Two reviews in flight** (read-only, dispatched after the commits): `review-osier-share`
      (the oracle + its fxstore seat; the number will GRADE an agent, so silent wrongness is the
      risk) and `review-writesurface` (648984f; a bypass of the closed write set is a blocker, not
      a nit). Result nodes `handoff-osier-share-review`, `handoff-writesurface-review`.

## 1. The oracle — the one thing that decides whether any of this is worth having

Everything below this line makes the substrate *observable, terminating and self-aware*. **Nothing
measures whether a change is BETTER.** The boot verdict certifies viability; `fxstore verify`
certifies coherence; neither says "improved".

- [x] **Decide the sense of "amount" for the first oracle** (`osier-share`): **code share** —
      the fraction of the SOURCE BYTES of the components the generation RUNS that are Osier
      (`.elm`). Code share is buildable now and fails visibly; behaviour share needs held-out
      machinery this repo does not have. The oracle PRINTS its extension set on every run.
- [x] **Built the `osier-share` measurement** — `tools/fx-osier-share.c`, a host-side query over
      the *active generation's* provenance, NOT the source tree: `svc_bin` picks the components
      the generation RUNS, `provides` turns each into its store dir, `srcstore` binds it to the
      source content hash, and the source comes from the store's own content-addressed artifact
      `<store>/<src_hash>-<name>-src`. A host tree is accepted ONLY if the C port of
      `fx_content_hash_dir` reproduces `srcstore`'s hash — an unverified tree is REFUSED. The run
      set is the OBJECTIVE and the closure is printed BESIDE it, never averaged into it, which
      kills both dead-code inflation and the wrapper loophole.
- [x] **Proved the instrument discriminates**: `make test-osier-share` exit 0 — A1 the number
      MOVES 0.000000 → 1.000000 when an Osier-sourced RUN component is added; A2 a built-but-NOT-run
      component leaves the run share EXACTLY invariant while the closure moves 0.359237 → 0.499734;
      A3 a RUN component with non-Osier source leaves the numerator invariant and the share strictly
      lower (1.000000 → 0.582965). Refusals fire instead of returning 0 (empty store, bad `--as-of`,
      mutated host tree). **Asymmetry**: against the pre-fix fxstore the seat does not exist and the
      oracle refuses to measure at all.
- [ ] **Make it a tie-breaker, not an objective**: `boots ok` → `no drift` → *then* maximise.
      Nothing yet enforces that order — today the number is reported, not gated.
- [ ] **Every oracle must be able to SEE capability changes.** A code-only oracle is blind to an
      agent quietly widening its own egress — and, per §7.1c, blind to *activity without progress*
      (the oscillator is the measured instance). `osier-share` is a static property of the store and
      does NOT see either: it is the per-task oracle, and the capability/activity seats are separate
      and still owed.

## 2. Measurements still owed

- [ ] **A recovery counter** (§7.2). The oscillator was invisible because nothing counts recoveries:
      every individual boot looks locally correct. Instrument it.
- [ ] **`.bootlog` growth**: unbounded, fully rescanned by `bootlog_last`/`bootlog_newest_ok_below` on
      every boot, and `fsync`'d per append. The guardrail bounds growth to real boots, so this is
      lower priority — but state the policy (rotate, cap, or index) rather than leaving it implicit.

## 3. Known defects, pre-existing, not hidden

- [ ] **The store cannot attribute a src_hash to a generation** (found by the osier-share review,
      worked around — not fixed — this round). `srcstore` is append-only and its rows are reaped only
      when the NAME becomes unreachable, while `provides`/`install`/`svc_*` are cleared per
      activation — so a package whose source changed and was re-activated has **several live srcstore
      rows for one name in the CURRENT snapshot**, and `fxstore facts` prints them in a
      **non-contractual** order. Nothing links a derivation hash to the src hash it was folded from,
      so no reader (the oracle included) can tell which source the running generation was built from.
      `fx-osier-share` now REFUSES when more than one candidate survives its narrowing checks
      (`tests/test_osier_share.sh` A4 pins it), but the honest fix is a **fact binding derivation
      hash → src hash, committed by the activation in fx-init** (`commitClosureMeta`,
      `activate.zig:890-915`) — fx-init's repo, not this one.
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
- [ ] **`fx_read`/`fx_ls` still resolve arbitrary paths under `FX_VERB_ROOT`** — including a `..` that
      climbs *above* a stub root, because `root_join` concatenates strings rather than resolving.
      Pre-existing, read-only, reported by the 648984f lane and NOT silently fixed there. Adjacent to
      the closed write set, so it must not be mistaken for closed: the write bound is a *write* bound.
- [ ] **`tests/qemu-agent-b2.sh:~602` carries the comment-blind substring `console_pin`** that
      `tests/qemu-agent-observe.sh` had fixed (a `console = Some "console"` inside a COMMENT passes a
      non-console row). Same one-line `strip_comments` fix; out of the 648984f lane's scope.

## 4. Design items awaiting a decision

- [x] **The write surface is now a CLOSED, HOST-DECLARED set** (`648984f`). It *was* an unstated
      assumption: the loop's guardrail rested on the record being beyond the agent's reach, and
      `fx_write` could truncate ANY path under `FX_VERB_ROOT` — so a model could erase its own
      attempt record and resurrect the oscillator, and a comment asserted the protection that did not
      exist. The principle settled here, and it generalises: **outside the guest the tool vocabulary
      is a policy; inside it is a fact** — one must not be read as the other. `FX_AGENT_WRITABLE`
      (root-relative, canonicalized, `O_NOFOLLOW`) with an UNSET default of exactly the task config
      path, so a forgetful deployment cannot re-open the hole. READS stay open deliberately, and the
      bound is stated as a property of the TOOL TABLE, not of the record's location.
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

- **A gate that reads a MOVING REF is not a gate — and a commit is an INPUT to the
  gate.** Phases 5g/8 of `tests/test_outcome.sh` built their "pre-fix" arm from
  `git show HEAD:`; the gate passed *before* the commit and went red the instant the
  commit landed, because `HEAD` was then the fixed source. Two consequences: **re-run
  a gate AFTER committing**, not only before, and **pin a control to a fixed revision
  and prove its domain** (a `cmp` against the working file, so a pin that happens to
  equal the working source fails as vacuous instead of silently proving nothing).
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
