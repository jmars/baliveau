# todo

Living list for **baliveau** — the self-modifying fixpoint-linux system. Design record:
[`docs/baliveau-self-plan.md`](docs/baliveau-self-plan.md). Plans, reviews and evidence live in the
agent memory store (node names are given per item).

Two repos are in play: **this one** (`fx-harness`) and **`../fx-init`** (PID 1, the boot/recovery lane).

---

## 0. Land what is already verified

- [x] **THE PLAN IS COMPLETE — the user-ordered sequence, all committed.** In order: the
      **config→generation link** (`fx-init 1399dbd` + `fxstore 0341650`), the **§6a vocabulary** —
      packages in the config, the four activation-time refusals (`fx-init 4c5803d`) — and the
      **reporter seat**, the third host-side reader (`fx-harness bcf96fd`). Then the two defects the
      reporter found in OTHER components were fixed: the **gc carve-out** (`fxstore c3da8ca` + the seat's
      inverted arm `afa861a`) and **durable operator interventions** (`fx-init ca9cb06`), whose read side
      (`f78d7b5`) made the seat's two weakest classes MEASURED. §6a's element (C) was deliberately NOT
      built: §6b downgraded it to optional defence-in-depth once the VM-is-the-boundary correction
      landed, and the reach that is still unbounded is stated in the code rather than implied.
      **NEXT, in the order I would take them:** (a) the **Osier→Lua backend** — blocked elsewhere, and
      the only thing between here and the first self-modification task; (b) the retention POLICY — **CLOSED
      2026-10-12: DECIDED UNBOUNDED**, stated in the reporter's frozen tables (§2), so there is nothing to
      build; (c) the residual store defects in §3 — **ALL THREE CLOSED**: the **`install`-fact fix** (the
      writer's 5 drifts on a stock system), the **`fx_read`/`fx_ls` `root_join` reach** (both now take the
      same `canon_root_rel` gate `fx_write` has) and the **ungated oracle paths**. What remains in §3 is
      the two-implementations-of-the-store note and the two literal-skip arms, below.
      **(d) THE CLAIM UNIT — the newest thread** (§1b's last item, and §1a's AI-Act gap 2): S0 is landed
      and green; **S1** (the judge seat `tools/fx-claim.c`), **S2** (reporter surfacing + the
      `claim-evaluator-location` bound) and **S3** (the `le`→Osier port + by-name enforcement) are queued.

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
- [x] **The agent's activation goes THROUGH PID 1** (COMMITTED `fx-harness 2818813` + `fx-init f3f60fd`):
      `fx_activate` spoke PID1's fifo line protocol natively (`activate <config>` on
      `<run>/fx/control.in`, the reply off `control.out`) instead of direct-exec'ing `/bin/fx-activate`,
      so the agent's change is COMMITTED (hot-apply of `/etc`+`/bin` on the live root, boot-decision
      re-arm, service restart, `rt_effect`), not merely published. WHY NOT `fxctl --fifo` (the existing
      client): MEASURED ~63s activation vs fxctl's hard 5s fifo poll budget — a false "no response"
      refusal while PID1 still commits. The fast fxctl verbs (`fx_query`/`fx_status`/`fx_rollback`) DO
      ride `--fifo` (they were socket-defaulted and ENOSYS-dead in the guest). Bounds kept: store-scope
      (new `needs_store` row flag), a whitespace config-path refusal (PID1's grammar is unquoted
      strtok), the fifo pair's single-client convention stated in the code. Channel-less deployments
      fall back to the old direct exec behind a LOUD reduced-semantics banner. See
      `handoff-activate-route-result`.

- [x] **THE GATES THAT SKIPPED NOW RUN — one sibling-resolution policy (`8d7d8b9` + the `Makefile` line;
      `handoff-path-sweep-ctx`/`-result`).** MEASURED, and the silence was the point: the tree MOVED out of the fx stack's
      workspace (`/var/data/workspace/fixpoint-linux/fx-harness` → `~/futaie/baliveau`), so every gate resolving its
      siblings as `$REPO/..` was looking in `~/futaie` for `fx-init`/`fxstore`/`datalog-dafsa` —
      `make test-osier-share` exited 2 at the Makefile's `DATALOG_DIR $(error)`, and with that supplied it **SKIPped** at a
      path that could never be right again. A skip is quiet enough to read as a pass, which is the failure mode this repo
      exists to argue against. ONE policy now at 14 sites in 11 files — `$FX_SIBLINGS` wins, else `$REPO/..` IF it really
      holds `fx-init`, else `$HOME/fixpoint-linux`, else a LOUD skip naming `FX_SIBLINGS` — plus the Makefile's own
      `DATALOG_DIR` default (`$(wildcard …)` on the real `.so`, else the relocated default) and every stale `Env:` comment
      corrected. **PROOF, mine, with NO env override:** `make test-osier-share` **0**, `make test-report` **0**,
      `make test-audit` **0**, `make test-sibling-paths` **0** (29 arms, ~9 min) — the first three previously skipped or
      died. The new gate runs EVERY site BOTH ways (a bogus `$FX_SIBLINGS` must skip loudly naming it, which proves the
      resolution line is LIVE on that script; with no override each script must get PAST resolution) under a stated bound
      (30s per qemu arm, so no guest is booted to completion), and pins the pre-fix revision (`0f2c902`, `cmp`-proven to
      differ) to show it SKIPPED. **The sweep touched NO assertion**: every deleted line in `8d7d8b9` is a resolution
      line, an `Env:` comment or a skip message (I read the whole deletion set). ONE deliberate deviation from my brief,
      ADOPTED: `$FX_SIBLINGS` is made to win even when set to a BOGUS path (`[ -n "${FX_SIBLINGS:-}" ]`), because the
      literal two lines I specified would have silently discarded an explicit override — and the arm that proves a
      resolution line is live is unsatisfiable without it.

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
- [x] **The oracle IS a tie-breaker now — the order is EXECUTED, not described** (`fx-select`: `0f2c902` + the review's fix
      round `cebcdda`/`9f6cd17`; `handoff-fx-select-ctx`/`-result`/`-review`). A new host-side seat sweeps the store's
      published versions in §7.1's order: **viability** from `<store>/.bootlog` (the LAST non-`shutdown` line naming the
      version; `failed`/`in-progress`/`damaged`/`never-judged`, and a torn tail naming it, are each NOT viable and NAMED) →
      **coherence** via `fxstore verify`, judged for CURRENT ONLY (every other candidate prints `not-live` WITH its reason
      and is not disqualified, because the live rootfs corresponds to exactly one generation — the honesty rule) → *then*
      the **share**, the oracle's own `run_set_share_fraction` shelled (never re-derived; a candidate the oracle refuses is
      EXCLUDED BY NAME, never counted as 0). Frozen TSV records + a `#` summary, the 8-step order + its bounds printed on
      every run, byte-deterministic; decision `keep` | `revert-to` | a named refusal, and `--apply` drives the EXISTING
      **soft** `fxstore rollback` (content back, version UP) and refuses — no mutation — whenever the decision is not
      actionable. **THE CANDIDATE SET IS BOUNDED, which is a design decision taken here**: `{CURRENT} ∪ {newest version
      below CURRENT whose `generation` fact genhash differs}`, tie → CURRENT. Unbounded, the third term becomes a GLOBAL
      OBJECTIVE — every strictly-lower-share change is reverted forever (a non-Osier task could never be kept) and each
      revert republishes the attractor higher — which §7.1's own *"a tie-breaker, not an objective"* forbids; the bound is
      also what keeps the two-snapshot publish honest (MEASURED: an activation/rollback publishes an INTERMEDIATE whose
      system facts are identical to its predecessor's, so "highest version" preferred a half-published snapshot). Exit
      3 = WITHHOLD, ONE predicate shared by the record and the trigger. Gate `make test-select` (22 arms, exit 0 — MY OWN
      RUN, no env override), three sed-mutants each blind on exactly its fixture (viability filter, coherence filter, tie
      clause). **MEASURED while fixing, and kept:** the fixer's `--apply` rolled 7→9 and the NEXT run reverted back to 7 —
      the seat undid its own rollback (`current-not-judged`), now a withhold state gated by S8c/S8d. STILL OPEN under this
      heading: §1's second item below (an oracle must SEE capability changes), and the intent record (§1b).
- [x] **Every oracle must be able to SEE capability changes — THE CAPABILITY HALF IS NOW CLOSED,
      AND THE ACTIVITY HALF IS NOT.** A code-only oracle is blind to an agent quietly widening its own
      egress, and blind to *activity without progress* (the oscillator is the measured instance).
      `osier-share` is a static property of the store and sees neither: it is the per-task oracle.
      **CAPABILITY — DONE**, and by the seats the item predicted: egress S4 gave `fx-select` a
      `reach-delta` term and `fx-report`/`fx-audit` the `reach-*`/`egress-reach` records; palisade S4
      gave `fx-select` a `reach-sandbox` term and the other two the `sandbox-*` records — so an
      operator table edit, a baseline change, a tool sidecar or a widened reach is now SEEN and NAMED,
      with the mandated blinds proving the instruments can fail (the widening-blind reads NONE while a
      sidecar declared `inet`; the drifted-pin join reports MATCH while it drifted). `fx-osier-share`
      STATES its blindness rather than being patched into seeing.
      **ACTIVITY WITHOUT PROGRESS — NOW BUILT** (**UNCOMMITTED**), as a `progress` class in
      `fx-report`, and the plan that designed it **REFUTED the assumption that it needed a new
      subsystem**: three quarters already existed. `dup_targets` (`fx-report.c:2918`) already
      classifies every version by CONTENT identity and already excludes the benign publish-pair;
      `read_facts` loads the per-version genhash; and `fx-init` already computes `fail_n`/`ver_n` per
      genhash and acts on `RECOVERY_CONTENT_FAIL_MAX`. So the work was the **collapse**, not a seat.
      **ACTIVITY** = published versions split by content identity (new / repeat / duplicate /
      NOT-KNOWN), excluding the protocol pair; **PROGRESS** = the FIRST SIGHTING of a content
      identity. The plan's line is the reason: *counting rows measures the logger, version numbers
      measure the publisher — only the genhash measures the system.*
      **THE THRESHOLD IS REUSED, NOT CHOSEN** — `RECOVERY_CONTENT_FAIL_MAX` (2), `init.zig:1050`,
      cited by name and location, with `guard_stats_for` (`:1218`) as the independent implementation,
      so the two are **cross-checkable**. **THE NAMED SILENT FAILURE IS CAUGHT:** `MUT-IDENTITY` keys
      the map on the version number instead of the genhash and **reads a flat store as FULL
      PROGRESS, losing the finding** — an instrument reporting healthy because it cannot see the
      thing, and the gate catches it. A second mutant keeps the correct READING and loses only the
      FINDING (the half-blind). **The loop BOTH it and the existing guard miss is named, not papered
      over** — always-new-content-always-failing — printed as `identities-never-ok` +
      `longest-failed-streak` and **deliberately not a finding**. The existing `content-recurrence`
      entry was **amended to say it is the NARROWER class** (`.recovery`-only, blind to a repeat a
      RE-ACTIVATION produced), because two look-alike entries without that distinction IS the
      silent-defect shape. The dangling `§7.1c` cite is corrected to `§7.1`.
      **Limits where a reader meets the number:** it is a MEASUREMENT, not a policy — it gates
      nothing — and it cannot know INTENT, so a long useful task can look flat. *Orchestrator-verified:*
      `test-report` rc=0 with the two mutants above, and `test`/`test-select`/`test-audit`/`test-hostgate`
      (207 OK, 0 FAIL) all green.
      **One flake reported and NOT reproduced:** the implementer saw `test-hostgate` exit rc=2 once
      ("proxy did not exit within 40s", phase 100) and rc=0 in isolation; my full run was clean. A
      load-sensitive wait loop — recorded rather than reconciled, and worth watching.

## 1c. The ACL split — access control out of the agent's config

**USER DIRECTIVE: "move the access control stuff out of the system config the agent is using to control
fxstore generations, into a config the host controls."** Plan: `handoff-aclsplit-plan`, whose own diagnosis
corrected the framing: it is not one file with two roles but a **CYCLE between two files** — the activation
config the agent writes names, via `services[].env`, WHICH agent config its successor reads. So opening it
would hand the agent its own constraints back, **unless the agent-config vocabulary can no longer EXPRESS
access control**. That is what this arc built.

- [x] **S1 — the operator's access table** (`3fad711`): `policy/access/access-verbs.tsv` (15 rows = the 13
      catalog verbs **UNION** the 2 host tools) + `PINS`, and a startup loader with **the totality check
      over BOTH vocabularies at once**, exact-name resolution, named refusals **before the slave path is
      published**, and `--print-access`. **Its blind is the ALLOWING one** by design — the failure direction
      is an unclassified verb silently ALLOWING, and a mutant that over-denied would prove nothing. S1
      judged nothing and said so in its header AND its startup line.
- [x] **S2 — the access AUTHOR** (`90f1bcc`): in position `denylist → ACCESS → ops → justification →
      claim`, refusing **both a classified deny and a name with no row** (silence is not an allow). The gate
      is **three-way on one fixture** — outside → denied + marker absent + `author=access`; the SAME fixture
      on the mutant → crosses; inside → crosses on both — because a seat that denies everything and one that
      allows everything BOTH print an armed startup line.
- [x] **S3 — the schema split** (`e651067`): `enabled_tools`/`disabled_tools`/`mcp_servers`/`providers[]`/
      `models[]` **gone** from the guest schema; `agent_main` builds an **empty ToolPolicy**; the lane file
      is **derived** from `policy/access/`. The migration pass runs **BESIDE `config_load`, not inside its
      fail-open path**, refusing a moved field **by name and by its new owner** — silence would leave an
      agent running allow-all with nothing at rest recording it. *The pre-fix control proves the claim
      rather than its absence:* on the old binary the same config is accepted AND its `enabled_tools` still
      bites in the guest — access control left the config and did not stop being enforced.
