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
 *                              verdicts it with no new in-progress).  No
 *                              boot the host started is behind such a line
 *                              (the appended "<failed v> ok" that would
 *                              stop fx-init rolling forward).  A TORN
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
 * recovery: fx-init's boot decision (bootlog_last, init.zig:765) reads the
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
 *                  ONE from the boot path (init.zig:4886: once per PID1
 *                  lifetime, for the version being booted, and only when a
 *                  generation was bootable AND its facts read ok — the
 *                  no-generation and facts-fail paths append NOTHING and
 *                  pre-decide the verdict away, g_boot_decided=1 before
 *                  any line is written), and ONE PER ACTIVATE from the
 *                  activate arm (init.zig:3724: appended AFTER the store's
 *                  CURRENT rewrite and BEFORE the activated version's facts
 *                  are read, so the activated window is OPEN on disk before
 *                  anything can refuse it).  The boot path's line is that
 *                  boot's FIRST in-progress, always — the PER-NONCE rule
 *                  below rests on exactly that.
 *   verdict        the g_boot_decided latch allows one verdict per DECISION:
 *                  the boot path (dhake failure init.zig:4897; grace
 *                  expiry :2961/:2973; a service exiting during grace
 *                  :3068) verdicts the version it BOOTED, in a boot that
 *                  already appended its in-progress for that same version;
 *                  the activate REFUSAL arm verdicts the version it refused
 *                  (init.zig:3767), riding the arm's own in-progress above
 *   the RE-ARM     the in-guest `activate` (the control channel, the path
 *                  the agent-slot loop uses every task cycle) PUBLISHES a
 *                  new version through fx-activate (the store's CURRENT
 *                  moves) and then RESETS the latch — g_boot_decided=0,
 *                  g_boot_failed=0, a fresh grace deadline (init.zig:
 *                  3797-3800) — so the SAME boot appends a SECOND verdict
 *                  for the NEWLY ACTIVATED version, which now WEARS ITS OWN
 *                  in-progress: init.zig:3724 writes it before the facts are
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
 *   shutdown       at most ONE (init.zig:4396, the SIGTERM path), naming
 *                  whatever version is current when PID1 exits (after an
 *                  activate, the ACTIVATED one — no in-progress of its own
 *                  in this boot either; the shutdown budget never looks at
 *                  versions)
 *   .recovery      at most ONE data row (recovery_append, init.zig:915,
 *                  once per successful roll-forward inside
 *                  decide_boot_version, whose every appending walk
 *                  iteration returns)
 * Hence, for the lines ADDED since the previous observation:
 *   1. each added ok/failed for version v must be accounted by ONE of the
 *      two writer paths, both anchored OUTSIDE the line itself:
 *      (a) an added in-progress for v wearing the SAME nonce, earlier in
 *      the window, not yet consumed by an earlier verdict for v (one nonce
 *      per PID1 lifetime — every line of a boot carries the one latched at
 *      its start), or
 *      (b) v is a version the STORE first published in this window: in the
 *      timeline now, absent from the previous observation's version list —
 *      the re-arm verdict is for exactly such a version, and the record is
 *      fxstore's own publish history (snapshots + facts + timeline,
 *      transactionally written), not .bootlog, the file the forger
 *      appends to.  A verdict with neither anchor is a FORGED VERDICT (the
 *      motivating exploit, named as that).  A TORN verdict (the file's
 *      LAST line, unterminated) rides the SAME two anchors, because
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
 *      version); shutdown lines and recovery rows at most the DELTA — more
 *      boots on paper than the host started are FABRICATED BOOTS.
 *      PER NONCE, the FIRST added in-progress is that boot's OWN
 *      (init.zig:4886, written before every verdict site), and every
 *      SUBSEQUENT one must be an activate re-arm (init.zig:3724) naming a
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
 * init.zig:1788, or the operator `rollback`, init.zig:3853) — and then
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
 * boot decision (init.zig:3797-3800); the re-armed grace window then
 * verdicts EXACTLY that version, riding the in-progress the activate arm
 * appended for it (init.zig:3724 — the writer's re-arm marker; the OLD
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
 * booted, init.zig:3724 — and <=1 shutdown, <=1 .recovery row) and PER
 * VERSION for verdicts: a verdict rides an in-progress wearing ITS OWN
 * nonce (one boot, one nonce — every line of a boot carries the nonce
 * latched at its start, the re-arm ip included) OR names a version the
 * STORE first published in this window (the OLD-writer activate re-arm,
 * which verdicts the activated generation without a new in-progress,
 * init.zig:3797-3800); and a version carries at most one verdict per
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
    for (size_t i = 0; i < g_nnled; i++) nip[i] = nvd[i] = nsd[i] = nrw[i] = 0;
    size_t n_unbound_bl = 0;   /* added lines with no window nonce */
    char unbound_bl_first[256]; unbound_bl_first[0] = 0;
    size_t n_unbound_rec = 0;  /* added rows with no window nonce */
    char unbound_rec_first[256]; unbound_rec_first[0] = 0;

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
         * in-progress of each nonce — that boot's OWN line (init.zig:4886,
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
         * OWN first in-progress (init.zig:4886): the re-arm line names a
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
        char *has_rej = malloc(g_nnled ? g_nnled : 1);
        unsigned long *rej_ip_v = malloc((g_nnled ? g_nnled : 1) * sizeof *rej_ip_v);
        char (*rej_ip_why)[288] = malloc((g_nnled ? g_nnled : 1) * sizeof *rej_ip_why);
        unsigned long *seen_ip = malloc((g_nbl ? g_nbl : 1) * sizeof *seen_ip);
        if (!first_ip_v || !have_first_ip || !is_rearm_ip || !has_rej || !rej_ip_v || !rej_ip_why || !seen_ip)
            die("out of memory");
        for (size_t i = 0; i < g_nnled; i++) {
            have_first_ip[i] = has_rej[i] = 0;
            first_ip_v[i] = rej_ip_v[i] = 0;
            rej_ip_why[i][0] = 0;
        }
        if (g_nbl) memset(is_rearm_ip, 0, g_nbl);
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
                if (in_win) {
                    if (!strcmp(st, "in-progress")) {
                        nip[ws]++;
                        if (!have_first_ip[ws]) {
                            have_first_ip[ws] = 1;
                            first_ip_v[ws] = g_bl[i].v;
                            /* that boot's OWN version.  A version is FRESH
                             * at activation time — the publish ratchet
                             * allocates max+1, so the activate arm's re-arm
                             * line (init.zig:3724) can only ever name a
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
                                             "v%lu was ALREADY BOOTED in this window (its own first in-progress appeared earlier) — a re-arm (init.zig:3724) names the version the activate JUST published (max+1, never booted): a forged pair riding an earlier boot's nonce to buy a SECOND verdict", g_bl[i].v);
                                }
                            } else if (!ver_published_this_window(g_bl[i].v)) {
                                if (!has_rej[ws]) {
                                    has_rej[ws] = 1; rej_ip_v[ws] = g_bl[i].v;
                                    snprintf(rej_ip_why[ws], sizeof rej_ip_why[ws],
                                             "v%lu is NOT a version the store first published in this window (init.zig:3724 only ever names the version the activate just published)", g_bl[i].v);
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
                                info("boot accounting: the nonce the host issued for boot %lu (%s) carries a RE-ARM in-progress for v%lu — a version the store FIRST PUBLISHED in this window and NEWER than v%lu, the version that boot BOOTED: the activate arm's own window marker (init.zig:3724, appended before the activated facts are read); accounted, not a finding",
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
                info("boot accounting: the ADDED '%lu %s %lu' verdict for v%lu CONSUMES the RE-ARM in-progress this boot wrote for it (init.zig:3724) — the activated generation's own window, closed by the re-armed grace window (init.zig:3797-3800) under the same nonce; accounted, not a finding",
                     g_bl[i].v, st, g_bl[i].epoch, g_bl[i].v);
            if (aj < 0) {
                if (ver_published_this_window(g_bl[i].v)) {
                    info("boot accounting: an ADDED '%lu %s %lu' verdict rides no in-progress of its own, but v%lu was FIRST PUBLISHED this window (in the store's timeline now, absent at the previous observation) — the in-guest activate RE-ARM shape: fx-init resets the boot decision for the activated generation (init.zig:3797-3800) and the re-armed grace window verdicts it without a new in-progress; accounted, not a finding",
                         g_bl[i].v, st, g_bl[i].epoch, g_bl[i].v);
                } else {
                    add_finding("bootlog-forged-verdict",
                                "an ADDED '%lu %s %lu' line has no '%lu in-progress' line earlier in this window wearing its nonce, and v%lu is not a version the store first published in this window — the only two writer paths behind a verdict are the boot that BOOTED the version (in-progress first, same nonce: init.zig:4886, then the verdict sites 2874/2886/2981/4793 under the g_boot_decided latch) and the boot that ACTIVATED the version in-guest (the re-armed grace window verdicts the newly published version with no new in-progress, init.zig:3797-3800; the store's own timeline records that publish), so no boot the host started is behind this line: it was APPENDED by hand. This is the forge that feeds fx-init's boot decision a verdict no boot produced (bootlog_last, init.zig:765): a forged 'ok' makes the next boot skip the roll-forward and keeps a broken generation CURRENT; a forged 'failed' forces one that should not happen",
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
                             tv, ts, tep, tv, (is_rearm_ip[aj] ? " (the RE-ARM marker the activate arm appended for the activated version, init.zig:3724)" : ""));
                    } else if (ver_published_this_window(tv)) {
                        /* charge the torn line's own slot when its token is
                         * whole and in-window, so the verdict-without-ip
                         * invariant below still sees this verdict */
                        long tws = nonce_slot(tnonce);
                        if (tws >= 0 && g_nled[tws].boot > g_obs_boots && g_nled[tws].boot <= g_boots)
                            nvd[tws]++;
                        info("boot accounting: an added TORN '%lu %s %lu' line (no trailing newline) rides no in-progress of its own, but v%lu was FIRST PUBLISHED this window (in the store's timeline now, absent at the previous observation) — the in-guest activate RE-ARM shape (init.zig:3797-3800) with its verdict append cut mid-write; counted, not a finding",
                             tv, ts, tep, tv);
                    } else {
                        add_finding("bootlog-forged-verdict",
                                    "an ADDED TORN '%lu %s %lu' line (no trailing newline) has no unconsumed '%lu in-progress' line earlier in this window and names no version the store first published in this window — a torn tail is what a crash mid-append leaves, and a hand-appended line without its newline looks identical, so the attribution decides it; the writer's only two paths behind a verdict are an in-progress FIRST (init.zig:4886, before the verdict sites) and the activate re-arm for a version newly published this window (its own marker at init.zig:3724, re-armed at :3797-3800), so no boot the host's count accounts for is behind this line. fx-init reads .bootlog with fgets, which RETURNS a final unterminated line, so bootlog_last still sees this verdict in-guest: the missing newline does not make an appended forge unreadable, only harder to see",
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
                            "the nonce the host issued for boot %lu (%s) carries %zu in-progress line(s) in this window — the FIRST is that boot's OWN (init.zig:4886, written before every verdict site); every later one must be an activate RE-ARM (init.zig:3724) naming a version the store FIRST PUBLISHED in this window, NEWER than that first version (the publish ratchet is max+1, so a re-arm version always exceeds the booted one) AND NOT ALREADY BOOTED (a re-arm names the version the activate JUST published, max+1, which has never been booted) — and, per window, at most ONE re-arm in-progress per first-published version (a publish allocates a version number exactly ONCE, so exactly one boot can have activated it). The one naming v%lu is none of those: %s. A second boot on paper wearing one real boot's nonce — and the verdict that rides this line-pair is part of the same forge",
                            g_nled[i].boot, g_nled[i].nonce, nip[i], rej_ip_v[i], rej_ip_why[i]);
            }
        /* the window's re-arm allowance (header rule 3): every activate
         * appends an in-progress for a version the store first published
         * HERE, so the budget is the boot delta PLUS those versions.  Slack
         * (a roll-forward republish also first-publishes a version) only
         * widens the bound, which is the safe direction — this must never
         * fire on a healthy machine. */
        size_t n_fp = nfp_this_window();
        if (n_ip > delta + n_fp)
            add_finding("bootlog-fabricated-boots",
                        "%zu in-progress line(s) added but the host started only %lu boot(s) since the previous observation (host boots %lu -> %lu) — and at most %zu of those can be an activate RE-ARM (a version the store FIRST PUBLISHED in this window, init.zig:3724): fx-init writes at most ONE in-progress per boot the host starts (init.zig:4886) plus one per activate re-arm; the surplus was appended by something that is not fx-init booting",
                        n_ip, delta, g_obs_boots, g_boots, n_fp);
        if (n_sd > delta)
            add_finding("bootlog-fabricated-boots",
                        "%zu shutdown line(s) added but the host started only %lu boot(s) since the previous observation (host boots %lu -> %lu) — at most one shutdown per boot (init.zig:4396)",
                        n_sd, delta, g_obs_boots, g_boots);
        /* the PER-VERSION verdict budget (the header's rule 2): the writer
         * verdicts a version once per boot that wrote an in-progress for it
         * (the g_boot_decided latch) and at most once more EVER — the boot
         * that ACTIVATED the version in-guest (the re-armed grace window;
         * a publish allocates the version number exactly once).  That ONE
         * extra slot is granted ONLY to a first-published version that
         * carries NO re-arm in-progress of its own: when the writer put the
         * re-arm ip on disk (init.zig:3724) the version's verdict rides THAT
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
                add_finding("bootlog-fabricated-boots",
                            "version %lu carries %zu ADDED verdict line(s) this window but at most %zu can be behind them (%zu in-progress line(s) for v%lu%s) — the writer verdicts a version once per boot that wrote an in-progress for it (the g_boot_decided latch, init.zig:2961/2886/2981/4793) and at most once more EVER: the boot that ACTIVATED it in-guest, the re-armed grace window (init.zig:3797-3800; a publish allocates the version number exactly once), and that ONE extra slot is granted only to a version with NO re-arm in-progress of its own (init.zig:3724). A surplus verdict is a boot on paper the host never started",
                            vs->v, vs->vd, allow, vs->ip, vs->v, credit);
            }
        }
        if (n_ip + n_sd + n_verdict == 0 && !g_obs_bl_absent)
            info("boot accounting: no .bootlog lines added this window");
        free(first_ip_v); free(have_first_ip); free(is_rearm_ip);
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
                            "the nonce the host issued for boot %lu (%s) carries %zu shutdown line(s) — at most one per boot (init.zig:4396)",
                            b, tok, nsd[s]);
            if (nvd[s] >= 1 && nip[s] == 0)
                add_finding("bootlog-fabricated-boots",
                            "a verdict rides the nonce the host issued for boot %lu (%s), but NO in-progress line wears that nonce — a boot that started wrote its in-progress FIRST (init.zig:4886, before every verdict site), and the re-arm verdict rides the SAME live boot's nonce (its own ip under the new writer, init.zig:3724), so a verdict whose nonce carries no in-progress is a forge wearing a stolen boot's nonce: the pair appended on top of a real boot's own lines",
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

    if (!skip_bl)
        info("boot accounting: host boots %lu -> %lu (delta %lu); this window added in-progress %zu, verdicts %zu, shutdown %zu — every verdict rides an in-progress the host's count can account for (the in-progress total is bounded by delta %lu + %zu version(s) FIRST PUBLISHED in this window: one activate re-arm per first-published version, each naming a version newer than the one its boot booted and not already booted itself)",
             g_obs_boots, g_boots, delta, n_ip, n_verdict, n_sd, delta, nfp_this_window());
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
    /* the host's nonce ledger is loaded AFTER obs_read (its window is
     * defined by the observation's boot count) and BEFORE the checks */
    load_nonces();

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
    printf("bound: this seat sees REWRITES and TRUNCATIONS of records it previously observed, cross-record INCOHERENCE, and — anchored on --boots and the per-boot nonce ledger (--nonces) — APPENDED .bootlog/.recovery growth the host cannot account for. IN THE NONCE REGIME (the host issues fx.bootnonce= per boot and every window boot is covered) the forged line-PAIR in a silent boot's slack is CLOSED: every ADDED line must wear a nonce the host issued for a boot in this window, the per-nonce IN-PROGRESS budget is the boot's OWN line plus one activate RE-ARM per version the store FIRST PUBLISHED in this window (each naming a version newer than the one its boot booted — init.zig:3724), the re-arm ip budget being ONE per first-published VERSION per WINDOW (a publish allocates a version number exactly once) AND naming a version NOT ALREADY BOOTED in the window (a re-arm names the version the activate JUST published, max+1, which has never been booted — this is what refuses the roll-forward REPUBLISH forge), shutdown / .recovery rows hold at one per boot, and the VERDICT accounting is per VERSION — one verdict per in-progress line the window added for that version, plus ONE more ONLY for a first-published version carrying NO re-arm ip of its own (the OLD-writer re-arm shape, init.zig:3797-3800). THE RE-ARM LINE'S OWN DELTA: that legitimate line RE-OPENS the forged-PAIR shape for a version that is first-published in the window AND newer than the boot's own, on ANY real window boot's nonce (the closure there is per VERSION, not per nonce — ONE re-arm in-progress per first-published version per window, so a forged pair cannot ride a second window nonce to buy a second verdict, whether the version was activated or republished — the republish shape is refused by the not-already-booted clause — and the legitimate line grants no verdict slot the +1 did not already grant). RESIDUAL, named: a forged pair for a version first published WITHOUT an activation and NOT YET BOOTED in the window (the operator `rollback` during a live boot, before the next boot boots it) still reads as a legitimate re-arm and lands the version's FIRST verdict — indistinguishable from a real activation without the .operator journal this seat does not read; the automatic roll-forward has no such window (the republish and the boot are one PID1 start), and the moment the version IS booted the not-already-booted clause refuses the same forge. What a forger still cannot mint is an in-progress for a version the store did not publish in this window, or one NOT newer than that nonce's own first line (the per-nonce rule fires on both) — and an unclaimed nonce is REPORTED as a silent boot. What this seat CANNOT see, stated as its bound: a verdict SUBSTITUTED inside a LIVE boot — the agent is root in the guest and can read its own /proc/cmdline nonce, so it can append the verdict itself in the writer's exact shape wearing the live nonce and suppress fx-init's own (a panic before grace expiry); that leaves ONE verdict for one (nonce, version) with every anchor satisfied, and the line's authorship inside the boot that owns the nonce is NOT distinguishable from the host — auditing, not proofing (the defence against substitution is the rollback machinery plus the observation hashes, not this reader); window boots the ledger does not cover (a mixed/manual regime — nonce-less lines are named and counted, but a forged pair in an UNCOVERED boot's slack still passes the arithmetic); boots started off the counting host, or a miscounted / moved --obs-file reuse (the count and the ledger are only as true as the host's own bookkeeping); a coherent tamper on a store first seen at enrollment (the enrollment gap — first run trusts, loudly). That is the honest bound of auditing, not proofing (§6b), printed on every run so the tool never implies more than it knows.\n");
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
