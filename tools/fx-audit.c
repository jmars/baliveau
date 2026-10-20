/* tools/fx-audit.c — the AUDIT SEAT of the baliveau harness.
 *
 * SIBLING OF THE ORACLE (tools/fx-osier-share.c), and it inherits the
 * oracle's three properties (design record §7.1): HOST-SIDE, AGENT-
 * UNWRITABLE, and a function of OBSERVABLE SYSTEM STATE.  It lives on the
 * host for the same reason the oracle does (§6b): the agent can write ANY
 * file in the guest — there is no CONFIG_SECURITY, no CONFIG_SECCOMP, no
 * CONFIG_NAMESPACES in the pinned kernel, so NOTHING in-guest can be
 * proofed — and an in-guest auditor would be auditing a witness the
 * suspect can edit.  The host is the one writer the agent cannot reach.
 *
 * WHAT IT IS: the detector half of "auditing, not proofing" (the user
 * decision of 2026-10-10): let the agent try to cheat, but SEE it and STOP
 * it -> rollback.  Rollback was already built (`fxstore rollback [--hard]`,
 * fx-init's roll-forward, the hold-at-current backstop); what was missing
 * is the thing that reads an INCOHERENCE and acts.  This tool is that
 * reader.  The act is deliberately SEPARATE (--rollback below): the seat
 * stays a SEAT — readable, assertable, and never a thing that mutates the
 * audited system as a side effect of being asked a question.
 *
 * WHAT IT READS — several records written by DIFFERENT WRITERS AT DIFFERENT
 * TIMES, which is what makes incoherence visible with no sandbox: one
 * doctored file cannot make them agree.
 *   <store>/.bootlog                  fx-init, per boot:   "<v> <status> <epoch>\n"
 *   <store>/.recovery                 fx-init, per automatic roll-forward:
 *                                     "#"-header + "<epoch> <published> <from-failed> <genhash|->\n"
 *   <store>/.db/snapshots/CURRENT     fxstore:             the current version number
 *   `fxstore facts <rel> --as-of N`   fx-activate's version-bound facts (TSV)
 *   --proxy-log FILE                 the host proxy's ONE LOG, taken as a
 *                                     KNOWN record (its bytes are recorded in
 *                                     the observation and the previously
 *                                     observed prefix must still hash the
 *                                     same: a truncated or rewritten host log
 *                                     is a TAMPER finding, a deleted one is a
 *                                     record REMOVED — the host's own account
 *                                     of what it ran, which no in-guest record
 *                                     can be)
 *   --proxy BIN / --ops-policy-dir DIR  the DECLARED REACH this observation
 *                                     measured (the proxy's compiled-in
 *                                     registry + the operator's pinned class
 *                                     tables), recorded BESIDE the boot the
 *                                     audit ran after and compared with the
 *                                     previous observation: a widening whose
 *                                     tables still hash to PINS is a RELEASE
 *                                     (named), one whose tables do not is the
 *                                     incoherence `reach-widened-unreleased`
 *   --proxy BIN (also)                the COMPOSED SANDBOX of this host (the
 *   + --ops-policy-dir DIR            proxy's own `--print-sandbox`: the
 *                                     executor baseline + each tool's sidecar),
 *                                     recorded per boot with a sha and compared
 *                                     with the previous observation: any ADDITION
 *                                     is `sandbox-widened-unreleased` — the
 *                                     operator table is DENY-MORE-ONLY and cannot
 *                                     widen the composition, and the baseline and
 *                                     the sidecar are pinned by NOTHING, so no
 *                                     release can license one.  A narrowing is
 *                                     named and is not a finding
 *   `fxstore verify <rootfs>`         fxstore: rootfs vs the install facts, exit 1 on drift
 *                                     (REUSED, never reimplemented)
 *
 * IT NEVER OPENS attempts.jsonl OR ANY OTHER HARNESS SELF-REPORT.  The
 * harness's record lives inside the guest and the agent can reach it; it is
 * an efficiency layer for the agent's own loop, never evidence for the
 * substrate's stop-and-roll-back (§6b).  The gate pins this property: the
 * same incoherent store with that file absent, deleted and doctored must
 * reach the SAME verdict.
 *
 * ── the previous-observation comparison (the load-bearing part) ──────────
 * The cross-checks above catch an INCOHERENT tamper only: a generation that
 * rewrites ALL of its own records consistently is invisible to any
 * in-guest-style cross-check — by design.  What it cannot undo is what the
 * host already recorded OUTSIDE the disk.  So this seat PERSISTS its own
 * observation of the store (content hashes of the append-only records, a
 * hash of every published version's facts, the timeline, the source-
 * artifact set) and compares on every run.  A rewrite of history surfaces
 * as a DISAGREEMENT WITH THE PREVIOUS OBSERVATION, named as that.
 *
 * THE OBSERVATION STORE: a plain text file under --obs-dir (default: the
 * environment FX_AUDIT_OBS_DIR, else the sibling directory <store>.fx-audit-obs),
 * one file per store, keyed by a hash of the store's absolute path.  A
 * directory INSIDE the store is REFUSED — the observation must not live on
 * agent-reachable disk.  A FIRST-EVER run ENROLS: it records what it sees
 * and compares nothing (stated in the output, never silent).  The
 * observation is rewritten ONLY after a COHERENT verdict, so a tampered
 * store keeps reporting incoherent on every run until someone acts on it;
 * --re-enroll (and the post-rollback trigger) reset the baseline.
 *
 * ── the named incoherences (one assertion, one message, one fixture each) ─
 *   recovery-without-failure   a .recovery row whose from-failed version has
 *                              no failed/in-progress verdict in .bootlog
 *   verify-drift               fxstore verify exits 1 (an unmanaged rootfs
 *                              file, a missing/mutated target, a moved link)
 *   facts-path-gone            a fact of the current generation names a
 *                              store path that is not there (a provides dir,
 *                              an install origin, a svc_bin binary, the
 *                              generation's own buildfile/dhake)
 *   version-chain              CURRENT unparseable or not a published
 *                              version; the install facts' genhash differs
 *                              from the generation fact's; a .recovery row's
 *                              genhash differs from the generation's as-of
 *                              its published version
 *   bootlog-damaged /
 *   recovery-damaged           a TERMINATED line in a file only fx-init
 *                              writes that is not the writer's shape
 *   disagreement-bootlog-rewritten / -recovery-rewritten
 *                              the append-only record's previously observed
 *                              bytes are no longer a byte-prefix (rewrite or
 *                              truncation) — the COHERENT-tamper catcher
 *   disagreement-facts-changed a published version's facts hash differs
 *                              from the previous observation (history was
 *                              rebuilt between audits)
 *   disagreement-artifact-gone a <src_hash>-<name>-src artifact the previous
 *                              observation saw is gone (a src_of binding
 *                              whose source artifact is gone)
 *   record-vanished            a record present at the previous observation
 *                              (.bootlog / .recovery) is now absent
 *   bootlog-forged-verdict     an ADDED ok/failed verdict with NEITHER an
 *                              ADDED in-progress for that version wearing
 *                              the SAME nonce in the same window NOR the
 *                              store's own record that the version was
 *                              first published in the window (the two
 *                              writer paths: a boot that verdicts booted
 *                              the version — in-progress first; a boot that
 *                              ACTIVATED the version in-guest — the re-arm
 *                              verdicts it with no new in-progress) NOR —
 *                              anchor (c) — an ADMITTED .operator reboot row
 *                              carrying the SAME nonce whose from-version is
 *                              that version, licensing a SOFT REBOOT LIFETIME
 *                              (see THE NONCE INVARIANT below).  No boot the
 *                              host started is behind such a line (the
 *                              appended "<failed v> ok" that would stop
 *                              fx-init rolling forward).  A TORN
 *                              (unterminated) verdict is judged by the same
 *                              attribution, never rejected on sight: with an
 *                              added in-progress answering for it, the torn
 *                              line is NAMED and tolerated (a crash
 *                              mid-append, not tamper).
 *   bootlog-fabricated-boots   ADDED in-progress / shutdown / recovery
 *                              lines outnumbering the boots the HOST
 *                              reports starting since the previous
 *                              observation (--boots delta), or — the nonce
 *                              form — one nonce carrying more than its one
 *                              boot's in-progress/shutdown/row budget, or a
 *                              verdict on a nonce no in-progress wears, or
 *                              — the verdict form — one VERSION carrying
 *                              more ADDED verdicts than the in-progress
 *                              lines behind them plus the one the in-guest
 *                              activate re-arm can add
 *   disagreement-proxy-log-rewritten / record-vanished
 *                              the host proxy's ONE LOG was truncated or
 *                              rewritten in place, or deleted, between
 *                              observations — the log is append-only, so a
 *                              shorter one is a record CUT, and a missing one
 *                              is a record REMOVED (never "no call was made")
 *   reach-widened-unreleased   what this host can REACH grew between
 *                              observations (a new host tool, a new pinned
 *                              class row, or a protection removed) and the
 *                              declaration behind it was NOT RELEASED: the
 *                              tables do not hash to PINS.  The same widening
 *                              WITH a correct re-pin is a RELEASE and is
 *                              NAMED, not a finding — a re-pin release is how
 *                              reach is supposed to change.  §7.1a's covert
 *                              direction, made an incoherence
 *   bootlog-unbound-nonce /
 *   recovery-unbound-nonce     an ADDED line/row carrying no nonce the host
 *                              issued for a boot in this window (no field,
 *                              the "none" placeholder, a nonce from an
 *                              earlier window, or one never issued) — in the
 *                              harness regime (every window boot nonce-
 *                              covered) this is the forged line-PAIR shape;
 *                              in a mixed/manual regime it is named, not a
 *                              finding
 *
 * A record that cannot be READ is its own LOUD state (exit 2), never a
 * silent pass — this repo has already paid for "a read error read as
 * absence" (414b26c).  A record that cannot be read IN FULL is the same
 * class, for the same reason: .bootlog and .recovery are parsed into fixed
 * tables (g_bl[4096], g_rec[1024]), and a line past the table would be
 * dropped from the counting AND from the forged-verdict attribution while
 * the run still printed a verdict — so an over-long record is exit 2,
 * naming the cap, the file and the line, instead of an audit of a truncated
 * view.  ABSENT is a recorded state, not an error: a store
 * that has not booted yet has no .bootlog, and absent-at-enrollment is
 * legal (growth absent -> present is a transition, presence -> absent is a
 * finding).
 *
 * NOT CHECKED, DELIBERATELY: .bootlog lines naming versions that are no
 * longer in the timeline.  `fxstore gc` legitimately prunes old snapshots
 * while .bootlog is append-only and outlives them, so that direction
 * cannot distinguish a forged line from a pruned version.  Stated here so
 * nobody reads its absence as an oversight.
 *
 * ── the trigger ──────────────────────────────────────────────────────────
 *   fx-audit --rollback [<v>]  run the audit; REFUSE on a coherent store
 *                              (never fires on a clean system); on
 *                              incoherence call the EXISTING machinery —
 *                              `fxstore rollback --hard <v> --store S` (the
 *                              minimal, auditable move: repoint CURRENT at
 *                              a known-good generation; the next boot and
 *                              fx-init's own verdict machinery do the rest)
 *                              — LOUDLY, naming every finding that caused
 *                              it, then re-enroll the observation against
 *                              the post-rollback state.  <v> defaults to
 *                              the newest version whose last .bootlog
 *                              verdict is ok (marked UNTRUSTED when the
 *                              bootlog itself is one of the tampered
 *                              records — the operator decides then).
 *
 * ── the host-boot accounting (the appended-line blind spot, closed) ──────
 * The comparison above catches REWRITES but cannot treat "the content
 * changed" as a finding, because LEGITIMATE growth is expected: fx-init
 * appends to .bootlog on every boot.  So an APPENDED forged line in the
 * writer's exact shape was invisible — and it defeats the substrate's own
 * recovery: fx-init's boot decision (bootlog_last, init.zig:784) reads the
 * LAST non-shutdown status for a version, so an agent that APPENDS
 * "<its failed version> ok <epoch>" makes the next boot read that version
 * as ok, fx-init does NOT roll forward, and the broken generation stays
 * current.  Epoch monotonicity cannot separate it (genEpoch is
 * wall-clock/env-overridable; skew would false-positive).
 *
 * THE ANCHOR: the host is the hypervisor — it knows every boot it started,
 * and that knowledge is OFF-DISK and unforgeable from inside the guest.
 * So the audit REQUIRES the host's boot count (--boots N, cumulative boots
 * the host has EVER started on this store), records it in the observation
 * beside the records it already hashes, and refuses growth the host cannot
 * account for.  Without the count the tool REFUSES (exit 2), loudly: an
 * optional anchor that silently defaults is exactly how a bound becomes
 * decorative.
 *
 * THE ACCOUNTING RULE, DERIVED FROM THE WRITER'S CALL SITES (init.zig, not
 * guessed) — every append path ONE boot the host started may take:
 *   boot start     TWO sites, both bounded by the boot's nonce.  At most
 *                  ONE from the boot path (init.zig:5243: once per PID1
 *                  lifetime, for the version being booted, and only when a
 *                  generation was bootable AND its facts read ok — the
 *                  no-generation and facts-fail paths append NOTHING and
 *                  pre-decide the verdict away, g_boot_decided=1 before
 *                  any line is written), and ONE PER ACTIVATE from the
 *                  activate arm (init.zig:3860: appended AFTER the store's
 *                  CURRENT rewrite and BEFORE the activated version's facts
 *                  are read, so the activated window is OPEN on disk before
 *                  anything can refuse it).  The boot path's line is that
 *                  boot's FIRST in-progress, always — the PER-NONCE rule
 *                  below rests on exactly that.
 *   verdict        the g_boot_decided latch allows one verdict per DECISION:
 *                  the boot path (dhake failure init.zig:5254; grace
 *                  expiry :3021/:3033; a service exiting during grace
 *                  :3128) verdicts the version it BOOTED, in a boot that
 *                  already appended its in-progress for that same version;
 *                  the activate REFUSAL arm verdicts the version it refused
 *                  (init.zig:3903), riding the arm's own in-progress above
 *   the RE-ARM     the in-guest `activate` (the control channel, the path
 *                  the agent-slot loop uses every task cycle) PUBLISHES a
 *                  new version through fx-activate (the store's CURRENT
 *                  moves) and then RESETS the latch — g_boot_decided=0,
 *                  g_boot_failed=0, a fresh grace deadline (init.zig:
 *                  3933-3936) — so the SAME boot appends a SECOND verdict
 *                  for the NEWLY ACTIVATED version, which now WEARS ITS OWN
 *                  in-progress: init.zig:3860 writes it before the facts are
 *                  read, so the activated window is on disk ip-FIRST under
 *                  the same boot's nonce (the boot's own in-progress already
 *                  ran for the version it booted; fx-init's own suite
 *                  measures this second DISK verdict pair, fx-init
 *                  tests/qemu_boot_rollback.sh).  The store's publish
 *                  RATCHET is what makes the pair attributable: a publish
 *                  allocates max+1, so a re-arm version is ALWAYS greater
 *                  than the version that boot BOOTED.
 *                  The ctrl `rollback` path moves CURRENT but does NOT
 *                  re-arm and appends nothing.  An activate can happen once
 *                  per control command — unbounded per boot — but every
 *                  publish allocates a FRESH version number (the store's
 *                  monotonic ratchet never reuses one), so at most ONE
 *                  re-arm in-progress and ONE re-arm verdict exists per
 *                  first-published VERSION per window — the one boot that
 *                  activated it (which may be ANY window boot, not
 *                  necessarily the one whose verdict it lands next to).
 *   shutdown       at most ONE (init.zig:4613, the SIGTERM path), naming
 *                  whatever version is current when PID1 exits (after an
 *                  activate, the ACTIVATED one — no in-progress of its own
 *                  in this boot either; the shutdown budget never looks at
 *                  versions)
 *   .recovery      at most ONE data row (recovery_append, init.zig:934,
 *                  once per successful roll-forward inside
 *                  decide_boot_version, whose every appending walk
 *                  iteration returns)
 * Hence, for the lines ADDED since the previous observation:
 *   1. each added ok/failed for version v must be accounted by ONE of the
 *      writer paths, each anchored OUTSIDE the line itself:
 *      (a) an added in-progress for v wearing the SAME nonce, earlier in
 *      the window, not yet consumed by an earlier verdict for v (one nonce
 *      per KERNEL BOOT — every line of a PID1 lifetime carries the one
 *      latched at its start; see THE NONCE INVARIANT, which is what a soft
 *      reboot forces), or
 *      (b) v is a version the STORE first published in this window: in the
 *      timeline now, absent from the previous observation's version list —
 *      the re-arm verdict is for exactly such a version, and the record is
 *      fxstore's own publish history (snapshots + facts + timeline,
 *      transactionally written), not .bootlog, the file the forger
 *      appends to; or
 *      (c) an ADMITTED .operator `reboot` row (action `reboot`, outcome
 *      `ok`) carrying the SAME nonce and a from-version equal to v, NOT YET
 *      CONSUMED by another lifetime in this run — ANCHOR (c), the one a SOFT
 *      REBOOT adds.  It is keyed on the PAIR (nonce, from-version) and it
 *      licenses ONE REBOOT LIFETIME: the in-progress that opens it and the
 *      verdict that closes it, and nothing else.  See THE NONCE INVARIANT.
 *      A verdict with no anchor at all is a FORGED VERDICT (the
 *      motivating exploit, named as that).  A TORN verdict (the file's
 *      LAST line, unterminated) rides the SAME anchors, because
 *      fx-init reads .bootlog with fgets, which RETURNS a final
 *      unterminated line — so a torn verdict still steers bootlog_last
 *      in-guest and cannot be exempted from the rule.  But a torn tail is
 *      equally what the writer leaves when it is killed MID-APPEND between
 *      a boot's in-progress line and that boot's verdict, and that boot is
 *      one the host's count accounts for: so a torn verdict is TOLERATED
 *      when an anchor answers for it — with its own line naming the torn
 *      verdict and the anchor (never a silent pass) — and reported as a
 *      forged verdict only when nothing in this window accounts for it.
 *      Always-finding was a MEASURED FALSE POSITIVE: it rejected a healthy
 *      machine and its message named an in-progress the same run's
 *      accounting line printed as present;
 *   2. per version v: added verdicts for v must number at most the added
 *      in-progress lines for v, PLUS ONE ONLY for a version first published
 *      in the window AND carrying NO re-arm in-progress of its own:
 *      allow(v) = ip(v) + 1 iff first-published(v) AND ip(v) == 0.  The +1
 *      is the OLD-writer shape of the single re-arm verdict (init.zig
 *      before the re-arm's in-progress existed) and must NEVER stack on a
 *      present re-arm ip — a first-published version that HAS its own ip
 *      gets exactly that one verdict slot.  More verdicts than boots behind
 *      them — including a SECOND verdict for a version the window already
 *      verdicted, under any nonce in the window — are FABRICATED BOOTS;
 *   3. added in-progress lines must number at most the host's boot DELTA
 *      PLUS the versions the store FIRST PUBLISHED in this window (every
 *      activate re-arm appends one, for a distinct first-published
 *      version) PLUS the SOFT-REBOOT LIFETIMES anchor (c) opened (a soft
 *      reboot starts no host boot, so its one in-progress is anchored by its
 *      own .operator row and by nothing in the boot count); shutdown lines
 *      at most the DELTA PLUS those lifetimes, recovery rows at most the
 *      DELTA (an admitted reboot's own boot verdict was ok, and ok is not a
 *      roll-forward trigger, so a reboot lifetime cannot append a row) —
 *      more boots on paper than the host started are FABRICATED BOOTS.
 *      PER NONCE, the FIRST added in-progress is that boot's OWN
 *      (init.zig:5243, written before every verdict site), and every
 *      SUBSEQUENT one must be an activate re-arm (init.zig:3860) naming a
 *      version the store FIRST PUBLISHED in this window AND numerically
 *      GREATER than the version that nonce's first in-progress named (the
 *      publish ratchet is max+1, so a boot's re-arm versions always exceed
 *      the version it booted) AND NOT ALREADY BOOTED in this window — the
 *      re-arm names the version the activate JUST published (max+1), which
 *      has therefore never been booted, so a later in-progress for a
 *      version whose OWN first in-progress already appeared is a forged
 *      pair riding an earlier boot's nonce.  AND PER WINDOW, the re-arm
 *      in-progress budget is ONE PER FIRST-PUBLISHED VERSION: a publish
 *      allocates a version number exactly ONCE, so exactly ONE boot can
 *      have activated that version and written its re-arm line — a SECOND
 *      in-progress naming the same version, under ANY window nonce, is a
 *      forged pair riding a second real boot's nonce (this is the keying
 *      that closes the cross-nonce flip: keyed per (nonce, version) it
 *      would be read as a legitimate re-arm for the second boot, ip(v) and
 *      vd(v) would rise in lockstep, and rule 2 would pass a SECOND verdict
 *      for a version the window already verdicted).  The NOT-ALREADY-BOOTED
 *      clause is what closes the REPUBLISH shape: a version the STORE first
 *      published WITHOUT an activation (a roll-forward republish, automatic
 *      or operator) and then BOOTED in the window has no legitimate later
 *      ip anywhere, and a forged "<v> in-progress Nth>" + "<v> ok Nth>"
 *      pair riding an EARLIER real boot's nonce would otherwise read as a
 *      legitimate re-arm (v is first-published and newer than that boot's
 *      own) and buy a SECOND verdict for a version the window already
 *      verdicted.  Anything else is a second boot on paper wearing one real
 *      boot's nonce — and a nonce that carries a verdict but no in-progress
 *      is that same forge (every verdict site runs in a boot that appended
 *      its own first).
 * ── THE NONCE INVARIANT, REDEFINED (fx-init's SOFT REBOOT) ──────────────
 * WHAT THIS SEAT USED TO ASSUME, and it was true of every fx-init before the
 * reboot verb: ONE NONCE PER PID1 LIFETIME — every line of a boot carries the
 * one latched at its start, so a nonce identifies a lifetime and a lifetime
 * carries at most one boot's own in-progress.  fx-init's soft reboot is
 * PID1 execve'ing /proc/self/exe to re-enter its own boot path: a NEW PID1
 * LIFETIME under the SAME KERNEL BOOT, and apply_kernel_nonce re-latches the
 * SAME fx.bootnonce= on every re-entry (the kernel command line did not
 * change — no kernel booted).  So the invariant is now:
 *
 *      ONE NONCE PER KERNEL BOOT.  A SOFT REBOOT IS A NEW PID1 LIFETIME
 *      UNDER THE SAME NONCE, DELIMITED BY AN ADMITTED .operator reboot ROW.
 *
 * The row is ANCHOR (c) and it is what makes the new lifetime accountable:
 * it names the boot nonce it happened under, the generation the machine was
 * running when it asked (from-version) and the admission (outcome `ok`).
 * ONE row licenses ONE lifetime — the new in-progress and the verdict that
 * closes it — and the row must match the line's nonce AND version, so a
 * reboot row is never a blanket permission for its nonce.
 *
 * THE FALSE POSITIVE THIS FIXES, MEASURED, because it is the whole reason
 * the reader lands BEFORE the writer: under the old invariant EVERY
 * legitimate soft reboot is a forgery.  No host boot starts, so `--boots`
 * does not move and the reboot's lines wear a nonce no window holds
 * (bootlog-unbound-nonce in the strict regime); the in-progress surplus is
 * unaccounted (bootlog-fabricated-boots); and if the window also holds the
 * pre-reboot pair, the same nonce now carries two in-progress lines for the
 * same version, which the re-arm rule rejects as an already-booted version
 * (bootlog-fabricated-boots again).  A machine that did exactly what its verb
 * was built to do is called a liar, and the trigger would roll it back.
 *
 * THE TRADE, written down rather than hidden: anchor (c) gives a forger a way
 * to buy a plausible in-progress + verdict pair for an EXISTING version by
 * ALSO writing a reboot row.  The bounds on it, each checked in code: the
 * version must EXIST in the store's timeline (ver_index >= 0 — no pair can
 * name a generation the store never published); the row must wear a nonce the
 * HOST issued for some boot (a minted nonce anchors nothing); the row is
 * spent by one lifetime, so a SECOND verdict for the same version under the
 * same nonce needs a SECOND row (the per-version budget is not widened — ip
 * and verdict rise together); and a row is only ever an ENABLER of
 * attribution, never a suppression of any other predicate.  What is NOT
 * closed, stated: a row written in an EARLIER window can license a lifetime
 * judged in a later one (the journal is read whole, like .bootlog's history),
 * so the row must exist on disk NOW but not necessarily be new — the same
 * "auditing, not proofing" boundary §6b draws, and the same residual shape as
 * the live-boot substitution (the guest is root and can write every one of
 * these records).  AND the journal is NOT part of this seat's observation
 * hash: .bootlog, .recovery and the host proxy's log are byte-scored and
 * re-hashed against the previous observation, while .operator is read for
 * this one purpose only — so a row may be ADDED, REWRITTEN or REMOVED between
 * two audits and this seat will not see the change, it will only judge the
 * pairs against whatever the journal says NOW.  That is the honest cost of
 * anchoring on a record the seat does not watch, and it is why the anchor can
 * only ever ENABLE an attribution: dropping a row makes a pair fire, never
 * pass, and rewriting one buys exactly the forged pair the forger could
 * already have appended to .bootlog.
 *
 * A reboot lifetime that BOOTS the version an activate just published is a
 * first-published version, and the anchor accepts it: that is the writer's
 * own recommended loop (activate -> poll the posted verdict -> reboot into
 * it), so requiring "not first-published" would break a healthy machine.
 *
 * WHY A LIFETIME AND NOT A BARE VERDICT: the plan's form of anchor (c) also
 * accounted a verdict with NO in-progress of its own.  No writer path
 * produces one (the boot path's in-progress is the first line of every
 * lifetime, init.zig:5243, before every verdict site), so this reader anchors
 * the LIFETIME instead — strictly harder to forge and strictly faithful.
 * ── THE THREAT-MODEL DELTA OF THE RE-ARM IN-PROGRESS ────────────────────
 * The pre-re-arm reader's per-nonce in-progress budget was ONE, and that
 * single budget WAS the pair-forgery closure: a forged
 * "<v> in-progress" + "<v> ok|failed" pair appended into the slack of a
 * real window boot fired it.  The writer's new re-arm line RE-OPENS that
 * shape, by design, and the closure moves into the per-nonce rule above: a
 * forged pair for a first-published version may now ride ANY real window
 * boot's nonce — provided the version is PLAUSIBLY ACTIVATABLE, i.e. first
 * published in the window, newer than that boot's own version, NOT already
 * booted in the window, AND provided NO other later in-progress in the
 * window already named that version (the one-per-first-published-VERSION-
 * per-window cap).  That last clause is the load-bearing one and it is
 * NOT derivable per nonce: with
 * two real nonces in a window, keyed per (nonce, version) a forger could
 * append an in-progress+verdict pair for the version the LIVE boot
 * activated, riding an EARLIER window boot's nonce — the version IS
 * first-published and IS newer than that earlier boot's own, so the pair
 * reads as a legitimate re-arm; ip(v) and vd(v) then rise in lockstep and
 * rule 2 passes a SECOND verdict for a version the window already
 * verdicted.  That is the flip the PRE-re-arm reader closed (one
 * in-progress per nonce) and a per-(nonce, version) rule re-opens; keying
 * the duplicate on the VERSION alone closes it (MEASURED: the cross-nonce
 * flip audits COHERENT on the per-(nonce, version) reader and INCOHERENT
 * after the fix — tests/test_fx_audit.sh REARMIPX, with the pre-fix reader
 * pinned as BEFORE-E and the pre-re-arm reader pinned firing it).  The
 * version-keyed cap alone does NOT close a SECOND shape, MEASURED in round
 * 2 (tests/test_fx_audit.sh REARMIPREPUB): a version the STORE first
 * published WITHOUT an activation — the roll-forward REPUBLISH (automatic,
 * init.zig:1816, or the operator `rollback`, init.zig:3989) — and then
 * BOOTED in the window has NO legitimate later ip anywhere, so the dup
 * check never sees it; a forged "<v> in-progress Nth>" + "<v> ok Nth>" pair
 * riding an EARLIER real window boot's nonce then passes every predicate
 * (v is first-published, newer than that boot's own, not a dup) and buys a
 * SECOND verdict for a version the window already verdicted — the exact
 * flip REARMIPX pins, in the republish shape.  The NOT-ALREADY-BOOTED
 * clause closes it: the re-arm ip for a republished version is a re-arm for
 * a version whose OWN first in-progress already appeared (it was BOOTED),
 * and a version the activate JUST published has never been booted, so that
 * later ip is refused — measured, tests/test_fx_audit.sh REARMIPREPUB.
 * What the forger still CANNOT do: mint an in-progress for a version the
 * store did not publish in this window, or one OLDER than that nonce's
 * first in-progress (both fire the per-nonce rule — the (b2) forged-pair
 * arm of tests/qemu-agent-observe.sh keeps firing, through this rule now),
 * or land a SECOND verdict for a version the window already verdicted
 * (rule 2, and tighter than before: the +1 no longer stacks on a present
 * re-arm ip, the re-arm ip itself is one per first-published version per
 * window, AND it must name a version not already booted — so a forged pair
 * cannot ride a second window nonce to buy that second verdict, whether
 * the version was activated or republished).  What the legitimate re-arm
 * line GRANTS a forger is therefore NOTHING it did not already have: the
 * +1 first-published credit already granted exactly ONE verdict slot per
 * first-published version, and the one-per-version-per-window cap (plus
 * the not-already-booted clause) keeps it at one; the in-progress line
 * only makes the activation window visible on disk.  The remaining hole is
 * the LIVE-BOOT substitution already named in the printed bound (the agent
 * appends inside its own boot under its own boot's nonce) — it is not
 * opened by this rule.  A SECOND residual, named, not closed: a version
 * first published WITHOUT an activation and NOT YET BOOTED in the window
 * admits a forged pair indistinguishable from a real activation's re-arm —
 * it lands the version's FIRST verdict (a fabricated one; the later real
 * boot of it is the second, inside the ip(v)=2/vd(v)=2 budget).  The only
 * writer window where that shape is reachable is the OPERATOR `rollback`
 * during a live boot (the republish lands on the ctrl channel, the next
 * boot boots it, and an agent runs in between); the AUTOMATIC roll-forward
 * has no such window (the republish and the boot are one PID1 start,
 * before any agent runs), and the not-already-booted clause refuses the
 * same forge the moment the version IS booted.  Telling that forge from a
 * real activation would require reading the .operator journal (an
 * `activate` row against a `rollback` row naming the version), which this
 * seat does not read; the PRE-re-arm reader closed it only as a side
 * effect of its one-in-progress-per-nonce budget, which also rejected
 * every healthy re-arm boot.
 *
 * The rule is deliberately STRICT about window edges: a verdict gets NO
 * credit for an in-progress left open at the previous observation.  The
 * audit is a BETWEEN-BOOTS instrument (run it with the guest stopped —
 * every harness does); a boot's in-progress and its verdict are written
 * within one PID1 lifetime, so a verdict in a NEW window with no new
 * in-progress is not a late verdict but an append.  Where the accounting
 * is ambiguous the check prefers the finding: a false stop is recoverable
 * and names itself; a false pass is the whole failure mode here.
 *
 * ── THE BOUND, in the tool's own output ──────────────────────────────────
 * A COHERENT tamper against a store this seat has never observed before is
 * UNDETECTABLE by it, and an in-guest cross-check is defeated by design.
 * This seat sees REWRITES and TRUNCATIONS of records it previously
 * observed, and — with --boots + the --nonces ledger — APPENDED
 * .bootlog/.recovery growth beyond what the host can account for, line by
 * line, not merely in aggregate.  The per-boot nonce closed the measured
 * pair-forgery (an in-progress + verdict pair appended into the slack of a
 * silent boot): in the NONCE REGIME every ADDED line must wear a nonce the
 * host issued for a boot in this window, per-nonce budgets hold at one
 * in-progress / shutdown / row, per-VERSION budgets hold the verdicts to
 * the boots behind them plus the one re-arm verdict a first-published
 * version can carry, and an UNCLAIMED nonce is itself reported (a silent
 * boot — visible, coherent, never a rollback by itself).  What it still
 * cannot see: a verdict SUBSTITUTED inside a LIVE boot — the agent (root
 * in the guest) can read its own /proc/cmdline nonce, append the verdict
 * itself in the writer's exact shape and suppress fx-init's own (panic
 * before grace expiry): one verdict for one (nonce, version), every
 * anchor satisfied, and the line's authorship inside the boot that owns
 * the nonce is NOT distinguishable from the host (auditing, not
 * proofing); window boots the ledger does not cover (the mixed/manual
 * regime — nonce-less lines are named and boot-counted, but a forged pair
 * in an UNCOVERED boot's slack still passes the arithmetic); boots started
 * off the counting host or a miscounted / moved --obs-file reuse (the count
 * and the ledger are only as true as the host's own bookkeeping); and the
 * enrollment gap (first run trusts, loudly).  That is the honest bound of
 * "auditing, not proofing" (§6b), printed on every run so the tool never
 * implies more than it knows.
 *
Host tool (like the oracle: native, no musl variant).  Links only the
 * vendored sha256.  Usage:
 *   fx-audit --store DIR --boots N [--rootfs DIR] [--obs-dir DIR]
 *            [--obs-file PATH] [--fxstore BIN] [--re-enroll] [--rollback [V]]
 * Exit: 0 coherent, 1 incoherent (or a refused rollback), 2 tool error.
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include "dhall.h" /* sha256_hex (vendored dhall-c/sha256.c) */