- [x] **S4 — THE COLLISION, and it had TWO teeth** (`976de14`): unprotecting the alias row
      (`Agentconfig yes→no`, re-pinned) was **necessary but not sufficient** — **D2**
      (`writable ∧ !boot_verdict(ok)`) independently denies, and the agent runs **entirely inside the grace
      window** (recorded: agent marker at console 273, `boot-ok v9` at 306, **15 s apart**). So the ORDER
      is the fix: `boot_verdict_wait()` in `agent_main.c` holds the write+activate until the verdict, using
      outcome.c's **existing** bootlog reader (one reader, no drift). The new arm proves the order is
      load-bearing in the way that matters: a payload writing **before** the verdict is refused with a
      message naming **D2, NOT D1** — so a future reader "simplifying" the wait away gets a failure that
      reads like a *timing* decision rather than a policy one. The named breakage was repaired **where it
      actually appeared, which was more places than the plan listed** (verbs-smoke 4 arms, test_ops_policy 3
      flag-keyed seds not 4, test_hostgate 6 phases + a new 85b, test_fx_report's hard-pinned `protected
      yes`), with D1's proof moved to a sha-pinned fixture table.
      **NOT OVERCLAIMED: the ORDER makes the loop work, not the unprotection** — and §6b stands (root can
      write that file by hand; this governs the HARNESS path).
- [ ] **S5 — STILL OWED: the oracle must SEE the access table.** `fx-select`'s reach term gains the access
      table as a **third dimension** (allow→deny is a NARROWING; deny→allow is a **WIDENING** with a named
      row and the loud `egress-reach-widened`), and `fx-audit`'s per-boot record carries the **armed-author
      set** including `access`. The fail-before is a REPRODUCED BLINDNESS: today's `fx-select`, given two
      observations differing only in one access row, sees nothing.

## 1b. The second goal — observability sufficient for a third-party EU AI Act report

User, 2026-10-10: *"this system should provide enough observability for another tool to generate reports
for the EU AI Act."* Designed in `docs/baliveau-self-plan.md` §1a — an ENGINEERING READING of a legal
instrument, NOT legal advice: the obligations that are observability-shaped reduce to "an attributable,
durable, machine-readable record of what the system did, what changed, and who intervened", which the
substrate already largely emits (a generation IS a store path with facts; `.bootlog`; `.recovery`, which
distinguishes automatic roll-forwards from deliberate operator action; the runtime datalog; the oracle;
`fx-audit`). **And the two goals reinforce each other: a log the subject can rewrite is not a log for a
regulator** — §6b's audit stance is what makes these records evidentially usable. The gaps, to be built:

- [x] **THE CONFIG→GENERATION LINK — BUILT AND COMMITTED (`fx-init 1399dbd`; `handoff-config-link-result`).**
      `generation_config(genhash, config_sha256, origin)` a3, all-sym, written in fx-activate's
      activation txn (cleared with the other generation facts, so version-bound exactly like
      `install`/`provides`); the input is RETAINED, not merely hashed — `<genhash>-system-generation/
      config.dhall`, store-relative like `install`'s origins, written in the scratch dir before the
      rename so it publishes atomically, from bytes read BEFORE evaluation and verified UNCHANGED by a
      re-read after it (a config edited mid-activation fails loudly; A→B→A inside the window is the
      stated residual — tamper-evident, not tamper-proof, §6b). `genhash` provably UNMOVED: raw
      64-hex byte-identical pre/post change under a fixed store root (both corpus success cases,
      2 runs each), the link rides OUTSIDE `serializeGeneration`. Dumpable: `fxstore facts
      generation_config [--as-of N]` (schema row added to `RELATION_SCHEMAS`); a reporter holding a
      generation resolves WHICH config produced it and READS the input — `--as-of` walks the whole
      lifecycle chain, which is Annex IV's "changes made" question. activate_diff re-pinned (5 golden
      lines added, 0 changed), 8/8. NOT recorded (deliberate): the activation-time `--config`
      invocation path — host/cwd-relative, neither relocatable nor durable; the retained copy is the
      readable form of the same claim.
- [x] **A CHANGE AND INCIDENT RECORD, with a stated taxonomy — FROZEN IN THE REPORTER SEAT
      (COMMITTED `fx-harness bcf96fd`; `handoff-reporter-seat-result`).** `tools/fx-report.c` carries ONE
      frozen table (not scattered literals), printed as machine records on EVERY run: each event
      class, the RECORD it is read from, and — the point of the table — what the class's ABSENCE
      means, "none occurred" vs "this is not durably recorded" (a never-booted store prints
      `no-boot-ever-recorded`; `activation-refusal` prints NOT-DURABLY-RECORDED because its only
      record is rt_effect on tmpfs — "no refusals occurred" CANNOT be concluded).  Classes:
      activation (snapshots+facts), activation-input (generation_config + the retained copy),
      boot-verdict/boot-start/shutdown (.bootlog), roll-forward-automatic (.recovery rows),
      operator-intervention (DERIVED — see the seat's bound), activation-refusal (not durably
      recorded), content-recurrence (.recovery same-genhash rows).  Each classification links to
      its affected generation.  MUTATIONS in the gate disable single classes and their arms go
      blind — the taxonomy is falsifiable, not decoration.  What remains OPEN under this item: a
      change's INTENT (what was ATTEMPTED and why) is still not a substrate record — the config
      content is now readable, but nothing records the intent behind it; that is a §4 design
      decision, not a reporter gap.
      **CORRECTION (appended 2026-10-13 by the claim unit — the item above is closed and this closes
      its one remaining sub-item): that design decision is now MADE, and the intent record is
      DESIGNED.** The intent is carried as the agent's own CLAIM riding into the activation's input
      bytes (`/etc/fx-claim.tsv` row + `/etc/fx-claim.le` free-LE argument), judged by a FROZEN,
      host-released POLICY over the store's facts — **the soundness boundary being the JUDGMENT
      PREDICATE `justified` alone** (absent from the agent's closed lexicon, so only the policy
      concludes it; every refusal is by name). FIRST INSTANCE HOST-SIDE: S0 (the closed lexicon, the
      frozen policy, the evaluator and its gate — landed in the working tree, uncommitted at this
      writing) with S1's `fx-claim` seat and S2's reporter rows to follow; the IN-GUEST TARGET is
      NAMED as the qemu lane via x64 QBE through the le→Osier port of the judgment path. Recorded in
      `docs/baliveau-self-plan.md` §1a gap 2 (the corrected version); the disposition of the class in
      the reporter's frozen tables is S2's, not this line's.
- [x] **THE OPERATOR-ACTION SUBSTRATE RECORD LANDED — the two weakest rows in the frozen table
      stop being (COMMITTED `fx-init ca9cb06`; `handoff-operator-journal-result`).** The
      reporter's `operator-intervention` row was a DERIVED disjunction and `activation-refusal`
      NOT-DURABLY-RECORDED because the only record of a ctrl arm was `rt_control`/`rt_effect` in
      `/run/fx/log.db` — tmpfs post-pivot, dead at every reboot. `fx-init zig/src/init.zig` now
      writes `<store>/.operator`, an append-only journal beside `.bootlog`/`.recovery` (their
      append shape: header once, `fflush`+`fsync`+`fclose`+`syncfs_store()` per row, before the
      channel reply is flushed): one DATA line per generation-plane intervention
      (`<epoch> <action> <arg> <outcome> <from|-> <to|-> <boot-nonce>`), covering EVERY exit of
      the `activate`/`rollback`/`shutdown` ctrl arms — including the refused activation/rollback
      (`refused-config`), the store-refused rollback (`refused`), the failed activate executor
      (`failed:<rc>`), and `shutdown` — and carrying the same latched `fx.bootnonce=` as
      `.bootlog`, so rows are boot-attributable with the audit's EXISTING nonce discipline.
      `.recovery`'s semantics are untouched (still AUTOMATIC roll-forwards only; the new file's
      header says so). The header also names the paths that can NEVER reach it (host-side
      `fxstore rollback`, `--hard`, a hand-edited CURRENT) so a reader knows what its absence
      means there. Gated by `tests/qemu_operator_journal.sh` (2 arms, 3 boots each, pinned
      pre-fix control `4c5803d`; rows read OFF the raw disk with debugfs after the machine is
      killed). The REPORTER's read side — replacing the DERIVED disjunction and the
      NOT-DURABLY-RECORDED bound with rows measured from `.operator` — is the follow-up unit and
      belongs to the reporter lane, not this one.
- [x] **THE REPORTER READS THE OPERATOR JOURNAL — both weak classes are MEASURED now
      (COMMITTED `fx-harness f78d7b5`; `handoff-reporter-operator-result`).** The follow-up named in the
      item above. `tools/fx-report.c` gained a third reader beside `.bootlog`/`.recovery`: it parses
      `<store>/.operator` in the WRITER's shape (the file's own header is the definition), refuses a
      line that is not that shape LOUDLY — including a line of PROSE, which splits into seven
      whitespace fields just as happily, so the generation pair is checked against the writer's own
      vocabulary (a decimal version or `-`) — and treats the file's ABSENCE as its own state (a
      store predating `ca9cb06`), never as "no interventions". `operator-intervention` is now
      MEASURED from the rows (action, the operator's VERBATIM arg, outcome, from→to, the boot nonce,
      file+line, plus a pruned-or-foreign note when a named version is not in the timeline — a row
      is CHECKABLE against the store's history, not authoritative over it), and `activation-refusal`
      is MEASURED from the refusal outcomes (`failed:<rc>`, `refused-config`, `refused`) with its
      absence-meaning restated: "none in the RETAINED journal", not "not durably recorded" — with
      `unverified` (ambiguous — the store could not be re-opened) and `dhake-failed` (the generation
      DID land) explicitly NOT the class, so the class never out-claims its record. The DERIVED
      disjunction is RETAINED, not deleted: it is the fallback for a store with no journal AND for
      the bypass paths the journal's own header names (host-side `fxstore rollback`, `--hard`, a
      hand-edited CURRENT), and a journal row that explains a backward move is recorded as an
      ANNOTATION (`note journal-attributes-a-move-to-this-version`) — it never SUPPRESSES the
      derivation, because a row can explain a move but cannot prove the journal saw the path that
      made it. The frozen tables moved with it: two new bounds (`operator-journal-bounds`,
      `operator-bypass-paths`) replace `operator-absent-by-default`, `rt-log-tmpfs` now says the
      bound is a property of the STORE rather than of the report, and a `.operator` retention row
      was added. Gate: the JOURNAL arm (S2J, the writer's rows) is paired with the OLD arm on S2
      (no file) so the inversion is the pair — with MEASURED, without DERIVED — plus MUT-OPS and
      MUT-REFUSE blinding exactly the MEASURED arms, and two `.operator` LOUD arms. **Every
      `init.zig` citation was re-measured against `ca9cb06`** (head + ~200 lines): rt_control ctrl
      arm 3351→3490, `rt_effect activate failed` 3417→3563, `dhake-failed` 3517→3671, the ctrl
      rollback arm 3550→3706, `DEFAULT_RUN` still :32. ONE was WRONG rather than moved: the old
      "opened at :4523" named the `snfmt` line that BUILDS the log.db path — the open was the next
      line — so the citation now reads "path built :4688, opened :4689". The pin moved
      `4c5803d`→`ca9cb06` CONSCIOUSLY, after the re-measurement it exists to force.
- [x] **RETENTION: the INEQUALITY IS NOW STATED AND MEASURED ON EVERY RUN — and the POLICY decision is
      now MADE: DECIDED UNBOUNDED (user, 2026-10-12; see §1a gap 4 and the §2 item).** The reporter
      seat prints a frozen retention table per run (where
      each record lives, what it survives: reboot / roll-forward-publish / `fxstore gc`, and the
      policy column — a DECISION since 2026-10-12: UNBOUNDED, with its rationale and named cost, where
      it used to say "NO policy exists").
      MEASURED, and sharper than §1a's "unpoliced" prediction: **`fxstore gc` DELETES the retained
      configs** — the dir sweep (store.zig) has no carve-out for `<genhash>-system-generation` dirs
      and "system-generation" is never a live package name, so one `gc` run removes EVERY
      generation's config.dhall and the Dhakefile.dhall/etc the install facts point at, silently
      (the generation_config FACT survives, the copy does not).  The gate re-measures this every
      run and the frozen row goes stale-loud if gc changes.  Also measured: the runtime log
      (`rt_effect`/`rt_control`, `/run/fx/log.db`, init.zig:32/:4544) dies at every reboot (tmpfs
      post-pivot), and `rollback --hard` + a later publish can renumber over the versions between
      (the `gc --retain` guard's own statement).  OWED THEN, DECIDED NOW (2026-10-12) — a DECISION, not a
      measurement: retention for `.bootlog`/`.recovery`/`.operator` growth is UNBOUNDED BY DECISION and
      nothing sets `gc --retain N`, stated in the seat's frozen tables (§2); gc's generation-dir deletion
      is presumably a DEFECT to fix rather than policy to accept (see §3).
- [x] **THE gc GENERATION-DIR DEFECT IS FIXED — liveness is derived from the facts (2026-10-11,
      COMMITTED `fxstore c3da8ca`; `handoff-gc-carveout-result`).** `fxstore gc`'s dir sweep now reads the
      `generation` fact as-of EVERY surviving snapshot version (not just the pinned one), takes
      each buildfile_rel's first component (`<genhash>-system-generation`, store-relative —
      fx-activate's own writer), and keeps an entry only on FULL-name match; every keep and every
      reap is logged on stderr. MEASURED, both directions: a surviving snapshot's dir is retained
      across `gc` (the reporter's post-gc store is now COHERENT, exit 0) and a dir whose snapshot
      was pruned by `gc --retain 1` IS reaped, with its facts — so a pruned generation's input is
      unreportable (absence-by-retention), never a dangling fact. The reporter's frozen retention
      row, its gc-config-loss bound and the gate's GCLOSS arm were all inverted to this truth
      (GCKEEP + GREAP: the pair proves the carve-out is precise, not a blanket keep);
      `config-retained-copy-gone` stays reachable only via a GENUINELY missing copy (the FINDINGS
      arm's hand-deleted file — MUT-FINDING now blinds THAT arm). The store.zig pin moved from
      revision 0341650 to the measured working-tree BLOB (now committed as `fxstore c3da8ca`; the blob name
      is stable across the eventual commit). The POLICY decision above is now MADE — DECIDED UNBOUNDED
      (user, 2026-10-12; §1a gap 4, §2).
- [x] **THE REPORTER AS THE THIRD HOST-SIDE SEAT — BUILT AND COMMITTED (`bcf96fd`, extended by `f78d7b5`;
      `handoff-reporter-seat-result`).** `tools/fx-report.c` (`make test-report`), host-side and
      read-only like its siblings: the oracle asks *is it better?*, the audit *is it honest?*, this
      one *is it documented?*.  It READS the substrate's durable records — CURRENT, the timeline,
      the version-bound facts via `fxstore facts --as-of`, `.bootlog`, `.recovery`, and the
      retained config each `generation_config` fact names — and never becomes a source of truth
      (it never opens attempts.jsonl or any self-report; gated byte-identically absent/present/
      doctored).  Its output is STABLE and MACHINE-READABLE for the separate reporting tool the
      goal names: frozen tab-separated records, every line marked MEASURED / DERIVED / ABSENT
      with the absence's KIND stated, a `#` human summary BESIDE them, byte-deterministic (no
      wall-clock/locale/HEAD; two runs cmp-identical), and the taxonomy/retention/bound tables
      printed on every run.  THE RECONSTRUCTION (the Act's actual question) is a GATE, not a
      claim: `tests/test_fx_report.sh` builds a two-config lifecycle and asserts a reader can
      answer, from the report alone, "what changed between N and N+1, and from which input?" —
      both configs' CONTENT readable (sha chain file→copy→fact→report proven), the Myers diff
      between them, the generation each produced.  The OPERATOR-INTERVENTION derivation, measured
      from the writers: the ctrl rollback arm and host `fxstore rollback` drive the SAME soft
      rollback and append NOTHING, so the durable operator record is only the ABSENCE of the
      `.recovery` row an automatic roll-forward would have written — and the benign
      publish-of-live pair every fx-activate leaves (MEASURED) is classified apart from a real
      restore, with the disjunction (operator / re-activation of an older config / removed row)
      stated inline, never a verdict.  THE BOUND prints on every run: the tmpfs runtime log,
      operator-absent-by-default, pre-first-snapshot, the gc config loss, renumber-after-hard,
      retention-unbounded-by-decision.

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
- [x] **`.bootlog` growth — POLICY DECIDED: UNBOUNDED (user, 2026-10-12). THE ITEM IS CLOSED.** Growth
      is unbounded, fully rescanned by `bootlog_last`/`bootlog_newest_ok_below` on every boot, and
      `fsync`'d per append. The guardrail bounds growth to real boots, so the rate is events that really
      happened, and **NOTHING MAY BE DROPPED**: `bootlog_last`/`bootlog_newest_ok_below` need the newest
      `ok` below CURRENT — that IS the roll-forward TARGET — and `fx-audit`'s append accounting plus its
      previous-observation comparison need the record INTACT (a rotation reads as a REWRITE of a
      previously observed record and fires on a HEALTHY machine). So no rotate/cap/index was added: the
      DECISION is the policy, with its COST NAMED rather than hidden — per-boot work is linear in the
      file's length. `.recovery` has the same shape and the same decision (one row per AUTOMATIC
      roll-forward); **`.operator` does too**, and it is the one an OPERATOR drives, so its rate is
      theirs; `src_of` inherits the question from the other side (never reaped at all). **The reporter
      PRINTS the policy** — the five retention rows and the `retention-unbounded-by-decision` bound now
      state the decision, its rationale and its cost on every run (it used to say "NO policy exists"),
      and `tests/test_fx_report.sh`'s POLICY arm pins that text so a silent drift fails. No new machinery
      was added, and no bound was weakened.

