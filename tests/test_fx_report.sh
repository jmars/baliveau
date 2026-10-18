#!/bin/sh
# tests/test_fx_report.sh — THE ACCEPTANCE for the REPORTER SEAT
# (tools/fx-report.c; todo.md §1b, design record §1a: observability
# sufficient for a third-party EU AI Act report — "is it documented?").
#
# THE GATE IS THE RECONSTRUCTION THE ACT ACTUALLY ASKS FOR: a store with a
# real lifecycle (two activations with DIFFERENT configs, a soft rollback —
# all written by the REAL writers: activate_paths, fx-activate, fxstore
# itself) must let a reader answer, FROM THE REPORT ALONE, "what changed
# between version N and N+1, and from which input?" — with the INPUT
# READABLE (the config content, both of them, verbatim), the DIFF between
# them, and the generation each produced.  Every arm below says what makes
# it FAIL; an arm that cannot fail is decoration.
#
#   RECON      exit 0; `config <VA> <sha256 cfgA>` — the INPUT IDENTITY
#              CHAIN (file -> retained copy -> generation_config fact ->
#              report) proven end-to-end: the sha in the report equals the
#              sha of the config file the gate WROTE.  FAIL: any link
#              silent.  `config-line` records carry each config's own
#              hostname line (the CONTENT readable, not a hash).  `config-
#              diff` carries a '-' line with repbox-a and a '+' line with
#              repbox-b (the adjacent pair (VB-1, VB) — MEASURED: every
#              fx-activate after the first leaves a benign publish-of-live
#              duplicate immediately before the new version), with the
#              exact counts 2/2.  `event activation ... version VB ...
#              genhash <ghB>` — the generation each produced, cross-checked
#              against `fxstore facts generation --as-of VB`.
#   CHAIN       every timeline version has a `version` record, ascending;
#              `current` == the CURRENT file.  FAIL: a version missing or
#              mis-ordered.
#   BOOTLOG     the writer's line shapes surface as events: ok, failed,
#              in-progress (boot-start), shutdown — with nonce and epoch.
#              FAIL: any verdict missing.
#   AUTO        S1 (a .recovery row naming the restore) reports `event
#              roll-forward-automatic ... published <VCUR>` and NO operator
#              event — the automatic path is attributed BY ITS RECORD.
#              FAIL: the row ignored, or the restore also called operator.
#   OPERATOR    S2 (no .recovery — the operator shape) DERIVES `event
#              operator-intervention ... shape restore ... version <VCUR>`
#              with the disjunction bound inline, and it is NOT a finding
#              (exit 0): an operator rollback is legitimate, the record's
#              gap is the finding of the SUBSTRATE, printed in the bound.
#              FAIL: the signature missed (the class is decoration) — the
#              MUT-CLASS mutation below must make exactly this arm go
#              blind, and MUT-ATTRIB must make the AUTO control fire.
#              S2 carries NO .operator, so this is ALSO the fallback's own
#              domain: the derived class is what a store predating the
#              journal can say, and nothing else.
#   ABSENT      the none-vs-not-recorded distinction, both directions:
#              S3 (never booted) says `absence .bootlog
#              no-boot-ever-recorded` and emits NO boot event; the rt-log
#              absence says NOT-durably-recorded (tmpfs); the .operator
#              absence says the store predates the journal — and THAT is
#              the one case where the activation-refusal row's OLD
#              absence-meaning (NOT-DURABLY-RECORDED) is still the right
#              answer.  With a journal that class is MEASURED and its
#              absence-meaning is "none in the retained journal" (JOURNAL).
#              FAIL: an absence printed as a zero, or a not-recorded
#              printed as none — in either direction.
#   FOREIGN     a .bootlog line naming a version not in the timeline is
#              reported with the pruned-or-foreign note (the
#              pre-first-snapshot bound, visible in-band).  FAIL: dropped.
#   JOURNAL     the DURABLE operator journal (<store>/.operator, fx-init
#              ca9cb06, written by PID1's control handler) is READ as the
#              record it is: S2J — a copy of S2 carrying the writer's own
#              rows — reports each intervention as `event
#              operator-intervention MEASURED file .operator ...` with
#              action / arg / outcome / from-version / to-version / nonce
#              VERBATIM, and each refusal outcome ALSO as `event
#              activation-refusal MEASURED ...`; the summary counts them.
#              THE INVERSION IS THE PAIR: S2 (no file) reports the DERIVED
#              fallback and says the journal does not exist, while S2J
#              reports the MEASURED rows AND STILL RETAINS the derived
#              signature — annotated `journal-attributes-a-move-to-this-
#              version` — because the journal's own header names paths it
#              cannot see (a host-side `fxstore rollback`, `rollback
#              --hard`, a hand-edited CURRENT).  A row can EXPLAIN a
#              backward move; it can never prove it saw the path that
#              produced one, so it never suppresses the derivation.
#              FAIL: the file ignored (the class reverts to a derivation
#              over nothing), a recorded refusal counted as none, the
#              AMBIGUOUS outcome (`unverified`) or the LANDED one
#              (`dhake-failed`) counted as refusals, or the derived
#              fallback dropped wherever the journal exists.  MUT-OPS and
#              MUT-REFUSE must blind exactly the MEASURED arms.
#   FINDINGS    corrupting the retained copy fires config-sha-mismatch;
#              deleting it fires config-retained-copy-gone; exit 1 and
#              `verdict documented-with-findings`.  FAIL: a broken input
#              reported as documented.  MUT-FINDING must blind this arm.
#   GCKEEP/GREAP the retention table's MEASURED gc claim, re-proven every
#              run, BOTH directions of the carve-out: `fxstore gc` on S3
#              RETAINS every <genhash>-system-generation dir named by a
#              surviving snapshot (asserted on the DISK, plus gc's own
#              LOUD keep log) and the post-gc report is COHERENT (exit 0,
#              no fabricated finding); then `gc --retain 1` on a copy
#              prunes the older snapshot and its generation dir IS reaped
#              (plus the LOUD reap log) — the carve-out is precise, not a
#              blanket keep.  FAIL: a surviving snapshot's dir is deleted
#              (the carve-out regressed — re-measure and update the
#              frozen retention row), a pruned snapshot's dir survives,
#              or the report flags a store whose inputs are all readable.
#              (The copy-gone FINDING itself stays reachable only via a
#              GENUINELY missing copy — the FINDINGS arm's hand-deleted
#              file; MUT-FINDING blinds THAT arm.)
#   REPOINT     `rollback --hard` (CURRENT moves, NO new version) surfaces
#              as `event operator-intervention ... shape current-repoint`,
#              and `current` != newest.  FAIL: the stale-CURRENT signature
#              invisible.
#   SELFREPORT  the report is a function of the SUBSTRATE, never the
#              agent's self-report: an attempts.jsonl ABSENT, DELETED and
#              DOCTORED inside the store directory produce byte-identical
#              output.  FAIL: any dependence.
#   DETERMINISM two runs over the same store are byte-identical (cmp).
#              FAIL: wall-clock, locale or order leaking into records.
#   POLICY      the retention policy is DECIDED (UNBOUNDED, user,
#              2026-10-12), and it PRINTS — so the frozen table and the
#              bound are pinned where they print, on every run: all six
#              retention rows state the decision (the claim-rows row is
#              S2's), the `.bootlog` row names its COST, the bound id is
#              `retention-unbounded-by-decision` printing NOTHING MAY BE
#              DROPPED, and the OLD text ("NO growth policy exists", the
#              id `retention-unpoliced`) is asserted ABSENT; the bound
#              table is COUNTED (12 rows) and S2's amended same-store-only
#              row is asserted ON THE OUTPUT — the pin drops it on BOTH
#              sides, so only this catches its loss or an id change.  FAIL: the
#              table drifts back to the open gap and nobody notices —
#              which only a grep for the old claim's ABSENCE can catch.
#   LOUD        an over-long .bootlog is exit 2 NAMING the cap (a report
#              over a truncated view is a lie); an unreadable .bootlog is
#              exit 2 (a read error is not an absence); a .operator line
#              that is NOT the writer's shape is exit 2 NAMING the shape
#              (a skipped row would silently delete an operator action
#              from the account).  FAIL: exit 0.
#   MUTATIONS   each sed-mutated copy of the seat, with ONE taxonomy piece
#              disabled, must make its own arm's assertion go blind:
#              MUT-CLASS (the DERIVED operator-intervention emission tag)
#              -> the OPERATOR arm fails on the mutant; MUT-ATTRIB (delete
#              the .recovery attribution line) -> the AUTO control fails
#              on the mutant; MUT-FINDING (the copy-gone finding tag) ->
#              the FINDINGS arm fails on the mutant; MUT-OPS (the MEASURED
#              journal emission tag) -> the JOURNAL arm fails on the
#              mutant; MUT-REFUSE (the activation-refusal emission tag) ->
#              the JOURNAL arm's refusal assertion fails on the mutant.  A
#              taxonomy nobody can falsify is decoration.
#   CLAIM (S2)  the judge seat's verdict record SURFACES: a store built by
#              the REAL writers with a claim riding in via extraEtc, then
#              judged by the REAL judge (fx-claim — its observation is a
#              durable record like .bootlog; the fixture honesty is
#              declared in-block), carries `claim-record` / `claim-verdict`
#              records verbatim from <store>.fx-claim-obs (the claim-sha
#              cross-checked against sha256(tsv||le), op-from against the
#              .operator row), with the ABSENCE MEANINGS in BOTH
#              directions: a claimless row inside the observation reads
#              none-occurred MEASURED (direction (i)); the observation's
#              ABSENCE reads not-durably-recorded and fabricates NO
#              verdict (direction (ii)); a POST-enrollment claimless
#              commit (a live generation the observation does not name)
#              is claim-record ... NOT-RECORDED with its disjunction —
#              NEVER none-occurred.  A tampered observation's verdict
#              surfaces verbatim as claim-disagreement (a RECORD, not a
#              reporter finding); an unknown verdict word is surfaced with
#              a note, never classified; a corrupted observation is exit 2
#              naming the grammar.  PIN-REPORT: the PRE-FIX report bytes
#              over the claim-carrying store (tests/fixtures/claims/
#              report-claims-before.txt) cmp'd every run against the
#              post-fix report minus its claim class (the epoch fields of
#              fx-activate's generation facts are masked on BOTH sides —
#              they are the fixture's wall-clock) — proving the pin's
#              DOMAIN (it is this store's report) and that S2 is ADDITIVE:
#              the pre-fix account is preserved byte for byte.  FAIL: the
#              pin drifted, the pin carries claim records (it would be the
#              after, not the before), or any pre-fix line moved.
#              MUT-CLAIM (the claim-verdict emission tag) and MUT-ENROLL
#              (the NOT-RECORDED mark -> literally `claimless`: a
#              post-enrollment claimless commit reported none-occurred,
#              the §1a gap-3 error) blind exactly the CLAIM arms, as does
#              MUT-LOUDLONG (the row-grammar %n exhaustion check) for
#              CLAIM-LOUD-LONG: an over-long FINAL field — the one shape
#              width limits cannot kill — is exit 2 naming the row shape,
#              never a truncated MEASURED row.
#   CALL (P9)   the host proxy's ONE LOG and the guest's TRANSCRIPT are
#              JOINED by call_id, making a denial AUDITABLE: the host gate
#              rewrites a denied call's name to a reserved name and
#              substitutes a denial text, and the guest's transcript records
#              the REWRITTEN name + a generic sentinel and NEVER learns the
#              true verb — so the true name, the verdict, its author and its
#              reason exist together ONLY in the host's log.  The arms drive
#              a REAL proxy run (build/fx-hostgate + build/fx-agent, a fresh
#              FX_AGENT_DATA per probe, the copy of the justified fixture,
#              the dispatch-recording stub, every proxy TIME-BOUNDED) and
#              read the REAL log + the REAL transcript, then assert the
#              TRIPLE VERBATIM (call-record = the justification that rode in
#              with the call; call-verdict = denied + author + refusal-name,
#              and allow-scope VERBATIM on an allowed row — the P8 R5
#              finding, never re-derived; call-outcome = the replayed
#              function_call_output), the DISAGREEMENT (call-disagreement:
#              the true verb vs the guest's fx_host_denied + its sentinel,
#              same call_id, both VERBATIM — and its second shape, the
#              REWRITE MISS where the guest recorded the TRUE name for a call
#              the host DENIED), the join's ABSENCE in BOTH
#              directions EACH as its own call-join FINDING with its own
#              meaning (a join that cannot fire FAILS OPEN IN THE RECORD),
#              the NOT-KNOWN discipline for a side not given, the
#              no-fabricated-verdict rule, an unknown verdict word surfaced
#              VERBATIM (never classified), the ECHO TELEMETRY rows
#              (unjoined-output, echo-anomaly) surfaced as records with NO
#              lane stop (the deliberate G7 demotion), the LOUD refusals
#              (a non-JSON row, an unknown row type), and the reporter's
#              NON-MODIFICATION of the log it reads (byte-identity in/out).
#              INJECTION IS DECLARED: the one-sided join cases, the
#              no-verdict row shape and the telemetry rows are built in
#              COPIES of the real records (the real run joins cleanly, which
#              the first arm asserts).  MUT-CALL-JOIN (the join emission
#              disabled), MUT-CALL-CLASSIFY (an unknown verdict word mapped
#              into the seat's own vocabulary) and MUT-CALL-SCOPE (allow_scope
#              RE-DERIVED instead of carried) each blind exactly the arm that
#              refuses their error.
#   S4-EXEC     WHICH SIDE RAN THE CALL, both ways: a REAL host_time call
#              through the real proxy makes the log row carry exec:"host" and
#              the report distinguishes it MEASURED, while a guest call on
#              the same class reads guest DERIVED from the writer's stated
#              grammar (§7.1a: an egress grant is a capability increase, so a
#              report that cannot tell the two apart is blind to it).
#              MUT-EXEC ignores the carried field and the host call reads
#              guest — the blindness, caught.
#   S4-REACH    the WEAKENED declared-vs-observed audit, its own rows: (a)
#              every pinned artifact MATCHes its PINS and the class rows no
#              observed call exercised are STALE GRANTS (each its own
#              stale-class-row FINDING, stating the weakening in the row
#              itself); (b) the exercised direction reads YES for a consumed
#              row through the MIRRORED canonicalizer while the untouched row
#              still reads STALE — both directions on ONE fixture, the
#              observed side a DECLARED COPY of the real log (stated in
#              block); (c) BOTH directions of absence (no log, no policy dir,
#              a dir with no PINS or tables, no --class-arg) are NOT-KNOWN
#              and NEVER stale, each with its own absence record; (d)
#              pin-drift is its own FINDING carrying BOTH pins and does not
#              smear onto the untouched tables.  MUT-REACH disables the
#              stale-grant row and MUT-PINDRIFT joins on the DRIFTED PIN (the
#              mandated blind: the reach-pin row still READS drift and no
#              finding follows — the quiet widening).
#   PINS        nothing depends on the position of HEAD: the citations in
#              the tool's frozen retention table are pinned to FIXED
#              revisions (fx-init ca9cb06, fxstore 0341650 — the trees the
#              table was measured against), guarded by git cat-file -e and
#              cmp-proven EQUAL to the working tree, so a moved sibling
#              fails the gate LOUDLY instead of leaving the table citing
#              line numbers that no longer exist.
#
# FIXTURE HONESTY: .bootlog/.recovery/.operator are fx-init's files and
# fx-init does not run host-side; the gate writes them in the writers'
# exact formats (bootlog_append's "%u %s %u %s\n" — in-progress at boot
# start plus the verdict per boot; recovery's "#"-header + "<epoch>
# <published> <from-failed> <genhash|-> <nonce>" row; and the operator
# journal's OWN header (copied from OPERATOR_HEADER, operator_journal.zig:122, because
# that header IS the definition) plus operator_line's "<epoch> <action>
# <arg> <outcome> <from-version|-> <to-version|-> <nonce>" rows) and
# DECLARES that here, exactly as tests/test_fx_audit.sh does.  Everything else is written by the real
# writers: fx-activate (host-built, the audit gate's provisioning shape)
# and fxstore itself (the soft rollback fx-init's roll-forward drives
# in-guest).
#
# Env: FX_SIBLINGS (default $HOME/fixpoint-linux unless $REPO/.. holds the
#      stack), FXSTORE_BIN (default $FX_SIBLINGS/fxstore/zig-out/bin/fxstore),
#      FX_INIT_REPO, FX_REPORT_KEEP=1.
set -u

fail() { echo "test_fx_report: FAIL: $*" >&2; exit 1; }
skip() { echo "test_fx_report: SKIP ($*)"; exit 77; }

cd "$(dirname "$0")/.." || fail "cannot cd to repo root"
REPO="$PWD"
# Sibling root: an explicit FX_SIBLINGS wins; else the historical neighbour
# $REPO/.. only if it actually holds the stack (fx-init present); else the
# relocated default $HOME/fixpoint-linux.
SIBS="${FX_SIBLINGS:-$(cd "$REPO/.." && pwd)}"
[ -d "$SIBS/fx-init" ] || [ -n "${FX_SIBLINGS:-}" ] || SIBS="$HOME/fixpoint-linux"

command -v cc >/dev/null 2>&1 || skip "cc not found"
command -v sed >/dev/null 2>&1 || skip "sed not found"

FXSTORE="${FXSTORE_BIN:-$SIBS/fxstore/zig-out/bin/fxstore}"
[ -x "$FXSTORE" ] || skip "fxstore binary missing at $FXSTORE (set FX_SIBLINGS or FXSTORE_BIN, or build the sibling)"
"$FXSTORE" --help 2>&1 | grep -q 'fxstore facts' || skip "fxstore at $FXSTORE predates 'facts' (rebuild the sibling)"
grep -aq generation_config "$FXSTORE" || skip "fxstore at $FXSTORE predates the generation_config schema row (rebuild the sibling)"
grep -aq "keeping generation dir" "$FXSTORE" \
    || skip "fxstore at $FXSTORE predates the gc generation-dir carve-out (rebuild the sibling)"

INIT="${FX_INIT_REPO:-$SIBS/fx-init}"
[ -d "$INIT" ] || skip "fx-init checkout not found at $INIT (set FX_SIBLINGS or FX_INIT_REPO)"
DL="$SIBS/datalog-dafsa/zig-out/lib"
[ -f "$DL/libdatalog.so" ] || skip "libdatalog.so missing at $DL (set FX_SIBLINGS)"

ZB="$REPO/build/guest-payload/init-x86_64-musl/bin"
if [ ! -x "$ZB/activate_paths" ] || [ ! -x "$ZB/fx-activate" ]; then
    command -v zig >/dev/null 2>&1 || skip "$ZB binaries absent and zig not found to build them"
    echo "test_fx_report: building fx-init's binaries (x86_64-linux-musl)"
    ( cd "$INIT/zig" && zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe \
        -p "$REPO/build/guest-payload/init-x86_64-musl" \
        --cache-dir "$REPO/build/guest-payload/zig-init-cache" ) || fail "fx-init zig build failed"
fi
[ -x "$ZB/activate_paths" ] || fail "no $ZB/activate_paths"
[ -x "$ZB/fx-activate" ] || fail "no $ZB/fx-activate"
grep -aq generation_config "$ZB/fx-activate" || {
    skip "staged fx-activate at $ZB predates the config link (fx-init 1399dbd) — the staging froze on an OLD fx-init; rm -rf build/guest-payload/init-x86_64-musl and re-run to rebuild it"
}

# ── the seat itself, and the STALE-BINARY guard: the artifact the gate
#    drives must be the artifact just built from THIS source (a cached
#    binary answering for a property of the system has bitten this repo
#    seven times).  make is idempotent; the -nt assertion catches any
#    cache that survived it; the marker greps (strings that exist only in
#    THIS source) catch a binary that is newer but not ours.
make -s build/fx-report >/dev/null || fail "cannot build build/fx-report"
REPORT="$REPO/build/fx-report"
[ -x "$REPORT" ] || fail "no $REPORT"
[ "$REPORT" -nt "$REPO/tools/fx-report.c" ] || fail "$REPORT is older than tools/fx-report.c — a stale cached binary answered for the seat; rm -rf build and re-run"
grep -aq "a report over a truncated view is a lie" "$REPORT" \
    || fail "STALE BINARY: $REPORT does not contain this source's bootlog-cap refusal message"
grep -aq "republish-live" "$REPORT" \
    || fail "STALE BINARY: $REPORT does not contain this source's publish-of-live classification"
grep -aq "no-operator-journal-this-store-predates-fx-init-ca9cb06" "$REPORT" \
    || fail "STALE BINARY: $REPORT does not contain this source's operator-journal absence record"
grep -aq "not the writer's shape \"<epoch> <action> <arg> <outcome>" "$REPORT" \
    || fail "STALE BINARY: $REPORT does not contain this source's operator-journal shape refusal"
grep -aq "no-observation-row-judge-not-run-since-publish" "$REPORT" \
    || fail "STALE BINARY: $REPORT does not contain this source's claim-coverage (NOT-RECORDED) marker"
grep -aq "claim-evaluator-location" "$REPORT" \
    || fail "STALE BINARY: $REPORT does not contain this source's claim-evaluator-location bound row"
grep -aq "no-verdict-field-no-policy-ran-on-this-call" "$REPORT" \
    || fail "STALE BINARY: $REPORT does not contain this source's call-class no-fabricated-verdict marker"
grep -aq "host-name" "$REPORT" || fail "STALE BINARY: $REPORT does not contain this source's call-disagreement row"
grep -aq "activity-without-progress-cannot-see-intent" "$REPORT" \
    || fail "STALE BINARY: $REPORT does not contain this source's progress-class bound (the content-identity seat)"

TAB="$(printf '\t')"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fxreport.XXXXXX")" || fail mktemp
if [ "${FX_REPORT_KEEP:-0}" = "1" ]; then
    trap 'echo "test_fx_report: scratch kept at $WORK"' EXIT
else
    trap 'rm -rf "$WORK"' EXIT
fi

