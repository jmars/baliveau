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
- [x] **The two reviews landed and their findings were applied** (`80618b4`): the oracle's two
      blockers (an arbitrary `srcstore` pick; a run component silently leaving the denominator) and
      the write-bound's findings (a red gate reading a moving ref; a false RUN; a documented spelling
      that refused everything). Nodes `handoff-osier-share-review`, `handoff-writesurface-review`.

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
- [x] **The `+64` poll window on an unbounded service set is CLOSED** (`fx-init 4d6a8c2`): `SVC_MAX=64`
      is now shared between the bound and the poll array, and an over-wide config is REFUSED BY NAME
      with the ordinal, the window and the skipped-row count — the loud option, chosen over growing
      silently. Gated by `tests/qemu_svc_limit.sh` (exit 0) against a pinned `9b20161` control that
      boots the same 70-service config happily, which is the defect's silence itself.
- [x] **The `console_pin` is no longer a text heuristic** (`fx-init 500fc68` + `fx-harness dfb77fa`):
      `agentService` is a REQUIRED config field and activation refuses a named agent that is unknown
      or non-console, so the identity is a FACT of the substrate. All three pins (including the
      comment-blind copy in `qemu-agent-b2.sh`) are replaced by an `agent_pin` that runs the REAL
      parser and requires it to refuse the mutants. Nothing left to harden here; the open question it
      raised — whether fx-init needs the identity beyond validation — was answered NO, measured.
- [ ] **`fx_read`/`fx_ls` still resolve arbitrary paths under `FX_VERB_ROOT`** — including a `..` that
      climbs *above* a stub root, because `root_join` concatenates strings rather than resolving.
      Pre-existing, read-only, reported by the 648984f lane and NOT silently fixed there. Adjacent to
      the closed write set, so it must not be mistaken for closed: the write bound is a *write* bound.
- [x] **The comment-blind `console_pin` in `tests/qemu-agent-b2.sh` is CLOSED** (`dfb77fa`) — replaced
      with the parser-backed `agent_pin` along with the other two copies. No `strip_comments` needed:
      the pin no longer reads the config as text at all.
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

