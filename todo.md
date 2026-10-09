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

- [x] **A recovery counter** — `fx-init 4d6a8c2`: `<store>/.recovery`, an append-only journal beside
      `.bootlog`, one data line per AUTOMATIC roll-forward (`<epoch> <published> <from> <genhash>`),
      with the definition and the honesty limit written in the FILE'S OWN HEADER. It is written by
      PID 1 and read by a plain file read, never the runtime DB. Gated by `tests/qemu_recovery_count.sh`
      (exit 0) against a pinned `9b20161` control that fails all ten journal assertions, and it counts
      a REAL oscillation: exactly 1 then 2 roll-forwards with an IDENTICAL genhash — the recurrence
      visible. A refused recovery and a deliberate operator rollback append NOTHING.
- [x] **BUT NOTHING READS IT YET — closed: the read side landed** (`src/llm2/outcome.c`
      `fx_outcome_recovery()`, one reader shared by both consumers, like the bootlog's).
      TWO surfaces, because the observe gate's boot 3 never dispatches the fixture (the harness
      refuses before the loop): the **ACTIVATION_FAILED report** carries a `recovery :` line
      (count, newest recovery, same-genhash recurrence bounded by the journal's own honesty
      limit — "THE SAME FAULT RETURNING, not a live-oscillation claim"), and the **`fx_outcome`
      verb** prints `recoveries <n>` / `recovery_last <epoch> published v<p> from v<f> genhash
      <h|->` / `recovery_recur <h> x<n>` / `recovery_torn <k> ... the count is a FLOOR` between
      `last` and the boot history. Absent journal ≠ zero: absent reads "UNKNOWN, not zero", a
      present empty journal reads "0 ... the FIRST time" — distinct claims, distinct words. A
      torn (unterminated) data line is skipped and SAID (the count is then a floor); two `-`
      genhashes are two absences, never a recurrence. Pinned pre-read asymmetry:
      `tests/test_outcome.sh` phase 9f builds `d94ea77`'s server AND outcome.c and shows the
      journal invisible on both surfaces (same store, same refusal verdict, no journal line);
      `tests/qemu-agent-observe.sh` asserts the guest's real journal (boot 1 `recoveries 0` in
      the fx_outcome transcript; boot 3 exactly one line `published v_C from v_A` + the report
      line on the console; boot 4 unchanged; the BLIND arm's disk counts its own roll-forward
      too — the substrate half is arm-independent).
- [ ] **`.bootlog` growth**: unbounded, fully rescanned by `bootlog_last`/`bootlog_newest_ok_below` on
      every boot, and `fsync`'d per append. The guardrail bounds growth to real boots, so this is
      lower priority — but state the policy (rotate, cap, or index) rather than leaving it implicit.
      `.recovery` has the same shape and now the same question; `src_of` inherits it (never reaped).

## 3. Known defects, pre-existing, not hidden