## 3. Known defects, pre-existing, not hidden

- [ ] **`log_probe_diff`'s golden was host-dependent — FIXED, with two residuals NAMED** (`fx-init
      bb46e77`). The golden had pinned the CAPTURE HOST: the `kernel` hostname column was the real
      `uname(2)` nodename, the `file` uid/gid were the creating user's, and (suspected in the brief,
      then MEASURED) the `file` MODE was the capture host's **umask** (0027 there, 0022 here). The mask
      mechanism already existed and was simply too wide (`file` `0x1F`→`0x07`, `kernel` `0x7C`→`0x78`),
      the fixture now chmods explicitly, the goldens were re-pinned the sanctioned way, and a mutation
      in BOTH directions proves the masking is what does the work. THE TWO RESIDUALS, same class one
      level down — the columns are fixture-derived now, two VALUES/ROWS are not: (1) `process` column 5
      (`rss_kb`) = the fixture's page count × the REAL `sysconf(_SC_PAGESIZE)` (`probe.zig:197-250`), so
      a 16 KiB-page host would go red; (2) the `fs` relation's ROW SET needs `statvfs` to succeed on the
      real `/`, `/run`, `/fx/store` (`:274-289`), so a host without `/run` sees one row. And the C oracle
      is gone, so "the re-pinned golden still equals verified C behaviour" is no longer checkable — the
      asymmetry is against the previous golden only.
      **(2026-10-11: BOTH RESIDUALS CLOSED — `fx-init fed72fb`.)** `process.rss_kb` and the `fs` row set
      are now masked (`0x3F`->`0x1F`, `0x01`->`0x00`), and a THIRD instance of the class was found that
      masking alone would have missed: the driver's inline CHECKs pinned the literals `400`/`1024`, i.e.
      the fixture's page counts times the CAPTURE HOST's page size — `fixture_rss_kb()` now applies the
      same sysconf, so those checks are self-consistent by construction. All 39 dumped tokens are
      attributed to a fixture file with file:line (0 unattributed), and a fixture-perturbation run left
      both goldens byte-identical while reddening only the rewritten CHECKs. **Coverage given up, stated:
      the `fs` port now has NO harness coverage at all** (statvfs needs real mounts and cannot be pointed
      at a fixture; making the probe fixture-aware there is a different unit), and the golden no longer
      pins the rss arithmetic, which now lives in those in-process CHECKs.

- [x] **A hot-applied config that REDECLARES the agent service starts a SECOND agent instance
      mid-turn** (measured 2026-10, fx-init `svc_table_free` frees the old table's memory and never
      stops the old processes — the issuer survives, unsupervised, and is reaped anonymously; the
      rebuilt table starts every service fresh). The successor reads the record before the first
      instance exits and before the re-armed window has judged (the re-arm writes NO `.bootlog`
      line), so the verdict's C==A "readable silence" row returns RUN and the successor RE-ISSUES
      the activation — an unbounded in-boot oscillator. Closed on the harness side by the SAME-BOOT
      GUARD (`agent_main.c`: bootlog last `in-progress` version < CURRENT while the record's own
      version == CURRENT -> loud stop; `tests/test_sameboot.sh`), and CLOSED AT THE ROOT in fx-init
      (2026-10, the route-b2 fix): the config's REQUIRED `agentService` field is persisted as an
      `agent_svc(name)` store fact (activate.zig; only for `Some`, wiped by clearRel like the other
      generation facts), PID1 reads it in `read_store_facts`, and the activate/rollback channel arms
      REMOVE that row from the rebuilt table (`svc_drop_agent`, init.zig) — the sweep never starts
      it, the re-armed verdict never judges it, and the next BOOT starts it normally (the boot path
      does not drop). Belt-and-braces on the harness side: a duplicate that nonetheless reaches
      `ckpt_run_open` on a held single-writer lock now REPORTS ("RUNSTORE HELD BY ANOTHER WRITER —
      ... DUPLICATE AGENT INSTANCE") and exits 0 instead of dying nonzero into ST_FAILED
      (agent_main.c; `tests/test_sameboot.sh` cases C+D, asymmetry-proven against a pre-fix
      binary). Gated end-to-end by `tests/qemu-agent-b2.sh` ARM 1 (config1 declares
      `agentService = Some "b2verifier"`: exemption line on the console, no lock death, no DRIFT
      canary, boot-ok v_NEW in-boot). The deeper `svc_table_free` semantics (old rows freed, never
      stopped) are UNCHANGED by design — the exemption makes them harmless for the agent row; the
      option (b) residual (the re-arm appends no `.bootlog` in-progress line) remains open below.
- [x] **The activate arm's re-arm writes NO `.bootlog` line — CLOSED.** The re-armed window judged the
      new generation with no on-disk marker: a crash between activation and verdict left the next boot to
      infer the in-flight generation from CURRENT alone. The activate arm now appends
      `bootlog_append(g_current_version, "in-progress", now_s())` between the CURRENT rewrite and
      `read_store_facts` (init.zig) — the SAME word the boot path uses, so `decide_boot_version`'s
      roll-forward trigger (`in-progress|failed == CURRENT`) already reads it as stale, and no .bootlog
      grammar changes in any of the three parsers. Gated by the new `tests/qemu_svc_refuse.sh` (see below).
      (Option (b) of the original oscillator note.)
- [x] **The refused-activation path can latch a vacuous boot-ok — CLOSED (the same unit).** On PID1's
      service-table overflow refusal the table was FREED and the boot decision NOT re-armed, so an
      already-running grace window could expire over an EMPTY table and pin `boot-ok` for the generation
      PID1 had just REFUSED. The activate arm now captures `read_store_facts`' rc, widens the refusal
      branch to `(g_svc_overflow != 0 or rc != 0)` (the rc-discard was an ADJACENT hole in the same arm —
      a corrupt-store read failure fell through the same way), and on any refusal writes the HONEST
      verdict: `rt_set_boot(v,"failed")` + `bootlog_append(v,"failed")` + the latch pin, BEFORE replying.
      The rollback-refusal arm gets the same latch pin (no disk line — a rollback opens no window).
      ASYMMETRY, MEASURED on one store/image/command sequence: the treatment disk `.bootlog` reads
      `… 7 in-progress / 7 failed` with NO `boot-ok v7` and boot 2 rolls forward; the pinned `ca9cb06`
      control reads `… 7 ok` — the vacuous ok, no marker — and boot 2 re-fails on v7. New gate
      `fx-init tests/qemu_svc_refuse.sh`, cmp-guarded control.

- [ ] **The fx-audit APPEND-ACCOUNTING is now PER-VERSION, and the older per-nonce entry below is a
      historical record of the nonce unit, LEFT AS WRITTEN (append-only correction, not a rewrite).** The
      re-arm in-progress line above changed a rule `fx-audit` DERIVES from the writer's call sites, so
      the seat's rule changed with it: the boot's own first in-progress anchors a nonce, every LATER
      in-progress in that nonce must name a version first-published in the window AND newer than that
      nonce's first, the re-arm ip budget is ONE PER FIRST-PUBLISHED VERSION PER WINDOW (keyed on version
      alone — a per-(nonce,version) key re-opened a cross-nonce flip, caught by review, pinned by
      `REARMIPX`), and the per-version verdict budget's `+1` first-published credit NEVER stacks on a
      present re-arm ip. A further clause — NOT-ALREADY-BOOTED — closes the roll-forward-REPUBLISH shape
      (a version first published WITHOUT an activation has no legitimate later ip; `REARMIPREPUB`). The
      seat's threat-model header and printed bound were rewritten and NO LONGER overclaim: the surviving
      residual is NAMED there (a forged pair for a version published without an activation and NOT YET
      booted still reads as a legitimate re-arm and lands that version's FIRST verdict — reachable only
      in the operator-rollback window; it grants no verdict slot the `+1` credit did not already grant).
      Arms: `REARMIP`/`REARMIP2` (healthy, incl. the false-positive direction) / `REARMIPFLIP` /
      `REARMIPFORGE` / `REARMIPOLDER` / `REARMIPX` / `REARMIPREPUB`, each with a pinned pre-fix reader
      (`BEFORE-D`/`BEFORE-E`/`BEFORE-F`) as its fail-before. NOTE: this unit moved `init.zig`, so
      `tests/test_fx_report.sh`'s init.zig pin and every `init.zig:` citation in `tools/fx-audit.c`,
      `tools/fx-report.c` and `tests/test_fx_audit.sh` were re-measured — a whole cluster was found
      STALE (cited `:4465` for the in-progress site, actually `:4718`; `:1674` for `recovery_append`,
      actually `:932`), the same class the reporter's own pin exists to catch.

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
- [x] **`fxstore verify` reports 5 drifts on a STOCK system** — CLOSED. fx-init's `install` fact for a
      `/bin` link now records the **exact store-relative content path** — the same BINARY its buildfile
      symlinks (`activate.zig` bin-link install loop; `<hash>-<pkg>/<basename(from)>`, so the first path
      segment is still the package store dir) — and `prov_verify`'s comparison is therefore verbatim with
      NO loss of exactness (the fact was made precise; the check was NOT made tolerant). ASYMMETRY,
      MEASURED: the same stock root reported exit=1 with 5 drifts of that one class before, and exit=0
      ("verify OK", 0 drifts) after. Gated at three levels: the origin shape end-to-end by the B2 qemu
      gate (its post-restart verdict is now pinned CLEAN, with six fireable mutants of the real report,
      one per conjunct), the writer's byte shape by the corrected `activate_diff` goldens (11/11), and
      the engine's fixtures by `zig build test` (fxstore + fx-core, which share the one
      `provenance` module).
- [x] **The prescribed fix was HALF-RIGHT** — COMPLETED, not replaced: emitting
      `<hash>-<pkg>/<basename(from)>` repaired `verify`, and the readers that want the DIR now resolve it
      as the origin's **first path segment** — the rule `prov_what` already used. That is `prov_why`
      (`provenance.zig`'s `provides_targets` collection) and `fx-osier-share.c`'s install-target
      attribution (`pkg_of_dir` still takes a genuine store dir; the two-origins-one-target alt-check is
      unchanged and still fires). `prov_verify` keeps its exact comparison. Both fixture families that
      encoded the buggy DIR shape had to be corrected WITH the writer, which is what makes them
      regression-catching: the fxstore/fx-core unit fixtures and the harness's `materialize_rootfs`
      (`test_fx_audit.sh` + `test_fx_select.sh`), whose mode-0 rows previously required
      `[ -d "$store/$origin" ]` and linked the rootfs path at the package DIR.
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
- [x] **`fx_read`/`fx_ls` could resolve arbitrary paths under `FX_VERB_ROOT` — CLOSED (fx-harness
      `217c7c7` is the pre-fix pin; gate `tests/verbs-smoke.sh`, run by `bash` — there is no
      `make test-verbs` target).** The defect as measured: `native_read` and `native_ls` called
      `root_join(path)` directly, and `root_join` only CONCATENATES under `FX_VERB_ROOT`, so
      `/../<a file just outside the stub root>` returned the HOST's bytes (and a deeper chain climbed
      out of `/` and back). Fix: both verbs now take the SAME `canon_root_rel` gate `native_write`
      has — canonicalize FIRST (refusing, exit 1, naming the path and the root), then open/opendir
      the CANONICAL spelling, so no `..` reaches `open()`/`opendir()`. THE READ POLICY IS UNCHANGED:
      reads stay OPEN inside the root, and a `..` that canonicalizes to a point still INSIDE it still
      reads and lists (arm 13f; the over-refusal direction). Two consequences stated rather than
      discovered later: (a) a RELATIVE path is now REFUSED like `fx_write`'s non-absolute case (paths
      are addressed absolutely under the root; the tool descriptions say so now) — `fx_ls`'s empty
      argument keeps its documented default (the root itself); (b) it is a NO-OP in production —
      `FX_VERB_ROOT` defaults to `/` and nothing climbs above `/` — so it bites only where a non-`/`
      root is set (the stub-root tests, a jailed deployment). ASYMMETRY, RUN: arm 13g builds the
      PINNED pre-fix server (`git show 217c7c7:tools/fx-verbs-server.c`, cat-file guarded, `cmp`-proven
      to differ from the working tree) and runs the SAME escaping requests against the SAME stub root —
      pre-fix they SUCCEED and return the planted host secret, post-fix they are REFUSED. SCOPE, stated
      from the table: the verbs that `root_join` a user-supplied PATH are exactly `fx_read`, `fx_write`
      (previously gated) and `fx_ls` — the other path-shaped arguments never reach `root_join` here
      (`fx_activate`'s config is passed VERBATIM to PID1 — `activate <config>` on the fifo, or the
      fallback exec argv — and `fx_what`/`fx_why` hand their target/package string to fxstore's own
      argv), so the two named verbs were the whole remaining surface. This read bound and the write
      bound are DIFFERENT bounds and neither implies the other: `fx_write`'s surface is still the
      host-declared `FX_AGENT_WRITABLE` set, not "anything readable".
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
      branch (`zig/src/init.zig:2743-2754`) pins `failed` on ANY exit during the grace window —
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
- [x] **The two ungated oracle paths — and the 64-candidate cap — are GATED (`tests/test_osier_share.sh`
      A7/A8/A9, all three on a REAL store, no stub).** A7 (two-origins-one-install-target): two closure
      packages (`alpha`, `beta`) whose build target has the SAME basename `twins` make the activation
      emit ONE `/bin/twins` link each, so the install facts bind one target to two origins
      (`<hashA>-alpha/twins` and `<hashB>-beta/twins` — both asserted as the arm's PREMISE from
      `fxstore facts install`); a `pkg=None` service running `/bin/twins` absolutely must make the
      oracle DIE naming BOTH, and the arm also asserts it printed no share and no service row — the
      "never silently picks one" half. A8 (the `<store>/<hash>-<pkg>/` argv spelling): a `pkg=None`
      service whose `argv[0]` is an ABSOLUTE store path is resolved through the store prefix and
      COUNTED as osier-svc's bytes (run set = the measured `OSIER_BYTES`, share 1.000000,
      `nonstore_run_unattributed` still 1 for the `/bin/sh` row alone). WHICH BRANCH, pinned: the arm
      asserts from `facts install` that NO install fact names that target — so this fixture exercises
      the store-prefix else-branch, while A5 already exercises the install-target first branch. A9 (the
      64-candidate cap): 62 further rebuilds of `ambig` on the OLD-writer store (pinned fx-init
      `2feedf6`) take it to exactly 64 LIVE srcstore rows with ZERO `src_of` rows (both asserted from
      `fxstore facts` before the oracle runs), and the oracle refuses with its own cap message
      ("64+ live srcstore rows … refusing to enumerate"); an OLDER snapshot of the same store (2
      candidates, both artifacts verifying) still gets the AMBIGUITY refusal — the cap is version-bound,
      not a poisoned store. EVERY arm was shown FIREABLE by sed-mutant of the oracle: neutering the alt
      check fails A7 ("produced a NUMBER"), neutering the store-prefix branch fails A8 ("not resolved
      to osier-svc"), and moving the cap to 640 fails A9 (the refusal is no longer the CAP refusal) —
      a gate that cannot fail is not a gate.
- [ ] **The oracle gate's two LITERAL skip arms remain ungated, as does the in-guest order.** The
      `echo "SKIP (old-writer arm): fx-init 2feedf6 unavailable (shallow clone?)"` and the
      `e3eb984` pinned-oracle variant are plain echoes, NOT the exit-77 skips
      `tests/test_sibling_paths.sh` already covers (its A1-pre/A1-fix/A2-live arms run
      `test_osier_share.sh` itself, under a bogus `FX_SIBLINGS` and against the pinned pre-fix copy);
      reproducing THESE two needs a shallow clone of the SIBLING repos, so they stay open rather than
      be faked. The in-guest `done→attempt→result` order is still open for its own reason: it needs a
      qemu resume-crash fixture — a different unit, deliberately not attempted here.

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
      writer's call sites (init.zig): per host-started boot at most ONE `in-progress` (:4408,
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
      init.zig:3946 from :4482; fails if a shutdown were made to require a preceding verdict, or
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

- [x] **THE BUILD VOCABULARY — ELEMENT 1's RESIDUAL ACCEPTED (user, 2026-10-17).** 
      **DECISION: the residual STANDS, deliberately.** The remaining element 1 is a userspace reach
      bound for the in-guest build path — and the reason it can only ever be userspace is decisive:
      the pinned guest kernel has **no LSM, no namespaces and no seccomp**, so **no sandbox primitive
      exists in-guest at all** (the same fact that rules palisade out there). What it would defend is
      `attempts.jsonl`, which is a **SELF-REPORT and never evidence**, and a root agent can walk
      around any userspace bound — which is §6b's whole conclusion (*audit, do not proof; the VM is
      the boundary*). Spending here would be spending on the lever side of that line. The rest of the
      vocabulary is BUILT and gated (`fx-init 4c5803d`; the four refusals enforced by name). (§6a; CORRECTED 2026-10-13, MEASURED from the source).**
      The four elements below were listed as NOT BUILT and in dependency order; elements **2, 3 and 4
      LANDED in `fx-init 4c5803d`**, together with the recipe admission itself, so the order below is no
      longer the live queue — **only element 1 remains**, and §6b deliberately downgraded it from
      load-bearing to optional defence-in-depth (§6b's stance: audit, do not proof; the VM is the
      boundary). The landing evidence: `inlinePackages` is a real config field (`zig/src/config.zig:672-905`,
      an eleven-action mirror of fxstore's Action union at `:124-160`) merged by `fx-activate`
      (`activate.zig:1930`); the four refusals are enforced BY NAME at `config.zig:965-983` — `Shell`
      (*"one action that dissolves every other bound"*), a relative `Run` argv[0] (`execvp` with a
      recipe-controlled PATH), `Fetch` as a src, and non-empty `deps` — gated by corpus fixtures
      (`zig/corpus/inline-{good,reject-shell,reject-fetch}.dhall`, `activate/inline-{closure,collide,inert}.dhall`)
      and a zig test at `config.zig:1437`. The commit also closed a gate that had been failing OPEN
      (`activate_diff.sh`'s per-case `n.genhash.empty` marker living in the SHARED scratch dir — see the
      house rule at the foot of this file). **What the remaining element 1 still costs, stated rather
      than implied:** the in-guest build path falls back to PLAIN EXEC in the workdir
      (`fxstore zig/src/build.zig:700-760`, the sanctioned LOUD bwrap-absent fallback), so an
      agent-authored recipe's `Copy` can reach the harness's own record
      (`/fx/disk/agent-data/attempts.jsonl`) — bounded, because that record is a SELF-REPORT and never
      evidence, and because fx-init's guardrail and the host-side seats are unreachable from in-guest.
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
      2. **[x] THE ACTIVATION-TIME REFUSAL — BUILT (`fx-init 4c5803d`).** An out-of-subset action is
         refused BY NAME where the config is validated — the `agentService` pattern (`fx-init
         500fc68`), same place, same loudness.
      3. **[x] THE SUBSET AND THE ABSOLUTE-ARGV RULE — BUILT (`fx-init 4c5803d`).** `Shell` is
         excluded from the agent-authorable set (host-frozen sets keep it); `Run` requires an absolute
         `argv[0]`, no PATH search — the discipline the code already applies to itself for `bwrap`
         (`build.zig:351-354`).
      4. **[x] INLINE PACKAGES IN THE CONFIG, merged by `fx-activate` — BUILT (`fx-init 4c5803d`,
         `activate.zig:1930`)** into the package set before the closure is computed, so no new file
         becomes agent-writable.
      PREREQUISITE for all of it: `fxstore` must run where the agent does — static, x86_64-linux-musl,
      against a static libdatalog (it is currently glibc-dynamic with a `.so` dependency).
      **DONE** (`fx-harness 3b7dacc` + `fxstore 23a293f`, `tests/qemu-agent-slot-inguest.sh`): the builder
      ships in the guest payload, static and stripped.
- [x] **The agent's activation goes THROUGH PID 1 — the change is COMMITTED, not merely published**
      (`fx-harness 2818813` + `fx-init f3f60fd`). It speaks PID 1's fifo protocol NATIVELY (one atomic
      `activate <config>\n`, ≤4096 = PIPE_BUF, reply classified as `fxctl.classifyLine`, 600 s budget) —
      NOT `fxctl --fifo`, because an activation is MEASURED at 63-65 s against fxctl's HARD 5 s fifo
      poll budget, so fxctl would have returned a FALSE "no response" exit 1 on a SUCCESSFUL activation.
      MEASURED BEFORE/AFTER on one fixture (pinned `be2fbd1`): the direct exec reached only the child
      half, so the live root had no `/bin/mcp-stub-runner`; the channel route puts it there IN THE SAME
      BOOT. It also DISCOVERED a failure mode — the hot-apply's restart sweep starts a second agent
      instance mid-turn, which would re-issue the activation (an in-boot oscillator) — now guarded in
      `src/llm2/agent_main.c` (`tests/test_sameboot.sh`), and, because the duplicate could also die
      non-zero on the single-writer runstore and mark its OWN new generation FAILED (`qemu-agent-b2.sh`
      went red), the activation no longer starts the agent service at all: exempted BY IDENTITY via the
      required `agentService` field, now persisted as the `agent_svc` store fact.
- [ ] **No in-guest reboot.** The control protocol carries `status|log|activate|rollback|shutdown`
      and no reboot (`init.zig:3119-3249`); the guest tests pass qemu `-no-reboot` with the HOST
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
- [x] **The runtime-record gap — CLOSED, with a STATED SUBSTITUTION.** A direct exec of
      `/bin/fx-activate` wrote no `rt_effect("activate")`, no runtime-DB update, no hot-apply: the
      activation was recorded in the *store* but not in the *runtime record*. **A literal `rt_effect` is
      IMPOSSIBLE and the reason is structural, not a missing call:** `/run/fx/log.db` is held FOR LIFE by
      PID1 under the datalog engine's process-lifetime exclusive lock (`fxctl.zig:8`: "direct access would
      block fx-init"), nothing outside fx-init opens it, and it is tmpfs. The DURABLE record is
      `<store>/.operator`, and PID1's control handler was its only writer. So the closure puts the record
      THERE: **fx-activate now self-records a publish it commits outside that handler** (fx-init
      `1aafa4a`; a marker env in the child suppresses the double record; the predicate is marker-absent
      AND a boot nonce parses from `/proc/cmdline`, which is what keeps every offline caller silent). The
      banner that claimed "no runtime record" was itself FALSE once the self-record existed and is
      corrected. `.operator`'s header and the reporter's bound now name TWO writers — a property with an
      exception, which is the same move this design makes everywhere else.
- [x] **Per-client reply fifos — DEFERRED (user, 2026-10-17).** 
      **DECISION: stay with one request fifo + one reply fifo, single-client by CONVENTION, not
      enforcement.** The choice is **reversible and purely additive** — the request line gains a reply
      path when a second client ever exists — and no second client does. Deferring costs nothing;
      building it now would be machinery for a user that does not exist. — deferred, and the choice is **reversible** because
      it is additive (the request line gains a reply path). Chosen now: one request fifo + one reply
      fifo, **single-client by convention, not enforcement** (a second client's replies interleave).
- [x] **Trial vs accepted GC roots — DECIDED: the rule is the user's, N is OURS (2026-10-17).** 
      **THE RULE (user, verbatim): a generation that was ACCEPTED AND LATER ROLLED BACK is a TRIAL;
      one that has HELD CURRENT ACROSS N JUDGED BOOTS is ACCEPTED.** Rollback therefore DEMOTES
      unconditionally, whatever the boot count says — a generation the substrate had to undo is
      evidence AGAINST itself.
      **N = 2, and it is chosen for SYMMETRY rather than taste:** this tree already condemns on **two
      consecutive content failures** (`RECOVERY_CONTENT_FAIL_MAX = 2`, fx-init `init.zig:1050`), so two
      successes as CURRENT to ACCEPT gives the same weight on the other side of the line. A "judged
      boot" means a boot with a recorded verdict — `in-progress` is NOT a judgement and does not count.
      **THE TENSION, stated rather than hidden:** an agent that supersedes a generation before its
      second boot leaves it a TRIAL — which is CORRECT (it was an experiment) but has a consequence
      worth naming: the accepted set is the KEPT history, not the COMPLETE history. That is the right
      property for a GC root set and the wrong one for an audit, so anything that needs the full
      history must read the store, never the accepted set.
      **The number must be a NAMED, PINNED constant** (in the seat that applies it, cited to this
      entry), never a literal — the same discipline `RECOVERY_CONTENT_FAIL_MAX` gets.
- [ ] **THE IN-GUEST REBOOT (planned: `handoff-reboot-plan`).** "A reboot the machine can perform on its
      own" — decided as **`execve("/proc/self/exe")` from PID1**, which re-enters `main()` in a FRESH
      address space and so structurally eliminates the "forgot to reset a global" class (53 file-scope
      `g_*` in `init.zig`, several latched once); it works under `-no-reboot` because it is not a kernel
      reboot, and `do_shutdown()` (`init.zig:4351`) already performs the whole teardown.
      **TWO TRAPS THE PLAN FOUND, both verified by me:** (1) **rebooting inside the GRACE WINDOW silently
      condemns a healthy generation** — `decide_boot_version`'s roll-forward (`:1728-1731`) fires on an
      `in-progress` tail, so a premature reboot rolls BACK and writes a `.recovery` row naming that
      content a failure; two reach `RECOVERY_CONTENT_FAIL_MAX` and **permanently blacklist content that
      never ran**; (2) **every legitimate soft reboot would have been accused of FORGERY**, because
      `fx-audit` rests on "one nonce per PID1 lifetime" with exactly two anchors, neither of which a soft
      reboot satisfies. That is why **the READER learns the shape BEFORE the mechanism exists.**
- [x] **REBOOT S1 — the vocabulary, the reader and a PURE admission function** (**fx-init `c0aa45b`**).
      One file (`zig/src/operator_journal.zig`), `init.zig` untouched, four blob pins untouched, **not
      wired to the channel** (a verb that records a reboot it cannot yet perform is a lie in the other
      direction). **SIX outcome tokens, and the two look-alike refusals are deliberately different
      states:** `not-decided` is a **timing** (no verdict yet), `boot-failed` is a **state** (the verdict
      landed and it was bad) — both derived from the **single guard**, so the predicate and the reasons
      cannot drift. A decided-FAILED boot still refuses (the guardrail already rolls forward; the verb for
      that is `rollback`). *The sixth token was added on review*: recording a failed state under a timing
      token is exactly the "claim that misstates the evidence" shape. **Asymmetry measured:** the pinned
      pre-fix control is HEAD's module with the new tests (no vocabulary/reader/admit); `MUT-DECIDED` fails
      the undecided fixture while the admitted one passes; **`MUT-COLLAPSE`** (a failed state recorded
      under the timing token) fails EXACTLY the two token assertions while all ten behaviour tests pass —
      behaviour-blind, record-sensitive, which is the direction that matters when an always-admit function
      looks identical on the happy path. 80/80 zig tests; `qemu_ctrl`/`qemu_console`/`qemu_operator_journal`
      all PASS.
- [x] **REBOOT S2 — `fx-audit` ANCHOR (c) + the nonce invariant redefined** (**baliveau**, UNCOMMITTED).
      An **ADMITTED** (`outcome ok`) `reboot` row with the same nonce **and the same from-version**
      licenses **one reboot lifetime** — one in-progress plus the verdict that closes it. Refused rows and
      `exec-error` open nothing and are **reported by token**; unreadable rows are named and can never
      anchor. *Orchestrator-verified:* **REBOOT** stays coherent (a new PID1 lifetime under the same
      kernel boot's nonce, no host boot, `--boots` unchanged); **MUT-ANCHOR** makes the same fixture
      incoherent, so the anchor — not some other predicate — is what legitimises a soft reboot;
      **REBOOTFORGE** still accuses a pair with no admitted row (the fix did not open the hole it closed);
      **REBOOTKEY** proves it is keyed on `(nonce, from-version)`, never the nonce alone; **REBOOTREF**
      shows a refused row opening no lifetime. The hard part was ORDERING: a re-arm line and a reboot
      lifetime naming the same first-published version must BOTH land, and the first greedy implementation
      false-positived on exactly that shape.
      **NAMED, not papered over:** the anchor is **not window-scoped** (`.operator` is not in the
      observation hash), and the observation format was deliberately NOT bumped — that would refuse every
      existing baseline without closing the forgery.
- [ ] **REBOOT S3/S4 still owed:** S3 (fx-init, the wiring: `teardown()` factored out of `do_shutdown`
      with `do_shutdown` PROVABLY unchanged, the guards, the ctrl arm, `do_soft_reboot`, and a
      `tests/qemu_reboot.sh` whose blind is `MUT-NOEXEC` — admit, record, reply, SKIP the execve, so only
      the SECOND-boot assertions fail) and S4 (the REBOOT block in `fx-report`). — re-scoped by the oscillator from a *retention* question
      to a *liveness* one: trials that are accepted-and-rolled-back are noise.
- [x] **The image is a CACHE (user, 2026-10-17).** 
      **DECISION: a CACHE** — rebuildable and verifiable, with its bytes pinned. The correction on
      record is the reason this is even askable: `image.zig:40-57` measures fx-init's *image* pipeline,
      and **fx-harness's own artifacts ARE byte-reproducible and path-independent** (static + stripped
      is what makes an artifact content-addressable). A blob could only be TRUSTED; a cache can be
      REBUILT and CHECKED, which is the difference the whole pin discipline exists to preserve. (§7.5). Note the correction: `image.zig:40-57` measures
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
          `status`/`log`/`activate`/`rollback`/`shutdown` and NO reboot (`init.zig:3119-3249`; only
          "shutdown" exists), and the guest tests pass qemu `-no-reboot` (`qemu-agent-observe.sh:648`)
          with the HOST restarting the VM. So "make it effective" currently depends on something
          outside the guest, which is the same class of gap the user is pointing at.
- [ ] **LuaJIT JIT on/off in the guest**: shipped ON and gated two-sidedly; the *compiler* and
      agent-authored MCP servers are the long-running workloads that justify it. Measure per lane.
      (2026-10-10: MEASURED IN-GUEST for the x86_64 artifact — `tests/qemu-luajit.sh`'s disk marker
      carries `traces=N,0`, traces compiled with the JIT on and none after `jit.off()`, inside the
      pinned-kernel guest.  The i386 artifact's JIT remains host-measured only: that artifact cannot
      exec in this guest at all, and the v86 lane is where its in-guest numbers must come from.)

## 6. Egress (§7.1a) — the SHAPE WAS REVISED BY THE USER, and the mechanism is now built

**⚠️ SUPERSEDED DESIGN (user, 2026-10-16), read this before the items below:** *"ok, i think it should
work the same as the tool call + policies but the calls run on the host, not HTTP specific."* So egress is
**NOT a type layer**: no Dhall union catalog and no typecheck bind seat (round-1's `policy/egress/` +
`tools/fx-egress-bind.c` are **dead**). A host-executed tool call is an **ordinary `function_call` through
the SAME gate and the SAME policies**; **only the EXECUTOR differs** (forced: the guest has no socket —
the boot logs say `socket failed: Function not implemented`). The result reaches the model through the
**existing outbound substitution**, so **zero guest code**, and it is an **ordinary call row** — no new row
type and no new reporter class. **NOT HTTP-specific**: HTTP is one instance of a host tool.
*(Why it is not "just" a policy: the DECISION genuinely is only policy; the EXECUTOR must be host-side;
and the vocabulary is the one real choice — round 1 chose a type, the user chose judged arguments. That
brings back an argument-normalisation surface, which is answered by a fail-closed totality rule — an
argument matching no operator class row is REFUSED BY NAME — rather than by a type.)*
- [x] **S1 — THE REGISTRY + `host_time` END-TO-END** (**COMMITTED**). A compiled-in, sha-pinned
      **host-tool table BESIDE (not merged with)** the guest `VERBS[]` mirror, with the **existing**
      `fh_catalog_check` collision loop extended (a colliding name is a FATAL refusal before the slave
      path is published); `host_time` takes **no arguments**; the dispatch sits on the **allowed** path
      only, so **denial does not fork per executor**; an `exec` map beside the deny map substitutes the
      real result on the next request; **one new field `exec`** on the call row, no new type. Gate arms
      with real asymmetry, incl. a **pinned pre-S1 control built from `835ac49`** that crosses with the
      sentinel **UNSUBSTITUTED**. *Orchestrator-verified:* 156 OK / 0 FAIL; an **unarmed** seat does NOT
      execute (fail-closed), and an **armed-and-allowed** `host_time` really runs on the host — the row
      carries `verdict=allowed, author=denylist, exec=host` and the outcome is the actual wall clock.
      **S1 deliberately does NOT cover argument judgement** (`host_time` has none) — that is S2/S3's.
      **S1-FIX (the review's three findings, all closed).** The reviewer's verdict was that the execution
      site is **sound for the shipped policy set** and that **one effect per `call_id` is a real guarantee**
      in every probed shape — but it found a correctness defect, a forged record, and one missing witness.
      **(A) RESUME + A POLICY FLIP BROKE THE RECORD AND LIED TO THE MODEL.** *A1:* run 1 executes, run 2
      resumes with the tool denied, and the in-place verdict refresh left `exec=host` on a now-**denied**
      row — run 3 then **refused to load the seat's own log** (the P8 self-lockout class, new instance).
      *A2 (worse):* run 1 denies, run 2 resumes with the policy allowing it, the carried row keeps saying
      **denied** and the host **executed anyway** — and the outbound leg substituted the run-1 *denial*
      text, so **the model was told "denied by host policy" for a call that had just executed**, while the
      instrument stayed silent. Fixed: the refresh drops `exec`/`outcome` and removes the exec-map entry;
      the dispatcher refuses on the carried verdict. **(B) A CRAFTED LOG COULD MINT AN EXEC ROW** — an
      `exec:"host"` row with an outcome and **no verdict** loaded cleanly, substituted an attacker-chosen
      result to the model, and could *suppress* a real execution; now refused by name at startup.
      **(C)** the fail-closed unarmed property was **ungated** (deleting the guard would have passed all
      156 arms); now witnessed. *Orchestrator-verified:* 160 OK / 0 FAIL, and by my own two-run probe a
      durable **denied** row does not execute even when a later run's policy would allow it.
- [x] **S2 — THE JUDGED ARGUMENTS AND THE TOTALITY CHECK** (**UNCOMMITTED**; `engineer`). The first host
      tool that takes an ARGUMENT, and the slice where the plan's **TOP RISK** becomes concrete.
      `host_cat(path)` is a bounded host-file read that **refuses rather than truncates**. `ops_judge`'s
      gate widens from write-verbs-only to **write-verbs OR a host tool**, with the `hosttool(W)` facts
      injected **at startup from the ONE registry table** (no second list). **D3** added to
      `policy/ops/ops-policy.le` — `hosttool(W) ∧ touches(W,P) ∧ class(P,C) ∧ protected(C) → denied`,
      deny-more-only, **re-pinned with `.dl` + `PINS` + lexicon in the same commit**. **THE TOTALITY
      CHECK — the point of the slice:** a path matching **no alias row is REFUSED BY NAME**
      (`unclassed-arg`) with nothing executed, so the operator need not enumerate what is forbidden.
      **THE NORMALISER IS A SINGLE CANONICALIZER** called by both the classifying and the executing side,
      so a spelling cannot be classed as one thing and executed as another. *Orchestrator-verified:* 166 OK
      / 0 FAIL; the NO_CLASS blind makes **both** the protected and the unclassed paths **execute**; and
      the no-canon mutant's `../`-spelling **reaches the executor and reads the protected file** while the
      real build denies on the canonical path. An over-cap file is refused, never read partially.
      **⚠️ ONE GUEST CHANGE, AND IT IS THE FIRST IN THE WHOLE CHAIN:** `tools/fx-verbs-server.c` gained
      **one line** — `dl_declare_relation(OPS.db, "hosttool", 1)` — because the datalog engine refuses an
      undeclared predicate (MEASURED, stated in the file) and the artifact is **shared**, so both seats
      must load the same pinned file. D3 is **INERT IN-GUEST**: the in-guest seat declares the relation
      and **never injects a `hosttool` fact** (verified — only the declaration appears there), so it keeps
      D2 and adds no host-tool denial of its own. The alternative was splitting the artifact per seat,
      which would double the pinned files and invite drift.
      **S2-FIX — the review found a BLOCKER, and it was the slice's own top risk reached by a SUPPORTED
      CONFIGURATION rather than an attack.** With a **denylist-only** config (the gate's own phase-71
      shape) the ops seat is absent, `ops_judge` returned OK, and the executor gated only on "some policy
      is armed" — so `host_cat` on a **protected** file **returned its content to the model** with a row
      reading `allowed+exec=host`. **The totality check silently vanished whenever the classifying seat
      was not armed.** Fixed: the gate is now *"the side that judges THIS argument ran"*, not *"some
      policy is armed"*, with `author=unarmed` — the ABSENCE refused, never the operator (a row saying
      `ops` would claim an author that did not run). It covers both named configurations (no dir, and
      **loaded-but-inert**). *Orchestrator-verified by invoking:* denylist-only, `host_cat` on
      `/fx/disk/agent-config.dhall` → `denied / author=unarmed / refusal=unarmed-ops`, no `exec`, nothing
      ran. **Also fixed:** the class governed the SPELLING while the **open followed the kernel** — a
      data-classed **symlink** to a protected file returned the protected content (now `O_NONBLOCK|
      O_NOFOLLOW` + `S_ISREG` on the *opened* fd, refused by name); a **FIFO hung the whole proxy**
      (`rc=124`, SIGTERM needed, no deadline — P10's discipline had not been carried); **NUL content was
      silently truncated** (now refused by name); the judge **ignored the registry's `arg_key`** and
      hardcoded `"path"` — harmless today but it would have left **S3's `fetch` URL neither classed nor
      totality-checked** (now read from the registry, with a startup refusal for an entry that declares a
      read and no classed key); and the path itself is bounded so record and wire agree. **One residual
      is PINNED as a machine-visible arm rather than left as prose:** a **hardlink** is a regular file at
      a classed name, so a data-classed hardlink to a protected inode still reads it — unfixable by
      spelling, stated in the executor, and phase 92b fails if it ever changes silently. The implementer
      also **corrected the reviewer**: the suggested "D1+D3 inert in-guest" wording is wrong — D1's four
      facts ARE injected in-guest; the correct split is **D1+D2 live, D3 inert**, now named on that
      seat's own startup line.
- [x] **S3 — THE HOST TOOL IS A DECLARED PROGRAM, WITH POLICY PARITY OF MECHANISM** (**UNCOMMITTED**;
      `engineer`). **THE USER CORRECTED THE SHAPE TWICE, and both corrections made the design smaller:**
      first *"the same as the tool call + policies but the calls run on the host, not HTTP specific"*, then
      *"why are we building in http as a special thing when it could be handled by the standard host tool
      policy/calling with a binary or something?"* — **so there is NO HTTP IN THE PROXY.** A registry entry
      is now a **DECLARED PROGRAM** `{name, program, args, arg_key, reads_arg, deadline_ms, out_cap}`, and
      the **one executor is a spawn** following `mcp_client.c`'s proven discipline (fork + `execve` with a
      PATH-only scrubbed env, pipes, an explicit deadline and output cap). `http_get`, `host_time` and
      `host_cat` are now **standalone binaries**, so P10's client stays the MODEL UPSTREAM's alone and
      egress is not shaped around one protocol.
      **THE GUARD THE USER ADDED, AND I FIRST GOT IT WRONG:** *"i dont mean apply the guest policy to host
      tool calls, i mean allow the same mechanism, policies for host calls."* So the agent config's
      `enabled_tools`/`disabled_tools` are **NOT** mirrored onto host tools — that is a guest-harness
      dimension. What IS required is that a host call is judged by the **same `call_judge`, the same
      authors, the same order, the same denial path and row shape**, with **no executor-specific policy
      hook**. Phase 100 proves it: the SAME call denied through **each** author host-executed — the
      `--deny` placeholder, the operator's D3, the totality `unclassed-arg`, the justification, and the
      claim judgment — plus the asymmetry that compiling one author out lets it execute.
      *Orchestrator-verified:* 194 OK / 0 FAIL; **gates rc=0**; and the program contract is proven —
      **argv is argc=1 (the program only), and metacharacters reach the program VERBATIM on stdin, never
      on the command line**; a hanging program is killed at the deadline, a flooding one is REFUSED at the
      cap (never truncated), a non-zero exit is a REFUSAL (never a silent success), a missing program is
      refused by name; and `http_get` refuses https / 3xx / non-http / IP literal / over-cap BY NAME.
      **THE COST, stated in the source and here:** "run a declared program" is a **much larger lever** than
      "the proxy does a GET", and on the host there is no VM to bound it — what restrains it is the
      pinned, operator-authored registry, the scrubbed env, the cap, the deadline and the log, **not the
      executor's narrowness**. **THE SEAT FOR SANDBOXING IS LEFT AND NOT BUILT** (user: *"later, we can use
      palisade"*): the spawn is the one place a future sandbox attaches, one comment, no speculative hook.
      *Guest code unchanged this round;* the only guest-facing edit is 3 lines of STAGING so the pinned set
      includes `ops-hosts.tsv`.
- [x] **S4 — THE RECORD AND THE ORACLES** (**UNCOMMITTED**; `coder`). The slice that answers §7.1a's own
      residual: *"every oracle in the family must be able to SEE capability changes … otherwise the agent
      satisfies the oracle while quietly widening what it can reach."* Egress now ships a real
      host-executed capability, so S4 makes it visible to the seats that judge generations.
      **`fx-report`**: a `call-exec` row on every judged call (host rows MEASURED from the log's own
      `exec` field — a row carries its own reading, never re-derived from today's registry), plus the
      **WEAKENED difference audit** as its own rows: `reach-pin` per PINS artifact, **`pin-drift`** (a
      finding carrying BOTH pins), `reach-row` per pinned class row with `exercised YES|NO|NOT-KNOWN`, and
      **`stale-class-row`** — a stale GRANT, i.e. a revocation question. A missing log, policy dir, PINS or
      mapping is **NOT-KNOWN, never "none", never "stale"**. Its exercised attribution *mirrors* the
      proxy's canonicalizer rather than sharing it — and that mirroring is a PRINTED BOUND, not a
      footnote.
      **`fx-select`**: REACH-DELTA becomes order step 6, naming `reach-delta` rows and a loud
      `egress-reach-widened`. **The disqualification consequence is left OPEN and PROVEN open** — the
      decision, the table and the exit code are byte-identical with and without it, and the row says so in
      its own bytes. That is the reversible choice the plan asked for, made visible instead of implied.
      **`fx-audit`**: `proxy-log-record` (the host log as a KNOWN RECORD — bytes+sha, prefix re-hashed, so
      truncated/rewritten/vanished are findings) and `egress-reach` (reach recorded beside the boot the
      audit ran after; a released widening is *named*, an unreleased one is `reach-widened-unreleased`).
      **`fx-osier-share`**: **STATES its §7.1a blindness** as its own output line, names where the sight
      lives, and does **not** let it enter the share — the honest resolution the plan chose, with nothing
      patched in.
      **DO NOT OVERCLAIM — carried into the rows themselves:** this is the **WEAKENED** audit (pinned
      tables + registry as "declared"), not the type-enforced one round 1 would have given.
      *Orchestrator-verified:* all suites rc=0; the report's mutants blind their own arms (the exec field
      ignored → host reads as guest; the stale-grant row disabled; the mandated **join on the drifted
      pin**); `fx-select`'s S4-reach/S4-reach-mutant pass in the enforced order; and the osier arm proves
      the blindness is stated WITHOUT entering the number.
      **Declared scope extension:** +30 lines in `tests/test_osier_share.sh` (that tool's only gate) so the
      blindness statement is asserted rather than merely printed.

- [ ] **PALISADE SANDBOXING** — the user's ask: *"do palisade - we should be able to configure the sandbox
      via policies in datalog or dhall, vendor palisade so we can make changes to it if needed"*. Plan:
      `handoff-palisade-plan`. **The "datalog or dhall" question is SETTLED and must not be re-opened:** the
      **operator's datalog/ops policy owns the spec**, because the proxy is the only process at the spawn
      and already evaluates that policy in-process, while a per-generation Dhall spec would be evaluated
      guest-side and be **invisible to the per-boot record**. Dhall has no role in v1.
- [x] **S0 — VENDORED + BUILT HERE** (`0f2174f`). `vendor/palisade/` holds the **source** (13 files,
      `cmp`-identical to the fxstore copy) with `VENDOR.txt` recording the origin repo/commits and the
      statement that this tree owns its copy. Built here via cosmocc into `build/stage3` and **pinned**
      (`vendor/palisade/PINS`); `make palisade` refuses on drift, two clean builds agree — including across
      a different absolute path. **The fxstore dependency is GONE and that was PROVEN:** with an empty
      bind-mount over the fxstore checkout the build still succeeds at the same sha. `stage-guest.sh` now
      stages this tree's build and keeps its LOUD refusal with NO fallback.
- [x] **S1 — `host_time` IS SANDBOXED, AND THE GATE PROVES A SANDBOX IS REAL** (`6dc963f`). Per-tool
      compiled-in floors; the spawn wraps `execve(stage3, [PROMISES, LANDLOCK, --, prog…])` keeping the
      scrubbed env, deadline and cap; a `sandbox` row field rendered through the **same one-spelling
      helper** the argv is built from, so row and argv cannot drift — *a grant you did not record is not
      auditable*. **The floor is MEASURED and is the LEAST that works.** Both layers proven BOTH
      directions against a pinned pre-S1 control: Landlock (`/etc/hostname` → EACCES inside, read through
      the old proxy) and seccomp (`socket` → EPERM inside, created through the old proxy). **And the
      mandated blind `FH_MUTANT_NO_STAGE3`:** the wrapper compiled out, the escape mutant reads the file
      **through a call whose row claims a sandbox** — spec-loaded-but-NOT-applied, caught on the wire.
      *Measured divergences:* the vendored pledge returns **EPERM, not SIGSYS** (the plan's assumption was
      wrong; the SIGSYS branch is still built and proven wired), the loader needs `:rx` not `:r`, and
      `/etc/hostname` is 0 bytes here so the proof is the open succeeding.
- [x] **S2 — THE SANDBOX IS NOW CONFIGURABLE BY POLICY** (**COMMITTED**, `6dd6395`).
      `policy/ops/ops-sandbox.tsv` (`tool<TAB>promises<TAB>landlock`) whose header states the author,
      **SILENCE = THE FLOOR** (there is no "unsandboxed" state to fall into), **DENY-MORE-ONLY**, and that
      rlimits are deliberately not here; it ships **EMPTY**, so every tool gets its floor.
      `eval_ops.py --check-sandbox` is **grammar only** and both headers say so — the authority is the
      seat's own **floor ∩ row** composition, so there is ONE spelling and the python check never
      re-spells the registry. The per-call judged-path unveil threads `ops_judge`'s **canonicalized** path
      to the spawn: the judge stays the ONE canonicalizer, no second spelling.
      *Orchestrator-verified:* **tightening works** (a dropped landlock path is judged allowed, the open
      then fails EACCES and the refusal is recorded), **loosening is refused** (a promise beyond the floor
      is a STARTUP REFUSAL naming the row — "a row may only NARROW, never widen"), the
      **`FH_MUTANT_NO_SANDBOX_TABLE` blind** is caught (row ignored, the forbidden path READ, the `sandbox`
      field showing the floor), and the **sibling-path escape** is EACCES post-fix while the pinned pre-S2
      control reads it.
      **Stated divergence:** landlock unveils the **path**, not a symlink's target, so `O_NOFOLLOW` stays
      load-bearing for symlinks while the sibling path *is* landlock-blocked — complementary defences, both
      stated. Also: the spawn bounds the judged path to `FH_HOST_PATH_MAX` before unveiling, because an
      over-long model path would overflow stage3's 512-byte `LANDLOCK_SPEC` before the executor's own
      length refusal ran.
- [x] **S3 (REVISED) — THE SANDBOX IS STRUCTURAL TO THE EXECUTOR, AND THE HTTP TOOL IS DROPPED**
      (**UNCOMMITTED**). **The user corrected the shape and the code had already admitted the defect:**
      the floor-validation comment said *"a NULL floor is a not-yet-migrated tool, not an empty sandbox"* —
      i.e. S1/S2 made the sandbox **opt-in per tool**, and `--print-sandbox` showed an **empty floor for
      `http_get`, the only network-capable tool**, which therefore ran **completely unsandboxed**. User:
      *"why do we need to sandbox the tools individually? it shouldnt be like that."* They are right:
      **sandboxing is a property of the EXECUTOR.** Now: `promises_floor`/`landlock_floor` are **gone from
      the registry struct**; `host_exec` computes `wrap = 1` unconditionally (only the
      `FH_MUTANT_NO_STAGE3` blind zeroes it); the **BASELINE** (`stdio rpath exec prot_exec` + loader `:rx`
      + libc `:r`) belongs to the executor and is applied to **every** spawn; extra capabilities come from
      **a sidecar beside the tool binary** (`<program>.sidecar`, one `promises<TAB>landlock` line), read
      and validated at startup. **THE FAILURE DIRECTION IS INVERTED, which is the real fix:** forgetting a
      declaration now means **baseline only** (no network, no write) and a **loud first refusal**, instead
      of silently running bare. The operator table still only **tightens** (row ⊆ baseline+sidecar).
      **`fx-http-get` IS GONE** — source deleted, registry entry and arms removed, the policy-parity arm
      re-pointed at `host_cat`; HTTP returns later as a declared program (host curl or similar) with an
      `inet dns` sidecar.
      *Orchestrator-verified:* 207 OK / 0 FAIL; **104b** the same socket mutant **succeeds once its sidecar
      declares `inet`** (the capability comes from the tool, the wrap from the executor); **104c** the
      write-escape probe — `O_WRONLY` → **EPERM**, since `wpath` is in no baseline; the `FH_MUTANT_NO_STAGE3`
      blind still caught; missing-`stage3` still a startup **and** per-call refusal with no unsandboxed
      fallback; and no tool currently ships a sidecar, so both run on the same baseline.
      **Two real bugs found beyond the brief:** a latent Makefile defect (`:=` `BIN_*` definitions placed
      *after* the prerequisite list that used them, so those prerequisites expanded **empty** and two
      mutant binaries were never built on a clean rebuild — the gate died at phase 0 and I diagnosed it
      before resuming); and the S2 judged-path unveil dying on a `;`-containing non-existent path in the
      echo-contract probe (now skips non-existent / spec-delimiter paths, fail-closed).
- [x] **S4 — THE RECORD SIDE: A SANDBOX CHANGE IS A CAPABILITY CHANGE, AND THE ORACLES SEE IT**
      (**UNCOMMITTED**). Closes §7.1a's rule for the sandbox: *a change to the wrap, the baseline, a tool's
      sidecar or the operator's tightening row decides what a host tool may do, so it is a capability
      change and must be visible to the seats that judge generations.*
      **`fx-report`**: the row's `sandbox` field is now a **column of `call-exec`**, with three states kept
      apart — host+field = MEASURED (what the spawn applied), host **without** the field = `NOT-KNOWN`
      (pre-S3, never "unsandboxed"), guest = DERIVED. New rows: `sandbox-composed` (per tool, from the
      proxy's own `--print-sandbox`), `sandbox-recorded`, `sandbox-pin` + a **`sandbox-pin-drift` FINDING**
      (both shas), and `sandbox-delta` per tool with the direction NAMED — four absence records, so a
      missing proxy / policy dir / pin is NOT-KNOWN and never "unchanged".
      **`fx-select`**: `reach-sandbox` as ORDER **step 7** (additive to step 6), with
      `sandbox-reach-widened` and **the consequence proved open** — winner, decision and exit code are
      byte-identical with and without it.
      **`fx-audit`**: a per-boot `sandbox-spec` / `sandbox-composed-sha` / `sandbox-boot` line and a new
      `sandbox-record` check naming a change against the audit's OWN previous observation.
      **THE MANDATED BLINDS, BOTH CAUGHT:** the **widening-blind** build (the addition re-derived from
      today's proxy instead of the record) reads **NONE while a sidecar declared `inet`**; and the
      **join-on-the-drifted-pin** build reports the operator sandbox table as **MATCH while it drifted** —
      the quiet release, caught.
      **NOT OVERCLAIMED:** the composed spec has **no released-widening path** (the operator table is
      deny-more-only and cannot widen `--print-sandbox`, and neither the baseline nor a sidecar is pinned),
      so every widening takes the loud side and a legitimate sidecar widening is a **stated false
      positive**. And visible ≠ strong: promises are coarse, confinement is per-process, no uid drop —
      printed as bounds in all three seats.
      **THREE BUGS FOUND, MEASURED, FIXED**, one of them **pre-existing at HEAD**: `test_fx_select.sh` was
      already broken because S3 emptied `ops-hosts.tsv`; plus the **same `:=`-definition-after-its-use**
      defect S3 hit (prerequisites expanding empty), and two instrument bugs of its own (a decomposition
      that dropped the baseline's trailing `libc:r` and produced a **false widening on an unchanged
      sandbox**; and an observation reader keeping the line terminator, firing INCOHERENT on every
      unchanged composition).

- [ ] **THE OLD DESIGN ITEMS BELOW ARE NOW LARGELY SUPERSEDED** (kept for the reasoning they carry):
      **A closed, host-owned catalog of network PRIMITIVES** (`http.get`/`http.post` + allowed hosts,
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

- [x] **A purpose-built i386 kernel** with virtio-console *and* ATA — BUILT and GATED. The lean demo
      kernel has `# CONFIG_PCI is not set`, and the pinned qemu kernel is **x86_64** while v86 cannot
      boot 64-bit; v86 also has **no virtio-blk**, so the guest's disk has to be ATA. The recipe is
      `fx-demo/kbuild/build-v86guest.sh` (commit `9255c43`): `kbuild/build-lean.sh`'s fragment
      **verbatim** (the 20-line `./scripts/config` invocation is byte-identical, python-proved) plus a
      second invocation carrying BLOCK/BLK_DEV/PCI/SCSI/ATA/ATA_PIIX/ATA_GENERIC/BLK_DEV_SD/
      VIRTIO(_MENU/_PCI/_CONSOLE) and the ext4+CRYPTO chain — every disk-path driver `=y`, **zero
      modules**. MEASURED: two COLD podman `debian:stable` builds are byte-identical (vmlinuz
      `f0278a8f`), toolchain-scoped as stated. Gated by the native port's own **two-leg oracle**
      (`souche tests/gate-m2-5.sh`, C port vs the pinned JS reference): both reach the ATA disk
      (`ata1.00`, `[sda]`, `sda1`, m2-3's pinned md5) AND the virtio console (`console [hvc0] enabled`,
      `11: N XT-PIC virtio0`, host→guest read-back), while the pinned lean kernel reaches neither.
      **ONE SYMBOL THE PLAN'S DELTA LIST DID NOT NAME**: `CONFIG_BLOCK` — tinyconfig leaves it OFF and
      it is the PARENT of SCSI, the ATA menu and the whole `if BLOCK` fs menu, so without it five
      named symbols silently resolved UNSET; the recipe's own fatal assert caught it on the first cold
      build.