/* ── knobs ─────────────────────────────────────────────────────────────── */

#define MAX_VERSIONS 64        /* timeline cap: a bigger store needs a real
                                * retention policy, not a louder guess */
#define MAX_BOOTLOG_BYTES (8u * 1024 * 1024)
#define MAX_FINDINGS 256
#define LINE_MAX_ 8192

/* The FROZEN relation list for the per-version facts hash: every relation
 * a writer in this stack declares (MEASURED census, fxstore provenance.zig
 * RELATION_SCHEMAS).  Sorted; a relation unknown to the fxstore binary is
 * a LOUD tool error (stale binary), never a silent skip. */
static const char *const FACT_RELS[] = {
    "activate_root", "boot_grace", "dep", "generation", "install", "pkg",
    "provides", "root", "src_of", "srcstore", "store", "svc", "svc_argv",
    "svc_backoff", "svc_bin", "svc_console", "svc_env", "svc_probe",
    "tool_fxstore", "user",
};
#define N_FACT_RELS (sizeof FACT_RELS / sizeof FACT_RELS[0])

/* ── state ─────────────────────────────────────────────────────────────── */

static const char *g_store = NULL;      /* --store (required) */
static const char *g_rootfs = NULL;     /* --rootfs (optional) */
static const char *g_obsdir = NULL;     /* --obs-dir (resolved) */
static const char *g_obsfile = NULL;    /* --obs-file (explicit) */
static const char *g_fxstore = NULL;    /* --fxstore / $FXSTORE_BIN / fxstore */
static int g_reenroll = 0;
static int g_rollback = 0;
static unsigned g_rollback_v = 0;
static int g_rollback_v_given = 0;
static unsigned long g_boots = 0;        /* --boots (required): cumulative
                                          * boots the HOST has ever started
                                          * on this store — the OFF-DISK
                                          * anchor for .bootlog growth */
static int g_boots_given = 0;
static const char *g_nonces_path = NULL; /* --nonces (required when the window
                                          * has boots): the HOST's own ledger
                                          * of the nonce it issued per boot */
static int g_nonces_given = 0;

static char g_store_abs[4096];
/* ── S4: THE PROXY'S ONE LOG AS A KNOWN RECORD, and the DECLARED REACH ────
 * §7.1a's residual, aimed at THIS seat: "every oracle in the family must be
 * able to SEE capability changes, because an egress grant is a capability
 * increase, and a code-only oracle is blind to it".  The observatory's two
 * new inputs:
 *
 *   --proxy-log FILE      the host proxy's ONE LOG (tools/fx-hostgate.c).
 *                         Taken as a KNOWN host-side record on exactly the
 *                         terms .bootlog/.recovery are: its whole bytes are
 *                         recorded in the observation, and the previously
 *                         observed PREFIX must still hash the same — the log
 *                         is append-only by construction, so a truncation or
 *                         an in-place rewrite is a TAMPER FINDING, not a
 *                         change of mind.  It is the host's own account of
 *                         what it ran, which is the one thing an in-guest
 *                         record cannot be (bound: the log is written by the
 *                         proxy the harness started; a run whose proxy wrote
 *                         no log leaves this seat silent, never reassured).
 *
 *   --proxy BIN           the DECLARED REACH half that is COMPILED IN, read
 *   --ops-policy-dir DIR  from the proxy itself (--print-host-tools: the
 *                         closed list the dispatch lookup reads), and the
 *                         half the OPERATOR pinned (ops-aliases.tsv's path
 *                         classes, ops-hosts.tsv's authority classes: every
 *                         row a GRANT with its protected flag).  Each
 *                         observation records them and names them BESIDE THE
 *                         BOOT it ran after, so "what this boot's generation
 *                         could reach" is in the record rather than in
 *                         somebody's memory of what was deployed.
 *
 * AND THE COMPARISON IS THE SEAT'S OWN DISCIPLINE, applied to capability:
 * the delta against the PREVIOUS OBSERVATION is named row by row (a new host
 * tool, a new class row, a protection removed = WIDENED; the mirror cases
 * NARROWED; a row bound to another class CHANGED, never dressed as a
 * widening).  Then, because the audit's job is to tell a CHANGE from a
 * TAMPER, the classification is the PINS: a widening whose tables STILL
 * MATCH PINS is an operator RELEASE (a re-pin release is exactly how reach is
 * supposed to change) and is NAMED, not a finding; a widening whose tables
 * do NOT match PINS is a capability change NOTHING RELEASED, and that is the
 * incoherence `reach-widened-unreleased` — the covert direction §7.1a is
 * about.  A missing PINS cannot verify a release, so it takes the LOUD side
 * (a finding), the same fail-closed choice the rest of this file makes.
 *
 * WHAT THIS WRITES, and it is deliberately SHARED with the selection seat:
 * the stdout rows `reach-tool <name>` and `reach-grant <dim> <pattern>
 * <class> <protected>` (the tab grammar fx-select PRINTS and consumes via
 * --reach-prev), so an audit run IS a baseline another oracle can delta
 * against — one grammar, two producers, no second spelling. */
#define MAX_REACH_TOOLS 256
#define MAX_REACH_GRANTS 4096

typedef struct { char name[128]; } reachtool_t;
typedef struct {
    char dim[16];        /* "path" | "authority" */
    char pattern[1024];
    char cls[128];
    int  prot;
} reachgrant_t;

static const char *g_plog = NULL;    /* --proxy-log */
static const char *g_proxy = NULL;   /* --proxy */
static const char *g_opsdir = NULL;  /* --ops-policy-dir */
static char *g_plog_bytes = NULL;
static size_t g_plog_len = 0;
static int g_plog_absent = 0, g_plog_given = 0;

static reachtool_t g_rtools[MAX_REACH_TOOLS]; static size_t g_nrtools = 0;
static reachgrant_t g_rgrants[MAX_REACH_GRANTS]; static size_t g_ngrants = 0;
static int g_rtools_known = 0, g_grants_known = 0;
static reachtool_t g_ptools[MAX_REACH_TOOLS]; static size_t g_nptools = 0;
static reachgrant_t g_pgrants[MAX_REACH_GRANTS]; static size_t g_npgrants = 0;
/* 1 = the current tables hash to PINS (a RELEASE), 0 = they do not (an
 * unreleased edit), -1 = PINS could not verify them (absent, or not naming
 * them) — the loud side, because an unverifiable release is not a release */
static int g_reach_pins_state = -1;
static char g_reach_pins_detail[512];

/* the boot this observation is anchored to: the LAST line in .bootlog */
static unsigned long g_reach_boot_v = 0; static int g_reach_boot_known = 0;
static char g_reach_boot_nonce[80] = "none";

/* ── S4b (PALISADE): the COMPOSED SANDBOX, recorded per boot ──────────────
 * §7.1a at the layer S3 made structural: every host spawn is wrapped, the
 * executor owns a BASELINE, a tool may declare MORE via a sidecar beside its
 * binary, and the operator's ops-sandbox.tsv row may only TIGHTEN.  So the
 * composed spec per tool IS a capability declaration, and this seat's own
 * discipline — record it, then name any change against the audit's OWN
 * previous observation — applies to it exactly as it applies to .bootlog,
 * .recovery, the host's one log and the declared reach.
 *
 * The composition is read from THE PROXY (`--print-sandbox`: name<TAB>
 * promises<TAB>static-landlock — the baseline + the tool's sidecar, rendered
 * by the same code the spawn uses), never re-spelled here: a second spelling
 * of the C baseline is a mirror that can drift, and a drifting mirror is how
 * an instrument goes quietly blind.
 *
 * THE RELEASE QUESTION, answered honestly rather than in the egress term's
 * SHAPE alone: the operator half (ops-sandbox.tsv) is PINNED, but the two
 * halves that can actually WIDEN a declaration — the sidecar and the
 * executor baseline — are pinned by NOTHING, and the operator table is
 * DENY-MORE-ONLY, so it can never be the source of a widening.  Therefore a
 * WIDENING of the composed spec is, by construction, a capability change no
 * pin covers: it is ALWAYS `sandbox-widened-unreleased` (the loud side), and
 * the operator table's own pin state is reported BESIDE it so the reader can
 * tell an unreleased operator edit from an unpinned sidecar.  A NARROWING is
 * the mirror direction and is NAMED — and when the operator table still
 * hashes to PINS that is a RELEASED tightening, which is how a sandbox is
 * supposed to narrow.  Both directions are measured, and the asymmetry is
 * stated in the check's own output rather than left to be discovered. */
#define MAX_SB_TOOLS 32
typedef struct { char name[128]; char promises[1024]; char landlock[2048]; } sandbox_t;
static sandbox_t g_sbt[MAX_SB_TOOLS];  static size_t g_nsbt = 0;
static sandbox_t g_psbt[MAX_SB_TOOLS]; static size_t g_npsbt = 0;
static int g_sbt_known = 0;           /* --print-sandbox answered */
static int g_obs_sandbox_known = 0;   /* the previous observation recorded one */
static char g_obs_sb_sha[65];         /* the sha that observation recorded */
static char g_sb_sha[65];             /* sha256 over the composed spec block */
static int g_sb_pins_state = -1;      /* 1 = ops-sandbox.tsv hashes to PINS, 0 = drift,
                                       * -1 = unverifiable (loud side) */
static char g_sb_pins_detail[512];

/* ── S5 (ACL SPLIT): THE ACCESS TABLE, AND THE ARMED-AUTHOR SET ──────────
 * §7.1a aimed at the last dimension the audit could not see.  S2 made
 * `policy/access/access-verbs.tsv` THE tool-vocabulary authority at the judge
 * and S3 removed the guest's own list, so flipping one row deny -> allow is a
 * capability WIDENING — and a seat that judges generations (fx-select) reads
 * its baseline from THIS seat's per-boot record.  So the audit records the
 * vocabulary beside the boot it ran after, in the SHARED grammar
 * (`reach-verb<TAB>verb<TAB>allow|deny`), and names any change against its OWN
 * previous observation.
 *
 * THE DIRECTION, named both ways: deny -> allow is a WIDENING and is the
 * finding `access-widened-unreleased` UNLESS the table still hashes to
 * policy/access/PINS (then it is a RELEASE — named, not a finding, exactly the
 * asymmetry reach-widened-unreleased already uses); allow -> deny is a
 * NARROWING, named and NOT a finding, because a tightening needs no release
 * and is the direction this mechanism exists to encourage.
 *
 * THE READING IS THE FILE (`<--access-dir>/access-verbs.tsv`), NOT the proxy's
 * loader — and that is forced by the question, not a preference: the loader
 * REFUSES a table whose bytes do not hash to PINS, so a table that drifted from
 * its release can never reach the printer, and "was this widening released?"
 * would answer "yes" for every reading that exists.  Reading the declared file
 * and verifying it against this directory's PINS keeps all three states real
 * (the bytes, the release, the difference).  THE LOADER'S OWN REFUSAL IS STILL
 * THE JUDGE'S: it is what stops a SERVED run on a stale table — this seat
 * reports the same fact as DRIFT plus an UNRELEASED widening.
 *
 * THE ARMED-AUTHOR SET: a boot's record also says WHICH AUTHORS COULD REFUSE
 * as this observation saw them (R5's durable-absence requirement: an access
 * seat armed on the gates and absent on the real lane must leave a record
 * rather than be inferred from a transient stderr line).  THE SCOPE IS STATED
 * RATHER THAN IMPLIED: the set is a LOWER BOUND derived from the inputs THIS
 * observation was given — `access` when the table was read, `ops` when the
 * pinned class tables were read — and the denylist, the justification arm and
 * the claim author are NOT queryable from this seat, which the row says in its
 * own bytes.  Its change between observations is NAMED with the direction that
 * matters: an author REMOVED is a WIDENING (fewer seats can refuse) and an
 * author ADDED is a NARROWING. */
#define MAX_ACCESS_VERBS 256
typedef struct { char name[128]; int allow; } accessverb_t;
static const char *g_accessdir;      /* --access-dir: policy/access (PINS + table) */
static accessverb_t g_atab[MAX_ACCESS_VERBS];  static size_t g_natab = 0;
static accessverb_t g_patab[MAX_ACCESS_VERBS]; static size_t g_npatab = 0;
static int g_atab_known = 0;         /* the declared table was read */
static int g_obs_access_known = 0;   /* the previous observation recorded the table */
static int g_access_pins_state = -1; /* 1 = access-verbs.tsv hashes to PINS, 0 = drift,
                                      * -1 = unverifiable (the loud side) */
static char g_access_pins_detail[512];
/* the armed-author set of THIS observation, "+"-joined ("none" when nothing
 * was seen armed — which is itself the R5 shape worth recording), and the
 * previous observation's value */
static char g_armed[256] = "none";
static char g_obs_armed[256];
static int  g_obs_armed_known = 0;
static int  g_armed_known = 0;       /* any input was given, so the set means something */

/* previous observation's halves */
static int g_obs_plog_known = 0;
static size_t g_obs_plog_bytes = 0; static char g_obs_plog_sha[65];
static int g_obs_plog_absent = 0;
static int g_obs_reach_known = 0;


/* findings */
typedef struct { char name[64]; char detail[LINE_MAX_]; } finding_t;
static finding_t g_findings[MAX_FINDINGS];
static size_t g_nfindings = 0;

/* .bootlog */
typedef struct { unsigned long v; char status[64]; unsigned long epoch;
                 char nonce[80];        /* the 4th field: the writer's
                                          * per-boot nonce token, "" when the
                                          * line has no 4th field (the
                                          * pre-nonce writer's shape — history
                                          * a nonce-era store may still carry;
                                          * only ADDED lines are judged) */
                 size_t off; } bl_line_t;
static bl_line_t g_bl[4096];
static size_t g_nbl = 0;
static size_t g_bl_damaged = 0, g_bl_torn = 0;
static char g_bl_bad1[512];      /* first damaged line, for the finding */
static char *g_bl_bytes = NULL;   /* whole file, NUL-terminated */
static size_t g_bl_len = 0;
static int g_bl_absent = 0;

/* .recovery: data rows only (header is '#' lines) */
typedef struct { unsigned long epoch, published, from_failed; char genhash[80];
                 char nonce[80];         /* 5th field, same meaning as
                                          * .bootlog's 4th ("" = absent) */
                 size_t lineno; size_t off; } rec_row_t;
static rec_row_t g_rec[1024];
static size_t g_nrec = 0;
static size_t g_rec_damaged = 0;
static char g_rec_bad1[512];
static size_t g_rec_bad1_lineno = 0;
static char *g_rec_bytes = NULL;
static size_t g_rec_len = 0;
static int g_rec_absent = 0;

/* timeline */
static unsigned g_vers[MAX_VERSIONS];
static size_t g_nvers = 0;
static unsigned g_current = 0;         /* EFFECTIVE current: the file's version
                                         * when it is published, else the timeline's
                                         * newest (the checks still see the FILE's
                                         * raw value via g_current_file) */
static unsigned g_current_file = 0;    /* what .db/snapshots/CURRENT literally says */
static int g_current_file_given = 0;   /* the file existed and parsed as a number */
static int g_current_from_file = 0;    /* the effective current CAME from the file */
static char g_current_garbage[64];     /* unparseable file content, for the finding */

/* per-version facts: hash + genhash */
static char g_facts_hash[MAX_VERSIONS][65];
static char g_genhash[MAX_VERSIONS][65]; /* "" when the version has no generation row */

/* observation (previous), parsed */
static int g_have_obs = 0;
static size_t g_obs_bl_bytes = 0;  static char g_obs_bl_sha[65];  static int g_obs_bl_absent = 0;
static size_t g_obs_rec_bytes = 0; static char g_obs_rec_sha[65]; static int g_obs_rec_absent = 0;
static unsigned g_obs_current = 0;
static unsigned long g_obs_boots = 0;   /* the host boot count recorded at the
                                          * previous observation (format 2) */
static unsigned g_obs_vers[MAX_VERSIONS]; static char g_obs_genhash[MAX_VERSIONS][65];
static char g_obs_facts[MAX_VERSIONS][65]; static size_t g_nobs_vers = 0;
static char (*g_obs_artifacts)[256] = NULL; static size_t g_nobs_artifacts = 0;

/* current artifact set (existing <64hex>-<name>-src dirs) */
static char (*g_artifacts)[256] = NULL; static size_t g_nartifacts = 0;

/* ── ANCHOR (c): the ADMITTED .operator reboot row ───────────────────────
 * A SOFT REBOOT re-enters PID1 under the SAME kernel boot's nonce (fx-init
 * re-latches the same fx.bootnonce= on every re-entry, apply_kernel_nonce),
 * so the lines the new lifetime appends wear a nonce the host boot count can
 * never account for: no host boot started, and the nonce belongs to a boot
 * outside the window.  The journal's `reboot` row is the record of that act
 * and is the THIRD anchor behind an added verdict (header rule 1(c)).
 *
 * Held as plain data, so the check that uses it owns every decision: one row
 * licenses ONE reboot LIFETIME (one in-progress and the verdict that closes
 * it), which is what the writer produces. */
typedef struct {
    unsigned long lineno;   /* the .operator line, so a finding can name it */
    unsigned long epoch;    /* the row's epoch, printed with the attribution */
    long slot;              /* the host ledger slot of the row's nonce */
    unsigned long v_from;   /* the row's from-version (the generation rebooted) */
    int consumed;           /* one row, one lifetime */
} rbanchor_t;
static rbanchor_t *g_rb = NULL; static size_t g_nrb = 0;
static size_t g_rb_refused = 0;      /* rows whose outcome is NOT an admission */
static unsigned long g_rb_refused_line = 0;
static char g_rb_refused_outcome[64] = "";
static size_t g_rb_unread = 0;       /* data rows this seat cannot read */
static unsigned long g_rb_unread_line = 0;
static size_t g_rb_unanchored = 0;   /* admitted, but its nonce is not a host-issued one */
static int g_op_present = 0;         /* <store>/.operator exists */

/* facts of the resolved current version (kept for the checks) */
typedef struct { char *cols[4]; int n; } row_t;
static row_t *g_install = NULL; static size_t g_ninstall = 0;
static row_t *g_provides = NULL; static size_t g_nprovides = 0;
static row_t *g_src_of = NULL;   static size_t g_nsrc_of = 0;
static row_t *g_svcbin = NULL;   static size_t g_nsvcbin = 0;

/* ── loud failure / findings ───────────────────────────────────────────── */

static void die(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    fputs("fx-audit: FAIL: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    exit(2);
}

static void info(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    fputs("fx-audit: ", stdout);
    vfprintf(stdout, fmt, ap);
    fputc('\n', stdout);
    va_end(ap);
}

static void add_finding(const char *name, const char *fmt, ...) {
    if (g_nfindings >= MAX_FINDINGS) die("too many findings (cap %d)", MAX_FINDINGS);
    finding_t *f = &g_findings[g_nfindings++];
    snprintf(f->name, sizeof f->name, "%s", name);
    va_list ap; va_start(ap, fmt);
    vsnprintf(f->detail, sizeof f->detail, fmt, ap);
    va_end(ap);
    /* printed in one block after the check loop: a finding emitted
     * mid-check must not ride the in-progress "check NAME: " banner —
     * every INCOHERENT line starts at column 0 so gates can grep it */
}

/* the check registry: one call per line in main() so the GATE can mutate
 * the detector by deleting exactly one line (tests/test_fx_audit.sh's
 * positive control — a detector whose assertion cannot fail on a disabled
 * check is not a detector). */
typedef void (*check_fn)(void);
typedef struct { const char *name; check_fn fn; } check_t;
static check_t g_checks[MAX_VERSIONS];
static size_t g_nchecks = 0;
static void run_check(const char *name, check_fn fn) {
    g_checks[g_nchecks].name = name; g_checks[g_nchecks].fn = fn; g_nchecks++;
}

/* ── helpers ───────────────────────────────────────────────────────────── */

static void *xmalloc(size_t n) { void *p = malloc(n ? n : 1); if (!p) die("out of memory"); return p; }
static char *xstrdup(const char *s) { char *p = xmalloc(strlen(s) + 1); strcpy(p, s); return p; }

static void check_safe_path(const char *p, const char *what) {
    if (!p || !p[0]) die("empty %s path", what);
    for (const char *q = p; *q; q++)
        if (*q == '\'' || *q == '"' || *q == '\\' || *q == ';' ||
            *q == '$' || *q == '`' || *q == '(' || *q == ')' ||
            strchr(" \t\n", *q))
            die("unsafe character in %s path: %s", what, p);
}

static char *read_file(const char *path, size_t *len_out, int *absent) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        if (errno == ENOENT) { *absent = 1; *len_out = 0; return NULL; }
        die("cannot open '%s': %s — a record that cannot be read is its own loud state, never a silent pass",
            path, strerror(errno));
    }
    *absent = 0;
    if (fseek(f, 0, SEEK_END) != 0) die("cannot seek '%s': %s", path, strerror(errno));
    long sz = ftell(f);
    if (sz < 0) die("cannot tell '%s': %s", path, strerror(errno));
    if ((unsigned long)sz > MAX_BOOTLOG_BYTES)
        die("'%s' is %ld bytes (cap %u) — refusing to hash a record this size",
            path, sz, MAX_BOOTLOG_BYTES);
    rewind(f);
    char *b = xmalloc((size_t)sz + 1);
    if (sz > 0 && fread(b, 1, (size_t)sz, f) != (size_t)sz)
        die("short read on '%s' (%ld bytes): %s", path, sz, strerror(errno));
    /* the outcome.c defect class: glibc fopen() succeeds on a directory and
     * the first read fails — the read error is the ABSENCE OF EVIDENCE */
    if (ferror(f)) die("cannot read '%s': %s", path, strerror(errno));
    fclose(f);
    b[sz] = 0;
    *len_out = (size_t)sz;
    return b;
}

/* Run `fxstore <args>` capturing stdout.  Returns the raw captured text
 * (caller frees) and the exit status via *rc.  fxstore's own stderr passes
 * through to ours. */
static char *fxstore_capture(const char *args, const char *what, int *rc) {
    char *cmd;
    if (asprintf(&cmd, "'%s' %s", g_fxstore, args) < 0) die("out of memory");
    FILE *p = popen(cmd, "r");
    if (!p) die("cannot popen fxstore (%s)", strerror(errno));
    size_t cap = 65536, len = 0;
    char *buf = xmalloc(cap);
    char line[LINE_MAX_];
    while (fgets(line, sizeof line, p)) {
        size_t ll = strlen(line);
        if (len + ll + 1 > cap) {
            while (len + ll + 1 > cap) cap *= 2;
            buf = realloc(buf, cap);
            if (!buf) die("out of memory");
        }
        memcpy(buf + len, line, ll + 1);
        len += ll;
    }
    int st = pclose(p);
    *rc = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
    free(cmd);
    if (len == 0) buf[0] = 0;
    (void)what;
    return buf;
}

/* fxstore <args> that MUST succeed (a failure is a tool error: we could not
 * read a record we need).  Returns captured stdout, split into chomped
 * lines (array + count); caller frees the array and each line. */
static char **fxstore_lines(const char *args, const char *what, size_t *n) {
    int rc;
    char *out = fxstore_capture(args, what, &rc);
    if (rc != 0)
        die("%s: 'fxstore %s' failed (exit %d) — cannot read the store's records",
            what, args, rc);
    char **lines = NULL; size_t cnt = 0;
    char *save = NULL;
    for (char *tok = strtok_r(out, "\n", &save); tok; tok = strtok_r(NULL, "\n", &save)) {
        lines = realloc(lines, (cnt + 1) * sizeof *lines);
        if (!lines) die("out of memory");
        lines[cnt++] = xstrdup(tok);
    }
    free(out);
    *n = cnt;
    return lines;
}

static void free_lines(char **lines, size_t n) {
    for (size_t i = 0; i < n; i++) free(lines[i]);
    free(lines);
}

/* rows: TSV facts split into columns (max 4).  Caller frees. */
static row_t *lines_to_rows(char **lines, size_t n, const char *rel, size_t *out_n) {
    row_t *rows = xmalloc(sizeof(row_t) * (n ? n : 1));
    size_t rn = 0;
    for (size_t i = 0; i < n; i++) {
        char *cols[4] = {0};
        int nc = 0;
        char *save = NULL;
        for (char *t = strtok_r(lines[i], "\t", &save); t && nc < 4; t = strtok_r(NULL, "\t", &save))
            cols[nc++] = xstrdup(t);
        if (nc == 0) continue;
        rows[rn].n = nc;
        for (int c = 0; c < nc; c++) rows[rn].cols[c] = cols[c];
        rn++;
    }
    (void)rel;
    *out_n = rn;
    return rows;
}

/* a version's index in the timeline, or -1 */
static long ver_index(unsigned v) {
    for (size_t i = 0; i < g_nvers; i++) if (g_vers[i] == v) return (long)i;
    return -1;
}

/* ── record readers ────────────────────────────────────────────────────── */

/* .bootlog, the writer's exact grammar ("%u %s %u"): a TERMINATED line that
 * does not parse is damaged (a finding); an unterminated TAIL is a torn
 * mid-write (counted, not a finding — crash, not tamper).  A torn tail is
 * NOT exempt from the boot accounting: fx-init's fgets returns it, so it is
 * counted and attributed there like any other added line (see
 * check_boot_accounting), and it is always NAMED in the run output. */
static void read_bootlog(void) {
    char path[4096];
    snprintf(path, sizeof path, "%s/.bootlog", g_store_abs);
    int absent = 0;
    g_bl_bytes = read_file(path, &g_bl_len, &absent);
    g_bl_absent = absent;
    if (absent) { info(".bootlog absent (this store has not booted)"); return; }
    char *p = g_bl_bytes;
    while (p < g_bl_bytes + g_bl_len) {
        char *nl = memchr(p, '\n', (size_t)(g_bl_bytes + g_bl_len - p));
        size_t llen = nl ? (size_t)(nl - p) : (size_t)(g_bl_bytes + g_bl_len - p);
        if (!nl) { g_bl_torn++; break; } /* torn tail */
        char save = p[llen]; p[llen] = 0;
        bl_line_t b; memset(&b, 0, sizeof b);
        b.off = (size_t)(p - g_bl_bytes); /* byte offset: the boot-accounting
                                           * check needs the lines ADDED since
                                           * the previous observation */
        char junk[8];
        /* The writer's grammar is "<v> <status> <epoch> <nonce>" (4 fields,
         * init.zig bootlog_append); a line with only three is the PRE-NONCE
         * writer's shape — history, legal in the baseline, judged only when
         * ADDED.  A FIFTH field is not any writer's shape: damaged.  (nonce
         * stays "" at nf==3: b was memset.) */
        int nf = sscanf(p, "%lu %63s %lu %79s %7s", &b.v, b.status, &b.epoch, b.nonce, junk);
        if (nf == 3 || nf == 4) {
            /* The table is FIXED.  Silently dropping the overflow would make
             * the COUNT and the ATTRIBUTION both partial while the run still
             * said "coherent" — a silent pass.  A fixed-array overflow is
             * the most repeated defect in this repo (a bound that goes inert
             * beyond a limit), so it is LOUD here: exit 2, naming the cap,
             * the file and the line. */
            if (g_nbl >= sizeof g_bl / sizeof g_bl[0])
                die("%s has more than %zu parseable lines: this build's .bootlog table (g_bl[%zu]) is FULL at line %zu, and every line past it would be silently dropped from the counting AND the forged-verdict attribution — the audit would report on a file it truncated. Raise the table and re-run (the whole file is already read into memory; only the parsed table is capped)",
                    path, sizeof g_bl / sizeof g_bl[0], sizeof g_bl / sizeof g_bl[0], g_nbl + 1);
            g_bl[g_nbl++] = b;
        } else {
            /* the FINDING is added by check_records_damaged (the reader only
             * records — findings belong to checks so the gate's mutation
             * control can disable exactly one) */
            g_bl_damaged++;
            if (g_bl_damaged == 1) snprintf(g_bl_bad1, sizeof g_bl_bad1, "%s", p);
        }
        p[llen] = save;
        p = nl + 1;
    }
}

/* last non-shutdown verdict per version, in FILE ORDER (bootver_apply's
 * semantics: later entry wins; shutdown is not a boot verdict) */
static int bootlog_last_verdict(unsigned long v, char *out, size_t cap) {
    int got = 0; out[0] = 0;
    for (size_t i = 0; i < g_nbl; i++) {
        if (g_bl[i].v != v) continue;
        if (!strcmp(g_bl[i].status, "shutdown")) continue;
        snprintf(out, cap, "%s", g_bl[i].status);
        got = 1;
    }
    return got;
}