- [x] **The store CAN attribute a src_hash to a generation — `src_of` landed and the oracle consumes it**
      (was: "the store cannot attribute", found by the osier-share review). `srcstore` is append-only
      and its rows are reaped only when the NAME becomes unreachable, while `provides`/`install`/`svc_*`
      are cleared per activation — so a rebuilt package has several live srcstore rows for one name and
      nothing linked either to the derivation in use. Fixed at the writer (fx-init `9b20161`:
      `commitClosureMeta` commits `src_of(deriv_hash, src_hash, name)` in the activation txn, col0 being
      the same field `provides` uses; fx-init's own gate is `tests/probe-src-of.sh`) and at the reader
      (fxstore `0e831a4`: the relation is in `RELATION_SCHEMAS`). `fx-osier-share` now resolves each
      component through `src_of` FIRST (attribution `src_of` in the output and an `attribution` summary
      line — "the store attributed it" and "only one srcstore candidate survived" are different claims),
      and the ambiguity REFUSAL fires only where the store genuinely cannot answer: no `src_of` row for
      the generation's derivation AND more than one verifying srcstore candidate. `tests/test_osier_share.sh`
      A4 pins BOTH behaviours: the NEW writer's ambiguous store RESOLVES to the current generation's own
      hash (version-bound, the older snapshot keeps its own), and the OLD writer's (pinned fx-init
      `2feedf6`, `cmp`-guarded) still refuses, naming both candidates. RESIDUAL, stated: `src_of` rows
      are never gc-reaped (growth is bounded by the rebuild count, not time — fx-init's commit message).
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
- [x] **A torn ATTEMPT line can no longer yield RUN — the DAMAGE RULE (decided and implemented).**
      The loader skipped an unterminated record line, which was conservative for a torn *result* line
      (no result → the UNRESOLVED branch, never a silent `done`) but NOT for a torn *attempt* line
      whose result line did land: the attempt vanished, the result survived, and the verdict was RUN.
      MEASURED at the API by `handoff-order-review`. DECISION: a torn line POISONS the record for the
      task it names — a torn line proves the file was mid-write, so "the record has no unaccounted
      attempt for this task" is not something the record can be trusted to say — and the poison
      forbids exactly one verdict: RUN. Two flags carry it (`has_torn_line`: an unterminated line
      whose task token survived the tear; `has_orphan_result`: a well-formed result line dropped for
      want of any readable attempt — that one catches the REPAIRED torn line, which is terminated but
      unparsable), both reset by a later COMPLETE attempt. Where RUN would issue ("nothing on record",
      "the ordinary re-run" at C==A) a damaged record gets UNRESOLVED with a report that names the
      damage; a done in force is NOT poisoned (`done` is positive evidence, not an inference from
      absence — both verdicts are stops, wedging a completed task would buy no safety). Gated in
      `tests/test_outcome.sh` phase 5g: `torn-attempt`/`torn-attempt-tail` → UNRESOLVED (pinned
      `014ebb7` shows the old RUN — the measured hole), `orphan-done` → ALREADY_DONE before and after.
      BOUND, stated: a torn line whose TASK token itself was cut is not attributable to any task and
      stays a plain skip (cross-task poisoning would wedge unrelated tasks forever).
- [x] **The outcome verdict table's four ungated cells are gated** (`tests/test_outcome.sh` phase 5g,
      each with its fail direction in the probe comment): (1) the OVERLAPPING CELL `A ok ∧ C == A ∧ no
      done` → SUPERSEDED by row precedence (a mutation that lets the C==A row decide first returns RUN
      and fails the arm); (2) `done → attempt → result` at `C ≠ A` → UNRESOLVED (the 5g probe had
      planted `CURRENT == A` only); (3) the v0-result reinstatement → ALREADY_DONE (a result naming no
      generation still accounts the attempt; a version check on the reinstatement fails it); (4) the
      torn-attempt DAMAGE RULE arm (see the entry above).
- [ ] **The system carries TWO implementations of the store, and the `facts` seat is in ONE.** fx-init
      LINKS the vendored C core (`Dhakefile.dhall:21` — "links fxstore_c (vendored C fxstore +
      dhall-c core)"), and `zig/src/fxstore.zig` is the facade over it; the user-facing `fxstore` CLI
      is the Zig port, built from the SIBLING checkout (`m3/package-set.dhall:128`,
      `src = < Path = "../../fxstore" >`), which is also what the harness freezes and stages.
      **CORRECTION, append-only:** the note added in `fx-init 9b20161` — "a deployment that builds its
      fxstore from this tree's vendor/ will NOT have `facts` at all" — is a PROJECTION PAST THE
      EVIDENCE. Nothing builds the user-facing fxstore from `vendor/`; the vendor copy is an include
      root, not a product. What survives: two implementations of one store coexist, `facts` exists in
      the Zig port only, and a deployment missing it fails LOUDLY at the oracle's capability probe
      (measured — the probe was added precisely because a stale neighbouring binary was found).

## 4. Design items awaiting a decision

- [x] **`src_of` closes the store's attribution gap** (`fx-init 9b20161`, read by the oracle
      since `d94ea77`): the store could say *that* a package was built but not *which source*,
      because `srcstore` is append-only while `provides`/`install`/`svc_*` are cleared per
      activation — so a rebuilt package left two live rows for one name and the oracle refused
      loudly on any store with a rebuild. `src_of(deriv_hash, src_hash, name)` is committed in the
      activation txn, keyed by the same `<hash>` `provides` uses, so a generation resolves its
      own source exactly. Open sub-item: `src_of` rows are **never gc-reaped** (gc keys `srcstore`
      by name-unreachability; a deriv-hash-keyed row has no reap path) — growth is bounded by the
      rebuild count, not by time.