- [x] **`/dev/hda` in fx-init** alongside `/dev/vda`, plus the harness device wiring — BUILT. The
      device is **`/dev/sda`, not `/dev/hda`** (MEASURED: libata names it that way; souche's M2-3 saw
      it first), so `pick_disk_dev()` became a probe over `[vda1, vda, sda1, sda]` with **vda first**
      so the qemu lane stays byte-inert (its kernel builds no ATA driver). The fallback keeps the
      pinned `no /dev/vda — using ramfs store` line **byte-identical**. Gate
      `fx-init tests/qemu_disk_probe.sh` (24 assertions) with a real fail-before (the pre-fix binary,
      cmp-proved to differ) and host arms proving the host's own `/dev/sda` is never touched. The
      browser lane wires the disk as `hda:{buffer}` in `fx-demo/harness` (commit `f10adee`) — **not
      `{url}`**, MEASURED: v86's url path writes into a JS block cache that dies with the emulator, so
      only `{buffer}` can reboot in place. Persistence is proven by an **in-place reboot**
      (`harness/persist.mjs`: boot 2 mounts, is not re-seeded, and the ledger grows with boot 1's bytes
      as a prefix), and the fail-before is the shipped pre-disk pair via `harness/control-ramfs.sh`.
- [x] **THE BUSYBOX (AND FX-CORE) ARE OUT OF THE GUEST — 2026-10-13, the user's decision.** The disk
      image briefly carried a static i386 busybox for fx-init's disk path, and the artifact we shipped
      **carried `sh`, `ash` AND `hush`** (MEASURED `busybox --list`) — a live shell inside the guest
      whose containment claim (§2, above) is "no `sh`, no `bash`, no busybox". Fixed at the root:
      fx-init's four shell-outs are NATIVE now (`rm_rf` / `copy_tree` / `rename(2)` / `syncfs_path` in
      init.zig), a blank disk is a **LOUD REFUSAL** (formatting is a BUILD condition — the host mkfs's
      the file image unprivileged; only MOUNT is a host limit), and `fx-demo` ships neither busybox
      nor the 63-binary fx-core payload — the image's only un-provenanced blob (no `provides`, no
      `src_of`). Gate: `fx-demo/harness/check-shell-free.mjs`, whose `--mutant` arm re-stages a
      busybox and requires the gate to flip. Cost, ACCEPTED: the demo has **no terminal**. The
      verdict survives for a reason worth writing down: the store is activated from
      `m3/config-good.dhall`, which declares NO console service — a DECLARED service whose binary is
      absent is an EXEC failure and fx-init fails the boot on that BY DESIGN. MEASURED the hard way:
      the first rebuild kept `config-console.dhall` and booted `fx-init: exec failed` /
      `boot-FAILED v3`; the "fx-init ignores a console service's exit" rule covers a user typing
      `exit`, not a missing binary.