/* .recovery: '#'-prefixed header lines, then data lines "<epoch> <pub> <from> <genhash|->" */
static void read_recovery(void) {
    char path[4096];
    snprintf(path, sizeof path, "%s/.recovery", g_store_abs);
    int absent = 0;
    g_rec_bytes = read_file(path, &g_rec_len, &absent);
    g_rec_absent = absent;
    if (absent) { info(".recovery absent (fx-init creates it on the first boot)"); return; }
    char *p = g_rec_bytes;
    size_t lineno = 0;
    while (p < g_rec_bytes + g_rec_len) {
        char *nl = memchr(p, '\n', (size_t)(g_rec_bytes + g_rec_len - p));
        size_t llen = nl ? (size_t)(nl - p) : (size_t)(g_rec_bytes + g_rec_len - p);
        lineno++;
        if (!nl) break; /* torn tail: a crash mid-write, not a verdict —
                         * counted as torn only for .bootlog; the journal's
                         * torn tail is skipped the same lenient way */
        char save = p[llen]; p[llen] = 0;
        if (p[0] != '#') {
            rec_row_t r; memset(&r, 0, sizeof r);
            char junk[8];
            /* "<epoch> <pub> <from> <genhash|-> <nonce>" (5 fields,
             * init.zig recovery_line); 4 = the pre-nonce history shape;
             * 6 = no writer's shape (damaged) */
            int nf = sscanf(p, "%lu %lu %lu %79s %79s %7s", &r.epoch, &r.published, &r.from_failed, r.genhash, r.nonce, junk);
            if (nf == 4 || nf == 5) {
                r.lineno = lineno;
                r.off = (size_t)(p - g_rec_bytes); /* for the added-row
                                                    * window selection */
                /* same loud-overflow rule as .bootlog: rows past g_rec[]
                 * would vanish from the added-row accounting without a
                 * word */
                if (g_nrec >= sizeof g_rec / sizeof g_rec[0])
                    die("%s has more than %zu data rows: this build's .recovery table (g_rec[%zu]) is FULL at row %zu (line %zu), and every row past it would be silently dropped from the added-row accounting — the audit would report on a file it truncated. Raise the table and re-run",
                        path, sizeof g_rec / sizeof g_rec[0], sizeof g_rec / sizeof g_rec[0], g_nrec + 1, lineno);
                g_rec[g_nrec++] = r;
            } else if (p[0] != 0) {
                g_rec_damaged++;
                if (g_rec_damaged == 1) {
                    snprintf(g_rec_bad1, sizeof g_rec_bad1, "%s", p);
                    g_rec_bad1_lineno = lineno;
                }
            }
        }
        p[llen] = save;
        p = nl + 1;
    }
}

static void read_current_file(void) {
    char path[8192];
    snprintf(path, sizeof path, "%s/.db/snapshots/CURRENT", g_store_abs);
    int absent = 0; size_t len = 0;
    char *b = read_file(path, &len, &absent);
    if (absent) {
        info("CURRENT file absent; resolving to the newest published version (fxstore's own fallback)");
        g_current = g_nvers ? g_vers[g_nvers - 1] : 0;
        g_current_from_file = 0;
        return;
    }
    /* strict: fxstore tolerates garbage via fallback, so a tampered CURRENT
     * is invisible to it — this seat is the one that must see it */
    char *end = NULL;
    unsigned long v = 0;
    int ok = 0;
    for (char *q = b; *q; q++) {
        if (!(*q == ' ' || (*q >= '\t' && *q <= '\r'))) { end = q; break; }
    }
    if (end && *end >= '0' && *end <= '9') {
        v = strtoul(end, &end, 10);
        while (end && (*end == ' ' || (*end >= '\t' && *end <= '\r'))) end++;
        ok = (end && *end == 0) && v > 0 && v <= 0xFFFFFFFFul;
    }
    if (!ok) {
        snprintf(g_current_garbage, sizeof g_current_garbage, "%.40s", b);
        free(b);
    } else {
        g_current_file = (unsigned)v;
        g_current_file_given = 1;
    }
    /* the EFFECTIVE current: the file's value when it is published, else the
     * timeline's newest — the checks must be able to collect EVERY finding,
     * so a broken CURRENT degrades the reads, never the report.  fxstore's
     * own fx_store_current_version has the same fallback semantics. */
    g_current = g_nvers ? g_vers[g_nvers - 1] : 0;
    g_current_from_file = 0;
    if (g_current_file_given && ver_index(g_current_file) >= 0) {
        g_current = g_current_file;
        g_current_from_file = 1;
    }
}

/* ── per-version facts hash ────────────────────────────────────────────── */

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

/* sha256 over, for every relation in the FROZEN list (sorted names), the
 * relation name + its sorted fact lines.  Sorting the lines makes the hash
 * independent of the engine's bag iteration order. */
static void hash_version_facts(unsigned v, char out[65]) {
    char args[8192];
    char *all = xmalloc(1); size_t alen = 0, acap = 1;
    all[0] = 0;
    for (size_t r = 0; r < N_FACT_RELS; r++) {
        snprintf(args, sizeof args, "facts %s --as-of %u --store '%s'", FACT_RELS[r], v, g_store_abs);
        size_t n = 0;
        char **lines = fxstore_lines(args, FACT_RELS[r], &n);
        if (n > 1) qsort(lines, n, sizeof *lines, cmp_str);
        const char *rel_hdr = FACT_RELS[r];
        size_t need = alen + strlen(rel_hdr) + 2;
        for (size_t i = 0; i < n; i++) need += strlen(lines[i]) + 1;
        if (need + 1 > acap) { while (need + 1 > acap) acap *= 2; all = realloc(all, acap); if (!all) die("out of memory"); }
        memcpy(all + alen, rel_hdr, strlen(rel_hdr)); alen += strlen(rel_hdr);
        all[alen++] = '\n';
        for (size_t i = 0; i < n; i++) {
            size_t ll = strlen(lines[i]);
            memcpy(all + alen, lines[i], ll); alen += ll;
            all[alen++] = '\n';
            free(lines[i]);
        }
        free(lines);
        all[alen] = 0;
    }
    sha256_hex(all, alen, out);
    free(all);
}

/* ── S4: the reach readers (the report's/select's shapes, this seat's rule) ─
 * The proxy's registry is read from THE PROXY (`--print-host-tools`: the one
 * closed list its collision check and dispatch lookup read), never re-spelled
 * here.  A named proxy that cannot be run is a LOUD state, not "no host
 * tools": a seat that read a failed probe as an empty registry would record
 * the narrowest possible reach, which is the one direction a capability
 * instrument must never fail in. */
static void reach_read_proxy(void) {
    if (!g_proxy) return;
    char cmd[8192];
    snprintf(cmd, sizeof cmd, "'%s' --print-host-tools 2>/dev/null", g_proxy);
    FILE *p = popen(cmd, "r");
    if (!p) die("cannot popen '%s' (the host-tool registry probe)", g_proxy);
    char line[LINE_MAX_];
    while (fgets(line, sizeof line, p)) {
        line[strcspn(line, "\r\n")] = 0;
        char *q = line;
        while (*q == ' ' || *q == '\t') q++;
        if (!*q) continue;
        if (g_nrtools >= MAX_REACH_TOOLS)
            die("the proxy printed more than %u host tools", (unsigned)MAX_REACH_TOOLS);
        if (strlen(q) >= sizeof g_rtools[0].name)
            die("the proxy printed a host tool name longer than %zu bytes — a TRUNCATED name "
                "is a different tool, so this seat refuses rather than shortens it",
                sizeof g_rtools[0].name - 1);
        snprintf(g_rtools[g_nrtools++].name, sizeof g_rtools[0].name, "%s", q);
    }
    int st = pclose(p);
    int rc = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
    if (rc != 0)
        die("the host proxy '%s' did not answer --print-host-tools (exit %d): the DECLARED "
            "reach of the running host cannot be read, and an unreadable registry is NOT an "
            "empty one", g_proxy, rc);
    g_rtools_known = 1;
}

/* The pinned class tables: the operator's grants.  A row this seat cannot
 * read is LOUD (a skipped row is a grant that vanishes from the audit);
 * eval_ops.py is the validator and owns the grammar. */