- [x] **The write surface is now a CLOSED, HOST-DECLARED set** (`648984f`). It *was* an unstated
      assumption: the loop's guardrail rested on the record being beyond the agent's reach, and
      `fx_write` could truncate ANY path under `FX_VERB_ROOT` — so a model could erase its own
      attempt record and resurrect the oscillator, and a comment asserted the protection that did not
      exist. The principle settled here, and it generalises: **outside the guest the tool vocabulary
      is a policy; inside it is a fact** — one must not be read as the other. `FX_AGENT_WRITABLE`
      (root-relative, canonicalized, `O_NOFOLLOW`) with an UNSET default of exactly the task config
      path, so a forgetful deployment cannot re-open the hole. READS stay open deliberately, and the
      bound is stated as a property of the TOOL TABLE, not of the record's location.
      **CONSEQUENCE FOR THE FIRST SELF-MODIFICATION TASK, not yet decided:** the default set is
      ONE path, so an agent cannot introduce a new COMPONENT — a component must be a package, and
      the package set is a different file. The host declares the set per task, so the first task's
      deployment must name whatever the task legitimately writes (the config AND how a component
      enters the closure). That is a design decision for the task, not a patch to the bound.
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
      provenance*. **THE GROUND IT NEEDS — work through this list the moment the backend lands, so the
      task is a step and not a discovery:**
        - **WHO PUTS THE COMPONENT IN THE CLOSURE — decide this first.** `osier-share` counts
          components of the ACTIVE GENERATION, and a component reaches the closure as a **package**
          (`provides(pkg, store_dir)` -> `src_of` -> its `.elm` source artifact). So an agent-authored
          MCP server is not counted unless the generation's closure contains the package it lives in.
          Two shapes: (a) the agent writes a **package-set entry** as well as its source — the agent
          then owns part of the BUILD GRAPH, which is exactly what `FX_AGENT_WRITABLE` (default: one
          path) was closed against; (b) the deployment pre-declares **a slot** — one placeholder
          package whose `src.path` is a directory the agent may write — leaving the package set
          host-frozen and the agent supplying SOURCE ONLY. **(b) is the recommended default**: it keeps
          the closed write set closed, keeps the build graph out of the agent's reach, and still moves
          the number. Either way the writable set for that task is a DELIBERATE, NAMED host decision —
          not a widening of the default.
        - **THE RECIPE IS HOST-FROZEN, AND IT IS THE GRADER.** The package's build action runs the
          Osier->Lua compiler over the agent's source and installs the produced Lua. The agent supplies
          source; the HOST supplies the compiler and the recipe. This is the same line the lane already
          states: *the agent may have a compiler; it may not have the one that GRADES it* — and the
          oracle is host-side precisely so the grading cannot be written by the thing being graded.
        - **WHAT THE SERVICE LOOKS LIKE.** `svc_bin` must resolve to the artifact, run under in-guest
          LuaJIT (already shipped, JIT gated two-sidedly), speaking newline-framed JSON-RPC on stdio —
          the same shape `tools/fx-verbs-server.c` and `mcp_client.c` already use, so the plumbing
          exists and the language is what changes. A NEW, non-console service is the right shape: it
          may legitimately FAIL, and a boot failure is what the recovery journal and the observation
          loop now handle. Do NOT copy the console pin onto it.
        - **THE ACCEPTANCE, stated as an asymmetry:** on the same machine, `osier-share` over the RUN
          SET reads **0%** before the agent's component is activated and **non-zero** after, the new
          component appears in the per-component table attributed **by the store** (not by a host
          tree), and the closure number moves with it. A number that moves without the component being
          attributed is not the same claim.
        - **STILL MISSING BEYOND THE BACKEND:** nothing in the guest can yet BUILD a package (the
          provisioned store is toolchain-free by design, `activate_paths`), so the first task needs
          either a host-side build step or an in-guest one — decide which, and note that an in-guest
          build is what makes the agent's source reach the store *inside* the machine rather than
          being copied into it.
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