- [ ] **CORRECTION to the entry below (append-only; my own inference was too wide).** I wrote that
      `414b26c`'s non-zero exit for an unreadable record made the `console_pin` load-bearing "harder
      than before". MEASURED against fx-init: **FALSE, and the reason matters.** The non-console
      branch (`zig/src/init.zig:2722-2733`) pins `failed` on ANY exit during the grace window —
      `if (g_boot_decided == 0 and !was_explicit_stop and s.console == 0)` — and **never consults the
      exit status**. Every refusal in this unit exits 0, and a non-console agent service exiting 0
      during grace fails the boot exactly as surely as exiting 2. So the pin's stake was already
      TOTAL; this round changed nothing about it, and "make the error exit 0" would fix nothing. The
      real choice is structural: teach the SUBSTRATE which service is the agent (so the console
      exemption is granted by identity, not by a test's text match), or validate at ACTIVATION that
      the config's agent service is console — either way the protection stops living in a test's
      string search. The pin is a text heuristic (`tests/qemu-agent-observe.sh`, with a still
      comment-blind copy in `tests/qemu-agent-b2.sh`), so this is worth doing before a deployment
      ships a non-console agent.
- [ ] **The `console_pin` now carries more weight than when it was written.** `414b26c` made an
      unreadable bootlog or record `FX_VERDICT_ERROR`, and `agent_main.c:646` returns **2** for that —
      where the same read errors previously produced `RUN` and exit **0**. Exit-non-zero is safe ONLY
      because the agent service is `console = Some "console"` (fx-init ignores the exit status for a
      console service and pins a FAILED verdict for a non-console one), so the pin is now the thing
      standing between a READ ERROR and a roll-forward spiral on any deployment whose agent service is
      not console. The pin is a TEXT heuristic (and `tests/qemu-agent-b2.sh` still carries the
      comment-blind copy), so this is the strongest argument yet for hardening it — or for deciding,
      deliberately, that a read error on the deployment's own record SHOULD fail the boot. Right now
      it is an unstated consequence rather than a decision.
- [x] **An unreadable `.bootlog` collapses to RUN — the re-issuing direction.** MEASURED by
      `handoff-loud-truncation` and NOT fixed there (out of its write scope): with a DIRECTORY at
      `<store>/.bootlog` and `CURRENT == version`, the verdict is `FX_VERDICT_RUN` where a readable
      bootlog gives `ACTIVATION_FAILED`. The bootlog is how the loop learns its activation FAILED, so
      an unreadable one must be its OWN loud state — the rule the module already states for the store
      ("a verdict that needs the store and cannot read it returns `FX_VERDICT_ERROR` naming the path")
      is exactly the rule this path breaks. RUN re-issues an activation; a false stop is the safer
      error. The journal's reader got its `UNREADABLE` state in that same round; the bootlog's still
      collapses.
      **CLOSED (bootlog-unreadable round, re-measured then fixed):** the collapse reproduced exactly
      as stated (isolated probe: directory AND chmod-000 at `.bootlog` with `CURRENT==A` → RUN), and
      the sweep found the SAME collapse in two more readers. Fixed, all in `fx_outcome_bootlog_read`
      (the ONE reader now — `_each`/`_verdict`/`_last` wrappers removed, they were the flattening):
      (1) a bootlog that EXISTS but cannot be read (EISDIR past fopen, EACCES at fopen, mid-read
      error) is `FX_VERDICT_ERROR` naming path+errno at every row that would decide on its silence
      (the C==A RUN row — the measured cell — and the C!=A "never judged" UNRESOLVED); (2) a TORN
      last line whose version token names the activated generation poisons the RUN row
      (UNRESOLVED with its own report) and re-words the C!=A cell's "superseded before it ever
      booted" claim to UNKNOWN — scoped to the NAMED generation, like the record's rule; (3) the
      RECORD's own file-level read errors (directory/EACCES at attempts.jsonl) are `FX_VERDICT_ERROR`
      naming the path (ENOENT stays the ordinary first boot → RUN), and the verb (`fx_outcome`)
      reports the bootlog's three states as distinct words (UNREADABLE / absent-unknown-not-zero /
      torn-floor) instead of "boots 0". DECIDED, not inherited: an ABSENT bootlog (ENOENT) stays
      SILENCE — the journal's absent-is-a-state rule; phase 5g's planted no-bootlog store already
      gated done-in-force there, and a store that predates `.bootlog` would otherwise be wedged
      forever; a done in force at C==A stays ALREADY_DONE even under an unreadable bootlog (the
      damage rule's "a done is positive evidence, never wedged" exception, re-derived for the
      store's file). Residual, accepted and stated: a REMOVED bootlog reads as silence
      (indistinguishable from a pre-bootlog store from this seat; host-side actor required — the
      model's write surface is closed to `.bootlog`); and `fx_outcome_bindings` (the drift sensor,
      informational) still reads a broken record as "nothing bound" on the `--reconsider`/`--resume`
      paths, where the verdict's new record refusal never runs — self-announcing only via the
      binding WRITE's own loud failure on the same broken file. Gated: tests/test_outcome.sh phase 11
      (a–j: the measured cell, the readable control, EACCES, absent-is-silence, the done exemption,
      torn poison + scope, the record directory/EACCES, the verb's three states, and the pinned
      7afa0c2 pre-fix asymmetry — RUN vs ERROR on the identical fixture).
- [x] **The LuaJIT audit's ARM 2 is a seat that is NEVER CALLED — a second implementation runs
      instead.** CLOSED 2026-10-13: the duplicate is GONE and the called implementation is the
      audit's own. `tests/qemu-luajit.sh` no longer re-implements the hatch probes inline; it
      stages `tests/luajit-audit.sh` into the image (cmp'd against the repo's bytes, and the
      image's extracted bytes) and its new `luajit-arm2` service runs it INSIDE the guest as
      `/usr/bin/busybox sh /usr/fx-agent/luajit-audit.sh /usr/fx-agent/bin/luajit --arm2
      --arm2-out /fx/disk/<MARK>.arm2` (the pivoted root binds /lib64 + /usr only, so busybox is
      the one shell there and `/bin/sh` — this arm's premise — is absent). MEASURED in-guest:
      the audit's own banner, its three `ok:` checks and "hatch probes held" appear on the
      console, and `ARM2 art=luajit verdict=held checks=3 failed=0` is read back OFF THE RAW
      IMAGE. The two arms are now exclusive: `--arm2` runs arm 2 only (the guest has neither
      file(1) nor readelf, so arm 1 cannot share the invocation) and arm 2 gained an
      ARM-EXECUTES control, which makes "this arm is meaningful for the x86_64 artifact only"
      (the i386 artifact cannot exec in this guest) a named FAILING assertion instead of a
      comment. The three false messages are corrected: "NOT YET RUN — pass --arm2 once a guest
      image exists" was true of nothing and now names its caller
      (`tests/qemu-luajit.sh` / `make test-luajit-guest`). Two MEASURED findings along the way:
      (a) arm 2's first in-guest run left the evidence file on the disk with the right name and
      ZERO BYTES (an unflushed page-cache write; PID1 stops the guest as soon as it decides the
      boot verdict, and this lane's i386 control fails the boot by construction) — arm 2 now
      calls `sync(2)` (which WAITS) and refuses loudly if it cannot, and the gate asserts a
      NON-EMPTY file; (b) `dirname(1)` does not exist in the guest (its PATH carries only the
      applets the image symlinks), so the audit's repo-root `cd` is now parameter expansion.
      Gated: `make test-luajit-guest` rc=0 by asymmetry — with the audit repointed at a missing
      script the same gate fails at "the audit's arm 2 never ran in the guest".
- [ ] **Two ungated oracle paths**: the two-origins-one-install-target refusal and the
      `<store>/<hash>-<pkg>/` argv spelling are implemented but have no fixture. Also ungated: the
      64-candidate cap, the shallow-clone SKIP paths, and the in-guest `done→attempt→result` order
      (it needs a qemu resume-crash fixture).

## 4. Design items awaiting a decision

- [x] **THE AUDIT AND ITS TRIGGER — BUILT (`fx-audit`, gate `make test-audit`; the stance is
      AUDITING, NOT PROOFING, user 2026-10-10; §6b).** The missing piece was the thing that
      reads an incoherence and ACTS; it now exists as the oracle's SIBLING seat (host-side,
      agent-unwritable, a function of observable system state — the same three properties
      §7.1 defines for oracles): `tools/fx-audit.c`, invoked `fx-audit --store DIR
      [--rootfs DIR] [--obs-dir DIR] [--rollback [V]]`, exit 0 coherent / 1 incoherent /
      2 tool error. What it reads: `.bootlog` + `.recovery` (fx-init), the version-bound
      facts (`fxstore facts`), CURRENT (fxstore), and `fxstore verify` for the rootfs
      (REUSED, exit 1 on drift — not reimplemented). Named incoherences, each its own
      check, message and fixture in `tests/test_fx_audit.sh`: recovery-without-failure,
      verify-drift, facts-path-gone, version-chain (CURRENT not published; recovery
      genhash vs the generation fact as-of its published version), bootlog-damaged /
      recovery-damaged (a terminated line in a shape the only writer never writes —
      beyond the record's starting set), disagreement-bootlog/recovery-rewritten,
      disagreement-facts-changed, disagreement-artifact-gone, record-vanished.
      **THE PREVIOUS-OBSERVATION COMPARISON (the load-bearing half):** the seat persists
      its own observation OUTSIDE the store (default `<store>.fx-audit-obs`, REFUSED
      inside it — host memory must not live on agent-reachable disk), keyed by the store
      path, recording content hashes of the append-only records, a hash of EVERY
      published version's facts (20 frozen relations, lines sorted so engine iteration
      order cannot produce spurious disagreements), the timeline and the source-artifact
      set; a first run ENROLS (stated in the output). A coherent in-guest rewrite
      (.bootlog `failed`->`ok` + the recovery row stripped, all records agreeing) passes
      EVERY cross-check and is caught ONLY here — the gate proves the "only" with a
      sed-mutant that drops the comparison and goes coherent on exactly that fixture.
      The observation is rewritten only after a COHERENT verdict (a tampered store keeps
      reporting incoherent until acted on), `--re-enroll` resets the baseline.
      **THE TRIGGER stays thin and separate:** the seat never mutates the audited system
      when asked a question; `--rollback [V]` runs the audit and, only on incoherence,
      calls the EXISTING `fxstore rollback --hard V` (refuses a clean store outright,
      defaults V to the newest ok-per-.bootlog, marks that target UNTRUSTED when the
      bootlog itself is the tampered record), prints a loud ROLLBACK line naming every
      finding that caused it, then re-enrolls against the post-rollback state.
      **RESIDUALS, stated rather than claimed away:** the seat sees REWRITES and
      TRUNCATIONS of previously observed records — ~~it CANNOT authenticate APPENDED
      lines (a forged bootlog line in the writer's exact shape is indistinguishable by
      content)~~ (SUPERSEDED by the entry below: with `--boots`, appended `.bootlog` /
      `.recovery` growth beyond what the host's boot count can account for now fires),
      and a coherent tamper on a never-observed store is undetectable by it (the
      enrollment gap — stands); both are printed in the tool's own output. `.bootlog`
      lines naming gc-pruned
      versions are deliberately NOT a finding (gc legitimately prunes snapshots while
      .bootlog outlives them — indistinguishable from a forged line). The two
      within-snapshot single-writer cross-checks (install genhash == the generation
      fact's; src_of's src_hash in srcstore) are implemented but have NO host-side
      fixture: every legitimate writer commits both sides in one txn and no raw fact
      editor exists outside the guest — the per-version observation hash covers that
      tamper class at version grain. ~~No pinned pre-fix revision: the tool is NEW~~
      (SUPERSEDED by the entry below: the boot-accounting change pins `030fbdc` as its
      fail-before; the seat's own arms needed no pin because none existed before it).
- [x] **THE APPENDED-LINE BLIND SPOT — CLOSED by correlating `.bootlog` growth with the boots
      the HOST knows it started (`--boots`, gate `make test-audit`; §6b's own conclusion one
      field further: the host is the hypervisor, so its boot count is off-disk knowledge the
      guest can neither see nor forge).** The hole, measured: an APPENDED `"<failed v> ok
      <epoch>"` in the writer's exact shape passed every check — and it defeats the substrate's
      OWN recovery, because fx-init's boot decision (`bootlog_last`) reads the last non-shutdown
      verdict, so the forged `ok` makes the next boot skip the roll-forward and keep the broken
      generation current (epoch monotonicity cannot separate it: `genEpoch` is
      wall-clock/env-overridable). The fix: `fx-audit --boots N` is REQUIRED (absent → exit 2,
      loudly — an anchor that silently defaults is decorative; chosen over an env var (ambient,
      invisible in evidence) and a host-maintained file (a stale-read failure mode: the count
      must be true as-of THIS audit)); N is the cumulative boots the host has EVER started on
      the store, recorded in the observation (format 2; a format-1 baseline is REFUSED with a
      re-enroll instruction — never assume a count). The accounting rule is DERIVED from the
      writer's call sites (init.zig): per host-started boot at most ONE `in-progress` (:4387,
      only when a generation is bootable and its facts read; the no-generation path appends
      NOTHING), at most ONE verdict (the `g_boot_decided` latch; :2619/:2631/:2726/:4398 — every
      verdict site runs in a boot that already appended its in-progress for the SAME version),
      at most ONE `shutdown` (:3925), at most ONE `.recovery` row (per successful roll-forward).
      So: an added verdict with no added in-progress of that version earlier in the window is
      `bootlog-forged-verdict` (the motivating forge, named in those terms — including its
      no-newline variant, which fgets still reads in-guest; SUPERSEDED in part by the entry
      below: a TORN verdict is judged by the SAME attribution, not rejected on sight); added
      in-progress/shutdown/recovery
      lines beyond the host delta are `bootlog-fabricated-boots`. STRICT window semantics: a
      verdict gets NO credit for an in-progress left open at the previous observation (the
      audit is a between-boots instrument; where ambiguous, prefer the finding — a false stop
      recovers and names itself, a false pass is the failure mode). **The asymmetry is pinned:**
      on `030fbdc` (git cat-file -e guarded, cmp-proven different from the working tree) the
      same forge audits COHERENT; on this tree it fires; a sed-mutant without the check goes
      coherent on exactly that fixture. **Every legitimate growth shape stays coherent, from
      fixtures:** ordinary boot, failed boot, failure→roll-forward (the real `fxstore rollback`
      republish + `.recovery` row), clean shutdown, killed-at-verdict (in-progress alone), and
      a silent boot (no bootable generation — appends nothing); plus a REAL in-guest
      demonstration in `tests/qemu-agent-observe.sh` (enroll after boot 1 with the gate's own
      count, coherent after 4 real boots, and the forge on the REAL guest-written bootlog
      firing). **THE NARROWED BOUND (what still cannot be seen):** a forged line-PAIR
      (in-progress + verdict) appended into the SLACK of a boot the host started but fx-init
      never recorded (killed before its in-progress, or no bootable generation) — closing that
      needs a per-boot host nonce, which changes the writer's format; the count is only as true
      as the host's bookkeeping (a boot started outside the counting host, or a miscounted /
      moved `--obs-file` reuse, reopens the hole); the enrollment gap stands (first run trusts,
      loudly); gc-pruned versions stay deliberately skipped.
- [x] **THE TORN VERDICT and the READ-BOUND — the review's two should-fixes, decided and built
      (gate `make test-audit`).** (1) THE FALSE POSITIVE, MEASURED: `check_boot_accounting`
      fired `bootlog-forged-verdict` UNCONDITIONALLY for an added TORN ok/failed (an
      unterminated appended line) — so a REAL crash shape (a boot's `"<v> in-progress"` line
      landed, its verdict line was cut short mid-append) was rejected with exit 1, and the
      message claimed "no in-progress behind it in this window" while the SAME run's accounting
      line printed `added in-progress 1`. A spurious finding rolls back a HEALTHY machine; that
      is the costly direction. DECIDED: a torn verdict gets the SAME in-window attribution as a
      terminated one (one shared helper, `bl_consume_ip`), for the same reason the reader
      already classes a torn tail as "a crash mid-write, not tamper" and for the reason fgets
      forces anyway (an unterminated final line is READ in-guest, so a torn verdict cannot be
      exempted from the rule). With an added in-progress for the same version answering for it:
      tolerated, and NAMED by its own line ("…is accounted for by an added '<v> in-progress'
      line earlier in this window — one boot the host started wrote both and the append was cut
      short mid-write; counted, not a finding"), so it is never a silent pass (the torn tail is
      also named in the run footer). With nothing in the window accounting for it: still a
      finding, with a message TRUE of that evidence (the delta-0 `TORNFORGE` fixture, the
      no-newline forge, still fires). (2) THE READ-BOUND: `.bootlog`/`.recovery` are parsed into
      FIXED tables (`g_bl[4096]`, `g_rec[1024]`) and the overflow was SILENTLY DROPPED — from
      both the counting and the forged-verdict attribution, i.e. an audit that reports on a file
      it truncated: the silent pass the tool's header forbids. Now exit 2 (tool error), naming
      the cap, the file and the line ("…has more than 4096 parseable lines: this build's
      .bootlog table (g_bl[4096]) is FULL at line 4097 …"); raising the table is the fix when a
      store outlives the cap, and the message says so. (3) NEW ASSERTIONS for the three
      legitimate shapes the review found untested — the SAME version booted twice in one window
      (`--boots 4 -> 6`; fails if the in-order consumption is dropped or made
      per-version-global: the second verdict then finds no unconsumed in-progress and exits 1),
      a MULTI-CYCLE roll-forward inside one window (two real `fxstore rollback` republishes,
      `--boots 4 -> 8`, 4 boots / 2 rows; fails if `recovery-without-failure` reads anything but
      the LAST non-shutdown verdict for a row's from-failed version — boot 6 wrote `R1 ok 113`,
      boot 7 `R1 failed 115`, so a first-match reader calls row 2 unanswered — or if the row
      bound were one-per-window), and an `in-progress` followed by a `shutdown` with NO verdict
      (SIGTERM during the grace: `do_shutdown` appends its line whether or not the boot decided,
      init.zig:3925 from :4461; fails if a shutdown were made to require a preceding verdict, or
      if an open in-progress for CURRENT became its own finding). Plus a KNOWN-HOLE arm that
      ASSERTS the admitted bound rather than leaving it implicit, and a CONTENT-level
      stale-binary guard (the test greps the built binary for a message that exists only in this
      source — an mtime check cannot see a shadowed artifact). **PINNED ASYMMETRY:** on
      `fcebaa3` (git cat-file -e guarded; `cmp` PROVES the pin differs from the working tree;
      nothing reads HEAD) the pre-fix tool rejects the same healthy store (exit 1, message
      contradicting its own accounting) while the fixed tool accepts the SAME store and the SAME
      observation file (exit 0, torn line named). **WHAT THIS DOES NOT FIX (residual, out of
      scope, SUPERSEDED by the per-boot-nonce entry below: CLOSED for nonce-covered boots):** a
      forged line-PAIR into the slack of an unrecorded boot still passed — the
      terminated form was already measured passing, and the torn form now rides the same rule
      (the pre-fix tool caught the torn form only as a side effect of the unconditional rule that
      produced the false positive). The per-boot nonce closes BOTH shapes; its cost is unchanged
      by this fix, and the run's printed bound now says "terminated or torn" so the shape is not
      mistaken for coverage.
- [x] **`attempts.jsonl` must never become evidence — now PINNED, not just stated.**
      `fx-audit` never opens it (or any harness self-report), and
      `tests/test_fx_audit.sh` pins the property behaviourally: the same incoherent
      store with that file ABSENT, PLANTED in the store and DOCTORED in the rootfs
      produces a byte-identical verdict (cmp, exit codes equal) — a self-report cannot
      talk the seat out of an incoherence (and cannot talk it into one either).
- [x] **THE FORGED LINE-PAIR — CLOSED by a PER-BOOT HOST NONCE (gate `make test-audit`;
      the last residual of the appended-line work, closed from both sides).** The hole,
      measured by the review that constructed it: a forged PAIR (`<v> in-progress` +
      `<v> ok`) appended into the SLACK of a boot the host started but fx-init never
      recorded (killed pre-in-progress, no bootable generation, the SVC_MAX-refused
      config) fully impersonated that boot — the count accounted it (1+1 ≤ delta 1) and
      the in-order attribution found its own forged in-progress. THE DESIGN: the host
      (the hypervisor) mints an unpredictable hex nonce per launch and hands it down on
      the kernel command line (`fx.bootnonce=`, the channel `fx.store=` already uses),
      keeping its own ledger (`<boot> <nonce>` per line) HOST-SIDE; fx-init latches the
      token once per PID1 lifetime (before `decide_boot_version`, the first possible
      append) and stamps it as a TRAILING field on every `.bootlog` line (4th) and
      `.recovery` row (5th) that boot appends — additive, MEASURED against every
      reader: fx-init's own three readers parse `"%u %63s"` (2 fields, tail ignored),
      the harness outcome reader `"%lu %31s %lu"` / `"%lu %lu %lu %71s"` (3/4 leading
      fields, tail ignored), every test grep is prefix-style. A boot with no token (an
      operator hand-boot) writes the DISTINGUISHABLE placeholder `none` — not valid
      hex, so no host-minted nonce can collide with it, and the writer REFUSES
      `fx.bootnonce=none` as a host value. WHY THE CLOSURE IS BY CONSTRUCTION, not a
      timing argument the agent could erode: the guest CAN read its own `/proc/cmdline`,
      so secrecy of the current nonce is not the mechanism — (1) a future boot's nonce
      does not exist yet; (2) a past boot's nonce is visible in-guest ONLY on the lines
      that boot itself wrote, and those already spent their per-boot budget, so reuse
      fires the per-nonce accounting; (3) a SILENT boot runs no service at all (the
      writer's own pre-decided failure path), so nobody is alive inside it to spend its
      nonce; (4) an invented nonce is not in the host's ledger. THE READER:
      `fx-audit --nonces FILE` (REQUIRED, exit 2, whenever the window holds boots —
      the `--boots` rule applied to the ledger; loud dies on every self-contradiction:
      two nonces for one boot, one nonce for two boots, a nonce for a boot past the
      count). Observation format 3: a format-2 (pre-nonce) baseline is REFUSED with a
      re-enroll instruction, the way format-1 was. The accounting is then applied PER
      NONCE — ≤1 in-progress, ≤1 verdict, ≤1 shutdown, ≤1 `.recovery` row per nonce,
      and a verdict needs a same-nonce in-progress (one boot, one nonce, latched at
      start): a pair appended ON TOP of a real boot's lines fires the budget (the
      strongest forger — one that READ a real nonce off the disk), a pair claiming a
      silent boot fires `bootlog-unbound-nonce` because it cannot wear that boot's
      nonce (invented / placeholder / earlier-window / no-field classes each named),
      and the silent boot's OWN nonce is itself a REPORTED fact — UNCLAIMED, an info
      line, coherent: a machine that booted nothing is not an incoherence, and an
      unclaimed nonce must never roll a healthy machine back (the false-positive
      direction the previous round shipped and review caught). A TORN verdict is never
      nonce-judged on its own (possibly cut) token: it rides the in-window attribution
      and is charged to the in-progress that answers for it. THE REGIMES, honestly
      split: when the ledger covers every window boot (the harness regime), an added
      line without a window nonce is a FINDING; when it covers fewer (a mixed/manual
      regime — an operator hand-boot, declared by the short ledger), such lines are
      NAMED by an info line and counted by the boot arithmetic only — never silently
      accepted as accounted, never silently skipped. Roll-forward rows carry the SAME
      boot's nonce by construction (the latch precedes `decide_boot_version`). THE
      GATE (`tests/test_fx_audit.sh`, exit 0): PAIRSIL (invented-nonce pair in a
      silent boot's slack fires unbound + the nonce REPORTED unclaimed), PAIRCLS
      (placeholder / no-field / earlier-window classes), PAIRONTOP (a REAL reused
      window nonce fires the per-nonce budget), PAIRNOLEDGER (exit 2), FORMAT2
      (refused), every LEGITIMATE shape re-asserted under per-boot nonces — ordinary
      boot, failed boot, roll-forward with its nonce-bound row, clean shutdown, killed
      at verdict, the silent boot (asserting the UNCLAIMED report), same-version
      twice, multi-cycle roll-forward, in-progress + shutdown — plus the mutant
      direction (sed-deleted `boot-accounting` goes coherent on exactly the pair
      fixture). THE ASYMMETRY, pinned on both sides with `git cat-file -e` + `cmp`
      domain proofs: READER at `88a73b8` — the pre-nonce tool calls the SAME pair
      COHERENT on the old-writer store (the reviewer's exact measurement, reproduced
      with its own format-2 enrollment) while the new tool fires on the same store and
      pair bytes; `030fbdc` keeps the original bare-verdict fail-before (and both
      format-1/format-2 refusals are asserted); `fcebaa3` keeps the torn false
      positive. WRITER at fx-init `500fc68` — pinned, cmp-proven different, and
      asserted at source level (its `bootlog_append` is the 3-field `"%u %s %u"` and
      it knows no `fx.bootnonce`; the working tree writes the 4-field line); the
      writer's BEHAVIOURAL proof is fx-init's zig tests (format + placeholder + parse
      battery, 63/63) and the REAL-GUEST demonstration in `tests/qemu-agent-observe.sh`:
      the gate's own boot loop mints a urandom nonce per launch, passes
      `fx.bootnonce=`, records the ledger, asserts PID1's console echo AND the real
      disk lines carry the issued nonces (boots 1-2), the roll-forward row carries
      boot 3's nonce, the 4-boot history audits coherent with `--boots 4 --nonces`,
      and the forged PAIR on the REAL guest-written bootlog fires BOTH ways (an
      invented nonce → unbound; boot 4's disk-read REAL nonce → the per-nonce budget).
      **WHAT STILL CANNOT BE SEEN (the narrowed bound, printed on every run):** window
      boots the ledger does not cover (the mixed/manual regime — a forged pair in an
      UNCOVERED boot's slack still passes the arithmetic); boots started off the
      counting host, or a miscounted/moved `--obs-file` reuse (the count AND the
      ledger are only as true as the host's own bookkeeping — a host-side forger
      defeats a host-side anchor by definition); the enrollment gap stands; and a
      silent boot's own nonce, worn by a pair constructed HOST-side, is
      indistinguishable from that boot's real lines — unreachable in the threat model
      (the guest cannot learn it: no lines carry it, the cmdline is gone, no service
      ran to read it), stated here so nobody mistakes the timing argument for a
      mechanism.

- [ ] **THE BUILD VOCABULARY — designed (§6a of the design record), NOT BUILT. Build in this order,
      because each element's absence makes the next one decorative:**
      1. **THE REACH BOUND — IN USERSPACE, NOT A SANDBOX (corrected 2026-10-10: the VM is the
         boundary).** The pinned guest kernel has `# CONFIG_SECURITY is not set` (no LSM ⇒ no
         landlock), `# CONFIG_SECCOMP is not set` (palisade's `n` IS seccomp), and
         `# CONFIG_NAMESPACES is not set` (bwrap is MADE of namespaces ⇒ bwrap cannot exist in the
         guest at all). So **no kernel sandbox primitive exists there**, and the `bwrap`-absent
         UNWRAPPED path (`fxstore zig/src/build.zig:711-733`) is not a gap to close by sandboxing.
         Instead the bound goes where the actions are OURS: `fxstore`'s action runner refuses a
         `Copy`/`Rm`/`Mkdir`/`Symlink`/… whose path is outside the build's own workdir and the path
         it installs. Residual, stated: the harness's `attempts.jsonl` is a SELF-REPORT, so against a
         MALICIOUS recipe the answer is to make the record tamper-EVIDENT (content-addressed /
         hash-chained) rather than tamper-proof — and the layers above it are fx-init's own guardrail
         and the HOST-side oracle, neither of which in-guest tampering can reach.
      2. **THE ACTIVATION-TIME REFUSAL.** An out-of-subset action is refused BY NAME where the config
         is validated — the `agentService` pattern (`fx-init 500fc68`), same place, same loudness.
      3. **THE SUBSET AND THE ABSOLUTE-ARGV RULE.** `Shell` is excluded from the agent-authorable set
         (host-frozen sets keep it); `Run` requires an absolute `argv[0]`, no PATH search — the
         discipline the code already applies to itself for `bwrap` (`build.zig:351-354`).
      4. **INLINE PACKAGES IN THE CONFIG, merged by `fx-activate`** into the package set before the
         closure is computed, so no new file becomes agent-writable.
      PREREQUISITE for all of it: `fxstore` must run where the agent does — static, x86_64-linux-musl,
      against a static libdatalog (it is currently glibc-dynamic with a `.so` dependency).
- [ ] **The agent's activation BYPASSES PID 1's commit.** It direct-execs `/bin/fx-activate`, which
      reaches only the child half (config → closure → Dhakefile → facts → snapshot → CURRENT) and
      skips PID 1's `run_dhake()` HOT-APPLY, the boot-decision re-arm, the service restart and the
      `rt_effect` (`fx-init zig/src/init.zig:3218-3395`). The route is the control channel —
      `fxctl --fifo` over `/run/fx/control.in` + `control.out`, which exists as "the in-guest
      transport" (`fxctl.zig:45-53`) and is a PURE CLIENT (imports only `std`, opens no DB) — and the
      half-wrong finding that sent the agent direct-exec is already flagged in this file's house
      rules.
- [ ] **No in-guest reboot.** The control protocol carries `status|log|activate|rollback|shutdown`
      and no reboot (`init.zig:3098-3228`); the guest tests pass qemu `-no-reboot` with the HOST
      restarting the VM. "Activate … (causing a reboot into it)" needs a reboot the machine can
      perform on its own.
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

- [x] **THE GROUND FOR THE FIRST TASK IS BUILT AND PROVEN (with the compiler
      still absent)** — the slot decision below was implemented, not just
      recommended.  **The slot:** `fx-init/m3/package-set-slot.dhall` (a
      SIBLING of the self-hosting set, never mixed with it) declares the
      package `oslot`, whose `src.path` is the in-guest directory
      `/fx/disk/agent-src/oslot`.  The agent writes EXACTLY ONE FILE there —
      MEASURED refinement of this item's own wording: `FX_AGENT_WRITABLE` is
      colon-separated EXACT paths (never prefixes), so the task's set names
      the FILE `/fx/disk/agent-src/oslot/Mcp.elm` plus the task config, and
      `fx_write` cannot mkdir parents, so the DEPLOYMENT pre-creates the
      directory on the disk (the seat), the agent fills the file.
      **The recipe is host-frozen and is a STUB, labelled at the artifact:**
      one Shell action that installs the agent's `Mcp.elm` beside a
      host-written `#!/bin/sh` stand-in runner and a `STUB-NOTE` saying what
      it is NOT; executed by the REAL `fxstore build` (bwrap hidden from its
      probe on this merged-usr host = fxstore's own sanctioned LOUD
      non-hermetic fallback, prov_e2e.sh's pattern).  **The build step is
      HOST-SIDE (the open decision above, now decided for this ground):**
      nothing in the guest can build, so the host reads the agent's source
      back off the disk, builds into a read-back copy of the GUEST'S OWN
      store, and injects the two content-addressed dirs (`<hash>-oslot`,
      `<src_hash>-oslot-src`) into the disk image (e2fsck -fy + debugfs -w;
      `rdump` cannot run unprivileged — per-file walks both ways).  The
      slot package carries NO DEPS, and that is load-bearing: the derivation
      hash serialises dep store PATHS, so a dep would make the host-built
      hash and the in-guest hash disagree; dep-free they agree by
      construction.  **The runner is a plain `#!/bin/sh` script, NOT
      LuaJIT:** MEASURED, the qemu lane's pinned kernel has
      `CONFIG_IA32_EMULATION` unset and the only LuaJIT artifact at the time
      was i386 — it cannot exec there at all; `CONFIG_BINFMT_SCRIPT=y` is
      asserted by the gate.  **(CORRECTED 2026-10-10 — an x86_64 LuaJIT now
      exists, so the ABI is no longer the blocker:** `tools/build-luajit.sh
      x86_64` builds `build/luajit-x86_64.musl` from the same vendored,
      pinned tree with the same capability bounds; `tools/stage-guest.sh`
      stages it as `/usr/fx-agent/bin/luajit` with the i386 one beside it as
      `luajit.i386`; `tests/qemu-luajit.sh` (`make test-luajit-guest`) proves
      it EXECUTES in this pinned-kernel guest — durable marker on the disk,
      JIT compiling traces in-guest — with the i386 artifact as the in-boot
      ENOEXEC control.  The stub runner stays as built; the Lua shape is no
      longer waiting on a kernel that can exec it.)
      **The service is NON-console** (`oslot-mcp`, svc_bin resolves to
      `<hash>-oslot/mcp-stub-runner` via the pkg'd-row rule), stays alive
      through the grace window (fx-init pins `failed` for ANY non-console
      exit during grace, whatever the status) and proves it EXECUTED by a
      marker file on the disk — its stdout goes to the log DB, not the
      console.  **The proof** (`tests/qemu-agent-slot.sh`, `make
      test-agent-slot`, a NEW gate — the observe gate is untouched): boot 1
      the agent writes source+config in-guest and its record/store tamper
      probes are REFUSED naming `FX_AGENT_WRITABLE`; host build; boot 2 the
      agent's own `fx_activate` publishes v_slot on the DISK store; boot 3
      v_slot boots and the service runs; `fx-osier-share` over the disk
      store read back per-file reads **0.000000** before (slot not in the
      closure; the agent row NONSTORE-UNATTRIBUTED) and **non-zero** after,
      with `component oslot <src_hash> store <bytes> ... run src_of` —
      attributed BY THE STORE, origin `store`, and the numerator exactly the
      agent's .elm bytes.  Two fixture images are used because the stream
      replays identically every boot: image A carries no `fx_activate` call
      (no attempt line ⇒ boot 2's verdict is RUN — the rule that lets the
      same task activate after the host step), image B adds the activation.
      RESIDUAL, stated: the agent's source reaches the store only THROUGH
      the host step (an in-guest builder would keep the bytes inside the
      machine — nothing ships one yet); the boot-2/3 flow depends on the
      image swap being a HOST decision at the build boundary, which is
      exactly what the first task's deployment must schedule.
- [x] **THE RESIDUAL IS CLOSED (2026-10-10): THE BUILD IS IN THE GUEST.**
      `tests/qemu-agent-slot-inguest.sh` (`make test-agent-slot-inguest`)
      proves the loop with NO host step: the payload now ships the BUILDER
      (fxstore cross-built x86_64-linux-musl, STATIC — `file`: "statically
      linked, stripped", NO dynamic section; staged by `tools/stage-guest.sh`
      at `/usr/fx-agent/bin/fxstore` beside `stage3` and the busybox applet
      links `sh/chmod/cp/...` the recipe needs — the pivoted root has no
      `/bin/sh`, so `fxstore` gained a `FXSTORE_SH` knob with the same
      resolve-ONCE-at-startup discipline as `FXSTORE_STAGE3`, and the verb's
      child env carries both, pointed at the staged seats).  THE AGENT'S
      VERB is `fx_build` (`tools/fx-verbs-server.c`): a pinned argv
      `fxstore build --store /fx/disk/store <pkg>`, a pinned cwd `/usr/fx`
      (where the image's frozen package-set.dhall lives), STORE-SCOPED like
      its neighbours — and the package argument is BOUNDED by a closed,
      host-declared set `FX_AGENT_BUILDABLE` (default: exactly `oslot`; a
      bare-name shape gate in front: no flags, no paths, no sets).  THE
      GATE (MEASURED, exit 0): ONE image and ONE disk for the whole loop;
      boot 1 the agent writes, calls `fx_build oslot` (the disk store
      carries the guest-written `<hash>-oslot` + `<src_hash>-oslot-src`;
      the transcript carries fxstore's own output AND the LOUD
      bwrap-absent NON-HERMETIC warning, visible, not silenced), probes the
      bound (invented name + flag shape → REFUSED naming the set), and
      activates v_slot; the oracle reads 0.000000 AS-OF the bracket; boot 2
      is the SAME image (sha256-compared byte-identical) and the SAME disk
      (no e2fsck, no debugfs -w between boots — read the script), boots
      v_slot, the stub service marks the disk; the oracle then reads
      non-zero with `component oslot <src_hash> store <bytes> ... run
      src_of` and the store's own `facts store/srcstore/src_of` rows shown
      off the read-back disk.  EXEC PROOFS in the same gate, in the guest:
      a console service runs the staged fxstore's `--help` (usage + the
      `facts` line on boot 1's console), and a DEDICATED one-generation
      boot runs bare `stage3` (usage on the console, exit 1 → boot FAILED
      by construction, the `failed` verdict on the disk bootlog — the
      SERVICE-GATE shape; this kernel has no SECCOMP, so no sandboxed-child
      shape is claimed).  `tests/qemu-agent-slot.sh` STAYS GREEN beside it:
      it still proves what the in-guest gate cannot — that a HOST-built
      hash is adopted by a GUEST activation (the cross-machine portability
      of the derivation hash) and the e2fsck/debugfs injection path itself.
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
        - **WHO PUTS THE COMPONENT IN THE CLOSURE — DECIDED (user, 2026-10-10; §6a of the design
          record).** `osier-share` counts components of the ACTIVE GENERATION, and a component
          reaches the closure as a **package** (`provides(pkg, store_dir)` -> `src_of` -> its source
          artifact), so the agent's work is not counted unless its package is in the generation.
          **The agent declares packages IN ITS CONFIG** — its existing write surface, so no new file
          becomes agent-writable and no bridge between the FS timeline and the store timeline is
          created. The recipe is admitted too, but only as a composition over a **HOST-FROZEN Action
          subset**: no `Shell` (it is `sh -c <arbitrary text>` and dissolves every other bound),
          `Run` requires an ABSOLUTE `argv[0]` (it is PATH-resolved and recipes control the
          environment), and the actions' REACH must be enforced in-guest. **SUPERSEDED by this:** my
          earlier recommendation of a single pre-declared SLOT as the default — the slot is the
          DEGENERATE CASE (one package, frozen recipe, agent-writable `src`) and stays as the proven
          ground. And the load-bearing caveat: **none of it holds until the reach bound is real**,
          because on the `bwrap`-absent path the recipe runs UNWRAPPED, so in the guest a `Copy`
          reaches the record as well as a `Shell` would.
        - **THE RECIPE IS HOST-FROZEN, AND IT IS THE GRADER — AMENDED by §6a.** The package's build
          action runs the compiler over the agent's source and installs the produced artifact. The
          GRADER is still host-side and the compiler still host-supplied; what §6a changes is that the
          recipe may be AGENT-COMPOSED from a host-frozen Action subset. The agent supplies source;
          the HOST supplies the compiler, the vocabulary and the reach bound. This is the line the
          lane states: *the agent may have a compiler; it may not have the one that GRADES it.*
        - **WHAT THE SERVICE LOOKS LIKE.** `svc_bin` must resolve to the artifact, run under in-guest
          LuaJIT (the x86_64 artifact `build/luajit-x86_64.musl`, staged at `/usr/fx-agent/bin/luajit` —
          NOT the repo's i386 artifact, which the pinned guest kernel cannot exec; `make
          test-luajit-guest` gates exactly this, JIT gated two-sidedly in-guest), speaking newline-framed JSON-RPC on stdio —
          the same shape `tools/fx-verbs-server.c` and `mcp_client.c` already use, so the plumbing
          exists and the language is what changes. A NEW, non-console service is the right shape: it
          may legitimately FAIL, and a boot failure is what the recovery journal and the observation
          loop now handle. Do NOT copy the console pin onto it.
        - **THE ACCEPTANCE, stated as an asymmetry:** on the same machine, `osier-share` over the RUN
          SET reads **0%** before the agent's component is activated and **non-zero** after, the new
          component appears in the per-component table attributed **by the store** (not by a host
          tree), and the closure number moves with it. A number that moves without the component being
          attributed is not the same claim.
        - **THE BUILD HAPPENS IN THE GUEST, AND THE IMAGE IS NOT THE UNIT OF CHANGE — DECIDED
          (user, 2026-10-10, correcting me twice).** The agent is ALREADY INSIDE the machine. A new
          generation must not require building, patching or injecting an **IMAGE**: the change is
          carried by the **STORE**, which is already there on the disk the agent is running from. The
          loop is **make changes -> APPLY them -> activate the new generation**, all in the running
          system. What I had wrong, and what must NOT survive as the agent's loop: the current slot
          chain (`tests/qemu-agent-slot.sh`) reads the source back OFF the disk image, builds on the
          HOST, injects the result back with `e2fsck`/`debugfs -w`, and boots again — a host round
          trip per iteration, which is exactly the dependency that makes iteration impossible.
          MEASURED OBSTACLES to the corrected loop: (a) `fxstore` has never been built to run
          anywhere but the host — dynamically linked against `libm.so.6`, `libc.so.6`,
          `ld-linux-x86-64.so.2` AND `libdatalog.so`, so a musl guest cannot exec it; (b) the recipe
          executor needs palisade `stage3`, whose absence is a LOUD exit 127 with NO fallback (only
          bwrap-absent has the LOUD non-hermetic fallback, so an in-guest run legitimately falls back
          to plain exec in the workdir and must SAY so) — `stage3` is a static System V x86-64 ELF and
          runs on this host, so it is EXPECTED guest-viable but must be PROVED there;
          (c) **THERE IS NO IN-GUEST REBOOT**: fx-init's control protocol carries
          `status`/`log`/`activate`/`rollback`/`shutdown` and NO reboot (`init.zig:3098-3228`; only
          "shutdown" exists), and the guest tests pass qemu `-no-reboot` (`qemu-agent-observe.sh:648`)
          with the HOST restarting the VM. So "make it effective" currently depends on something
          outside the guest, which is the same class of gap the user is pointing at.
- [ ] **LuaJIT JIT on/off in the guest**: shipped ON and gated two-sidedly; the *compiler* and
      agent-authored MCP servers are the long-running workloads that justify it. Measure per lane.
      (2026-10-10: MEASURED IN-GUEST for the x86_64 artifact — `tests/qemu-luajit.sh`'s disk marker
      carries `traces=N,0`, traces compiled with the JIT on and none after `jit.off()`, inside the
      pinned-kernel guest.  The i386 artifact's JIT remains host-measured only: that artifact cannot
      exec in this guest at all, and the v86 lane is where its in-guest numbers must come from.)

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

- **Suspect the INSTRUMENT before the phenomenon — and this cost me a wrong report.** I measured
  "the new refusals exit 0" and was one step from telling the user the protection was inert and
  dispatching a fix lane for it. The refusals exit **1**; my *echo* was wrong:
  `echo "$(basename $f) rc=$?"` expands the command substitution **first**, and running `basename`
  resets `$?` to **its own** status. The same class bit me twice more: `cmd | head; echo $?` reports
  *head's* status, not `cmd`'s. **Capture `$?` into a variable on its own line, immediately**, before
  any other expansion or pipeline. A perverse or inert-looking result usually means the instrument.

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