- [ ] **THE DEMO'S TERMINAL — DEFERRED, the user's own terms: install fxsh THROUGH THE SYSTEM DHALL
      CONFIG as a package.** That is the route that makes it attributable (`provides`, `src_of`, the
      oracle can see it), instead of `mkinitramfs.sh -b` copying binaries from a host bindir beside
      the store's knowledge. Until it lands, `fx-demo/harness/assert.mjs`'s terminal-driven rows
      (materialization, pipeline, `/tmp`, the ledger read-back) and `harness/persist.mjs`'s `cat`
      step stay RED — the boot-verdict, pivot, disk-mount and no-ramfs-fallback rows still run.
      Nothing else was touched to make them pass, and the gates are NOT marked skip: a red gate that
      names its reason is the record.
- [x] **Determinism** (§7.3) — the NATIVE lane's half is CLOSED; the browser lane's half is
      OUT OF SCOPE BY CONSTRUCTION. The requirement: v86's RTC is host-fed, device identity comes from
      `Math.random`/`getRandomValues`, and `Date.now()` appears in the network stack — patch those three
      sites, or always enter from a hashed `restore_state` snapshot; the *agent* path can never be
      hermetic, only the *build* path. **MEASURED, and the brief's premise was wrong:** two boots of the
      pre-fix binary already produced BYTE-IDENTICAL transcripts — the residual was one level in, SIX
      boots giving SIX DIFFERENT INSTRUCTION COUNTS over one transcript, because the host-fed RTC changes
      how the guest PACES ITSELF. Closed in `souche` (the native port) by the port's own D-F2 timebase
      (1 instruction = 1 µs) on a FIXED epoch, and by RDRAND always taking its seeded arm (a per-run
      seed would be host entropy by another route, and the guest can OBSERVE RDRAND). Item three of the
      list is vacuous there: no NE2K/virtio-net, and `clock_gettime` now appears in no file under `src/`.
      Gate `souche tests/gate-m2-5-determinism.sh` (two boots byte-identical in serial, virtio AND
      instruction count), with the RTC as the attributed cause by CONTROL (RTC back on the host clock
      with RDRAND fixed -> the counts differ again). **The browser lane cannot be patched** — `v86`'s JS
      is this project's READ-ONLY reference and fx-demo ships its unmodified build — so its route is
      `restore_state` or nothing, and that is a separate decision, not owed here.