static void reach_read_tables(void) {
    static const struct { const char *file, *dim; int aliases; } T[] = {
        { "ops-aliases.tsv", "path", 1 },
        { "ops-hosts.tsv",   "authority", 0 },
    };
    if (!g_opsdir) return;
    for (size_t t = 0; t < sizeof T / sizeof *T; t++) {
        char path[4096];
        snprintf(path, sizeof path, "%s/%s", g_opsdir, T[t].file);
        size_t len = 0; int absent = 0;
        char *b = read_file(path, &len, &absent);
        if (absent) continue;
        g_grants_known = 1;
        char *save = NULL; size_t ln = 0;
        for (char *line = strtok_r(b, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
            ln++;
            size_t ll = strlen(line);
            if (ll && line[ll - 1] == '\r') line[--ll] = 0;
            if (!ll || line[0] == '#') continue;
            char *f[4] = {0}; int nf = 0;
            char *lsave = NULL;
            for (char *tok = strtok_r(line, "\t", &lsave); tok && nf < 4;
                 tok = strtok_r(NULL, "\t", &lsave))
                f[nf++] = tok;
            const char *pattern, *cls, *prot;
            if (T[t].aliases) {
                if (nf != 4)
                    die("%s:%u: a path-class row is alias<TAB>pathclass<TAB>protected<TAB>"
                        "pattern (eval_ops.py --check-aliases validates it; this seat will "
                        "not skip a row it cannot read): \"%s\"", path, ln, line);
                pattern = f[3]; cls = f[1]; prot = f[2];
            } else {
                if (nf != 3)
                    die("%s:%u: a host row is pattern<TAB>argclass<TAB>protected "
                        "(eval_ops.py --check-hosts validates it; this seat will not skip a "
                        "row it cannot read): \"%s\"", path, ln, line);
                pattern = f[0]; cls = f[1]; prot = f[2];
            }
            if (strlen(pattern) >= sizeof g_rgrants[0].pattern)
                die("%s:%u: the pattern exceeds this seat's %zu-byte cap", path, ln,
                    sizeof g_rgrants[0].pattern);
            if (g_ngrants >= MAX_REACH_GRANTS)
                die("%s: more than %u class rows", path, (unsigned)MAX_REACH_GRANTS);
            reachgrant_t *G = &g_rgrants[g_ngrants++];
            snprintf(G->dim, sizeof G->dim, "%s", T[t].dim);
            snprintf(G->pattern, sizeof G->pattern, "%s", pattern);
            snprintf(G->cls, sizeof G->cls, "%s", cls);
            G->prot = !strcmp(prot, "yes");
        }
        free(b);
    }
}

/* THE RELEASE CHECK — is the table on disk the table PINS froze?  A re-pin
 * release is exactly how reach is SUPPOSED to change, so this separates a
 * RELEASED widening (named, not a finding) from an UNRELEASED one (a
 * finding).  State: 1 verified, 0 drifted, -1 unverifiable (PINS absent, not
 * naming a table, or a table it names is missing) — the last takes the LOUD
 * side, because an unverifiable release is not a release. */
static int reach_verify_pins(void) {
    if (!g_opsdir) { snprintf(g_reach_pins_detail, sizeof g_reach_pins_detail, "no --ops-policy-dir"); return -1; }
    char path[4096];
    snprintf(path, sizeof path, "%s/PINS", g_opsdir);
    size_t len = 0; int absent = 0;
    char *b = read_file(path, &len, &absent);
    if (absent) {
        snprintf(g_reach_pins_detail, sizeof g_reach_pins_detail, "%.400s does not exist", path);
        return -1;
    }
    int state = 1, checked = 0;
    char *save = NULL;
    for (char *line = strtok_r(b, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        size_t ll = strlen(line);
        if (ll && line[ll - 1] == '\r') line[--ll] = 0;
        if (!ll || line[0] == '#') continue;
        char *tab = strchr(line, '\t');
        if (!tab) die("%s: a PINS row is <artifact><TAB><sha256>: \"%s\"", path, line);
        *tab = 0;
        if (strcmp(line, "ops-aliases.tsv") && strcmp(line, "ops-hosts.tsv")) continue;
        checked++;
        char apath[4096];
        snprintf(apath, sizeof apath, "%s/%s", g_opsdir, line);
        size_t alen = 0; int aabsent = 0;
        char *ab = read_file(apath, &alen, &aabsent);
        if (aabsent) {
            state = 0;
            snprintf(g_reach_pins_detail, sizeof g_reach_pins_detail,
                     "%.200s is named by PINS and is NOT THERE", line);
            continue;
        }
        char sha[65];
        sha256_hex(ab, alen, sha);
        free(ab);
        if (strcmp(sha, tab + 1) != 0) {
            state = 0;
            snprintf(g_reach_pins_detail, sizeof g_reach_pins_detail,
                     "%.200s hashes to %s but PINS pins %s", line, sha, tab + 1);
        }
    }
    free(b);
    if (!checked) {
        snprintf(g_reach_pins_detail, sizeof g_reach_pins_detail,
                 "%.400s/PINS names neither class table", g_opsdir);
        return -1;
    }
    if (state == 1) snprintf(g_reach_pins_detail, sizeof g_reach_pins_detail,
                             "both class tables hash to their PIN");
    return state;
}

/* ── S4b: the composed sandbox reader and its own pin check ─────────────── */

/* Read the composition from the proxy ITSELF.  A proxy that cannot answer is
 * LOUD (never "no sandbox"): a capability instrument that read a failed probe
 * as the narrowest possible declaration would fail in exactly the direction
 * it exists to catch. */
static void sandbox_read_composed(void) {
    if (!g_proxy) return;
    char cmd[8192];
    snprintf(cmd, sizeof cmd, "'%s' --print-sandbox 2>/dev/null", g_proxy);
    FILE *p = popen(cmd, "r");
    if (!p) die("cannot popen '%s --print-sandbox' (the composed sandbox probe)", g_proxy);
    char line[LINE_MAX_];
    while (fgets(line, sizeof line, p)) {
        line[strcspn(line, "\r\n")] = 0;
        if (!line[0]) continue;
        char *f[3] = {0};
        int nf = 0;
        char *save = NULL;
        for (char *tok = strtok_r(line, "\t", &save); tok && nf < 3;
             tok = strtok_r(NULL, "\t", &save))
            f[nf++] = tok;
        if (nf < 2)
            die("'%s --print-sandbox' printed a row that is not name<TAB>promises<TAB>"
                "landlock: \"%s\" — a spec this seat cannot read is refused, never "
                "skipped", g_proxy, line);
        if (g_nsbt >= MAX_SB_TOOLS)
            die("'%s --print-sandbox' printed more than %u composed specs",
                g_proxy, (unsigned)MAX_SB_TOOLS);
        sandbox_t *S = &g_sbt[g_nsbt++];
        snprintf(S->name, sizeof S->name, "%s", f[0]);
        snprintf(S->promises, sizeof S->promises, "%s", f[1]);
        snprintf(S->landlock, sizeof S->landlock, "%s", nf > 2 ? f[2] : "");
    }
    int st = pclose(p);
    int rc = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
    if (rc != 0)
        die("the host proxy '%s' did not answer --print-sandbox (exit %d): the COMPOSED "
            "sandbox of the running host cannot be read, and an unreadable composition is "
            "NOT an empty one", g_proxy, rc);
    if (g_nsbt == 0)
        die("'%s --print-sandbox' printed NO tool: the proxy's closed registry cannot be "
            "empty, so this is a tool error, not a sandbox with nothing in it", g_proxy);
    /* ONE sha over the whole block, so a reader can compare two observations
     * at a glance while the per-tool rows remain the evidence */
    struct tbuf_sha { char *p; size_t len, cap; } t = {0};
    for (size_t i = 0; i < g_nsbt; i++) {
        char row[4096];
        int n = snprintf(row, sizeof row, "%.127s\t%.1023s\t%.2047s\n", g_sbt[i].name,
                         g_sbt[i].promises, g_sbt[i].landlock);
        if (n < 0) continue;
        size_t l = (size_t)n;
        if (t.len + l + 1 > t.cap) {
            t.cap = (t.len + l + 1) * 2;
            t.p = realloc(t.p, t.cap);
            if (!t.p) die("out of memory");
        }
        memcpy(t.p + t.len, row, l);
        t.len += l;
        t.p[t.len] = 0;
    }
    sha256_hex(t.p ? t.p : "", t.len, g_sb_sha);
    free(t.p);
    g_sbt_known = 1;
}

/* THE OPERATOR HALF'S PIN — ops-sandbox.tsv against PINS.  This is the ONLY
 * pinned part of the composition, and it is reported so a reader can tell an
 * unreleased OPERATOR edit from an unpinned SIDECAR edit; it can never
 * LICENSE a widening (the table is deny-more-only, enforced at the seat). */
static int sandbox_verify_pins(void) {
    if (!g_opsdir) { snprintf(g_sb_pins_detail, sizeof g_sb_pins_detail, "no --ops-policy-dir"); return -1; }
    char path[4096];
    snprintf(path, sizeof path, "%s/PINS", g_opsdir);
    size_t len = 0; int absent = 0;
    char *b = read_file(path, &len, &absent);
    if (absent) {
        snprintf(g_sb_pins_detail, sizeof g_sb_pins_detail, "%.400s does not exist", path);
        return -1;
    }
    int state = -1;
    char *save = NULL;
    for (char *line = strtok_r(b, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        size_t ll = strlen(line);
        if (ll && line[ll - 1] == '\r') line[--ll] = 0;
        if (!ll || line[0] == '#') continue;
        char *tab = strchr(line, '\t');
        if (!tab) die("%s: a PINS row is <artifact><TAB><sha256>: \"%s\"", path, line);
        *tab = 0;
        if (strcmp(line, "ops-sandbox.tsv")) continue;
        char apath[4096];
        snprintf(apath, sizeof apath, "%s/%s", g_opsdir, line);
        size_t alen = 0; int aabsent = 0;
        char *ab = read_file(apath, &alen, &aabsent);
        if (aabsent) {
            state = 0;
            snprintf(g_sb_pins_detail, sizeof g_sb_pins_detail,
                     "%.200s is named by PINS and is NOT THERE", line);
            break;
        }
        char sha[65];
        sha256_hex(ab, alen, sha);
        free(ab);
        if (strcmp(sha, tab + 1) != 0) {
            state = 0;
            snprintf(g_sb_pins_detail, sizeof g_sb_pins_detail,
                     "%.200s hashes to %s but PINS pins %s", line, sha, tab + 1);
        } else {
            state = 1;
            snprintf(g_sb_pins_detail, sizeof g_sb_pins_detail,
                     "%.200s hashes to its PIN", line);
        }
        break;
    }
    free(b);
    if (state == -1)
        snprintf(g_sb_pins_detail, sizeof g_sb_pins_detail,
                 "%.400s/PINS does not name ops-sandbox.tsv", g_opsdir);
    return state;
}

/* ── S5: the access-table reader, its release check, and the armed set ──── */

/* Read the operator's access table FROM THE FILE — and the reason is the
 * RELEASE QUESTION itself, stated because the surprising half is the route:
 *
 *   THE PROXY'S LOADER (`--print-access`) cannot answer what this seat is for.
 *   It sha256-verifies the table against PINS and REFUSES TO START on a stale
 *   one, so a table that has drifted from its release never reaches the
 *   printer — and "was this widening RELEASED?" would then always answer "yes"
 *   for every reading that exists.  An instrument that can only ever report
 *   the licensed case is the blind shape this tree keeps finding.
 *
 *   So the audit reads the DECLARED file (the same way it reads
 *   ops-aliases.tsv/ops-hosts.tsv) and verifies it against THIS DIRECTORY's
 *   PINS itself.  The three states are then real: the bytes on disk, the
 *   release that pins them, and the difference between them.  The loader's
 *   own refusal is not lost — it is what stops a JUDGE from running on a stale
 *   table; here the same fact is reported as DRIFT plus an unreleased
 *   widening, which is the finding (a silent no-change would be the failure).
 *
 * The grammar is the pinned one — `verb<TAB>allow|deny`, exact names, '#'
 * comments and blank lines skipped — and a row this seat cannot read is LOUD
 * (a skipped row is a capability that vanishes from the delta). */
static void access_read_table(void) {
    if (!g_accessdir) return;
    char path[4096];
    snprintf(path, sizeof path, "%s/access-verbs.tsv", g_accessdir);
    size_t len = 0; int absent = 0;
    char *b = read_file(path, &len, &absent);
    if (absent)
        die("--access-dir '%s' holds no access-verbs.tsv: an absent table is NOT an empty "
            "vocabulary (the judge refuses to start without one, so reading it as 'every verb "
            "unchanged' — or as 'nothing is allowed' — would invent a state)", g_accessdir);
    char *save = NULL;
    size_t ln = 0;
    for (char *line = strtok_r(b, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        ln++;
        size_t ll = strlen(line);
        if (ll && line[ll - 1] == '\r') line[--ll] = 0;
        if (!ll || line[0] == '#') continue;
        char *f[3] = {0};
        int nf = 0;
        char *lsave = NULL;
        for (char *tok = strtok_r(line, "\t", &lsave); tok && nf < 3;
             tok = strtok_r(NULL, "\t", &lsave))
            f[nf++] = tok;
        if (nf != 2 || (strcmp(f[1], "allow") && strcmp(f[1], "deny")))
            die("%s:%zu: an access row is verb<TAB>allow|deny (the table has no third state, so "
                "a row this seat cannot read is refused, never skipped): \"%s\"", path, ln, line);
        if (g_natab >= MAX_ACCESS_VERBS)
            die("%s: more than %u verbs", path, (unsigned)MAX_ACCESS_VERBS);
        accessverb_t *V = &g_atab[g_natab++];
        snprintf(V->name, sizeof V->name, "%s", f[0]);
        V->allow = !strcmp(f[1], "allow");
    }
    free(b);
    if (g_natab == 0)
        die("%s holds no access row: the table is TOTAL over a non-empty closed vocabulary, so "
            "an empty reading is a tool error, not a vocabulary with nothing in it", path);
    g_atab_known = 1;
}

/* THE RELEASE CHECK for the access table: is the file on disk the bytes
 * policy/access/PINS froze?  1 = yes (a re-pin RELEASE — a widening is then a
 * named operator act, not a finding), 0 = drift, -1 = unverifiable (PINS
 * absent, not naming the table, or the table missing) — the last takes the
 * LOUD side, because an unverifiable release is not a release. */
static int access_verify_pins(void) {
    if (!g_accessdir) {
        snprintf(g_access_pins_detail, sizeof g_access_pins_detail, "no --access-dir");
        return -1;
    }
    char path[4096];
    snprintf(path, sizeof path, "%s/PINS", g_accessdir);
    size_t len = 0; int absent = 0;
    char *b = read_file(path, &len, &absent);
    if (absent) {
        snprintf(g_access_pins_detail, sizeof g_access_pins_detail, "%.400s does not exist", path);
        return -1;
    }
    int state = -1;
    char *save = NULL;
    for (char *line = strtok_r(b, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        size_t ll = strlen(line);
        if (ll && line[ll - 1] == '\r') line[--ll] = 0;
        if (!ll || line[0] == '#') continue;
        char *tab = strchr(line, '\t');
        if (!tab) die("%s: a PINS row is <artifact><TAB><sha256>: \"%s\"", path, line);
        *tab = 0;
        if (strcmp(line, "access-verbs.tsv")) continue;
        char apath[4096];
        snprintf(apath, sizeof apath, "%s/%s", g_accessdir, line);
        size_t alen = 0; int aabsent = 0;
        char *ab = read_file(apath, &alen, &aabsent);
        if (aabsent) {
            state = 0;
            snprintf(g_access_pins_detail, sizeof g_access_pins_detail,
                     "%.200s is named by PINS and is NOT THERE", line);
            break;
        }
        char sha[65];
        sha256_hex(ab, alen, sha);
        free(ab);
        if (strcmp(sha, tab + 1) != 0) {
            state = 0;
            snprintf(g_access_pins_detail, sizeof g_access_pins_detail,
                     "%.200s hashes to %s but PINS pins %s", line, sha, tab + 1);
        } else {
            state = 1;
            snprintf(g_access_pins_detail, sizeof g_access_pins_detail,
                     "%.200s hashes to its PIN", line);
        }
        break;
    }
    free(b);
    if (state == -1)
        snprintf(g_access_pins_detail, sizeof g_access_pins_detail,
                 "%.400s/PINS does not name access-verbs.tsv", g_accessdir);
    return state;
}

/* THE ARMED-AUTHOR SET, as THIS observation can see it, "+"-joined in judge
 * order (denylist -> access -> ops -> justification -> claim).  Only the
 * middle members are observable from here — the denylist is compiled into the
 * proxy, and the justification arm and the claim author are flags of the
 * JUDGE, not of this seat — so the value is a LOWER BOUND and every row that
 * prints it says so.  Recorded rather than left to a transient stderr line:
 * "the access seat was armed on the gates and absent on the real lane" is the
 * shape R5 names, and a boot's record is the only place that absence can be
 * durable. */
static void armed_authors_compute(void) {
    if (!g_proxy && !g_opsdir && !g_accessdir) return;
    size_t n = 0;
    g_armed[0] = 0;
#define ARMED_ADD(s)                                                          \
    do {                                                                      \
        n += (size_t)snprintf(g_armed + n, n < sizeof g_armed ? sizeof g_armed - n : 0, \
                              "%s%s", n ? "+" : "", (s));                     \
    } while (0)
    if (g_atab_known) ARMED_ADD("access");
    if (g_grants_known) ARMED_ADD("ops");
#undef ARMED_ADD
    if (n == 0) snprintf(g_armed, sizeof g_armed, "none");
    g_armed_known = 1;
}

/* The boot this observation is anchored to: the LAST line .bootlog holds.
 * The reach measured NOW belongs to the boot the audit ran after — the seat
 * says exactly that and never attributes today's registry to an earlier
 * boot's generation. */
static void reach_anchor_boot(void) {
    if (g_nbl == 0) return;
    bl_line_t *b = &g_bl[g_nbl - 1];
    g_reach_boot_v = b->v;
    g_reach_boot_known = 1;
    snprintf(g_reach_boot_nonce, sizeof g_reach_boot_nonce, "%s", b->nonce[0] ? b->nonce : "none");
}

/* Emit the observation in the SHARED grammar (the tags fx-select prints and
 * consumes), plus the boot it is anchored to. */
static void emit_reach_rows(void) {
    if (!g_proxy && !g_opsdir && !g_accessdir) return;
    for (size_t i = 0; i < g_nrtools; i++) printf("reach-tool\t%s\n", g_rtools[i].name);
    for (size_t i = 0; i < g_ngrants; i++)
        printf("reach-grant\t%s\t%s\t%s\t%s\n", g_rgrants[i].dim, g_rgrants[i].pattern,
               g_rgrants[i].cls, g_rgrants[i].prot ? "yes" : "no");
    /* S5: the tool VOCABULARY, in the SHARED grammar fx-select consumes via
     * --reach-prev — so the seat that judges generations builds its baseline
     * from what THIS seat recorded around a boot, never from a second read. */
    for (size_t i = 0; i < g_natab; i++)
        printf("reach-verb\t%s\t%s\n", g_atab[i].name, g_atab[i].allow ? "allow" : "deny");
    if (g_reach_boot_known)
        printf("reach-boot\t%lu\tnonce\t%s\tMEASURED\tthe reach recorded around this boot "
               "(the LAST .bootlog line): the host tool(s) and pinned class row(s) above are "
               "what the HOST could run WHEN THIS OBSERVATION WAS TAKEN — a registry read at "
               "observation time, never a reconstruction of what an earlier boot could reach\n",
               g_reach_boot_v, g_reach_boot_nonce);
    else
        printf("reach-boot\t-\tnonce\t-\tABSENT\tthis store has no .bootlog line, so the reach "
               "observation is NOT attributed to any boot (it is still measured — the host's "
               "registry and tables are read now)\n");
    if (!g_proxy)
        printf("reach-absence\tregistry\tnot-given-no---proxy-so-the-host-tool-half-of-the-"
               "reach-observation-is-NOT-KNOWN (NOT 'the host runs nothing')\tABSENT\n");
    if (!g_opsdir)
        printf("reach-absence\tclass-tables\tnot-given-no---ops-policy-dir-so-the-grant-half-"
               "of-the-reach-observation-is-NOT-KNOWN (NOT 'nothing is granted')\tABSENT\n");
    if (!g_accessdir)
        printf("reach-absence\taccess-table\tnot-given-no---access-dir-so-the-VOCABULARY-half-"
               "of-the-reach-observation-is-NOT-KNOWN (NOT 'no verb is allowed' and NOT 'no "
               "verb changed')\tABSENT\n");

    /* S5: WHICH AUTHORS COULD REFUSE, as this observation saw them, beside the
     * boot it was taken around — the durable record R5 asks for, with its own
     * scope stated in its own bytes (a LOWER BOUND: only the members this
     * seat's inputs make observable). */
    if (g_armed_known) {
        if (g_reach_boot_known)
            printf("authors-armed\t%s\tboot\t%lu\tnonce\t%s\tMEASURED\tthe AUTHORS this "
                   "observation could SEE armed (access = the operator's access table was read, "
                   "ops = the pinned class tables were read), recorded around the LAST .bootlog "
                   "line: a LOWER BOUND, NOT a statement about the judge's own flags — the "
                   "compiled-in denylist, the justification arm and the claim author are not "
                   "queryable from this seat and are therefore NOT in this set.  A boot's record "
                   "says what could have refused; 'none' here is the absence made durable rather "
                   "than inferred from a transient stderr line\n", g_armed, g_reach_boot_v,
                   g_reach_boot_nonce);
        else
            printf("authors-armed\t%s\tboot\t-\tnonce\t-\tABSENT\tthe AUTHORS this "
                   "observation could SEE armed (a LOWER BOUND: see the bound line) — this store "
                   "has no .bootlog line, so the set is NOT attributed to any boot\n", g_armed);
    }
}

/* Emit the composed sandbox in the SHARED grammar (the tag fx-select prints
 * and consumes via --reach-prev: `reach-sandbox <tool> <promises> <landlock>`),
 * per tool, BESIDE the boot it was taken around.  Nothing here is a verdict:
 * the delta is the check's job, and a reader must be able to reconstruct
 * WHAT was compared from the record alone. */
static void emit_sandbox_rows(void) {
    if (!g_proxy) return;
    for (size_t i = 0; i < g_nsbt; i++) {
        printf("reach-sandbox\t%s\t%s\t%s\n", g_sbt[i].name, g_sbt[i].promises,
               g_sbt[i].landlock);
        printf("sandbox-spec\t%s\tpromises\t%s\tlandlock\t%s\tsha\t", g_sbt[i].name,
               g_sbt[i].promises, g_sbt[i].landlock);
        char row[4096], sha[65];
        snprintf(row, sizeof row, "%.127s\t%.1023s\t%.2047s\n", g_sbt[i].name,
                 g_sbt[i].promises, g_sbt[i].landlock);
        sha256_hex(row, strlen(row), sha);
        printf("%s\tMEASURED\tthe composed spec this host would apply to %s (the executor's "
               "baseline + the tool's sidecar, read from the proxy itself)\n", sha,
               g_sbt[i].name);
    }
    printf("sandbox-composed-sha\t%s\tMEASURED\tone sha over the whole composed spec block: "
           "two observations can be compared at a glance, and the per-tool rows above remain "
           "the evidence\n", g_sb_sha);
    if (g_reach_boot_known)
        printf("sandbox-boot\t%lu\tnonce\t%s\tMEASURED\tthe composed sandbox recorded around "
               "this boot (the LAST .bootlog line): a sandbox read at observation time, never "
               "a reconstruction of what an earlier boot's sandbox was\n",
               g_reach_boot_v, g_reach_boot_nonce);
    else
        printf("sandbox-boot\t-\tnonce\t-\tABSENT\tthis store has no .bootlog line, so the "
               "sandbox record is NOT attributed to any boot (it is still measured — the "
               "composition is read now)\n");
}

/* ── the observation store ─────────────────────────────────────────────── */

static void obs_path_for(char *out, size_t cap) {
    if (g_obsfile) { snprintf(out, cap, "%s", g_obsfile); return; }
    char key[65]; char kb[8192];
    snprintf(kb, sizeof kb, "store:%s", g_store_abs);
    sha256_hex(kb, strlen(kb), key);
    key[16] = 0;
    snprintf(out, cap, "%s/%s.obs", g_obsdir, key);
}

static void obs_write(void) {
    char path[4096];
    obs_path_for(path, sizeof path);
    if (!g_obsfile) {
        /* create the observation dir (first use) */
        char dir[4096];
        snprintf(dir, sizeof dir, "%s", path);
        char *slash = strrchr(dir, '/');
        if (slash) {
            *slash = 0;
            mkdir(dir, 0755); /* EEXIST is fine; other errors die below */
        }
    }
    char tmp[4200];
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    FILE *f = fopen(tmp, "w");
    if (!f) die("cannot write observation '%s': %s", tmp, strerror(errno));
    char sha[65];
    /* FORMAT 3: adds nothing over 2 field-wise; the bump is the REGIME
     * marker — a format-2 baseline predates the per-boot nonce and its
     * window semantics differ (added lines were never nonce-judged), so it
     * is refused rather than assumed (see obs_read). */
    fprintf(f, "fx-audit-observation 3\n");
    fprintf(f, "store %s\n", g_store_abs);
    if (g_bl_absent) fprintf(f, "bootlog_absent 1\n");
    else {
        sha256_hex(g_bl_bytes ? g_bl_bytes : "", g_bl_len, sha);
        fprintf(f, "bootlog_bytes %zu\nbootlog_sha256 %s\n", g_bl_len, sha);
    }
    if (g_rec_absent) fprintf(f, "recovery_absent 1\n");
    else {
        sha256_hex(g_rec_bytes ? g_rec_bytes : "", g_rec_len, sha);
        fprintf(f, "recovery_bytes %zu\nrecovery_sha256 %s\n", g_rec_len, sha);
    }
    fprintf(f, "current %u\n", g_current);
    fprintf(f, "host_boots %lu\n", g_boots);
    for (size_t i = 0; i < g_nvers; i++)
        fprintf(f, "version %u genhash %s facts %s\n", g_vers[i],
                g_genhash[i][0] ? g_genhash[i] : "-",
                g_facts_hash[i][0] ? g_facts_hash[i] : "-");
    for (size_t i = 0; i < g_nartifacts; i++)
        fprintf(f, "artifact %s\n", g_artifacts[i]);
    /* S4: the proxy's one log as a KNOWN RECORD (its bytes + sha, the
     * .bootlog/.recovery discipline extended to the host's account of what
     * it ran), and the DECLARED REACH this observation measured.  Both are
     * written only when they were GIVEN: their absence in a baseline is
     * NOT-KNOWN for that dimension, and an optional field that silently
     * defaulted to "empty" would read as "no capability" — the one reading
     * a capability instrument must never invent. */
    if (g_plog_given) {
        if (g_plog_absent) fprintf(f, "proxy_log_absent 1\n");
        else {
            sha256_hex(g_plog_bytes ? g_plog_bytes : "", g_plog_len, sha);
            fprintf(f, "proxy_log_bytes %zu\nproxy_log_sha256 %s\n", g_plog_len, sha);
        }
    }
    if (g_proxy || g_opsdir) {
        for (size_t i = 0; i < g_nrtools; i++)
            fprintf(f, "reach_tool\t%s\n", g_rtools[i].name);
        for (size_t i = 0; i < g_ngrants; i++)
            fprintf(f, "reach_grant\t%s\t%s\t%s\t%s\n", g_rgrants[i].dim,
                    g_rgrants[i].pattern, g_rgrants[i].cls, g_rgrants[i].prot ? "yes" : "no");
    }
    /* S4b: the COMPOSED SANDBOX, per tool, plus one sha over the block.  Written
     * only when the proxy answered: a baseline that carries no sandbox_ line is
     * NOT-KNOWN for this dimension (never "the sandbox was empty"), exactly the
     * discipline the proxy-log and reach records above follow. */
    if (g_sbt_known) {
        fprintf(f, "sandbox_sha256 %s\n", g_sb_sha);
        for (size_t i = 0; i < g_nsbt; i++)
            fprintf(f, "sandbox_tool\t%s\t%s\t%s\n", g_sbt[i].name, g_sbt[i].promises,
                    g_sbt[i].landlock);
    }
    /* S5: the TOOL VOCABULARY this observation measured, and the authors it
     * could see armed.  Both are written only when they were READ: a baseline
     * without them is NOT-KNOWN for that dimension (never "the vocabulary was
     * empty" and never "no author was armed" — the last being the exact
     * reading a durable absence must not fabricate). */
    if (g_atab_known)
        for (size_t i = 0; i < g_natab; i++)
            fprintf(f, "access_verb\t%s\t%s\n", g_atab[i].name,
                    g_atab[i].allow ? "allow" : "deny");
    if (g_armed_known) fprintf(f, "armed_authors\t%s\n", g_armed);
    fprintf(f, "end\n");
    fflush(f);
    if (ferror(f)) die("cannot write observation '%s'", tmp);
    fclose(f);
    if (rename(tmp, path) != 0) die("cannot rename '%s' -> '%s': %s", tmp, path, strerror(errno));
}

static void obs_read(void) {
    char path[4096];
    obs_path_for(path, sizeof path);
    FILE *f = fopen(path, "r");
    if (!f) {
        if (errno == ENOENT) return; /* first-ever run: enroll */
        die("cannot open observation '%s': %s", path, strerror(errno));
    }
    char line[LINE_MAX_];
    line[0] = 0;
    if (!fgets(line, sizeof line, f) || strcmp(line, "fx-audit-observation 3\n") != 0) {
        /* a format-1 file is a baseline from BEFORE the host-boot anchor:
         * it carries no boot count, so the appended-line accounting has no
         * delta to compare against.  Assuming one is exactly the silent
         * default this seat refuses — die loudly and name the way out. */
        if (line[0] && !strncmp(line, "fx-audit-observation 1", 22))
            die("observation '%s' is FORMAT 1 (predates --boots): it recorded no host boot count, so .bootlog growth cannot be anchored against it — re-establish the baseline with --re-enroll --boots N (the enrollment gap applies until then)", path);
        /* a format-2 file predates the per-boot nonce: its windows were
         * never nonce-judged, so a nonce accounting computed against it
         * would compare growth measured under two different regimes — the
         * same silent assumption, refused the same way */
        if (line[0] && !strncmp(line, "fx-audit-observation 2", 22))
            die("observation '%s' is FORMAT 2 (predates the per-boot nonce): its baseline was taken before .bootlog lines were nonce-bound, so this window's growth cannot be nonce-judged against it — re-establish the baseline with --re-enroll --boots N --nonces F (the enrollment gap applies until then)", path);
        die("observation '%s' is not format 3", path);
    }
    while (fgets(line, sizeof line, f)) {
        char name[64], v1[4096], v2[4096], v3[4096];
        if (sscanf(line, "store %4095s", v1) == 1) continue;
        if (strncmp(line, "bootlog_bytes ", 14) == 0) { g_obs_bl_bytes = strtoul(line + 14, NULL, 10); continue; }
        if (strncmp(line, "bootlog_sha256 ", 15) == 0) { if (sscanf(line + 15, "%64s", g_obs_bl_sha) != 1) die("bad obs line: %s", line); continue; }
        if (strncmp(line, "bootlog_absent", 14) == 0) { g_obs_bl_absent = 1; continue; }
        if (strncmp(line, "recovery_bytes ", 15) == 0) { g_obs_rec_bytes = strtoul(line + 15, NULL, 10); continue; }
        if (strncmp(line, "recovery_sha256 ", 16) == 0) { if (sscanf(line + 16, "%64s", g_obs_rec_sha) != 1) die("bad obs line: %s", line); continue; }
        if (strncmp(line, "recovery_absent", 15) == 0) { g_obs_rec_absent = 1; continue; }
        if (sscanf(line, "current %u", &g_obs_current) == 1) continue;
        if (sscanf(line, "host_boots %lu", &g_obs_boots) == 1) continue;
        unsigned vv;
        if (sscanf(line, "version %u", &vv) == 1) {
            if (g_nobs_vers >= MAX_VERSIONS) die("observation has too many versions");
            char *gh = line, *fa;
            /* format: version <v> genhash <g> facts <f> */
            if (!(gh = strstr(line, " genhash ")) || !(fa = strstr(gh + 9, " facts ")))
                die("bad version line in observation: %s", line);
            *fa = 0; fa += 7;
            gh += 9;
            gh[strcspn(gh, "\n")] = 0; fa[strcspn(fa, "\n")] = 0;
            g_obs_vers[g_nobs_vers] = vv;
            if (!strcmp(gh, "-")) g_obs_genhash[g_nobs_vers][0] = 0;
            else snprintf(g_obs_genhash[g_nobs_vers], 65, "%.64s", gh);
            if (!strcmp(fa, "-")) g_obs_facts[g_nobs_vers][0] = 0;
            else snprintf(g_obs_facts[g_nobs_vers], 65, "%.64s", fa);
            g_nobs_vers++;
            continue;
        }
        if (strncmp(line, "proxy_log_bytes ", 16) == 0) { g_obs_plog_bytes = strtoul(line + 16, NULL, 10); g_obs_plog_known = 1; continue; }
        if (strncmp(line, "proxy_log_sha256 ", 17) == 0) {
            if (sscanf(line + 17, "%64s", g_obs_plog_sha) != 1) die("bad obs line: %s", line);
            g_obs_plog_known = 1;
            continue;
        }
        if (strncmp(line, "proxy_log_absent", 16) == 0) { g_obs_plog_absent = 1; g_obs_plog_known = 1; continue; }
        if (strncmp(line, "sandbox_sha256 ", 15) == 0) {
            if (sscanf(line + 15, "%64s", g_obs_sb_sha) != 1) die("bad obs line: %s", line);
            g_obs_sandbox_known = 1;
            continue;
        }
        if (strncmp(line, "sandbox_tool\t", 13) == 0) {
            char *c = line + 13;
            char *f3[3] = {0};
            int nf3 = 0;
            char *ssave = NULL;
            for (char *tok = strtok_r(c, "\t", &ssave); tok && nf3 < 3;
                 tok = strtok_r(NULL, "\t", &ssave))
                f3[nf3++] = tok;
            if (nf3 < 1 || !f3[0][0]) die("bad sandbox_tool row in observation: %s", line);
            if (g_npsbt >= MAX_SB_TOOLS) die("observation has too many sandbox_tool rows");
            sandbox_t *S = &g_psbt[g_npsbt++];
            snprintf(S->name, sizeof S->name, "%.*s", (int)sizeof S->name - 1, f3[0]);
            snprintf(S->promises, sizeof S->promises, "%s", nf3 > 1 ? f3[1] : "");
            snprintf(S->landlock, sizeof S->landlock, "%s", nf3 > 2 ? f3[2] : "");
            /* the LAST field still carries the record's line terminator: a
             * comparison that kept it would report the baseline's own last
             * landlock entry as an ADDITION on every run (MEASURED: the first
             * run of this check fired on an unchanged composition for exactly
             * that reason) */
            S->name[strcspn(S->name, "\r\n")] = 0;
            S->promises[strcspn(S->promises, "\r\n")] = 0;
            S->landlock[strcspn(S->landlock, "\r\n")] = 0;
            g_obs_sandbox_known = 1;
            continue;
        }
        if (strncmp(line, "access_verb\t", 12) == 0) {
            char *c = line + 12;
            char *f2[3] = {0};
            int nf2 = 0;
            char *asave = NULL;
            for (char *tok = strtok_r(c, "\t", &asave); tok && nf2 < 3;
                 tok = strtok_r(NULL, "\t", &asave))
                f2[nf2++] = tok;
            if (nf2 < 2) die("bad access_verb row in observation: %s", line);
            f2[1][strcspn(f2[1], "\r\n")] = 0;
            if (strcmp(f2[1], "allow") && strcmp(f2[1], "deny"))
                die("bad access_verb decision in observation (allow|deny only): %s", line);
            if (g_npatab >= MAX_ACCESS_VERBS) die("observation has too many access_verb rows");
            accessverb_t *V = &g_patab[g_npatab++];
            snprintf(V->name, sizeof V->name, "%.*s", (int)sizeof V->name - 1, f2[0]);
            V->allow = !strcmp(f2[1], "allow");
            g_obs_access_known = 1;
            continue;
        }
        if (strncmp(line, "armed_authors\t", 14) == 0) {
            snprintf(g_obs_armed, sizeof g_obs_armed, "%.*s", (int)sizeof g_obs_armed - 1,
                     line + 14);
            g_obs_armed[strcspn(g_obs_armed, "\r\n")] = 0;
            g_obs_armed_known = 1;
            continue;
        }
        if (strncmp(line, "reach_tool\t", 11) == 0) {
            char *n = line + 11;
            n[strcspn(n, "\r\n")] = 0;
            if (g_nptools >= MAX_REACH_TOOLS) die("observation has too many reach_tool rows");
            if (strlen(n) >= sizeof g_ptools[0].name)
                die("the observation carries a reach_tool name longer than %zu bytes",
                    sizeof g_ptools[0].name - 1);
            snprintf(g_ptools[g_nptools++].name, sizeof g_ptools[0].name, "%s", n);
            g_obs_reach_known = 1;
            continue;
        }
        if (strncmp(line, "reach_grant\t", 12) == 0) {
            char *c = line + 12;
            char *f4[4] = {0};
            int nf4 = 0;
            char *rsave = NULL;
            for (char *tok = strtok_r(c, "\t", &rsave); tok && nf4 < 4; tok = strtok_r(NULL, "\t", &rsave))
                f4[nf4++] = tok;
            if (nf4 < 4) die("bad reach_grant row in observation: %s", line);
            if (g_npgrants >= MAX_REACH_GRANTS) die("observation has too many reach_grant rows");
            reachgrant_t *G = &g_pgrants[g_npgrants++];
            snprintf(G->dim, sizeof G->dim, "%.*s", (int)sizeof G->dim - 1, f4[0]);
            snprintf(G->pattern, sizeof G->pattern, "%s", f4[1]);
            snprintf(G->cls, sizeof G->cls, "%.*s", (int)sizeof G->cls - 1, f4[2]);
            f4[3][strcspn(f4[3], "\r\n")] = 0;
            G->prot = !strcmp(f4[3], "yes");
            g_obs_reach_known = 1;
            continue;
        }
        if (sscanf(line, "artifact %255s", v1) == 1) {
            g_obs_artifacts = realloc(g_obs_artifacts, (g_nobs_artifacts + 1) * sizeof *g_obs_artifacts);
            if (!g_obs_artifacts) die("out of memory");
            snprintf(g_obs_artifacts[g_nobs_artifacts], sizeof g_obs_artifacts[g_nobs_artifacts], "%.*s", (int)(sizeof g_obs_artifacts[g_nobs_artifacts] - 1), v1);
            g_nobs_artifacts++;
            continue;
        }
        if (!strcmp(line, "end\n")) { g_have_obs = 1; fclose(f); return; }
        (void)name; (void)v2; (void)v3;
        die("unknown line in observation '%s': %s", path, line);
    }
    fclose(f);
    die("observation '%s' has no end marker (torn write?)", path);
}

/* ── S4: the proxy's one log as a KNOWN RECORD (its own check) ──────────── */

/* Read the log as BYTES — this seat never parses the proxy's rows (the
 * REPORTER owns that grammar); what it needs is the record's identity, so a
 * truncation or an in-place rewrite can be caught on the next observation,
 * exactly as .bootlog's and .recovery's are. */
static void read_proxy_log_record(void) {
    if (!g_plog) return;
    g_plog_given = 1;
    size_t len = 0; int absent = 0;
    g_plog_bytes = read_file(g_plog, &len, &absent);
    g_plog_len = len;
    g_plog_absent = absent;
}

/* The log is APPEND-ONLY by construction (the proxy re-renders its rows and
 * writes them once), so the previous observation's prefix must still hash the
 * same.  A failure direction worth naming: treating a vanished log as "no
 * calls" would let a host log be deleted to hide what ran — this seat says
 * the RECORD was removed, and says which byte count it had. */
static void check_proxy_log(void) {
    if (!g_plog_given) {
        info("proxy log: no --proxy-log given — the host's own account of what it ran is NOT-KNOWN to this audit (NOT 'the host ran nothing')");
        return;
    }
    if (g_plog_absent) {
        if (g_obs_plog_known && !g_obs_plog_absent)
            add_finding("record-vanished",
                        "the host proxy's one log ('%s') was present (%zu byte(s) at the previous "
                        "observation) and is now ABSENT — the host's own account of what it ran "
                        "was REMOVED between audits (deleting the record is not the same as "
                        "nothing having happened)", g_plog, g_obs_plog_bytes);
        else
            info("proxy log: '%s' does not exist — NO host record was produced for this span, so the log class is NOT-KNOWN here (never 'no call was made')", g_plog);
        return;
    }
    if (!g_have_obs || !g_obs_plog_known) {
        info("proxy log: %zu byte(s) recorded as a KNOWN record%s — the append accounting starts on the next observation", g_plog_len,
             g_have_obs ? " (the baseline predates the proxy-log record: no comparison is possible for it)" : " (first observation of this store)");
        return;
    }
    if (g_obs_plog_absent) {
        info("transition: the proxy log was absent at the previous observation and holds %zu byte(s) now", g_plog_len);
        return;
    }
    if (g_plog_len < g_obs_plog_bytes) {
        add_finding("disagreement-proxy-log-rewritten",
                    "the host proxy's one log was %zu byte(s) at the previous observation and is %zu now — TRUNCATED (the proxy only ever appends: a shorter log is a record that was CUT, not one that shrank)",
                    g_obs_plog_bytes, g_plog_len);
        return;
    }
    {
        char sha[65];
        sha256_hex(g_plog_bytes ? g_plog_bytes : "", g_obs_plog_bytes, sha);
        if (strcmp(sha, g_obs_plog_sha) != 0)
            add_finding("disagreement-proxy-log-rewritten",
                        "the proxy log's previously observed first %zu byte(s) no longer hash the "
                        "same (was %s, now %s..%s) — the record was REWRITTEN in place; the "
                        "appended tail is %zu byte(s)", g_obs_plog_bytes, g_obs_plog_sha, sha,
                        sha + 56, g_plog_len - g_obs_plog_bytes);
        else if (g_plog_len > g_obs_plog_bytes)
            info("proxy log grew by %zu byte(s) (append-only respected)", g_plog_len - g_obs_plog_bytes);
    }
}

/* ── S4: the REACH comparison (its own check) ───────────────────────────── */

/* The delta against the previous observation, named row by row, and then ONE
 * classification: a widening whose tables still hash to their PIN is an
 * operator RELEASE (named, not a finding — a re-pin release is how reach is
 * supposed to change); a widening whose tables do NOT is the incoherence
 * `reach-widened-unreleased`, the covert capability change §7.1a is about.
 * An unverifiable release (no PINS, or one not naming the tables) takes the
 * LOUD side. */
static void check_reach(void) {
    if (!g_proxy && !g_opsdir) {
        info("reach: NOT ARMED (no --proxy / --ops-policy-dir) — this audit cannot say what the host could run, so it can name no capability change (§7.1a's blindness, named rather than left to be discovered)");
        return;
    }
    g_reach_pins_state = reach_verify_pins();
    if (g_reach_pins_state == 1)
        info("reach: the pinned class tables hash to their PIN (%s) — this declaration is a RELEASE", g_reach_pins_detail);
    else if (g_reach_pins_state == 0)
        info("reach: the class tables do NOT hash to PINS (%s) — an edit NOBODY RELEASED (a widening found under this state is a finding, not a release)", g_reach_pins_detail);
    else
        info("reach: the release CANNOT be verified (%s) — a widening found under this state takes the loud side", g_reach_pins_detail);

    if (!g_have_obs || !g_obs_reach_known) {
        info("reach: %zu host tool(s) and %zu pinned class row(s) recorded as the reach baseline%s — the delta starts on the next observation",
             g_nrtools, g_ngrants,
             g_have_obs ? " (the baseline predates the reach record: it cannot be compared)" : " (first observation of this store)");
        return;
    }

    unsigned n_widen = 0, n_narrow = 0, n_change = 0;
    /* The finding's one-line summary of the widenings is CAPPED, and the cap
     * is MARKED rather than silent: every widening already has its own
     * reach-delta row above, so a cut list loses nothing a reader cannot
     * recover — but an unmarked cut would read as "that was all of them". */
    char wide[LINE_MAX_]; wide[0] = 0;
    int wide_cut = 0;
#define WIDE_ADD(...) do { \
        size_t _l = strlen(wide); \
        int _w = snprintf(wide + _l, sizeof wide - _l, __VA_ARGS__); \
        if (_w < 0 || (size_t)_w >= sizeof wide - _l) { wide_cut = 1; wide[sizeof wide - 1] = 0; } \
    } while (0)

    for (size_t i = 0; i < g_nrtools; i++) {
        int seen = 0;
        for (size_t j = 0; j < g_nptools; j++)
            if (!strcmp(g_rtools[i].name, g_ptools[j].name)) { seen = 1; break; }
        if (seen) continue;
        printf("reach-delta\ttool\t%s\tWIDENED\tDERIVED\tthe registry holds a host tool the previous observation did not — a NEW HOST-EXECUTABLE CAPABILITY\n", g_rtools[i].name);
        WIDE_ADD("host tool '%s'; ", g_rtools[i].name);
        n_widen++;
    }
    for (size_t j = 0; j < g_nptools; j++) {
        int seen = 0;
        for (size_t i = 0; i < g_nrtools; i++)
            if (!strcmp(g_rtools[i].name, g_ptools[j].name)) { seen = 1; break; }
        if (!seen) {
            printf("reach-delta\ttool\t%s\tNARROWED\tDERIVED\tthe previous observation held this host tool and the registry does not — a capability WITHDRAWN\n", g_ptools[j].name);
            n_narrow++;
        }
    }
    for (size_t i = 0; i < g_ngrants; i++) {
        reachgrant_t *C = &g_rgrants[i], *P = NULL;
        for (size_t j = 0; j < g_npgrants; j++)
            if (!strcmp(g_pgrants[j].dim, C->dim) && !strcmp(g_pgrants[j].pattern, C->pattern)) { P = &g_pgrants[j]; break; }
        if (!P) {
            printf("reach-delta\tgrant\t%s:%s\tWIDENED\tDERIVED\tthe pinned table holds a class row the previous observation did not (class %s, protected=%s) — a NEW GRANT\n",
                   C->dim, C->pattern, C->cls, C->prot ? "yes" : "no");
            WIDE_ADD("new %s grant %s (class %s); ", C->dim, C->pattern, C->cls);
            n_widen++;
        } else if (P->prot && !C->prot) {
            printf("reach-delta\tgrant\t%s:%s\tWIDENED\tDERIVED\tthe row's protected flag flipped yes->no (class %s): what a policy DENIED, it now permits\n",
                   C->dim, C->pattern, C->cls);
            WIDE_ADD("protection REMOVED from %s grant %s (class %s); ", C->dim, C->pattern, C->cls);
            n_widen++;
        } else if (!P->prot && C->prot) {
            printf("reach-delta\tgrant\t%s:%s\tNARROWED\tDERIVED\tthe row's protected flag flipped no->yes (class %s): what a policy permitted, it now denies\n",
                   C->dim, C->pattern, C->cls);
            n_narrow++;
        } else if (strcmp(P->cls, C->cls) != 0) {
            printf("reach-delta\tgrant\t%s:%s\tCHANGED\tDERIVED\tthe row is bound to class %s where it was %s — neither direction is stated (the two classes' own protection decides, and this seat will not guess it into a widening)\n",
                   C->dim, C->pattern, C->cls, P->cls);
            n_change++;
        }
    }
    for (size_t j = 0; j < g_npgrants; j++) {
        reachgrant_t *P = &g_pgrants[j];
        int seen = 0;
        for (size_t i = 0; i < g_ngrants; i++)
            if (!strcmp(g_rgrants[i].dim, P->dim) && !strcmp(g_rgrants[i].pattern, P->pattern)) { seen = 1; break; }
        if (seen) continue;
        printf("reach-delta\tgrant\t%s:%s\tNARROWED\tDERIVED\tthe previous observation held this pinned class row and the table does not (class %s) — a grant WITHDRAWN\n",
               P->dim, P->pattern, P->cls);
        n_narrow++;
    }
#undef WIDE_ADD

    if (!n_widen && !n_narrow && !n_change)
        printf("reach-delta\t-\t-\tNONE\tDERIVED\tthe previous observation and this one carry the SAME host tools and the SAME pinned class rows — no capability change BETWEEN THESE TWO OBSERVATIONS\n");
    if (n_widen && g_reach_pins_state == 1)
        info("reach: %u WIDENING(s) between the observations, and the class tables hash to their PIN — a RELEASED declaration (named, NOT a finding: a re-pin release is how reach is supposed to change).  The widenings: %s", n_widen, wide);
    else if (n_widen)
        add_finding("reach-widened-unreleased",
                    "%u WIDENING(s) of what this host can reach between the previous observation "
                    "and this one, and the declaration behind them was NOT RELEASED (%s) — a "
                    "capability change nothing pinned: %s%s(the check is PINS, because a "
                    "RELEASED widening is an operator act with a record, and an unreleased one "
                    "is the covert direction §7.1a names)",
                    n_widen, g_reach_pins_detail, wide,
                    wide_cut ? "[the list above was CUT at this message's bound — every "
                               "widening is named on its own reach-delta row] " : "");
    else if (n_narrow || n_change)
        info("reach: %u narrowings and %u changed row(s) between the observations (no widening) — recorded, not findings: a narrowing is not the direction this check exists for", n_narrow, n_change);
}

/* ── S4b: the SANDBOX record (its own check) ────────────────────────────── */

/* Token-set membership over a separated list. */
static int sb_set_has(const char *set, char sep, const char *tok) {
    if (!set) return 0;
    size_t tl = strlen(tok);
    const char *p = set;
    for (;;) {
        while (*p == sep) p++;
        if (!*p) return 0;
        const char *e = p;
        while (*e && *e != sep) e++;
        if ((size_t)(e - p) == tl && !strncmp(p, tok, tl)) return 1;
        p = e;
    }
}

/* THE CHECK.  The composed sandbox per tool is compared against the audit's
 * OWN previous observation, row by row, and the classification is the ONE
 * asymmetry the mechanism actually has:
 *
 *   WIDENING   a promise token or a static landlock entry ADDED, or a tool
 *              whose composed sandbox did not exist before.  Because the
 *              operator table can only TIGHTEN (and does not touch
 *              --print-sandbox at all), an addition can only come from the
 *              EXECUTOR BASELINE or a tool's SIDECAR — and NEITHER is
 *              pinned.  So a widening is ALWAYS `sandbox-widened-unreleased`,
 *              with the operator table's own pin state reported beside it so
 *              a reader can tell an unreleased operator EDIT from an unpinned
 *              sidecar.  A RELEASED widening does not exist in this shape,
 *              and the check says so rather than implying a pin covers it.
 *   NARROWING  anything removed, or a tool that vanished.  NAMED, not a
 *              finding — and when the operator table still hashes to PINS a
 *              tightening IS a RELEASED operator act, which is the direction
 *              this mechanism is supposed to move.
 *   ABSENCE    no --proxy now = NOT-KNOWN (never "unchanged"); a baseline with
 *              no sandbox_tool row = NOT-KNOWN (never "every spec is new"). */
static void check_sandbox(void) {
    if (!g_proxy) {
        info("sandbox: NOT ARMED (no --proxy) — the COMPOSED sandbox of the running host is "
             "NOT-KNOWN to this audit, so it can name no sandbox change (§7.1a's blindness at "
             "this layer, named rather than left to be discovered)");
        return;
    }
    g_sb_pins_state = sandbox_verify_pins();
    if (g_sb_pins_state == 1)
        printf("sandbox-pin\tops-sandbox.tsv\tMATCH\tMEASURED\t%s\tthe operator's tightening "
               "table is the released one — and it can only ever TIGHTEN, so it is never the "
               "source of a widening\n", g_sb_pins_detail);
    else if (g_sb_pins_state == 0)
        printf("sandbox-pin\tops-sandbox.tsv\tDRIFT\tMEASURED\t%s\tthe operator's sandbox "
               "table is NOT the bytes the release froze: a tightening nobody released, and a "
               "widening found under this state carries that attribution\n", g_sb_pins_detail);
    else
        printf("sandbox-pin\tops-sandbox.tsv\tNOT-KNOWN\tABSENT\t%s\tthe release of the "
               "operator's sandbox table CANNOT be verified (never 'no edit'): a width finding "
               "under this state cannot be attributed to the operator or the sidecar\n",
               g_sb_pins_detail);

    if (!g_have_obs || !g_obs_sandbox_known) {
        info("sandbox: %zu composed spec(s) recorded as the sandbox baseline (sha %s)%s — the "
             "delta starts on the next observation", g_nsbt, g_sb_sha,
             g_have_obs ? " (the baseline predates the sandbox record: it cannot be compared)"
                        : " (first observation of this store)");
        return;
    }
    if (g_obs_sb_sha[0] && !strcmp(g_obs_sb_sha, g_sb_sha))
        info("sandbox: the composed spec block hashes to the SAME sha as the previous "
             "observation (%s) — the per-tool delta below is the evidence", g_sb_sha);

    unsigned n_wide = 0, n_narrow = 0, n_change = 0;
    char wide[LINE_MAX_]; wide[0] = 0;
    int wide_cut = 0;
#define SB_WIDE_ADD(...) do { \
        size_t _l = strlen(wide); \
        int _w = snprintf(wide + _l, sizeof wide - _l, __VA_ARGS__); \
        if (_w < 0 || (size_t)_w >= sizeof wide - _l) { wide_cut = 1; wide[sizeof wide - 1] = 0; } \
    } while (0)

    for (size_t i = 0; i < g_nsbt; i++) {
        sandbox_t *C = &g_sbt[i], *P = NULL;
        for (size_t j = 0; j < g_npsbt; j++)
            if (!strcmp(g_psbt[j].name, C->name)) { P = &g_psbt[j]; break; }
        if (!P) {
            printf("sandbox-delta\t%s\tWIDER\tDERIVED\tthe previous observation recorded no "
                   "composed sandbox for this tool and the proxy declares one now (promises "
                   "\"%s\") — a host capability whose SANDBOX was never recorded, so a "
                   "widening rather than a difference\n", C->name, C->promises);
            SB_WIDE_ADD("tool '%s' newly carries a composed sandbox; ", C->name);
            n_wide++;
            continue;
        }
        char add_p[1024] = "", del_p[1024] = "", add_l[2048] = "", del_l[2048] = "";
        {
            char *dup = xstrdup(C->promises), *sv = NULL;
            for (char *t = strtok_r(dup, " \t", &sv); t; t = strtok_r(NULL, " \t", &sv))
                if (!sb_set_has(P->promises, ' ', t)) {
                    size_t l = strlen(add_p);
                    snprintf(add_p + l, sizeof add_p - l, "%s%s", l ? " " : "", t);
                }
            free(dup);
            dup = xstrdup(P->promises); sv = NULL;
            for (char *t = strtok_r(dup, " \t", &sv); t; t = strtok_r(NULL, " \t", &sv))
                if (!sb_set_has(C->promises, ' ', t)) {
                    size_t l = strlen(del_p);
                    snprintf(del_p + l, sizeof del_p - l, "%s%s", l ? " " : "", t);
                }
            free(dup);
            dup = xstrdup(C->landlock); sv = NULL;
            for (char *t = strtok_r(dup, ";", &sv); t; t = strtok_r(NULL, ";", &sv))
                if (!sb_set_has(P->landlock, ';', t)) {
                    size_t l = strlen(add_l);
                    snprintf(add_l + l, sizeof add_l - l, "%s%s", l ? ";" : "", t);
                }
            free(dup);
            dup = xstrdup(P->landlock); sv = NULL;
            for (char *t = strtok_r(dup, ";", &sv); t; t = strtok_r(NULL, ";", &sv))
                if (!sb_set_has(C->landlock, ';', t)) {
                    size_t l = strlen(del_l);
                    snprintf(del_l + l, sizeof del_l - l, "%s%s", l ? ";" : "", t);
                }
            free(dup);
        }
        int has_add = add_p[0] || add_l[0];
        int has_del = del_p[0] || del_l[0];
        if (!has_add && !has_del) continue;
        if (has_add) {
            printf("sandbox-delta\t%s\t%s\tDERIVED\tthe composed sandbox spec WIDENED", C->name,
                   has_del ? "CHANGED" : "WIDER");
            if (add_p[0]) printf("; promise(s) added \"%s\"", add_p);
            if (add_l[0]) printf("; landlock entr(y/ies) added \"%s\"", add_l);
            if (del_p[0]) printf("; promise(s) removed \"%s\"", del_p);
            if (del_l[0]) printf("; landlock entr(y/ies) removed \"%s\"", del_l);
            printf(" — a sandbox spec is a CAPABILITY DECLARATION, so an ADDITION is a wider "
                   "host capability than the previous observation recorded\n");
            SB_WIDE_ADD("composed spec of '%s' (%s%s%s%s); ", C->name,
                        add_p[0] ? "promises +" : "", add_p,
                        add_l[0] ? " landlock +" : "", add_l);
            n_wide++;
            if (has_del) n_change++;
        } else {
            printf("sandbox-delta\t%s\tNARROWER\tDERIVED\tthe composed sandbox spec NARROWED",
                   C->name);
            if (del_p[0]) printf("; promise(s) removed \"%s\"", del_p);
            if (del_l[0]) printf("; landlock entr(y/ies) removed \"%s\"", del_l);
            printf(" — the mirror direction, named so a reader can tell a tightening from a "
                   "widening, and NOT raised as a finding: a narrowing needs no release.  WHAT "
                   "THIS IS NOT: an operator RELEASE.  The operator's table is DENY-MORE-ONLY "
                   "and narrows only what the spawn APPLIES, so it cannot narrow "
                   "--print-sandbox either — the composition narrowed because the EXECUTOR "
                   "BASELINE or a SIDECAR did, exactly the halves that no pin covers, and the "
                   "operator table's own state above explains neither%s\n",
                   g_sb_pins_state == 1 ? " (it is intact, so the edit was NOT the operator's)"
                                        : " (and it is NOT the bytes PINS froze, so an "
                                          "unreleased operator edit is ALSO on the record)");
            n_narrow++;
        }
    }
    for (size_t j = 0; j < g_npsbt; j++) {
        sandbox_t *P = &g_psbt[j];
        int seen = 0;
        for (size_t i = 0; i < g_nsbt; i++)
            if (!strcmp(g_sbt[i].name, P->name)) { seen = 1; break; }
        if (seen) continue;
        printf("sandbox-delta\t%s\tNARROWER\tDERIVED\tthe previous observation recorded a "
               "composed sandbox for this tool and the proxy declares none now: the host tool "
               "(or its declaration) is GONE — a capability withdrawn\n", P->name);
        n_narrow++;
    }
#undef SB_WIDE_ADD

    if (!n_wide && !n_narrow && !n_change)
        printf("sandbox-delta\t-\tNONE\tDERIVED\tthe previous observation and this one carry "
               "the SAME composed sandbox spec for every tool — no sandbox change BETWEEN THESE "
               "TWO OBSERVATIONS\n");
    if (n_wide)
        add_finding("sandbox-widened-unreleased",
                    "%u WIDENING(s) of the COMPOSED SANDBOX between the previous observation and "
                    "this one: %s%s.  The operator's table is DENY-MORE-ONLY and does not touch "
                    "--print-sandbox, so an addition can only come from the EXECUTOR BASELINE or "
                    "a tool's SIDECAR — and NEITHER is pinned (the operator half's own state: "
                    "%s).  A sandbox spec is a CAPABILITY DECLARATION, so this is a capability "
                    "change nothing released: the covert direction §7.1a names, at the layer S3 "
                    "made structural",
                    n_wide, wide,
                    wide_cut ? "[the list above was CUT at this message's bound — every widening "
                               "is named on its own sandbox-delta row] " : "",
                    g_sb_pins_detail);
    else if (n_narrow || n_change)
        info("sandbox: %u narrowing(s) and %u changed row(s) between the observations (no "
             "widening) — recorded, not findings: a tightening is the direction this mechanism "
             "exists for", n_narrow, n_change);
}

/* ── S5 (ACL SPLIT): THE ACCESS RECORD AND THE ARMED-AUTHOR SET ─────────── */

/* THE VOCABULARY, compared with THIS audit's own previous observation, row by
 * row.  THE CLASSIFICATION IS TOTAL AND SYMMETRIC (the same rule fx-select
 * applies to the same rows, so the two seats cannot disagree about a
 * direction):
 *   deny -> allow, or a DENY row withdrawn   WIDENED
 *   allow -> deny, or an ALLOW row withdrawn NARROWED
 *   a row present on one side only           classified by that row's decision
 * A WIDENING is the finding `access-widened-unreleased` UNLESS
 * policy/access/PINS still freezes the table — then it is a RELEASE, named and
 * not a finding (the exact asymmetry reach-widened-unreleased uses, because a
 * re-pin release is how reach is SUPPOSED to change).  A NARROWING is named
 * and is never a finding: a tightening needs no release.
 *
 * THE ARMED-AUTHOR SET's change between observations is named HERE too, with
 * the direction that matters and no more: an author REMOVED is a WIDENING
 * (fewer seats could refuse — what a seat used to be able to refuse, nothing
 * now does) and an author ADDED is a NARROWING.  NEITHER is a finding, and
 * the row says why: the set follows the INPUTS an invocation was given, no pin
 * covers an invocation, and the access table's own release question is
 * answered by the pin check above — a finding here would be a policy about how
 * the audit was called, which is not this seat's dimension. */
/* THE ARMED-AUTHOR SET's change between observations, named with the
 * direction that matters: an author REMOVED is a WIDENING (fewer seats can
 * refuse) and an author ADDED is a NARROWING.  NEITHER is a finding — the set
 * follows the INPUTS an invocation was given, no pin covers an invocation, and
 * the vocabulary's own release question is answered by check_access's pin row;
 * a finding here would be a policy about how the audit was CALLED.
 *
 * It runs even when the access table itself was not read this time (the "-access"
 * direction is exactly that case: the set can lose a member while the dimension
 * it names is absent, and that absence is the R5 shape a durable record
 * exists to keep). */
static void armed_authors_delta(void) {
    if (!g_obs_armed_known || !g_armed_known) return;
    /* THE ARMED-AUTHOR SET's change, named before the table delta so it is
     * reported even when the previous observation carries no table baseline
     * (the set can be recorded while the vocabulary was not). */
    {
        unsigned n_add = 0, n_del = 0;
        char added[256] = "", removed[256] = "";
        char *sv0 = NULL;
        /* walk the union: an author in one set and not the other */
        char bulk[600];
        snprintf(bulk, sizeof bulk, "%s+%s", g_armed, g_obs_armed);
        char *dup = xstrdup(bulk), *sv = NULL;
        for (char *t = strtok_r(dup, "+", &sv); t; t = strtok_r(NULL, "+", &sv)) {
            if (!strcmp(t, "none")) continue;
            int now = sb_set_has(g_armed, '+', t), was = sb_set_has(g_obs_armed, '+', t);
            if (now && !was && !sb_set_has(added, ' ', t)) {
                size_t l = strlen(added);
                snprintf(added + l, sizeof added - l, "%s%s", l ? " " : "", t);
            } else if (!now && was && !sb_set_has(removed, ' ', t)) {
                size_t l = strlen(removed);
                snprintf(removed + l, sizeof removed - l, "%s%s", l ? " " : "", t);
            }
        }
        free(dup);
        /* counted on COPIES: strtok_r writes over its input, and the lists
         * themselves are printed below */
        char *cnt = xstrdup(added);
        for (char *q = strtok_r(cnt, " ", &sv0); q; q = strtok_r(NULL, " ", &sv0)) n_add++;
        free(cnt);
        cnt = xstrdup(removed);
        sv0 = NULL;
        for (char *q = strtok_r(cnt, " ", &sv0); q; q = strtok_r(NULL, " ", &sv0)) n_del++;
        free(cnt);
        if (removed[0])
            printf("authors-armed-delta\t-%s\tWIDENED\tDERIVED\tan author that COULD REFUSE "
                   "at the previous observation could not at this one (%s): fewer seats can "
                   "refuse, so what a seat used to be able to refuse nothing now does — the "
                   "WIDENING direction.  Named against THIS audit's own previous observation "
                   "(\"%s\" -> \"%s\"); NOT a finding: the set follows the inputs an "
                   "invocation was given, no pin covers an invocation, and the table's own "
                   "release question is the access-pin row above\n", removed, removed,
                   g_obs_armed, g_armed);
        if (added[0])
            printf("authors-armed-delta\t+%s\tNARROWED\tDERIVED\tan author that could not "
                   "refuse at the previous observation can at this one (%s): MORE seats can "
                   "refuse — the narrowing direction, named as one and never raised as a "
                   "widening (\"%s\" -> \"%s\")\n", added, added, g_obs_armed, g_armed);
        if (!added[0] && !removed[0])
            printf("authors-armed-delta\t-\tNONE\tDERIVED\tthe previous observation and this "
                   "one saw the SAME authors armed (\"%s\" vs \"%s\", compared as SETS): no "
                   "author was armed or disarmed between these two observations\n", g_armed,
                   g_obs_armed);
        else
            info("authors armed: \"%s\" now against \"%s\" at the previous observation (%u "
                 "added, %u removed) — the access/ops members are the ones this seat's inputs "
                 "make observable; the denylist, the justification arm and the claim author are "
                 "not queryable here", g_armed, g_obs_armed, n_add, n_del);
    }

}

static void check_access(void) {
    /* FIRST, before any access-dir branch: the armed set can LOSE a member
     * while the dimension it names is absent, and that absence ("armed on the
     * gates, absent on the real lane") is exactly the change this record
     * exists to keep. */
    armed_authors_delta();
    if (!g_accessdir) {
        info("access: NOT ARMED (no --access-dir) — this audit cannot say what the tool "
             "VOCABULARY of the running host is, so it can name no vocabulary change (§7.1a's "
             "blindness at the dimension S2 created, named rather than left to be discovered)");
        return;
    }
    if (!g_atab_known) {
        info("access: --access-dir '%s' was given but the table was NOT READ — the vocabulary of "
             "this observation is NOT-KNOWN, never 'every verb unchanged' and never 'every verb "
             "denied'", g_accessdir);
        return;
    }
    g_access_pins_state = access_verify_pins();
    if (g_access_pins_state == 1)
        printf("access-pin\taccess-verbs.tsv\tMATCH\tMEASURED\t%s\ta widening found under "
               "this state is a RE-PIN RELEASE — a named operator act, not an incoherence\n",
               g_access_pins_detail);
    else if (g_access_pins_state == 0)
        printf("access-pin\taccess-verbs.tsv\tDRIFT\tMEASURED\t%s\tthe table is NOT the bytes "
               "the release froze: a widening found under this state is the covert direction "
               "§7.1a names\n", g_access_pins_detail);
    else
        printf("access-pin\taccess-verbs.tsv\tNOT-KNOWN\tABSENT\t%s\tthe release CANNOT be "
               "verified (never 'no edit'), and an unverifiable release is not a release: a "
               "widening found under this state takes the LOUD side\n", g_access_pins_detail);

    if (!g_have_obs || !g_obs_access_known) {
        info("access: %zu verb(s) recorded as the vocabulary baseline (from %s/%s)%s — the "
             "delta starts on the next observation", g_natab, g_accessdir, "access-verbs.tsv",
             g_have_obs ? " (the baseline predates the access record: it cannot be compared)"
                        : " (first observation of this store)");
        return;
    }

    unsigned n_wide = 0, n_narrow = 0;
    char wide[LINE_MAX_]; wide[0] = 0;
    int wide_cut = 0;
#define ACC_WIDE_ADD(...) do { \
        size_t _l = strlen(wide); \
        int _w = snprintf(wide + _l, sizeof wide - _l, __VA_ARGS__); \
        if (_w < 0 || (size_t)_w >= sizeof wide - _l) { wide_cut = 1; wide[sizeof wide - 1] = 0; } \
    } while (0)

    for (size_t i = 0; i < g_natab; i++) {
        accessverb_t *C = &g_atab[i], *P = NULL;
        for (size_t j = 0; j < g_npatab; j++)
            if (!strcmp(g_patab[j].name, C->name)) { P = &g_patab[j]; break; }
        if (!P) {
            if (C->allow) {
                printf("access-delta\t%s\tWIDENED\tDERIVED\tthe table classifies this verb "
                       "ALLOW and the previous observation carried no row for it: a CALLABLE "
                       "verb where the vocabulary said nothing — a WIDENING\n", C->name);
                ACC_WIDE_ADD("verb '%s' newly classified allow; ", C->name);
                n_wide++;
            } else {
                printf("access-delta\t%s\tNARROWED\tDERIVED\tthe table classifies this verb "
                       "DENY and the previous observation carried no row for it: a REFUSABLE "
                       "verb where the vocabulary said nothing — a NARROWING, not a widening\n",
                       C->name);
                n_narrow++;
            }
            continue;
        }
        if (!P->allow && C->allow) {
            printf("access-delta\t%s\tWIDENED\tDERIVED\tthe row flipped deny->allow: a verb "
                   "the operator's table REFUSED is now callable — the tool VOCABULARY grew by "
                   "one named row (§7.1a's capability increase, at the dimension S2 created)\n",
                   C->name);
            ACC_WIDE_ADD("verb '%s' deny->allow; ", C->name);
            n_wide++;
        } else if (P->allow && !C->allow) {
            printf("access-delta\t%s\tNARROWED\tDERIVED\tthe row flipped allow->deny: a verb "
                   "that was callable is now REFUSED — a NARROWING, named as the mirror "
                   "direction and never raised as a widening (a tightening needs no release)\n",
                   C->name);
            n_narrow++;
        }
    }
    for (size_t j = 0; j < g_npatab; j++) {
        accessverb_t *P = &g_patab[j];
        int seen = 0;
        for (size_t i = 0; i < g_natab; i++)
            if (!strcmp(g_atab[i].name, P->name)) { seen = 1; break; }
        if (seen) continue;
        if (P->allow) {
            printf("access-delta\t%s\tNARROWED\tDERIVED\tthe previous observation carried an "
                   "ALLOW row and the table carries none now: a permitted verb's row was "
                   "WITHDRAWN — a NARROWING\n", P->name);
            n_narrow++;
        } else {
            printf("access-delta\t%s\tWIDENED\tDERIVED\tthe previous observation carried a "
                   "DENY row and the table carries none now: the REFUSAL was withdrawn — a "
                   "WIDENING\n", P->name);
            ACC_WIDE_ADD("verb '%s' deny row withdrawn; ", P->name);
            n_wide++;
        }
    }
#undef ACC_WIDE_ADD

    if (!n_wide && !n_narrow)
        printf("access-delta\t-\tNONE\tDERIVED\tthe previous observation and this one carry "
               "the SAME access table, verb by verb — no vocabulary change BETWEEN THESE TWO "
               "OBSERVATIONS\n");
    if (n_wide && g_access_pins_state == 1)
        info("access: %u WIDENING(s) of the tool vocabulary, and the table hashes to its PIN — a "
             "RELEASED declaration (named, NOT a finding: a re-pin release is how the vocabulary "
             "is supposed to change).  The widenings: %s", n_wide, wide);
    else if (n_wide)
        add_finding("access-widened-unreleased",
                    "%u WIDENING(s) of the TOOL VOCABULARY between the previous observation and "
                    "this one, and the operator's access table was NOT RELEASED (%s) — a "
                    "capability change nothing pinned: %s%s(the check is PINS, exactly as the "
                    "egress term's is: a RELEASED widening is an operator act with a record, and "
                    "an unreleased one is the covert direction §7.1a names)",
                    n_wide, g_access_pins_detail, wide,
                    wide_cut ? "[the list above was CUT at this message's bound — every widening "
                               "is named on its own access-delta row] " : "");
    else if (n_narrow)
        info("access: %u NARROWING(s) of the tool vocabulary between the observations (no "
             "widening) — recorded, not a finding: a tightening is the direction this mechanism "
             "exists to encourage, and it needs no release", n_narrow);
}

/* ── the checks (each its own assertion with its own message) ──────────── */

static void check_version_chain(void) {
    /* (a) CURRENT parseable and published.  The seat reads the remaining
     * facts against the timeline's NEWEST when the file is broken (it must
     * collect every finding, not die on the first), but the FINDING is
     * about the file's own value. */
    if (g_current_garbage[0])
        add_finding("version-chain", ".db/snapshots/CURRENT is not a version number: \"%s\" (fxstore would silently fall back to the newest published — this seat refuses to guess; the remaining reads used the newest published version)",
                    g_current_garbage);
    else if (g_current_file_given && ver_index(g_current_file) < 0) {
        unsigned lo = g_nvers ? g_vers[0] : 0, hi = g_nvers ? g_vers[g_nvers - 1] : 0;
        add_finding("version-chain", "CURRENT=%u is not a published version (timeline %u..%u, %zu version(s)) — the version chain does not line up; the remaining checks read facts as-of %u",
                    g_current_file, lo, hi, g_nvers, g_current);
    }
    if (!g_nvers) {
        add_finding("version-chain", "the store has no published snapshot; nothing to audit against");
        return;
    }
    /* (b) the install facts' genhash must equal the generation fact's, both
     * written by fx-activate in ONE transaction.  NO host-side fixture can
     * construct a violation (every legitimate writer commits both sides
     * together, and no raw fact editor exists outside the guest); the check
     * is cheap insurance against an agent-side writer, and the per-version
     * observation hash covers the same tamper class at version grain. */
    long ci = ver_index(g_current);
    const char *gh = (ci >= 0) ? g_genhash[ci] : "";
    if (g_ninstall == 0 && (!gh || !gh[0])) { /* both empty: consistent */ }
    else if (g_ninstall == 0 || !gh || !gh[0])
        add_finding("version-chain", "as-of CURRENT v%u: %s without %s — fx-activate writes both in one transaction",
                    g_current,
                    g_ninstall ? "install facts" : "no install facts",
                    (gh && gh[0]) ? "a generation fact" : "no generation fact");
    else {
        for (size_t i = 0; i < g_ninstall; i++) {
            if (g_install[i].n < 4) continue;
            if (strcmp(g_install[i].cols[3], gh) != 0) {
                add_finding("version-chain", "install fact for '%s' carries genhash %s but the generation fact says %s (as-of v%u)",
                            g_install[i].cols[0], g_install[i].cols[3], gh, g_current);
                break;
            }
        }
    }
    /* (c) each .recovery row's genhash == the generation's as-of its
     * published version (when that version is still in the timeline). */
    size_t unchecked = 0;
    for (size_t i = 0; i < g_nrec; i++) {
        rec_row_t *r = &g_rec[i];
        if (!strcmp(r->genhash, "-")) { unchecked++; continue; }
        long pi = ver_index((unsigned)r->published);
        if (pi < 0) { unchecked++; continue; }
        const char *want = g_genhash[pi];
        if (!want || !want[0] || strcmp(r->genhash, want) != 0)
            add_finding("version-chain", ".recovery row (line %zu) says the roll-forward republished v%lu with content %s, but the generation fact as-of v%lu is %s",
                        r->lineno, r->published, r->genhash, r->published,
                        (want && want[0]) ? want : "(absent)");
    }
    if (unchecked) info("recovery genhash cross-check: %zu row(s) unchecked (genhash '-' or published version pruned)", unchecked);
}

static void check_recovery_without_failure(void) {
    for (size_t i = 0; i < g_nrec; i++) {
        rec_row_t *r = &g_rec[i];
        char last[64];
        int got = bootlog_last_verdict(r->from_failed, last, sizeof last);
        if (!got) {
            add_finding("recovery-without-failure", ".recovery row (line %zu): fx-init republished v%lu from v%lu, but .bootlog carries NO verdict for v%lu — a roll-forward nobody recorded a failure for",
                        r->lineno, r->published, r->from_failed, r->from_failed);
        } else if (strcmp(last, "failed") != 0 && strcmp(last, "in-progress") != 0) {
            add_finding("recovery-without-failure", ".recovery row (line %zu): fx-init republished v%lu from v%lu, but v%lu's last bootlog verdict is '%s' (fx-init rolls forward only from failed/in-progress)",
                        r->lineno, r->published, r->from_failed, r->from_failed, last);
        }
    }
}

static void check_verify_drift(void) {
    if (!g_rootfs) {
        info("check verify-drift SKIPPED: no --rootfs given (the rootfs lives inside the guest image; pass a host view of it to run fxstore verify)");
        return;
    }
    char args[8192];
    snprintf(args, sizeof args, "verify '%s' --store '%s'", g_rootfs, g_store_abs);
    int rc;
    char *out = fxstore_capture(args, "verify", &rc);
    if (rc == 0) { free(out); return; }
    if (rc == 1) {
        /* keep the first drift lines in the finding: the message must NAME
         * the drift, not just count it */
        char detail[LINE_MAX_]; size_t dl = 0;
        detail[0] = 0;
        char *save = NULL;
        size_t nlines = 0;
        for (char *t = strtok_r(out, "\n", &save); t; t = strtok_r(NULL, "\n", &save)) {
            if (strncmp(t, "fxstore: verify ", 16) == 0 || strncmp(t, "fxstore: ", 9) == 0) continue;
            nlines++;
            int w = snprintf(detail + dl, sizeof detail - dl, "%s%s", dl ? " | " : "", t);
            if (w > 0 && (size_t)w < sizeof detail - dl) dl += (size_t)w; else break;
            if (dl > sizeof detail - 200) break;
        }
        add_finding("verify-drift", "fxstore verify against rootfs '%s' reports %zu drift(s): %s",
                    g_rootfs, nlines, detail);
        free(out);
        return;
    }
    free(out);
    die("fxstore verify failed with exit %d — cannot check the rootfs", rc);
}

/* does <store>/<rel> exist?  name the path in the finding when not */
static int path_exists(const char *first_seg_or_rel, int need_dir, char *gone, size_t gcap, const char **fact, const char *rel) {
    char full[8192];
    snprintf(full, sizeof full, "%s/%s", g_store_abs, first_seg_or_rel);
    struct stat st;
    if (lstat(full, &st) != 0 || (need_dir && !S_ISDIR(st.st_mode))) {
        snprintf(gone, gcap, "%s", first_seg_or_rel);
        *fact = rel;
        return 0;
    }
    return 1;
}

static void check_facts_path_gone(void) {
    if (!g_nvers) return;
    char gone[4096]; const char *fact = NULL;
    /* provides rows name store dirs */
    for (size_t i = 0; i < g_nprovides; i++) {
        if (g_provides[i].n < 2) continue;
        if (!path_exists(g_provides[i].cols[1], 1, gone, sizeof gone, &fact, "provides")) {
            add_finding("facts-path-gone", "provides says package '%s' lives in store dir '%s', but <store>/%s is not there",
                        g_provides[i].cols[0], gone, gone);
        }
    }
    /* install rows name the origin of every installed target */
    for (size_t i = 0; i < g_ninstall; i++) {
        if (g_install[i].n < 2) continue;
        if (!path_exists(g_install[i].cols[1], 0, gone, sizeof gone, &fact, "install")) {
            add_finding("facts-path-gone", "install says target '%s' comes from store path '%s', but <store>/%s is not there",
                        g_install[i].cols[0], gone, gone);
        }
    }
    /* store-relative svc_bin rows name the binary the service execs */
    for (size_t i = 0; i < g_nsvcbin; i++) {
        if (g_svcbin[i].n < 2) continue;
        const char *bin = g_svcbin[i].cols[1];
        if (bin[0] == '/') continue; /* absolute: base-system binary, not a store path */
        if (!path_exists(bin, 0, gone, sizeof gone, &fact, "svc_bin")) {
            add_finding("facts-path-gone", "svc_bin says service '%s' execs '%s', but <store>/%s is not there",
                        g_svcbin[i].cols[0], gone, gone);
        }
    }
    /* the generation fact names its own buildfile and dhake file */
    long ci = ver_index(g_current);
    if (ci >= 0 && g_genhash[ci][0] && g_nvers) {
        char args[8192];
        snprintf(args, sizeof args, "facts generation --as-of %u --store '%s'", g_current, g_store_abs);
        size_t n = 0;
        char **lines = fxstore_lines(args, "generation", &n);
        for (size_t i = 0; i < n; i++) {
            char *save = NULL;
            int nc = 0; char *cols[4] = {0};
            for (char *t = strtok_r(lines[i], "\t", &save); t && nc < 4; t = strtok_r(NULL, "\t", &save))
                cols[nc++] = t;
            /* cols: genhash buildfile dhake epoch — check cols 1 and 2 */
            for (int c = 1; c <= 2; c++) {
                if (cols[c] && !path_exists(cols[c], 0, gone, sizeof gone, &fact, "generation")) {
                    add_finding("facts-path-gone", "generation says its %s is '%s', but <store>/%s is not there",
                                c == 1 ? "buildfile" : "dhake", gone, gone);
                }
            }
        }
        free_lines(lines, n);
    }
}

/* src_of bindings: count the artifacts that exist; absence of an artifact
 * is a LEGITIMATE fallback (the oracle's origin 2 verifies the host tree),
 * so the finding lives in the observation comparison (artifact-gone), not
 * here.  This check reports the state; the comparison detects the change. */
static void check_src_of_artifact(void) {
    size_t bound = 0, present = 0;
    for (size_t i = 0; i < g_nsrc_of; i++) {
        if (g_src_of[i].n < 3) continue;
        bound++;
        char art[8192];
        snprintf(art, sizeof art, "%.64s-%.600s-src", g_src_of[i].cols[1], g_src_of[i].cols[2]);
        struct stat st;
        if (stat(art, &st) == 0) present++;
    }
    if (bound)
        info("src_of: %zu binding(s), %zu source artifact(s) present in the store (absence is the oracle's host-tree fallback; a DISAPPEARANCE is the finding)", bound, present);
}

static void check_records_damaged(void) {
    if (g_bl_damaged)
        add_finding("bootlog-damaged", ".bootlog has %zu terminated line(s) that are not fx-init's \"<v> <status> <epoch>\" shape; first: '%s' — only fx-init writes this file, so a well-formed-but-foreign line is suspected tamper",
                    g_bl_damaged, g_bl_bad1);
    if (g_rec_damaged)
        add_finding("recovery-damaged", ".recovery has %zu data line(s) that are not fx-init's \"<epoch> <published> <from-failed> <genhash|->\" shape; first (line %zu): '%s'",
                    g_rec_damaged, g_rec_bad1_lineno, g_rec_bad1);
}

/* consume the most recent ADDED, not-yet-consumed '<v> in-progress' line at
 * an index BELOW `before`; returns its INDEX, or -1 when none was found.
 * This is the attribution rule both verdict forms ride: a verdict is
 * answered for by its OWN boot's in-progress — EARLIER in the window, not
 * already consumed by an earlier verdict (the writer is single and
 * sequential), and wearing the SAME nonce (one nonce per PID1 lifetime:
 * every line of a boot carries the one latched at its start, so a verdict
 * is never answered by another boot's in-progress).  `nonce` NULL disables
 * the nonce requirement — the TORN path only: a torn verdict's own token
 * may be cut mid-write and cannot be trusted to equal anything.  A
 * TERMINATED and a TORN verdict get exactly this — nothing else — so a
 * crash mid-append is not reported as a forgery.  The index is what binds
 * a TORN verdict to the nonce of the in-progress that answers for it. */
static long bl_consume_ip(size_t before, unsigned long v, const char *nonce, size_t base, char *consumed) {
    size_t j = before;
    while (j > 0) {
        j--;
        if (g_bl[j].off < base) break;
        if (consumed[j]) continue;
        if (g_bl[j].v != v || strcmp(g_bl[j].status, "in-progress")) continue;
        if (nonce && strcmp(g_bl[j].nonce, nonce) != 0) continue;
        consumed[j] = 1; return (long)j;
    }
    return -1;
}

/* ── the second provenance anchor: the STORE'S OWN publish record ────────
 * Is V a version first published IN THIS WINDOW — present in the store's
 * timeline now, absent from the previous observation's version list?  The
 * in-guest `activate` handler publishes a NEW version through the
 * fx-activate child (the store's CURRENT moves with it) and RE-ARMS the
 * boot decision (init.zig:3933-3936); the re-armed grace window then
 * verdicts EXACTLY that version, riding the in-progress the activate arm
 * appended for it (init.zig:3860 — the writer's re-arm marker; the OLD
 * writer shape has no such line, which is what the allow(v) +1 is for).
 * The record used here is fxstore's own publish history — the timeline,
 * the snapshot manifests and facts a publish writes transactionally —
 * NOT .bootlog, the file a forger appends to.  A version number is
 * allocated fresh by every publish (the monotonic ratchet never reuses
 * one), so "in the timeline now, absent at the previous observation" is
 * exactly "first published this window", and the ONE re-arm verdict a
 * version can ever carry is why the per-version verdict budget adds at
 * most one for it — but ONLY when that version carries no re-arm
 * in-progress of its own: the new-writer shape has the ip, so the +1 must
 * not stack on it (a first-published version gets exactly one slot either
 * way, and the extra ip must never buy a second verdict).  Forging the
 * fxstore db itself: hand-crafting that in-guest is a store-format
 * barrier (and the per-version facts hash + genhash cross-checks apply
 * to the fabricated version the moment it exists), while running the
 * REAL fx-activate in-guest produces an honest publish — from this
 * seat's grain the store then truly records an activation.  What remains
 * un-closed either way (a verdict substituted inside the live boot) is
 * named in the printed bound, not hidden. */
static int ver_published_this_window(unsigned long v) {
    if (ver_index((unsigned)v) < 0) return 0;
    for (size_t j = 0; j < g_nobs_vers; j++)
        if (g_obs_vers[j] == v) return 0;
    return 1; /* REARM-ANCHOR: first published since the previous observation */
}

/* how many versions the store FIRST PUBLISHED in this window — the store's
 * own total for the identifier above (the header's rule 3: every activate's
 * in-progress is for one of them, and every publish allocates a fresh
 * number, so this is exactly the re-arm line allowance of the window). */
static size_t nfp_this_window(void) {
    size_t n = 0;
    if (!g_have_obs) return 0;
    for (size_t i = 0; i < g_nvers; i++) {
        int seen = 0;
        for (size_t j = 0; j < g_nobs_vers; j++)
            if (g_obs_vers[j] == g_vers[i]) { seen = 1; break; }
        if (!seen) n++;
    }
    return n;
}

/* per-VERSION verdict accounting for the ADDED lines of one window (see
 * the header's rule 2): a linear table is plenty — it is bounded by the
 * added-line count of one window, and it dies loudly rather than silently
 * truncating, the fixed-array discipline of this file. */
typedef struct { unsigned long v; size_t ip, vd; char own; } vstat_t;
static vstat_t g_vstat[4096];
static size_t g_nvstat = 0;
static vstat_t *vstat_for(unsigned long v) {
    for (size_t i = 0; i < g_nvstat; i++)
        if (g_vstat[i].v == v) return &g_vstat[i];
    if (g_nvstat >= sizeof g_vstat / sizeof g_vstat[0])
        die("%zu versions carry added lines this window — this build's per-version verdict table (g_vstat[%zu]) is FULL; raise the table and re-run rather than silently truncating the accounting", g_nvstat, sizeof g_vstat / sizeof g_vstat[0]);
    g_vstat[g_nvstat].v = v;
    g_vstat[g_nvstat].ip = 0;
    g_vstat[g_nvstat].vd = 0;
    g_vstat[g_nvstat].own = 0;
    return &g_vstat[g_nvstat++];
}

/* ── the host's per-boot nonce ledger (the pair-forgery anchor) ──────────
 *
 * THE HOLE THIS CLOSES (measured by the review that constructed it): a
 * forged line-PAIR ("<v> in-progress <e>" + "<v> ok <e>") appended into the
 * SLACK of a boot the host started but fx-init never recorded (killed
 * before its in-progress, a refused service table, no bootable generation)
 * fully impersonates that boot — the count arithmetic accounts it (1 ip +
 * 1 verdict <= delta 1) and the in-order attribution finds its own forged
 * in-progress behind it.  The count could not tell a forger's bytes from
 * an unrecorded boot's own.
 *
 * THE ANCHOR: the host issues an unpredictable per-boot nonce on the kernel
 * command line (fx.bootnonce=, minted at launch), records "<boot> <nonce>"
 * in its own ledger, and fx-init stamps that nonce on every .bootlog line
 * and .recovery row it appends during the boot (init.zig bootlog_append /
 * recovery_line, latched once per PID1 lifetime before any append).  The
 * guest can read its OWN cmdline — so the closure is NOT secrecy of the
 * current nonce; it is that (1) a nonce for a FUTURE boot does not exist
 * yet, (2) a PAST boot's nonce is visible in-guest only on the lines that
 * boot itself wrote — and those already spent its per-boot line budget, so
 * reuse fires the per-nonce accounting below, (3) a SILENT boot (nothing
 * written) runs no agent service at all (no services load — the writer's
 * own pre-decided failure path), so nobody is alive inside it to spend its
 * nonce, and (4) an invented nonce is not in the host's ledger.  The
 * per-boot accounting is then applied PER NONCE for the in-progress lines
 * (the boot's OWN first line plus one activate RE-ARM per version the store
 * FIRST PUBLISHED in this window — each newer than the version its boot
 * booted, init.zig:3860 — and <=1 shutdown, <=1 .recovery row) and PER
 * VERSION for verdicts: a verdict rides an in-progress wearing ITS OWN
 * nonce (one boot, one nonce — every line of a boot carries the nonce
 * latched at its start, the re-arm ip included) OR names a version the
 * STORE first published in this window (the OLD-writer activate re-arm,
 * which verdicts the activated generation without a new in-progress,
 * init.zig:3933-3936); and a version carries at most one verdict per
 * in-progress behind it, plus that one re-arm verdict ONLY when it has no
 * re-arm ip of its own.  What this genuinely cannot see — a verdict
 * SUBSTITUTED for
 * the live boot's own (the agent appends the verdict itself wearing the
 * live nonce and suppresses fx-init's): one verdict, one (nonce, version)
 * — named in the printed bound, not claimed closed.
 *
 * THE REGIMES, honestly distinguished: when the ledger covers every boot of
 * the window (window nonces == delta — the harness regime, the host issues
 * one nonce per boot it starts) an ADDED line with no window nonce is a
 * FINDING: the host issued a nonce for every boot, fx-init under that
 * regime writes its nonce on every line, so no boot the host started is
 * behind such a line.  When the window holds boots the host started
 * WITHOUT a nonce (a mixed/manual regime — an operator hand-boot between
 * audits, honestly declared by the short ledger), lines without a window
 * nonce are NAMED and counted by the boot-count arithmetic only: reported,
 * never silently accepted as accounted, and never silently skipped. */

typedef struct { unsigned long boot; char nonce[80]; } nled_t;
static nled_t g_nled[8192];
static size_t g_nnled = 0;

/* Load and validate the host's ledger.  Loud on every anomaly: this file is
 * the HOST'S OWN MEMORY of what it issued, and a contradiction inside it is
 * a tool error (exit 2), never a guess. */
static void load_nonces(void) {
    if (!g_nonces_given) return;
    FILE *f = fopen(g_nonces_path, "r");
    if (!f) die("cannot open --nonces '%s': %s — the host's nonce ledger is required to judge this window", g_nonces_path, strerror(errno));
    char line[LINE_MAX_];
    size_t lineno = 0;
    while (fgets(line, sizeof line, f)) {
        lineno++;
        if (line[0] == '\n' || line[0] == '#') continue;
        unsigned long boot;
        char tok[80];
        if (sscanf(line, "%lu %79s", &boot, tok) != 2)
            die("%s:%zu: not the ledger's \"<boot> <nonce>\" shape: %s", g_nonces_path, lineno, line);
        if (!strcmp(tok, "none"))
            die("%s:%zu: the ledger claims the literal nonce 'none' for boot %lu — the WRITER reserves 'none' as its no-nonce-issued placeholder and refuses fx.bootnonce=none as a host value (init.zig parse_kernel_nonce), so the host can never have issued it; a ledger entry for it would make every placeholder line in a window claimable as that boot's. Fix the ledger", g_nonces_path, lineno, boot);
        if (boot == 0)
            die("%s:%zu: boot ordinal 0 — boots are counted from 1 (--boots semantics)", g_nonces_path, lineno);
        if (boot > g_boots)
            die("%s:%zu: a nonce for boot %lu but the host has started only %lu boot(s) — the ledger contradicts --boots", g_nonces_path, lineno, boot, g_boots);
        if (g_nnled >= sizeof g_nled / sizeof g_nled[0])
            die("%s: more than %zu ledger entries: this build's nonce table is FULL — raise the table and re-run", g_nonces_path, sizeof g_nled / sizeof g_nled[0]);
        for (size_t i = 0; i < g_nnled; i++) {
            if (g_nled[i].boot == boot)
                die("%s:%zu: two nonces for boot %lu (first %s) — the host issued ONE nonce per boot", g_nonces_path, lineno, boot, g_nled[i].nonce);
            if (!strcmp(g_nled[i].nonce, tok))
                die("%s:%zu: nonce %s issued for both boot %lu and boot %lu — one nonce identifies one boot", g_nonces_path, lineno, tok, g_nled[i].boot, boot);
        }
        g_nled[g_nnled].boot = boot;
        snprintf(g_nled[g_nnled].nonce, sizeof g_nled[g_nnled].nonce, "%s", tok);
        g_nnled++;
    }
    if (ferror(f)) die("cannot read '%s': %s", g_nonces_path, strerror(errno));
    fclose(f);
}

/* the ledger slot of a nonce token, or -1 (not issued by this host) */
static long nonce_slot(const char *tok) {
    if (!tok || !tok[0]) return -1;
    for (size_t i = 0; i < g_nnled; i++)
        if (!strcmp(g_nled[i].nonce, tok)) return (long)i;
    return -1;
}

/* ── <store>/.operator: read for ANCHOR (c) and for NOTHING else ─────────
 * ONE reason, stated so nobody widens this reader by accident: a soft reboot
 * is a new PID1 lifetime under the SAME kernel boot's nonce, so the lines it
 * appends wear a nonce the window does not hold.  The journal's `reboot` row
 * (fx-init's REBOOT_ACTION, operator_journal.zig) is the record of that act.
 *
 * WHAT COUNTS AS AN ANCHOR: action exactly `reboot` and outcome exactly `ok`
 * — the ADMISSION.  `not-decided`, `boot-failed`, `shell-open`,
 * `same-version-loop` and `exec-error` refuse or fail and open NO lifetime
 * (the row records the ADMISSION, never the execution: an admitted reboot
 * that was never executed is visible as the ABSENCE of a later .bootlog line
 * under that nonce, which is the honest reconstruction).  Refused rows are
 * COUNTED and NAMED — never silently dropped.
 *
 * A row this seat cannot read (a torn append, a foreign grammar) is NOT an
 * anchor and cannot be: the fail-open direction every reader of these records
 * takes, because a misread must never LICENSE a line.  It is named with its
 * line number, so a pair that goes unanchored has a visible cause.  (A
 * journal this seat cannot read is also why the anchor is only ever an
 * ENABLER: losing a row costs an attribution line, never a false pass on
 * .bootlog's own arithmetic.)
 *
 * The nonce is BOUND to the host's ledger (the row must wear a nonce the host
 * issued for SOME boot — that is what identifies the kernel boot the lifetime
 * re-entered); an admitted row whose nonce the ledger does not hold (the
 * mixed/manual regime: a hand-boot with no fx.bootnonce=) can anchor nothing
 * and is named, never guessed at. */
static void read_operator_journal(void) {
    char path[4096];
    snprintf(path, sizeof path, "%s/.operator", g_store_abs);
    int absent = 0; size_t len = 0;
    char *b = read_file(path, &len, &absent);
    g_op_present = !absent;
    if (absent) return; /* a store predating the journal: no row, no anchor */
    char *p = b;
    unsigned long lineno = 0;
    while (p < b + len) {
        char *nl = memchr(p, '\n', (size_t)(b + len - p));
        size_t llen = nl ? (size_t)(nl - p) : (size_t)(b + len - p);
        lineno++;
        if (!nl) { g_rb_unread++; if (!g_rb_unread_line) g_rb_unread_line = lineno; break; }
        char save = p[llen]; p[llen] = 0;
        if (p[0] != '#' && p[0]) {
            unsigned ep;
            char action[32], arg[4096], outcome[64], froms[16], tos[16], nonce[80], junk[8];
            int nf = sscanf(p, "%u %31s %4095s %63s %15s %15s %79s %7s",
                            &ep, action, arg, outcome, froms, tos, nonce, junk);
            unsigned long vf = 0;
            int vf_ok = 0;
            if (nf == 7) {
                /* the writer's generation field: a decimal version or "-"
                 * (operator_line's "{d}"/"-"); anything else is not a row */
                if (froms[0] == '-') vf_ok = 0;
                else {
                    vf_ok = 1;
                    for (const char *q = froms; *q; q++) if (*q < '0' || *q > '9') { vf_ok = 0; break; }
                    if (vf_ok) vf = strtoul(froms, NULL, 10);
                }
            }
            if (nf != 7 || !vf_ok) {
                g_rb_unread++;
                if (!g_rb_unread_line) g_rb_unread_line = lineno;
            } else if (!strcmp(action, "reboot")) {
                if (strcmp(outcome, "ok") != 0) {
                    g_rb_refused++;
                    if (!g_rb_refused_line) {
                        g_rb_refused_line = lineno;
                        snprintf(g_rb_refused_outcome, sizeof g_rb_refused_outcome, "%s", outcome);
                    }
                } else {
                    long sl = nonce_slot(nonce);
                    if (sl < 0) { g_rb_unanchored++; }
                    else {
                        g_rb = realloc(g_rb, (g_nrb + 1) * sizeof *g_rb);
                        if (!g_rb) die("out of memory");
                        g_rb[g_nrb].lineno = lineno;
                        g_rb[g_nrb].epoch = ep;
                        g_rb[g_nrb].slot = sl;
                        g_rb[g_nrb].v_from = vf;
                        g_rb[g_nrb].consumed = 0;
                        g_nrb++;
                    }
                }
            }
        }
        p[llen] = save;
        p = nl + 1;
    }
    free(b);
}

/* Hand out ONE admitted reboot row for a (nonce, from-version) pair: the row
 * must carry the SAME nonce (the kernel boot the lifetime re-entered) and the
 * SAME from-version (the generation the machine was running when it asked) —
 * a row for a different generation licenses nothing, which is what keeps a
 * reboot row from becoming a blanket permission for the nonce.  Rows are
 * handed out once each, in file order: N admitted reboots buy N lifetimes,
 * never more. */
static long reboot_anchor_take(long slot, unsigned long v) {
    if (!g_rb) return -1;   /* REBOOT-ANCHOR (c) */
    for (size_t i = 0; i < g_nrb; i++)
        if (!g_rb[i].consumed && g_rb[i].slot == slot && g_rb[i].v_from == v) {
            g_rb[i].consumed = 1;
            return (long)i;
        }
    return -1;
}

/* the host-boot accounting — the APPENDED-line blind spot, closed.
 * observation_compare catches REWRITES; this check binds the GROWTH of the
 * append-only records to the boots the HOST reports starting (--boots
 * delta).  The host is the hypervisor: its count is the one input in this
 * comparison the guest cannot write.  The rule is stated in the header,
 * derived from the writer's call sites — at most one in-progress, one
 * verdict, one shutdown and one recovery row per boot the host started,
 * and every verdict must ride an in-progress for the SAME version in the
 * SAME window. */
static void check_boot_accounting(void) {
    if (!g_have_obs) {
        info("boot accounting: enrolling — the host boot count %lu is recorded as the baseline; .bootlog growth is accounted from the NEXT audit", g_boots);
        return;
    }
    if (g_boots < g_obs_boots)
        die("the host boot count went DOWN (%lu at the previous observation -> %lu now) — the --boots input contradicts the host's own recorded memory; refusing to guess an accounting from it", g_obs_boots, g_boots);
    unsigned long delta = g_boots - g_obs_boots;

    /* ── the nonce window ──
     * The ledger's entries for boots IN THIS WINDOW ((obs, boots]) are the
     * nonces a legitimately-written added line may wear.  Without the
     * ledger the window cannot be judged at all — the pair-forgery blind
     * spot reopens silently — so it is REQUIRED whenever the window holds
     * boots (the same rule as --boots: an anchor that silently defaults is
     * decorative). */
    if (delta > 0 && !g_nonces_given)
        die("--nonces is REQUIRED when the window holds boots (%lu since the previous observation): the host's ledger of the nonce it issued per boot is what binds an ADDED line to the boot that wrote it — without it a forged line-PAIR in a silent boot's slack is invisible (the measured hole), and silently skipping the nonce accounting is how a bound becomes decorative. Pass --nonces FILE with \"<boot> <nonce>\" per line (a window boot the host started with NO nonce is declared by its absence from the ledger — a mixed/manual regime, reported not guessed)");
    size_t *wslot = NULL;      /* ledger slot per window boot, by scan order */
    unsigned long nwin = 0;    /* nonces issued for boots in this window */
    if (g_nonces_given) {
        wslot = xmalloc((g_nnled ? g_nnled : 1) * sizeof *wslot);
        for (size_t i = 0; i < g_nnled; i++)
            if (g_nled[i].boot > g_obs_boots && g_nled[i].boot <= g_boots)
                wslot[nwin++] = i;
        if (nwin > delta)
            die("the ledger holds %lu nonce(s) for this window's %lu boot(s) (host boots %lu -> %lu) — the host issued more nonces than boots it started; its own record contradicts itself, refusing to account from it", nwin, delta, g_obs_boots, g_boots);
    }
    /* STRICT = the harness regime: the host issued a nonce for EVERY boot
     * of the window, so every ADDED line must wear one.  nwin < delta is
     * the mixed/manual regime (named below), never silently accepted. */
    int strict = g_nonces_given && (nwin == delta);
    /* per-nonce usage: indexed by LEDGER slot (so a PAST nonce reused on an
     * added line is attributable: nonce_slot finds its slot, its boot is
     * outside the window) */
    size_t *nip = xmalloc((g_nnled ? g_nnled : 1) * sizeof *nip);
    size_t *nvd = xmalloc((g_nnled ? g_nnled : 1) * sizeof *nvd);
    size_t *nsd = xmalloc((g_nnled ? g_nnled : 1) * sizeof *nsd);
    size_t *nrw = xmalloc((g_nnled ? g_nnled : 1) * sizeof *nrw);
    /* per-slot REBOOT LIFETIMES opened by anchor (c): the budget the per-nonce
     * shutdown/row rules and the totals ARE widened by, and by nothing else */
    size_t *nrl = xmalloc((g_nnled ? g_nnled : 1) * sizeof *nrl);
    for (size_t i = 0; i < g_nnled; i++) nip[i] = nvd[i] = nsd[i] = nrw[i] = nrl[i] = 0;
    size_t n_rl_total = 0;     /* reboot lifetimes anchored in this window */
    size_t n_unbound_bl = 0;   /* added lines with no window nonce */
    char unbound_bl_first[256]; unbound_bl_first[0] = 0;
    size_t n_unbound_rec = 0;  /* added rows with no window nonce */
    char unbound_rec_first[256]; unbound_rec_first[0] = 0;
    /* the OPEN reboot lifetimes: a verdict/shutdown binds to the lifetime its
     * anchor opened (same nonce slot, same version), and it is bound ONCE —
     * one admitted row, one in-progress, one verdict.  That is the whole
     * budget anchor (c) grants, and it is what keeps a reboot row from
     * licensing a SECOND verdict for a generation the window already
     * verdicted (the flip the per-version budget exists to catch). */
    typedef struct { long slot; unsigned long v; int vd_seen; int sd_seen; } rl_t;
    rl_t *rl = malloc((g_nbl ? g_nbl : 1) * sizeof *rl);
    size_t n_rl = 0;
    if (!rl) die("out of memory");

    /* ── the .bootlog lines ADDED since the previous observation ── */
    size_t base = 0;                 /* byte offset where the added lines start */
    int skip_bl = 0;
    if (g_obs_bl_absent && g_bl_absent) {
        /* never booted, still nothing grown */
    } else if (g_obs_bl_absent && !g_bl_absent) {
        info("boot accounting: .bootlog was absent at the previous observation — the WHOLE file (%zu line(s)) is this window's growth", g_nbl);
    } else if (!g_obs_bl_absent && g_bl_absent) {
        skip_bl = 1; /* record-vanished already fired; nothing to count */
    } else if (g_bl_len < g_obs_bl_bytes) {
        skip_bl = 1; /* truncated — disagreement-bootlog-rewritten fired */
    } else {
        char sha[65];
        sha256_hex(g_bl_bytes ? g_bl_bytes : "", g_obs_bl_bytes, sha);
        if (strcmp(sha, g_obs_bl_sha) != 0) {
            skip_bl = 1; /* rewritten in place — already a finding */
        } else {
            base = g_obs_bl_bytes;
        }
    }
    if (skip_bl)
        info("boot accounting: .bootlog skipped — the previously observed bytes are not an intact prefix (rewritten/truncated/vanished: already reported); counting lines inside a rewritten file would be arithmetic on a lie");

    size_t n_ip = 0, n_sd = 0, n_verdict = 0;
    if (!skip_bl) {
        char *consumed = calloc(g_nbl ? g_nbl : 1, 1);
        if (!consumed) die("out of memory");
        /* ── the RE-ARM classification state (header rule 3) ──
         * have_first_ip[slot] / first_ip_v[slot] record the FIRST added
         * in-progress of each nonce — that boot's OWN line (init.zig:5243,
         * written before every verdict site, so it is provably the boot's
         * first).  is_rearm_ip[i] marks every LATER in-progress the store's
         * own publish record accounts for (a re-arm: first-published in
         * this window AND newer than that nonce's first version — the
         * publish ratchet is max+1), and seen_ip[] is the set of VERSIONS
         * the window's later in-progress lines have named: the re-arm ip
         * budget is ONE PER FIRST-PUBLISHED VERSION PER WINDOW, so the
         * duplicate check is keyed on the VERSION ALONE — a version is
         * published by exactly ONE activate, hence exactly one boot can
         * have written its re-arm ip; a second line naming it anywhere in
         * the window is a forged pair riding a second boot's nonce.
         * vstat_t.own marks a version that already appeared as a boot's
         * OWN first in-progress (init.zig:5243): the re-arm line names a
         * version the activate JUST published (max+1), which has therefore
         * NEVER been booted, so a later in-progress naming an already-
         * booted version is the roll-forward REPUBLISH forge — a version
         * first published WITHOUT an activation, then booted, then given a
         * forged re-arm pair riding an earlier boot's nonce to buy a SECOND
         * verdict for it.  rej_ip_* keep the FIRST offending later line per
         * nonce, so the finding can be reported with the nonce's total and
         * the reason. */
        unsigned long *first_ip_v = malloc((g_nnled ? g_nnled : 1) * sizeof *first_ip_v);
        char *have_first_ip = malloc(g_nnled ? g_nnled : 1);
        char *is_rearm_ip = malloc((g_nbl ? g_nbl : 1) * sizeof *is_rearm_ip);
        char *is_reboot_ip = malloc((g_nbl ? g_nbl : 1) * sizeof *is_reboot_ip);
        char *has_rej = malloc(g_nnled ? g_nnled : 1);
        unsigned long *rej_ip_v = malloc((g_nnled ? g_nnled : 1) * sizeof *rej_ip_v);
        char (*rej_ip_why)[288] = malloc((g_nnled ? g_nnled : 1) * sizeof *rej_ip_why);
        unsigned long *seen_ip = malloc((g_nbl ? g_nbl : 1) * sizeof *seen_ip);
        if (!first_ip_v || !have_first_ip || !is_rearm_ip || !is_reboot_ip || !has_rej || !rej_ip_v || !rej_ip_why || !seen_ip)
            die("out of memory");
        for (size_t i = 0; i < g_nnled; i++) {
            have_first_ip[i] = has_rej[i] = 0;
            first_ip_v[i] = rej_ip_v[i] = 0;
            rej_ip_why[i][0] = 0;
        }
        if (g_nbl) { memset(is_rearm_ip, 0, g_nbl); memset(is_reboot_ip, 0, g_nbl); }
        size_t n_seen_ip = 0;
        for (size_t i = 0; i < g_nbl; i++) {
            if (g_bl[i].off < base) continue; /* not added this window */
            const char *st = g_bl[i].status;
            /* nonce classification first (every ip/sd/verdict line the
             * writer appends carries one; foreign statuses belong to
             * records-damaged and are skipped as before) */
            if (!strcmp(st, "in-progress") || !strcmp(st, "shutdown") ||
                !strcmp(st, "ok") || !strcmp(st, "failed")) {
                long ws = nonce_slot(g_bl[i].nonce);
                int in_win = (ws >= 0 && g_nled[ws].boot > g_obs_boots && g_nled[ws].boot <= g_boots);
                /* ── ANCHOR (c): the SOFT REBOOT ─────────────────────────
                 * A soft reboot is a NEW PID1 LIFETIME under the SAME
                 * kernel boot's nonce (fx-init re-latches the same
                 * fx.bootnonce= on re-entry), so the lines it appends can
                 * wear a nonce THIS WINDOW DOES NOT HOLD — no host boot
                 * started, and the nonce belongs to a boot at or before the
                 * previous observation.  `in_win` therefore cannot be the
                 * only way in.
                 *
                 * An added in-progress OPENS a lifetime when an ADMITTED
                 * .operator reboot row carries the SAME nonce and the SAME
                 * from-version (the generation the machine was running when
                 * it asked).  ONE row buys ONE lifetime — one in-progress
                 * and the verdict that closes it — which is exactly what the
                 * writer produces, so a reboot row can never become a
                 * blanket permission for its nonce.
                 *
                 * The boot's OWN line is never an anchor (a free pass no
                 * row should be needed for); only a LATER line of a window
                 * nonce, or ANY line under a past boot's nonce, needs one.
                 * And the RE-ARM rule has FIRST REFUSAL on a later line: see
                 * the comment on the predicate below, which is the measured
                 * ordering (the greedy order false-positived on the writer's
                 * own recommended loop, tests/test_fx_audit.sh REBOOTACT). */
                int bound = in_win;
                long anchor = -1;
                /* ANCHOR (c) IS TRIED WHERE THE RE-ARM RULE WOULD REFUSE, and
                 * never before it — THE ORDER IS LOAD-BEARING: an activate
                 * re-arm in-progress and a reboot lifetime's in-progress can
                 * name the SAME first-published version under the same nonce
                 * (activate -> poll the verdict -> reboot into it, the
                 * writer's own recommended loop, writes both in ONE window).
                 * A greedy anchor would spend the row on the RE-ARM line and
                 * then refuse the real lifetime — a false positive on the
                 * healthiest sequence this verb has.  So the re-arm
                 * predicates are evaluated FIRST (the same four the chain
                 * below applies) and the anchor is only offered to a line the
                 * re-arm rule is about to reject. */
                int rearm_wins = 0;
                if (in_win && have_first_ip[ws] && !strcmp(st, "in-progress")) {
                    int dup = 0;
                    for (size_t q = 0; q < n_seen_ip; q++)
                        if (seen_ip[q] == g_bl[i].v) { dup = 1; break; }
                    rearm_wins = !dup && !vstat_for(g_bl[i].v)->own
                              && ver_published_this_window(g_bl[i].v)
                              && (g_bl[i].v > first_ip_v[ws]);
                }
                if (ws >= 0 && !strcmp(st, "in-progress") && !rearm_wins &&
                    !(in_win && !have_first_ip[ws])) {
                    anchor = reboot_anchor_take(ws, g_bl[i].v);
                    if (anchor >= 0) {
                        bound = 1;
                        is_reboot_ip[i] = 1;
                        nrl[ws]++;
                        n_rl_total++;
                        rl[n_rl].slot = ws; rl[n_rl].v = g_bl[i].v;
                        rl[n_rl].vd_seen = 0; rl[n_rl].sd_seen = 0; n_rl++;
                        info("boot accounting: an ADDED '%lu in-progress' under the nonce the host issued for boot %lu (%s) rides ANCHOR (c) — the ADMITTED .operator reboot row at line %lu (epoch %lu, from-version %lu, same nonce): a soft reboot is a NEW PID1 LIFETIME under the SAME kernel boot's nonce, which the host boot count can never account for (a soft reboot starts no boot); one admitted row licenses one lifetime (this in-progress and the verdict that closes it); accounted, not a finding",
                             g_bl[i].v, g_nled[ws].boot, g_nled[ws].nonce,
                             g_rb[anchor].lineno, g_rb[anchor].epoch, g_rb[anchor].v_from);
                    }
                } else if (!in_win && ws >= 0 && (!strcmp(st, "shutdown") || !strcmp(st, "ok") || !strcmp(st, "failed"))) {
                    /* the CLOSING half of an already-anchored lifetime: a
                     * verdict binds to the lifetime its own in-progress
                     * opened (same nonce, same version) and binds ONCE — so
                     * a second verdict needs a second admitted row, never
                     * the same one.  A shutdown names whatever version is
                     * current when PID1 exits (an activate can have moved
                     * CURRENT inside the lifetime), so it binds on the
                     * lifetime's NONCE alone; the per-nonce shutdown budget
                     * (at most one) is what still bounds it. */
                    int is_sd = !strcmp(st, "shutdown");
                    for (size_t q = 0; q < n_rl; q++) {
                        if (rl[q].slot != ws) continue;
                        if (is_sd) {
                            if (rl[q].sd_seen) continue;
                            rl[q].sd_seen = 1; bound = 1; break;
                        }
                        if (rl[q].v != g_bl[i].v || rl[q].vd_seen) continue;
                        rl[q].vd_seen = 1; bound = 1; break;
                    }
                }
                if (bound) {
                    if (!strcmp(st, "in-progress")) {
                        nip[ws]++;
                        if (anchor >= 0) {
                            /* registered above: the line that OPENED the
                             * lifetime is accounted, not classified again */
                        } else if (!have_first_ip[ws]) {
                            have_first_ip[ws] = 1;
                            first_ip_v[ws] = g_bl[i].v;
                            /* that boot's OWN version.  A version is FRESH
                             * at activation time — the publish ratchet
                             * allocates max+1, so the activate arm's re-arm
                             * line (init.zig:3860) can only ever name a
                             * version that has NOT yet been booted.  Mark it
                             * booted so the later-ip check below refuses a
                             * "re-arm" for an already-booted version — the
                             * REPUBLISH forge, where a first-published-but-
                             * never-activated version is booted and a forged
                             * pair rides an earlier boot's nonce to buy a
                             * SECOND verdict for it. */
                            vstat_for(g_bl[i].v)->own = 1;
                        } else {
                            /* a LATER in-progress of this boot: only an
                             * activate re-arm can produce one, and each
                             * VERSION it names can be activated exactly
                             * once in the window */
                            int dup = 0;
                            for (size_t q = 0; q < n_seen_ip; q++)
                                if (seen_ip[q] == g_bl[i].v) { /* VERSION-KEY */ dup = 1; break; }
                            if (dup) {
                                if (!has_rej[ws]) {
                                    has_rej[ws] = 1; rej_ip_v[ws] = g_bl[i].v;
                                    snprintf(rej_ip_why[ws], sizeof rej_ip_why[ws],
                                             "a SECOND in-progress for v%lu in this window (a publish allocates a version number exactly ONCE, so exactly ONE boot can have activated it and written its re-arm in-progress — a second one is a forged pair riding a second boot's nonce)", g_bl[i].v);
                                }
                            } else if (vstat_for(g_bl[i].v)->own) { /* NOT-BOOTED-KEY */
                                if (!has_rej[ws]) {
                                    has_rej[ws] = 1; rej_ip_v[ws] = g_bl[i].v;
                                    snprintf(rej_ip_why[ws], sizeof rej_ip_why[ws],
                                             "v%lu was ALREADY BOOTED in this window (its own first in-progress appeared earlier) — a re-arm (init.zig:3860) names the version the activate JUST published (max+1, never booted): a forged pair riding an earlier boot's nonce to buy a SECOND verdict", g_bl[i].v);
                                }
                            } else if (!ver_published_this_window(g_bl[i].v)) {
                                if (!has_rej[ws]) {
                                    has_rej[ws] = 1; rej_ip_v[ws] = g_bl[i].v;
                                    snprintf(rej_ip_why[ws], sizeof rej_ip_why[ws],
                                             "v%lu is NOT a version the store first published in this window (init.zig:3860 only ever names the version the activate just published)", g_bl[i].v);
                                }
                            } else if (!(g_bl[i].v > first_ip_v[ws])) {
                                if (!has_rej[ws]) {
                                    has_rej[ws] = 1; rej_ip_v[ws] = g_bl[i].v;
                                    snprintf(rej_ip_why[ws], sizeof rej_ip_why[ws],
                                             "v%lu is NOT greater than v%lu, the version that nonce's first in-progress named (the publish ratchet is max+1, so a real re-arm version always exceeds the booted one)",
                                             g_bl[i].v, first_ip_v[ws]);
                                }
                            } else {
                                is_rearm_ip[i] = 1;
                                info("boot accounting: the nonce the host issued for boot %lu (%s) carries a RE-ARM in-progress for v%lu — a version the store FIRST PUBLISHED in this window and NEWER than v%lu, the version that boot BOOTED: the activate arm's own window marker (init.zig:3860, appended before the activated facts are read); accounted, not a finding",
                                     g_nled[ws].boot, g_nled[ws].nonce, g_bl[i].v, first_ip_v[ws]);
                            }
                            seen_ip[n_seen_ip++] = g_bl[i].v;
                        }
                    }
                    else if (!strcmp(st, "shutdown")) nsd[ws]++;
                    else nvd[ws]++;
                } else {
                    n_unbound_bl++;
                    if (n_unbound_bl == 1) {
                        snprintf(unbound_bl_first, sizeof unbound_bl_first, "%lu %s %lu %s",
                                 g_bl[i].v, g_bl[i].status, g_bl[i].epoch,
                                 g_bl[i].nonce[0] ? g_bl[i].nonce : "(no field)");
                    }
                }
            }
            if (!strcmp(st, "in-progress")) { n_ip++; vstat_for(g_bl[i].v)->ip++; continue; }
            if (!strcmp(st, "shutdown"))    { n_sd++; continue; }
            if (strcmp(st, "ok") && strcmp(st, "failed")) continue; /* foreign status: records-damaged owns the shape */
            n_verdict++;
            vstat_for(g_bl[i].v)->vd++;
            /* the verdict must ride one of the TWO writer paths (the
             * header's rule 1): (a) an ADDED in-progress for the same
             * version wearing the SAME nonce, EARLIER in this window, not
             * yet consumed by an earlier verdict for it (in-order matching
             * — the writer is single and sequential; one nonce per PID1
             * lifetime), or (b) the version was FIRST PUBLISHED in this
             * window — the in-guest activate re-arm verdicts the newly
             * activated generation without a new in-progress.  Anything
             * else is a verdict no writer path produces. */
            const long aj = bl_consume_ip(i, g_bl[i].v, g_bl[i].nonce, base, consumed);
            if (aj >= 0 && is_rearm_ip[aj])
                info("boot accounting: the ADDED '%lu %s %lu' verdict for v%lu CONSUMES the RE-ARM in-progress this boot wrote for it (init.zig:3860) — the activated generation's own window, closed by the re-armed grace window (init.zig:3933-3936) under the same nonce; accounted, not a finding",
                     g_bl[i].v, st, g_bl[i].epoch, g_bl[i].v);
            if (aj >= 0 && is_reboot_ip[aj])
                info("boot accounting: the ADDED '%lu %s %lu' verdict for v%lu CONSUMES the in-progress ANCHOR (c) opened for the SOFT-REBOOT lifetime — the generation the machine rebooted into, re-judged by the new PID1 lifetime under the same kernel boot's nonce (anchor (a) riding the row that licensed it); accounted, not a finding",
                     g_bl[i].v, st, g_bl[i].epoch, g_bl[i].v);
            if (aj < 0) {
                if (ver_published_this_window(g_bl[i].v)) {
                    info("boot accounting: an ADDED '%lu %s %lu' verdict rides no in-progress of its own, but v%lu was FIRST PUBLISHED this window (in the store's timeline now, absent at the previous observation) — the in-guest activate RE-ARM shape: fx-init resets the boot decision for the activated generation (init.zig:3933-3936) and the re-armed grace window verdicts it without a new in-progress; accounted, not a finding",
                         g_bl[i].v, st, g_bl[i].epoch, g_bl[i].v);
                } else {
                    add_finding("bootlog-forged-verdict",
                                "an ADDED '%lu %s %lu' line has no '%lu in-progress' line earlier in this window wearing its nonce, and v%lu is not a version the store first published in this window — the only two writer paths behind a verdict are the boot that BOOTED the version (in-progress first, same nonce: init.zig:5243, then the verdict sites 2874/2886/2981/4793 under the g_boot_decided latch) and the boot that ACTIVATED the version in-guest (the re-armed grace window verdicts the newly published version with no new in-progress, init.zig:3933-3936; the store's own timeline records that publish), so no boot the host started is behind this line: it was APPENDED by hand. This is the forge that feeds fx-init's boot decision a verdict no boot produced (bootlog_last, init.zig:784): a forged 'ok' makes the next boot skip the roll-forward and keeps a broken generation CURRENT; a forged 'failed' forces one that should not happen",
                                g_bl[i].v, st, g_bl[i].epoch, g_bl[i].v, g_bl[i].v);
                }
            }
        }
        /* the TORN TAIL is readable in-guest: fx-init reads .bootlog with
         * fgets, which returns a final unterminated line — so a forged
         * verdict appended WITHOUT its newline still steers bootlog_last.
         * Account it like any other added line or the check has a
         * no-newline bypass.
         *
         * A torn verdict gets the SAME in-window attribution as a terminated
         * one, and for the same reason: a torn tail is what the writer
         * leaves when it is killed MID-APPEND between a boot's in-progress
         * line and that boot's verdict (the reader above classes a torn tail
         * as "a crash mid-write, not tamper"), and that boot IS one the
         * host's count accounts for.  Firing unconditionally rejected a
         * HEALTHY machine and its message ("no in-progress behind it in this
         * window") contradicted the SAME run's accounting line — a spurious
         * finding rolls back a working system.  It is still never SILENT: a
         * tolerated torn verdict is NAMED, with the in-progress that
         * answers for it, and a torn verdict nothing in this window accounts
         * for is a finding whose message is true of the evidence printed. */
        if (g_bl_torn && g_bl_len > base) {
            char save = g_bl_bytes[g_bl_len];
            g_bl_bytes[g_bl_len] = 0;
            char *tail = g_bl_bytes + base;
            char *last_nl = NULL;
            for (char *q = tail; *q; q++) if (*q == '\n') last_nl = q;
            if (last_nl) tail = last_nl + 1;
            unsigned long tv; char ts[64]; unsigned long tep; char tnonce[80]; char junk[8];
            int tnf = sscanf(tail, "%lu %63s %lu %79s %7s", &tv, ts, &tep, tnonce, junk);
            if (tnf == 3) tnonce[0] = 0;
            if (tail[0] && (tnf == 3 || tnf == 4)) {
                if (!strcmp(ts, "in-progress")) { n_ip++; vstat_for(tv)->ip++; }
                else if (!strcmp(ts, "shutdown")) n_sd++;
                else if (!strcmp(ts, "ok") || !strcmp(ts, "failed")) {
                    n_verdict++;
                    vstat_for(tv)->vd++;
                    /* a torn line's own nonce may be CUT mid-write (tnf==3,
                     * or a truncated 4th field), so a torn verdict is never
                     * nonce-judged on its own token: it rides the in-window
                     * attribution below, and when an in-progress answers for
                     * it, THAT in-progress's nonce is charged — the boot the
                     * host counts is the same boot either way.  A forger
                     * cannot use this as a bypass: a torn tail is the file's
                     * LAST line, so its forged in-progress partner must be
                     * TERMINATED and must itself wear a window nonce (or be
                     * an unbound finding), and the answering slot is charged
                     * a second verdict when the boot already wrote one.
                     * The RE-ARM anchor applies here exactly as for a
                     * terminated verdict: a torn tail is also what a crash
                     * mid-append leaves on the activate path. */
                    long aj = bl_consume_ip(g_nbl, tv, NULL, base, consumed);
                    if (aj >= 0) {
                        long aws = nonce_slot(g_bl[aj].nonce);
                        int awin = (aws >= 0 && g_nled[aws].boot > g_obs_boots && g_nled[aws].boot <= g_boots);
                        if (awin) nvd[aws]++;
                        info("boot accounting: an added TORN '%lu %s %lu' line (no trailing newline) is accounted for by an added '%lu in-progress' line earlier in this window%s — one boot the host started wrote both and the append was cut short mid-write; counted, not a finding",
                             tv, ts, tep, tv, (is_rearm_ip[aj] ? " (the RE-ARM marker the activate arm appended for the activated version, init.zig:3860)" : ""));
                    } else if (ver_published_this_window(tv)) {
                        /* charge the torn line's own slot when its token is
                         * whole and in-window, so the verdict-without-ip
                         * invariant below still sees this verdict */
                        long tws = nonce_slot(tnonce);
                        if (tws >= 0 && g_nled[tws].boot > g_obs_boots && g_nled[tws].boot <= g_boots)
                            nvd[tws]++;
                        info("boot accounting: an added TORN '%lu %s %lu' line (no trailing newline) rides no in-progress of its own, but v%lu was FIRST PUBLISHED this window (in the store's timeline now, absent at the previous observation) — the in-guest activate RE-ARM shape (init.zig:3933-3936) with its verdict append cut mid-write; counted, not a finding",
                             tv, ts, tep, tv);
                    } else {
                        add_finding("bootlog-forged-verdict",
                                    "an ADDED TORN '%lu %s %lu' line (no trailing newline) has no unconsumed '%lu in-progress' line earlier in this window and names no version the store first published in this window — a torn tail is what a crash mid-append leaves, and a hand-appended line without its newline looks identical, so the attribution decides it; the writer's only two paths behind a verdict are an in-progress FIRST (init.zig:5243, before the verdict sites) and the activate re-arm for a version newly published this window (its own marker at init.zig:3860, re-armed at :3933-3936), so no boot the host's count accounts for is behind this line. fx-init reads .bootlog with fgets, which RETURNS a final unterminated line, so bootlog_last still sees this verdict in-guest: the missing newline does not make an appended forge unreadable, only harder to see",
                                    tv, ts, tep, tv);
                    }
                }
            }
            g_bl_bytes[g_bl_len] = save;
        }
        free(consumed);
        /* ── THE RE-ARM IN-PROGRESS RULE (header's rule 3) ────────────────
         * The first in-progress a nonce carries is that boot's OWN; every
         * later one must be an activate re-arm — first-published in this
         * window, newer than the nonce's first version, and the ONLY later
         * in-progress in the window naming that version.  One finding per
         * offending nonce: it names the nonce, the nonce's in-progress
         * TOTAL, the offending version and WHY it cannot be a re-arm — and
         * it says the verdict riding that pair is part of the same forge,
         * because the forged ip is exactly what vouches for the forged
         * verdict. */
        if (g_nonces_given)
            for (size_t i = 0; i < g_nnled; i++) {
                if (!has_rej[i]) continue;
                add_finding("bootlog-fabricated-boots",
                            "the nonce the host issued for boot %lu (%s) carries %zu in-progress line(s) in this window — the FIRST is that boot's OWN (init.zig:5243, written before every verdict site); every later one must be an activate RE-ARM (init.zig:3860) naming a version the store FIRST PUBLISHED in this window, NEWER than that first version (the publish ratchet is max+1, so a re-arm version always exceeds the booted one) AND NOT ALREADY BOOTED (a re-arm names the version the activate JUST published, max+1, which has never been booted) — and, per window, at most ONE re-arm in-progress per first-published version (a publish allocates a version number exactly ONCE, so exactly one boot can have activated it). The one naming v%lu is none of those: %s. A second boot on paper wearing one real boot's nonce — and the verdict that rides this line-pair is part of the same forge",
                            g_nled[i].boot, g_nled[i].nonce, nip[i], rej_ip_v[i], rej_ip_why[i]);
            }
        /* the window's re-arm allowance (header rule 3): every activate
         * appends an in-progress for a version the store first published
         * HERE, so the budget is the boot delta PLUS those versions.  Slack
         * (a roll-forward republish also first-publishes a version) only
         * widens the bound, which is the safe direction — this must never
         * fire on a healthy machine. */
        size_t n_fp = nfp_this_window();
        if (n_ip > delta + n_fp + n_rl_total)
            add_finding("bootlog-fabricated-boots",
                        "%zu in-progress line(s) added but the host started only %lu boot(s) since the previous observation (host boots %lu -> %lu) — and at most %zu of those can be an activate RE-ARM (a version the store FIRST PUBLISHED in this window, init.zig:3860): fx-init writes at most ONE in-progress per boot the host starts (init.zig:5243) plus one per activate re-arm; the surplus was appended by something that is not fx-init booting.  Plus %zu SOFT-REBOOT LIFETIME(S) anchored by an ADMITTED .operator reboot row (anchor (c)): a soft reboot starts no host boot, so its lines ride a nonce the window does not hold, and every one of them needs its own row",
                        n_ip, delta, g_obs_boots, g_boots, n_fp, n_rl_total);
        if (n_sd > delta + n_rl_total)
            add_finding("bootlog-fabricated-boots",
                        "%zu shutdown line(s) added but the host started only %lu boot(s) since the previous observation (host boots %lu -> %lu) — at most one shutdown per boot (init.zig:4613), plus one for each of the %zu SOFT-REBOOT LIFETIME(S) an admitted .operator reboot row anchored (anchor (c))",
                        n_sd, delta, g_obs_boots, g_boots, n_rl_total);
        /* the PER-VERSION verdict budget (the header's rule 2): the writer
         * verdicts a version once per boot that wrote an in-progress for it
         * (the g_boot_decided latch) and at most once more EVER — the boot
         * that ACTIVATED the version in-guest (the re-armed grace window;
         * a publish allocates the version number exactly once).  That ONE
         * extra slot is granted ONLY to a first-published version that
         * carries NO re-arm in-progress of its own: when the writer put the
         * re-arm ip on disk (init.zig:3860) the version's verdict rides THAT
         * and the +1 must not stack on top of it — otherwise a real ip plus
         * one forged verdict would fit the budget and REARMFLIP would
         * regress silently.  This is the budget that survives the re-arm: a
         * per-NONCE verdict budget cannot (one boot, one nonce, MANY
         * activates), and a per-version budget is what catches a SECOND
         * verdict for a version the window already verdicted — under ANY
         * window nonce, the flip that would overwrite a real verdict by
         * appending after it. */
        for (size_t k = 0; k < g_nvstat; k++) { /* VERDICT-BUDGET */
            vstat_t *vs = &g_vstat[k];
            const int fp = ver_published_this_window(vs->v);
            size_t allow = vs->ip + ((fp && vs->ip == 0) ? 1u : 0u);
            if (vs->vd > allow) {
                /* the parenthetical must state what was actually GRANTED:
                 * the +1 credit never applies on top of a present re-arm ip,
                 * and printing the first-published flag then would imply a
                 * slot this version did not get. */
                char credit[200];
                if (vs->ip == 0 && fp)
                    snprintf(credit, sizeof credit, ", first published this window");
                else if (vs->ip != 0 && fp)
                    snprintf(credit, sizeof credit, ", first published this window but its RE-ARM in-progress is PRESENT — the extra slot is NOT granted on top of it");
                else
                    credit[0] = 0;
                /* The cite group below carried ONE colon for FOUR members
                 * (init.zig:2961/2886/2981/4793), so only the first was ever
                 * remapped: 2886 named a pivot_root portability comment, 2981
                 * a BLANK line, 4793 a std.process.exit(1).  They are the four
                 * boot-path verdict APPENDS (ok, boot-failed, grace-expiry,
                 * dhake-failed) — 2961/2973/3068/4897 at the pinned tree — and
                 * were re-aimed by content at the S3 re-measure.  A group like
                 * this is why the pin alone is not enough. */
                add_finding("bootlog-fabricated-boots",
                            "version %lu carries %zu ADDED verdict line(s) this window but at most %zu can be behind them (%zu in-progress line(s) for v%lu%s) — the writer verdicts a version once per boot that wrote an in-progress for it (the g_boot_decided latch, init.zig:3021/3033/3128/5254) and at most once more EVER: the boot that ACTIVATED it in-guest, the re-armed grace window (init.zig:3933-3936; a publish allocates the version number exactly once), and that ONE extra slot is granted only to a version with NO re-arm in-progress of its own (init.zig:3860). A surplus verdict is a boot on paper the host never started",
                            vs->v, vs->vd, allow, vs->ip, vs->v, credit);
            }
        }
        if (n_ip + n_sd + n_verdict == 0 && !g_obs_bl_absent)
            info("boot accounting: no .bootlog lines added this window");
        free(first_ip_v); free(have_first_ip); free(is_rearm_ip); free(is_reboot_ip);
        free(has_rej); free(rej_ip_v); free(rej_ip_why); free(seen_ip);
    }

    /* ── the .recovery rows ADDED since the previous observation ── */
    if (!(g_obs_rec_absent && g_rec_absent) && !(!g_obs_rec_absent && g_rec_absent)) {
        size_t rec_base = g_obs_rec_absent ? 0 : g_obs_rec_bytes;
        int skip_rec = 0;
        if (!g_obs_rec_absent) {
            if (g_rec_len < g_obs_rec_bytes) skip_rec = 1;      /* truncated: already a finding */
            else {
                char sha[65];
                sha256_hex(g_rec_bytes ? g_rec_bytes : "", g_obs_rec_bytes, sha);
                if (strcmp(sha, g_obs_rec_sha) != 0) skip_rec = 1; /* rewritten: already a finding */
            }
        }
        if (!skip_rec && g_rec_len > rec_base) {
            size_t n_rows = 0;
            const char *q = g_rec_bytes + rec_base;
            const char *end = g_rec_bytes + g_rec_len;
            while (q < end) {
                const char *nl = memchr(q, '\n', (size_t)(end - q));
                size_t ll = nl ? (size_t)(nl - q) : (size_t)(end - q);
                /* data rows start with a digit; grep-based readers count a
                 * torn final row too, so a torn row is still growth */
                if (ll && q[0] >= '0' && q[0] <= '9') n_rows++;
                if (!nl) break;
                q = nl + 1;
            }
            if (n_rows > delta)
                add_finding("bootlog-fabricated-boots",
                            "%zu .recovery data row(s) added but the host started only %lu boot(s) since the previous observation (host boots %lu -> %lu) — recovery_append runs at most once per boot (a successful roll-forward inside decide_boot_version); rows no boot wrote are a fabricated recovery history",
                            n_rows, delta, g_obs_boots, g_boots);
            /* the nonce binding for rows (same classification as lines; a
             * TORN final row is counted by n_rows above but never
             * nonce-judged — its token may be cut mid-write) */
            for (size_t i = 0; i < g_nrec; i++) {
                if (g_rec[i].off < rec_base) continue; /* not added */
                long ws = nonce_slot(g_rec[i].nonce);
                int in_win = (ws >= 0 && g_nled[ws].boot > g_obs_boots && g_nled[ws].boot <= g_boots);
                if (in_win) {
                    nrw[ws]++;
                } else {
                    n_unbound_rec++;
                    if (n_unbound_rec == 1)
                        snprintf(unbound_rec_first, sizeof unbound_rec_first, "%lu %lu %lu %s %s",
                                 g_rec[i].epoch, g_rec[i].published, g_rec[i].from_failed,
                                 g_rec[i].genhash,
                                 g_rec[i].nonce[0] ? g_rec[i].nonce : "(no field)");
                }
            }
        }
    }

    /* ── the nonce verdicts (the pair-forgery closure) ────────────────────
     * Order matters for the reader: the STRICT regime turns every unbound
     * added line into a finding; the mixed/manual regime NAMES them and
     * keeps only the boot-count arithmetic.  Both regimes report; neither
     * silently accepts a line as nonce-accounted, and neither silently
     * skips it.  (Counts only ever accumulate inside a judged walk, so a
     * skipped record contributes zeros; the UNCLAIMED report additionally
     * requires the bootlog walk to have run — unknown lines must not read
     * as an unclaimed nonce.) */
    if (g_nonces_given) {
        if (n_unbound_bl) {
            if (strict)
                add_finding("bootlog-unbound-nonce",
                            "%zu ADDED .bootlog line(s) carry no nonce the host issued for a boot in this window; first: '%s' — the host issued a nonce for EVERY boot of this window (window nonces %lu == delta %lu), and fx-init under that regime writes its boot's nonce on every line it appends (init.zig bootlog_append latches the fx.bootnonce= token once per PID1 lifetime), so no boot the host started is behind a nonce-less or foreign-nonce line: this is the forged line-PAIR shape that would otherwise impersonate a silent boot. A line with no nonce field is the PRE-NONCE writer's shape; 'none' is the writer's no-nonce-issued placeholder; a hex nonce from an earlier window or outside the ledger is one this boot was never issued",
                            n_unbound_bl, unbound_bl_first, nwin, delta);
            else
                info("boot accounting: %zu ADDED .bootlog line(s) carry no nonce the host issued for a boot in this window (first: '%s') — the ledger covers %lu of the %lu window boot(s): a MIXED/MANUAL regime (window boots the host started without a nonce, e.g. an operator hand-boot). The nonce binding does not cover these lines; the boot-count arithmetic and the in-progress attribution still do. Reported, never silently accepted as nonce-accounted",
                     n_unbound_bl, unbound_bl_first, nwin, delta);
        }
        if (n_unbound_rec) {
            if (strict)
                add_finding("recovery-unbound-nonce",
                            "%zu ADDED .recovery row(s) carry no nonce the host issued for a boot in this window; first: '%s' — one row per boot, written by recovery_append under that boot's latched nonce; a row no issued nonce backs is a fabricated recovery",
                            n_unbound_rec, unbound_rec_first);
            else
                info("boot accounting: %zu ADDED .recovery row(s) carry no window nonce (first: '%s') — the mixed/manual regime: counted by the boot arithmetic, not nonce-bound",
                     n_unbound_rec, unbound_rec_first);
        }
        /* the per-nonce budget for the lines that ARE once-per-boot: one
         * shutdown, one row per nonce, and a nonce that carries a verdict
         * must carry an in-progress (every verdict site runs in a live boot,
         * which wrote its own in-progress first — and the re-arm verdict
         * rides the re-arm's own ip, or, under the OLD writer, the SAME live
         * boot's nonce).  The IN-PROGRESS budget is per VERSION, not per
         * nonce — one boot can activate many versions, each with its own
         * re-arm line (the per-nonce re-arm rule above), and the VERDICT
         * budget is per version too, on the added-line walk. */
        for (size_t w = 0; w < nwin; w++) {
            size_t s = wslot[w];
            unsigned long b = g_nled[s].boot;
            const char *tok = g_nled[s].nonce;
            if (nsd[s] > 1)
                add_finding("bootlog-fabricated-boots",
                            "the nonce the host issued for boot %lu (%s) carries %zu shutdown line(s) — at most one per boot (init.zig:4613)",
                            b, tok, nsd[s]);
            if (nvd[s] >= 1 && nip[s] == 0)
                add_finding("bootlog-fabricated-boots",
                            "a verdict rides the nonce the host issued for boot %lu (%s), but NO in-progress line wears that nonce — a boot that started wrote its in-progress FIRST (init.zig:5243, before every verdict site), and the re-arm verdict rides the SAME live boot's nonce (its own ip under the new writer, init.zig:3860), so a verdict whose nonce carries no in-progress is a forge wearing a stolen boot's nonce: the pair appended on top of a real boot's own lines",
                            b, tok);
            if (nrw[s] > 1)
                add_finding("bootlog-fabricated-boots",
                            "the nonce the host issued for boot %lu (%s) carries %zu .recovery row(s) — recovery_append runs at most once per boot",
                            b, tok, nrw[s]);
            if (!skip_bl && nip[s] + nvd[s] + nsd[s] + nrw[s] == 0)
                info("boot accounting: the nonce the host issued for boot %lu (%s) is UNCLAIMED — no .bootlog line and no .recovery row this window carries it — a SILENT boot: the host started it and fx-init recorded nothing (no bootable generation, a refused service table, or killed before the in-progress append). REPORTED, not a finding: a machine that booted nothing is not an incoherence, and an unclaimed nonce must never roll a healthy machine back",
                     b, tok);
        }
        if (!strict && delta > 0)
            info("boot accounting: the nonce ledger covers %lu of the %lu boot(s) this window — the pair-forgery closure holds only for the covered boots (a forged pair in an uncovered boot's slack still passes the arithmetic; the run's bound states this)", nwin, delta);
        free(wslot); free(nip); free(nvd); free(nsd); free(nrw);
    }
    free(nrl); free(rl);

    /* ── the journal's own accounting, NAMED ────────────────────────────────
     * The anchor is (c) only for an ADMITTED reboot row; everything else the
     * journal shows about reboots is REPORTED, never silently dropped: a
     * REFUSED reboot opens no lifetime (and is the S1 vocabulary's own
     * report — `not-decided` is a timing, `boot-failed` a state,
     * `shell-open`/`same-version-loop`/`exec-error` their own outcomes), and a
     * row this seat cannot read cannot be an anchor, which is the direction
     * that costs an attribution line instead of licensing a forged one. */
    if (g_op_present && (g_nrb || g_rb_refused || g_rb_unread || g_rb_unanchored || n_rl_total))
        info("boot accounting: .operator holds %zu ADMITTED reboot row(s) this seat may ANCHOR (c) on (%zu of them opened a LIFETIME in this window), %zu REFUSED reboot row(s) (first at line %lu, outcome '%s' — a refusal re-enters nothing and anchors nothing, REPORTED not a finding), %zu admitted row(s) whose nonce the host ledger does not hold (the mixed/manual regime: they can anchor nothing), and %zu data row(s) this seat cannot read as a row (first at line %lu, REPORTED not a finding — a misread must never LICENSE a line, so an unreadable row only ever loses an attribution)",
             g_nrb, n_rl_total, g_rb_refused, g_rb_refused_line,
             g_rb_refused_outcome[0] ? g_rb_refused_outcome : "-",
             g_rb_unanchored, g_rb_unread, g_rb_unread_line);

    if (!skip_bl)
        info("boot accounting: host boots %lu -> %lu (delta %lu); this window added in-progress %zu, verdicts %zu, shutdown %zu — every verdict rides an in-progress the host's count can account for (the in-progress total is bounded by delta %lu + %zu version(s) FIRST PUBLISHED in this window: one activate re-arm per first-published version, each naming a version newer than the one its boot booted and not already booted itself, + %zu SOFT-REBOOT LIFETIME(S) an admitted .operator reboot row anchored)",
             g_obs_boots, g_boots, delta, n_ip, n_verdict, n_sd, delta, nfp_this_window(), n_rl_total);
}

/* the previous-observation comparison — THE load-bearing check */
static void observation_compare(void) {
    if (!g_have_obs) {
        info("first observation of this store: ENROLLING (nothing to compare — a coherent tamper is invisible until the host has seen the store once; this is the seat's bound)");
        return;
    }
    /* .bootlog prefix */
    if (g_obs_bl_absent && g_bl_absent) {
        /* still absent */
    } else if (g_obs_bl_absent && !g_bl_absent) {
        info("transition: .bootlog absent -> present (%zu bytes) — fx-init wrote its first boot verdict", g_bl_len);
    } else if (!g_obs_bl_absent && g_bl_absent) {
        add_finding("record-vanished", ".bootlog was present (%zu bytes at the previous observation) and is now absent", g_obs_bl_bytes);
    } else {
        if (g_bl_len < g_obs_bl_bytes)
            add_finding("disagreement-bootlog-rewritten", ".bootlog was %zu bytes at the previous observation and is now %zu — TRUNCATED (fx-init only ever appends)",
                        g_obs_bl_bytes, g_bl_len);
        else {
            char sha[65];
            sha256_hex(g_bl_bytes ? g_bl_bytes : "", g_obs_bl_bytes, sha);
            if (strcmp(sha, g_obs_bl_sha) != 0)
                add_finding("disagreement-bootlog-rewritten", ".bootlog's previously observed first %zu bytes (sha256 %s..%s) no longer hash the same — the record was REWRITTEN in place; the appended tail is %zu byte(s)",
                            g_obs_bl_bytes, g_obs_bl_sha, g_obs_bl_sha + 56, g_bl_len - g_obs_bl_bytes);
            else if (g_bl_len > g_obs_bl_bytes)
                info(".bootlog grew by %zu byte(s) (append-only respected)", g_bl_len - g_obs_bl_bytes);
        }
    }
    /* .recovery prefix */
    if (g_obs_rec_absent && g_rec_absent) {
    } else if (g_obs_rec_absent && !g_rec_absent) {
        info("transition: .recovery absent -> present (%zu bytes)", g_rec_len);
    } else if (!g_obs_rec_absent && g_rec_absent) {
        add_finding("record-vanished", ".recovery was present (%zu bytes at the previous observation) and is now absent", g_obs_rec_bytes);
    } else {
        if (g_rec_len < g_obs_rec_bytes)
            add_finding("disagreement-recovery-rewritten", ".recovery was %zu bytes at the previous observation and is now %zu — TRUNCATED (fx-init only ever appends)",
                        g_obs_rec_bytes, g_rec_len);
        else {
            char sha[65];
            sha256_hex(g_rec_bytes ? g_rec_bytes : "", g_obs_rec_bytes, sha);
            if (strcmp(sha, g_obs_rec_sha) != 0)
                add_finding("disagreement-recovery-rewritten", ".recovery's previously observed first %zu bytes no longer hash the same — the journal was REWRITTEN in place",
                            g_obs_rec_bytes);
            else if (g_rec_len > g_obs_rec_bytes)
                info(".recovery grew by %zu byte(s) (append-only respected)", g_rec_len - g_obs_rec_bytes);
        }
    }
    /* CURRENT transition (never a finding: activation advances it, hard
     * rollback moves it back — both are writer actions) */
    if (g_current != g_obs_current)
        info("transition: CURRENT %u -> %u (activation or rollback — a change, not an incoherence)", g_obs_current, g_current);
    /* per-version facts */
    for (size_t i = 0; i < g_nobs_vers; i++) {
        unsigned v = g_obs_vers[i];
        long ni = ver_index(v);
        if (ni < 0) {
            info("version %u was in the previous observation and is no longer published — pruned (fxstore gc --retain prunes old snapshots; .bootlog legitimately outlives them)", v);
            continue;
        }
        if (g_obs_genhash[i][0] && g_genhash[ni][0] && strcmp(g_obs_genhash[i], g_genhash[ni]) != 0)
            add_finding("disagreement-facts-changed", "version %u's generation hash was %s at the previous observation and is %s now — a PUBLISHED version's history was rewritten between audits",
                        v, g_obs_genhash[i], g_genhash[ni]);
        if (g_obs_facts[i][0] && g_facts_hash[ni][0] && strcmp(g_obs_facts[i], g_facts_hash[ni]) != 0)
            add_finding("disagreement-facts-changed", "version %u's facts hash was %s at the previous observation and is %s now — the store's own immutable history was rewritten between audits (this is the DISAGREEMENT WITH THE PREVIOUS OBSERVATION no coherent in-guest rewrite can undo)",
                        v, g_obs_facts[i], g_facts_hash[ni]);
    }
    for (size_t i = 0; i < g_nvers; i++) {
        int seen = 0;
        for (size_t j = 0; j < g_nobs_vers; j++) if (g_obs_vers[j] == g_vers[i]) { seen = 1; break; }
        if (!seen) info("version %u is new since the previous observation", g_vers[i]);
    }
    /* source artifacts */
    for (size_t i = 0; i < g_nobs_artifacts; i++) {
        int still = 0;
        for (size_t j = 0; j < g_nartifacts; j++)
            if (!strcmp(g_obs_artifacts[i], g_artifacts[j])) { still = 1; break; }
        if (!still)
            add_finding("disagreement-artifact-gone", "source artifact '%s' existed at the previous observation and is now gone — a src_of binding's source artifact disappeared",
                        g_obs_artifacts[i]);
    }
}

/* ── the trigger ───────────────────────────────────────────────────────── */

static int do_rollback(void) {
    if (g_nfindings == 0) {
        printf("fx-audit: refusing to roll back a coherent store (the trigger must never fire on a clean system)\n");
        return 1;
    }
    unsigned target = g_rollback_v;
    if (!g_rollback_v_given) {
        /* newest version whose last bootlog verdict is ok */
        long best = -1;
        for (size_t i = 0; i < g_nvers; i++) {
            char last[64];
            if (bootlog_last_verdict(g_vers[i], last, sizeof last) && !strcmp(last, "ok"))
                best = (long)i;
        }
        if (best < 0) {
            printf("fx-audit: refusing to roll back: no published version's last .bootlog verdict is ok — the operator must name a target (--rollback <v>)\n");
            return 1;
        }
        if (g_vers[best] == g_current) {
            printf("fx-audit: refusing to roll back: the newest ok-per-.bootlog version IS the current one (%u) — that would be a no-op; the operator must name a target (--rollback <v>)\n", g_current);
            return 1;
        }
        target = g_vers[best];
        for (size_t i = 0; i < g_nfindings; i++)
            if (!strcmp(g_findings[i].name, "disagreement-bootlog-rewritten"))
                printf("fx-audit: NOTE: target v%u was chosen from .bootlog, which is itself one of the tampered records — treat it as UNTRUSTED\n", target);
    } else if (ver_index(target) < 0) {
        printf("fx-audit: refusing to roll back to v%u: not a published version\n", target);
        return 1;
    }
    printf("fx-audit: ROLLBACK %u -> %u (%s) BECAUSE:\n", g_current, target,
           g_current_from_file ? "fxstore rollback --hard" : "current resolved from newest");
    for (size_t i = 0; i < g_nfindings; i++)
        printf("fx-audit:   INCOHERENT %s %s\n", g_findings[i].name, g_findings[i].detail);
    char args[256];
    snprintf(args, sizeof args, "rollback --hard %u --store '%s'", target, g_store_abs);
    int rc;
    char *out = fxstore_capture(args, "rollback", &rc);
    if (out[0]) fputs(out, stdout);
    free(out);
    if (rc != 0) {
        printf("fx-audit: fxstore rollback --hard %u FAILED (exit %d) — the store is UNCHANGED; the incoherence stands\n", target, rc);
        return 2;
    }
    printf("fx-audit: ROLLBACK DONE: CURRENT repointed at v%u. The incoherent records above motivated it; the next boot re-verdicts through fx-init.\n", target);
    /* re-enroll against the post-rollback state: the observation becomes
     * the accepted post-incident baseline (CURRENT moved; the tampered
     * records stay as they are — the response is the rollback, not a
     * history rewrite by the auditor) */
    read_current_file();
    obs_write();
    printf("fx-audit: observation re-enrolled against the post-rollback state (CURRENT=%u)\n", g_current);
    return 0;
}

/* ── main ──────────────────────────────────────────────────────────────── */

static void usage(FILE *f) {
    fprintf(f,
        "fx-audit — the AUDIT seat (host-side coherence detector + rollback trigger)\n"
        "usage: fx-audit --store DIR --boots N [--nonces FILE] [--rootfs DIR]\n"
        "                 [--obs-dir DIR] [--obs-file PATH] [--fxstore BIN]\n"
        "                 [--proxy-log FILE] [--proxy BIN] [--ops-policy-dir DIR]\n"
        "                 [--re-enroll] [--rollback [V]]\n"
        "  --store DIR     the store to audit (as the host sees it)\n"
        "  --boots N       REQUIRED, host truth: how many boots the HOST has EVER\n"
        "                  started on this store, cumulative. The off-disk anchor\n"
        "                  that .bootlog/.recovery growth is accounted against —\n"
        "                  the guest can neither see nor set it. Without it the\n"
        "                  audit REFUSES (an appended forged line is invisible\n"
        "                  without the anchor; assuming a count would make the\n"
        "                  bound decorative).\n"
        "  --nonces FILE   REQUIRED when the window holds boots: the host's OWN\n"
        "                  ledger of the per-boot nonce it issued, one\n"
        "                  \"<boot> <nonce>\" per line (boot = the same ordinal\n"
        "                  --boots counts; the nonce rides the kernel cmdline as\n"
        "                  fx.bootnonce= and fx-init stamps it on every line and\n"
        "                  row it appends that boot). Never read from the guest.\n"
        "                  When the ledger covers every window boot, an ADDED\n"
        "                  line without a window nonce is a FINDING (the forged\n"
        "                  line-PAIR shape); when it covers fewer (a mixed/manual\n"
        "                  regime), such lines are NAMED and counted by the boot\n"
        "                  arithmetic only.  A ledger entry whose nonce is the\n"
        "                  literal \"none\" is REFUSED (exit 2): the writer\n"
        "                  reserves that token as its no-nonce placeholder, so\n"
        "                  the host can never have issued it.\n"
        "  --rootfs DIR    a host view of the guest rootfs (runs `fxstore verify`)\n"
        "  --proxy-log FILE  the host proxy's ONE LOG, taken as a KNOWN record: its\n"
        "                   bytes are recorded in the observation and the previously\n"
        "                   observed prefix must still hash the same (the append-only\n"
        "                   discipline .bootlog and .recovery get): a truncated or\n"
        "                   rewritten host log is a TAMPER finding, and a VANISHED one\n"
        "                   is a record removed, never 'no call was made'\n"
        "  --proxy BIN     the host proxy: its COMPILED-IN registry is the reach\n"
        "                   observation's tool half (--print-host-tools) and its own\n"
        "                   --print-sandbox is the COMPOSED SANDBOX recorded per boot\n"
        "                   (executor baseline + each tool's sidecar); a proxy that\n"
        "                   will not answer is a LOUD failure, never 'no host tools'\n"
        "                   and never 'no sandbox'\n"
        "  --ops-policy-dir DIR  the operator's PINNED tables: the reach observation's\n"
        "                   grant half AND ops-sandbox.tsv, the one pinned half of the\n"
        "                   sandbox.  Each observation records the reach and the\n"
        "                   composed sandbox BESIDE the boot it ran after and names\n"
        "                   the delta against the previous one; a reach WIDENING whose\n"
        "                   tables still hash to PINS is a RELEASE (named, not a\n"
        "                   finding) and one whose tables do NOT is\n"
        "                   `reach-widened-unreleased`.  A sandbox widening is ALWAYS\n"
        "                   `sandbox-widened-unreleased`: the operator table can only\n"
        "                   tighten the APPLIED spec, so it can never widen the\n"
        "                   composition, and nothing pins the baseline or a sidecar\n"
        "  --access-dir DIR  the operator's PINNED ACCESS TABLE (policy/access: PINS +\n"
        "                   access-verbs.tsv) — the tool VOCABULARY.  The FILE is read and\n"
        "                   sha256-verified against policy/access/PINS here (not through the\n"
        "                   proxy's loader, which REFUSES a stale table and so could only\n"
        "                   ever report the released case: the unreleased widening is the\n"
        "                   finding this dimension exists for).  A row the grammar cannot\n"
        "                   read, or an absent table, is LOUD.\n"
        "                   The table is recorded per boot in the shared reach-verb\n"
        "                   grammar and a change is NAMED against this audit's previous\n"
        "                   observation: deny->allow is a WIDENING and is\n"
        "                   `access-widened-unreleased` unless the table hashes to PINS\n"
        "                   (a re-pin RELEASE, named not a finding); allow->deny is a\n"
        "                   NARROWING, named and never a finding.  The per-boot record\n"
        "                   also carries the ARMED-AUTHOR SET this observation could SEE\n"
        "                   (a LOWER BOUND, stated as such) and names a change in it\n"
        "  --obs-dir DIR   observation store dir (default $FX_AUDIT_OBS_DIR, else\n"
        "                  the sibling dir <store>.fx-audit-obs).  MUST NOT be\n"
        "                  inside the store — the observation is host memory.\n"
        "  --obs-file PATH exact observation file (overrides the keying)\n"
        "  --fxstore BIN   fxstore binary (default $FXSTORE_BIN, else PATH)\n"
        "  --re-enroll     accept the current state as the new baseline\n"
        "  --rollback [V]  the thin trigger: on incoherence, `fxstore rollback\n"
        "                  --hard V` (default: newest ok-per-.bootlog).  Refuses\n"
        "                  on a coherent store.\n"
        "exit: 0 coherent, 1 incoherent / refused rollback, 2 tool error\n");
}

int main(int argc, char **argv) {
    const char *obsdir_arg = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--store") && i + 1 < argc) g_store = argv[++i];
        else if (!strncmp(argv[i], "--store=", 8)) g_store = argv[i] + 8;
        else if (!strcmp(argv[i], "--rootfs") && i + 1 < argc) g_rootfs = argv[++i];
        else if (!strncmp(argv[i], "--rootfs=", 9)) g_rootfs = argv[i] + 9;
        else if (!strcmp(argv[i], "--obs-dir") && i + 1 < argc) obsdir_arg = argv[++i];
        else if (!strncmp(argv[i], "--obs-dir=", 10)) obsdir_arg = argv[i] + 10;
        else if (!strcmp(argv[i], "--obs-file") && i + 1 < argc) g_obsfile = argv[++i];
        else if (!strncmp(argv[i], "--obs-file=", 11)) g_obsfile = argv[i] + 11;
        else if (!strcmp(argv[i], "--fxstore") && i + 1 < argc) g_fxstore = argv[++i];
        else if (!strncmp(argv[i], "--fxstore=", 10)) g_fxstore = argv[i] + 10;
        else if (!strcmp(argv[i], "--proxy-log") && i + 1 < argc) g_plog = argv[++i];
        else if (!strncmp(argv[i], "--proxy-log=", 12)) g_plog = argv[i] + 12;
        else if (!strcmp(argv[i], "--proxy") && i + 1 < argc) {
            g_proxy = argv[++i];
            check_safe_path(g_proxy, "--proxy");
        }
        else if (!strncmp(argv[i], "--proxy=", 8)) {
            if (!argv[i][8]) die("--proxy= needs the host proxy binary path");
            g_proxy = argv[i] + 8;
            check_safe_path(g_proxy, "--proxy");
        }
        else if (!strcmp(argv[i], "--ops-policy-dir") && i + 1 < argc) g_opsdir = argv[++i];
        else if (!strncmp(argv[i], "--ops-policy-dir=", 17)) g_opsdir = argv[i] + 17;
        else if (!strcmp(argv[i], "--access-dir") && i + 1 < argc) g_accessdir = argv[++i];
        else if (!strncmp(argv[i], "--access-dir=", 13)) g_accessdir = argv[i] + 13;
        else if (!strcmp(argv[i], "--re-enroll")) g_reenroll = 1;
        else if (!strcmp(argv[i], "--nonces") && i + 1 < argc) {
            g_nonces_path = argv[++i];
            check_safe_path(g_nonces_path, "--nonces");
            g_nonces_given = 1;
        }
        else if (!strncmp(argv[i], "--nonces=", 9)) {
            if (!argv[i][9]) die("--nonces= needs the host's nonce ledger path");
            g_nonces_path = argv[i] + 9;
            check_safe_path(g_nonces_path, "--nonces");
            g_nonces_given = 1;
        }
        else if (!strcmp(argv[i], "--boots") && i + 1 < argc) {
            char *end = NULL;
            g_boots = strtoul(argv[++i], &end, 10);
            if (!end || *end || end == argv[i] || argv[i][0] == '-')
                die("--boots '%s' is not a non-negative integer", argv[i]);
            g_boots_given = 1;
        }
        else if (!strncmp(argv[i], "--boots=", 8)) {
            char *val = argv[i] + 8, *end = NULL;
            g_boots = strtoul(val, &end, 10);
            if (!end || *end || end == val || val[0] == '-')
                die("--boots '%s' is not a non-negative integer", val);
            g_boots_given = 1;
        }
        else if (!strcmp(argv[i], "--rollback")) {
            g_rollback = 1;
            if (i + 1 < argc && argv[i + 1][0] >= '0' && argv[i + 1][0] <= '9') {
                g_rollback_v = (unsigned)strtoul(argv[++i], NULL, 10);
                g_rollback_v_given = 1;
            }
        }
        else if (!strncmp(argv[i], "--rollback=", 11)) {
            g_rollback = 1;
            g_rollback_v = (unsigned)strtoul(argv[i] + 11, NULL, 10);
            g_rollback_v_given = 1;
        }
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) { usage(stdout); return 0; }
        else { fprintf(stderr, "fx-audit: unknown arg '%s'\n", argv[i]); usage(stderr); return 2; }
    }
    if (!g_store) { fprintf(stderr, "fx-audit: --store is required\n"); usage(stderr); return 2; }
    if (!g_boots_given)
        die("--boots is REQUIRED: the host's cumulative boot count on this store is the OFF-DISK anchor that .bootlog growth is accounted against — without it an appended forged line is INVISIBLE (the measured hole this seat exists to close), and silently assuming a count is how a bound becomes decorative. Pass --boots N (N = boots the host has EVER started on this store; 0 is valid)");
    check_safe_path(g_store, "--store");
    if (g_rootfs) check_safe_path(g_rootfs, "--rootfs");
    if (g_obsfile) check_safe_path(g_obsfile, "--obs-file");
    if (!g_fxstore) {
        const char *fb = getenv("FXSTORE_BIN");
        g_fxstore = (fb && *fb) ? fb : "fxstore";
    }
    check_safe_path(g_fxstore, "--fxstore");

    if (!realpath(g_store, g_store_abs))
        die("cannot resolve --store '%s': %s", g_store, strerror(errno));

    if (g_obsfile) {
        /* an explicit observation FILE gets the same guard as --obs-dir:
         * host memory must not live on agent-reachable disk.  realpath when
         * the file exists, lexical check when it does not (a first run
         * points at a file nothing has written yet). */
        char oabs[4096];
        if (!realpath(g_obsfile, oabs)) {
            if (g_obsfile[0] == '/')
                snprintf(oabs, sizeof oabs, "%s", g_obsfile);
            else
                oabs[0] = 0;
        }
        if (oabs[0]) {
            size_t sl0 = strlen(g_store_abs);
            if (!strncmp(oabs, g_store_abs, sl0) && (oabs[sl0] == '/' || oabs[sl0] == 0))
                die("--obs-file '%s' is INSIDE the store '%s' — the observation is host memory and must not live on agent-reachable disk", oabs, g_store_abs);
        }
    }

    /* the observation dir defaults to the SIBLING of the store and must
     * never live INSIDE it (agent-reachable disk) */
    if (!g_obsdir && !g_obsfile) {
        const char *env = getenv("FX_AUDIT_OBS_DIR");
        if (env && *env) g_obsdir = env;
    }
    if (obsdir_arg) g_obsdir = obsdir_arg;
    if (g_obsdir && !g_obsfile) {
        check_safe_path(g_obsdir, "--obs-dir");
        char abs[8192];
        if (!realpath(g_obsdir, abs)) {
            /* not there yet: resolve its parent and append the leaf */
            char parent[4096];
            snprintf(parent, sizeof parent, "%s", g_obsdir);
            char *slash = strrchr(parent, '/');
            const char *leaf = g_obsdir;
            if (slash && slash != parent) {
                *slash = 0;
                leaf = slash + 1;
            } else if (slash) leaf = g_obsdir + 1;
            char pabs[4096];
            if (!realpath(parent[0] ? parent : "/", pabs))
                die("cannot resolve --obs-dir parent '%s': %s", parent, strerror(errno));
            snprintf(abs, sizeof abs, "%s/%s", pabs, leaf);
        }
        g_obsdir = xstrdup(abs);
        size_t sl = strlen(g_store_abs);
        int inside = !strncmp(g_obsdir, g_store_abs, sl) && (g_obsdir[sl] == '/' || g_obsdir[sl] == 0);
        if (inside)
            die("--obs-dir '%s' is INSIDE the store '%s' — the observation is host memory and must not live on agent-reachable disk", g_obsdir, g_store_abs);
    }
    if (!g_obsdir && !g_obsfile) {
        static char def[4200];
        snprintf(def, sizeof def, "%s.fx-audit-obs", g_store_abs);
        g_obsdir = def;
    }

    printf("fx-audit: store %s (fxstore %s)\n", g_store_abs, g_fxstore);
    printf("fx-audit: host boots on this store: %lu (the off-disk anchor; the guest can neither see nor set it)\n", g_boots);
    {
        char op[4096]; obs_path_for(op, sizeof op);
        printf("fx-audit: observation %s\n", op);
    }

    /* ── read every record (a read error dies loudly) ── */
    read_bootlog();
    read_recovery();
    {
        char args[4096];
        snprintf(args, sizeof args, "timeline --store '%s'", g_store_abs);
        size_t n = 0;
        char **lines = fxstore_lines(args, "timeline", &n);
        for (size_t i = 0; i < n; i++) {
            unsigned v;
            if (sscanf(lines[i], " %u", &v) == 1) {
                if (g_nvers >= MAX_VERSIONS)
                    die("timeline has more than %d versions — raise the cap or prune (gc --retain)", MAX_VERSIONS);
                g_vers[g_nvers++] = v;
            }
        }
        free_lines(lines, n);
        /* timeline prints ascending; make no assumption */
        for (size_t i = 0; i + 1 < g_nvers; i++)
            for (size_t j = i + 1; j < g_nvers; j++)
                if (g_vers[j] < g_vers[i]) { unsigned t = g_vers[i]; g_vers[i] = g_vers[j]; g_vers[j] = t; }
    }
    read_current_file();

    /* per-version facts hashes + genhashes */
    for (size_t i = 0; i < g_nvers; i++) {
        hash_version_facts(g_vers[i], g_facts_hash[i]);
        char args[8192];
        snprintf(args, sizeof args, "facts generation --as-of %u --store '%s'", g_vers[i], g_store_abs);
        size_t n = 0;
        char **lines = fxstore_lines(args, "generation", &n);
        g_genhash[i][0] = 0;
        for (size_t j = 0; j < n; j++) {
            char *tab = strchr(lines[j], '\t');
            if (tab) *tab = 0;
            snprintf(g_genhash[i], 65, "%s", lines[j]);
            break;
        }
        free_lines(lines, n);
    }

    /* the current version's facts used by the checks */
    {
        char args[8192];
        size_t n = 0;
        struct { const char *rel; row_t **rows; size_t *n; } loads[] = {
            { "install", &g_install, &g_ninstall },
            { "provides", &g_provides, &g_nprovides },
            { "src_of",   &g_src_of,   &g_nsrc_of },
            { "svc_bin",  &g_svcbin,   &g_nsvcbin },
        };
        for (size_t k = 0; k < sizeof loads / sizeof loads[0]; k++) {
            snprintf(args, sizeof args, "facts %s --as-of %u --store '%s'", loads[k].rel, g_current, g_store_abs);
            char **lines = fxstore_lines(args, loads[k].rel, &n);
            *loads[k].rows = lines_to_rows(lines, n, loads[k].rel, loads[k].n);
            free_lines(lines, n);
            n = 0;
        }
    }

    /* the store's source artifacts (existing <64hex>-<name>-src dirs) */
    {
        char cmd[4096];
        snprintf(cmd, sizeof cmd, "find '%s' -maxdepth 1 -type d -name '*-src' 2>/dev/null | sort", g_store_abs);
        FILE *p = popen(cmd, "r");
        if (!p) die("cannot list the store (%s)", strerror(errno));
        char line[4096];
        while (fgets(line, sizeof line, p)) {
            line[strcspn(line, "\n")] = 0;
            const char *base = strrchr(line, '/');
            base = base ? base + 1 : line;
            g_artifacts = realloc(g_artifacts, (g_nartifacts + 1) * sizeof *g_artifacts);
            if (!g_artifacts) die("out of memory");
            snprintf(g_artifacts[g_nartifacts], sizeof g_artifacts[g_nartifacts], "%.*s",
                     (int)(sizeof g_artifacts[g_nartifacts] - 1), base);
            g_nartifacts++;
        }
        pclose(p);
    }

    /* ── the previous observation (read BEFORE the checks so the compare
     * has it; written only at the end) ── */
    obs_read();
    /* S4: the proxy's one log as a KNOWN RECORD, and the DECLARED REACH this
     * observation measures — read BEFORE the checks (they only judge what is
     * loaded) and AFTER obs_read (the comparison needs the baseline). */
    read_proxy_log_record();
    reach_read_proxy();
    sandbox_read_composed();
    reach_read_tables();
    /* S5: the access table (the DECLARED file, verified against its PINS by
     * the check) and the armed-author set this observation can see — both read
     * BEFORE the emission below, so the per-boot record carries them. */
    access_read_table();
    armed_authors_compute();
    reach_anchor_boot();
    emit_reach_rows();
    emit_sandbox_rows();
    /* the host's nonce ledger is loaded AFTER obs_read (its window is
     * defined by the observation's boot count) and BEFORE the checks */
    load_nonces();
    /* ANCHOR (c): the .operator journal, read AFTER the ledger (a reboot row
     * is only an anchor when it wears a nonce the host issued) — the soft
     * reboot is a new PID1 lifetime under the SAME kernel boot's nonce, so
     * the boot count cannot account for its lines */
    read_operator_journal();

    /* ── the checks.  ONE run_check CALL PER LINE: the gate deletes exactly
     * one of these lines to build a mutated detector and prove the matching
     * fixture's assertion can FAIL (the positive control). ── */
    run_check("version-chain", check_version_chain);
    run_check("recovery-without-failure", check_recovery_without_failure);
    run_check("verify-drift", check_verify_drift);
    run_check("facts-path-gone", check_facts_path_gone);
    run_check("src-of-artifact", check_src_of_artifact);
    run_check("records-damaged", check_records_damaged);
    run_check("boot-accounting", check_boot_accounting);
    run_check("proxy-log-record", check_proxy_log);
    run_check("egress-reach", check_reach);
    run_check("sandbox-record", check_sandbox);
    run_check("access-record", check_access);
    run_check("previous-observation", observation_compare);

    size_t pass = 0, skip = 0, fail = 0;
    size_t before;
    for (size_t i = 0; i < g_nchecks; i++) {
        before = g_nfindings;
        g_checks[i].fn();
        printf("check %s: ", g_checks[i].name);
        if (g_nfindings > before) { printf("failed\n"); fail++; }
        else { printf("pass\n"); pass++; }
        (void)skip;
    }

    for (size_t i = 0; i < g_nfindings; i++)
        printf("INCOHERENT %s %s\n", g_findings[i].name, g_findings[i].detail);

    if (g_bl_torn) info(".bootlog has a torn tail (%zu unterminated line(s)) — a crash mid-write, not a verdict", g_bl_torn);
    printf("checks: %zu pass, %zu failed; findings: %zu\n", pass, fail, g_nfindings);
    printf("bound: this seat sees REWRITES and TRUNCATIONS of records it previously observed, cross-record INCOHERENCE, and — anchored on --boots and the per-boot nonce ledger (--nonces) — APPENDED .bootlog/.recovery growth the host cannot account for. IN THE NONCE REGIME (the host issues fx.bootnonce= per boot and every window boot is covered) the forged line-PAIR in a silent boot's slack is CLOSED: every ADDED line must wear a nonce the host issued for a boot in this window, the per-nonce IN-PROGRESS budget is the boot's OWN line plus one activate RE-ARM per version the store FIRST PUBLISHED in this window (each naming a version newer than the one its boot booted — init.zig:3860), the re-arm ip budget being ONE per first-published VERSION per WINDOW (a publish allocates a version number exactly once) AND naming a version NOT ALREADY BOOTED in the window (a re-arm names the version the activate JUST published, max+1, which has never been booted — this is what refuses the roll-forward REPUBLISH forge), shutdown / .recovery rows hold at one per boot, and the VERDICT accounting is per VERSION — one verdict per in-progress line the window added for that version, plus ONE more ONLY for a first-published version carrying NO re-arm ip of its own (the OLD-writer re-arm shape, init.zig:3933-3936). THE RE-ARM LINE'S OWN DELTA: that legitimate line RE-OPENS the forged-PAIR shape for a version that is first-published in the window AND newer than the boot's own, on ANY real window boot's nonce (the closure there is per VERSION, not per nonce — ONE re-arm in-progress per first-published version per window, so a forged pair cannot ride a second window nonce to buy a second verdict, whether the version was activated or republished — the republish shape is refused by the not-already-booted clause — and the legitimate line grants no verdict slot the +1 did not already grant). RESIDUAL, named: a forged pair for a version first published WITHOUT an activation and NOT YET BOOTED in the window (the operator `rollback` during a live boot, before the next boot boots it) still reads as a legitimate re-arm and lands the version's FIRST verdict — indistinguishable from a real activation without the .operator journal this seat does not read; the automatic roll-forward has no such window (the republish and the boot are one PID1 start), and the moment the version IS booted the not-already-booted clause refuses the same forge. What a forger still cannot mint is an in-progress for a version the store did not publish in this window, or one NOT newer than that nonce's own first line (the per-nonce rule fires on both) — and an unclaimed nonce is REPORTED as a silent boot. What this seat CANNOT see, stated as its bound: a verdict SUBSTITUTED inside a LIVE boot — the agent is root in the guest and can read its own /proc/cmdline nonce, so it can append the verdict itself in the writer's exact shape wearing the live nonce and suppress fx-init's own (a panic before grace expiry); that leaves ONE verdict for one (nonce, version) with every anchor satisfied, and the line's authorship inside the boot that owns the nonce is NOT distinguishable from the host — auditing, not proofing (the defence against substitution is the rollback machinery plus the observation hashes, not this reader); window boots the ledger does not cover (a mixed/manual regime — nonce-less lines are named and counted, but a forged pair in an UNCOVERED boot's slack still passes the arithmetic); boots started off the counting host, or a miscounted / moved --obs-file reuse (the count and the ledger are only as true as the host's own bookkeeping); a coherent tamper on a store first seen at enrollment (the enrollment gap — first run trusts, loudly). ANCHOR (c), the SOFT REBOOT, is the newest widening and it is named here: a legitimate soft reboot is a NEW PID1 LIFETIME under the SAME kernel boot's nonce, delimited by an ADMITTED .operator `reboot` row (no host boot starts, so the boot count can never account for its lines), and an anchor-(c) pair must still name an EXISTING published version under a nonce the HOST issued, with ONE row per lifetime. What that COSTS: a forger who writes a reboot row buys a plausible in-progress + verdict pair for an existing version — one row per pair, on a machine whose agent is root either way; and the journal is NOT watched the way .bootlog/.recovery are (it is not in this seat's observation hash), so a row may be added, rewritten or removed between audits without this seat seeing the change — it judges the pairs against whatever the journal says NOW, and dropping a row can only make a pair FIRE, never pass. That is the trade, stated rather than left to be discovered. That is the honest bound of auditing, not proofing (§6b), printed on every run so the tool never implies more than it knows.\n");
    printf("bound (S4): the host proxy's ONE LOG is a KNOWN record only from the bytes it has NOW onward — this seat records them and re-hashes the prefix, so a TAMPER AFTER an observation is caught and a tamper BEFORE the first one is not (the same enrollment bound as every other record here); a log the caller does not name is NOT-KNOWN, never 'no call was made'.  The DECLARED REACH is measured WHEN THE OBSERVATION IS TAKEN (the proxy's registry as it prints now, the operator's tables as they hash now) and attributed to the LAST boot in .bootlog — it is NOT a reconstruction of what any EARLIER boot's generation could reach, and this seat does not claim one.  'Released' means the two class tables hash to their PINS (an operator act with a record); a widening under an UNVERIFIABLE release (no PINS) takes the loud side by construction, which can be a FALSE POSITIVE on a host with no pinned table set — named here rather than discovered.\n");
    printf("bound (S4b): the COMPOSED SANDBOX is recorded per boot (the proxy's own --print-sandbox: the executor baseline + each tool's sidecar, plus one sha over the block) and a change is NAMED against THIS audit's previous observation.  What that can and cannot see, said rather than left to be discovered: the operator's ops-sandbox.tsv is the ONLY pinned half, it is DENY-MORE-ONLY and it narrows only what the spawn APPLIES — so it cannot WIDEN --print-sandbox, and therefore a widening of the composition can only come from the executor BASELINE or a SIDECAR, NEITHER of which any pin covers.  There is no released-widening path in v1: every widening takes the loud side (sandbox-widened-unreleased), and a deliberately, legitimately widened sidecar is a false positive this seat cannot distinguish — the pin's reach is the bound.  A NARROWING needs no release and is named.  And VISIBLE IS NOT STRONG: the promises are coarse (`inet` is any destination), the confinement is per-process and not per-call, there is no uid drop, and this record says what was DECLARED and APPLIED, never which syscalls a call made.\n");
    printf("bound (S5): the ACCESS TABLE (the tool VOCABULARY) is recorded per boot in the shared reach-verb grammar and a change is NAMED against THIS audit's previous observation; deny->allow is a WIDENING and is the finding access-widened-unreleased unless the table still hashes to policy/access/PINS (then it is a RE-PIN RELEASE: named, not a finding), and allow->deny is a NARROWING (named, never a finding).  What that CANNOT see: this seat reads the DECLARED file and pins it here, so it says what the table SAYS and whether that was released — not what a served judge has loaded (the loader's startup refusal is that seat's own guard, and it fires before any verdict); and it says nothing about the PATHS a permitted call may touch (the ops seat and the in-guest floor are those) nor about an agent acting outside a tool call.  The ARMED-AUTHOR SET in the per-boot record is a LOWER BOUND taken from the INPUTS this observation was given (access = the table was read, ops = the pinned class tables were read): the compiled-in denylist, the justification arm and the claim author are NOT queryable from this seat, so 'none' means 'none was visible HERE', never 'nothing could refuse'.\n");
    printf("evidence: the store's own records only — attempts.jsonl (the harness self-report) is never opened.\n");

    if (g_nfindings > 0) {
        printf("VERDICT: incoherent (%zu finding(s))\n", g_nfindings);
        if (g_rollback) return do_rollback();
        return 1;
    }
    printf("VERDICT: coherent\n");
    obs_write();
    if (g_reenroll)
        printf("fx-audit: --re-enroll given on a coherent store: observation already written\n");
    if (g_rollback) {
        printf("fx-audit: refusing to roll back a coherent store (the trigger must never fire on a clean system)\n");
        return 1;
    }
    return 0;
}