# ── the PINS: the tool's frozen retention table cites fx-init init.zig and
#    fxstore store.zig/provenance.zig facts measured against FIXED objects
#    (commits for the unchanged siblings; store.zig's carve-out was measured
#    against its working-tree BLOB — the gc retention row — pinned by object
#    name).  Guard the object, then cmp the pinned blob against
#    the working tree: a sibling that moved fails the gate LOUDLY (the
#    table's citations are stale — re-measure) instead of silently
#    citing a file that no longer says what the table claims.
FXS_REPO="$(dirname "$FXSTORE")"
[ -d "$FXS_REPO/.git" ] || FXS_REPO="$SIBS/fxstore"
pin_guard() { # pin_guard REPO REV FILE LABEL
    git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null \
        || fail "PIN: $4 revision $2 not present in $1 — the pin is a fixed object name; update it consciously"
    git -C "$1" show "$2:$3" 2>/dev/null | cmp -s - "$1/$3" \
        || fail "PIN: $1/$3 differs from the pinned $2 this seat's retention table was measured against — the citations in tools/fx-report.c are STALE; re-measure and update the frozen tables"
}
# pin_blob: the same guard for a file measured against an UNCOMMITTED tree —
# the pin is the file's BLOB object name (stable across the later commit:
# the committed tree stores the same blob), not a revision.  The object must
# already be in the odb (git hash-object -w, or the commit that lands it).
pin_blob() { # pin_blob REPO BLOB FILE LABEL
    git -C "$1" cat-file -e "$2" 2>/dev/null \
        || fail "PIN: $4 blob $2 not present in $1's object db — the pin is a fixed object name; hash-object -w the measured file or update the pin consciously"
    git -C "$1" cat-file blob "$2" | cmp -s - "$1/$3" \
        || fail "PIN: $1/$3 differs from the pinned blob $2 this seat's retention table was measured against — the citations in tools/fx-report.c are STALE; re-measure and update the frozen tables"
}
# fx-init RE-MEASURED AGAIN at the RUNTIME-RECORD CLOSURE (fx-activate
# SELF-RECORDS the publish it commits when it is NOT PID1's child: the
# handler's marker in the activate child, the boot-nonce predicate in
# activate.zig's selfRecord, and the ONE journal definition — header,
# grammar, nonce parse — moved OUT of init.zig into operator_journal.zig,
# imported by both writers).  EVERY line citation in tools/fx-report.c was
# re-measured against THIS tree.  The edit DELETED two blocks (the kernel-
# nonce parse, old :719-741; the journal definition, old :961-1073), MOVED
# two test batteries out to the module, and INSERTED the child's marker, so
# the deltas are piecewise — every cite at or after the deleted journal
# block moved by -173 or more, and the ones that survived with the same
# code are content-verified (old line N and new line N' carry IDENTICAL
# text for every remapped cite).  The previous units' pair tables (the
# re-arm-accounting and round-2 refresh) are SUPERSEDED: they named lines
# of trees that no longer exist, and the cites they moved are re-anchored
# above.  The pin is a BLOB object (git hash-object -w zig/src/init.zig),
# the same shape as the fxstore store.zig carve-out pin below, because this
# unit's fx-init change is not committed yet: identical bytes give the same
# blob object, so the pin stays exact once the commit lands (a revision pin
# at ca9cb06 can no longer match — the tree it guarded has moved on).
# ROUND-2 NIT PASS (reviewer's five NITs, same uncommitted tree): init.zig
# changed (ONE REQ_MAX definition, the marker's setenv now CHECKED) with a
# ZERO line delta — the marker comment was reflowed to pay for the guard —
# so every cite above still lands.  The blob moved; the citation map did not.
# SLICE 2 RE-MEASURE (HANDOFF=v86guest, fx-init's DISK PROBE): pick_disk_dev()
# became a probe over [vda1, vda, sda1, sda] (DISK_DEVS added at old :2195) so
# the v86/ATA lane finds /dev/sda.  The addition is +21 lines and lies entirely
# between old :2195 and old :2320, so EVERY cite at or after old :2320 moved
# exactly +21 and every cite before :2195 is untouched — an old->new line map
# built from the two blobs was applied mechanically and each remapped cite was
# verified to carry IDENTICAL text at its new line (so the cites' MEANINGS are
# unchanged, only their numbers).  The cites THIS file's surface uses
# (:1769) are before the insertion: no cite in test_fx_report.sh moved.  The
# cites inside the pinned tools/fx-report.c table DID move and were remapped in
# the same pass (e.g. :3375 -> :3396, :3484 -> :3505, :4675/:4676 -> :4696/:4697)
# — the blob pin below is the mechanism that would have caught a miss.
# SLICE 2 ROUND 2 (reviewer SF2: the false-premise comment at old :2348-2349,
# "the host cannot mkfs/populate the image as uid 1001", refuted by this
# slice's own unprivileged host-side mkfs): a COMMENT-ONLY edit with a ZERO
# line delta — the two-line block is replaced line for line — so no cite here
# or in tools/fx-report.c moved; only the blob pin was re-measured.
# NOBB RE-MEASURE (fx-init 43d3221 "disk: the ATA probe, and then NO busybox",
# committed; working tree == HEAD, blob 201cf9ed, 5354 -> 5609 lines): the
# disk migration is native (run_bb deleted, mkfs a pre-format refusal, lstat
# added to fxstat.zig), so init.zig moved +255 — first divergence at old :755
# (a comment rework inside bootlog_append), a large rework over old
# :2170-:2394, small edits at old :2679/:3205/:3263, and a +95 insert at old
# :4805.  An old->new map from the two blobs was applied mechanically to every
# init.zig:PREFIXED cite AND every bare ":NNNN" continuation ref sharing a
# line with one (fx-report.c's frozen tables carry 25 of the bare kind); each
# remapped cite was verified to carry IDENTICAL text at its new line.  This
# file's one cite moved off the SLICE 2 paragraph's "did not move" claim:
# :1769 -> :1770.  tools/fx-report.c's cites moved with it (e.g. :3396 ->
# :3556, :3505 -> :3665, :4696/:4697 -> :4856/:4857).  The SLICE 2 paragraph's
# present-tense "no cite in test_fx_report.sh moved" is thereby superseded —
# recorded here, the paragraph above kept as history.
# TWO MORE FINDINGS in fx-report.c's refusal-vocabulary comment, same class
# as the fx-audit.c ones (citations WRONG at the pinned tree, not shifted —
# this pass content-checked EVERY bare ":NNNN" continuation ref, per line,
# having found that a cross-line de-dup in the first inventory scan had
# hidden four of them): (3) "refused is the rollback arm's when the STORE
# rejected the target (:3677)" — old :3677 is the ACTIVATE arm's loss-window
# comment, the wrong arm; the true refused append was :3698, corrected to
# :3858.  (4) "`dhake-failed` (the live-root reapply failed, :3635)" — old
# :3635 is the activate arm's re-arm comment; the reapply-failure surface is
# :3654-:3656, corrected to :3816 (the dhake-failed append, which the
# taxonomy's ctrl-arms list at :890 already named as :3656->:3816).  ONE
# further ref was APPROXIMATE at the pinned tree and is mechanically
# preserved, not blessed: "the rollback arm's :3856" points at that branch's
# rationale comment, 21 lines above the refused-config append (:3877) —
# same text it always pointed at, flagged here rather than re-aimed by
# guesswork.
pin_blob "$INIT" 201cf9ed6a5303e52e69dc9d40d5f7cf24d558c5 zig/src/init.zig "fx-init"
# fxstore re-measured at e97758c (the install-origin unit): the FACTS SURFACE
# this seat reads is unchanged — RELATION_SCHEMAS still defines every name in
# fx-report.c's FACT_RELS, and the gc carve-out's claim (store.zig) is a
# comment-only difference. This pin guards the facts surface, not a line
# citation (fx-report.c cites init.zig by line and store.zig's carve-out; it
# names provenance.zig nowhere).
pin_guard "$FXS_REPO" e97758c zig/src/provenance.zig "fxstore"
pin_blob "$FXS_REPO" 334570c2719d3e5294c1088e33407721c0ae3acf zig/src/store.zig "fxstore"

# ── the fixture store (toolchain-free provisioning, the audit gate's shape)
SRC="$WORK/src"
mkdir -p "$SRC/tool" || fail mkdir
echo "/* shared tool tree */" > "$SRC/tool/tool.c"

PSN=0
ps_pkg() {
    if [ "$PSN" -eq 0 ]; then echo "  { name = \"$1\", version = \"0\""
    else echo "  , { name = \"$1\", version = \"0\""; fi
    PSN=$((PSN + 1))
    cat <<EOF
    , src = < Path = "$2" >
    , deps = [] : List Text
    , excludes = [] : List Text
    , build = { target = "bin", recipe = [] : List Action } }
EOF
}

# cfg_write OUT HOSTNAME GRACE — the two configs differ in EXACTLY two
# lines (hostname, bootGraceMs), so the diff counts are pinned (2/2).
cfg_write() {
    cat > "$1" <<EOF
let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }),
                console : Optional Text }
let User = { name : Text, uid : Natural, groups : List Text }
in  { hostname = "$2"
    , packages = [] : List Text
    , users = [ { name = "root", uid = 0, groups = [] : List Text } ] : List User
    , services = [] : List Service
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some $3
    , agentService = None Text
    }
EOF
}