---

## 8. The claim/policy layer, and the HOST PROXY as the tool-call gate

**Design record: `docs/baliveau-self-plan.md` §7.6** (added 2026-10-14 — read it first; this section is
the status, that one is the design). The layer answers §1b's last open item (**a change's INTENT**) and
§1a's AI-Act gap 2. The shape: the agent **pre-registers a claim** (a free-*Logical English* argument
over a closed, host-declared lexicon, compiled by `le` to datalog); a **frozen host-side policy**
judges it; **claim + verdict + outcome are one record** and the **disagreement** is the instrument.

- [x] **S0 — the lexicon, the frozen policy and the free-LE evaluator** (`baliveau 94f773b`). The
      soundness boundary is **the judgment predicate alone**: the agent's lexicon declares no
      `justified`, so only the host's policy can conclude it. Gate `make test-claim-policy`, 36 arms;
      the boundary is proved by EXECUTING the breach (the mutant that adds `justified` *and* drops the
      head check lets the agent derive it itself). **A measured seam finding carries**: LE constants are
      letters-only, so a policy that naively spells a runtime symbol matches NOTHING = a silent
      allow-all.
- [x] **S1 — the judge seat** (`tools/fx-claim.c`; `baliveau f409025`). Five rounds, every one a
      MEASURED blocker in the same class (*what counts as a LANDING*): first-appearance version joins;
      the op-row half; the `activate`-only landing filter; the unjournaled landings. The last closed by
      DECISION: `bound<TAB>unjournaled-landings` prints on every run — the seat judges JOURNALED
      landings, and the AUTOMATIC `.recovery` roll-forward, host-side `fxstore rollback`, `--hard` and
      a hand-edited CURRENT are NOT judged (M8 proves the bound can be missing). Gate `make test-claim`,
      21 arms.
- [x] **S2 — the reporter's claim class** (`baliveau fbc2316`): `claim-record`/`claim-verdict`/
      `claim-disagreement`, absence meanings BOTH directions, and the **`claim-evaluator-location`**
      bound row (host-side today / in-guest via a port is a DEPLOYMENT difference with identical
      semantics — the row exists so the location can never silently become a reason to shrink the
      language). A review found the parser's *stated* over-long-field property **false for the last
      field** — a truncated value printed as `MEASURED` — now a full-exhaustion refusal.
- [x] **S3b — the enforcement at fx-activate** (fx-init, **UNCOMMITTED**): the pinned policy embedded
      byte-exact, the `claim : Optional Text` field arming it, the `refused-claim` outcome, and
      `tests/claim_refuse.sh` 21/0 (absent, malformed, id-mismatch, spine-lie, differs-guard,
      unknown-from-version each activate pre-fix and are refused BY NAME post-fix). `init.zig` was NOT
      touched, so the four blob pins are unbroken. **⚠️ ITS PLACEMENT IS SUPERSEDED — see below.**
- [x] **The operator allow/deny policy** (`policy/ops/`, `baliveau e2ebb39` + the C seat `ec4bc1d`):
      a second, visibly distinct author — the operator says *"you may not do this"*, the host says
      *"this is not justified"* — with **DENY-MORE-ONLY** (user, 2026-10-14) and the lexicon closure
      enforced both ways. Its review found an **operator-reachable silent allow**: alias patterns were
      exact-match globs while validation checked only absoluteness, so a rule that *looked* protective
      never fired for any child — now a stated AND enforced two-form grammar. **⚠️ THE C SEAT'S
      PLACEMENT IS SUPERSEDED — see below.**
- [x] **⚠️ THE ARCHITECTURE CORRECTION (user, 2026-10-14) — the enforcement moves OFF the VM.** *(APPLIED: it is what P1–P10 built.)*
      **The model generation is host-side; the tool calls are ALREADY IN THE PROXIED MODEL STREAM; the
      HOST records them and runs the policy; and A DENIAL IS THE CALL'S ORDINARY MCP TOOL RESULT**
      (`role=tool`, the same call_id, the content the denial and why) — so the model needs NO special
      training and no schema change, it is just MCP. The shape is already in the tree:
      `src/agent/agent_loop.c:800` returns `"(tool disabled)"` as the tool result and does not dispatch.
      **SUPERSEDED AS PLACEMENT, NOT AS MACHINERY:** S3b's attachment (the claim should ride WITH THE
      CALL, in the same model turn — which also makes "BEFORE" structural) and the C seat's in-VM
      denial (an in-VM lever; the agent is root). **AND THE `le`→Osier→Lua PORT IS DISSOLVED**: the
      evaluation is host-side, where `le` already runs.
- [x] **THE OWED PIECE: THE HOST PROXY — IT NOW EXISTS** (`tools/fx-hostgate.c`, built across P1–P10;
      the design record above said it was owed and NOT built, which was true when written and is now
      SUPERSEDED). The canned SSE file (`usr/fx-agent/chardev.sse`, the offline arm, staged by
      `tools/stage-guest.sh`) is no longer the only provider: the proxy serves it as the CONTROL arm and
      itself speaks both a canned fixture and a live HTTP endpoint. It owns the model endpoint, the
      headers, the credential, the two-author policy, the deny map and the ONE LOG — the natural home the
      record predicted.
- [x] **THE DESIGN DECISION — SETTLED (user, 2026-10-14), and it is NEITHER of the two candidates
      first put.** Both are **REJECTED**: (a) *the loop stays in the guest and the host MARKS the
      verdict* is **UNSOUND** — user, verbatim: *"in that design there is nothing stopping the harness
      from simply executing tool calls, the host has no say whatsoever"* (the host could annotate and
      afterwards detect; it could not PREVENT — its executor would be the governed component); and (b)
      *the host owns the loop* is an **over-read** — the host does not take over the loop.
- [x] **WHAT IT IS: THE HOST REWRITES THE DECODE STREAM AT THE BOUNDARY — BUILT (P1–P10).** User: *"the host ALREADY
      owns the decode stream, since the model engine is on the host (or via an endpoint from the
      host)"* — *"the host can simply detect the model's outputted tool calls in the decode before they
      even go into the harness in the guest and run the policy against them. Accepted ones go through
      fine into the harness which executes them, rejected are replaced with a rejection response. As
      far as the harness in the guest is concerned it looks like a normal decode stream."* **MEASURED:**
      the host sees BOTH legs (`src/agent/fx_transport.c:57-85` — the guest writes its request and then
      READS on the same fd), so the denial can reach the model as *the call's own result*.
      **MEASURED:** the guest already refuses a call by NAME without dispatching
      (`tool_policy.c:85-97` + `agent_loop.c:770-830` → `"(tool disabled)"`), and empty
      enabled/disabled lists are **ALLOW-ALL** — so the guest-changeless form is a mid-stream NAME
      rewrite, with the lane's config excluding the reserved name; an allow-all lane would defeat it
      SILENTLY. The rewrite's mid-stream safety, the config pre-condition and what the guest's own
      transcript then records are **open** — round-2 plan `handoff-hostgate-plan2`.
- [x] **P3 — THE DECODE GATE (H2) + THE OUTBOUND SUBSTITUTION** (**UNCOMMITTED**; routed to `engineer`, the
      soundness-critical slice). The invariant: **for a denied call the TRUE VERB NAME never crosses the
      chardev into the guest** — args cross deliberately (they are the intent record), the `call_id`
      crosses untouched (the join key). A denied call's `name` becomes `fx_host_denied` in every event
      carrying it; on the guest's next request the host **restores** the true name and **replaces** that
      call's `function_call_output` with the denial text. 25 gate phases; verified by orchestrator: 26 OK
      / 0 FAIL, `make test` green, zero guest change.
      **THE REVIEW FOUND A REPRODUCED SILENT ALLOW** — the exact class ranked first in the review brief.
      `serve_stream` had a **single** open-item accumulator, so an **interleaved** second `function_call`
      (`added(B)` before `done(A)`) was merged under A's identity, judged under A's (accepted) name, and
      forwarded **verbatim**: the *denied* verb's true name crossed and **dispatched** — rc 0, logs
      protective. Fixed by a **per-item** open-item list keyed by `item.id`, judged at its own `done`,
      with `-DFH_MUTANT_SINGLE_ITEM` pinned as the pre-fix control. Round 2 confirmed **the class
      closed** (8 crafted streams; ASAN/UBSAN/LSAN clean) and found three residual fail-opens from
      `function_call` events **outside** the `added→done` window — `completed`'s array with an item still
      open; `done` for a never-opened item / duplicate `done`; and an **oversize `added` served verbatim
      under a false "event skipped" note** (the only one dispatchable by today's guest). All three fixed
      and gated. *Reproduced independently by the orchestrator:* pre-fix serves `name: fx_write` on the
      wire; fixed serves none. Stated residual: a stream-end flush of a held `added` still forwards it
      verbatim but **loudly** — safe, since name-only-at-`done` makes the guest dispatch nothing.
- [x] **P4 + P5 LANDED** (**COMMITTED**). **P4:** a built-in **13-verb catalog** mirroring the real
      `VERBS[]`, sha256-pinned, verified at startup with a mirror of the guest's `validate_identifier`
      charset; `fh_catalog_check()` runs **first in `main`, before the slave path is published**, and
      **refuses to start** on a collision — because a collision makes the "reserved" name **callable**,
      which is a silent allow. *Orchestrator-verified by invoking:* the catalog is an **exact match** to
      what the real `build/fx-verbs-server` advertises over `tools/list`, and the collision build exits
      rc=1 naming the cause with no slave published. **P5:** `--require-justification` injects a `tools`
      array (`required:["justification"]`) into the forwarded frame and judges each call on the
      **delta-accumulated arguments**; absent/malformed → denied **by name** through the existing P3
      rewrite + outbound substitution; plus a **denial-rate instrument** so "an effectively dead agent
      whose logs read as protective" is *visible* rather than inferred.
      **The review found a real bypass, reproduced end-to-end:** the judgment fell back to
      `output_item.done`'s `item.arguments` — **a field the guest never reads** (its only fallback is the
      `function_call_arguments.done` *event*, `openai_responses.c:171-180`) — so a crafted stream made the
      host judge a call **justified** while the guest accumulated nothing. *Reproduced by the
      orchestrator:* the pinned `doneargs` build crosses `get_weather` and records `allowed`, the fixed
      build crosses `fx_host_denied` and records `denied`/`absent-justification`. The fix makes the host
      judge exactly the accumulator the guest emits; **the orchestrator verified the mirroring line by
      line** (`fx-hostgate.c:2074-2089` — deltas append in order, the `.done` event's `arguments` only
      when no delta arrived — matching the guest), so the review's divergence was not traded for a new
      one. The reviewer's verdict otherwise: **the name invariant is sound in every constructed shape**,
      and the three earlier fail-opens remain closed.
- [ ] **THE STATED RESIDUAL:** this closes the **tool-call channel** only — a root agent in the guest
      can still run things directly, outside any tool call (§6b: *auditing, not proofing*).