mkdir -p "$WORK/store" || fail mkdir
{
    cat <<'EOF'
let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text
             | Rm : Text | Touch : Text | Move : { from : Text, to : Text }
             | Symlink : { from : Text, to : Text } | Chmod : { path : Text, mode : Text }
             | Echo : Text | Env : { key : Text, value : Text } | Run : { argv : List Text } >
let Src = < Path : Text | Fetch : { url : Text, hash : Text } >
let Package = { name : Text, version : Text, src : Src, deps : List Text,
                excludes : List Text, build : { target : Text, recipe : List Action } }
in  { packages = [
EOF
    ps_pkg dhake        "$SRC/tool"
    ps_pkg fx-init      "$SRC/tool"
    ps_pkg fxctl        "$SRC/tool"
    ps_pkg fx-activate  "$SRC/tool"
    echo "  ] }"
} > "$WORK/pkgset.dhall"
PS="$WORK/pkgset.dhall"

P=$(LD_LIBRARY_PATH="$DL" "$ZB/activate_paths" --store "$WORK/store" --package-set "$PS" \
    dhake fx-init fxctl fx-activate) || fail "activate_paths failed: $P"
for _pd in $P; do mkdir -p "$WORK/store/$_pd" || fail "cannot create $_pd"; done

cfg_write "$WORK/cfgA.dhall" repbox-a 30000
cfg_write "$WORK/cfgB.dhall" repbox-b 45000

act() { # act CFGFILE -> the version fx-activate published
    _o=$(LD_LIBRARY_PATH="$DL" "$ZB/fx-activate" --store "$WORK/store" --package-set "$PS" \
        --config "$1" 2>&1) || fail "fx-activate failed: $_o"
    _v=$(echo "$_o" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
    [ -n "$_v" ] || fail "no version from fx-activate: $_o"
    echo "$_v"
}

VA=$(act "$WORK/cfgA.dhall")
VB=$(act "$WORK/cfgB.dhall")
[ "$VB" -gt "$VA" ] || fail "expected VB ($VB) > VA ($VA)"

# the operator-shaped move: fxstore's SOFT rollback (the same call fx-init's
# automatic roll-forward drives in-guest, init.zig:1770) republishes VA's
# content as a NEW version — the ONLY durable difference between the
# automatic and the operator path is the .recovery row, and the gate arms
# exactly that split below.
"$FXSTORE" rollback "$VA" --store "$WORK/store" >/dev/null 2>&1 \
    || fail "fxstore rollback $VA failed"
VCUR=$(cat "$WORK/store/.db/snapshots/CURRENT")
VDUPE=$((VB - 1))   # the benign publish-of-live duplicate before VB (MEASURED)

gh() { "$FXSTORE" facts generation --as-of "$2" --store "$1" | head -1 | cut -f1; }
GHA=$(gh "$WORK/store" "$VA")
GHB=$(gh "$WORK/store" "$VB")
GHC=$(gh "$WORK/store" "$VCUR")
[ -n "$GHA" ] && [ -n "$GHB" ] && [ -n "$GHC" ] || fail "no generation facts as-of $VA/$VB/$VCUR"
[ "$GHC" = "$GHA" ] || fail "rollback did not restore VA's content (gh $GHC != $GHA)"
[ "$GHA" != "$GHB" ] || fail "fixture configs produced the SAME generation — the diff arm cannot work"

# .bootlog in the WRITER's exact 4-field shape, each boot its real line pair
# (in-progress at boot start, init.zig bootlog_append; then the verdict).
write_bootlog() { # write_bootlog STORE
    cat > "$1/.bootlog" <<EOF
$VA in-progress 100 gateboot01
$VA ok 101 gateboot01
$VB in-progress 200 gateboot02
$VB failed 201 gateboot02
$VCUR in-progress 300 gateboot03
$VCUR ok 301 gateboot03
$VCUR shutdown 302 gateboot03
EOF
}

# the three report domains from ONE lifecycle: S3 (never booted — copied
# BEFORE any record is written), then the records land for S1/S2; S1 (the
# automatic path recorded), S2 (the operator shape — no .recovery at all,
# which is what a store that never rolled forward looks like).
cp -a "$WORK/store" "$WORK/s3" || fail "cp s3"
write_bootlog "$WORK/store"
cp -a "$WORK/store" "$WORK/s1" || fail "cp s1"
cp -a "$WORK/store" "$WORK/s2" || fail "cp s2"

# S1's .recovery: the writer's verbatim header + ONE row attributing the
# restore to the AUTOMATIC roll-forward (the boot that failed $VB).
cat > "$WORK/s1/.recovery" <<EOF
# fx-init recovery journal. One DATA line per AUTOMATIC roll-forward:
# fx-init republished an older ok generation because the current
# version's last .bootlog verdict was failed/in-progress. The count
# of recoveries is the number of lines starting with a digit.
301 $VCUR $VB $GHA gateboot03
EOF

report() { # report STORE OUTFILE -> exit code
    FXSTORE_BIN="$FXSTORE" "$REPORT" --store "$1" > "$2" 2>"$2.err"
}

# the mutant builder lives HERE, beside report(), because the PROGRESS class's
# arms (which come before the MUTATIONS section) need it: a function defined
# after its first use is a gate that silently runs nothing, the same class of
# defect as a Makefile ':=' after its prerequisites.
mutbuild() { # mutbuild NAME SED-EXPR -> builds build/fx-report-<name>
    cp "$REPO/tools/fx-report.c" "$WORK/mut-$1.c"
    sed "$2" "$WORK/mut-$1.c" > "$WORK/mut-$1.c.new" && mv "$WORK/mut-$1.c.new" "$WORK/mut-$1.c"
    cc -std=c11 -O2 -g -Wall -Wextra -Isrc/vendor/dhall-c -Isrc/vendor/yyjson -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
        -o "$REPO/build/fx-report-$1" "$WORK/mut-$1.c" src/vendor/dhall-c/sha256.c src/vendor/yyjson/yyjson.c \
        || fail "MUTATION $1: the mutated source does not build"
}

# ══ RECON: the acceptance the Act asks for ══════════════════════════════
report "$WORK/s1" "$WORK/out-s1"
[ $? -eq 0 ] || fail "RECON: expected exit 0 on the attributed store, got $? ($(head -3 "$WORK/out-s1.err"))"
grep -q "^verdict${TAB}documented$" "$WORK/out-s1" || fail "RECON: no clean verdict on the attributed store"
grep -q "^current${TAB}$VCUR${TAB}MEASURED" "$WORK/out-s1" || fail "CHAIN: current record missing/wrong"
NVER=$(grep -c "^version${TAB}" "$WORK/out-s1")
NTL=$("$FXSTORE" timeline --store "$WORK/s1" | sed -n 's/.*(\([0-9][0-9]*\) version(s)).*/\1/p')
[ "$NVER" = "$NTL" ] || fail "CHAIN: $NVER version records for $NTL timeline versions"
SHA_A=$(sha256sum "$WORK/cfgA.dhall" | cut -d' ' -f1)
SHA_B=$(sha256sum "$WORK/cfgB.dhall" | cut -d' ' -f1)
grep -q "^config${TAB}$VA${TAB}$SHA_A${TAB}.*${TAB}retained" "$WORK/out-s1" \
    || fail "RECON: the INPUT IDENTITY CHAIN broke — the report's config sha for v$VA is not the sha of the config file the gate wrote (expected $SHA_A)"
grep -q "^config${TAB}$VB${TAB}$SHA_B${TAB}.*${TAB}retained" "$WORK/out-s1" \
    || fail "RECON: config sha for v$VB is not cfgB's sha (expected $SHA_B)"
grep -q "^config-line${TAB}$VA${TAB}[0-9]*${TAB}.*hostname = \"repbox-a\"" "$WORK/out-s1" \
    || fail "RECON: config A's hostname line is not READABLE in the report (the content, not just the hash)"
grep -q "^config-line${TAB}$VB${TAB}[0-9]*${TAB}.*hostname = \"repbox-b\"" "$WORK/out-s1" \
    || fail "RECON: config B's hostname line is not READABLE in the report"
grep -q "^config-diff${TAB}${VDUPE}${TAB}${VB}${TAB}-${TAB}[0-9]*${TAB}.*repbox-a" "$WORK/out-s1" \
    || fail "RECON: no '-' diff line carrying config A's hostname (v$VDUPE -> v$VB)"
grep -q "^config-diff${TAB}${VDUPE}${TAB}${VB}${TAB}+${TAB}[0-9]*${TAB}.*repbox-b" "$WORK/out-s1" \
    || fail "RECON: no '+' diff line carrying config B's hostname (v$VDUPE -> v$VB)"
grep -q "^config-diff-summary${TAB}${VDUPE}${TAB}${VB}${TAB}2${TAB}2$" "$WORK/out-s1" \
    || fail "RECON: diff counts for (v$VDUPE,v$VB) are not the pinned 2/2 — the configs differ in exactly two lines"
grep -q "^event${TAB}activation${TAB}MEASURED${TAB}version${TAB}$VB${TAB}genhash${TAB}$GHB" "$WORK/out-s1" \
    || fail "RECON: no activation event for v$VB carrying the store's own genhash for it"
grep -q "^event${TAB}activation${TAB}MEASURED${TAB}version${TAB}$VDUPE${TAB}genhash${TAB}$GHA.*kind${TAB}republish-live" "$WORK/out-s1" \
    || fail "RECON: v$VDUPE (the benign publish-of-live duplicate) is not classified republish-live — MEASURED shape of every fx-activate after the first"
grep -q "^event${TAB}activation${TAB}MEASURED${TAB}version${TAB}$VCUR${TAB}genhash${TAB}$GHC.*kind${TAB}restore" "$WORK/out-s1" \
    || fail "RECON: v$VCUR (the rollback's restored content) is not classified restore"

# BOOTLOG events
grep -q "^event${TAB}boot-verdict${TAB}MEASURED${TAB}version${TAB}$VA${TAB}status${TAB}ok${TAB}epoch${TAB}101${TAB}nonce${TAB}gateboot01" "$WORK/out-s1" \
    || fail "BOOTLOG: v$VA's ok verdict missing"
grep -q "^event${TAB}boot-verdict${TAB}MEASURED${TAB}version${TAB}$VB${TAB}status${TAB}failed" "$WORK/out-s1" \
    || fail "BOOTLOG: v$VB's failed verdict missing"
grep -q "^event${TAB}boot-verdict${TAB}MEASURED${TAB}version${TAB}$VA${TAB}status${TAB}in-progress" "$WORK/out-s1" \
    || fail "BOOTLOG: the boot-start (in-progress) event missing"
grep -q "^event${TAB}boot-verdict${TAB}MEASURED${TAB}version${TAB}$VCUR${TAB}status${TAB}shutdown" "$WORK/out-s1" \
    || fail "BOOTLOG: the shutdown event missing"

# AUTO: the .recovery row attributes the restore — NOT an operator event
grep -q "^event${TAB}roll-forward-automatic${TAB}MEASURED${TAB}epoch${TAB}301${TAB}published${TAB}$VCUR${TAB}from-failed${TAB}$VB${TAB}genhash${TAB}$GHA" "$WORK/out-s1" \
    || fail "AUTO: no roll-forward-automatic event from the .recovery row"
grep -q "^event${TAB}operator-intervention" "$WORK/out-s1" \
    && fail "AUTO CONTROL: an operator event fired on the .recovery-ATTRIBUTED store — the row was ignored"

# SELFREPORT: the report is a function of the SUBSTRATE, never the agent's
# self-report — the same store directory with attempts.jsonl ABSENT, then
# PRESENT, then DOCTORED must produce byte-identical output (the report
# record carries the store's own path, so the comparison must be same-dir).
cp -a "$WORK/s1" "$WORK/sr" || fail cp
report "$WORK/sr" "$WORK/out-sr0"
echo '{"attempt":"tampered"}' > "$WORK/sr/attempts.jsonl"
report "$WORK/sr" "$WORK/out-sr1"
{ echo '{"attempt":"tampered"}'; echo '{"verdict":"ok","boot":999}'; } > "$WORK/sr/attempts.jsonl"
report "$WORK/sr" "$WORK/out-sr2"
rm -f "$WORK/sr/attempts.jsonl"
report "$WORK/sr" "$WORK/out-sr3"
cmp -s "$WORK/out-sr0" "$WORK/out-sr1" || fail "SELFREPORT: output changed with an attempts.jsonl present"
cmp -s "$WORK/out-sr0" "$WORK/out-sr2" || fail "SELFREPORT: output changed with a DOCTORED attempts.jsonl present"
cmp -s "$WORK/out-sr0" "$WORK/out-sr3" || fail "SELFREPORT: output changed after the self-report was deleted"

# DETERMINISM: byte-identical rerun
report "$WORK/s1" "$WORK/out-s1b"
cmp -s "$WORK/out-s1" "$WORK/out-s1b" || fail "DETERMINISM: two runs over the same store differ"

# ══ PROGRESS: MEASURE ACTIVITY WITHOUT PROGRESS (§1's last owed seat) ═══
# ACTIVITY is counted by CONTENT IDENTITY (the store's own genhash — the same
# key fx-init's guard_stats_for uses), never by the version number: the number
# is inflated by the publish protocol's own pair (one duplicate of the live
# generation per fx-activate run after the first — v$VA/v$VDUPE and
# v$VB/v$((VCUR-1)) here) which is NOT activity.  PROGRESS is the FIRST
# SIGHTING of an identity, so a repeat is zero progress by definition.
#
# THE SILENT FAILURE IS 'REPORTS PROGRESS WHERE THERE IS NONE' and
# MUT-IDENTITY below reproduces it from THIS source (keying on the version
# number instead of the genhash).  The LOUD direction — 'a repeat where the
# system progressed' — is pinned by the PRE-EXISTING exit-0/`verdict
# documented` expectation above, which this slice must not move: on this very
# store the seat reports repeats and raises NOTHING.
#
# ASYMMETRY (why the arms can fail): at the pinned pre-fix revision there is
# no `progress-*` row at all, so every assertion below fails against a
# pre-change binary — and the mutants prove the properties are load-bearing
# from the SAME source, not from a hand-written expectation.
act_in() { # act_in STORE CFGFILE -> the version fx-activate published
    _o=$(LD_LIBRARY_PATH="$DL" "$ZB/fx-activate" --store "$1" --package-set "$PS" \
        --config "$2" 2>&1) || fail "fx-activate (act_in) failed: $_o"
    _v=$(echo "$_o" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
    [ -n "$_v" ] || fail "act_in: no version from fx-activate: $_o"
    echo "$_v"
}

# ── F2/F1 on the PRE-EXISTING chain: two content identities, one repeat, and
# NO finding.  The repeat is the ROLLBACK's own restore of cfgA's content at
# v$VCUR — a version number advanced and the content went back to an identity
# it already had, which is exactly 'activity without progress'.
grep -q "^progress-content${TAB}$GHA${TAB}versions${TAB}[0-9]*${TAB}.*first-version${TAB}$VA${TAB}last-version${TAB}$VCUR${TAB}live${TAB}yes${TAB}classification${TAB}repeat-of-${VA}${TAB}MEASURED" "$WORK/out-s1" \
    || fail "PROGRESS(F2): the restored identity is not a repeat-of-$VA on the LIVE row: $(grep -m1 "^progress-content.*$GHA" "$WORK/out-s1")"
grep -q "^progress-content${TAB}$GHB${TAB}versions${TAB}[0-9]*${TAB}runs${TAB}1${TAB}failed${TAB}1${TAB}.*first-version${TAB}$VB${TAB}.*classification${TAB}benign-publish-pair${TAB}MEASURED" "$WORK/out-s1" \
    || fail "PROGRESS(F1): the publish-protocol pair is not its OWN classification (it must never read as a repeat-of): $(grep -m1 "^progress-content.*$GHB" "$WORK/out-s1")"
grep -q "^progress-content${TAB}-.versions" "$WORK/out-s1" \
    || fail "PROGRESS: the versions with NO generation facts are not printed as the NOT-KNOWN identity"
grep -q "^progress-content${TAB}-.*classification${TAB}not-known${TAB}MEASURED" "$WORK/out-s1" \
    || fail "PROGRESS: the NOT-KNOWN identity is not classified as such (it must be its own row, counted in NEITHER activity nor progress)"
grep -q "^# ACTIVITY = 3 content-advancing publish(es) = 2 first-sighting(s) + 1 repeat(s)" "$WORK/out-s1" \
    || fail "PROGRESS(F1): the summary does not say activity 3 = 2 first sighting(s) + 1 repeat: $(grep -m1 '^# ACTIVITY = ' "$WORK/out-s1")"
grep -q "^# PROGRESS (a FIRST SIGHTING of a content identity) — 2 distinct identities, 2 first-sighting(s), 1 repeat(s)" "$WORK/out-s1" \
    || fail "PROGRESS: the summary does not report the 2 distinct identities / 1 repeat"
grep -q "progress/activity = 2/3" "$WORK/out-s1" \
    || fail "PROGRESS: the ratio is not printed with its convention (progress/activity = 2/3)"
grep -q "^progress-finding" "$WORK/out-s1" \
    && fail "PROGRESS(F1): a finding fired on a store whose repeated identity failed ONCE — the arm cannot tell a repeat from a loop"
# the limits print where a reader MEETS the number, not only in the record
grep -q "^# ACTIVITY blind to WHAT the content does:.*INTENDED" "$WORK/out-s1" \
    || fail "PROGRESS: the ACTIVITY block must say it cannot know INTENT and that a long useful task looks FLAT"
grep -q "^# PROGRESS cannot see the OTHER loop shape:.*identities-never-ok [0-9]* .*longest-failed-streak [0-9]*" "$WORK/out-s1" \
    || fail "PROGRESS: the axis-2 numbers (identities-never-ok, longest-failed-streak) are not printed as NUMBERS"
echo "test_fx_report: PROGRESS(F1/F2) activity is counted by content identity (2 first sightings + 1 repeat on a chain of 3 content-advancing publishes), the publish pair is its own classification, and a repeat raises NO finding"

# ── ABSENT-LOG DIRECTION (the third silent shape): a store with NO .bootlog
# has no verdicts at all, so `failed` reads 0 because NOTHING WAS JUDGED.  The
# summary must say NOT-KNOWN, never present a zero.
report "$WORK/s3" "$WORK/out-progress-nolog"
[ $? -eq 0 ] || fail "PROGRESS(nolog): a never-booted store must report cleanly, got $?"
grep -q "^# PROGRESS verdicts: NOT-KNOWN" "$WORK/out-progress-nolog" \
    || fail "PROGRESS(nolog): an absent .bootlog must print verdicts NOT-KNOWN — an absent log must never become a zero"
grep -q "^progress-content${TAB}$GHB${TAB}versions${TAB}[0-9]*${TAB}runs${TAB}1${TAB}failed${TAB}0${TAB}in-progress${TAB}0${TAB}ok${TAB}0${TAB}not-judged" "$WORK/out-progress-nolog" \
    || fail "PROGRESS(nolog): with no log every verdict is NOT-JUDGED (failed 0 for the right reason: nothing was judged)"
echo "test_fx_report: PROGRESS(nolog) an absent .bootlog reads verdicts NOT-KNOWN with the not-judged count, never a bare zero"

# ── F1 (SAID, NOT ESCALATED): the SAME config re-activated after the
# rollback publishes a new version number whose content identity is one the
# chain already had.  The seat must SAY it (repeat-of, activity < versions) and
# must NOT escalate: exit 0, no finding.
cp -a "$WORK/s1" "$WORK/p1" || fail "PROGRESS(F1) SETUP: cp"
VREP=$(act_in "$WORK/p1" "$WORK/cfgB.dhall")
[ "$VREP" -gt "$VCUR" ] || fail "PROGRESS(F1) SETUP: the re-activation published v$VREP, not above v$VCUR"
report "$WORK/p1" "$WORK/out-p1"
[ $? -eq 0 ] || fail "PROGRESS(F1): a REPEAT is not a finding — expected exit 0, got $? ($(grep -m1 '^progress-finding' "$WORK/out-p1"))"
grep -q "^progress-content${TAB}$GHB${TAB}versions${TAB}3${TAB}runs${TAB}2${TAB}failed${TAB}1${TAB}.*first-version${TAB}$VB${TAB}last-version${TAB}$VREP${TAB}live${TAB}yes${TAB}classification${TAB}repeat-of-${VB}${TAB}MEASURED" "$WORK/out-p1" \
    || fail "PROGRESS(F1): the re-activated identity is not 3 versions / 2 runs / repeat-of-$VB with one failure: $(grep -m1 "^progress-content.*$GHB" "$WORK/out-p1")"
grep -q "^# ACTIVITY = 4 content-advancing publish(es) = 2 first-sighting(s) + 2 repeat(s)" "$WORK/out-p1" \
    || fail "PROGRESS(F1): the summary does not say the second re-activation added activity and NO progress: $(grep -m1 '^# ACTIVITY = ' "$WORK/out-p1")"
grep -q "progress/activity = 2/4" "$WORK/out-p1" \
    || fail "PROGRESS(F1): the ratio did not move to 2/4"
grep -q "^progress-finding" "$WORK/out-p1" \
    && fail "PROGRESS(F1): the finding fired on a SINGLE failure — the loud direction (it must not cry loop on one failed verdict)"
echo "test_fx_report: PROGRESS(F1) a re-activated identity is SAID (repeat-of-$VB, 3 versions / 2 runs, ratio 2/4) and NOT escalated (exit 0)"

# ── F3: THE LOOP, on the same recorded state — the SAME identity judged failed
# a SECOND time.  Now the count reaches fx-init's RECOVERY_CONTENT_FAIL_MAX and
# the row is a FINDING, naming the threshold's LOCATION and the bound inline.
cp -a "$WORK/p1" "$WORK/p3" || fail "PROGRESS(F3) SETUP: cp"
printf '%s in-progress 400 gateboot04\n%s failed 401 gateboot04\n' "$VREP" "$VREP" >> "$WORK/p3/.bootlog"
report "$WORK/p3" "$WORK/out-p3"
[ $? -eq 1 ] || fail "PROGRESS(F3): a second failure of the SAME content is a FINDING — expected exit 1, got $?"
grep -q "^progress-finding${TAB}activity-without-progress-recurrence${TAB}genhash${TAB}$GHB${TAB}versions${TAB}3${TAB}failed${TAB}2${TAB}first-version${TAB}$VB${TAB}last-version${TAB}$VREP${TAB}live${TAB}yes" "$WORK/out-p3" \
    || fail "PROGRESS(F3): no recurrence finding for $GHB at 2 failed verdicts: $(grep -m1 '^progress-finding' "$WORK/out-p3")"
grep -q "^progress-finding.*RECOVERY_CONTENT_FAIL_MAX=2" "$WORK/out-p3" \
    || fail "PROGRESS(F3): the threshold is not cited BY NAME"
grep -q "^progress-finding.*zig/src/init.zig:1050" "$WORK/out-p3" \
    || fail "PROGRESS(F3): the threshold is not cited BY LOCATION (fx-init zig/src/init.zig:1050)"
grep -q "^progress-finding.*bound${TAB}activity-without-progress-cannot-see-intent" "$WORK/out-p3" \
    || fail "PROGRESS(F3): the finding row does not carry its bound INLINE"
grep -q "^progress-finding.*cannot know INTENT" "$WORK/out-p3" \
    || fail "PROGRESS(F3): the finding row does not state that it cannot know intent, where a reader meets the number"
grep -q "^progress-finding.*THE SAME FAULT RETURNING, not proof of a live loop" "$WORK/out-p3" \
    || fail "PROGRESS(F3): the row must not call a recurrence in the record a live loop"
grep -q "^progress-content${TAB}$GHA${TAB}" "$WORK/out-p3" \
    || fail "PROGRESS(F3): the finding suppressed the READING (the other identity's row is gone)"
echo "test_fx_report: PROGRESS(F3) the same content failed twice is a FINDING naming RECOVERY_CONTENT_FAIL_MAX (zig/src/init.zig:1050) and its bound inline"

# ── AXIS 2: THE LOOP THE RECURRENCE FINDING CANNOT SEE — always-NEW content,
# always failing.  Two more configs, each activated once and judged failed, so
# EVERY identity fails exactly once: the recurrence count never reaches 2, the
# seat reports FULL progress over a wall of failures, and the shape is printed
# as two NUMBERS that are deliberately NOT a finding (a normal debugging
# session looks identical, so a threshold here would fire on every honest
# afternoon).  This is the honest half of §1's requirement and it is an arm,
# not a comment: the numbers must COUNT, and nothing may escalate on them.
cp -a "$WORK/s1" "$WORK/p2" || fail "PROGRESS(axis2) SETUP: cp"
cfg_write "$WORK/cfgC.dhall" repbox-c 60000
cfg_write "$WORK/cfgD.dhall" repbox-d 75000
VPC=$(act_in "$WORK/p2" "$WORK/cfgC.dhall")
VPD=$(act_in "$WORK/p2" "$WORK/cfgD.dhall")
GHC2=$(gh "$WORK/p2" "$VPC")
GHD2=$(gh "$WORK/p2" "$VPD")
[ "$GHC2" != "$GHA" ] && [ "$GHD2" != "$GHB" ] && [ "$GHC2" != "$GHD2" ] \
    || fail "PROGRESS(axis2) SETUP: the two new configs did not produce two NEW identities"
printf '%s in-progress 500 gateboot05\n%s failed 501 gateboot05\n' "$VPC" "$VPC" >> "$WORK/p2/.bootlog"
printf '%s in-progress 600 gateboot06\n%s failed 601 gateboot06\n' "$VPD" "$VPD" >> "$WORK/p2/.bootlog"
report "$WORK/p2" "$WORK/out-p2"
[ $? -eq 0 ] || fail "PROGRESS(axis2): an always-new-content loop must raise NO finding (the numbers are the record) — got exit $? ($(grep -m1 '^progress-finding' "$WORK/out-p2"))"
grep -q "^progress-finding" "$WORK/out-p2" \
    && fail "PROGRESS(axis2): the recurrence finding fired on identities that each failed ONCE"
# 2, and the number is exactly the point: cfgB's identity (failed once) and
# cfgC's (failed once) have NO ok verdict among their non-CURRENT versions,
# while the CURRENT one (cfgD's) is EXCLUDED — a verdict arrives one boot
# LATER than the state it judges, so counting it would fire on every healthy
# store.  MEASURED on this fixture, not assumed.
grep -q "identities-never-ok 2 " "$WORK/out-p2" \
    || fail "PROGRESS(axis2): identities-never-ok did not count the two identities with no ok verdict among their non-CURRENT versions (CURRENT excluded): $(grep -m1 '^# PROGRESS cannot' "$WORK/out-p2" | cut -c1-80)"
grep -q "longest-failed-streak 2 " "$WORK/out-p2" \
    || fail "PROGRESS(axis2): longest-failed-streak did not count the two consecutive content-advancing publishes judged failed: $(grep -m1 'longest-failed-streak' "$WORK/out-p2")"
grep -q "^# PROGRESS cannot see the OTHER loop shape:.*deliberately NOT a finding" "$WORK/out-p2" \
    || fail "PROGRESS(axis2): the summary does not say those numbers are NOT a finding"
echo "test_fx_report: PROGRESS(axis2) the always-new-content loop prints identities-never-ok 2 (CURRENT excluded) and longest-failed-streak 2 and raises NO finding (progress over a wall of failures, said as numbers)"

# ── MUT-IDENTITY (THE MANDATED BLIND, on exactly F1/F3): the identity map keys
# on the VERSION NUMBER instead of the genhash, so every version is its own
# identity — the repeat reads as a first sighting, the store reports FULL
# progress, and the finding cannot fire.  THIS IS THE NAMED SILENT FAILURE: the
# instrument reports healthy because it cannot see the thing.
mutbuild identity 's/snprintf(I->genhash, sizeof I->genhash, "%s", V->genhash);/snprintf(I->genhash, sizeof I->genhash, "%u", V->v);/'
grep -q 'snprintf(I->genhash, sizeof I->genhash, "%u", V->v);' "$WORK/mut-identity.c" \
    || fail "MUT-IDENTITY: the sed did not land (check the source text)"
FXSTORE_BIN="$FXSTORE" "$REPO/build/fx-report-identity" --store "$WORK/p1" > "$WORK/out-mutidentity" 2>/dev/null
grep -q "^progress-content${TAB}$GHB${TAB}" "$WORK/out-mutidentity" \
    && fail "MUT-IDENTITY: the version-keyed build STILL collapses $GHB into one identity — the arm is not load-bearing"
grep -q "^progress-content" "$WORK/out-mutidentity" \
    || fail "MUT-IDENTITY: the mutant is not a working reporter at all (no rows) — a broken control proves nothing"
# the blindness, stated as the SHAPE it takes: one identity per VERSION, so
# nothing repeats and the numerator equals the denominator
grep -q "^progress-content.*versions${TAB}1${TAB}runs${TAB}1" "$WORK/out-mutidentity" \
    || fail "MUT-IDENTITY: the mutant is not one-identity-per-version (its rows are not the blind shape)"
grep -q "^progress-content.*classification${TAB}repeat-of-" "$WORK/out-mutidentity" \
    && fail "MUT-IDENTITY: the version-keyed build STILL reads a repeat — the arm is not load-bearing"
grep -q " 0 repeat(s)," "$WORK/out-mutidentity" \
    || fail "MUT-IDENTITY: the mutant did not reproduce the blindness (a repeated identity reading as zero repeats)"
MUT_RATIO=$(sed -n 's/.*progress\/activity = \([0-9]*\)\/\([0-9]*\),.*/\1 \2/p' "$WORK/out-mutidentity")
[ "$(printf '%s\n' "$MUT_RATIO" | awk '{ print ($1 == $2) }')" = "1" ] \
    || fail "MUT-IDENTITY: the mutant's ratio is not FULL progress (numerator == denominator), so it is not reading a flat store as healthy: '$MUT_RATIO'"
[ "$(printf '%s\n' "$MUT_RATIO" | awk '{ print $1 }')" -gt 2 ] \
    || fail "MUT-IDENTITY: the mutant claims no more identities than the real build's 2 — the identity map did not change"
FXSTORE_BIN="$FXSTORE" "$REPO/build/fx-report-identity" --store "$WORK/p3" > "$WORK/out-mutidentity3" 2>/dev/null
grep -q "^progress-finding" "$WORK/out-mutidentity3" \
    && fail "MUT-IDENTITY: the version-keyed build STILL raises the recurrence finding — the finding is decoration"
echo "test_fx_report: PROGRESS-MUTANT the version-keyed build reads a flat store as FULL PROGRESS and loses the finding — the named silent failure, caught"

# ── MUT-VERDICT (the half-blind, on F3): the verdict join is deleted, so every
# version reads not-judged.  The READING survives (versions/runs are correct)
# and only the JUDGEMENT dies — the exact shape S4's MUT-PINDRIFT pinned: a
# reader who trusts the findings is blind while the rows still look right.
mutbuild verdict 's/const char \*st = verdict_of(V->v);/const char *st = NULL; (void)verdict_of;/'
grep -q 'const char \*st = NULL; (void)verdict_of;' "$WORK/mut-verdict.c" \
    || fail "MUT-VERDICT: the sed did not land (check the source text)"
FXSTORE_BIN="$FXSTORE" "$REPO/build/fx-report-verdict" --store "$WORK/p3" > "$WORK/out-mutverdict" 2>/dev/null
grep -q "^progress-finding" "$WORK/out-mutverdict" \
    && fail "MUT-VERDICT: the joinless build STILL raises the finding — the arm is not load-bearing"
grep -q "^progress-content${TAB}$GHB${TAB}versions${TAB}3${TAB}runs${TAB}2${TAB}failed${TAB}0${TAB}in-progress${TAB}0${TAB}ok${TAB}0${TAB}not-judged${TAB}3" "$WORK/out-mutverdict" \
    || fail "MUT-VERDICT: the mutant lost the READING too — this control is meant to blind the JUDGEMENT only, so the two must be independent"
echo "test_fx_report: PROGRESS-MUTANT the joinless build keeps the correct versions/runs/not-judged READING and loses only the FINDING"

# POLICY: the retention policy is a DECISION now (UNBOUNDED, user,
# 2026-10-12), and it prints — so it is PINNED where it prints, in the
# seat's frozen retention table and its bound, on every run.  FAIL: the
# tables revert to the open gap ("NO policy exists"), a row loses the
# decision, the date drifts silently, the .bootlog row stops naming its
# COST (the full rescan per boot — a policy without its cost is not the
# decision), or the OLD bound id `retention-unpoliced` is still printed —
# which is false now that the policy IS stated, and only a grep for its
# absence catches that.
NRETROWS=$(grep -c "^retention${TAB}" "$WORK/out-s1")
[ "$NRETROWS" = "8" ] || fail "POLICY: expected the seat's 8 retention rows on every run, got $NRETROWS (a row was silently dropped; 8 = the original 7 + S2's claim-rows row)"
DECIDED=$(grep -c "^retention${TAB}.*${TAB}DECIDED (user, 2026-10-12): UNBOUNDED" "$WORK/out-s1")
[ "$DECIDED" = "6" ] || fail "POLICY: the six frozen retention rows must state the DECISION (UNBOUNDED, user, 2026-10-12) in the policy column; $DECIDED of 6 do"
grep -q "^retention${TAB}\.bootlog${TAB}.*STATED COST" "$WORK/out-s1" \
    || fail "POLICY: the .bootlog row must name its COST (the full .bootlog rescan per boot)"
grep -q "^bound${TAB}retention-unbounded-by-decision${TAB}.*NOTHING MAY BE DROPPED" "$WORK/out-s1" \
    || fail "POLICY: the retention bound must print the decision (id retention-unbounded-by-decision, NOTHING MAY BE DROPPED)"
grep -q "^bound${TAB}retention-unpoliced" "$WORK/out-s1" \
    && fail "POLICY: the OLD bound id 'retention-unpoliced' still prints — the policy IS stated, so that id is a false claim"
grep -q "NO growth policy exists" "$WORK/out-s1" \
    && fail "POLICY: a frozen retention row still says no growth policy exists — §1a gap 4 was DECIDED, not left open"
# the bound table is counted like the retention table, and S2's amended
# same-store-only row is asserted ON THE OUTPUT: the PIN-REPORT filter
# drops that row on BOTH sides (its text was amended in S2), so the row's
# complete loss or an id change would otherwise pass the pin silently.
NBOUNDROWS=$(grep -c "^bound${TAB}" "$WORK/out-s1")
[ "$NBOUNDROWS" = "26" ] || fail "POLICY: expected the seat's 26 bound rows on every run, got $NBOUNDROWS (a row was silently dropped; 26 = the 8 pre-S2 rows + S2's 4 claim bounds + P9's 2 call bounds + S4's 2 reach bounds + S4-palisade's 2 sandbox bounds + progress's 8)"
grep -q "^bound${TAB}reach-audit-is-the-weakened-one${TAB}.*JUDGED ARGUMENTS rather than typed" "$WORK/out-s1" \
    || fail "POLICY: the S4 bound that says the reach audit is the WEAKENED one must print on every run (a report that reads stronger than it is, is the failure this project keeps finding)"
grep -q "^bound${TAB}reach-attribution-mirrors-the-seat${TAB}" "$WORK/out-s1" \
    || fail "POLICY: the S4 bound naming the MIRRORED matcher (the attribution risk) must print on every run"
grep -q "^bound${TAB}same-store-only${TAB}.*the ONE in-domain exception" "$WORK/out-s1" \
    || fail "POLICY: the amended same-store-only row must print on every run — the pin drops it on BOTH sides, so its loss or an id change is caught only here"
grep -q "^bound${TAB}call-auditing-not-proofing${TAB}.*NO LANE STOP BY DEFAULT" "$WORK/out-s1" \
    || fail "POLICY: the call class's auditing-not-proofing bound (the G7 demotion stated) must print on every run"
# S4 (palisade): the two bounds that say what the sandbox class CANNOT see print
# on every run — a report that reads stronger than it is, is the failure this
# project keeps finding, and "the sandbox change is VISIBLE" is exactly the
# claim that must not grow into "the sandbox is STRONG".
grep -q "^bound${TAB}sandbox-audit-is-the-weakened-one${TAB}.*the sidecar is UNPINNED" "$WORK/out-s1" \
    || fail "POLICY: the S4 bound that says the sandbox audit is the WEAKENED one must print on every run"
grep -q "^bound${TAB}sandbox-visible-is-not-strong${TAB}.*no uid drop" "$WORK/out-s1" \
    || fail "POLICY: the S4 bound that says a visible sandbox change is not a STRONG one must print on every run"
# the progress class's bounds: the count arm above cannot say WHICH row went
# missing, so the ids are asserted as a list.  Each one is a limit a reader
# needs WHERE THEY MEET THE NUMBER.
for _b in activity-without-progress-cannot-see-intent progress-identity-is-content-not-behaviour \
          progress-verdict-join-mirrors-the-select-seat progress-is-not-a-policy \
          progress-cannot-see-a-changing-content-loop progress-blind-to-the-self-report \
          progress-record-scope progress-version-cap; do
    grep -q "^bound${TAB}$_b${TAB}" "$WORK/out-s1" \
        || fail "POLICY: the progress bound '$_b' is not printed on every run (a measurement that hides its own blind spots is incomplete work)"
done
grep -q "^bound${TAB}progress-is-not-a-policy${TAB}.*does not gate, deny, refuse, reorder or stop anything" "$WORK/out-s1" \
    || fail "POLICY: the bound that says the progress class is a MEASUREMENT and not a policy must print"
grep -q "^bound${TAB}progress-cannot-see-a-changing-content-loop${TAB}.*identities-never-ok" "$WORK/out-s1" \
    || fail "POLICY: the bound naming the loop the recurrence finding CANNOT see must print"
# and the taxonomy carries both classes, with content-recurrence NAMED as the
# narrower one — two look-alike entries without that IS the silent defect
grep -q "^taxonomy${TAB}content-recurrence${TAB}.*THIS IS THE NARROWER CLASS" "$WORK/out-s1" \
    || fail "POLICY: the content-recurrence taxonomy row must say it is the NARROWER class and why"
grep -q "^taxonomy${TAB}progress${TAB}MEASURED.*progress-content" "$WORK/out-s1" \
    || fail "POLICY: the progress taxonomy row is not printed (the class has no grammar)"
grep -q "^taxonomy${TAB}progress${TAB}.*this class does not read it" "$WORK/out-s1" \
    || fail "POLICY: the progress taxonomy row must state that it does not read .recovery — that IS the difference from content-recurrence"

# ══ OPERATOR: the derived class on the unattributed store ═══════════════
report "$WORK/s2" "$WORK/out-s2"
[ $? -eq 0 ] || fail "OPERATOR: the DERIVED intervention must NOT be a finding (exit 0), got $?"
grep -q "^absence${TAB}.recovery${TAB}no-automatic-roll-forward-recorded" "$WORK/out-s2" \
    || fail "OPERATOR: the no-.recovery absence not stated"
grep -q "^event${TAB}operator-intervention${TAB}DERIVED${TAB}shape${TAB}restore${TAB}version${TAB}$VCUR${TAB}genhash${TAB}$GHC${TAB}represents" "$WORK/out-s2" \
    || fail "OPERATOR: no DERIVED operator-intervention for the unattributed restore of v$VCUR"
grep -q "^event${TAB}operator-intervention.*bound${TAB}disjunction: operator-rollback-OR-re-activation-of-older-config-OR-removed-recovery-row" "$WORK/out-s2" \
    || fail "OPERATOR: the disjunction bound is not stated inline"
grep -q "^event${TAB}roll-forward-automatic" "$WORK/out-s2" \
    && fail "OPERATOR: a roll-forward-automatic event with NO .recovery — fabricated"
grep -q "^# operator interventions: 1 DERIVED" "$WORK/out-s2" \
    || fail "OPERATOR: the summary count is wrong"
grep -q "^# operator interventions: 1 DERIVED (a backward move or a stale CURRENT the records do not attribute).  NO .operator journal exists for this store: it predates fx-init ca9cb06" "$WORK/out-s2" \
    || fail "OPERATOR: the summary must say the journal does not exist for this store (the derived class's OWN domain, not a verdict)"
grep -q "^absence${TAB}.operator${TAB}no-operator-journal-this-store-predates-fx-init-ca9cb06" "$WORK/out-s2" \
    || fail "OPERATOR: the absent .operator must be its OWN state, never silently read as no-interventions"
grep -q "^event${TAB}operator-intervention${TAB}MEASURED" "$WORK/out-s2" \
    && fail "OPERATOR: a MEASURED operator row with NO .operator — fabricated"

# ══ JOURNAL: the DURABLE operator journal is the RECORD, and the derived
#    fallback is RETAINED beside it (the pair that proves the move is real:
#    S2 has no file and reports the derivation; S2J has the rows and reports
#    them MEASURED while STILL deriving what the journal cannot see) ══════
cp -a "$WORK/s2" "$WORK/s2j" || fail cp
# the writer's header, abridged but verbatim where it defines the SHAPE —
# every "#" line is the writer's header and the reader skips them all.  A
# QUOTED heredoc: the real header contains backticks (command substitution
# in an unquoted one).
cat > "$WORK/s2j/.operator" <<'OPHDR'
# fx-init operator journal. One DATA line per OPERATOR intervention
# on the generation plane: per control-channel `activate`, `rollback`
# or `shutdown` — INCLUDING the ones that FAILED or were REFUSED; an
# intervention that did not take effect is still one — AND, since the
# runtime-record closure, one row for each publish fx-activate committed
# OUTSIDE that handler.  The count of interventions is the number of
# lines starting with a digit.
# line: <epoch-s> <action> <arg> <outcome> <from-version|-> <to-version|-> <boot-nonce|none>
# (the rest of OPERATOR_HEADER, operator_journal.zig:122, is abridged here: every "#"
# line is the writer's header and the reader skips them ALL.)
OPHDR
# the data rows: five shapes of intervention, three of them refusals, one
# naming a version the store does not hold (the row is CHECKABLE against
# the store's history, not authoritative over it).
cat >> "$WORK/s2j/.operator" <<EOF
190 activate /fx/src/cfgB.dhall ok $VA $VB gateboot02
201 activate /fx/src/bad.dhall failed:1 $VA - gateboot02
202 activate /fx/src/big.dhall refused-config $VA $VCUR gateboot02
203 rollback 9 refused $VCUR - gateboot03
204 activate /fx/src/x.dhall unverified $VCUR - gateboot03
205 activate /fx/src/y.dhall dhake-failed $VCUR 5 gateboot03
300 rollback $VA ok $VB $VCUR gateboot03
301 activate /fx/src/gone.dhall ok $VCUR 999 gateboot03
302 activate /run/fx/config-a.dhall ok $VB $VCUR gateboot03
EOF
# 302 IS THE DIRECT-EXEC SHAPE (the runtime-record closure): fx-activate
# recording the publish IT committed when it ran outside PID1's handler —
# same grammar, same file, and its nonce is the boot's own token (a
# self-recorded row NEVER carries "none", the predicate forbids it).
NOPROWS=9
NOPSREF=3
report "$WORK/s2j" "$WORK/out-s2j"
[ $? -eq 0 ] || fail "JOURNAL: a store WITH an operator journal must report cleanly (exit 0), got $?"
grep -q "^absence${TAB}.operator" "$WORK/out-s2j" \
    && fail "JOURNAL: an absence record for a .operator that IS there — fabricated"
# MEASURED, carrying the row VERBATIM: epoch, action, the operator's own
# operand, the outcome, the generation pair, the boot nonce, the file+line.
grep -q "^event${TAB}operator-intervention${TAB}MEASURED${TAB}file${TAB}.operator${TAB}line${TAB}[0-9]*${TAB}epoch${TAB}190${TAB}action${TAB}activate${TAB}arg${TAB}/fx/src/cfgB.dhall${TAB}outcome${TAB}ok${TAB}from-version${TAB}$VA${TAB}to-version${TAB}$VB${TAB}nonce${TAB}gateboot02" "$WORK/out-s2j" \
    || fail "JOURNAL: no MEASURED operator row for the journal's own first data line (the file is being ignored)"
grep -q "^event${TAB}operator-intervention${TAB}MEASURED${TAB}file${TAB}.operator${TAB}line${TAB}[0-9]*${TAB}epoch${TAB}300${TAB}action${TAB}rollback${TAB}arg${TAB}$VA${TAB}outcome${TAB}ok" "$WORK/out-s2j" \
    || fail "JOURNAL: the operator ROLLBACK row (action+verbatim arg) is not reported"
# the DIRECT-EXEC row: parsed by the SAME read_operator shape validator (a
# self-recorded row is a row like any other — the writer is not a field)
grep -q "^event${TAB}operator-intervention${TAB}MEASURED${TAB}file${TAB}.operator${TAB}line${TAB}[0-9]*${TAB}epoch${TAB}302${TAB}action${TAB}activate${TAB}arg${TAB}/run/fx/config-a.dhall${TAB}outcome${TAB}ok${TAB}from-version${TAB}$VB${TAB}to-version${TAB}$VCUR${TAB}nonce${TAB}gateboot03" "$WORK/out-s2j" \
    || fail "JOURNAL: the direct-exec (self-recorded) activate row — the shape the runtime-record closure adds — is not parsed and reported"
# the row naming a version the store does not hold is CHECKED, not trusted
grep -q "^event${TAB}operator-intervention${TAB}MEASURED.*to-version${TAB}999.*note${TAB}to-version-not-in-timeline-pruned-or-foreign" "$WORK/out-s2j" \
    || fail "JOURNAL: a journal row naming a version not in the timeline must carry the pruned-or-foreign note (the row is checkable, not authoritative)"
# REFUSALS: MEASURED, and the class that could not answer before
grep -q "^event${TAB}activation-refusal${TAB}MEASURED${TAB}file${TAB}.operator${TAB}line${TAB}[0-9]*${TAB}epoch${TAB}201${TAB}action${TAB}activate${TAB}arg${TAB}/fx/src/bad.dhall${TAB}outcome${TAB}failed:1" "$WORK/out-s2j" \
    || fail "JOURNAL: the failed activation (outcome failed:<rc>) is not reported as an activation-refusal"
grep -q "^event${TAB}activation-refusal${TAB}MEASURED.*epoch${TAB}202.*outcome${TAB}refused-config" "$WORK/out-s2j" \
    || fail "JOURNAL: the REFUSED-CONFIG activation is not reported as an activation-refusal"
grep -q "^event${TAB}activation-refusal${TAB}MEASURED.*epoch${TAB}203.*action${TAB}rollback.*outcome${TAB}refused" "$WORK/out-s2j" \
    || fail "JOURNAL: a rollback the STORE refused is an intervention that did not take effect and must be reported"
grep -q "^event${TAB}activation-refusal${TAB}MEASURED.*outcome${TAB}unverified" "$WORK/out-s2j" \
    && fail "JOURNAL: \`unverified\` is AMBIGUOUS (the store could not be re-opened), not a refusal — a class must not be more authoritative than its record"
grep -q "^event${TAB}activation-refusal${TAB}MEASURED.*outcome${TAB}dhake-failed" "$WORK/out-s2j" \
    && fail "JOURNAL: \`dhake-failed\` means the generation LANDED (only the live-root reapply failed) — it is not a refusal"
grep -q "^# operator interventions: $NOPROWS MEASURED from the .operator journal ($NOPROWS row(s); $NOPSREF of them a refusal" "$WORK/out-s2j" \
    || fail "JOURNAL: the summary must count the MEASURED rows and the refusals among them"
grep -q "^# activation refusals: $NOPSREF MEASURED in the .operator journal" "$WORK/out-s2j" \
    || fail "JOURNAL: the refusal summary must say MEASURED with its count"
grep -q "^# activation refusals: THIS REPORT CANNOT SAY" "$WORK/out-s2j" \
    && fail "JOURNAL: the pre-ca9cb06 'cannot say' must NOT be printed for a store that HAS the journal"
# THE RETAINED DERIVATION: a journal row EXPLAINS the backward move; it
# must not SUPPRESS it (the journal cannot prove it saw every path).
grep -q "^event${TAB}operator-intervention${TAB}DERIVED${TAB}shape${TAB}restore${TAB}version${TAB}$VCUR.*journal-attributes-a-move-to-this-version" "$WORK/out-s2j" \
    || fail "JOURNAL: the DERIVED fallback was DROPPED for a store that has the journal — a row explains a move, it cannot prove the journal saw the path"
grep -q "^taxonomy${TAB}activation-refusal${TAB}MEASURED.*outcome is a refusal" "$WORK/out-s2j" \
    || fail "JOURNAL: the taxonomy row still describes the pre-ca9cb06 record (the frozen table did not move)"

# ══ ABSENT: none-occurred vs not-durably-recorded ════════════════════════
report "$WORK/s3" "$WORK/out-s3"
[ $? -eq 0 ] || fail "ABSENT: a never-booted store must report cleanly (absence is not a finding), got $?"
grep -q "^absence${TAB}.bootlog${TAB}no-boot-ever-recorded" "$WORK/out-s3" \
    || fail "ABSENT: a store with no .bootlog must say no-boot-ever-recorded, not zero boots"
grep -q "^event${TAB}boot-verdict" "$WORK/out-s3" \
    && fail "ABSENT: boot events fabricated with no .bootlog"
grep -q "^absence${TAB}rt-log${TAB}/run/fx/log.db-not-durably-recorded-tmpfs" "$WORK/out-s3" \
    || fail "ABSENT: the rt-log absence (tmpfs, not 'none') is not stated"
grep -q "^taxonomy${TAB}activation-refusal${TAB}.*NOT-DURABLY-RECORDED" "$WORK/out-s3" \
    || fail "ABSENT: the refusal class's not-durably-recorded row is not in the taxonomy"
grep -q "^absence${TAB}.operator${TAB}no-operator-journal-this-store-predates-fx-init-ca9cb06" "$WORK/out-s3" \
    || fail "ABSENT: a store with no .operator must say it predates the journal — the absence of the FILE is a state, not an absence of interventions"
grep -q "^event${TAB}activation-refusal" "$WORK/out-s3" \
    && fail "ABSENT: a refusal event fabricated with NO .operator"
grep -q "^# activation refusals: THIS REPORT CANNOT SAY" "$WORK/out-s3" \
    || fail "ABSENT: the summary must refuse to say whether any activation was refused"

# GCKEEP/GREAP: the MEASURED gc behaviour, re-proven every run, on S3 —
# BOTH directions of the generation-dir carve-out.  Keep the old evidence
# VISIBLE as the inverted pair rather than deleting it: a dir a surviving
# snapshot names is retained, AND a dir whose snapshot was pruned IS reaped.
[ -d "$WORK/s3/$GHA-system-generation" ] || fail "GCKEEP precondition: no retained config dir before gc"
[ -d "$WORK/s3/$GHB-system-generation" ] || fail "GCKEEP precondition: no second generation dir before gc"
"$FXSTORE" gc dhake --store "$WORK/s3" >/dev/null 2>"$WORK/gc-s3.err" || fail "fxstore gc failed"
[ -d "$WORK/s3/$GHA-system-generation" ] \
    || fail "GCKEEP: the retained config dir DID NOT SURVIVE gc — the frozen retention row in tools/fx-report.c is STALE (gc regressed; re-measure and update it)"
[ -d "$WORK/s3/$GHB-system-generation" ] \
    || fail "GCKEEP: v$VB's generation dir did not survive gc — a surviving snapshot's generation fact names it"
grep -q "keeping generation dir '$GHA-system-generation'" "$WORK/gc-s3.err" \
    || fail "GCKEEP: gc did not LOUDLY log keeping $GHA-system-generation (a silent store-policy decision is the defect class)"
report "$WORK/s3" "$WORK/out-s3gc"
[ $? -eq 0 ] || fail "GCKEEP: the post-gc store must be COHERENT (exit 0 — every surviving copy is readable), got $?"
grep -q "^verdict${TAB}documented$" "$WORK/out-s3gc" \
    || fail "GCKEEP: verdict must be documented for a store whose inputs survived gc"
grep -q "^finding${TAB}config-retained-copy-gone" "$WORK/out-s3gc" \
    && fail "GCKEEP: a config-retained-copy-gone finding on a store gc did NOT prune — fabricated (the class now needs a GENUINELY missing copy; see FINDINGS)"
# the REAP direction: gc --retain 1 prunes every snapshot but the newest,
# whose generation fact names $GHA — so $GHB's dir is reaped WITH v$VB.
# The report over the pruned store stays COHERENT: the pruned version is
# gone from the timeline entirely (absence-by-retention), never a finding.
cp -a "$WORK/s3" "$WORK/s3r" || fail cp
"$FXSTORE" gc --retain 1 dhake --store "$WORK/s3r" >/dev/null 2>"$WORK/gc-s3r.err" || fail "fxstore gc --retain 1 failed"
[ -d "$WORK/s3r/$GHA-system-generation" ] \
    || fail "GREAP: the NEWEST snapshot's generation dir must survive gc --retain 1"
[ -d "$WORK/s3r/$GHB-system-generation" ] \
    && fail "GREAP: the pruned snapshot's generation dir $GHB survived — the carve-out is a blanket keep, not the fact-derived rule the retention row states"
grep -q "reaping generation dir '$GHB-system-generation'" "$WORK/gc-s3r.err" \
    || fail "GREAP: gc did not LOUDLY log reaping $GHB-system-generation"
report "$WORK/s3r" "$WORK/out-s3rgc"
[ $? -eq 0 ] || fail "GREAP: the pruned store must report COHERENTLY (exit 0 — absence-by-retention is not a finding), got $?"

# FOREIGN: a bootlog line naming a version the store no longer holds
echo "999 in-progress 900 gateboot99" >> "$WORK/s2/.bootlog"
echo "999 ok 901 gateboot99" >> "$WORK/s2/.bootlog"
report "$WORK/s2" "$WORK/out-s2f"
grep -q "version-not-in-timeline-pruned-or-foreign" "$WORK/out-s2f" \
    || fail "FOREIGN: a bootlog line for a version not in the timeline was dropped instead of named"

# FINDINGS: sha mismatch, then a missing copy (S2's retained configs)
CFG_A_PATH="$WORK/s2/$GHA-system-generation/config.dhall"
CFG_B_PATH="$WORK/s2/$GHB-system-generation/config.dhall"
echo "-- tampered by the FINDINGS arm" > "$CFG_B_PATH"
report "$WORK/s2" "$WORK/out-s2s"
[ $? -eq 1 ] || fail "FINDINGS: a corrupted retained copy must be exit 1, got $?"
grep -q "^finding${TAB}config-sha-mismatch${TAB}version${TAB}$VB" "$WORK/out-s2s" \
    || fail "FINDINGS: no config-sha-mismatch for v$VB"
rm -f "$CFG_A_PATH"
report "$WORK/s2" "$WORK/out-s2m"
[ $? -eq 1 ] || fail "FINDINGS: a deleted retained copy must be exit 1, got $?"
grep -q "^finding${TAB}config-retained-copy-gone${TAB}version${TAB}$VA" "$WORK/out-s2m" \
    || fail "FINDINGS: no config-retained-copy-gone for v$VA"

# REPOINT: rollback --hard moves CURRENT without a new version
"$FXSTORE" rollback --hard "$VA" --store "$WORK/s2" >/dev/null 2>&1 \
    || fail "rollback --hard $VA failed"
report "$WORK/s2" "$WORK/out-s2h"
grep -q "^current${TAB}$VA${TAB}MEASURED${TAB}newest" "$WORK/out-s2h" \
    || fail "REPOINT: current record does not follow the --hard repoint"
grep -q "^event${TAB}operator-intervention${TAB}DERIVED${TAB}shape${TAB}current-repoint${TAB}current${TAB}$VA" "$WORK/out-s2h" \
    || fail "REPOINT: the stale-CURRENT signature (rollback --hard) is not derived"

# LOUD: a cap refusal and a read error are exit 2, never a silent pass
cp -a "$WORK/s1" "$WORK/loud" || fail cp
: > "$WORK/loud/.bootlog"
i=0; while [ $i -lt 9000 ]; do echo "$VA ok $((100 + i)) gatebootXX" >> "$WORK/loud/.bootlog"; i=$((i + 1)); done
report "$WORK/loud" "$WORK/out-loud"
[ $? -eq 2 ] || fail "LOUD: an over-long .bootlog must be exit 2 (a report over a truncated view is a lie), got $?"
grep -q "MAX_BOOTLOG_LINES" "$WORK/loud/.bootlog.d.err" 2>/dev/null || grep -q "MAX_BOOTLOG_LINES" "$WORK/out-loud.err" \
    || fail "LOUD: the cap refusal does not name the cap"
cp -a "$WORK/s1" "$WORK/loud2" || fail cp
chmod 000 "$WORK/loud2/.bootlog"
report "$WORK/loud2" "$WORK/out-loud2"
[ $? -eq 2 ] || fail "LOUD: an unreadable .bootlog must be exit 2 (a read error is not an absence), got $?"
chmod 644 "$WORK/loud2/.bootlog"

# LOUD: a .operator line that is not the writer's shape is exit 2 NAMING
# the shape — a silently skipped row would DELETE an operator action from
# the account, which is the whole reason the journal exists.
cp -a "$WORK/s1" "$WORK/loud3" || fail cp
printf '99 activate /fx/src/cfgA.dhall ok\n' > "$WORK/loud3/.operator"
report "$WORK/loud3" "$WORK/out-loud3"
[ $? -eq 2 ] || fail "LOUD: a TRUNCATED .operator line (the realistic corruption) must be exit 2 (never skipped silently), got $?"
grep -q "not the writer's shape" "$WORK/out-loud3.err" \
    || fail "LOUD: the .operator shape refusal does not name the shape"
# ... and a line of PROSE also splits into seven whitespace fields, so the
# SHAPE alone is not enough: the generation pair must be the writer's
# vocabulary (a decimal version or "-"), or a damaged file would invent an
# operator action.  FAIL: exit 0 (the prose accepted as a row).
printf '99 this is not the writer shape at all\n' > "$WORK/loud3/.operator"
report "$WORK/loud3" "$WORK/out-loud3b"
[ $? -eq 2 ] || fail "LOUD: a prose line was accepted as a journal row (seven fields is not the writer's shape), got $?"
grep -q "not the writer's vocabulary" "$WORK/out-loud3b.err" \
    || fail "LOUD: the prose refusal does not name the generation-pair check"
# LOUD: an unreadable .operator is exit 2 (a read error is not an absence)
cp -a "$WORK/s1" "$WORK/loud4" || fail cp
printf '190 activate /fx/src/cfgA.dhall ok 1 2 none\n' > "$WORK/loud4/.operator"
chmod 000 "$WORK/loud4/.operator"
report "$WORK/loud4" "$WORK/out-loud4"
[ $? -eq 2 ] || fail "LOUD: an unreadable .operator must be exit 2 (a read error is not an absence), got $?"
chmod 644 "$WORK/loud4/.operator"

# ══ MUTATIONS: disable one taxonomy piece at a time; the arm that asserts
#    it must GO BLIND on the mutant, or the taxonomy is decoration ══════
# MUT-CLASS: the operator-intervention emission is disabled (its record tag
# renamed) — the OPERATOR arm must go blind on exactly the S2 fixture.
mutbuild class 's/event\\toperator-intervention\\tDERIVED\\tshape\\trestore/disabled\\toperator-intervention\\tDERIVED\\tshape\\trestore/'
FXSTORE_BIN="$FXSTORE" "$REPO/build/fx-report-class" --store "$WORK/s2" > "$WORK/out-mutclass" 2>/dev/null
grep -q "^event${TAB}operator-intervention${TAB}DERIVED${TAB}shape${TAB}restore${TAB}version${TAB}$VCUR" "$WORK/out-mutclass" \
    && fail "MUT-CLASS: the operator arm still passes with the class disabled — the assertion is not load-bearing"

# MUT-ATTRIB: the .recovery attribution check is deleted — every restore
# becomes an operator event, so the AUTO CONTROL (S1: NO operator event)
# must go blind on the mutant.
mutbuild attrib '/if (recrow_names(V->v)) continue; \/\* the automatic path recorded it \*\//d'
FXSTORE_BIN="$FXSTORE" "$REPO/build/fx-report-attrib" --store "$WORK/s1" > "$WORK/out-mutattr" 2>/dev/null
grep -q "^event${TAB}operator-intervention" "$WORK/out-mutattr" \
    || fail "MUT-ATTRIB: the AUTO control still passes with the attribution deleted — the .recovery row is not load-bearing"

# MUT-FINDING: the copy-gone finding is disabled — the FINDINGS arm must go
# blind on S2's GENUINELY missing copy (hand-deleted in the FINDINGS arm;
# the post-gc store can no longer produce the class — gc now RETAINS every
# surviving snapshot's copy, so the class's reachable shape is the hand-
# deleted file).
mutbuild finding 's/finding\\tconfig-retained-copy-gone/finding\\tconfig-retained-copy-DISABLED/'
FXSTORE_BIN="$FXSTORE" "$REPO/build/fx-report-finding" --store "$WORK/s2" > "$WORK/out-mutfind" 2>/dev/null
grep -q "^finding${TAB}config-retained-copy-gone${TAB}version${TAB}$VA" "$WORK/out-mutfind" \
    && fail "MUT-FINDING: the copy-gone arm still passes with the finding disabled — the assertion is not load-bearing"

# MUT-OPS: the MEASURED journal emission is disabled — the JOURNAL arm's
# MEASURED assertion must go blind on exactly the S2J fixture.
mutbuild ops 's/event\\toperator-intervention\\tMEASURED/disabled\\toperator-intervention\\tMEASURED/'
FXSTORE_BIN="$FXSTORE" "$REPO/build/fx-report-ops" --store "$WORK/s2j" > "$WORK/out-mutops" 2>/dev/null
grep -q "^event${TAB}operator-intervention${TAB}MEASURED" "$WORK/out-mutops" \
    && fail "MUT-OPS: the JOURNAL arm still passes with the MEASURED emission disabled — the assertion is not load-bearing"

# MUT-REFUSE: the activation-refusal emission is disabled — the JOURNAL
# arm's refusal assertion must go blind on the same fixture.
mutbuild refuse 's/event\\tactivation-refusal\\tMEASURED/disabled\\tactivation-refusal\\tMEASURED/'
FXSTORE_BIN="$FXSTORE" "$REPO/build/fx-report-refuse" --store "$WORK/s2j" > "$WORK/out-mutrefuse" 2>/dev/null
grep -q "^event${TAB}activation-refusal${TAB}MEASURED" "$WORK/out-mutrefuse" \
    && fail "MUT-REFUSE: the JOURNAL arm's refusal assertion still passes with the refusal emission disabled"

# ══ CLAIM (S2): the judge seat's verdict record SURFACES ════════════════
# The claim class is MEASURED from <store>.fx-claim-obs — fx-claim's own
# durable record, the same standing as .bootlog/.operator.  The fixture is
# built by the REAL writers (activate_paths, fx-activate with the two claim
# rows riding extraEtc — tests/test_claim.sh's exact construction) and
# judged by the REAL judge (build/fx-claim; le + dlb are consumed as
# dependencies, never forked).  FIXTURE HONESTY: .operator is fx-init's
# file and fx-init does not run host-side — the gate writes it in the
# writer's exact shape (as test_claim.sh and the JOURNAL arm do), with the
# args as fixed literals; the observation is fx-claim's OWN output (the
# real seat, no hand-writing), except where an arm TAMPERS it and says so.
CLAIM_READY=1
LE_ROOT="${LE_DIR:-}"
if [ -z "$LE_ROOT" ]; then
    for _cand in "$SIBS/logical-english" "$REPO/../logical-english" "$HOME/logical-english"; do
        if [ -f "$_cand/le/__init__.py" ]; then LE_ROOT="$_cand"; break; fi
    done
fi
DLB_PY="${DLB_PATH:-}"
if [ -z "$DLB_PY" ]; then
    for _cand in "$SIBS/datalog-dafsa/python" "$REPO/../datalog-dafsa/python" "$HOME/fixpoint-linux/datalog-dafsa/python"; do
        if [ -f "$_cand/dlb/__init__.py" ]; then DLB_PY="$_cand"; break; fi
    done
fi
if [ ! -f "$LE_ROOT/le/__init__.py" ] || [ ! -f "$DLB_PY/dlb/__init__.py" ] || [ ! -f "$REPO/policy/claims-policy.dl" ]; then
    echo "test_fx_report: CLAIM ARMS SKIPPED — no le checkout / dlb binding / policy artifact (set LE_DIR and DLB_PATH; run make policy-artifact): the claim class cannot be judged without the frozen policy, and this gate does not fake a verdict"
    CLAIM_READY=0
fi
make -s build/fx-claim >/dev/null 2>&1 || CLAIM_READY=0
if [ "$CLAIM_READY" = 1 ]; then
    export LE_DIR="$LE_ROOT" DLB_PATH="$DLB_PY"
    CLAIM="$REPO/build/fx-claim"
    [ "$CLAIM" -nt "$REPO/tools/fx-claim.c" ] || fail "CLAIM: build/fx-claim is older than tools/fx-claim.c — a stale judge answered"
    grep -aq "fx-claim-observation 1" "$CLAIM" || fail "CLAIM: STALE JUDGE — no observation-format marker"
    POLICY_CLAIM="$REPO/policy/claims-policy.dl"
    FIXC="$REPO/tests/fixtures/claims"

    # ── the fixture: root (claimless) -> the deriving claim -> enrollment,
    # then a POST-enrollment claimless commit (the coverage arm's gap).
    # write_cfg/write_cfg_nc: tests/test_claim.sh's writers verbatim — the
    # two claim rows ride INTO the config's extraEtc (BEFORE, structural).
    write_cfg() {
        python3 - "$1" "$2" "$3" "$4" <<'PYEOF'
import sys
out, host, tsv_path, le_path = sys.argv[1:5]
def dh(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
tsv = open(tsv_path).read()
le = open(le_path).read()
extra = ('Some [ { path = "fx-claim.tsv", content = "%s" }\n'
         '             , { path = "fx-claim.le", content = "%s" } ]' % (dh(tsv), dh(le)))
cfg = '''let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }),
                console : Optional Text }
let User = { name : Text, uid : Natural, groups : List Text }
in  { hostname = "%s"
    , packages = [] : List Text
    , users = [ { name = "root", uid = 0, groups = [] : List Text } ] : List User
    , services = [] : List Service
    , extraEtc = %s
    , bootGraceMs = Some 30000
    , agentService = None Text
    }
''' % (host, extra)
open(out, "w").write(cfg)
PYEOF
    }
    write_cfg_nc() {
        python3 - "$1" "$2" <<'PYEOF'
import sys
out, host = sys.argv[1:3]
cfg = '''let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }),
                console : Optional Text }
let User = { name : Text, uid : Natural, groups : List Text }
in  { hostname = "%s"
    , packages = [] : List Text
    , users = [ { name = "root", uid = 0, groups = [] : List Text } ] : List User
    , services = [] : List Service
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 30000
    , agentService = None Text
    }
''' % host
open(out, "w").write(cfg)
PYEOF
    }
    mkdir -p "$WORK/claim-store" || fail mkdir
    P=$(LD_LIBRARY_PATH="$DL" "$ZB/activate_paths" --store "$WORK/claim-store" --package-set "$PS" \
        dhake fx-init fxctl fx-activate) || fail "activate_paths failed: $P"
    for _pd in $P; do mkdir -p "$WORK/claim-store/$_pd" || fail "cannot create $_pd"; done
    claimact() { # claimact CFGFILE -> "<version> <genhash>" on stdout; LOUD on failure
        _o=$(LD_LIBRARY_PATH="$DL" "$ZB/fx-activate" --store "$WORK/claim-store" --package-set "$PS" \
            --config "$1" 2>&1) || { echo "fx-activate failed: $_o" >&2; return 1; }
        _r=$(echo "$_o" | sed -n 's/.*activated \([0-9a-f]*\) as version \([0-9][0-9]*\).*/\2 \1/p' | head -1)
        [ -n "$_r" ] || { echo "no version from fx-activate: $_o" >&2; return 1; }
        echo "$_r"
    }
    write_cfg_nc "$WORK/cfg-croot.dhall" repbox-root
    write_cfg_nc "$WORK/cfg-cnoclaim.dhall" repbox-noclaim
    claimact "$WORK/cfg-croot.dhall" > "$WORK/act-croot" || fail "claimact failed for the root"
    read _VR CGR < "$WORK/act-croot"
    SHACROOT=$(sha256sum "$WORK/cfg-croot.dhall" | cut -d' ' -f1)
    printf 'claima\tcfg-diff-ok\t%s\t%s\n' "$CGR" "$SHACROOT" > "$WORK/rows-cok.tsv"
    write_cfg "$WORK/cfg-cok.dhall" repbox-ok "$WORK/rows-cok.tsv" "$FIXC/good.le"
    claimact "$WORK/cfg-cok.dhall" > "$WORK/act-cok" || fail "claimact failed for the claim"
    read _VB CGB < "$WORK/act-cok"
    # the writer's .operator shape (fixture honesty as declared above)
    cat > "$WORK/claim-store/.operator" <<'OPHDR'
# fx-init operator journal. One DATA line per OPERATOR intervention
# on the generation plane: per control-channel `activate`, `rollback`
# or `shutdown` — INCLUDING the ones that FAILED or were REFUSED; an
# intervention that did not take effect is still one — AND, since the
# runtime-record closure, one row for each publish fx-activate committed
# OUTSIDE that handler.  The count of interventions is the number of
# lines starting with a digit.
# line: <epoch-s> <action> <arg> <outcome> <from-version|-> <to-version|-> <boot-nonce|none>
# (the rest of OPERATOR_HEADER, operator_journal.zig:122, is abridged here: every "#"
# line is the writer's header and the reader skips them ALL.)
OPHDR
    echo "100 activate /fx/src/cfg-root.dhall ok - $_VR gatenonce" >> "$WORK/claim-store/.operator"
    echo "110 activate /fx/src/cfg-ok.dhall ok $_VR $_VB gatenonce" >> "$WORK/claim-store/.operator"

    run_claimrep() { # run_claimrep OUTFILE [extra judge args...] -> the judge's rc on stdout
        _out=$1; shift
        "$CLAIM" --store "$WORK/claim-store" --policy "$POLICY_CLAIM" --fxstore "$FXSTORE" "$@" \
            >"$_out" 2>"$_out.err"
        echo $?
    }
    _rc=$(run_claimrep "$WORK/claim-j1")
    [ "$_rc" = 0 ] || fail "CLAIM fixture: the enroll run must exit 0, got $_rc ($(head -3 "$WORK/claim-j1.err"))"
    grep -q "ENROLLMENT" "$WORK/claim-j1" || fail "CLAIM fixture: the judge's enrollment is not stated"
    # the POST-enrollment claimless commit, judged: the judge fires no-claim
    # and the observation is NOT rewritten (the two seats agree on the gap)
    claimact "$WORK/cfg-cnoclaim.dhall" > "$WORK/act-cnoclaim" || fail "claimact failed for the post-enrollment commit"
    read _VH CGH3 < "$WORK/act-cnoclaim"
    echo "120 activate /fx/src/cfg-noclaim.dhall ok $_VB $_VH gatenonce" >> "$WORK/claim-store/.operator"
    _rc=$(run_claimrep "$WORK/claim-j2")
    [ "$_rc" = 1 ] || fail "CLAIM fixture: the post-enrollment claimless run must exit 1 (no-claim), got $_rc"
    grep -q "^finding${TAB}no-claim${TAB}$CGH3" "$WORK/claim-j2" || fail "CLAIM fixture: the judge did not name no-claim for $CGH3"
    cp "$WORK/claim-store.fx-claim-obs" "$WORK/obs-pinned"
    _rc=$(run_claimrep "$WORK/claim-j3")
    cmp -s "$WORK/obs-pinned" "$WORK/claim-store.fx-claim-obs" || fail "CLAIM fixture: the observation changed under the no-claim disagreement"
    # the claim identity the record carries: sha256(tsv bytes || le bytes)
    CLAIMSHA=$(cat "$WORK/rows-cok.tsv" "$FIXC/good.le" | sha256sum | cut -d' ' -f1)

    # report() with a FIXED RELATIVE store name: the report's own store
    # field is then a constant, which the PIN comparison below relies on.
    report_rel() { # report_rel OUTFILE
        ( cd "$WORK" && FXSTORE_BIN="$FXSTORE" "$REPORT" --store claim-store > "$1" 2>"$1.err" )
    }

    # CLAIM-REC: the surfaces, verbatim from the observation
    report_rel "$WORK/out-claim"
    [ $? -eq 0 ] || fail "CLAIM: the judged store must report cleanly (a disagreement is a record, not a finding), got $?"
    grep -q "^claim-record${TAB}$CGR${TAB}version${TAB}$_VR${TAB}claim-sha${TAB}-${TAB}op-from${TAB}-${TAB}MEASURED$" "$WORK/out-claim" \
        || fail "CLAIM: the claimless root generation's record is not surfaced verbatim"
    grep -q "^claim-verdict${TAB}$CGR${TAB}verdict${TAB}claimless${TAB}MEASURED$" "$WORK/out-claim" \
        || fail "CLAIM (direction i): the claimless row INSIDE the observation must read none-occurred MEASURED — a judge that ran measured it"
    grep -q "^claim-record${TAB}$CGB${TAB}version${TAB}$_VB${TAB}claim-sha${TAB}$CLAIMSHA${TAB}op-from${TAB}$_VR${TAB}MEASURED$" "$WORK/out-claim" \
        || fail "CLAIM: the deriving claim's record is not surfaced — or its identity chain broke (claim-sha must be sha256(tsv||le) = $CLAIMSHA, op-from the .operator row's from-version $_VR)"
    grep -q "^claim-verdict${TAB}$CGB${TAB}verdict${TAB}ok${TAB}MEASURED$" "$WORK/out-claim" \
        || fail "CLAIM: the honest claim's verdict ok is not surfaced"
    grep -q "^claim-disagreement" "$WORK/out-claim" \
        && fail "CLAIM: a disagreement fabricated on a coherent record"
    grep -q "^claim-record${TAB}$CGR.*NOT-RECORDED" "$WORK/out-claim" \
        && fail "CLAIM: a COVERED generation (the observation names it) emitted NOT-RECORDED — the coverage comparison is inverted"
    grep -q "^claim-verdict${TAB}$CGH3${TAB}" "$WORK/out-claim" \
        && fail "CLAIM: a verdict fabricated for a generation the observation does not cover"
    # the enrollment comparison: the post-enrollment claimless commit is
    # NOT-RECORDED with its disjunction — NEVER none-occurred
    grep -q "^claim-record${TAB}$CGH3${TAB}version${TAB}$_VH${TAB}claim-sha${TAB}-${TAB}op-from${TAB}-${TAB}NOT-RECORDED${TAB}bound${TAB}no-observation-row-judge-not-run-since-publish-or-its-run-disagreed-and-the-observation-kept-its-baseline (NOT 'none occurred')$" "$WORK/out-claim" \
        || fail "CLAIM (the enrollment comparison): the post-enrollment claimless commit $CGH3 must be NOT-RECORDED with its disjunction stated, never read as none-occurred"
    grep -q "^# claim records: 2 row(s) in the observation — 2 live generation(s) covered, 1 NOT covered" "$WORK/out-claim" \
        || fail "CLAIM: the summary must single-source the coverage counts"

    # CLAIM-ABSENT (direction ii): the observation's ABSENCE is its own
    # state — not-durably-recorded, and NO verdict fabricated anywhere.
    cp -a "$WORK/claim-store" "$WORK/cs2" || fail cp
    report "$WORK/cs2" "$WORK/out-cs2"
    [ $? -eq 0 ] || fail "CLAIM-ABSENT: an unjudged store must still report cleanly, got $?"
    grep -q "^absence${TAB}\.fx-claim-obs${TAB}not-durably-recorded-no-judge-observation" "$WORK/out-cs2" \
        || fail "CLAIM-ABSENT: a store with no observation must say not-durably-recorded, not none-occurred"
    grep -q "^claim-verdict" "$WORK/out-cs2" \
        && fail "CLAIM-ABSENT: a verdict fabricated from NO record — the §1a gap-3 error in the other direction"
    grep -q "^claim-record${TAB}$CGB.*NOT-RECORDED" "$WORK/out-cs2" \
        || fail "CLAIM-ABSENT: the uncovered claim-bearing generation must still be named NOT-RECORDED"
    grep -q "^# claim records: NO observation" "$WORK/out-cs2" \
        || fail "CLAIM-ABSENT: the summary must refuse to count from nothing"

    # CLAIM-DISAGREE: a tampered observation's verdict surfaces VERBATIM as
    # claim-disagreement — a RECORD, not a reporter finding (exit 0); the
    # audit of the observation is the judge's own next run.
    cp -a "$WORK/claim-store" "$WORK/cs3" || fail cp
    cp "$WORK/claim-store.fx-claim-obs" "$WORK/cs3.fx-claim-obs"
    sed -i -e "s/verdict ok claim-sha/verdict stale-world claim-sha/" "$WORK/cs3.fx-claim-obs"
    grep -aq "stale-world" "$WORK/cs3.fx-claim-obs" || fail "CLAIM-DISAGREE setup: the sed matched nothing"
    report "$WORK/cs3" "$WORK/out-cs3"
    [ $? -eq 0 ] || fail "CLAIM-DISAGREE: a disagreement in the record is a record — exit 0, got $?"
    grep -q "^claim-disagreement${TAB}$CGB${TAB}verdict${TAB}stale-world${TAB}DERIVED" "$WORK/out-cs3" \
        || fail "CLAIM-DISAGREE: the disagreement class in the observation is not surfaced by name"
    grep -q "^claim-verdict${TAB}$CGB${TAB}verdict${TAB}stale-world${TAB}MEASURED$" "$WORK/out-cs3" \
        || fail "CLAIM-DISAGREE: the verdict itself must surface verbatim beside the disagreement"

    # CLAIM-UNKNOWN: a verdict word this report does not know is surfaced
    # verbatim with a note — never silently classified (a newer judge's
    # vocabulary must not read as coherent here).
    cp -a "$WORK/claim-store" "$WORK/cs4" || fail cp
    cp "$WORK/claim-store.fx-claim-obs" "$WORK/cs4.fx-claim-obs"
    sed -i -e "s/verdict ok claim-sha/verdict ok-rewritten claim-sha/" "$WORK/cs4.fx-claim-obs"
    report "$WORK/cs4" "$WORK/out-cs4"
    grep -q "^claim-verdict${TAB}$CGB${TAB}verdict${TAB}ok-rewritten${TAB}MEASURED${TAB}note${TAB}verdict-vocabulary-not-known-to-this-report-surfaced-verbatim-never-classified$" "$WORK/out-cs4" \
        || fail "CLAIM-UNKNOWN: an unknown verdict word must surface verbatim with the not-classified note"
    grep -q "^claim-disagreement${TAB}$CGB" "$WORK/out-cs4" \
        && fail "CLAIM-UNKNOWN: an unknown word classified as a disagreement — the report must not guess"

    # CLAIM-LOUD: a corrupted observation is exit 2 naming the grammar (a
    # report over a misparsed record would be a lie).
    cp -a "$WORK/claim-store" "$WORK/cs5" || fail cp
    cp "$WORK/claim-store.fx-claim-obs" "$WORK/cs5.fx-claim-obs"
    sed -i -e '1s/.*/tampered header/' "$WORK/cs5.fx-claim-obs"
    report "$WORK/cs5" "$WORK/out-cs5"
    [ $? -eq 2 ] || fail "CLAIM-LOUD: an observation that is not the judge's format must be exit 2, got $?"
    grep -q "format-1 observation header" "$WORK/out-cs5.err" \
        || fail "CLAIM-LOUD: the refusal does not name the observation format"

    # CLAIM-LOUD-LONG: an over-long FINAL field is the one shape width
    # limits cannot kill (no following literal to mismatch) — the %n
    # exhaustion check is what refuses it; a truncated op-from printed as
    # MEASURED would be a lying record.  MUT-LOUDLONG below removes exactly
    # that check and must make THIS arm go blind (the row parses,
    # truncated): the arm can fail.
    cp -a "$WORK/claim-store" "$WORK/cs6" || fail cp
    cp "$WORK/claim-store.fx-claim-obs" "$WORK/cs6.fx-claim-obs"
    sed -i -e "s/^\(claim $CGR .*\)op-from -$/\1op-from aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/" "$WORK/cs6.fx-claim-obs"
    grep -aq "op-from aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$WORK/cs6.fx-claim-obs" \
        || fail "CLAIM-LOUD-LONG setup: the sed matched nothing ($CGR's op-from must become a 37-char token)"
    report "$WORK/cs6" "$WORK/out-cs6"
    [ $? -eq 2 ] || fail "CLAIM-LOUD-LONG: an over-long FINAL field must be exit 2 (width limits alone cannot kill it — the exhaustion check must), got $?"
    grep -q "not the judge seat's row shape" "$WORK/out-cs6.err" \
        || fail "CLAIM-LOUD-LONG: the refusal does not name the row shape"
    grep -q "^claim-record${TAB}$CGR" "$WORK/out-cs6" \
        && fail "CLAIM-LOUD-LONG: a TRUNCATED op-from printed as MEASURED — the seat lied"

    # MUT-LOUDLONG: the exhaustion check removed — the over-long final
    # field parses with the op-from truncated to the destination width and
    # the report exits 0: exactly the pre-fix lie the arm above refuses.
    mutbuild loudlong 's/|| pos < 0 || line\[6 + (size_t)pos\] != 0)/\&\& 0)/'
    FXSTORE_BIN="$FXSTORE" "$REPO/build/fx-report-loudlong" --store "$WORK/cs6" > "$WORK/out-mutloudlong" 2>/dev/null
    [ $? -eq 2 ] \
        && fail "MUT-LOUDLONG: the mutant still refuses the over-long final field — the sed removed nothing (the arm is not load-bearing)"
    grep -q "^claim-record${TAB}$CGR${TAB}version.*op-from${TAB}aaa" "$WORK/out-mutloudlong" \
        || fail "MUT-LOUDLONG: the mutant must PARSE the row with the op-from truncated (the pre-fix behaviour this arm exists to refuse)"

    # PIN-REPORT: the PINNED PRE-FIX CONTROL.  The pin is the PRE-FIX
    # report's bytes over THIS claim-carrying store, with the epoch fields
    # of fx-activate's generation facts masked (they are the fixture's
    # wall-clock; everything else is content).  The filter below drops the
    # lines S2 ADDS (the claim class) and masks the same fields on BOTH
    # sides, so cmp proves two things at once: the pin's DOMAIN (it is
    # byte-for-byte this store's pre-fix report — a vacuous pin over some
    # other store cannot reproduce) and that S2 is ADDITIVE (the pre-fix
    # account is preserved byte for byte, only extended).
    PIN="$REPO/tests/fixtures/claims/report-claims-before.txt"
    [ -f "$PIN" ] || fail "PIN-REPORT: missing $PIN (the pre-fix report over the claim store — re-record it consciously)"
    grep -q "^claim-record" "$PIN" \
        && fail "PIN-REPORT: the pin carries claim records — it is the AFTER, not the BEFORE"
    grep -q "the ONE in-domain exception" "$PIN" \
        && fail "PIN-REPORT: the pin carries the post-fix same-store-only amendment — it is not the pre-fix bytes"
    pinfilter() { # pinfilter IN OUT
        awk '
            BEGIN { FS = OFS = "\t" }
            /^version\t/ { $5 = "EPOCH"; print; next }
            /^fact\tgeneration\t/ { $7 = "EPOCH"; print; next }
            /^event\tactivation\t/ { for (i = 1; i < NF; i++) if ($i == "epoch") $(i + 1) = "EPOCH"; print; next }
            /^claim-record\t/ { next }
            /^claim-verdict\t/ { next }
            /^claim-disagreement\t/ { next }
            /^absence\t\.fx-claim-obs\t/ { next }
            /^bound\tclaim-/ { next }
            /^taxonomy\tclaim\t/ { next }
            /^retention\tclaim rows/ { next }
            /^# claim records:/ { next }
            /^taxonomy\tcall\t/ { next }
            /^taxonomy\tcall-telemetry\t/ { next }
            /^bound\tcall-/ { next }
            /^taxonomy\tcall-exec\t/ { next }
            /^taxonomy\treach\t/ { next }
            /^bound\treach-/ { next }
            /^taxonomy\tsandbox\t/ { next }
            /^bound\tsandbox-/ { next }
            /^bound\tsame-store-only\t/ { next }
            /^taxonomy\tcontent-recurrence\t/ { next }
            /^taxonomy\tprogress\t/ { next }
            /^bound\tprogress-/ { next }
            /^bound\tactivity-without-progress-/ { next }
            /^progress-content\t/ { next }
            /^progress-finding\t/ { next }
            /^# (ACTIVITY|PROGRESS)/ { next }
            { print }
        ' "$1" > "$2"
    }
    pinfilter "$WORK/out-claim" "$WORK/out-claim.filtered"
    pinfilter "$PIN" "$WORK/pin.filtered"
    cmp -s "$WORK/pin.filtered" "$WORK/out-claim.filtered" \
        || fail "PIN-REPORT: the pin is not byte-identical to the live report minus its claim class — the pin drifted, the fixture moved, or S2 is no longer ADDITIVE (a pre-existing line changed); re-record the pin consciously only after reading the diff"
    # ... and the AFTER is real: the live report names the claim the
    # pre-fix bytes could not see.
    grep -q "^claim-record${TAB}$CGB${TAB}version${TAB}$_VB" "$WORK/out-claim" \
        || fail "PIN-REPORT: the live report lost the claim record — the asymmetry is broken"

    # MUT-CLAIM: the claim-verdict emission disabled — the CLAIM-REC arm's
    # verdict assertions must go blind on exactly the claim fixture.
    mutbuild claim 's/claim-verdict\\t%s\\tverdict/disabled-claim-verdict\\t%s\\tverdict/'
    FXSTORE_BIN="$FXSTORE" "$REPO/build/fx-report-claim" --store "$WORK/claim-store" > "$WORK/out-mutclaim" 2>/dev/null
    grep -q "^claim-verdict${TAB}$CGB${TAB}verdict${TAB}ok${TAB}MEASURED" "$WORK/out-mutclaim" \
        && fail "MUT-CLAIM: the CLAIM arm still passes with the verdict emission disabled — the assertion is not load-bearing"

    # MUT-ENROLL: the enrollment comparison deleted — the NOT-RECORDED mark
    # becomes literally `claimless`, and the post-enrollment claimless
    # commit reads none-occurred: the §1a gap-3 error, reproduced.
    mutbuild enroll 's/\\tNOT-RECORDED\\tbound\\tno-observation-row/\\tclaimless\\tbound\\tno-observation-row/'
    FXSTORE_BIN="$FXSTORE" "$REPO/build/fx-report-enroll" --store "$WORK/claim-store" > "$WORK/out-mutenroll" 2>/dev/null
    grep -q "^claim-record${TAB}$CGH3.*NOT-RECORDED" "$WORK/out-mutenroll" \
        && fail "MUT-ENROLL: the mutant still emits NOT-RECORDED — the sed deleted nothing (the arm is not load-bearing)"
    grep -q "^claim-record${TAB}$CGH3.*${TAB}claimless${TAB}bound${TAB}no-observation-row" "$WORK/out-mutenroll" \
        || fail "MUT-ENROLL: the mutant did not reproduce the gap-3 error (an uncovered claimless commit must read claimless on it)"
    grep -q "^claim-verdict${TAB}$CGB${TAB}verdict${TAB}ok" "$WORK/out-mutenroll" \
        || fail "MUT-ENROLL: the mutant must leave the COVERED generations untouched (the enrollment comparison is blind on exactly the uncovered one)"
fi

# ══ CALL (P9): the host proxy's ONE LOG <-> the guest's TRANSCRIPT ═══════
# The host gate (tools/fx-hostgate.c) delivers a denial by REWRITING the
# call's name to a reserved name and substituting a denial text; the guest's
# transcript records the REWRITTEN name + a generic sentinel and NEVER learns
# the true verb.  So a denial is AUDITABLE only by joining the guest's view to
# the host's log by call_id — which is what this class makes queryable.  The
# arms below drive a REAL proxy run (build/fx-hostgate + build/fx-agent, the
# same shapes tests/test_hostgate.sh phase 11 uses) and read the REAL log the
# proxy writes and the REAL transcript the guest writes.  FIXTURE HONESTY:
# the one-sided join cases and the telemetry rows are INJECTED into COPIES of
# the real records (declared at each arm) — the real run joins cleanly in both
# directions, which the first arm asserts; nothing is injected into a file the
# report is asked to read as a record.  EVERY proxy is TIME-BOUNDED and
# killed if it outlives the bound; every probe gets a FRESH FX_AGENT_DATA.
CALL_READY=1
[ -x "$REPO/build/fx-hostgate" ] || CALL_READY=0
[ -x "$REPO/build/fx-agent" ] || CALL_READY=0
command -v python3 >/dev/null 2>&1 || CALL_READY=0
if [ "$CALL_READY" = 0 ]; then
    echo "test_fx_report: CALL ARMS SKIPPED — build/fx-hostgate and build/fx-agent (plus python3) are required to produce a REAL host log ('make test-hostgate' builds them)"
fi
if [ "$CALL_READY" = 1 ]; then
    CALLID="call_00_DgJfXOD0j0bvOV7jB0tl0124"
    JUST="the user asked for the weather in Paris; the call reads public weather data and touches nothing else"
    SCOPE="seat-scoped: no operator denial at this seat; the in-guest floor and D2 still govern"

    # the dispatch-recording stub, modelled on the real verbs server: the
    # marker fires ONLY for the known verb (a stub that fired for
    # fx_host_denied would make the marker assert vacuous —
    # test_hostgate.sh phase 10 pins exactly this discipline).
    cat > "$WORK/call_mcp.py" <<PYEOF
#!/usr/bin/env python3
import json, sys
MARKER = "$WORK/call-marker"
KNOWN = "get_weather"
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        req = json.loads(line)
    except ValueError:
        continue
    m = req.get("method")
    if m == "initialize":
        print(json.dumps({"jsonrpc": "2.0", "id": req.get("id"), "result": {
            "protocolVersion": req.get("params", {}).get("protocolVersion"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "call-stub", "version": "0"}}}), flush=True)
    elif m == "tools/call":
        n = (req.get("params") or {}).get("name")
        if n == KNOWN:
            with open(MARKER, "a") as f:
                f.write("dispatched %s\n" % n)
            print(json.dumps({"jsonrpc": "2.0", "id": req.get("id"),
                              "result": {"content": [{"type": "text", "text": "stub-ok-weather"}]}}), flush=True)
        else:
            print(json.dumps({"jsonrpc": "2.0", "id": req.get("id"),
                              "error": {"code": -32602, "message": "unknown tool: %s" % n}}), flush=True)
PYEOF
    chmod +x "$WORK/call_mcp.py"
    mkdir -p "$WORK/call-cfg"
    cat > "$WORK/call-cfg/config.dhall" <<DHALLEOF
{ agents = [ { name = "fx", agent_type = "agent",
    mcp_servers = [ { command = "$WORK/call_mcp.py", args = [] : List Text } ] } ] }
DHALLEOF
    # the upstream is a COPY of the justified fixture (ADDED fixtures only;
    # the repo's fixture is never modified).  Its call's args carry the
    # justification the CLAIM is read from.
    cp "$REPO/tests/fixtures/responses_justified.sse" "$WORK/call-up.sse" \
        || fail "CALL: cannot copy the fixture"

    call_wait_slave() { # PATHFILE PID ERRLOG
        _i=0
        while [ ! -s "$1" ] && [ "$_i" -lt 200 ]; do
            kill -0 "$2" 2>/dev/null || fail "CALL: the proxy died before publishing its slave path ($(tail -2 "$3" 2>/dev/null | tr '\n' ' '))"
            sleep 0.05
            _i=$((_i + 1))
        done
        [ -s "$1" ] || fail "CALL: the proxy never published its slave path"
    }
    call_reap() { # PID ERRLOG
        _i=0
        while kill -0 "$1" 2>/dev/null && [ "$_i" -lt 400 ]; do # <= 40 s
            sleep 0.1
            _i=$((_i + 1))
        done
        if kill -0 "$1" 2>/dev/null; then
            kill -9 "$1" 2>/dev/null
            fail "CALL: the proxy (pid $1) did not exit within 40s — a hung proxy is a FAIL, never a hang"
        fi
    }
    # call_run DENYNAME LOGFILE DATADIR [FIXTURE] — ONE real proxy run
    # (--turns 2, the two-turn shape whose call the guest records),
    # TIME-BOUNDED.  FIXTURE defaults to the justified fixture; the S4 exec
    # arm passes the host_time stream (a REAL host-executed call).
    call_run() { # DENYNAME LOGFILE DATADIR [FIXTURE]
        "$REPO/build/fx-hostgate" --upstream "${4:-$WORK/call-up.sse}" \
            --slave-file "$WORK/call-slave" --log "$2" --deny "$1" --turns 2 \
            2> "$WORK/call-proxy.err" &
        _pid=$!
        call_wait_slave "$WORK/call-slave" "$_pid" "$WORK/call-proxy.err"
        _dev="$(cat "$WORK/call-slave")"
        FX_CHARDEV="$_dev" FX_AGENT_CONFIG_DIR="$WORK/call-cfg" \
            FX_AGENT_DATA="$3" HOME="$WORK" \
            "$REPO/build/fx-agent" -p call-p9-probe --agent fx --max-turns 2 --output text \
            > "$WORK/call-agent.out" 2> "$WORK/call-agent.err" \
            || fail "CALL: the guest run failed (see $WORK/call-agent.err)"
        call_reap "$_pid" "$WORK/call-proxy.err"
        wait "$_pid" 2>/dev/null
        [ $? -eq 0 ] || fail "CALL: the proxy exited nonzero for --deny $1"
    }

    # ── the REAL denied run: the triple + the disagreement, joined ────────
    call_run get_weather "$WORK/call-log-deny.jsonl" "$WORK/call-data-deny"
    TR_DENY="$(ls "$WORK"/call-data-deny/sessions/*/messages.jsonl 2>/dev/null)"
    [ -f "$TR_DENY" ] || fail "CALL: no guest transcript — the run is not the real scenario"
    [ ! -e "$WORK/call-marker" ] || fail "CALL: the denied call EXECUTED (the marker is present) — this is not the denied shape"
    SHA_LOG_BEFORE="$(sha256sum "$WORK/call-log-deny.jsonl" | cut -d' ' -f1)"

    FXSTORE_BIN="$FXSTORE" "$REPORT" --store "$WORK/s1" \
        --proxy-log "$WORK/call-log-deny.jsonl" --transcript "$TR_DENY" \
        > "$WORK/out-call-deny" 2> "$WORK/out-call-deny.err"
    [ $? -eq 0 ] || fail "CALL: the joined run must report cleanly (the join fired in both directions), got $? ($(head -3 "$WORK/out-call-deny.err"))"
    # (1) THE TRIPLE, verbatim from the host log
    grep -q "^call-record${TAB}$CALLID${TAB}turn${TAB}1${TAB}true-name${TAB}get_weather${TAB}justification${TAB}$JUST${TAB}MEASURED$" "$WORK/out-call-deny" \
        || fail "CALL: the CLAIM (the justification that rode in with the call) is not surfaced verbatim"
    grep -q "^call-verdict${TAB}$CALLID${TAB}verdict${TAB}denied${TAB}author${TAB}denylist${TAB}refusal-name${TAB}denied-by-denylist${TAB}reason${TAB}" "$WORK/out-call-deny" \
        || fail "CALL: the VERDICT (with its author and its refusal name) is not surfaced"
    grep -q "^call-outcome${TAB}$CALLID${TAB}outcome${TAB}(tool call failed)${TAB}MEASURED$" "$WORK/out-call-deny" \
        || fail "CALL: the OUTCOME (the replayed function_call_output) is not surfaced"
    grep -q "^call-verdict${TAB}$CALLID${TAB}verdict${TAB}allowed" "$WORK/out-call-deny" \
        && fail "CALL: a verdict was FABRICATED for a denied call"
    # (2) THE DISAGREEMENT — the true verb vs the guest's sentinel name, same call_id
    grep -q "^call-disagreement${TAB}$CALLID${TAB}host-name${TAB}get_weather${TAB}guest-name${TAB}fx_host_denied${TAB}host-verdict${TAB}denied${TAB}host-author${TAB}denylist${TAB}host-refusal${TAB}denied-by-denylist${TAB}guest-output${TAB}(tool call failed)${TAB}DERIVED" "$WORK/out-call-deny" \
        || fail "CALL: the disagreement (the true verb vs the guest's fx_host_denied, same call_id) is not surfaced"
    # (3) the join fired BOTH directions: no absence row
    grep -q "^call-join${TAB}" "$WORK/out-call-deny" \
        && fail "CALL: a join-absence row on a run where BOTH records hold the call — the direction test is wrong"
    # (4) the reporter did NOT modify the log it reads (byte-identity)
    SHA_LOG_AFTER="$(sha256sum "$WORK/call-log-deny.jsonl" | cut -d' ' -f1)"
    [ "$SHA_LOG_BEFORE" = "$SHA_LOG_AFTER" ] || fail "CALL: the reporter MODIFIED the log it reads — byte-identity in/out is broken"

    # ── the REAL allowed run: allow_scope VERBATIM (the P8 R5 finding) ────
    call_run not_a_verb "$WORK/call-log-allowed.jsonl" "$WORK/call-data-allowed"
    TR_ACC="$(ls "$WORK"/call-data-allowed/sessions/*/messages.jsonl 2>/dev/null)"
    [ -f "$TR_ACC" ] || fail "CALL: no transcript on the allowed run"
    [ -f "$WORK/call-marker" ] || fail "CALL: the allowed call did NOT execute — this is not the allowed shape"
    FXSTORE_BIN="$FXSTORE" "$REPORT" --store "$WORK/s1" \
        --proxy-log "$WORK/call-log-allowed.jsonl" --transcript "$TR_ACC" \
        > "$WORK/out-call-acc" 2>/dev/null
    [ $? -eq 0 ] || fail "CALL: the allowed run must report cleanly"
    grep -q "^call-verdict${TAB}$CALLID${TAB}verdict${TAB}allowed${TAB}author${TAB}denylist${TAB}refusal-name${TAB}-${TAB}allow-scope${TAB}$SCOPE${TAB}MEASURED$" "$WORK/out-call-acc" \
        || fail "CALL: the allowed row's allow_scope is not carried VERBATIM (a re-derived scope is the P8 R5 defect)"
    grep -q "^call-disagreement${TAB}" "$WORK/out-call-acc" \
        && fail "CALL: a disagreement FABRICATED on an ALLOWED call (the two names agree — there is nothing to disagree about)"

    # ── THE REWRITE-MISS SHAPE: the guest recorded the TRUE name for a call
    #    the host DENIED — the silent-allow direction.  Built in a COPY of the
    #    real transcript (declared) by replacing the guest's recorded name with
    #    the host's true name, so the two names AGREE while the verdict is
    #    still denied: a second, distinct disagreement shape.
    sed 's/"name":"fx_host_denied"/"name":"get_weather"/' "$TR_DENY" > "$WORK/call-tr-crossed.jsonl"
    grep -q '"name":"get_weather"' "$WORK/call-tr-crossed.jsonl" || fail "CALL-CROSSED setup: the sed matched nothing"
    FXSTORE_BIN="$FXSTORE" "$REPORT" --store "$WORK/s1" \
        --proxy-log "$WORK/call-log-deny.jsonl" --transcript "$WORK/call-tr-crossed.jsonl" \
        > "$WORK/out-call-crossed" 2>/dev/null
    [ $? -eq 0 ] || fail "CALL-CROSSED: a rewrite miss is a RECORD, not a reporter finding (exit 0), got $?"
    grep -q "^call-disagreement${TAB}$CALLID${TAB}host-name${TAB}get_weather${TAB}guest-name${TAB}get_weather.*REWRITE MISS" "$WORK/out-call-crossed" \
        || fail "CALL-CROSSED: the guest recording the TRUE name for a DENIED call must surface as a rewrite miss"

    # ── ABSENCE, BOTH DIRECTIONS (each its OWN row + meaning + FINDING) ───
    # INJECTED into COPIES of the real records (declared): the real run joins
    # cleanly, so the one-sided cases are built.
    cp "$WORK/call-log-deny.jsonl" "$WORK/call-log-hostonly.jsonl"
    printf '%s\n' '{"ts":"2026-10-16T00:00:00Z","session":null,"run":null,"turn":9,"call_id":"call_HOSTONLY_9001","true_name":"fx_ls","args":"{}","pending":false,"outcome":"listing","verdict":"denied","author":"denylist","refusal_name":"denied-by-denylist","reason":"injected fixture row","denial_text":"(denied by host policy: injected fixture row)"}' >> "$WORK/call-log-hostonly.jsonl"
    FXSTORE_BIN="$FXSTORE" "$REPORT" --store "$WORK/s1" \
        --proxy-log "$WORK/call-log-hostonly.jsonl" --transcript "$TR_DENY" \
        > "$WORK/out-call-hostonly" 2>/dev/null
    [ $? -eq 1 ] || fail "CALL: a host-judged call the transcript does not record must be a FINDING (exit 1), got $?"
    grep -q "^call-join${TAB}call_HOSTONLY_9001${TAB}host-log-only${TAB}FINDING${TAB}bound${TAB}" "$WORK/out-call-hostonly" \
        || fail "CALL (direction 1): the host-log-only absence has no row of its own — the join that cannot fire reports NOTHING"

    cp "$TR_DENY" "$WORK/call-tr-tranonly.jsonl"
    printf '%s\n' '{"role":"assistant","content":"","tool_calls":[{"id":"call_TRANONLY_9002","name":"fx_write","arguments":"{}"}]}' >> "$WORK/call-tr-tranonly.jsonl"
    FXSTORE_BIN="$FXSTORE" "$REPORT" --store "$WORK/s1" \
        --proxy-log "$WORK/call-log-deny.jsonl" --transcript "$WORK/call-tr-tranonly.jsonl" \
        > "$WORK/out-call-tranonly" 2>/dev/null
    [ $? -eq 1 ] || fail "CALL: a transcript call the host never judged must be a FINDING (exit 1), got $?"
    grep -q "^call-join${TAB}call_TRANONLY_9002${TAB}transcript-only${TAB}FINDING${TAB}bound${TAB}" "$WORK/out-call-tranonly" \
        || fail "CALL (direction 2): the transcript-only absence has no row of its own"

    # ── a side NOT GIVEN is NOT-KNOWN, never read as a zero ───────────────
    FXSTORE_BIN="$FXSTORE" "$REPORT" --store "$WORK/s1" \
        --proxy-log "$WORK/call-log-deny.jsonl" > "$WORK/out-call-one" 2>/dev/null
    [ $? -eq 0 ] || fail "CALL: a one-sided join must not fabricate findings, got $?"
    grep -q "^absence${TAB}transcript${TAB}not-given-the-guest-transcript" "$WORK/out-call-one" \
        || fail "CALL: a NOT-given side must read NOT-KNOWN, not 'no call recorded'"
    grep -q "^call-join${TAB}" "$WORK/out-call-one" \
        && fail "CALL: with no transcript the join's guest direction is NOT-KNOWN — a per-call absence row would be a fabricated measurement"

    # ── NO FABRICATED VERDICT: a row with no verdict field (no policy ran)
    #    reads NOT-RECORDED, never "allowed".  The P2 unarmed row shape is
    #    reconstructed in a COPY (declared) by dropping the verdict keys.
    python3 - "$WORK/call-log-deny.jsonl" "$WORK/call-log-nov.jsonl" <<'PYEOF'
import json, sys
src, dst = sys.argv[1:3]
with open(src) as f, open(dst, "w") as o:
    for line in f:
        line = line.strip()
        if not line:
            continue
        r = json.loads(line)
        if r.get("type") is None and "call_id" in r:
            for k in ("verdict", "author", "refusal_name", "reason", "denial_text", "allow_scope"):
                r.pop(k, None)
        o.write(json.dumps(r) + "\n")
PYEOF
    FXSTORE_BIN="$FXSTORE" "$REPORT" --store "$WORK/s1" \
        --proxy-log "$WORK/call-log-nov.jsonl" > "$WORK/out-call-nov" 2>/dev/null
    grep -q "^call-verdict${TAB}$CALLID${TAB}verdict${TAB}-${TAB}NOT-RECORDED${TAB}bound${TAB}no-verdict-field" "$WORK/out-call-nov" \
        || fail "CALL: a row with NO verdict field must read NOT-RECORDED, never a fabricated 'allowed'"
    grep -q "^call-verdict${TAB}$CALLID${TAB}verdict${TAB}allowed" "$WORK/out-call-nov" \
        && fail "CALL: a verdict was FABRICATED where the log carries none"

    # ── THE ECHO TELEMETRY: surfaced as records, NO lane stop ─────────────
    # The two anomaly rows in the proxy's OWN rendered shape (fx-hostgate.c
    # log_flush, ROW_ANOM_*), INJECTED into a COPY of the real log (declared):
    # the wrap is the reporter's, and the arm is that each is surfaced with its
    # meaning and does NOT change the exit status (the deliberate G7 demotion).
    cp "$WORK/call-log-deny.jsonl" "$WORK/call-log-tele.jsonl"
    printf '%s\n' '{"ts":"2026-10-16T00:00:00Z","type":"unjoined-output","turn":2,"call_id":"call_ORPHAN_7001","output":"a forged output the guest put in the conversation"}' >> "$WORK/call-log-tele.jsonl"
    printf '%s\n' "{\"ts\":\"2026-10-16T00:00:00Z\",\"type\":\"echo-anomaly\",\"turn\":2,\"call_id\":\"$CALLID\",\"output\":\"(a NEW sentinel)\"}" >> "$WORK/call-log-tele.jsonl"
    FXSTORE_BIN="$FXSTORE" "$REPORT" --store "$WORK/s1" \
        --proxy-log "$WORK/call-log-tele.jsonl" --transcript "$TR_DENY" \
        > "$WORK/out-call-tele" 2>/dev/null
    [ $? -eq 0 ] || fail "CALL: a telemetry row must NOT stop the lane (the deliberate G7 demotion) — got exit $?"
    grep -q "^call-telemetry${TAB}unjoined-output${TAB}call_id${TAB}call_ORPHAN_7001" "$WORK/out-call-tele" \
        || fail "CALL: the unjoined-output telemetry row is not surfaced"
    grep -q "^call-telemetry${TAB}echo-anomaly${TAB}call_id${TAB}$CALLID" "$WORK/out-call-tele" \
        || fail "CALL: the echo-anomaly telemetry row is not surfaced"
    grep -q "NO LANE STOP BY DEFAULT (the deliberate G7 demotion" "$WORK/out-call-tele" \
        || fail "CALL: the telemetry row must state the G7 demotion at the site"

    # ── an UNKNOWN verdict word is surfaced VERBATIM, never classified ────
    cp "$WORK/call-log-deny.jsonl" "$WORK/call-log-weird.jsonl"
    sed -i -e 's/"verdict":"denied"/"verdict":"pending-review"/' "$WORK/call-log-weird.jsonl"
    grep -q "pending-review" "$WORK/call-log-weird.jsonl" || fail "CALL-UNKNOWN setup: the sed matched nothing"
    FXSTORE_BIN="$FXSTORE" "$REPORT" --store "$WORK/s1" \
        --proxy-log "$WORK/call-log-weird.jsonl" --transcript "$TR_DENY" > "$WORK/out-call-weird" 2>/dev/null
    [ $? -eq 0 ] || fail "CALL-UNKNOWN: an unknown verdict word is a record, not a finding"
    grep -q "^call-verdict${TAB}$CALLID${TAB}verdict${TAB}pending-review${TAB}" "$WORK/out-call-weird" \
        || fail "CALL-UNKNOWN: an unknown verdict word must surface VERBATIM"
    grep -q "^call-verdict${TAB}$CALLID${TAB}verdict${TAB}pending-review.*note${TAB}verdict-vocabulary-not-known" "$WORK/out-call-weird" \
        || fail "CALL-UNKNOWN: the not-classified note is missing"
    grep -q "^call-verdict${TAB}$CALLID${TAB}verdict${TAB}allowed" "$WORK/out-call-weird" \
        && fail "CALL-UNKNOWN: the seat CLASSIFIED a verdict word it does not own"

    # ── LOUD: a log line that is not the grammar is exit 2, never skipped ─
    cp "$WORK/call-log-deny.jsonl" "$WORK/call-log-corrupt.jsonl"
    printf '%s\n' 'this is not a json row' >> "$WORK/call-log-corrupt.jsonl"
    FXSTORE_BIN="$FXSTORE" "$REPORT" --store "$WORK/s1" \
        --proxy-log "$WORK/call-log-corrupt.jsonl" > "$WORK/out-call-corrupt" 2>"$WORK/out-call-corrupt.err"
    [ $? -eq 2 ] || fail "CALL-LOUD: a host-log row that is not JSON must be exit 2, got $?"
    grep -q "not JSON" "$WORK/out-call-corrupt.err" || fail "CALL-LOUD: the refusal does not name the cause"
    cp "$WORK/call-log-deny.jsonl" "$WORK/call-log-newtype.jsonl"
    printf '%s\n' '{"ts":"2026-10-16T00:00:00Z","type":"some-future-row","turn":2}' >> "$WORK/call-log-newtype.jsonl"
    FXSTORE_BIN="$FXSTORE" "$REPORT" --store "$WORK/s1" \
        --proxy-log "$WORK/call-log-newtype.jsonl" > "$WORK/out-call-newtype" 2>"$WORK/out-call-newtype.err"
    [ $? -eq 2 ] || fail "CALL-LOUD: an unknown host-log row type must be exit 2, got $?"
    grep -q "unknown row type \"some-future-row\"" "$WORK/out-call-newtype.err" \
        || fail "CALL-LOUD: the refusal does not name the unknown type"

    # ── MUT-CALL-* : each mutant must make ITS OWN passing arm go blind ───
    # MUT-CALL-JOIN (the join that cannot fire reports nothing): the join
    # emission disabled — the ABSENCE arms must go blind.
    mutbuild calljoin 's/call-join/join-disabled/'
    FXSTORE_BIN="$FXSTORE" "$REPO/build/fx-report-calljoin" --store "$WORK/s1" \
        --proxy-log "$WORK/call-log-hostonly.jsonl" --transcript "$TR_DENY" > "$WORK/out-mutcalljoin" 2>/dev/null
    grep -q "^call-join${TAB}call_HOSTONLY_9001" "$WORK/out-mutcalljoin" \
        && fail "MUT-CALL-JOIN: the absence arm still passes with the join emission disabled — the assertion is not load-bearing"

    # MUT-CALL-CLASSIFY (a vocabulary the seat does not own): an unknown
    # verdict word becomes "allowed".
    mutbuild callclassify 's/static const char \*call_verdict_word(const char \*v) { return v; }/static const char *call_verdict_word(const char *v) { return (v \&\& !strcmp(v, "denied")) ? v : "allowed"; }/'
    FXSTORE_BIN="$FXSTORE" "$REPO/build/fx-report-callclassify" --store "$WORK/s1" \
        --proxy-log "$WORK/call-log-weird.jsonl" --transcript "$TR_DENY" > "$WORK/out-mutcallclassify" 2>/dev/null
    grep -q "^call-verdict${TAB}$CALLID${TAB}verdict${TAB}pending-review" "$WORK/out-mutcallclassify" \
        && fail "MUT-CALL-CLASSIFY: the unknown word still surfaces verbatim — the sed removed nothing (the arm is not load-bearing)"
    grep -q "^call-verdict${TAB}$CALLID${TAB}verdict${TAB}allowed" "$WORK/out-mutcallclassify" \
        || fail "MUT-CALL-CLASSIFY: the mutant did not reproduce the classification error the arm refuses"

    # MUT-CALL-SCOPE (the P8 R5 re-derivation): allow_scope recomputed by the
    # reporter instead of carried.
    mutbuild callscope 's/static const char \*call_scope_text(const hostcall_t \*H) { return H->allow_scope; }/static const char *call_scope_text(const hostcall_t *H) { (void)H; return "seat-scoped: RECOMPUTED by the reporter"; }/'
    FXSTORE_BIN="$FXSTORE" "$REPO/build/fx-report-callscope" --store "$WORK/s1" \
        --proxy-log "$WORK/call-log-allowed.jsonl" --transcript "$TR_ACC" > "$WORK/out-mutcallscope" 2>/dev/null
    grep -q "^call-verdict${TAB}$CALLID${TAB}verdict${TAB}allowed.*allow-scope${TAB}$SCOPE" "$WORK/out-mutcallscope" \
        && fail "MUT-CALL-SCOPE: the allow_scope-verbatim assertion still passes with the scope re-derived — the arm is not load-bearing"
    grep -q "RECOMPUTED by the reporter" "$WORK/out-mutcallscope" \
        || fail "MUT-CALL-SCOPE: the mutant did not reproduce the re-derivation the arm refuses"
fi

    # ══ S4: THE EXEC DIMENSION — who RAN the call ═════════════════════════
    # §7.1a: an egress grant is a CAPABILITY INCREASE, so a report that cannot
    # tell a host-executed call from a guest one is blind to exactly that.
    # The arm drives a REAL host_time call (the proxy's own S1 host tool, no
    # arguments) through the same harness: the host executes, the guest sees
    # the call and its sentinel, and the log row carries `exec`:"host".
    cp "$REPO/tests/fixtures/responses_host_time.sse" "$WORK/call-host.sse" \
        || fail "EXEC: cannot copy the host_time fixture"
    call_run fx_write "$WORK/call-log-host.jsonl" "$WORK/call-data-host" "$WORK/call-host.sse"
    TR_HOST="$(ls "$WORK"/call-data-host/sessions/*/messages.jsonl 2>/dev/null)"
    [ -f "$TR_HOST" ] || fail "EXEC: no guest transcript for the host-executed run"
    grep -q '"exec":"host"' "$WORK/call-log-host.jsonl" \
        || fail "EXEC: the proxy did not write the exec field — this is not the host-executed shape"
    FXSTORE_BIN="$FXSTORE" "$REPORT" --store "$WORK/s1" \
        --proxy-log "$WORK/call-log-host.jsonl" --transcript "$TR_HOST" \
        > "$WORK/out-call-host" 2>"$WORK/out-call-host.err"
    [ $? -eq 0 ] || fail "EXEC: the host-executed run must report cleanly, got $? ($(head -3 "$WORK/out-call-host.err"))"
    grep -q "^call-exec${TAB}$CALLID${TAB}exec${TAB}host${TAB}sandbox${TAB}.*MEASURED" "$WORK/out-call-host" \
        || fail "EXEC: a HOST-executed call is not distinguishable in the report"
    # S4 (palisade): THE SANDBOX IS A COLUMN of the same row ($7.1a: a spec IS
    # a capability declaration), and it is the spec the spawn APPLIED —
    # promises plus the effective landlock, carried VERBATIM from the log.
    grep -q "^call-exec${TAB}$CALLID${TAB}exec${TAB}host${TAB}sandbox${TAB}stdio rpath exec prot_exec .*fx-host-time:rx" "$WORK/out-call-host" \
        || fail "SANDBOX: the applied sandbox spec is not a column of the call-exec row: $(grep -m1 '^call-exec' "$WORK/out-call-host")"
    grep -q "^call-exec${TAB}$CALLID${TAB}exec${TAB}guest${TAB}sandbox${TAB}-${TAB}DERIVED" "$WORK/out-call-deny" \
        || fail "EXEC: a GUEST-executed call is not identified as such (the dimension must read both ways)"
    grep -q "^call-exec${TAB}$CALLID${TAB}exec${TAB}host" "$WORK/out-call-deny" \
        && fail "EXEC: a guest call was reported as host-executed — the shape is being inferred, not read"
    echo "test_fx_report: S4-EXEC the executed side is in the report, both ways (host MEASURED from the row's own field, guest DERIVED from the writer's grammar)"

    # ══ S4: THE REACH CLASS — the WEAKENED declared-vs-observed audit ═════
    # DECLARED = the operator's PINNED class tables + PINS; OBSERVED = the one
    # log's rows.  The two findings are its own rows with their own meanings:
    # stale-class-row (a STALE GRANT) and pin-drift (the table judged against
    # is not the table pinned).  NOT the type-enforced audit — the rows, the
    # bound and the taxonomy say so, and this gate reads that statement back.
    RPOL="$WORK/reach-pol"
    cp -r "$REPO/policy/ops" "$RPOL" || fail "REACH: cannot copy the pinned tables"
    report_reach() { # report_reach OUT POLICYDIR [args...] -> rc on stdout
        _o="$1"; _p="$2"; shift 2
        FXSTORE_BIN="$FXSTORE" "$REPORT" --store "$WORK/s1" --policy-dir "$_p" "$@" \
            > "$_o" 2>"$_o.err"
        echo $?
    }

    # (a) DECLARED == PINNED: every artifact MATCHes its pin, so there is NO
    # pin-drift; the log's calls consume no class row (get_weather is not a
    # tool the tables judge and host_time declares no classed argument), so
    # every row is a STALE GRANT and each one is its own FINDING.
    rc=$(report_reach "$WORK/out-reach-a" "$RPOL" \
            --proxy-log "$WORK/call-log-host.jsonl" \
            --class-arg path:host_cat=path)
    [ "$rc" = "1" ] || fail "REACH(a): stale grants are FINDINGS — expected exit 1, got $rc"
    for _f in ops-policy.dl ops-aliases.tsv ops-hosts.tsv ops-lexicon.ini; do
        grep -q "^reach-pin${TAB}$_f${TAB}sha${TAB}[0-9a-f]*${TAB}pinned${TAB}[0-9a-f]*${TAB}MATCH${TAB}MEASURED" "$WORK/out-reach-a" \
            || fail "REACH(a): $_f is not reported as matching its PIN"
    done
    grep -q "^pin-drift${TAB}" "$WORK/out-reach-a" \
        && fail "REACH(a): a pin-drift was FABRICATED on tables that hash to their PINS"
    grep -q "^stale-class-row${TAB}ops-aliases.tsv${TAB}line${TAB}[0-9]*${TAB}dimension${TAB}path" "$WORK/out-reach-a" \
        || fail "REACH(a): a pinned path class no observed call exercised is not a stale-class-row FINDING"
    # S3 (REVISED): the AUTHORITY dimension has NO consumer (http_get was
    # dropped; ops-hosts.tsv ships EMPTY), so no authority reach-row is emitted
    # — the absence is itself the re-pointed assertion (the reach-row mechanism
    # is still exercised by the path rows above).
    grep -q "^reach-row${TAB}ops-hosts.tsv${TAB}" "$WORK/out-reach-a" \
        && fail "REACH(a): an authority reach-row was emitted from an EMPTY authority table"
    grep -q 'a STALE GRANT' "$WORK/out-reach-a" || fail "REACH(a): the finding does not state what it means"
    grep -q 'WEAKENED AUDIT, stated' "$WORK/out-reach-a" \
        || fail "REACH(a): the finding does not state that this is the WEAKENED audit (not the type-enforced one)"
    grep -q "^bound${TAB}reach-audit-is-the-weakened-one" "$WORK/out-reach-a" \
        || fail "REACH(a): the bound that names the weakening is not printed"
    echo "test_fx_report: S4-REACH(a) every pinned artifact MATCHes, the class rows no call exercised are STALE GRANTS, and each row states the weakening"

    # (b) THE EXERCISED DIRECTION (the other side of the same rows).  A real
    # host_cat call would need the ops seat armed end-to-end (test_hostgate
    # owns that); here the OBSERVED side is a DECLARED COPY of the real log
    # with one row's name and args replaced by a pinned path — the writer's
    # exact row shape, one field pair changed, and stated as such.
    python3 - "$WORK/call-log-host.jsonl" "$WORK/call-log-exercised.jsonl" <<'PYCOPY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
n = 0
with open(src) as f, open(dst, "w") as o:
    for line in f:
        line = line.strip()
        if not line:
            continue
        r = json.loads(line)
        if n == 0 and "call_id" in r and "type" not in r:
            r["true_name"] = "host_cat"
            r["args"] = json.dumps({"path": "/fx/disk//agent-config.dhall",
                                    "justification": "the declared-copy arm"})
            n += 1
        o.write(json.dumps(r) + "\n")
sys.exit(0 if n else 1)
PYCOPY
    [ $? -eq 0 ] || fail "REACH(b) SETUP: the log copy carries no call row to rewrite"
    rc=$(report_reach "$WORK/out-reach-b" "$RPOL" \
            --proxy-log "$WORK/call-log-exercised.jsonl" \
            --class-arg path:host_cat=path)
    grep -q "^reach-row${TAB}ops-aliases.tsv${TAB}line${TAB}[0-9]*${TAB}dimension${TAB}path${TAB}pattern${TAB}/fx/disk/agent-config.dhall${TAB}class${TAB}Configpath${TAB}protected${TAB}yes${TAB}exercised${TAB}YES${TAB}DERIVED" "$WORK/out-reach-b" \
        || fail "REACH(b): the exercised row does not read YES (the //-spelling must canonicalize, as the seat's own matcher does)"
    grep -q "^stale-class-row${TAB}ops-aliases.tsv${TAB}line${TAB}[0-9]*${TAB}dimension${TAB}path${TAB}pattern${TAB}/fx/disk/agent-data" "$WORK/out-reach-b" \
        || fail "REACH(b): the OTHER row went stale-quiet — the exercised direction is reading every row as used"
    echo "test_fx_report: S4-REACH(b) the exercised direction reads YES for a consumed row and the untouched row still reads STALE"

    # (c) THE TWO DIRECTIONS OF ABSENCE — nothing is ever read as 'none'.
    rc=$(report_reach "$WORK/out-reach-c" "$RPOL")
    [ "$rc" = "0" ] || fail "REACH(c): with NO observed side there is no finding to raise — got exit $rc"
    grep -q "^reach-row${TAB}.*${TAB}exercised${TAB}NOT-KNOWN${TAB}ABSENT" "$WORK/out-reach-c" \
        || fail "REACH(c): with no log the rows are not NOT-KNOWN"
    grep -q "^stale-class-row" "$WORK/out-reach-c" \
        && fail "REACH(c): a stale grant was reported with NO observed side — a missing log read as 'nothing was called'"
    rc=$(report_reach "$WORK/out-reach-c2" "$WORK/no-such-policy" --proxy-log "$WORK/call-log-host.jsonl")
    grep -q "^absence${TAB}reach-pins" "$WORK/out-reach-c2" \
        || fail "REACH(c): a --policy-dir with no PINS in it does not say the pin direction is NOT-KNOWN"
    grep -q "^absence${TAB}reach-tables" "$WORK/out-reach-c2" \
        || fail "REACH(c): a --policy-dir with no class tables in it reads as 'no class is granted'"
    grep -q "^reach-row${TAB}" "$WORK/out-reach-c2" \
        && fail "REACH(c): class rows were reported with NO declared side"
    grep -q "^pin-drift${TAB}" "$WORK/out-reach-c2" \
        && fail "REACH(c): a pin-drift was reported with NO PINS file — an unreadable release is not a drift either"
    rc=$(FXSTORE_BIN="$FXSTORE" "$REPORT" --store "$WORK/s1" --proxy-log "$WORK/call-log-host.jsonl" \
            > "$WORK/out-reach-c4" 2>/dev/null; echo $?)
    grep -q "^absence${TAB}reach-declared" "$WORK/out-reach-c4" \
        || fail "REACH(c): no --policy-dir at all is not its own absence record (the DECLARED side is NOT-KNOWN, never 'nothing is granted')"
    rc=$(report_reach "$WORK/out-reach-c3" "$RPOL" --proxy-log "$WORK/call-log-host.jsonl")
    grep -q "^absence${TAB}reach-class-arg" "$WORK/out-reach-c3" \
        || fail "REACH(c): no --class-arg is not named as an absence (an unmapped dimension is NOT 'no classed argument')"
    grep -q "^stale-class-row" "$WORK/out-reach-c3" \
        && fail "REACH(c): rows went STALE with no mapping declared — an unattributable dimension is NOT-KNOWN"
    echo "test_fx_report: S4-REACH(c) BOTH absence directions are NOT-KNOWN and each is its own absence record (no log, no policy dir, no --class-arg)"

    # (d) PIN-DRIFT IS ITS OWN FINDING: an edit nobody re-pinned.  Built in a
    # COPY (the shared policy/ops is never touched).
    cp -r "$RPOL" "$WORK/reach-pol-drift"
    printf 'evil.example.com\tEvil\tno\n' >> "$WORK/reach-pol-drift/ops-hosts.tsv"
    rc=$(report_reach "$WORK/out-reach-d" "$WORK/reach-pol-drift" \
            --proxy-log "$WORK/call-log-host.jsonl" \
            --class-arg path:host_cat=path)
    [ "$rc" = "1" ] || fail "REACH(d): pin-drift is a FINDING — expected exit 1, got $rc"
    grep -q "^reach-pin${TAB}ops-hosts.tsv${TAB}sha${TAB}[0-9a-f]*${TAB}pinned${TAB}[0-9a-f]*${TAB}DRIFT" "$WORK/out-reach-d" \
        || fail "REACH(d): the drifted artifact does not read DRIFT in its own reach-pin row"
    grep -q "^pin-drift${TAB}ops-hosts.tsv${TAB}sha${TAB}[0-9a-f]*${TAB}pinned${TAB}[0-9a-f]*${TAB}FINDING" "$WORK/out-reach-d" \
        || fail "REACH(d): the drifted artifact is not a pin-drift FINDING"
    grep -q "^reach-pin${TAB}ops-aliases.tsv${TAB}sha${TAB}[0-9a-f]*${TAB}pinned${TAB}[0-9a-f]*${TAB}MATCH" "$WORK/out-reach-d" \
        || fail "REACH(d): the UNTOUCHED artifact stopped matching — the drift is being reported for everything"
    echo "test_fx_report: S4-REACH(d) an edit nobody re-pinned is pin-drift, with BOTH pins, and it does not smear onto the untouched tables"

    # (e) THE MUTANTS — one per new property, each from the SAME source.
    # MUT-EXEC: the carried exec field is ignored, so a host call reads guest
    # (the §7.1a blindness: the report cannot see the grant).
    mutbuild exec 's/H->exec = ex ? xstrdup(ex) : NULL;/H->exec = NULL; (void)ex;/'
    FXSTORE_BIN="$FXSTORE" "$REPO/build/fx-report-exec" --store "$WORK/s1" \
        --proxy-log "$WORK/call-log-host.jsonl" --transcript "$TR_HOST" > "$WORK/out-mutexec" 2>/dev/null
    grep -q "^call-exec${TAB}$CALLID${TAB}exec${TAB}host" "$WORK/out-mutexec" \
        && fail "MUT-EXEC: the host call still reads host with the exec field ignored — the arm is not load-bearing"
    grep -q "^call-exec${TAB}$CALLID${TAB}exec${TAB}guest" "$WORK/out-mutexec" \
        || fail "MUT-EXEC: the mutant did not reproduce the blindness the arm refuses"

    # MUT-REACH: the stale-class-row emission is renamed, so a stale GRANT
    # stops being a finding.
    mutbuild reach 's/printf("stale-class-row\\t%s\\tline/printf("disabled-stale-class-row\\t%s\\tline/'
    FXSTORE_BIN="$FXSTORE" "$REPO/build/fx-report-reach" --store "$WORK/s1" --policy-dir "$RPOL" \
        --proxy-log "$WORK/call-log-host.jsonl" --class-arg path:host_cat=path \
        > "$WORK/out-mutreach" 2>/dev/null
    grep -q "^stale-class-row${TAB}" "$WORK/out-mutreach" \
        && fail "MUT-REACH: the stale-grant arm still passes with its row disabled — the finding is decoration"

    # MUT-PINDRIFT (THE MANDATED BLIND): the seat joins on the DRIFTED pin —
    # it compares the value on disk with itself instead of with PINS, so the
    # drift VANISHES.  An instrument that cannot see a table nobody released is
    # the quiet widening this whole slice exists to prevent.
    mutbuild pindrift 's/} else if (strcmp(P->got, P->want) != 0) {/} else if (strcmp(P->got, P->got) != 0) {/'
    FXSTORE_BIN="$FXSTORE" "$REPO/build/fx-report-pindrift" --store "$WORK/s1" --policy-dir "$WORK/reach-pol-drift" \
        --proxy-log "$WORK/call-log-host.jsonl" --class-arg path:host_cat=path \
        > "$WORK/out-mutpindrift" 2>/dev/null
    grep -q "^pin-drift${TAB}" "$WORK/out-mutpindrift" \
        && fail "MUT-PINDRIFT: the join-on-the-drifted-pin build STILL reports the drift — the arm is not load-bearing"
    # the READING survives the mutant and the JUDGEMENT does not, which is the
    # exact failure: the reach-pin row still says DRIFT while no finding is
    # raised from it — a reader who trusts the findings is now blind.
    grep -q "^reach-pin${TAB}ops-hosts.tsv${TAB}sha${TAB}[0-9a-f]*${TAB}pinned${TAB}[0-9a-f]*${TAB}DRIFT" "$WORK/out-mutpindrift" \
        || fail "MUT-PINDRIFT: the mutant lost the pin READING too — this control is meant to blind the FINDING only, so the two must be independent"
    echo "test_fx_report: S4-MUTANTS each new property blinds its own arm: the exec field ignored (host reads guest), the stale-grant row disabled, and the pin joined on the DRIFTED value (the reach-pin row still reads DRIFT and NO finding follows — the quiet widening)"

    # ══ S4 (PALISADE): THE SANDBOX CLASS — a spec IS a capability change ══
    # §7.1a at the layer S3 made structural: every host spawn is wrapped, the
    # executor owns the BASELINE, a tool may declare MORE via a sidecar, and
    # the operator table may only TIGHTEN.  The class carries the applied spec
    # as a COLUMN of the call rows, then compares the DECLARED composition
    # (--proxy --print-sandbox) against the RECORDED specs (the log) and pins
    # the one pinned half.  A real widening is constructed in a COPY of the
    # proxy (a sidecar) and each seat must NAME it.
    sb_report() { # sb_report OUT [args...] -> rc on stdout
        _o="$1"; shift
        FXSTORE_BIN="$FXSTORE" "$REPORT" --store "$WORK/s1" "$@" > "$_o" 2>"$_o.err"
        echo $?
    }
    # (a) THE AGREED STATE: the composition the proxy declares now IS the spec
    # the recorded call applied (same build, no sidecar), so the delta reads
    # NONE — the negative direction, and it is what makes (c) mean anything.
    rc=$(sb_report "$WORK/out-sb-a" --proxy "$REPO/build/fx-hostgate" \
            --proxy-log "$WORK/call-log-host.jsonl" --policy-dir "$RPOL")
    [ "$rc" = "0" ] || fail "S4-SANDBOX(a): the agreeing state must report cleanly, got $rc ($(grep -m2 'sandbox-' "$WORK/out-sb-a"))"
    grep -q "^sandbox-composed${TAB}host_time${TAB}promises${TAB}stdio rpath exec prot_exec${TAB}landlock${TAB}" "$WORK/out-sb-a" \
        || fail "S4-SANDBOX(a): the composed spec per tool is not declared in the report"
    grep -q "^sandbox-recorded${TAB}host_time${TAB}calls${TAB}1${TAB}promises${TAB}stdio rpath exec prot_exec${TAB}" "$WORK/out-sb-a" \
        || fail "S4-SANDBOX(a): the spec the recorded call APPLIED is not surfaced"
    grep -q "^sandbox-pin${TAB}ops-sandbox.tsv${TAB}sha${TAB}[0-9a-f]*${TAB}pin${TAB}[0-9a-f]*${TAB}MATCH${TAB}MEASURED" "$WORK/out-sb-a" \
        || fail "S4-SANDBOX(a): the operator sandbox table is not reported against its PIN"
    grep -q "^sandbox-delta${TAB}-${TAB}NONE${TAB}DERIVED" "$WORK/out-sb-a" \
        || fail "S4-SANDBOX(a): the agreeing state did not read NONE: $(grep -m1 '^sandbox-delta' "$WORK/out-sb-a")"
    grep -q "^sandbox-widened-since-record" "$WORK/out-sb-a" \
        && fail "S4-SANDBOX(a): a sandbox widening was FABRICATED where nothing changed"
    # the PER-TOOL blind is NAMED, not left to be discovered: host_cat is
    # declared and the log recorded no call for it, so it cannot be compared
    # HERE (fx-audit's per-boot record covers it).
    grep -q "^sandbox-delta${TAB}host_cat${TAB}NOT-KNOWN${TAB}ABSENT" "$WORK/out-sb-a" \
        || fail "S4-SANDBOX(a): a declared tool with no recorded call is not named as NOT-KNOWN"
    grep -q "^bound${TAB}sandbox-audit-is-the-weakened-one" "$WORK/out-sb-a" \
        || fail "S4-SANDBOX(a): the bound naming the sandbox audit as WEAKENED is not printed"
    echo "test_fx_report: S4-SANDBOX(a) the composed spec, the recorded spec and the operator pin are all surfaced, and the agreeing state reads NONE (both directions)"

    # (b) THE TWO DIRECTIONS OF ABSENCE — nothing is ever read as 'unchanged'.
    rc=$(sb_report "$WORK/out-sb-b1" --proxy-log "$WORK/call-log-host.jsonl")
    grep -q "^absence${TAB}sandbox-composed" "$WORK/out-sb-b1" \
        || fail "S4-SANDBOX(b): no --proxy is not its own absence record (the DECLARED side is NOT-KNOWN, never 'unchanged')"
    grep -q "^absence${TAB}sandbox-pin" "$WORK/out-sb-b1" \
        || fail "S4-SANDBOX(b): no --policy-dir is not its own absence record for the pin"
    rc=$(sb_report "$WORK/out-sb-b2" --proxy "$REPO/build/fx-hostgate" --policy-dir "$RPOL")
    grep -q "^absence${TAB}sandbox-recorded" "$WORK/out-sb-b2" \
        || fail "S4-SANDBOX(b): no --proxy-log is not its own absence record (the RECORDED side is NOT-KNOWN)"
    grep -q "^sandbox-delta${TAB}-${TAB}NOT-KNOWN" "$WORK/out-sb-b2" \
        || fail "S4-SANDBOX(b): a delta was computed with NO recorded side"
    grep -q "^sandbox-delta${TAB}host_time${TAB}WIDER" "$WORK/out-sb-b2" \
        && fail "S4-SANDBOX(b): a widening was reported with NO recorded side"
    mkdir -p "$WORK/sb-nopins"
    cp "$RPOL/ops-sandbox.tsv" "$WORK/sb-nopins/" || fail "S4-SANDBOX(b) SETUP: cp"
    rc=$(sb_report "$WORK/out-sb-b3" --proxy "$REPO/build/fx-hostgate" \
            --proxy-log "$WORK/call-log-host.jsonl" --policy-dir "$WORK/sb-nopins")
    grep -q "^absence${TAB}sandbox-pin${TAB}not-durably-recorded" "$WORK/out-sb-b3" \
        || fail "S4-SANDBOX(b): a --policy-dir with no PINS does not say the pin direction is NOT-KNOWN"
    echo "test_fx_report: S4-SANDBOX(b) each missing side is its own absence record: no proxy, no log, no PINS — never 'unchanged'"

    # (c) A REAL SANDBOX WIDENING, CONSTRUCTED AND NAMED.  The widening is a
    # SIDECAR beside a COPY of the proxy (the shared build/ is never touched):
    # fx-host-time gains `inet` and one landlock entry.  The proxy is the real
    # binary, the composition is the real composition, and the record is the
    # real log from the exec arm above.
    mkdir -p "$WORK/sbproxy" || fail "S4-SANDBOX(c) SETUP: mkdir"
    cp "$REPO/build/fx-hostgate" "$WORK/sbproxy/fx-hostgate" || fail "S4-SANDBOX(c) SETUP: cp proxy"
    printf 'inet\t/tmp/sb-extra:r' > "$WORK/sbproxy/fx-host-time.sidecar" \
        || fail "S4-SANDBOX(c) SETUP: cannot write the sidecar"
    "$WORK/sbproxy/fx-hostgate" --print-sandbox 2>/dev/null | grep -q "^host_time${TAB}stdio rpath exec prot_exec inet${TAB}" \
        || fail "S4-SANDBOX(c) SETUP: the widened copy does not declare the extra promise — the fixture is not a widening"
    rc=$(sb_report "$WORK/out-sb-c" --proxy "$WORK/sbproxy/fx-hostgate" \
            --proxy-log "$WORK/call-log-host.jsonl" --policy-dir "$RPOL")
    [ "$rc" = "1" ] || fail "S4-SANDBOX(c): a sandbox WIDENING is a FINDING — expected exit 1, got $rc"
    grep -q "^sandbox-delta${TAB}host_time${TAB}WIDER${TAB}DERIVED.*promise(s) added \"inet\"" "$WORK/out-sb-c" \
        || fail "S4-SANDBOX(c): the added promise is not NAMED on a WIDER sandbox-delta row"
    grep -q "^sandbox-delta${TAB}host_time${TAB}WIDER${TAB}DERIVED.*landlock entr(y/ies) added \"/tmp/sb-extra:r\"" "$WORK/out-sb-c" \
        || fail "S4-SANDBOX(c): the added landlock entry is not NAMED on the widening row"
    grep -q "^sandbox-widened-since-record${TAB}host_time${TAB}FINDING" "$WORK/out-sb-c" \
        || fail "S4-SANDBOX(c): the widening is not its own FINDING"
    grep -q "UNPINNED" "$WORK/out-sb-c" \
        || fail "S4-SANDBOX(c): the finding does not say WHY no release can license it (the sidecar/baseline are unpinned)"
    grep -q "^sandbox-change-note" "$WORK/out-sb-c" \
        || fail "S4-SANDBOX(c): the change is not tallied"
    echo "test_fx_report: S4-SANDBOX(c) a constructed sidecar widening (inet + a landlock entry) is NAMED row by row and is a FINDING"

    # (d) THE OPERATOR TABLE'S PIN IS ITS OWN FINDING, in a COPY (the shared
    # policy/ops is only ever READ).
    cp -r "$RPOL" "$WORK/sb-pol-drift" || fail "S4-SANDBOX(d) SETUP: cp"
    printf '# an edit nobody re-pinned\n' >> "$WORK/sb-pol-drift/ops-sandbox.tsv" \
        || fail "S4-SANDBOX(d) SETUP: cannot append"
    rc=$(sb_report "$WORK/out-sb-d" --proxy "$REPO/build/fx-hostgate" \
            --proxy-log "$WORK/call-log-host.jsonl" --policy-dir "$WORK/sb-pol-drift")
    [ "$rc" = "1" ] || fail "S4-SANDBOX(d): an unreleased operator sandbox table is a FINDING — got $rc"
    grep -q "^sandbox-pin${TAB}ops-sandbox.tsv${TAB}sha${TAB}[0-9a-f]*${TAB}pin${TAB}[0-9a-f]*${TAB}DRIFT" "$WORK/out-sb-d" \
        || fail "S4-SANDBOX(d): the drifted operator table does not read DRIFT in its own row"
    grep -q "^sandbox-pin-drift${TAB}ops-sandbox.tsv${TAB}.*FINDING" "$WORK/out-sb-d" \
        || fail "S4-SANDBOX(d): the drifted operator table is not its own FINDING with both pins"
    grep -q "^sandbox-delta${TAB}-${TAB}NONE" "$WORK/out-sb-d" \
        || fail "S4-SANDBOX(d): the operator drift smeared onto the SPEC comparison (the two are different questions)"
    echo "test_fx_report: S4-SANDBOX(d) the operator sandbox table against PINS is its own DRIFT finding, and it does not smear onto the spec comparison"

    # (e) THE MUTANTS, each from the SAME source, each proven to make a PASSING
    # arm go blind.  MUT-SB-SPEC is THE MANDATED ONE: the comparison is made
    # against TODAY'S PROXY instead of the RECORDED spec (the addition is
    # re-derived from the live composition, so there is nothing to compare) —
    # the widening VANISHES and the gate must catch it.
    mutbuild sbspec 's/int has_add = added_tok\[0\] || added_lk\[0\];/int has_add = 0; (void)added_tok; (void)added_lk;/'
    grep -q "int has_add = 0;" "$WORK/mut-sbspec.c" \
        || fail "MUT-SB-SPEC: the sed did not land (check the source text)"
    FXSTORE_BIN="$FXSTORE" "$REPO/build/fx-report-sbspec" --store "$WORK/s1" \
        --proxy "$WORK/sbproxy/fx-hostgate" --proxy-log "$WORK/call-log-host.jsonl" \
        --policy-dir "$RPOL" > "$WORK/out-mutsbspec" 2>/dev/null
    grep -q "^sandbox-delta${TAB}host_time${TAB}WIDER" "$WORK/out-mutsbspec" \
        && fail "MUT-SB-SPEC: the blind build STILL names the widening — the arm is not load-bearing"
    grep -q "^sandbox-widened-since-record" "$WORK/out-mutsbspec" \
        && fail "MUT-SB-SPEC: the blind build still raises the finding"
    grep -q "^sandbox-delta${TAB}-${TAB}NONE" "$WORK/out-mutsbspec" \
        || fail "MUT-SB-SPEC: the mutant did not reproduce the dangerous shape the arm refuses (a seat reading NONE while the sandbox widened)"
    echo "test_fx_report: S4-SANDBOX-MUTANT the widening-blind build (the addition re-derived from today's proxy) reads NONE while a sidecar declared inet — §7.1a's failure, caught"

    # MUT-SB-PIN (THE SECOND MANDATED BLIND): the sandbox pin is JOINED ON THE
    # DRIFTED VALUE — the comparison is short-circuited to equal, so the
    # operator table's drift vanishes from the sandbox class entirely.
    mutbuild sbpin 's/int sb_drift = P->present && strcmp(P->got, P->want) != 0;/int sb_drift = 0; (void)P->want;/'
    grep -q "int sb_drift = 0;" "$WORK/mut-sbpin.c" \
        || fail "MUT-SB-PIN: the sed did not land (check the source text)"
    FXSTORE_BIN="$FXSTORE" "$REPO/build/fx-report-sbpin" --store "$WORK/s1" \
        --proxy "$REPO/build/fx-hostgate" --proxy-log "$WORK/call-log-host.jsonl" \
        --policy-dir "$WORK/sb-pol-drift" > "$WORK/out-mutsbpin" 2>/dev/null
    grep -q "^sandbox-pin-drift" "$WORK/out-mutsbpin" \
        && fail "MUT-SB-PIN: the join-on-the-drifted-pin build STILL reports the drift — the arm is not load-bearing"
    grep -q "^sandbox-pin${TAB}ops-sandbox.tsv${TAB}sha.*${TAB}MATCH" "$WORK/out-mutsbpin" \
        || fail "MUT-SB-PIN: the mutant did not reproduce the blindness (the table reads MATCH while it drifted)"
    echo "test_fx_report: S4-SANDBOX-MUTANT the join-on-the-drifted-pin build reports the operator sandbox table as MATCH while it drifted — the quiet release, caught"

# the mutants are gate artifacts, not seats — remove them so no stale
# binary can later answer for the seat
rm -f "$REPO/build/fx-report-class" "$REPO/build/fx-report-attrib" "$REPO/build/fx-report-finding" \
    "$REPO/build/fx-report-ops" "$REPO/build/fx-report-refuse" \
    "$REPO/build/fx-report-claim" "$REPO/build/fx-report-enroll" "$REPO/build/fx-report-loudlong" \
    "$REPO/build/fx-report-calljoin" "$REPO/build/fx-report-callclassify" "$REPO/build/fx-report-callscope" \
    "$REPO/build/fx-report-exec" "$REPO/build/fx-report-reach" "$REPO/build/fx-report-pindrift" \
    "$REPO/build/fx-report-sbspec" "$REPO/build/fx-report-sbpin" \
    "$REPO/build/fx-report-identity" "$REPO/build/fx-report-verdict"

echo "test_fx_report: PASS — the reconstruction is answerable from the report alone (both inputs readable, the diff, the generation each produced), the taxonomy separates none-occurred from not-durably-recorded (a never-booted store says so; refusals cannot be counted), the operator class is MEASURED from the .operator journal where the journal exists and DERIVED only where it does not (the .recovery row, or the missing file) with the derivation RETAINED beside the journal for its own blind spots (and the mutations blind exactly their own arms), the gc retention carve-out is re-measured every run (a surviving snapshot's dir is retained, a pruned one's is reaped), the retention policy is the user's DECISION (UNBOUNDED, 2026-10-12) pinned where it prints — every row, its named cost, and the old 'NO policy exists' claim asserted ABSENT, and the output is byte-deterministic and independent of any self-report."