- [x] **P10 — THE REAL LANE** (**COMMITTED**; `engineer`). The proxy gains an **HTTP(S) upstream**
      (`--http`; endpoint/key/timeout from env, the key sent only in the Authorization header and **never
      printed, logged or crossed**), with a native plain-HTTP client (non-blocking connect+poll, per-read
      and total deadlines, a **32 MiB cap** (see the CORRECTION below), close/content-length/chunked
      framing), and — required — a **LOUD NAMED SKIP
      (exit 77)** when the endpoint is absent, unreachable, https or malformed. The canned-file arm stays
      **byte-identical** (it is every existing phase's control). A live unauthenticated OpenAI-compatible
      endpoint serving the **Responses API over SSE** exists on this host at
      `http://10.0.0.1:8321/v1/responses` (I probed it directly; the canned fixtures were plainly recorded
      from it — same field set, same `parallel_tool_calls: true`).
      **THE THREE QUESTIONS THE REVIEWS PARKED ARE NOW MEASURED — this was the slice's real value:**
      **(a) A LIVE PROVIDER DOES NOT INTERLEAVE.** Driven into three calls in one turn, the provider echoes
      `parallel_tool_calls: true` but **serializes** the items on the wire (`added(A) → args.done → done(A)`
      fully closes before `added(B)`). So the P3 review's biggest unmeasured risk **does not reach the guest
      from a natural stream here** — the per-item buffers are **defence in depth, not a live-lane fix**.
      **(b) THE INJECTED TOOLS SCHEMA IS HONORED:** with the proxy's exact 13-verb array (`justification`
      REQUIRED) the model emitted a well-formed justification on **every** call — and on a denied call
      replayed with the denial text it **acknowledged the denial, did not blind-retry, and pivoted to other
      verbs**, folding the denial into its later justifications. That is the design property ("the model
      needs no special training") **observed against a real model rather than asserted**.
      **(c)** The live lane POSTs **exactly** the buffer `outbound_pass` returns — `cmp`-asserted against the
      `--dump-requests` record (P3's SHOULD-FIX 4, closed).
      *Orchestrator-verified:* offline `make test-hostgate` rc=0 (135 OK / 0 FAIL) with the 4 loud-skip arms;
      **live** `make test-hostgate` rc=0 with phase 72 running — `LIVE observed: 1 call decoded; 1 denied;
      0 allowed`; and my own skip probes return rc=77 naming the reason, with *"never a silent green"* in
      the message. **RESIDUALS, owned and stated:** https is **refused loudly, not implemented** (the
      configured endpoint is plain http; hand-rolled TLS would be the silent-wrong surface); the live
      measurements are **n=1** — real, repeatable via phase 72, **not** a proof of invariant provider
      behaviour.
      **P10-FIX — the review's three should-fixes, all closed.** The verdict was that the lane is **sound
      for its stated invariant** (no silent allow on any of 16 hostile-response probes under ASAN/UBSAN,
      the key boundary clean), but its **liveness signalling** was broken. *Orchestrator-verified by
      invoking, with my own broken endpoints:* a response with **no HTTP status line** → was rc 0
      (a SILENT GREEN), now **rc 1** *"did not answer HTTP (unrecognized status line) — refusing to serve
      it"*; a **lying `Content-Length`** → was rc 0, now **rc 1** *"closed mid-stream — 20 of 9999
      Content-Length bytes arrived"*; a legitimately **close-delimited** response still **rc 0**, and the
      guest's stream now **begins `event: response.complete…`** rather than `HTTP/1.0 200 OK…`.
      **CORRECTION (appended, not silently fixed):** the "32 MiB cap" I claimed in the P10 commit message
      was **wrong by 2×** — the check fired only *after* the doubling, so the real cap was **64 MiB**
      (the review measured 35,651,655 bytes accepted at rc 0). The check now tests before the doubling, so
      the documented number is the real one. The commit message cannot be corrected in place; this is the
      correction of record. Also fixed: a **credential embedded in the endpoint URL** was printed verbatim
      in skip notes (now redacted, and userinfo in the endpoint is **refused by name** — the credential
      comes from `FX_HOSTGATE_KEY` only, and the key was verified end-to-end to reach only the POST's
      Authorization header); and **phase 72 no longer passes trivially** when the live model makes no call
      (a distinct WARNING, with the LIVE observation folded into the PASS echo — deliberately not a hard
      FAIL, which would flake against a live model). A defect was also found and fixed mid-pass: returning
      an interior pointer from the header-strip made the caller `free()` it and the proxy aborted.
- [x] **P9 — THE REPORTER'S CALL CLASS** (**COMMITTED**; `coder`). The problem it solves: the host gate
      delivers a denial by rewriting a call's name to `fx_host_denied` and substituting a denial text, so
      the **guest's transcript records the rewritten name and a generic sentinel and never learns the true
      verb** — meaning the host's one log is the ONLY place the true name, verdict, author and reason exist
      together, and nothing joined it back to what the guest recorded. `tools/fx-report.c` gains
      `--proxy-log` + `--transcript` and a `call` class following S2's claim class **shape** (not a second
      one): the **triple by `call_id`** — `call-record` (the CLAIM = the justification from the call's
      args, verbatim), `call-verdict` (author + refusal, `allow-scope` carried **verbatim**, **no fabricated
      verdict** — no verdict field is `NOT-RECORDED`, never `allowed`), `call-outcome` (the replayed
      `function_call_output`) — plus **`call-disagreement`** and **`call-join`**.
      **THE DISAGREEMENT IS THE DELIVERABLE**, and I read it out of the gate's own artifacts:
      `call-disagreement  call_00_DgJf…  host-name get_weather  guest-name fx_host_denied  host-verdict
      denied  host-author denylist  host-refusal denied-by-denylist  guest-output "(tool call failed)"` —
      the true verb the guest never learned, recovered by the join. **ABSENCE IN BOTH DIRECTIONS**, each a
      FINDING with its own stated meaning: `call-join … host-log-only FINDING bound "the host decoded and
      judged this call; the guest transcript holds NO tool_call with this call_id (a rewrite miss, a crash,
      or a transcript from another run — NOT 'no call occurred')"`. The echo telemetry
      (`unjoined-output` / `echo-anomaly` / `unresolved-substitution`) is surfaced as records with **no lane
      stop**, the deliberate G7 demotion, stated at the site. The reporter only ever `fopen`s the log
      **read-only**, and the gate asserts **byte-identity in and out**.
      **DECISION (mine), on the two calls the implementer surfaced:** an unknown row type is a fail-closed
      exit 2 (a reporter that silently skips a row type it does not know is the "instrument that cannot see"
      failure), and a join-direction absence increments `g_findings` (exit 1) rather than being a mere
      record — both KEPT, because in this check the absence really is an anomaly, and the row states so.
      **I did NOT commission a review round for this slice** — it is the one read-only, non-enforcing seat in
      the chain, and I verified its triple, its disagreement and both absence directions myself out of the
      gate's kept artifacts. That is a judgement about risk, not a verification result.
- [x] **P8 — RESUME, AND THE ONE LOG AS JOIN STATE** (**COMMITTED**; `coder`, then a review round and a fix
      round). **THE DEFECT I MEASURED FIRST, and it was not what the plan expected:** the log was rendered
      by an atomic whole-file rewrite from an in-memory array that started **empty and was never read
      back** — so **a second run with the same `--log` WIPED the first run's record** (reproduced: run 1
      wrote `call_RUN1 denied`, run 2 left only `call_RUN2 allowed`). That contradicted the code's own rule
      at `log_flush`: *"a record that silently stops is the one failure mode this seat must never have."*
      **Fixed:** `log_load()` parses an existing log at startup as a **gate before the slave path is
      published**, prior rows survive, the **deny map is rebuilt** so a resumed run's old denied items are
      restored and substituted on the outbound leg, replay is idempotent, and a corrupt/truncated log is a
      **loud refusal leaving the file byte-identical**. *Orchestrator-verified:* both rows now survive a
      restart; a non-JSONL file, a torn tail and a hand-edited row each exit rc=1 with a precise diagnosis
      and no slave published.
      **THE REVIEW: the load path is SOUND FOR ENFORCEMENT** (no loadable log can make the seat *allow*
      anything — the decode-leg judge never consults the log), but *structure* was strict while *content*
      was trusted. **Five reproduced should-fixes**, all now fixed: a crafted 1 MB `denial_text` +
      `true_name` loaded verbatim with no policy armed (**R1**); the seat's **own** arm appending a row per
      re-served call, leaving three rows for one `call_id` and a phantom unresolved entry (**R2** — and
      phase 5/12's pins had to move, since they pinned the old semantics; arms intact, only the expected
      counts changed); **quadratic load** (100 K rows → 89.7 s, 200 K → a refusal whose recovery *lost* the
      join state it protected — now 0.188 s) (**R3**); non-regular `--log` (**R4** — a FIFO **silently
      hung**); and the loader **re-
      wording a carried row's `allow_scope`** from the *current* run's seats,
      making the record claim a judgement another run made (**R5**).
      **HONEST MISMATCH, REPORTED NOT RECONCILED:** my own probe of R1's headline — a crafted 1 MB log row
      reaching the model — shows the model-facing output bounded and **marked**
      (`...[TRUNCATED from 1048576 bytes]`, 512 B) in **both** the fixed build *and* the `loadunbound`
      mutant, so I could **not** reproduce the reviewer's 1,048,576 through that path: the bound that
      matters is applied at *substitution* time, and the load bound must address a different consumer (the
      held field / the re-rendered row). The property that mattered holds; the mutant's claim is narrower
      than I can confirm.
- [x] **P7 — THE CLAIM AUTHOR** (**COMMITTED**; `engineer`, then a review round). The second and last
      policy author: `policy/calls/` mirrors S0 ([`calls-lexicon.ini`] closed over the agent's vocabulary
      with **no judgment predicate**, `calls-policy.le` frozen/host-authored as the **only concluder**,
      `calls-policy.dl` + `PINS`, `eval_calls.py` mirroring `eval_claim.py`'s file-based interface, `le`
      consumed as a host-side dependency), and the proxy judges each call's justification with it
      (`author=claim`, denial through the **existing P3 path**). **THE RULE:**
      `justified(C1) :- contention(C1,W1), call_name(C1,W1), call_purpose(C1,P1), !forbidden_purpose(P1)`
      — the agent's contention must **derive** (vacuity falls out of the least fixpoint), and
      `call_name`/`call_purpose` are **seat-injected facts, never the agent's word**.
      **THE REVIEW'S VERDICT: THE SOUNDNESS BOUNDARY IS INTACT** — the frozen host-authored policy is the
      only concluder of `justified` on every enumerated path, and the two-author partition is enforced by
      `le`'s **closure** in both directions. *Orchestrator-verified by invoking:* a mutant agent lexicon
      with `justified` added is **REFUSED rc=1** naming it exactly, while the real lexicon lints clean and
      prints the absence explicitly (`judgment-in-agent-lexicon=absent`). The review also settled a
      question I raised: agent-derived `forbidden_purpose` can only **self-deny**, and what is actually
      **load-bearing is the HEAD CHECK, not negation semantics** (with it dropped, an agent rule
      concluding `forbidden_purpose` flips a real derivation).
      **THREE HOST-SIDE SHOULD-FIXES, one a REPRODUCED SILENT ALLOW** (none agent-reachable, all fixed):
      (1) **`eval_calls.py` was not pinned** — replacing it with an always-`derives` script armed the seat
      and let the forbidden `fx_activate` **cross verbatim and EXECUTE** with the log reading
      `allowed/claim`; the seat pinned its *inputs* but not its *judge*. Now pinned and verified at
      startup. (2) **no timeout on the per-call subprocess** — a `sleep(600)` evaluator stalled the whole
      seat with **no log row**, leaving the denial-rate instrument (the dead-agent detector) blind. Now
      bounded, with the timeout a **recorded** refusal. (3) **duplicate folded verb-symbols** passed both
      `--check-verbs` and the C loader, so a shared symbol justified both runtime verbs and the rule's
      demand #2 stopped discriminating. Now refused at both sites. *Verified by the orchestrator:* a
      swapped evaluator is refused rc=1 with `sha256 mismatch`, never prints `ARMED`, never publishes the
      slave path; and the new bound is validated `[1,3600]` from **operator env only** (invalid → loud
      die), so it can never be set to "no timeout".
- [x] **P6 — THE OPERATOR AUTHOR AT THE HOST SEAT** (**COMMITTED**; `coder`, then a review round).
      The in-guest ops evaluation is **ported** into the proxy beside P3's `--deny` placeholder, which
      stays and stays honestly named `denylist`. **THE D1/D2 SPLIT, confirmed from the rule text and
      NAMED in the startup line:** **D1** (`touches ∧ kind(write) ∧ class(P,C) ∧ protected(C)`) needs only
      host-derivable facts → **LIVE at this seat**; **D2** adds `writable(P)` and `!boot_verdict(ok)` —
      live in-guest state no host reader can see → **INERT by construction** (the seat never injects those
      facts), **STAYS IN-GUEST** in the demoted C seat. The seat also states plainly that it **has no floor
      of its own and does not claim one**: an ALLOW here means *"no operator denial at this seat"*, never
      *"the write is permitted"*. **THE REVIEW'S VERDICT: the D1 denial path is SOUND and the D2 inertness
      claim is TRUE** — all seven adversarial probes clean, including a 47-case mechanical diff showing the
      host canonicalizer is **equivalent** to the in-guest one, and the path-key binding sharing one
      interned id (the "plausible spelling that matches nothing" seam is closed here).
      **The one real finding was RECORD HONESTY:** an `allowed` row rendered `verdict=allowed/author=ops`
      with the seat-scoped qualifier living only in the **transient stderr startup line** — so the durable
      artifact `fx-audit` reads *at rest* outlived its own qualifier and read as a permission the seat
      never grants. Fixed with a NEW `allow_scope` key (deliberately not `reason`, which phase 12 asserts
      null on allowed rows) and **gated** so the honesty property is asserted, not documented.
      *Orchestrator-verified by invoking:* the armed allowed row carries `allow_scope`; with no policy the
      row carries **no** verdict field; a write to the protected `/fx/disk/agent-config.dhall` is rewritten
      to `fx_host_denied` with `author=ops` and a reason **quoting rule D1**, while the unprotected
      `/fx/disk/agent-data` crosses as `fx_write`.
      **DECISION (mine):** `allow_scope` is emitted on **every** allowed row, not only ops-authored ones —
      the risk it addresses is generic to any allowed row, and its "this seat" names the **host gate seat**.
      **GOTCHA RECORDED:** `make` alone does **not** build the `build/fx-hostgate*` binaries; only
      `make test-hostgate` does — so a restored source with a stale proxy binary still in place measures
      the OLD build. Always let the gate rebuild, and hash-verify after any source mutation.
- [x] **P1 — THE PROXY SKELETON / TRANSPARENCY** (`tools/fx-hostgate.c`, `tests/test_hostgate.sh`,
      `Makefile`; **UNCOMMITTED**). Gate `make test-hostgate`; the arm/control pair is the transparency
      proof. **MEASURED, AND IT CORRECTED THE PLAN:** the plan said `downstream=FIFO` — **a single FIFO
      opened `O_RDWR` SELF-READS** (the guest consumes its own request frame; it parses as SSE with no
      recognised events → synthesized `FINISH` → empty result at rc 0 — LOUD BUT FLAKY, and flaky is not
      a transparency proof). A **PTY pair** is the faithful chardev stand-in (`lseek` → `ESPIPE`, exactly
      what `fx_send_request` already ignores). Second measurement: **the pty ldisc buffer is 4096 B and a
      proxy that EXITS drops kernel-staged bytes** — the guest sees a silent 4095-byte truncation
      indistinguishable from EOF. *A close is a truncation channel.*
- [x] **P2 — THE ONE LOG + THE JOIN** (**UNCOMMITTED**). One JSONL row per call, bounded, single writer;
      joined by `call_id` against the guest's next request (`function_call_output`, no new channel).
      Nine gate phases; **BOTH directions asserted** (a real two-turn run RESOLVES the call_id; an
      unfireable join is REPORTED by call_id), so a join that never fires cannot pass. **NO `verdict`
      field is emitted** — no policy has run, and a row saying `allowed` would be a claim wider than the
      evidence. Two orchestrator findings were routed back and fixed: the bound was applied to only two
      of four model-controlled fields (`true_name` landed at 2000 B unmasked — **proved by invoking**),
      and the bound was **ungated**; now `call_id` (the join key) renders verbatim by decision, and the
      over-long-field arm flips a clean pass to a fail (`-DFH_MUTANT_NO_BOUND`).

---

## House rules this session earned (each cost something real)

- **A gate that has to be TOLD to re-measure is worth building, and a citation into a file that MOVED
  is a FINDING, not a renumbering job.** `tests/test_fx_report.sh` pins the working `fx-init
  zig/src/init.zig` to the revision its frozen tables were measured against, and it only passes while the
  two are EQUAL — so any change to that file fails the gate with "the citations are STALE; re-measure and
  update". It fired when the operator journal grew `init.zig` by ~200 lines, and the re-measurement found
  a citation that was **wrong rather than shifted**: the bound said the runtime log was "opened at
  `:4523`", and that line *builds* the path — the open is the next line. **A drifted line number that
  still points at something plausible is a lie that survives proofreading.** If a document cites another
  file by line, pin the two together so drift is loud.

- **Masking the INSTRUMENT is not masking the ASSERTION — check where else the value is asserted.** The
  `log_probe` golden was maskable column by column (twice), and the third instance of the same
  host-dependence was NOT in the golden at all: the driver's inline `CHECK`s pinned the *capture host's*
  page size as the literals `400`/`1024`, so a 16 KiB-page host would still have failed with every golden
  masked. When a value is host- or environment-derived, ask **where else it is written down** before
  believing the fix is complete.

- **A record you introduce is not more authoritative than its writer.** The operator journal's own header
  says *"Root in-guest can forge or truncate it exactly as it can `.bootlog`; a row is CHECKABLE against
  the store's version/genhash history, not authoritative over it"* — and the reporter carries that bound
  INTO the class it feeds rather than upgrading it to a fact. A new durable record is an opportunity to
  state a fresh bound, not a licence to raise the confidence of everything downstream.

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
- **A per-case marker file in a shared scratch dir leaks across cases.** `activate_diff.sh`'s
  `n.genhash.empty` was never cleared between cases, so after the first failing case every LATER
  case — including succeeding ones — took the no-generation branch: the genhash golden and the
  raw-hash idempotency check silently no-opped for every case after the first failure (the
  `idempotency` case included, since `svc-no-closure` ran before it). Found while adding the
  inlinePackages cases: my succeeding fixtures pinned `genhash.empty` goldens. Fixed by clearing
  the marker at the top of `run_side`; the fix UNMASKED the idempotency case's assertions (it had
  been green with them inert). Same shape as the "budget compared after charging" class: a seat
  that exists and is never read on the deciding path.
